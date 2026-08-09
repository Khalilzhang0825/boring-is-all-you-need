#requires -Version 7.5
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$hooks = Join-Path $repoRoot "tools\hooks"
$script:Passed = 0
$script:Failed = 0
$script:ResultRegistry = @{}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("steadyagent-v2-hooks-" + [guid]::NewGuid().ToString("N"))
$auditPath = Join-Path $fixtureRoot "guard-audit.log"

$hookInvocationLedger = [Environment]::GetEnvironmentVariable(
    "STEADYAGENT_HOOK_INVOCATION_LEDGER"
)
if (-not [string]::IsNullOrWhiteSpace($hookInvocationLedger)) {
    if ($env:STEADYAGENT_EQUIVALENCE_TEST_MODE -ne "1") {
        throw "Hook invocation ledger is available only to the isolated equivalence test."
    }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\")
    $ledgerFull = [IO.Path]::GetFullPath($hookInvocationLedger)
    $ledgerParent = [IO.Path]::GetFullPath((Split-Path -Parent $ledgerFull)).TrimEnd("\")
    $ledgerLeaf = Split-Path -Leaf $ledgerFull
    if (-not [string]::Equals(
        $ledgerParent,
        $tempRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -or $ledgerLeaf -notmatch '^steadyagent-hook-invocation-[a-f0-9]{32}[.]log$') {
        throw "Hook invocation ledger path is outside the isolated temp contract."
    }
    $parentAttributes = [IO.File]::GetAttributes($ledgerParent)
    if (($parentAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Hook invocation ledger parent cannot be a reparse point."
    }
    if (-not (Test-Path -LiteralPath $ledgerFull -PathType Leaf)) {
        throw "Hook invocation ledger was not prepared by the equivalence test."
    }
    $ledgerAttributes = [IO.File]::GetAttributes($ledgerFull)
    if (($ledgerAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Hook invocation ledger cannot be a reparse point."
    }
    [IO.File]::AppendAllText(
        $ledgerFull,
        ("hooks|" + $repoRoot + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )
}

function New-Event {
    param([hashtable]$Value)
    return ($Value | ConvertTo-Json -Compress -Depth 12)
}

function Invoke-Hook {
    param([string]$Name, [string]$InputText, [string[]]$Arguments = @())
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "pwsh.exe"
    $hookPath = if ([IO.Path]::IsPathRooted($Name)) { $Name } else { Join-Path $hooks $Name }
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"" + $hookPath + "`""
    foreach ($argument in $Arguments) {
        $psi.Arguments += " `"" + ([string]$argument).Replace('"', '\"') + "`""
    }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    try { $psi.StandardInputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
    try { $psi.StandardErrorEncoding = [Text.Encoding]::UTF8 } catch { }
    $oldAuditPath = [Environment]::GetEnvironmentVariable(
        "STEADYAGENT_GUARD_AUDIT_LOG",
        "Process"
    )
    [Environment]::SetEnvironmentVariable(
        "STEADYAGENT_GUARD_AUDIT_LOG",
        $auditPath,
        "Process"
    )
    try {
        $process = [Diagnostics.Process]::Start($psi)
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            "STEADYAGENT_GUARD_AUDIT_LOG",
            $oldAuditPath,
            "Process"
        )
    }
    try {
        if ($InputText) {
            $inputBytes = [Text.Encoding]::UTF8.GetBytes($InputText)
            $process.StandardInput.BaseStream.Write(
                $inputBytes,
                0,
                $inputBytes.Length
            )
            $process.StandardInput.BaseStream.Flush()
        }
    }
    catch {
        # A bounded guard may close stdin as soon as it proves the event is too
        # large. The deny decision on stdout remains the authoritative result.
    }
    finally {
        try { $process.StandardInput.Close() } catch { }
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout; Error = $stderr }
}

function Get-ManagedPreToolUseBlocks {
    param([string]$TemplateText)

    $blocks = New-Object Collections.Generic.List[object]
    $current = $null
    foreach ($line in ($TemplateText -split "`r?`n")) {
        if ($line -ceq "[[hooks.PreToolUse]]") {
            if ($null -ne $current) { $blocks.Add([pscustomobject]$current) }
            $current = @{ Matcher = ""; Script = ""; Arguments = @() }
            continue
        }
        if ($line -match '^\[\[hooks[.]' -and $null -ne $current -and
            $line -cne "[[hooks.PreToolUse.hooks]]") {
            $blocks.Add([pscustomobject]$current)
            $current = $null
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^matcher = "(.+)"$') {
            $current.Matcher = [string]$Matches[1]
        }
        elseif ($line -match 'agent-hook-[a-z-]+[.]ps1') {
            $current.Script = [string]$Matches[0]
            if ($line -match '-GuardMode ([A-Za-z]+)') {
                $current.Arguments = @("-GuardMode", [string]$Matches[1])
            }
            if ($line -match '-EnforcementMode ([A-Za-z]+)') {
                $current.Arguments += @("-EnforcementMode", [string]$Matches[1])
            }
        }
    }
    if ($null -ne $current) { $blocks.Add([pscustomobject]$current) }
    return @($blocks | ForEach-Object { $_ })
}

function Invoke-ManagedPreToolUse {
    param(
        [object[]]$Blocks,
        [string]$InputText,
        [Collections.Generic.List[string]]$Ledger
    )

    $event = $InputText | ConvertFrom-Json -DateKind String
    $toolName = [string]$event.tool_name
    $results = New-Object Collections.Generic.List[object]
    foreach ($block in $Blocks) {
        if (-not $block.Matcher -or -not $block.Script) {
            throw "Managed PreToolUse block is incomplete."
        }
        if ($toolName -notmatch ('^(?:' + [string]$block.Matcher + ')$')) { continue }
        $Ledger.Add(([string]$block.Script + '|' + $toolName))
        $results.Add((Invoke-Hook `
            -Name ([string]$block.Script) `
            -InputText $InputText `
            -Arguments @($block.Arguments)))
    }
    return @($results | ForEach-Object { $_ })
}

function Test-AnyHookDeny {
    param([object[]]$Results)
    return @($Results | Where-Object {
        $_.Output -match '"permissionDecision"\s*:\s*"deny"'
    }).Count -gt 0
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($script:ResultRegistry.ContainsKey($Name)) {
        $script:Failed++
        Write-Host ("FAIL duplicate public evidence case name - " + $Name)
        return
    }
    $script:ResultRegistry[$Name] = $Condition
    if ($Condition) {
        $script:Passed++
        Write-Host ("PASS " + $Name)
    }
    else {
        $script:Failed++
        Write-Host ("FAIL " + $Name + $(if ($Detail) { " - " + $Detail } else { "" }))
    }
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        )).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Write-SemanticPass {
    param([string]$Id, [string[]]$Cases)
    $missing = @($Cases | Where-Object { -not $script:ResultRegistry.ContainsKey($_) })
    $failed = @($Cases | Where-Object {
        $script:ResultRegistry.ContainsKey($_) -and -not $script:ResultRegistry[$_]
    })
    if ($missing.Count -eq 0 -and $failed.Count -eq 0) {
        Write-Host ("SEMANTIC PASS " + $Id)
        return
    }
    $detail = "missing={0}; failed={1}" -f ($missing -join ","), ($failed -join ",")
    Assert-True -Name ("semantic evidence registry complete: " + $Id) -Condition $false -Detail $detail
}

function Assert-Deny {
    param([string]$Name, [object]$Result)
    $ok = $false
    try {
        $json = $Result.Output | ConvertFrom-Json -DateKind String
        $hook = $json.hookSpecificOutput
        $ok = ($Result.ExitCode -eq 0 -and -not $Result.Error -and
            $hook.hookEventName -eq "PreToolUse" -and
            $hook.permissionDecision -eq "deny" -and
            [string]$hook.permissionDecisionReason)
    }
    catch { $ok = $false }
    Assert-True -Name $Name -Condition $ok -Detail ($Result.Output + $Result.Error)
}

function Assert-NoDecision {
    param([string]$Name, [object]$Result)
    Assert-True -Name $Name -Condition (
        $Result.ExitCode -eq 0 -and -not $Result.Error -and $Result.Output -notmatch '"permissionDecision"\s*:\s*"deny"'
    ) -Detail ($Result.Output + $Result.Error)
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    $stateRoot = Join-Path $fixtureRoot "state"
    $agentStateRoot = Join-Path $fixtureRoot "agent-state"
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $agentStateRoot ".agent") -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $stateRoot "PROJECT_STATE.md"), "# State`nSMOKE_PROJECT_STATE", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $agentStateRoot ".agent\state.md"), "# State`nSMOKE_AGENT_STATE", [Text.Encoding]::UTF8)

    $managedTemplatePath = Join-Path $repoRoot `
        "templates\codex\requirements.managed-hooks.example.toml"
    if (-not (Test-Path -LiteralPath $managedTemplatePath -PathType Leaf)) {
        $managedTemplatePath = Join-Path $repoRoot `
            "manifests\codex-requirements.expected.toml"
    }
    $managedTemplateText = [IO.File]::ReadAllText(
        $managedTemplatePath,
        [Text.Encoding]::UTF8
    )
    Assert-True "managed template retains SessionStart" ($managedTemplateText -match '(?m)^\[\[hooks[.]SessionStart\]\]$')
    Assert-True "managed template retains one unified PreToolUse guard" (
        ([regex]::Matches($managedTemplateText, '(?m)^\[\[hooks[.]PreToolUse\]\]$')).Count -eq 1
    )
    Assert-True "managed template runs the unified PreToolUse guard in audit-only mode" (
        $managedTemplateText -match '-GuardMode Unified -EnforcementMode Audit'
    )
    Assert-True "managed template retains PreCompact" ($managedTemplateText -match '(?m)^\[\[hooks[.]PreCompact\]\]$')
    Assert-True "managed template routes context to the Codex-only runtime" (
        $managedTemplateText -match 'agent-hook-context[.]ps1' -and
        $managedTemplateText -notmatch '(?i)claude'
    )
    Assert-True "managed template omits a Caveman repair hook" (
        $managedTemplateText -notmatch 'codex-hook-caveman-lite-sync[.]ps1'
    )
    Assert-True "managed template omits UserPromptSubmit" ($managedTemplateText -notmatch 'UserPromptSubmit')
    Assert-True "managed template omits PermissionRequest" ($managedTemplateText -notmatch 'PermissionRequest')
    Assert-True "managed template omits PostToolUse" ($managedTemplateText -notmatch 'PostToolUse')

    $managedPreToolUseBlocks = @(Get-ManagedPreToolUseBlocks $managedTemplateText)
    $managedHookCases = @(
        [pscustomobject]@{
            Name = "shell"
            Event = New-Event @{ tool_name = "functions.shell_command"; tool_input = @{ command = "git status" } }
            Deny = $false
        },
        [pscustomobject]@{
            Name = "file"
            Event = New-Event @{ tool_name = "apply_patch"; tool_input = @{ path = "fixture/.env" } }
            Deny = $false
        },
        [pscustomobject]@{
            Name = "mixed parallel"
            Event = New-Event @{
                tool_name = "multi_tool_use.parallel"
                tool_input = @{ tool_uses = @(
                    @{ recipient_name = "functions.shell_command"; parameters = @{ command = "git status" } },
                    @{ recipient_name = "apply_patch"; parameters = @{ path = "fixture/.env" } }
                ) }
            }
            Deny = $false
        },
        [pscustomobject]@{
            Name = "mixed parallel shell danger"
            Event = New-Event @{
                tool_name = "multi_tool_use.parallel"
                tool_input = @{ tool_uses = @(
                    @{ recipient_name = "functions.shell_command"; parameters = @{ command = "git reset --hard HEAD" } },
                    @{ recipient_name = "apply_patch"; parameters = @{ path = "docs/safe.md" } }
                ) }
            }
            Deny = $false
        },
        [pscustomobject]@{
            Name = "incomplete mixed parallel"
            Event = New-Event @{
                tool_name = "multi_tool_use.parallel"
                tool_input = @{ tool_uses = @(
                    @{ recipient_name = "functions.shell_command"; parameters = @{ command = "git status" } },
                    @{ recipient_name = "apply_patch"; parameters = @{} }
                ) }
            }
            Deny = $false
        }
    )
    $managedHookDurations = New-Object Collections.Generic.List[double]
    foreach ($managedHookCase in $managedHookCases) {
        $hookLedger = New-Object Collections.Generic.List[string]
        $managedHookStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $managedResults = @(Invoke-ManagedPreToolUse `
            -Blocks $managedPreToolUseBlocks `
            -InputText ([string]$managedHookCase.Event) `
            -Ledger $hookLedger)
        $managedHookStopwatch.Stop()
        $managedHookDurations.Add($managedHookStopwatch.Elapsed.TotalMilliseconds)
        Assert-True ("managed runtime launches one PowerShell for " + $managedHookCase.Name) (
            $hookLedger.Count -eq 1 -and $managedResults.Count -eq 1
        ) ($hookLedger -join ",")
        Assert-True ("managed runtime enforces expected decision for " + $managedHookCase.Name) (
            (Test-AnyHookDeny $managedResults) -eq [bool]$managedHookCase.Deny
        ) (($managedResults | ForEach-Object { $_.Output + $_.Error }) -join ";")
    }
    $sortedManagedHookDurations = @($managedHookDurations | Sort-Object)
    $managedHookMedianMs = $sortedManagedHookDurations[
        [int][Math]::Floor($sortedManagedHookDurations.Count / 2)
    ]
    $managedHookMaxMs = ($sortedManagedHookDurations | Measure-Object -Maximum).Maximum
    Write-Host ("HOOK_RUNTIME_METRIC cold_start_median_ms={0:N1} cold_start_max_ms={1:N1} samples={2}" -f
        $managedHookMedianMs, $managedHookMaxMs, $sortedManagedHookDurations.Count)
    Assert-True "managed PreToolUse cold-start median stays within 6000 ms" (
        $managedHookMedianMs -le 6000
    ) ("median_ms={0:N1}" -f $managedHookMedianMs)
    Assert-True "managed PreToolUse cold-start maximum stays within 15000 ms" (
        $managedHookMaxMs -le 15000
    ) ("max_ms={0:N1}" -f $managedHookMaxMs)

    $reviewRuleText = [IO.File]::ReadAllText(
        (Join-Path $repoRoot "rules\review-gates.md"),
        [Text.Encoding]::UTF8
    )
    Assert-True "review rules are Codex-only" ($reviewRuleText -match 'Applies to: Codex Desktop only[.]')
    Assert-True "review rules omit a combined host matrix" ($reviewRuleText -notmatch '\| Codex / Claude Code \|')

    $diagnoseText = [IO.File]::ReadAllText(
        (Join-Path $repoRoot "tools\diagnose-install.ps1"),
        [Text.Encoding]::UTF8
    )
    Assert-True "diagnosis is Codex-only" (
        $diagnoseText -match 'Boring Is All You Need v3[.]0[.]0 Codex diagnosis' -and
        $diagnoseText -notmatch '[.]claude'
    )
    Assert-True "diagnosis contains no Claude hard gate" ($diagnoseText -notmatch '(?i)claude')
    Assert-True "diagnosis checks the exact managed matrix" (
        $diagnoseText -match 'active managed config exactly matches the rendered V2 matrix'
    )

    $result = Invoke-Hook "agent-hook-context.ps1" (New-Event @{ source = "startup"; cwd = $fixtureRoot })
    Assert-True "SessionStart emits compact Codex context" ($result.ExitCode -eq 0 -and -not $result.Error -and $result.Output -match "Caveman startup status report")
    Assert-True "startup reports Caveman lite exactly once" (
        ([regex]::Matches($result.Output, [regex]::Escape("Caveman startup status report: ON, mode lite"))).Count -eq 1
    )
    Assert-True "startup injects lesson titles" ($result.Output -match "Known pitfalls to avoid" -and $result.Output -match "PowerShell 7 encoding")
    Assert-True "fresh install without review marker suppresses due notice" (
        $result.Output -notmatch "HARNESS-REVIEW DUE"
    )
    Assert-True "startup does not inject stale state" ($result.Output -notmatch "TASK STATE")
    $startupObject = $result.Output | ConvertFrom-Json -DateKind String
    $startupContext = [string]$startupObject.hookSpecificOutput.additionalContext
    $duplicatedHostContractFragments = @(
        "Read the closest AGENTS.md plus project state before editing.",
        "Keep context lean; load detailed rules only when needed.",
        "Run preflight before edits and verify before claiming completion.",
        "Multi-file changes alone do not require independent fresh-context review;",
        "Use explicit-file checkpoint commits; do not push unless asked."
    )
    Assert-True "startup omits five AGENTS host contract duplicates" (
        @($duplicatedHostContractFragments | Where-Object {
            $startupContext -match [regex]::Escape($_)
        }).Count -eq 0
    )
    Assert-True "startup dynamic context stays within 800 characters" ($startupContext.Length -le 800)
    Assert-True "startup output has no known mojibake marker" ($result.Output -notmatch [string][char]0x951B)

    $reviewedHome = Join-Path $fixtureRoot "reviewed-home"
    New-Item -ItemType Directory -Path (Join-Path $reviewedHome "rules"), (Join-Path $reviewedHome "config") -Force | Out-Null
    $lessonBodyMarker = "LESSON_BODY_MUST_NOT_BE_INJECTED"
    [IO.File]::WriteAllText(
        (Join-Path $reviewedHome "rules\lessons.md"),
        ("### Fixture lesson`n{0}`n### <placeholder>`nPlaceholder body" -f $lessonBodyMarker),
        [Text.Encoding]::UTF8
    )
    $reviewMarker = Join-Path $reviewedHome ".harness-last-review"
    [IO.File]::WriteAllText($reviewMarker, [datetime]::UtcNow.ToString("yyyy-MM-dd"), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $reviewedHome "config\caveman.json"), '{"defaultMode":"off"}', [Text.Encoding]::UTF8)
    $result = Invoke-Hook "agent-hook-context.ps1" `
        (New-Event @{ source = "startup"; cwd = $fixtureRoot }) `
        @("-SteadyAgentHome", $reviewedHome)
    Assert-True "current review marker suppresses due notice" ($result.Output -notmatch "HARNESS-REVIEW DUE")
    Assert-True "local Caveman config can disable mode" ($result.Output -match "Caveman startup status report: OFF, mode off")
    Assert-True "fixture lesson title is injected" ($result.Output -match "Fixture lesson")
    Assert-True "lesson body is not injected" ($result.Output -notmatch [regex]::Escape($lessonBodyMarker))
    Assert-True "placeholder lesson title is excluded" ($result.Output -notmatch [regex]::Escape("<placeholder>"))

    $manyLessonsPath = Join-Path $reviewedHome "rules\lessons.md"
    $manyLessonLines = @(1..20 | ForEach-Object {
        "### Synthetic lesson title number {0} with bounded startup context" -f $_
    })
    [IO.File]::WriteAllLines($manyLessonsPath, $manyLessonLines, [Text.Encoding]::UTF8)
    $result = Invoke-Hook "agent-hook-context.ps1" `
        (New-Event @{ source = "startup"; cwd = $fixtureRoot }) `
        @("-SteadyAgentHome", $reviewedHome)
    $manyLessonsObject = $result.Output | ConvertFrom-Json -DateKind String
    $manyLessonsContext = [string]$manyLessonsObject.hookSpecificOutput.additionalContext
    Assert-True "startup many-lessons context stays within 800 characters" (
        $manyLessonsContext.Length -le 800
    )
    Assert-True "startup many-lessons context reports omitted titles" (
        $manyLessonsContext -match 'more pitfall title[(]s[)]; see lessons[.]md'
    )

    $staleInstallHome = Join-Path $fixtureRoot "stale-install-home"
    $staleHookDirectory = Join-Path $staleInstallHome "tools\hooks"
    New-Item -ItemType Directory -Path $staleHookDirectory -Force | Out-Null
    $staleInstalledContext = Join-Path $staleHookDirectory "agent-hook-context.ps1"
    [IO.File]::WriteAllText($staleInstalledContext, "# installed fixture", [Text.Encoding]::UTF8)
    [IO.File]::SetLastWriteTimeUtc(
        $staleInstalledContext,
        [datetime]::UtcNow.Date.AddDays(-90)
    )
    $result = Invoke-Hook "agent-hook-context.ps1" `
        (New-Event @{ source = "startup"; cwd = $fixtureRoot }) `
        @("-SteadyAgentHome", $staleInstallHome)
    Assert-True "90-day install baseline without marker emits due notice" (
        $result.Output -match "HARNESS-REVIEW DUE" -and
        $result.Output -match "90 days"
    )

    [IO.File]::WriteAllText($reviewMarker, [datetime]::UtcNow.Date.AddDays(-89).ToString("yyyy-MM-dd"), [Text.Encoding]::UTF8)
    $result = Invoke-Hook "agent-hook-context.ps1" `
        (New-Event @{ source = "startup"; cwd = $fixtureRoot }) `
        @("-SteadyAgentHome", $reviewedHome)
    Assert-True "89-day review marker suppresses due notice" ($result.Output -notmatch "HARNESS-REVIEW DUE")

    [IO.File]::WriteAllText($reviewMarker, [datetime]::UtcNow.Date.AddDays(-90).ToString("yyyy-MM-dd"), [Text.Encoding]::UTF8)
    $result = Invoke-Hook "agent-hook-context.ps1" `
        (New-Event @{ source = "startup"; cwd = $fixtureRoot }) `
        @("-SteadyAgentHome", $reviewedHome)
    Assert-True "90-day review marker emits due notice" (
        $result.Output -match "HARNESS-REVIEW DUE" -and $result.Output -match "90 days ago"
    )

    [IO.File]::WriteAllText($reviewMarker, "not-a-valid-review-date", [Text.Encoding]::UTF8)
    $result = Invoke-Hook "agent-hook-context.ps1" `
        (New-Event @{ source = "startup"; cwd = $fixtureRoot }) `
        @("-SteadyAgentHome", $reviewedHome)
    Assert-True "invalid review marker fails safe" (
        $result.Output -match "HARNESS-REVIEW DUE" -and $result.Output -match "No valid config review on record"
    )

    $result = Invoke-Hook "agent-hook-context.ps1" (New-Event @{ source = "compact"; cwd = $stateRoot })
    Assert-True "compact restores PROJECT_STATE" ($result.Output -match "SMOKE_PROJECT_STATE")
    Assert-True "compact context omits the Caveman startup report" (
        $result.Output -notmatch 'Caveman startup status report'
    )
    $result = Invoke-Hook "agent-hook-context.ps1" (New-Event @{ source = "resume"; cwd = $agentStateRoot })
    Assert-True "resume restores .agent state" ($result.Output -match "SMOKE_AGENT_STATE")
    Assert-True "resume context omits the Caveman startup report" (
        $result.Output -notmatch 'Caveman startup status report'
    )
    $result = Invoke-Hook "agent-hook-context.ps1" (New-Event @{ source = "resume"; cwd = $fixtureRoot })
    Assert-True "resume without state emits a bounded fallback" (
        $result.Output -match 'No PROJECT_STATE'
    )

    $result = Invoke-Hook "agent-hook-precompact.ps1" ""
    Assert-True "PreCompact emits supported systemMessage" ($result.ExitCode -eq 0 -and -not $result.Error -and $result.Output -match "systemMessage")

    $result = Invoke-Hook "agent-hook-command-guard.ps1" ""
    Assert-Deny "command guard fails closed on empty input" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" "{bad"
    Assert-Deny "command guard fails closed on malformed JSON" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" "null"
    Assert-Deny "command guard fails closed on null event" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (
        New-Event @{ tool_name = "PowerShell"; tool_input = @{} }
    )
    Assert-Deny "command guard fails closed on missing command" $result
    $missingCommandUtilsRoot = Join-Path $fixtureRoot "missing-command-utils"
    New-Item -ItemType Directory -Path $missingCommandUtilsRoot -Force | Out-Null
    $isolatedCommandGuard = Join-Path $missingCommandUtilsRoot "agent-hook-command-guard.ps1"
    Copy-Item -LiteralPath (Join-Path $hooks "agent-hook-command-guard.ps1") `
        -Destination $isolatedCommandGuard
    $result = Invoke-Hook $isolatedCommandGuard (
        New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git status" } }
    )
    Assert-Deny "command guard fails closed when utils are absent" $result
    $oversizedCommandEvent = (
        '{"tool_name":"PowerShell","tool_input":{"command":"git status","padding":"' +
        ("x" * 300000) +
        '"}}'
    )
    $result = Invoke-Hook "agent-hook-command-guard.ps1" $oversizedCommandEvent
    Assert-Deny "command guard rejects oversized raw hook input before JSON traversal" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git status" } })
    Assert-NoDecision "command guard allows safe command" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git push --force-with-lease=refs/heads/main:deadbeef origin main" } })
    Assert-Deny "command guard denies force-with-lease assignment" $result
    $combinedForcePushCases = @(
        "git push -fu origin HEAD",
        "git push -uf origin HEAD"
    )
    foreach ($combinedForcePush in $combinedForcePushCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $combinedForcePush } })
        Assert-Deny ("command guard denies combined short force option: " + $combinedForcePush) $result
    }
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git push --mirror origin HEAD" } })
    Assert-Deny "command guard denies mirror push" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git push --force-unknown origin HEAD" } })
    Assert-Deny "command guard fails closed on unknown force-like push option" $result
    $remoteDeletionPushCases = @(
        "git push --delete origin main",
        "git push origin --delete main",
        "git push origin -d main",
        "git push -vd origin main",
        "git push origin -dv main",
        "git push --prune origin",
        "git push origin --prune",
        "git push origin :refs/heads/main"
    )
    foreach ($remoteDeletionPush in $remoteDeletionPushCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $remoteDeletionPush } })
        Assert-Deny ("command guard denies remote deletion push: " + $remoteDeletionPush) $result
    }
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git push origin main" } })
    Assert-NoDecision "command guard allows ordinary push" $result
    $normalizedDangerCases = @(
        '"C:\Program Files\Git\cmd\git.exe" reset --hard HEAD',
        "/usr/bin/rm -rf build",
        'bash -c "/usr/bin/rm -rf build"',
        '"/bin/bash" -c "/usr/bin/rm -rf build"',
        'Microsoft.PowerShell.Management\Remove-Item -LiteralPath C:\fixture -Recurse -Force',
        '"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -Command "git reset --hard HEAD"'
    )
    foreach ($normalizedDanger in $normalizedDangerCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $normalizedDanger } })
        Assert-Deny ("command guard normalizes and denies dangerous command: " + $normalizedDanger) $result
    }
    $normalizedSafeCases = @(
        '"C:\Program Files\Git\cmd\git.exe" --version',
        'Get-Command "C:\Program Files\Git\cmd\git.exe"',
        "/usr/bin/rm --version",
        'Write-Output ''"C:\Program Files\Git\cmd\git.exe" reset --hard HEAD''',
        "Write-Output 'Microsoft.PowerShell.Management\Remove-Item -Recurse -Force'"
    )
    foreach ($normalizedSafe in $normalizedSafeCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $normalizedSafe } })
        Assert-NoDecision ("command guard allows safe query or quoted prose: " + $normalizedSafe) $result
    }
    $transparentWrapperDangerCases = @(
        "/usr/bin/env git reset --hard HEAD",
        "env VAR=x git push -f",
        'sh -c "exec git reset --hard HEAD"',
        'sh -lc "git reset --hard HEAD"',
        'sh -c "command git restore --worktree x"',
        'powershell -NoProfile -Command "& { git reset --hard HEAD }"',
        'powershell.exe -Com "git reset --hard HEAD"',
        'cmd.exe /k "git reset --hard HEAD"',
        'powershell -NoProfile -Command "& ''C:\Program Files\Git\cmd\git.exe'' reset --hard HEAD"',
        'env VAR=x sh -c "exec git reset --hard HEAD"',
        "env --definitely-unknown git status",
        'env "$TOOL" reset --hard HEAD',
        'exec "$TOOL" reset --hard HEAD',
        'command "$TOOL" reset --hard HEAD',
        "sh -c",
        "powershell -NoProfile -Command"
    )
    foreach ($transparentWrapperDanger in $transparentWrapperDangerCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $transparentWrapperDanger } })
        Assert-Deny ("command guard denies danger behind transparent wrappers: " + $transparentWrapperDanger) $result
    }
    $transparentWrapperSafeCases = @(
        "env",
        "env VAR=x",
        "command -v git",
        "env VAR=x git status",
        'sh -c "exec git status"',
        'powershell -NoProfile -Command "& { git status }"',
        '& "C:\Program Files\Git\cmd\git.exe" status',
        "Write-Output 'env VAR=x git reset --hard HEAD'",
        "env -u TEMP git status",
        "exec -- git status",
        "command -p git status",
        "exec",
        "command",
        "env --version"
    )
    foreach ($transparentWrapperSafe in $transparentWrapperSafeCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $transparentWrapperSafe } })
        Assert-NoDecision ("command guard preserves safe transparent wrapper use: " + $transparentWrapperSafe) $result
    }
    $wrapperNormalizationDangerCases = @(
        'cmd.exe /c"git reset --hard HEAD"',
        'cmd.exe /k"git reset --hard HEAD"',
        'cmd.exe /c "call git reset --hard HEAD"',
        'cmd.exe /c "@git reset --hard HEAD"',
        'cmd.exe /c "(git reset --hard HEAD)"',
        'powershell.exe -Command ". git reset --hard HEAD"'
    )
    foreach ($wrapperNormalizationDanger in $wrapperNormalizationDangerCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $wrapperNormalizationDanger } })
        Assert-Deny ("command guard normalizes compact or prefixed wrapper danger: " + $wrapperNormalizationDanger) $result
    }
    $wrapperNormalizationSafeCases = @(
        'cmd.exe /c"git --version"',
        'cmd.exe /k"git --version"',
        'cmd.exe /c "call git --version"',
        'cmd.exe /c "@git --version"',
        'cmd.exe /c "(git --version)"',
        'powershell.exe -Command ". git --version"',
        'Write-Output ''cmd.exe /c"git reset --hard HEAD"''',
        'Write-Output ''powershell.exe -Command ". git reset --hard HEAD"'''
    )
    foreach ($wrapperNormalizationSafe in $wrapperNormalizationSafeCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $wrapperNormalizationSafe } })
        Assert-NoDecision ("command guard preserves safe compact or prefixed wrapper use: " + $wrapperNormalizationSafe) $result
    }
    $deepTransparentWrapperDanger = (("env " * 40) + "git reset --hard HEAD").Trim()
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $deepTransparentWrapperDanger } })
    Assert-Deny "command guard bounds transparent wrapper recursion" $result
    $oversizedTransparentWrapper = "env VAR=x " + ("x" * 70000)
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $oversizedTransparentWrapper } })
    Assert-Deny "command guard bounds transparent wrapper command length" $result
    $dangerText = "git reset --hard HEAD"
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $dangerText } })
    Assert-Deny "command guard denies destructive Git" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git restore task.txt" } })
    Assert-Deny "command guard denies default worktree restore" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git restore --worktree task.txt" } })
    Assert-Deny "command guard denies explicit worktree restore" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git checkout -- task.txt" } })
    Assert-Deny "command guard denies checkout path discard" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git checkout task.txt" } })
    Assert-Deny "command guard denies ambiguous checkout path" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git checkout HEAD task.txt" } })
    Assert-Deny "command guard denies tree checkout path" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git checkout --pathspec-from-file=paths.txt" } })
    Assert-Deny "command guard denies checkout pathspec file" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git restore --staged task.txt" } })
    Assert-NoDecision "command guard allows staged-only restore" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git add -u" } })
    Assert-Deny "command guard denies update-all staging" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git add :/" } })
    Assert-Deny "command guard denies repository-wide pathspec staging" $result
    $backtickEscapeDangerCases = @(
        'git re`set --hard HEAD',
        'git a`dd -A',
        'power`shell.exe -EncodedCommand AAAA',
        '.\tools\git-checkpoint.ps1 -A`ll -Message test'
    )
    foreach ($backtickEscapeDanger in $backtickEscapeDangerCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{ command = $backtickEscapeDanger }
        })
        Assert-Deny (
            "command guard fails closed on executable PowerShell backtick escape: " +
            $backtickEscapeDanger
        ) $result
    }
    $safeSingleQuotedBacktick = 'Write-Output ''literal ` text'''
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{ command = $safeSingleQuotedBacktick }
    })
    Assert-NoDecision "command guard allows a literal backtick inside single-quoted data" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "del -Recurse build" } })
    Assert-Deny "command guard denies recursive del alias" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath C:\fixture -Recurse:$true -Force' } })
    Assert-Deny "command guard denies explicitly enabled recursive Remove-Item" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath C:\fixture\authorized-delete-target -Recurse -Force' } })
    Assert-NoDecision "command guard allows recursive Remove-Item for an explicit nested literal target" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath ''C:\fixture\authorized delete target'' -Recurse -Force -ErrorAction SilentlyContinue' } })
    Assert-NoDecision "command guard allows a quoted explicit recursive Remove-Item target" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Microsoft.PowerShell.Management\Remove-Item -LiteralPath C:\fixture\authorized-delete-target -Recurse:$true' } })
    Assert-NoDecision "command guard allows module-qualified recursive Remove-Item for an explicit target" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'powershell.exe -NoProfile -Command "Remove-Item -LiteralPath C:\fixture\authorized-delete-target -Recurse -Force"' } })
    Assert-NoDecision "command guard allows an explicit recursive Remove-Item behind PowerShell" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath C:\fixture\authorized-delete-target -Recurse'; workdir = 'C:\fixture\authorized-delete-target' } })
    Assert-Deny "command guard denies recursive removal of the active working directory" $result
    $systemSubtreeTarget = Join-Path $env:SystemRoot "System32"
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{ command = ("Remove-Item -LiteralPath '" + $systemSubtreeTarget.Replace("'", "''") + "' -Recurse -Force") }
    })
    Assert-Deny "command guard denies recursive removal inside a protected system subtree" $result
    $tempChildTarget = Join-Path ([IO.Path]::GetTempPath()) "steadyagent-authorized-delete-target"
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{ command = ("Remove-Item -LiteralPath '" + $tempChildTarget.Replace("'", "''") + "' -Recurse -Force") }
    })
    Assert-NoDecision "command guard still allows an explicit child below the temp root" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath .\authorized-delete-target -Recurse -Force' } })
    Assert-Deny "command guard denies a relative recursive Remove-Item target" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath $targetPath -Recurse -Force' } })
    Assert-Deny "command guard denies an external local variable recursive Remove-Item target" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = '$auditRoot = ''C:\fixture\authorized-delete-target''; Remove-Item -LiteralPath $auditRoot -Recurse -Force' } })
    Assert-NoDecision "command guard allows one same-command safe literal variable assignment" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = '$auditRoot = "C:\fixture\authorized-delete-target"; Remove-Item -LiteralPath $auditRoot -Recurse -Force' } })
    Assert-NoDecision "command guard allows a double-quoted same-command safe literal assignment" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = '$auditRoot = C:\fixture\authorized-delete-target; Remove-Item -LiteralPath $auditRoot -Recurse -Force' } })
    Assert-Deny "command guard denies a bare assignment that PowerShell parses as a command" $result
    $protectedRootLiteral = ([string]$env:USERPROFILE).Replace("'", "''")
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{ command = ('$auditRoot = ''' + $protectedRootLiteral + '''; Remove-Item -LiteralPath $auditRoot -Recurse -Force') }
    })
    Assert-Deny "command guard rechecks a local variable assignment against protected roots" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = '$auditRoot = $HOME; Remove-Item -LiteralPath $auditRoot -Recurse -Force' } })
    Assert-Deny "command guard denies a dynamic local variable assignment" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = '$auditRoot = ''C:\fixture\one''; $auditRoot = ''C:\fixture\two''; Remove-Item -LiteralPath $auditRoot -Recurse -Force' } })
    Assert-Deny "command guard denies a reassigned local variable target" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = '$auditRoot = ''C:\fixture\authorized-delete-target''; $auditRoot += ''\..\..''; Remove-Item -LiteralPath $auditRoot -Recurse -Force' } })
    Assert-Deny "command guard denies a compound-written local variable target" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = '$auditRoot = ''C:\fixture\authorized-delete-target''; [void][int]::TryParse(''1'', [ref]$auditRoot); Remove-Item -LiteralPath $auditRoot -Recurse -Force' } })
    Assert-Deny "command guard denies a referenced local variable target" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'if ($approved) { $auditRoot = ''C:\fixture\authorized-delete-target'' }; Remove-Item -LiteralPath $auditRoot -Recurse -Force' } })
    Assert-Deny "command guard denies a conditional local variable assignment" $result
    foreach ($protectedVariableTarget in @('$HOME', '$USERPROFILE', '$PWD', '$env:TEMP')) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{ command = ('Remove-Item -LiteralPath ' + $protectedVariableTarget + ' -Recurse -Force') }
        })
        Assert-Deny ("command guard denies protected variable recursive target: " + $protectedVariableTarget) $result
    }
    foreach ($dynamicVariableTarget in @('$targetPaths[0]', '$script:targetPath', '$(Get-TargetPath)', '@($targetPath)')) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{ command = ('Remove-Item -LiteralPath ' + $dynamicVariableTarget + ' -Recurse -Force') }
        })
        Assert-Deny ("command guard denies expression recursive target: " + $dynamicVariableTarget) $result
    }
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -Path C:\fixture\authorized-delete-target -Recurse -Force' } })
    Assert-Deny "command guard requires LiteralPath for recursive Remove-Item" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath C:\fixture\one -LiteralPath C:\fixture\two -Recurse -Force' } })
    Assert-Deny "command guard denies multiple recursive Remove-Item targets" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath C:\ -Recurse -Force' } })
    Assert-Deny "command guard denies recursive removal of a filesystem root" $result
    $result = Invoke-Hook `
        "agent-hook-command-guard.ps1" `
        (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath $targetPath -Recurse -Force' } }) `
        @("-GuardMode", "Unified", "-EnforcementMode", "Audit")
    Assert-NoDecision "audit-only unified guard never denies an authorized recursive deletion" $result
    $result = Invoke-Hook `
        "agent-hook-command-guard.ps1" `
        (New-Event @{ tool_name = "apply_patch"; tool_input = @{ path = "fixture/.env" } }) `
        @("-GuardMode", "Unified", "-EnforcementMode", "Audit")
    Assert-NoDecision "audit-only unified guard never denies an authorized protected-file edit" $result
    $auditLineCountBefore = if (Test-Path -LiteralPath $auditPath) {
        @([IO.File]::ReadAllLines($auditPath, [Text.Encoding]::UTF8)).Count
    }
    else { 0 }
    $result = Invoke-Hook `
        "agent-hook-command-guard.ps1" `
        (New-Event @{
            tool_name = "multi_tool_use.parallel"
            tool_input = @{ tool_uses = @(
                @{ recipient_name = "functions.shell_command"; parameters = @{ command = "git reset --hard HEAD" } },
                @{ recipient_name = "apply_patch"; parameters = @{ path = "fixture/.env" } }
            ) }
        }) `
        @("-GuardMode", "Unified", "-EnforcementMode", "Audit")
    Assert-NoDecision "audit-only unified guard never denies a mixed authorized payload" $result
    $newAuditLines = if (Test-Path -LiteralPath $auditPath) {
        @([IO.File]::ReadAllLines($auditPath, [Text.Encoding]::UTF8) | Select-Object -Skip $auditLineCountBefore)
    }
    else { @() }
    Assert-True "audit-only unified guard records every recognized mixed-payload risk" (
        @($newAuditLines | Where-Object { $_ -match '\[unified-guard\]' }).Count -eq 2
    ) ($newAuditLines -join "`n")
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath C:\fixture -Recurse:$enabled -Force' } })
    Assert-Deny "command guard fails closed for dynamic recursive Remove-Item" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'rm -LiteralPath C:\fixture -Recurse' } })
    Assert-Deny "command guard treats PowerShell rm as Remove-Item" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'rm -LiteralPath C:\fixture -Recu:$enabled' } })
    Assert-Deny "command guard fails closed for dynamic Recurse prefix on rm" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath C:\fixture -Recurs:$true' } })
    Assert-Deny "command guard denies every valid Recurse prefix" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath C:\fixture -Recurse:$false -Force' } })
    Assert-NoDecision "command guard allows explicitly disabled recursive Remove-Item" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'rm -LiteralPath C:\fixture -Recur:$false' } })
    Assert-NoDecision "command guard allows explicitly disabled Recurse prefix on rm" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath C:\fixture -Rec:false -Force' } })
    Assert-NoDecision "command guard allows false recursive Remove-Item alias" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Remove-Item -LiteralPath C:\fixture -R:0 -Force' } })
    Assert-NoDecision "command guard allows zero recursive Remove-Item alias" $result
    $checkpointAllEnabledCases = @(
        "-A",
        "-Al",
        "-All",
        '-A:$true',
        '-Al:$true',
        '-All:$true'
    )
    foreach ($checkpointAllEnabled in $checkpointAllEnabledCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{
                command = (
                    'powershell.exe -File .\tools\git-checkpoint.ps1 -Message fixture ' +
                    $checkpointAllEnabled
                )
            }
        })
        Assert-Deny (
            "command guard denies enabled checkpoint blanket staging switch: " +
            $checkpointAllEnabled
        ) $result
    }
    $checkpointAllDisabledCases = @(
        '-A:$false',
        '-Al:$false',
        '-All:$false'
    )
    foreach ($checkpointAllDisabled in $checkpointAllDisabledCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{
                command = (
                    'powershell.exe -File .\tools\git-checkpoint.ps1 -Message fixture ' +
                    $checkpointAllDisabled
                )
            }
        })
        Assert-NoDecision (
            "command guard allows disabled checkpoint blanket staging switch: " +
            $checkpointAllDisabled
        ) $result
    }
    $powerShellDashCharacters = @(
        [char]0x2013,
        [char]0x2014,
        [char]0x2015
    )
    foreach ($powerShellDash in $powerShellDashCharacters) {
        $dashCode = ("U+{0:X4}" -f [int]$powerShellDash)
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{ command = ("Remove-Item {0}Rec {0}Force C:\fixture" -f $powerShellDash) }
        })
        Assert-Deny ("command guard denies Unicode-dash recursive Remove-Item: " + $dashCode) $result

        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{ command = ("git-checkpoint.ps1 {0}Al -Message fixture" -f $powerShellDash) }
        })
        Assert-Deny ("command guard denies Unicode-dash checkpoint blanket staging: " + $dashCode) $result

        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{ command = ("pwsh {0}EncodedCommand VwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAHgAJwA=" -f $powerShellDash) }
        })
        Assert-Deny ("command guard denies Unicode-dash encoded PowerShell: " + $dashCode) $result

        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{
                command = ('pwsh {0}Com "Remove-Item {0}Rec {0}Force C:\fixture"' -f $powerShellDash)
            }
        })
        Assert-Deny ("command guard denies Unicode-dash nested PowerShell danger: " + $dashCode) $result

        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{ command = ("Remove-Item {0}Rec:`$false C:\fixture" -f $powerShellDash) }
        })
        Assert-NoDecision ("command guard allows disabled Unicode-dash Recurse: " + $dashCode) $result

        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
            tool_name = "PowerShell"
            tool_input = @{
                command = ("git-checkpoint.ps1 {0}Al:`$false -Message fixture -Files task.txt" -f $powerShellDash)
            }
        })
        Assert-NoDecision ("command guard allows disabled Unicode-dash checkpoint switch: " + $dashCode) $result
    }
    $unicodeNestedDash = [char]0x2013
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "multi_tool_use.parallel"
        tool_input = @{
            tool_uses = @(
                @{
                    recipient_name = "functions.shell_command"
                    parameters = @{
                        command = ("Remove-Item {0}Rec {0}Force C:\fixture" -f $unicodeNestedDash)
                    }
                }
            )
        }
    })
    Assert-Deny "command guard denies nested Unicode-dash danger" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{
            command = ('Write-Output ''Remove-Item {0}Rec {0}Force C:\fixture''' -f $unicodeNestedDash)
        }
    })
    Assert-NoDecision "command guard allows quoted Unicode-dash prose" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "rm --recursive --force build" } })
    Assert-Deny "command guard denies GNU rm long recursive force flags" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "rm safe.txt; rm -rf build" } })
    Assert-Deny "command guard checks every shell statement" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "rm safe.txt && rm --recursive --force build" } })
    Assert-Deny "command guard checks commands after and separator" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "rm safe.txt || rm -fr build" } })
    Assert-Deny "command guard checks commands after or separator" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "rm safe.txt`nrm -rf build" } })
    Assert-Deny "command guard checks commands after newline" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{ command = 'foreach ($item in 1) { if ($item) { Write-Output $item } }' }
    })
    Assert-NoDecision "command guard allows safe nested PowerShell blocks" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{ command = 'foreach ($item in 1) { if ($item) { git reset --hard HEAD } }' }
    })
    Assert-Deny "command guard denies danger inside nested PowerShell blocks" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{ command = '$h = @{ ''Remove-Item'' = ''-Recurse'' }' }
    })
    Assert-NoDecision "command guard allows command-like PowerShell hashtable data" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{ command = '@{ rm = ''-rf'' } | ConvertTo-Json' }
    })
    Assert-NoDecision "command guard allows rm-like PowerShell hashtable data" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{ command = '$h = @{ value = $(git reset --hard HEAD) }' }
    })
    Assert-Deny "command guard denies danger executed inside PowerShell hashtable data" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = 'Write-Output "GNU rm"; Get-ChildItem -Recurse .' } })
    Assert-NoDecision "command guard does not combine quoted rm text with later flags" $result
    $quotedDangerCases = @(
        "git reset '--hard' HEAD",
        "git 'restore' --worktree task.txt",
        "git checkout '--' task.txt",
        "git add '.'",
        "rm '-rf' build",
        'cmd /c "rm -rf build"',
        'powershell -Command "git reset --hard HEAD"',
        'powershell -NoProfile -Command "git restore --worktree task.txt"'
    )
    foreach ($quotedDanger in $quotedDangerCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $quotedDanger } })
        Assert-Deny ("command guard denies quoted or wrapped danger: " + $quotedDanger) $result
    }
    $gitPagerDangerCases = @(
        "git -p reset --hard HEAD",
        "git -P checkout -- task.txt",
        "git -p restore --worktree task.txt",
        "git -P add .",
        "git -p clean -fd",
        "git -C repo reset --hard HEAD",
        "git -c core.pager=cat checkout -- task.txt",
        "git --no-pager add :/",
        "git --exec-path=C:\fixture reset --hard HEAD"
    )
    foreach ($gitPagerDanger in $gitPagerDangerCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $gitPagerDanger } })
        Assert-Deny ("command guard locates subcommand after no-value Git option: " + $gitPagerDanger) $result
    }
    $safeQuotedGitText = @(
        "Write-Output 'git reset --hard HEAD'",
        "Write-Output 'git checkout -- task.txt'",
        "Write-Output 'git add .'",
        "Write-Output 'git restore task.txt'"
    )
    foreach ($safeGitText in $safeQuotedGitText) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $safeGitText } })
        Assert-NoDecision ("command guard allows quoted Git documentation text: " + $safeGitText) $result
    }
    $safeGitGlobalCases = @(
        "git --version",
        "git --help",
        "git --exec-path",
        "git --no-advice status",
        "git --no-lazy-fetch status"
    )
    foreach ($safeGitGlobal in $safeGitGlobalCases) {
        $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = $safeGitGlobal } })
        Assert-NoDecision ("command guard allows safe Git global option: " + $safeGitGlobal) $result
    }
    $nestedDanger = @{
        tool_name = "multi_tool_use.parallel"
        tool_input = @{
            tool_uses = @(
                @{
                    recipient_name = "multi_tool_use.parallel"
                    parameters = @{
                        tool_uses = @(
                            @{ recipient_name = "functions.shell_command"; parameters = @{ command = "git clean -fd" } }
                        )
                    }
                }
            )
        }
    }
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event $nestedDanger)
    Assert-Deny "command guard recursively denies nested danger" $result
    $nestedInputSafe = @{
        tool_name = "multi_tool_use.parallel"
        tool_input = @{
            tool_uses = @(
                @{
                    recipient_name = "multi_tool_use.parallel"
                    input = @{
                        tool_uses = @(
                            @{ recipient_name = "functions.shell_command"; input = @{ command = "git status" } }
                        )
                    }
                }
            )
        }
    }
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event $nestedInputSafe)
    Assert-NoDecision "command guard allows safe nested input schema" $result
    $nestedInputDanger = $nestedInputSafe.Clone()
    $nestedInputDanger.tool_input = @{
        tool_uses = @(
            @{
                recipient_name = "multi_tool_use.parallel"
                input = @{
                    tool_uses = @(
                        @{ recipient_name = "functions.shell_command"; input = @{ command = "git clean -fd" } }
                    )
                }
            }
        )
    }
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event $nestedInputDanger)
    Assert-Deny "command guard denies dangerous nested input schema" $result
    $nestedLongRm = $nestedInputSafe.Clone()
    $nestedLongRm.tool_input = @{
        tool_uses = @(
            @{ recipient_name = "functions.shell_command"; input = @{ command = "rm --force --recursive build" } }
        )
    }
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event $nestedLongRm)
    Assert-Deny "command guard denies nested GNU rm long flags" $result
    $nestedRestore = $nestedInputSafe.Clone()
    $nestedRestore.tool_input = @{
        tool_uses = @(
            @{ recipient_name = "functions.shell_command"; input = @{ command = "git restore --worktree task.txt" } }
        )
    }
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event $nestedRestore)
    Assert-Deny "command guard denies nested worktree restore" $result
    $unknownParallel = @{
        tool_name = "multi_tool_use.parallel"
        tool_input = @{ tool_uses = @(@{ recipient_name = "multi_tool_use.parallel"; parameters = @{ calls = @() } }) }
    }
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event $unknownParallel)
    Assert-Deny "command guard fails closed on unknown nested wrapper" $result
    $deepParallelLeaf = '{"recipient_name":"functions.shell_command","parameters":{"command":"git status"}}'
    for ($depthIndex = 0; $depthIndex -lt 40; $depthIndex++) {
        $deepParallelLeaf = (
            '{"recipient_name":"multi_tool_use.parallel","parameters":{"tool_uses":[' +
            $deepParallelLeaf +
            ']}}'
        )
    }
    $deepParallelEvent = (
        '{"tool_name":"multi_tool_use.parallel","tool_input":{"tool_uses":[' +
        $deepParallelLeaf +
        ']}}'
    )
    $result = Invoke-Hook "agent-hook-command-guard.ps1" $deepParallelEvent
    Assert-Deny "command guard bounds nested hook tree depth before extraction" $result
    $wideParallelLeaves = @(
        1..300 | ForEach-Object {
            '{"recipient_name":"functions.shell_command","parameters":{"command":"git status"}}'
        }
    ) -join ","
    $wideParallelEvent = (
        '{"tool_name":"multi_tool_use.parallel","tool_input":{"tool_uses":[' +
        $wideParallelLeaves +
        ']}}'
    )
    $result = Invoke-Hook "agent-hook-command-guard.ps1" $wideParallelEvent
    Assert-Deny "command guard bounds parallel hook collection width" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "apply_patch"; tool_input = @{ patch = "*** Begin Patch`n*** End Patch" } })
    Assert-NoDecision "command guard ignores named non-shell tool" $result

    $result = Invoke-Hook "agent-hook-file-guard.ps1" ""
    Assert-Deny "file guard fails closed on empty input" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" "{bad"
    Assert-Deny "file guard fails closed on malformed JSON" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" "null"
    Assert-Deny "file guard fails closed on null event" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (
        New-Event @{ tool_name = "apply_patch"; tool_input = @{} }
    )
    Assert-Deny "file guard fails closed on missing path" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (
        New-Event @{
            tool_name = "apply_patch"
            tool_input = @{ patch = "*** Begin Patch`ninvalid`n*** End Patch" }
        }
    )
    Assert-Deny "file guard fails closed on invalid patch target" $result
    $missingFileUtilsRoot = Join-Path $fixtureRoot "missing-file-utils"
    New-Item -ItemType Directory -Path $missingFileUtilsRoot -Force | Out-Null
    $isolatedFileGuard = Join-Path $missingFileUtilsRoot "agent-hook-file-guard.ps1"
    Copy-Item -LiteralPath (Join-Path $hooks "agent-hook-file-guard.ps1") `
        -Destination $isolatedFileGuard
    $result = Invoke-Hook $isolatedFileGuard (
        New-Event @{ tool_name = "apply_patch"; tool_input = @{ path = "docs/safe.md" } }
    )
    Assert-Deny "file guard fails closed when utils are absent" $result
    $oversizedFileEvent = (
        '{"tool_name":"apply_patch","tool_input":{"path":"docs/safe.md","padding":"' +
        ("x" * 300000) +
        '"}}'
    )
    $result = Invoke-Hook "agent-hook-file-guard.ps1" $oversizedFileEvent
    Assert-Deny "file guard rejects oversized raw hook input before JSON traversal" $result
    $secretPath = "fixture/.env"
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{ tool_name = "apply_patch"; tool_input = @{ path = $secretPath } })
    Assert-Deny "file guard denies env file" $result
    foreach ($ambiguousProtectedPath in @(
        "fixture/.env.",
        "fixture/.env ",
        "fixture/.env:stream",
        "fixture/.git./config",
        "fixture/.git /config",
        "fixture/.git/config:stream"
    )) {
        $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{
            tool_name = "apply_patch"
            tool_input = @{ path = $ambiguousProtectedPath }
        })
        Assert-Deny ("file guard denies ambiguous Windows protected path: " + $ambiguousProtectedPath) $result
    }
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{ tool_name = "apply_patch"; tool_input = @{ path = "keys/id_ed25519.pub" } })
    Assert-NoDecision "file guard allows SSH public key" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{ tool_name = "apply_patch"; tool_input = @{ path = "docs/secret_sauce.md" } })
    Assert-NoDecision "file guard allows documentation example" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{
        tool_name = "Write"
        tool_input = @{
            file_path = "docs/safe-example.md"
            content = "Example only:`n*** Add File: .env`nDo not commit secrets."
        }
    })
    Assert-NoDecision "file guard does not parse ordinary Write content as a patch" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{
        tool_name = "apply_patch"
        tool_input = @{ patch = "*** Begin Patch`n*** Add File: .env`n+TOKEN=fixture`n*** End Patch" }
    })
    Assert-Deny "file guard still parses apply_patch patch fields" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{
        tool_name = "apply_patch"
        tool_input = @{ command = "*** Begin Patch`n*** Add File: docs/safe.md`n+safe`n*** End Patch" }
    })
    Assert-NoDecision "file guard allows safe command-shaped apply_patch payload" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{
        tool_name = "apply_patch"
        tool_input = @{ command = "*** Begin Patch`n*** Add File: .env`n+TOKEN=fixture`n*** End Patch" }
    })
    Assert-Deny "file guard denies protected command-shaped apply_patch payload" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event $unknownParallel)
    Assert-Deny "file guard fails closed on unknown nested wrapper" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{ tool_name = "functions.shell_command"; tool_input = @{ command = "git status" } })
    Assert-NoDecision "file guard ignores named non-file tool" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (
        New-Event @{ tool_name = "Read"; tool_input = @{ path = "fixture/.env" } }
    )
    Assert-NoDecision "file guard ignores read-only protected path" $result

    $auditSecretMarker = "SECRET_MARKER_7e91"
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{
        tool_name = "PowerShell"
        tool_input = @{ command = ("git --opaque=" + $auditSecretMarker + " status") }
    })
    Assert-Deny "command guard fails closed on unknown Git global options" $result
    Assert-True "command guard deny JSON omits unknown Git option contents" (
        $result.Output -notmatch [regex]::Escape($auditSecretMarker)
    ) $result.Output

    $audit = if (Test-Path -LiteralPath $auditPath) { [IO.File]::ReadAllText($auditPath, [Text.Encoding]::UTF8) } else { "" }
    Assert-True "guard audit records input hashes" ($audit -match "input_sha256=[a-f0-9]{64}")
    Assert-True "guard audit omits raw command" ($audit -notmatch [regex]::Escape($dangerText))
    Assert-True "guard audit omits raw path" ($audit -notmatch [regex]::Escape($secretPath))
    Assert-True "guard audit omits unknown Git option contents" (
        $audit -notmatch [regex]::Escape($auditSecretMarker)
    ) $audit

    $utilsEvidence = @(
        "command guard checks every shell statement",
        "command guard checks commands after and separator",
        "command guard checks commands after or separator",
        "command guard checks commands after newline",
        "command guard does not combine quoted rm text with later flags",
        "command guard recursively denies nested danger",
        "command guard allows safe nested input schema",
        "command guard denies dangerous nested input schema",
        "command guard denies nested GNU rm long flags",
        "command guard denies nested worktree restore",
        "command guard fails closed on unknown nested wrapper",
        "command guard rejects oversized raw hook input before JSON traversal",
        "command guard bounds nested hook tree depth before extraction",
        "command guard bounds parallel hook collection width",
        "command guard fails closed on unknown Git global options",
        "command guard deny JSON omits unknown Git option contents",
        "guard audit records input hashes",
        "guard audit omits raw command",
        "guard audit omits raw path",
        "guard audit omits unknown Git option contents"
    )
    foreach ($quotedDanger in $quotedDangerCases) {
        $utilsEvidence += "command guard denies quoted or wrapped danger: " + $quotedDanger
    }
    foreach ($gitPagerDanger in $gitPagerDangerCases) {
        $utilsEvidence += "command guard locates subcommand after no-value Git option: " + $gitPagerDanger
    }
    foreach ($safeGitText in $safeQuotedGitText) {
        $utilsEvidence += "command guard allows quoted Git documentation text: " + $safeGitText
    }
    foreach ($safeGitGlobal in $safeGitGlobalCases) {
        $utilsEvidence += "command guard allows safe Git global option: " + $safeGitGlobal
    }
    foreach ($combinedForcePush in $combinedForcePushCases) {
        $utilsEvidence += "command guard denies combined short force option: " + $combinedForcePush
    }
    foreach ($backtickEscapeDanger in $backtickEscapeDangerCases) {
        $utilsEvidence += (
            "command guard fails closed on executable PowerShell backtick escape: " +
            $backtickEscapeDanger
        )
    }
    $utilsEvidence += "command guard allows a literal backtick inside single-quoted data"
    $utilsEvidence += "command guard denies mirror push"
    $utilsEvidence += "command guard fails closed on unknown force-like push option"
    foreach ($normalizedDanger in $normalizedDangerCases) {
        $utilsEvidence += "command guard normalizes and denies dangerous command: " + $normalizedDanger
    }
    foreach ($normalizedSafe in $normalizedSafeCases) {
        $utilsEvidence += "command guard allows safe query or quoted prose: " + $normalizedSafe
    }
    foreach ($transparentWrapperDanger in $transparentWrapperDangerCases) {
        $utilsEvidence += "command guard denies danger behind transparent wrappers: " + $transparentWrapperDanger
    }
    foreach ($transparentWrapperSafe in $transparentWrapperSafeCases) {
        $utilsEvidence += "command guard preserves safe transparent wrapper use: " + $transparentWrapperSafe
    }
    foreach ($checkpointAllEnabled in $checkpointAllEnabledCases) {
        $utilsEvidence += (
            "command guard denies enabled checkpoint blanket staging switch: " +
            $checkpointAllEnabled
        )
    }
    foreach ($checkpointAllDisabled in $checkpointAllDisabledCases) {
        $utilsEvidence += (
            "command guard allows disabled checkpoint blanket staging switch: " +
            $checkpointAllDisabled
        )
    }
    $wrapperNormalizationEvidence = @()
    foreach ($wrapperNormalizationDanger in $wrapperNormalizationDangerCases) {
        $wrapperNormalizationEvidence += "command guard normalizes compact or prefixed wrapper danger: " + $wrapperNormalizationDanger
    }
    foreach ($wrapperNormalizationSafe in $wrapperNormalizationSafeCases) {
        $wrapperNormalizationEvidence += "command guard preserves safe compact or prefixed wrapper use: " + $wrapperNormalizationSafe
    }
    $utilsEvidence += $wrapperNormalizationEvidence
    $utilsEvidence += "command guard bounds transparent wrapper recursion"
    $utilsEvidence += "command guard bounds transparent wrapper command length"
    Write-SemanticPass "hooks.utils-parser-wrapper-privacy-git-options" $utilsEvidence
    Write-SemanticPass "hooks.command-guard-wrapper-normalization" $wrapperNormalizationEvidence
    Write-SemanticPass "hooks.command-guard-bounded-input-tree" @(
        "command guard rejects oversized raw hook input before JSON traversal",
        "command guard bounds nested hook tree depth before extraction",
        "command guard bounds parallel hook collection width",
        'command guard denies danger behind transparent wrappers: sh -lc "git reset --hard HEAD"',
        'command guard denies danger behind transparent wrappers: powershell.exe -Com "git reset --hard HEAD"',
        'command guard denies danger behind transparent wrappers: cmd.exe /k "git reset --hard HEAD"'
    )
    $fileGuardEvidence = @(
        "file guard fails closed on empty input",
        "file guard fails closed on malformed JSON",
        "file guard rejects oversized raw hook input before JSON traversal",
        "file guard denies env file",
        "file guard allows SSH public key",
        "file guard allows documentation example",
        "file guard does not parse ordinary Write content as a patch",
        "file guard still parses apply_patch patch fields",
        "file guard fails closed on unknown nested wrapper",
        "file guard ignores named non-file tool"
    )
    foreach ($ambiguousProtectedPath in @(
        "fixture/.env.",
        "fixture/.env ",
        "fixture/.env:stream",
        "fixture/.git./config",
        "fixture/.git /config",
        "fixture/.git/config:stream"
    )) {
        $fileGuardEvidence += "file guard denies ambiguous Windows protected path: " + $ambiguousProtectedPath
    }
    Write-SemanticPass "hooks.file-guard-nested-protected-failclosed" $fileGuardEvidence
    Write-SemanticPass "context.caveman-lite" @(
        "SessionStart emits compact Codex context",
        "startup reports Caveman lite exactly once",
        "local Caveman config can disable mode"
    )
    Write-SemanticPass "context.lessons-title-only" @(
        "startup injects lesson titles",
        "fixture lesson title is injected",
        "lesson body is not injected",
        "placeholder lesson title is excluded"
    )
    Write-SemanticPass "context.review-90-day" @(
        "fresh install without review marker suppresses due notice",
        "90-day install baseline without marker emits due notice",
        "current review marker suppresses due notice",
        "89-day review marker suppresses due notice",
        "90-day review marker emits due notice",
        "invalid review marker fails safe"
    )
    Write-SemanticPass "context.state-restore" @(
        "compact restores PROJECT_STATE",
        "resume restores .agent state"
    )

    $scopeManifestPath = Join-Path $repoRoot "manifests\local-postimage-equivalence.json"
    $scopeManifest = [IO.File]::ReadAllText(
        $scopeManifestPath,
        [Text.Encoding]::UTF8
    ) | ConvertFrom-Json -DateKind String
    $scopeEntry = @($scopeManifest.entries | Where-Object {
        [string]$_.payload -ceq "06-agent-hook-smoke-test.ps1"
    })
    $scopeValid = (
        $scopeEntry.Count -eq 1 -and
        $null -ne $scopeEntry[0].scopeContract -and
        [string]$scopeEntry[0].scopeContract.assertionProjectionKind -ceq
            "ordered-name-to-public-evidence-cases-v1"
    )
    Assert-True "retained Hook evidence contract has one supported projection" $scopeValid

    if ($scopeValid) {
        $scope = $scopeEntry[0].scopeContract
        $retainedMappings = @($scope.retainedAssertions)
        $mappingNames = @($retainedMappings | ForEach-Object { [string]$_.name })
        $uniqueMappingNames = @($mappingNames | Sort-Object -Unique)
        $nameProjection = $mappingNames -join "`n"
        $bindingRows = @($retainedMappings | ForEach-Object {
            $evidenceCases = @($_.evidenceCases | ForEach-Object { [string]$_ })
            ([string]$_.name) + "`t" + ($evidenceCases -join ([char]0x1F))
        })
        $bindingProjection = $bindingRows -join "`n"
        $mappingShapeValid = (
            $retainedMappings.Count -eq [int]$scope.retainedAssertionCount -and
            $mappingNames.Count -eq $uniqueMappingNames.Count -and
            (Get-Sha256Text $nameProjection) -ceq
                [string]$scope.retainedAssertionProjectionSha256 -and
            (Get-Sha256Text $bindingProjection) -ceq
                [string]$scope.retainedEvidenceProjectionSha256
        )
        Assert-True "retained Hook evidence projection matches frozen count and digests" `
            $mappingShapeValid

        $missingEvidence = New-Object Collections.Generic.List[string]
        $failedEvidence = New-Object Collections.Generic.List[string]
        foreach ($mapping in $retainedMappings) {
            $cases = @($mapping.evidenceCases | ForEach-Object { [string]$_ })
            if ($cases.Count -eq 0) {
                $missingEvidence.Add(([string]$mapping.name + "=>NO_CASES"))
                continue
            }
            foreach ($caseName in $cases) {
                if (-not $script:ResultRegistry.ContainsKey($caseName)) {
                    $missingEvidence.Add(([string]$mapping.name + "=>" + $caseName))
                }
                elseif (-not $script:ResultRegistry[$caseName]) {
                    $failedEvidence.Add(([string]$mapping.name + "=>" + $caseName))
                }
            }
        }
        $runtimeBindingValid = (
            $missingEvidence.Count -eq 0 -and
            $failedEvidence.Count -eq 0
        )
        Assert-True "all retained Hook assertions bind to passing public evidence" `
            $runtimeBindingValid `
            ("missing={0}; failed={1}" -f
                ($missingEvidence -join ","),
                ($failedEvidence -join ","))
        if ($mappingShapeValid -and $runtimeBindingValid) {
            Write-Host (
                (
                    "CASESET PASS hooks.codex-active-retained-assertions " +
                    "count={0} sha256={1} binding_sha256={2}"
                ) -f
                    $retainedMappings.Count,
                    (Get-Sha256Text $nameProjection),
                    (Get-Sha256Text $bindingProjection)
            )
        }
    }

    if ($script:Failed -eq 0) {
        Write-Host "SEMANTIC PASS hooks.codex-active-suite-executed"
    }
    Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

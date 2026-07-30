[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$hooks = Join-Path $repoRoot "tools\hooks"
$script:Passed = 0
$script:Failed = 0
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("steadyagent-v2-hooks-" + [guid]::NewGuid().ToString("N"))
$auditPath = Join-Path $fixtureRoot "guard-audit.log"

function New-Event {
    param([hashtable]$Value)
    return ($Value | ConvertTo-Json -Compress -Depth 12)
}

function Invoke-Hook {
    param([string]$Name, [string]$InputText, [string[]]$Arguments = @())
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"" + (Join-Path $hooks $Name) + "`""
    foreach ($argument in $Arguments) {
        $psi.Arguments += " `"" + ([string]$argument).Replace('"', '\"') + "`""
    }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    try { $psi.StandardErrorEncoding = [Text.Encoding]::UTF8 } catch { }
    $psi.EnvironmentVariables["STEADYAGENT_GUARD_AUDIT_LOG"] = $auditPath
    $process = [Diagnostics.Process]::Start($psi)
    if ($InputText) { $process.StandardInput.Write($InputText) }
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout; Error = $stderr }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        $script:Passed++
        Write-Host ("PASS " + $Name)
    }
    else {
        $script:Failed++
        Write-Host ("FAIL " + $Name + $(if ($Detail) { " - " + $Detail } else { "" }))
    }
}

function Assert-Deny {
    param([string]$Name, [object]$Result)
    $ok = $false
    try {
        $json = $Result.Output | ConvertFrom-Json
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

    $result = Invoke-Hook "agent-hook-context.ps1" (New-Event @{ source = "startup"; cwd = $fixtureRoot })
    Assert-True "SessionStart emits compact Codex context" ($result.ExitCode -eq 0 -and -not $result.Error -and $result.Output -match "SteadyAgent Codex")
    Assert-True "startup reports Caveman lite once" ($result.Output -match "Caveman startup status report: ON, mode lite")
    Assert-True "startup injects lesson titles" ($result.Output -match "Known pitfalls to avoid" -and $result.Output -match "PowerShell 5.1 encoding")
    Assert-True "startup reports overdue Harness review" ($result.Output -match "HARNESS-REVIEW DUE")
    Assert-True "startup does not inject stale state" ($result.Output -notmatch "TASK STATE")

    $reviewedHome = Join-Path $fixtureRoot "reviewed-home"
    New-Item -ItemType Directory -Path (Join-Path $reviewedHome "rules"), (Join-Path $reviewedHome "config") -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $reviewedHome "rules\lessons.md"), "### Fixture lesson", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $reviewedHome ".harness-last-review"), (Get-Date).ToString("yyyy-MM-dd"), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $reviewedHome "config\caveman.json"), '{"defaultMode":"off"}', [Text.Encoding]::UTF8)
    $result = Invoke-Hook "agent-hook-context.ps1" `
        (New-Event @{ source = "startup"; cwd = $fixtureRoot }) `
        @("-SteadyAgentHome", $reviewedHome)
    Assert-True "current review marker suppresses due notice" ($result.Output -notmatch "HARNESS-REVIEW DUE")
    Assert-True "local Caveman config can disable mode" ($result.Output -match "Caveman startup status report: OFF, mode off")
    Assert-True "fixture lesson title is injected" ($result.Output -match "Fixture lesson")
    $result = Invoke-Hook "agent-hook-context.ps1" (New-Event @{ source = "compact"; cwd = $stateRoot })
    Assert-True "compact restores PROJECT_STATE" ($result.Output -match "SMOKE_PROJECT_STATE")
    $result = Invoke-Hook "agent-hook-context.ps1" (New-Event @{ source = "resume"; cwd = $agentStateRoot })
    Assert-True "resume restores .agent state" ($result.Output -match "SMOKE_AGENT_STATE")

    $result = Invoke-Hook "agent-hook-precompact.ps1" ""
    Assert-True "PreCompact emits supported systemMessage" ($result.ExitCode -eq 0 -and -not $result.Error -and $result.Output -match "systemMessage")

    $result = Invoke-Hook "agent-hook-command-guard.ps1" ""
    Assert-Deny "command guard fails closed on empty input" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" "{bad"
    Assert-Deny "command guard fails closed on malformed JSON" $result
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "git status" } })
    Assert-NoDecision "command guard allows safe command" $result
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
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "PowerShell"; tool_input = @{ command = "del -Recurse build" } })
    Assert-Deny "command guard denies recursive del alias" $result
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
    $result = Invoke-Hook "agent-hook-command-guard.ps1" (New-Event @{ tool_name = "apply_patch"; tool_input = @{ patch = "*** Begin Patch`n*** End Patch" } })
    Assert-NoDecision "command guard ignores named non-shell tool" $result

    $result = Invoke-Hook "agent-hook-file-guard.ps1" ""
    Assert-Deny "file guard fails closed on empty input" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" "{bad"
    Assert-Deny "file guard fails closed on malformed JSON" $result
    $secretPath = "fixture/.env"
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{ tool_name = "apply_patch"; tool_input = @{ path = $secretPath } })
    Assert-Deny "file guard denies env file" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{ tool_name = "apply_patch"; tool_input = @{ path = "keys/id_ed25519.pub" } })
    Assert-NoDecision "file guard allows SSH public key" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{ tool_name = "apply_patch"; tool_input = @{ path = "docs/secret_sauce.md" } })
    Assert-NoDecision "file guard allows documentation example" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event $unknownParallel)
    Assert-Deny "file guard fails closed on unknown nested wrapper" $result
    $result = Invoke-Hook "agent-hook-file-guard.ps1" (New-Event @{ tool_name = "functions.shell_command"; tool_input = @{ command = "git status" } })
    Assert-NoDecision "file guard ignores named non-file tool" $result

    $audit = if (Test-Path -LiteralPath $auditPath) { [IO.File]::ReadAllText($auditPath, [Text.Encoding]::UTF8) } else { "" }
    Assert-True "guard audit records input hashes" ($audit -match "input_sha256=[a-f0-9]{64}")
    Assert-True "guard audit omits raw command" ($audit -notmatch [regex]::Escape($dangerText))
    Assert-True "guard audit omits raw path" ($audit -notmatch [regex]::Escape($secretPath))

    Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

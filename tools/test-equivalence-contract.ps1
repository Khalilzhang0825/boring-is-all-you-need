[CmdletBinding()]
param(
    [switch]$InternalVerify,
    [string]$InjectPolicyDrift = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:Passed = 0
$script:Failed = 0
$policyIds = @(
    "policy.review-risk-trigger",
    "policy.skill-explicit-lightweight",
    "policy.workflow-sequence",
    "policy.safety-authority-live-boundary",
    "policy.guide-runtime-recovery-evidence",
    "policy.periodic-maintenance-marker"
)

function Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        $script:Passed++
        Write-Host ("PASS " + $Name)
    }
    else {
        $script:Failed++
        Write-Host ("FAIL " + $Name)
    }
}

function Check-Policy {
    param([string]$Id, [bool]$Condition)
    Check -Name $Id -Condition $Condition
    if ($Condition) {
        Write-Host ("SEMANTIC PASS " + $Id)
    }
}

function Read-PublicText {
    param([string]$Relative)
    return [IO.File]::ReadAllText((Join-Path $root $Relative), [Text.Encoding]::UTF8)
}

function Replace-RequiredText {
    param([string]$Text, [string]$Before, [string]$After, [string]$Id)
    if ($Text.IndexOf($Before, [StringComparison]::Ordinal) -lt 0) {
        throw ("Policy drift seam not found for " + $Id)
    }
    return $Text.Replace($Before, $After)
}

function Inject-PolicyDrift {
    param([hashtable]$Texts, [string]$Id)
    switch ($Id) {
        "policy.review-risk-trigger" {
            $Texts["review"] = Replace-RequiredText $Texts["review"] `
                "File count alone is not a trigger." `
                "File count alone is always a trigger." `
                $Id
        }
        "policy.skill-explicit-lightweight" {
            $Texts["skills"] = Replace-RequiredText $Texts["skills"] `
                "require explicit user invocation" `
                "permit automatic invocation" `
                $Id
        }
        "policy.workflow-sequence" {
            $Texts["workflow"] = Replace-RequiredText $Texts["workflow"] `
                "understand -> plan -> red check -> smallest change -> green check -> risk gate -> independent review when required, otherwise self-review -> checkpoint" `
                "understand -> plan -> red check -> smallest change -> green check -> always delegate review -> checkpoint" `
                $Id
        }
        "policy.safety-authority-live-boundary" {
            $Texts["safety"] = Replace-RequiredText $Texts["safety"] `
                "Explicit authorization is required before push, publish, deploy, dependency installation, migration, bulk rename/delete, or external writes." `
                "External writes may proceed without explicit authorization." `
                $Id
        }
        "policy.guide-runtime-recovery-evidence" {
            $Texts["guide"] = Replace-RequiredText $Texts["guide"] `
                "They do not prove that a Codex" `
                "They prove that a Codex" `
                $Id
        }
        "policy.periodic-maintenance-marker" {
            $Texts["maintenance"] = Replace-RequiredText $Texts["maintenance"] `
                '$SteadyAgentRoot' `
                '$HOME\.steadyagent-broken' `
                $Id
        }
        default {
            throw ("Unknown policy drift id: " + $Id)
        }
    }
}

function Invoke-InternalVerification {
    param([string]$DriftId = "")
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"" + $PSCommandPath + "`" -InternalVerify"
    if ($DriftId) {
        $psi.Arguments += " -InjectPolicyDrift `"" + $DriftId + "`""
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    try { $psi.StandardErrorEncoding = [Text.Encoding]::UTF8 } catch { }
    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $stdout
        Error = $stderr
    }
}

if ($InjectPolicyDrift -and -not $InternalVerify) {
    Write-Host "FAIL InjectPolicyDrift requires -InternalVerify test mode"
    exit 2
}
if ($InternalVerify -and $InjectPolicyDrift -and $policyIds -notcontains $InjectPolicyDrift) {
    Write-Host ("FAIL unknown policy drift id: " + $InjectPolicyDrift)
    exit 2
}

if (-not $InternalVerify) {
    $normal = Invoke-InternalVerification
    $normalLines = @($normal.Output -split "\r?\n" | Where-Object { $_ })
    $normalMarkers = @($normalLines | Where-Object { $_ -match "^SEMANTIC PASS " })
    $normalOk = ($normal.ExitCode -eq 0 -and -not $normal.Error)
    foreach ($id in $policyIds) {
        $normalOk = $normalOk -and (@($normalMarkers | Where-Object { $_ -eq ("SEMANTIC PASS " + $id) }).Count -eq 1)
    }
    if (-not $normalOk) {
        Write-Host "FAIL normal policy verification"
        if ($normal.Output) { Write-Host -NoNewline $normal.Output }
        if ($normal.Error) { Write-Host -NoNewline $normal.Error }
        exit 1
    }
    Write-Host -NoNewline $normal.Output

    $mutationPassed = 0
    $mutationFailed = 0
    foreach ($id in $policyIds) {
        $mutated = Invoke-InternalVerification -DriftId $id
        $mutatedLines = @($mutated.Output -split "\r?\n" | Where-Object { $_ })
        $failLines = @($mutatedLines | Where-Object { $_ -match "^FAIL " })
        $semanticLine = "SEMANTIC PASS " + $id
        $red = (
            $mutated.ExitCode -eq 1 -and
            -not $mutated.Error -and
            $failLines.Count -eq 1 -and
            $failLines[0] -eq ("FAIL " + $id) -and
            $mutatedLines -notcontains $semanticLine -and
            @($mutatedLines | Where-Object { $_ -match "^RESULT pass=[0-9]+ fail=1$" }).Count -eq 1
        )
        if ($red) {
            $mutationPassed++
            Write-Host ("PASS policy mutation turns check red: " + $id)
        }
        else {
            $mutationFailed++
            Write-Host ("FAIL policy mutation did not isolate check: " + $id)
            if ($mutated.Output) { Write-Host -NoNewline $mutated.Output }
            if ($mutated.Error) { Write-Host -NoNewline $mutated.Error }
        }
    }
    Write-Host ("MUTATION RESULT pass={0} fail={1}" -f $mutationPassed, $mutationFailed)
    if ($mutationFailed -gt 0) { exit 1 }
    exit 0
}

$policyTexts = @{
    maintenance = Read-PublicText "rules\harness-review.md"
    review = Read-PublicText "rules\review-gates.md"
    skills = Read-PublicText "rules\skill-routing.md"
    workflow = Read-PublicText "rules\workflow-routing.md"
    safety = Read-PublicText "rules\safety-boundaries.md"
    guide = Read-PublicText "rules\HARNESS-GUIDE.md"
}
if ($InjectPolicyDrift) {
    Inject-PolicyDrift -Texts $policyTexts -Id $InjectPolicyDrift
}

$requirements = Read-PublicText "templates\codex\requirements.managed-hooks.example.toml"
Check "managed runtime has exactly three blocks and one unified PreToolUse" (
    ([regex]::Matches($requirements, '(?m)^\[\[hooks[.][A-Za-z]+[.]hooks\]\]$')).Count -eq 3 -and
    ([regex]::Matches($requirements, '(?m)^\[\[hooks[.]PreToolUse\]\]$')).Count -eq 1 -and
    $requirements -match [regex]::Escape('functions[.]shell_command') -and
    $requirements -match [regex]::Escape('functions[.]apply_patch') -and
    $requirements -match [regex]::Escape('multi_tool_use[.]parallel') -and
    $requirements -match 'agent-hook-command-guard[.]ps1\\" -GuardMode Unified'
)
Check "managed runtime remains Codex-only and lightweight" (
    $requirements -notmatch "Claude|UserPromptSubmit|PermissionRequest|PostToolUse"
)

$context = Read-PublicText "tools\hooks\agent-hook-context.ps1"
$hookTests = Read-PublicText "tools\test-agent-hooks.ps1"
$agents = Read-PublicText "templates\codex\AGENTS.md"
$rulesIndex = Read-PublicText "rules\README.md"
Check "SessionStart retains Caveman lite startup behavior" (
    $context -match "Caveman startup status report" -and
    $context -match 'mode = "lite"' -and
    $context -match "first assistant response" -and
    $agents -match "Caveman.*lite"
)
Check "SessionStart retains lessons title injection" (
    $context -match "Known pitfalls to avoid" -and
    $context -match "lessons[.]md" -and
    (Read-PublicText "rules\lessons.md") -match "PowerShell 5[.]1 encoding"
)
Check "SessionStart retains periodic review reminder" (
    $context -match "HARNESS-REVIEW DUE" -and
    $context -match "[.]harness-last-review" -and
    $context -match "yyyy-MM-dd"
)
Check "Hook suite asserts Caveman lessons and review behavior" (
    $hookTests -match "startup reports Caveman lite exactly once" -and
    $hookTests -match "startup injects lesson titles" -and
    $hookTests -match "current review marker suppresses due notice" -and
    $hookTests -match "89-day review marker suppresses due notice" -and
    $hookTests -match "90-day review marker emits due notice" -and
    $hookTests -match "invalid review marker fails safe"
)

$diagnose = Read-PublicText "tools\diagnose-install.ps1"
Check "diagnosis keeps file evidence below Live acceptance" (
    $diagnose -match "RequireRuntimeCatalog" -and
    $diagnose -match "Test-RolloutFileCatalogSnapshot" -and
    $diagnose -match "completed_utc" -and
    $diagnose -match "rollout-file-confirmed" -and
    $diagnose -match "manual Codex Live acceptance is still required" -and
    $diagnose -match "Assert-CatalogSessionStartedAfterReceipt" -and
    $diagnose -notmatch "CreationTimeUtc" -and
    $diagnose -notmatch "runtime-confirmed"
)
Check "diagnosis checks Caveman and review skill contracts" (
    $diagnose -match "Caveman lite startup contract" -and
    $diagnose -match "review, skill, and periodic maintenance contracts"
)
Check "diagnosis checks Git identity on request" (
    $diagnose -match "RequireGitIdentity" -and
    $diagnose -match "Git user[.]name is configured" -and
    $diagnose -match "Git user[.]email is configured"
)

$runtimeSlice = Read-PublicText "tools\validate-runtime-slice.ps1"
$releaseReadiness = Read-PublicText "tools\validate-release-readiness.ps1"
$localEquivalence = Read-PublicText "tools\test-local-equivalence.ps1"
Check "release readiness executes the Hook behavior suite only once" (
    $runtimeSlice -match 'SkipHookBehaviorSuite' -and
    $releaseReadiness -match 'Codex runtime slice passes.*SkipHookBehaviorSuite' -and
    $releaseReadiness -match 'release gate owns exactly one installed Hook suite invocation' -and
    $localEquivalence -match 'Hook invocation ledger reports exactly one authoritative suite run' -and
    $localEquivalence -match 'installedHookSuite' -and
    $localEquivalence -notmatch 'STEADYAGENT_HOOK_RETAINED_EVIDENCE_DROP' -and
    (Read-PublicText "tools\test-v2-migration.ps1") -match '(?s)Invoke-StrictDiagnosisFixture.*?-ThreadId \$strictThreadId.*?-SkipSmoke'
)

$readmeEnglish = Read-PublicText "README.md"
$readmeChinese = Read-PublicText "README.zh-CN.md"
Check "strict post-install audit is explicitly bound to a new Codex task" (
    $readmeEnglish -match 'new Codex task' -and
    $readmeEnglish -match ([regex]::Escape('-ThreadId $env:CODEX_THREAD_ID')) -and
    $readmeChinese -match '\u65B0\u7684 Codex \u4EFB\u52A1' -and
    $readmeChinese -match ([regex]::Escape('-ThreadId $env:CODEX_THREAD_ID'))
)
$strictAuditDocuments = @(
    "docs\getting-started.md",
    "docs\getting-started.zh-CN.md",
    "docs\activation-guide.md",
    "docs\activation-guide.zh-CN.md",
    "docs\feature-map.md",
    "docs\feature-map.zh-CN.md",
    "docs\tools.md",
    "docs\tools.zh-CN.md",
    "docs\release-checklist.md",
    "docs\release-checklist.zh-CN.md"
)
foreach ($strictAuditDocument in $strictAuditDocuments) {
    $strictAuditText = Read-PublicText $strictAuditDocument
    Check ("strict post-install audit contract: " + $strictAuditDocument) (
        $strictAuditText -match 'CODEX_THREAD_ID' -and
        $strictAuditText -match 'skill-index[.]ps1' -and
        $strictAuditText -match 'RequireInstalledBytes' -and
        $strictAuditText -match 'RequireHooksActive' -and
        $strictAuditText -match 'RequireRuntimeCatalog' -and
        $strictAuditText -match 'RequireGitIdentity'
    )
}
$toolsEnglish = Read-PublicText "docs\tools.md"
$toolsChinese = Read-PublicText "docs\tools.zh-CN.md"
Check "local equivalence docs retain the authoritative 23 mapped plus 30 support closure" (
    $toolsEnglish -match '23 mapped plus 30 support.*53' -and
    $toolsChinese -match '23.*30.*53' -and
    $toolsEnglish -match '27 removals.*80' -and
    $toolsChinese -match '27.*80' -and
    $toolsEnglish -notmatch '23 mapped plus 29 support' -and
    $toolsChinese -notmatch '23.*29'
)

$maintenance = $policyTexts["maintenance"]
foreach ($clause in @(
    "three to six months",
    "lessons inbox",
    "180 days",
    "MCP allowlists",
    "model and effort settings",
    ".harness-last-review",
    "RequireRuntimeCatalog",
    "RequireGitIdentity"
)) {
    Check ("periodic maintenance retains clause: " + $clause) (
        $maintenance.IndexOf($clause, [StringComparison]::OrdinalIgnoreCase) -ge 0
    )
}

$review = $policyTexts["review"]
$skills = $policyTexts["skills"]
$workflow = $policyTexts["workflow"]
$safety = $policyTexts["safety"]
$guide = $policyTexts["guide"]
Check "maintenance cold strict block binds task catalog before diagnosis" (
    $maintenance -match '(?s)```powershell.*?CODEX_THREAD_ID.*?skill-index[.]ps1.*?-ThreadId \$env:CODEX_THREAD_ID.*?diagnose-install[.]ps1.*?RequireRuntimeCatalog'
)
Check-Policy "policy.review-risk-trigger" (
    $review -match [regex]::Escape("Use independent fresh-context review for material risk, not ceremony.") -and
    $review -match [regex]::Escape("File count alone is not a trigger.") -and
    $review -match "explicitly requests it" -and
    $review -match "safety hooks" -and
    $review -match "A required review cannot be replaced by implementer self-review"
)
Check-Policy "policy.skill-explicit-lightweight" (
    $skills -match [regex]::Escape("Ordinary tasks do not search the entire installed skill inventory.") -and
    $skills -match "workflow expansion require explicit user invocation" -and
    $skills -match "do not start them automatically" -and
    $skills -match "Never claim that scanning disk proves a skill is visible" -and
    $agents -match [regex]::Escape("rules\README.md") -and
    $rulesIndex -match [regex]::Escape("skill-routing.md") -and
    $skills -match 'Read-Host.*task or intent' -and
    $skills -match 'Join-Path \$HOME "[.]steadyagent"' -and
    $skills -match '& \$SkillSearch -Query \$SkillQuery' -and
    $skills -notmatch 'STEADYAGENT_HOME' -and
    $skills -notmatch '[<]user intent[>]' -and
    $skills -match 'returned absolute `SKILL[.]md` path' -and
    $skills -match "no current-task-visible skill was proven" -and
    $skills -match "Do not silently use an unadvertised disk entry"
)
$activationGuide = Read-PublicText "docs\activation-guide.md"
$activationGuideZh = Read-PublicText "docs\activation-guide.zh-CN.md"
Check "Live acceptance guide provides executable disposable probes" (
    $activationGuide -match "steadyagent-live-" -and
    $activationGuide -match "STEADYAGENT_LIVE_SENTINEL" -and
    $activationGuide -match "git reset --hard HEAD\^" -and
    $activationGuide -match '[$]LiveEvidencePath' -and
    $activationGuide -match "git add .*review-target[.]md" -and
    $activationGuide -match "git diff --name-only -- review-target[.]md" -and
    $activationGuide -match "git restore -- review-target[.]md" -and
    $activationGuide -notmatch "LIVE_ACCEPTANCE[.]md" -and
    $activationGuideZh -match "steadyagent-live-" -and
    $activationGuideZh -match "SYNTHETIC_ONLY_DO_NOT_USE" -and
    $activationGuideZh -match '[$]LiveEvidencePath' -and
    $activationGuideZh -match "git add .*review-target[.]md" -and
    $activationGuideZh -match "git diff --name-only -- review-target[.]md" -and
    $activationGuideZh -match "git restore -- review-target[.]md" -and
    $activationGuideZh -notmatch "LIVE_ACCEPTANCE[.]md"
)
Check-Policy "policy.workflow-sequence" (
    $workflow -match [regex]::Escape("understand -> plan -> red check -> smallest change -> green check -> risk gate -> independent review when required, otherwise self-review -> checkpoint") -and
    $workflow -match "diagnose before editing" -and
    $workflow -match "reproduce the behavior or find observable evidence before changing code" -and
    $workflow -match "final diff only contains files needed for the task"
)
Check-Policy "policy.safety-authority-live-boundary" (
    $safety -match [regex]::Escape("Never run destructive Git or broad deletion commands by default.") -and
    $safety -match [regex]::Escape("Explicit authorization is required before push, publish, deploy, dependency installation, migration, bulk rename/delete, or external writes.") -and
    $safety -match "not an adversarial sandbox" -and
    $safety -match "Unknown matched payloads and unknown nested parallel wrappers pass without a deny decision in the standard managed Audit mode" -and
    $safety -match "never raw commands, patches, file content, or complete target paths"
)
Check-Policy "policy.guide-runtime-recovery-evidence" (
    $guide -match "runtime\s+reference, not proof that a particular Codex Desktop process has reloaded" -and
    $guide -match "explicit fixture mode and never becomes Live evidence" -and
    $guide -match 'Production output is labeled `rollout-file-confirmed`' -and
    $guide -match "Repository tests, fixture tests, and strict diagnosis prove package,\s+configuration, and rollout-file consistency[.] They do not prove that a Codex" -and
    $guide -match "Only behavior observed\s+in a real post-restart Codex task can establish that Live fact" -and
    $guide -match "Before compaction, write objective, decisions, progress, next step, remaining" -and
    $guide -match "After compaction, treat the summary as a cache and restore" -and
    $guide -match "Installer and rollback operations are dry-run by default" -and
    $guide -match "transaction\s+receipt"
)
Check-Policy "policy.periodic-maintenance-marker" (
    $maintenance -match 'Let `SteadyAgentRoot` mean the production installation root' -and
    ([regex]::Matches($maintenance, 'Join-Path \$SteadyAgentRoot "[.]harness-last-review"')).Count -eq 2 -and
    $maintenance -match "current UTC date" -and
    $maintenance -match "yyyy-MM-dd" -and
    $maintenance -match 'Production installation does not accept a\s+custom root' -and
    $maintenance -match "three to six months"
)

$catalogResolver = Read-PublicText "tools\skill-catalog-resolver.ps1"
$catalogIndex = Read-PublicText "tools\skill-index.ps1"
$catalogSearch = Read-PublicText "tools\skill-search.ps1"
$catalogTests = Read-PublicText "tools\test-skill-catalog.ps1"
Check "catalog host identity is source-bound" (
    $catalogResolver -match "Resolve-CatalogHostFromOriginator" -and
    $catalogResolver -match "does not match rollout originator"
)
Check "catalog file evidence is never labeled runtime-confirmed" (
    $catalogResolver -notmatch "runtime-confirmed" -and
    $catalogIndex -notmatch "runtime-confirmed" -and
    $catalogSearch -notmatch "runtime-confirmed" -and
    $catalogIndex -match "rollout-file-confirmed" -and
    $catalogSearch -match "CODEX_THREAD_ID"
)
Check "catalog suite covers both host mismatch directions and temp naming" (
    $catalogTests -match "Desktop rollout cannot be labeled CLI" -and
    $catalogTests -match "CLI rollout cannot be labeled Desktop" -and
    $catalogTests -match 'Name -match "\^\[\.\]tmp\[\.\]"'
)

Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

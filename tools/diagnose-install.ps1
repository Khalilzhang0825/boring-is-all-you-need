[CmdletBinding()]
param(
    [string]$TargetRoot = (Join-Path $HOME ".steadyagent"),
    [string]$CodexHome = (Join-Path $HOME ".codex"),
    [string]$ManagedConfigPath,
    [string]$GitConfigPath,
    [switch]$RequireHooksActive,
    [switch]$RequireRuntimeCatalog,
    [switch]$RequireGitIdentity,
    [switch]$SkipSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

if (-not $ManagedConfigPath) {
    $programDataRoot = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
    $ManagedConfigPath = Join-Path $programDataRoot "OpenAI\Codex\requirements.toml"
}

$script:Passed = 0
$script:Warned = 0
$script:Failed = 0

function Add-Result {
    param(
        [ValidateSet("PASS", "WARN", "FAIL")][string]$Status,
        [string]$Name,
        [string]$Detail = ""
    )
    if ($Status -eq "PASS") { $script:Passed++ }
    elseif ($Status -eq "WARN") { $script:Warned++ }
    else { $script:Failed++ }
    Write-Host ("{0} {1}{2}" -f $Status, $Name, $(if ($Detail) { " - " + $Detail } else { "" }))
}

function Test-File {
    param([string]$Name, [string]$Path)
    Add-Result $(if (Test-Path -LiteralPath $Path -PathType Leaf) { "PASS" } else { "FAIL" }) $Name $Path
}

function Test-ManagedConfig {
    param(
        [string]$Path,
        [string]$ExpectedPath,
        [ValidateSet("WARN", "FAIL")][string]$MissingSeverity
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Result $MissingSeverity "Codex managed config exists" $Path
        return
    }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    Add-Result "PASS" "Codex managed config exists"
    if (-not (Test-Path -LiteralPath $ExpectedPath -PathType Leaf)) {
        Add-Result "FAIL" "rendered expected managed config exists" $ExpectedPath
    }
    else {
        $expectedText = [IO.File]::ReadAllText($ExpectedPath, [Text.Encoding]::UTF8)
        Add-Result $(if ($text -eq $expectedText) { "PASS" } else { "FAIL" }) "active managed config exactly matches the rendered V2 matrix"
    }
    $blocks = ([regex]::Matches($text, '(?m)^\[\[hooks[.][A-Za-z]+[.]hooks\]\]$')).Count
    Add-Result $(if ($blocks -eq 4) { "PASS" } else { "FAIL" }) "exact four managed hook blocks" ("blocks=" + $blocks)
    foreach ($required in @(
        "agent-hook-context[.]ps1",
        "agent-hook-command-guard[.]ps1",
        "agent-hook-file-guard[.]ps1",
        "agent-hook-precompact[.]ps1"
    )) {
        Add-Result $(if ($text -match $required) { "PASS" } else { "FAIL" }) ("managed config includes " + $required)
    }
    Add-Result $(if ($text -notmatch "UserPromptSubmit|PermissionRequest|PostToolUse") { "PASS" } else { "FAIL" }) "high-frequency lifecycle hooks are absent"
    Add-Result $(if ($text -notmatch "%STEADYAGENT_HOME%") { "PASS" } else { "FAIL" }) "managed paths are rendered"
}

$targetFull = [IO.Path]::GetFullPath($TargetRoot)
$codexFull = [IO.Path]::GetFullPath($CodexHome)
$managedFull = [IO.Path]::GetFullPath($ManagedConfigPath)

Write-Host "SteadyAgent 2.0.0 Codex diagnosis"
Write-Host ("TargetRoot: " + $targetFull)
Write-Host ("CodexHome: " + $codexFull)
Write-Host ("ManagedConfigPath: " + $managedFull)

Test-File "Codex AGENTS installed" (Join-Path $codexFull "AGENTS.md")
Test-File "Codex user hooks installed" (Join-Path $codexFull "hooks.json")
Test-File "workflow rule installed" (Join-Path $targetFull "rules\workflow-routing.md")
Test-File "review rule installed" (Join-Path $targetFull "rules\review-gates.md")
Test-File "safety rule installed" (Join-Path $targetFull "rules\safety-boundaries.md")
Test-File "lessons index source installed" (Join-Path $targetFull "rules\lessons.md")
Test-File "Harness guide installed" (Join-Path $targetFull "rules\HARNESS-GUIDE.md")
Test-File "Harness review contract installed" (Join-Path $targetFull "rules\harness-review.md")
Test-File "workflow skill installed" (Join-Path $codexFull "skills\steadyagent-workflow\SKILL.md")
foreach ($hook in @(
    "agent-hook-utils.ps1",
    "agent-hook-context.ps1",
    "agent-hook-command-guard.ps1",
    "agent-hook-file-guard.ps1",
    "agent-hook-precompact.ps1"
)) {
    Test-File ("hook installed: " + $hook) (Join-Path $targetFull ("tools\hooks\" + $hook))
}

$contextHookPath = Join-Path $targetFull "tools\hooks\agent-hook-context.ps1"
$agentsPath = Join-Path $codexFull "AGENTS.md"
if ((Test-Path -LiteralPath $contextHookPath -PathType Leaf) -and
    (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
    $contextText = [IO.File]::ReadAllText($contextHookPath, [Text.Encoding]::UTF8)
    $agentsText = [IO.File]::ReadAllText($agentsPath, [Text.Encoding]::UTF8)
    Add-Result $(if (
        $contextText -match "Caveman startup status report" -and
        $contextText -match "first assistant response" -and
        $contextText -match "mode = `"lite`"" -and
        $agentsText -match "Caveman.*lite"
    ) { "PASS" } else { "FAIL" }) "Caveman lite startup contract is installed"
    Add-Result $(if (
        $contextText -match "Known pitfalls to avoid" -and
        $contextText -match "HARNESS-REVIEW DUE" -and
        $contextText -match "[.]harness-last-review"
    ) { "PASS" } else { "FAIL" }) "lessons and periodic Harness review injection are installed"
}

$reviewRulePath = Join-Path $targetFull "rules\review-gates.md"
$skillRulePath = Join-Path $targetFull "rules\skill-routing.md"
$maintenancePath = Join-Path $targetFull "rules\harness-review.md"
if ((Test-Path -LiteralPath $reviewRulePath -PathType Leaf) -and
    (Test-Path -LiteralPath $skillRulePath -PathType Leaf) -and
    (Test-Path -LiteralPath $maintenancePath -PathType Leaf)) {
    $reviewText = [IO.File]::ReadAllText($reviewRulePath, [Text.Encoding]::UTF8)
    $skillText = [IO.File]::ReadAllText($skillRulePath, [Text.Encoding]::UTF8)
    $maintenanceText = [IO.File]::ReadAllText($maintenancePath, [Text.Encoding]::UTF8)
    Add-Result $(if (
        $reviewText -match "File count alone is not a trigger" -and
        $reviewText -match "material risk" -and
        $skillText -match "Ordinary tasks do not search" -and
        $skillText -match "require explicit user invocation" -and
        $maintenanceText -match "three to six months" -and
        $maintenanceText -match "180 days" -and
        $maintenanceText -match "[.]harness-last-review"
    ) { "PASS" } else { "FAIL" }) "review, skill, and periodic maintenance contracts are consistent"
}
Test-File "protected path policy installed" (Join-Path $targetFull "tools\protected-path-policy.ps1")
Test-File "rollback tool installed" (Join-Path $targetFull "tools\rollback.ps1")
foreach ($catalogTool in @(
    "skill-catalog-resolver.ps1",
    "skill-index.ps1",
    "skill-search.ps1",
    "test-skill-catalog.ps1",
    "test-protected-path-policy.ps1"
)) {
    Test-File ("catalog/equivalence tool installed: " + $catalogTool) (Join-Path $targetFull ("tools\" + $catalogTool))
}
Test-File "pre-commit entrypoint installed" (Join-Path $targetFull "tools\git-hooks\pre-commit")
Test-File "pre-commit guard installed" (Join-Path $targetFull "tools\git-hooks\pre-commit-check.ps1")
$legacyManifest = Join-Path $targetFull "manifests\v1-codex-owned-files.txt"
Test-File "V1-owned file manifest installed" $legacyManifest
$equivalenceManifest = Join-Path $targetFull "manifests\local-postimage-equivalence.json"
Test-File "23-item local equivalence manifest installed" $equivalenceManifest
if (Test-Path -LiteralPath $equivalenceManifest -PathType Leaf) {
    try {
        $equivalence = Get-Content -LiteralPath $equivalenceManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-Result $(if (@($equivalence.entries).Count -eq 23) { "PASS" } else { "FAIL" }) `
            "local equivalence manifest maps all 23 entries" ("count=" + @($equivalence.entries).Count)
        Add-Result $(if ([string]$equivalence.localPostimageManifestSha256 -eq "A76846A184673C176F2FE2FE22B14835D216CA79824CB2F0ABF583B0F91D89FF") { "PASS" } else { "FAIL" }) `
            "local equivalence manifest identity is frozen"
    }
    catch {
        Add-Result "FAIL" "local equivalence manifest parses" $_.Exception.Message
    }
}
$expectedManagedConfig = Join-Path $targetFull "manifests\codex-requirements.expected.toml"
Test-File "rendered expected managed config installed" $expectedManagedConfig
if (Test-Path -LiteralPath $legacyManifest -PathType Leaf) {
    foreach ($relative in @([IO.File]::ReadAllLines($legacyManifest, [Text.Encoding]::UTF8))) {
        if (-not $relative.Trim()) { continue }
        $removedPath = Join-Path $codexFull $relative.Trim()
        Add-Result $(if (-not (Test-Path -LiteralPath $removedPath)) { "PASS" } else { "FAIL" }) ("V1-owned Codex file absent: " + $relative.Trim())
    }
}

$hooksJsonPath = Join-Path $codexFull "hooks.json"
if (Test-Path -LiteralPath $hooksJsonPath -PathType Leaf) {
    try {
        $hooksData = [IO.File]::ReadAllText($hooksJsonPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $hookPropertyCount = if ($hooksData.PSObject.Properties.Name -contains "hooks") {
            @($hooksData.hooks.PSObject.Properties).Count
        }
        else { -1 }
        Add-Result $(if ($hookPropertyCount -eq 0) { "PASS" } else { "FAIL" }) "Codex user hooks are empty"
    }
    catch { Add-Result "FAIL" "Codex user hooks parse as JSON" $_.Exception.Message }
}

$activeSeverity = if ($RequireHooksActive) { "FAIL" } else { "WARN" }
Test-ManagedConfig -Path $managedFull -ExpectedPath $expectedManagedConfig -MissingSeverity $activeSeverity

$expectedHooksPath = Join-Path $targetFull "tools\git-hooks"
if ($GitConfigPath) {
    $activeHooksPath = & git config --file $GitConfigPath --get core.hooksPath
}
else {
    $activeHooksPath = & git config --global --get core.hooksPath
}
$gitHooksActive = $LASTEXITCODE -eq 0 -and
    [string]$activeHooksPath -and
    ([string]$activeHooksPath).Equals($expectedHooksPath, [StringComparison]::OrdinalIgnoreCase)
Add-Result $(if ($gitHooksActive) { "PASS" } else { $activeSeverity }) "Git pre-commit path is active" ([string]$activeHooksPath)

if ($RequireRuntimeCatalog) {
    try {
        . (Join-Path $targetFull "tools\skill-catalog-resolver.ps1")
        $catalogThread = [string]$env:CODEX_THREAD_ID
        $catalogRoot = Join-Path $targetFull "runtime-skill-catalogs"
        $expectedCatalog = Resolve-RuntimeCatalogSnapshot `
            -HostSurface "Auto" `
            -ThreadId $catalogThread `
            -CatalogRoot $catalogRoot
        Add-Result $(if (Test-RuntimeCatalogSnapshot -Expected $expectedCatalog) { "PASS" } else { "FAIL" }) `
            "current rollout-bound runtime catalog is valid" $expectedCatalog.SnapshotId
    }
    catch {
        Add-Result "FAIL" "current rollout-bound runtime catalog is valid" $_.Exception.Message
    }
}

$identitySeverity = if ($RequireGitIdentity) { "FAIL" } else { "WARN" }
if ($GitConfigPath) {
    $gitName = & git config --file $GitConfigPath --get user.name
    $gitEmail = & git config --file $GitConfigPath --get user.email
}
else {
    $gitName = & git config --global --get user.name
    $gitEmail = & git config --global --get user.email
}
Add-Result $(if ([string]$gitName) { "PASS" } else { $identitySeverity }) "Git user.name is configured"
Add-Result $(if ([string]$gitEmail) { "PASS" } else { $identitySeverity }) "Git user.email is configured"

if ($SkipSmoke) {
    Add-Result "WARN" "installed hook smoke" "skipped"
}
else {
    $smoke = Join-Path $targetFull "tools\test-agent-hooks.ps1"
    if (-not (Test-Path -LiteralPath $smoke -PathType Leaf)) {
        Add-Result "FAIL" "installed hook smoke" ("missing " + $smoke)
    }
    else {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $smoke
        $code = $LASTEXITCODE
        Add-Result $(if ($code -eq 0 -and ($output | Out-String) -match "fail=0") { "PASS" } else { "FAIL" }) "installed hook smoke" ($output | Out-String).Trim()
    }
}

Write-Host ("RESULT pass={0} warn={1} fail={2}" -f $script:Passed, $script:Warned, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

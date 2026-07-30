[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:Passed = 0
$script:Failed = 0

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

function Read-PublicText {
    param([string]$Relative)
    return [IO.File]::ReadAllText((Join-Path $root $Relative), [Text.Encoding]::UTF8)
}

$requirements = Read-PublicText "templates\codex\requirements.managed-hooks.example.toml"
Check "managed runtime has exactly four blocks" (
    ([regex]::Matches($requirements, '(?m)^\[\[hooks[.][A-Za-z]+[.]hooks\]\]$')).Count -eq 4
)
Check "managed runtime remains Codex-only and lightweight" (
    $requirements -notmatch "Claude|UserPromptSubmit|PermissionRequest|PostToolUse"
)

$context = Read-PublicText "tools\hooks\agent-hook-context.ps1"
$hookTests = Read-PublicText "tools\test-agent-hooks.ps1"
$agents = Read-PublicText "templates\codex\AGENTS.md"
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
    $hookTests -match "startup reports Caveman lite once" -and
    $hookTests -match "startup injects lesson titles" -and
    $hookTests -match "current review marker suppresses due notice"
)

$diagnose = Read-PublicText "tools\diagnose-install.ps1"
Check "diagnosis exposes strict runtime catalog mode" (
    $diagnose -match "RequireRuntimeCatalog" -and
    $diagnose -match "Test-RuntimeCatalogSnapshot"
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

$maintenance = Read-PublicText "rules\harness-review.md"
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

$review = Read-PublicText "rules\review-gates.md"
$skills = Read-PublicText "rules\skill-routing.md"
$workflow = Read-PublicText "rules\workflow-routing.md"
$safety = Read-PublicText "rules\safety-boundaries.md"
Check "review stays risk-triggered rather than file-count-triggered" (
    $review -match "File count alone is not a trigger" -and $review -match "material risk"
)
Check "skill routing stays explicit and lightweight" (
    $skills -match "Ordinary tasks do not search" -and $skills -match "explicit user invocation"
)
Check "workflow retains diagnose verify review checkpoint sequence" (
    $workflow -match "diagnose" -and $workflow -match "red check" -and $workflow -match "green check" -and
    $workflow -match "review" -and $workflow -match "checkpoint"
)
Check "safety retains external-write and destructive authorization boundaries" (
    $safety -match "external" -and $safety -match "destructive" -and $safety -match "authorization"
)

$catalogResolver = Read-PublicText "tools\skill-catalog-resolver.ps1"
$catalogTests = Read-PublicText "tools\test-skill-catalog.ps1"
Check "catalog host identity is source-bound" (
    $catalogResolver -match "Resolve-CatalogHostFromOriginator" -and
    $catalogResolver -match "does not match rollout originator"
)
Check "catalog suite covers both host mismatch directions and temp naming" (
    $catalogTests -match "Desktop rollout cannot be labeled CLI" -and
    $catalogTests -match "CLI rollout cannot be labeled Desktop" -and
    $catalogTests -match 'Name -match "\^\[\.\]tmp\[\.\]"'
)

Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

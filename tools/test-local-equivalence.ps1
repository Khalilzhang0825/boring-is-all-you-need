[CmdletBinding()]
param(
    [switch]$InternalVerify,
    [switch]$InjectMappingDrift,
    [switch]$InjectSemanticDrift,
    [switch]$InjectSupportSubstitution,
    [switch]$InjectRemovalSubstitution,
    [switch]$InjectByteExactSubstitution,
    [switch]$InjectSemanticCheckSubstitution,
    [switch]$InjectSemanticCheckGateSubstitution,
    [switch]$InjectCatalogCaseSetDrift,
    [switch]$InjectHookScopeDrift
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Passed = 0
$script:Failed = 0
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$mapPath = Join-Path $repoRoot "manifests\local-postimage-equivalence.json"
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("steadyagent-v2-migration-" + [guid]::NewGuid().ToString("N"))
$hookInvocationLedgerPath = $null
$ownsHookInvocationLedger = $false
$installedHookGateOutput = @()
$installedHookGateExit = $null
$expectedInstalledHookRoot = $null
$oldHookInvocationLedger = [Environment]::GetEnvironmentVariable(
    "STEADYAGENT_HOOK_INVOCATION_LEDGER"
)

function Check {
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

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace("-", "")
    }
    finally { $sha.Dispose() }
}

function Test-SafeRelativePath {
    param([string]$Path)
    if (-not $Path -or [IO.Path]::IsPathRooted($Path)) { return $false }
    return -not ($Path -match '(^|[\\/])[.][.]([\\/]|$)')
}

function Copy-PackageFixture {
    param([string]$Destination)

    $destinationFull = [IO.Path]::GetFullPath($Destination)
    $destinationPrefix = $destinationFull.TrimEnd("\") + "\"
    New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
    $manifestPath = Join-Path $repoRoot "package-assets.sha256"
    $relativePaths = New-Object Collections.Generic.List[string]
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadAllLines($manifestPath, [Text.Encoding]::UTF8)) {
        if ($line -notmatch '^[0-9A-F]{64}  (?<path>[A-Za-z0-9._/-]+)$') {
            throw "Package fixture manifest line is invalid."
        }
        $relative = [string]$Matches.path
        if (-not (Test-SafeRelativePath -Path $relative) -or -not $seen.Add($relative)) {
            throw ("Package fixture manifest path is unsafe or duplicated: " + $relative)
        }
        $relativePaths.Add($relative) | Out-Null
    }
    if ($relativePaths.Count -ne 52) {
        throw ("Package fixture requires exactly 52 source assets; observed " + $relativePaths.Count)
    }
    foreach ($relative in @($relativePaths.ToArray()) + @("package-assets.sha256", "tools/install.ps1")) {
        $source = [IO.Path]::GetFullPath((Join-Path $repoRoot $relative.Replace("/", "\")))
        $target = [IO.Path]::GetFullPath((Join-Path $destinationFull $relative.Replace("/", "\")))
        if (-not $target.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw ("Package fixture target escaped its root: " + $relative)
        }
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::Copy($source, $target, $false)
    }
}

function Get-InstalledPath {
    param(
        [object]$Entry,
        [string]$TargetRoot,
        [string]$CodexHome,
        [string]$ManagedConfigPath
    )
    $destination = [string]$Entry.installedDestination
    if ($destination -eq "@managedConfig") {
        return $ManagedConfigPath
    }
    if ($destination.StartsWith("@codex/", [StringComparison]::Ordinal)) {
        return Join-Path $CodexHome $destination.Substring(7)
    }
    return Join-Path $TargetRoot $destination
}

function Get-SemanticMarkerAudit {
    param(
        [object[]]$ObservedMarkers,
        [Collections.Generic.Dictionary[string,string]]$ExpectedGateById
    )

    $markers = @($ObservedMarkers)
    $filterId = [Environment]::GetEnvironmentVariable(
        "STEADYAGENT_EQUIVALENCE_FILTER_SEMANTIC_MARKER"
    )
    $filterApplied = $false
    if (-not [string]::IsNullOrWhiteSpace($filterId)) {
        if ($env:STEADYAGENT_EQUIVALENCE_TEST_MODE -ne "1") {
            throw "Semantic marker filtering is available only to the isolated equivalence test."
        }
        $retained = New-Object Collections.Generic.List[object]
        foreach ($marker in $markers) {
            if (-not $filterApplied -and [string]$marker.Id -ceq $filterId) {
                $filterApplied = $true
                continue
            }
            $retained.Add($marker)
        }
        $markers = @($retained.ToArray())
        if ($filterApplied) {
            Write-Host ("MUTATION semantic execution marker filtered in memory: " + $filterId)
        }
    }

    $counts = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    foreach ($marker in $markers) {
        $id = [string]$marker.Id
        if ($counts.ContainsKey($id)) {
            $counts[$id]++
        }
        else {
            $counts.Add($id, 1)
        }
    }

    $missing = @($ExpectedGateById.Keys | Where-Object {
        -not $counts.ContainsKey($_)
    } | Sort-Object)
    $duplicates = @($counts.Keys | Where-Object {
        $counts[$_] -ne 1
    } | Sort-Object)
    $unknown = @($counts.Keys | Where-Object {
        -not $ExpectedGateById.ContainsKey($_)
    } | Sort-Object)
    $wrongGate = @($markers | Where-Object {
        $ExpectedGateById.ContainsKey([string]$_.Id) -and
        [string]$_.Gate -cne $ExpectedGateById[[string]$_.Id]
    } | ForEach-Object {
        "{0}@{1} expected={2}" -f $_.Id, $_.Gate, $ExpectedGateById[[string]$_.Id]
    } | Sort-Object)
    $filterMissing = (
        -not [string]::IsNullOrWhiteSpace($filterId) -and
        -not $filterApplied
    )
    $passed = (
        $missing.Count -eq 0 -and
        $duplicates.Count -eq 0 -and
        $unknown.Count -eq 0 -and
        $wrongGate.Count -eq 0 -and
        -not $filterMissing
    )

    return [pscustomobject]@{
        Passed = $passed
        Detail = (
            "missing={0}; duplicate={1}; unknown={2}; wrongGate={3}; filterApplied={4}" -f
            ($missing -join ","),
            ($duplicates -join ","),
            ($unknown -join ","),
            ($wrongGate -join ","),
            $filterApplied
        )
        Missing = $missing
        Duplicates = $duplicates
        Unknown = $unknown
        WrongGate = $wrongGate
        FilterApplied = $filterApplied
    }
}

function Get-HookEvidenceAudit {
    param(
        [string]$GateText,
        [object[]]$RetainedMappings,
        [string]$DropCase = ""
    )

    $passingCases = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($line in @($GateText -split '\r?\n')) {
        if ($line -cmatch '^PASS (?<case>.+)$') {
            $passingCases.Add([string]$Matches.case) | Out-Null
        }
    }
    $dropApplied = $false
    if (-not [string]::IsNullOrWhiteSpace($DropCase)) {
        $dropApplied = $passingCases.Remove($DropCase)
    }

    $missing = New-Object Collections.Generic.List[string]
    foreach ($mapping in $RetainedMappings) {
        $cases = @($mapping.evidenceCases | ForEach-Object { [string]$_ })
        if ($cases.Count -eq 0) {
            $missing.Add(([string]$mapping.name + "=>NO_CASES"))
            continue
        }
        foreach ($caseName in $cases) {
            if (-not $passingCases.Contains($caseName)) {
                $missing.Add(([string]$mapping.name + "=>" + $caseName))
            }
        }
    }
    return [pscustomobject]@{
        Passed = $missing.Count -eq 0
        Missing = @($missing.ToArray())
        DropApplied = $dropApplied
        Detail = "missing=" + ($missing -join ",") + "; dropApplied=" + $dropApplied
    }
}

function Clear-HookInvocationLedger {
    if (-not $script:ownsHookInvocationLedger) { return }
    if ($null -ne $script:hookInvocationLedgerPath -and
        (Test-Path -LiteralPath $script:hookInvocationLedgerPath -PathType Leaf)) {
        Remove-Item -LiteralPath $script:hookInvocationLedgerPath -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $script:oldHookInvocationLedger) {
        Remove-Item Env:\STEADYAGENT_HOOK_INVOCATION_LEDGER -ErrorAction SilentlyContinue
    }
    else {
        $env:STEADYAGENT_HOOK_INVOCATION_LEDGER = $script:oldHookInvocationLedger
    }
}

if (-not $InternalVerify) {
    if ([string]::IsNullOrWhiteSpace($oldHookInvocationLedger)) {
        $ownsHookInvocationLedger = $true
        $hookInvocationLedgerPath = Join-Path ([IO.Path]::GetTempPath()) (
            "steadyagent-hook-invocation-" + [guid]::NewGuid().ToString("N") + ".log"
        )
        $ledgerStream = [IO.File]::Open(
            $hookInvocationLedgerPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::Read
        )
        $ledgerStream.Dispose()
        $env:STEADYAGENT_HOOK_INVOCATION_LEDGER = $hookInvocationLedgerPath
    }
    else {
        $hookInvocationLedgerPath = [IO.Path]::GetFullPath($oldHookInvocationLedger)
    }
}
trap {
    Clear-HookInvocationLedger
    throw
}

if (($InjectMappingDrift -or $InjectSemanticDrift -or $InjectSupportSubstitution -or
     $InjectRemovalSubstitution -or $InjectByteExactSubstitution -or
     $InjectSemanticCheckSubstitution -or $InjectSemanticCheckGateSubstitution -or
     $InjectCatalogCaseSetDrift -or $InjectHookScopeDrift) -and
    $env:STEADYAGENT_EQUIVALENCE_TEST_MODE -ne "1") {
    throw "Mapping drift injection is available only to the isolated equivalence test."
}
$requestedSemanticMarkerFilter = [Environment]::GetEnvironmentVariable(
    "STEADYAGENT_EQUIVALENCE_FILTER_SEMANTIC_MARKER"
)
if (-not [string]::IsNullOrWhiteSpace($requestedSemanticMarkerFilter) -and
    $env:STEADYAGENT_EQUIVALENCE_TEST_MODE -ne "1") {
    throw "Semantic marker filtering is available only to the isolated equivalence test."
}

if (-not $InternalVerify) {
    $oldMode = $env:STEADYAGENT_EQUIVALENCE_TEST_MODE
    try {
        $env:STEADYAGENT_EQUIVALENCE_TEST_MODE = "1"
        $negativeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -InternalVerify -InjectMappingDrift
        $negativeExit = $LASTEXITCODE
        $negativeText = @($negativeOutput) -join "`n"
        Check "deliberate mapping drift makes the equivalence gate red" (
            $negativeExit -ne 0 -and
            $negativeText -match "MUTATION expected source hash changed" -and
            $negativeText -match "RESULT pass=\d+ fail=[1-9]\d*"
        ) $negativeText

        $semanticOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -InternalVerify -InjectSemanticDrift
        $semanticExit = $LASTEXITCODE
        $semanticText = @($semanticOutput) -join "`n"
        Check "deliberate semantic mapping drift makes the equivalence gate red" (
            $semanticExit -ne 0 -and
            $semanticText -match "MUTATION semantic gate catalog substituted" -and
            $semanticText -match "RESULT pass=\d+ fail=[1-9]\d*"
        ) $semanticText

        $supportOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -InternalVerify -InjectSupportSubstitution
        $supportExit = $LASTEXITCODE
        $supportText = @($supportOutput) -join "`n"
        Check "deliberate support substitution makes the destination gate red" (
            $supportExit -ne 0 -and
            $supportText -match "MUTATION support destination substituted" -and
            $supportText -notmatch "isolated public installation succeeds" -and
            $supportText -match "RESULT pass=\d+ fail=[1-9]\d*"
        ) $supportText

        $removalOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -InternalVerify -InjectRemovalSubstitution
        $removalExit = $LASTEXITCODE
        $removalText = @($removalOutput) -join "`n"
        Check "equal-count V1 removal substitution makes the frozen projection gate red" (
            $removalExit -ne 0 -and
            $removalText -match "MUTATION V1 removal entry substituted" -and
            $removalText -match "FAIL V1 removal projection matches the independent frozen digest" -and
            $removalText -match "RESULT pass=\d+ fail=[1-9]\d*"
        ) $removalText

        $byteExactOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -InternalVerify -InjectByteExactSubstitution
        $byteExactExit = $LASTEXITCODE
        $byteExactText = @($byteExactOutput) -join "`n"
        Check "injected byte-exact classification makes the empty identity gate red" (
            $byteExactExit -ne 0 -and
            $byteExactText -match "MUTATION byte-exact payload classification added" -and
            $byteExactText -match "FAIL portable hardening leaves no byte-exact payload identities" -and
            $byteExactText -match "RESULT pass=\d+ fail=[1-9]\d*"
        ) $byteExactText

        $semanticCheckOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
            -InternalVerify `
            -InjectSemanticCheckSubstitution
        $semanticCheckExit = $LASTEXITCODE
        $semanticCheckText = @($semanticCheckOutput) -join "`n"
        Check "equal-count semantic check ID substitution makes the allowlist gate red" (
            $semanticCheckExit -ne 0 -and
            $semanticCheckText -match "MUTATION semantic check ID substituted with equal count" -and
            $semanticCheckText -match "FAIL semantic check array matches independent allowlist: 01-requirements.toml" -and
            $semanticCheckText -match "RESULT pass=\d+ fail=[1-9]\d*"
        ) $semanticCheckText

        $semanticGateOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
            -InternalVerify `
            -InjectSemanticCheckGateSubstitution
        $semanticGateExit = $LASTEXITCODE
        $semanticGateText = @($semanticGateOutput) -join "`n"
        Check "semantic check gate reassignment makes the independent gate map red" (
            $semanticGateExit -ne 0 -and
            $semanticGateText -match "MUTATION semantic check gate reassigned" -and
            $semanticGateText -match "FAIL semantic check gate matches independent allowlist: 07-agent-config-audit.ps1" -and
            $semanticGateText -match "RESULT pass=\d+ fail=[1-9]\d*"
        ) $semanticGateText

        $catalogSetOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
            -InternalVerify `
            -InjectCatalogCaseSetDrift
        $catalogSetExit = $LASTEXITCODE
        $catalogSetText = @($catalogSetOutput) -join "`n"
        Check "coupled catalog case-set drift makes the independent digest gate red" (
            $catalogSetExit -ne 0 -and
            $catalogSetText -match "MUTATION catalog case-set contract changed" -and
            $catalogSetText -notmatch "isolated public installation succeeds" -and
            $catalogSetText -match "FAIL catalog default and rollout-file canary case-set contract matches independent frozen digests" -and
            $catalogSetText -match "RESULT pass=\d+ fail=[1-9]\d*"
        ) $catalogSetText

        $hookScopeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
            -InternalVerify `
            -InjectHookScopeDrift
        $hookScopeExit = $LASTEXITCODE
        $hookScopeText = @($hookScopeOutput) -join "`n"
        Check "Hook scope substitution makes the Codex-active partition gate red" (
            $hookScopeExit -ne 0 -and
            $hookScopeText -match "MUTATION Hook scope exclusion substituted" -and
            $hookScopeText -notmatch "isolated public installation succeeds" -and
            $hookScopeText -match "FAIL payload 06 excluded assertion allowlist and reasons are exact" -and
            $hookScopeText -match "RESULT pass=\d+ fail=[1-9]\d*"
        ) $hookScopeText

    }
    finally {
        if ($null -eq $oldMode) { Remove-Item Env:\STEADYAGENT_EQUIVALENCE_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_EQUIVALENCE_TEST_MODE = $oldMode }
    }
}

$map = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json
$entries = @($map.entries)
$legacyRemovalLines = @(
    [IO.File]::ReadAllLines(
        (Join-Path $repoRoot "manifests\v1-codex-owned-files.txt"),
        [Text.Encoding]::UTF8
    ) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)
$expectedSemanticGateCatalog = [ordered]@{
    migration = [ordered]@{ script = "tools/test-v2-migration.ps1"; expected = "fail=0" }
    hooks = [ordered]@{ script = "tools/test-agent-hooks.ps1"; expected = "fail=0" }
    checkpoint = [ordered]@{ script = "tools/test-git-checkpoint.ps1"; expected = "0 failed" }
    skills = [ordered]@{ script = "tools/test-skill-catalog.ps1"; expected = "0 failed" }
    precommit = [ordered]@{ script = "tools/test-pre-commit.ps1"; expected = "0 failed" }
    policy = [ordered]@{ script = "tools/test-equivalence-contract.ps1"; expected = "fail=0" }
    protected_paths = [ordered]@{ script = "tools/test-protected-path-policy.ps1"; expected = "0 failed" }
}
$expectedSemanticChecksByPayload = [ordered]@{
    "01-requirements.toml" = @(
        "migration.rendered-three-block-unified-matrix"
    )
    "02-agent-hook-utils.ps1" = @(
        "hooks.utils-parser-wrapper-privacy-git-options",
        "hooks.command-guard-wrapper-normalization"
    )
    "03-agent-hook-command-guard.ps1" = @(
        "hooks.command-guard-bounded-input-tree"
    )
    "04-agent-hook-file-guard.ps1" = @(
        "hooks.file-guard-nested-protected-failclosed"
    )
    "05-agent-hook-context.ps1" = @(
        "context.caveman-lite",
        "context.lessons-title-only",
        "context.review-90-day",
        "context.state-restore"
    )
    "06-agent-hook-smoke-test.ps1" = @(
        "hooks.codex-active-suite-executed"
    )
    "07-agent-config-audit.ps1" = @(
        "diagnose.strict-installed-contract"
    )
    "08-git-checkpoint.ps1" = @(
        "checkpoint.isolated-index-cas-compensation",
        "checkpoint.quarantined-object-publication"
    )
    "09-git-checkpoint-test.ps1" = @(
        "checkpoint.adversarial-suite-executed"
    )
    "10-skill-catalog-resolver.ps1" = @(
        "catalog.resolver-bound-identity"
    )
    "11-skill-index.ps1" = @(
        "catalog.index-atomic-publication"
    )
    "12-skill-search.ps1" = @(
        "catalog.search-bound-fixture-isolation"
    )
    "13-skill-catalog-test.ps1" = @(
        "catalog.required-suite-executed"
    )
    "14-pre-commit-check.ps1" = @(
        "precommit.protected-secret-size"
    )
    "15-pre-commit-check-test.ps1" = @(
        "precommit.local-contract-suite-executed"
    )
    "16-review-gates.md" = @(
        "policy.review-risk-trigger"
    )
    "17-skill-routing.md" = @(
        "policy.skill-explicit-lightweight"
    )
    "18-workflow-routing.md" = @(
        "policy.workflow-sequence"
    )
    "19-safety-boundaries.md" = @(
        "policy.safety-authority-live-boundary"
    )
    "20-HARNESS-GUIDE.md" = @(
        "policy.guide-runtime-recovery-evidence"
    )
    "21-harness-review.md" = @(
        "policy.periodic-maintenance-marker"
    )
    "22-protected-path-policy.ps1" = @(
        "protected-paths.windows-alias-policy",
        "protected-paths.bound-mutation",
        "protected-paths.owned-directory"
    )
    "23-protected-path-policy-test.ps1" = @(
        "protected-paths.local-contract-suite-executed"
    )
}
$expectedSemanticGateAssignments = [ordered]@{
    "migration.rendered-three-block-unified-matrix" = "migration"
    "diagnose.strict-installed-contract" = "migration"
    "hooks.utils-parser-wrapper-privacy-git-options" = "hooks"
    "hooks.command-guard-wrapper-normalization" = "hooks"
    "hooks.command-guard-bounded-input-tree" = "hooks"
    "hooks.file-guard-nested-protected-failclosed" = "hooks"
    "context.caveman-lite" = "hooks"
    "context.lessons-title-only" = "hooks"
    "context.review-90-day" = "hooks"
    "context.state-restore" = "hooks"
    "hooks.codex-active-suite-executed" = "hooks"
    "checkpoint.isolated-index-cas-compensation" = "checkpoint"
    "checkpoint.quarantined-object-publication" = "checkpoint"
    "checkpoint.adversarial-suite-executed" = "checkpoint"
    "catalog.resolver-bound-identity" = "skills"
    "catalog.index-atomic-publication" = "skills"
    "catalog.search-bound-fixture-isolation" = "skills"
    "catalog.required-suite-executed" = "skills"
    "precommit.protected-secret-size" = "precommit"
    "precommit.local-contract-suite-executed" = "precommit"
    "policy.review-risk-trigger" = "policy"
    "policy.skill-explicit-lightweight" = "policy"
    "policy.workflow-sequence" = "policy"
    "policy.safety-authority-live-boundary" = "policy"
    "policy.guide-runtime-recovery-evidence" = "policy"
    "policy.periodic-maintenance-marker" = "policy"
    "protected-paths.windows-alias-policy" = "protected_paths"
    "protected-paths.bound-mutation" = "protected_paths"
    "protected-paths.owned-directory" = "protected_paths"
    "protected-paths.local-contract-suite-executed" = "protected_paths"
}
if ($InjectSemanticDrift) {
    $map.semanticGateCatalog.migration.script = "tools/test-equivalence-contract.ps1"
    Write-Host "MUTATION semantic gate catalog substituted"
}
if ($InjectSupportSubstitution) {
    $map.supportInstalls[0].installedDestination = "@codex/unexplained-substitute.md"
    Write-Host "MUTATION support destination substituted"
}
if ($InjectRemovalSubstitution) {
    $legacyRemovalLines[0] = "requirements.managed-hooks.substituted.toml"
    Write-Host "MUTATION V1 removal entry substituted"
}
if ($InjectByteExactSubstitution) {
    ($entries | Where-Object { [string]$_.payload -eq "04-agent-hook-file-guard.ps1" }).mode = "byte-exact"
    Write-Host "MUTATION byte-exact payload classification added"
}
if ($InjectSemanticCheckSubstitution) {
    $semanticEntry = $entries | Where-Object {
        [string]$_.payload -eq "01-requirements.toml"
    } | Select-Object -First 1
    $semanticEntry.semanticChecks[0] = "migration.rendered-three-block-unified-substitute"
    Write-Host "MUTATION semantic check ID substituted with equal count"
}
if ($InjectSemanticCheckGateSubstitution) {
    ($entries | Where-Object {
        [string]$_.payload -eq "07-agent-config-audit.ps1"
    } | Select-Object -First 1).semanticGate = "policy"
    Write-Host "MUTATION semantic check gate reassigned"
}
if ($InjectCatalogCaseSetDrift) {
    $catalogEntryForMutation = @($entries | Where-Object {
        [string]$_.payload -ceq "13-skill-catalog-test.ps1"
    }) | Select-Object -First 1
    $catalogEntryForMutation.semanticCaseSets.defaultCount = 44
    $catalogEntryForMutation.semanticCaseSets.defaultSha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    Write-Host "MUTATION catalog case-set contract changed"
}
if ($InjectHookScopeDrift) {
    $hookScopeEntryForMutation = @($entries | Where-Object {
        [string]$_.payload -ceq "06-agent-hook-smoke-test.ps1"
    }) | Select-Object -First 1
    $hookScopeEntryForMutation.scopeContract.excludedAssertions[0].name =
        "startup: substituted host branch"
    Write-Host "MUTATION Hook scope exclusion substituted"
}
Check "equivalence schema is v1" ([int]$map.schemaVersion -eq 1)
Check "release identity is v2.0.2" ([string]$map.release -eq "v2.0.2")
Check "canonical local manifest SHA-256 is frozen" (
    [string]$map.localPostimageManifestSha256 -eq "A76846A184673C176F2FE2FE22B14835D216CA79824CB2F0ABF583B0F91D89FF"
)
Check "all 23 local postimage entries are mapped" ($entries.Count -eq 23) ([string]$entries.Count)
Check "mapped install count is 23" ([int]$map.mappedInstallCount -eq 23)
Check "support install count is explicitly 30" ([int]$map.supportInstallCount -eq 30)
Check "total install count is explicitly 53" ([int]$map.totalInstallCount -eq 53)
Check "legacy removal count is explicitly 27" ([int]$map.legacyRemovalCount -eq 27)
$expectedCatalogDefaultCaseCount = 69
$expectedCatalogDefaultCaseSetSha256 = "EF25BDC297AA7402B1EC8D3B42A6F7B70C9EA94CA92FA336AD280301BD4134E7"
$expectedCatalogRolloutFileCanaryCaseCount = 76
$expectedCatalogRolloutFileCanaryCaseSetSha256 = "6AAF6F06C85B1165317DAA376BE3F371885A8293632BAB6B64402388C353A13A"
$catalogContractEntry = @($entries | Where-Object {
    [string]$_.payload -ceq "13-skill-catalog-test.ps1"
}) | Select-Object -First 1
$catalogCaseSetContract = if (
    $catalogContractEntry -and
    $catalogContractEntry.PSObject.Properties.Name -contains "semanticCaseSets"
) { $catalogContractEntry.semanticCaseSets } else { $null }
Check "catalog default and rollout-file canary case-set contract matches independent frozen digests" (
    $catalogCaseSetContract -and
    [int]$catalogCaseSetContract.defaultCount -eq $expectedCatalogDefaultCaseCount -and
    [string]$catalogCaseSetContract.defaultSha256 -ceq $expectedCatalogDefaultCaseSetSha256 -and
    [int]$catalogCaseSetContract.rolloutFileCanaryCount -eq $expectedCatalogRolloutFileCanaryCaseCount -and
    [string]$catalogCaseSetContract.rolloutFileCanarySha256 -ceq $expectedCatalogRolloutFileCanaryCaseSetSha256
)
$expectedHookScopeSourceCount = 73
$expectedHookScopeSourceSha256 = "D8510FD50093292CF978FBE351018C4F28BF7881739FCB661F852BBF484F13A4"
$expectedHookScopeRetainedCount = 65
$expectedHookScopeRetainedSha256 = "90F5004A5321EBA6BFC4710CBA4C5185D6CD032E84F9D42FCF53DFED80A49101"
$expectedHookEvidenceBindingSha256 = "4ADA439151FE6FFC6B0266A4F842ED2143E6094C862FA5862B8F43466CD7E106"
$expectedHookScopeExcluded = @(
    [pscustomobject]@{
        name = "startup: Claude review policy unchanged"
        reason = "unsupported-host:Claude"
    },
    [pscustomobject]@{
        name = "startup: Claude omits Codex review policy"
        reason = "unsupported-host:Claude"
    },
    [pscustomobject]@{
        name = "danger permission: denied"
        reason = "removed-event:PermissionRequest"
    },
    [pscustomobject]@{
        name = "safe permission: no decision"
        reason = "removed-event:PermissionRequest"
    },
    [pscustomobject]@{
        name = "any prompt: RULES"
        reason = "removed-event:UserPromptSubmit"
    },
    [pscustomobject]@{
        name = "push prompt: risk line"
        reason = "removed-event:UserPromptSubmit"
    },
    [pscustomobject]@{
        name = "sync hook: no deny"
        reason = "removed-event:UserPromptSubmit"
    },
    [pscustomobject]@{
        name = "posttool audit: no deny"
        reason = "removed-event:PostToolUse"
    }
)
$expectedHookScopeExcludedRows = @($expectedHookScopeExcluded | ForEach-Object {
    [string]$_.name + "|" + [string]$_.reason
})
$expectedHookScopeExcludedSha256 = "DEDE51BCC4B3F64C9A931B03D18603BF9CEEECC79ECD614FCA54AA79E59235F4"
$hookScopeEntry = @($entries | Where-Object {
    [string]$_.payload -ceq "06-agent-hook-smoke-test.ps1"
}) | Select-Object -First 1
$hookScopeContract = if (
    $hookScopeEntry -and
    $hookScopeEntry.PSObject.Properties.Name -contains "scopeContract"
) { $hookScopeEntry.scopeContract } else { $null }
$actualHookScopeExcludedRows = if (
    $hookScopeContract -and
    $hookScopeContract.PSObject.Properties.Name -contains "excludedAssertions"
) {
    @($hookScopeContract.excludedAssertions | ForEach-Object {
        [string]$_.name + "|" + [string]$_.reason
    })
}
else { @() }
Check "payload 06 uses Codex-active scoped equivalence rather than a full behavior superset" (
    $hookScopeEntry -and
    [string]$hookScopeEntry.mode -ceq "scoped-equivalent"
)
Check "payload 06 freezes the authoritative local assertion catalog" (
    $hookScopeContract -and
    [string]$hookScopeContract.scope -ceq "codex-active-v2" -and
    [int]$hookScopeContract.sourceAssertionCount -eq $expectedHookScopeSourceCount -and
    [string]$hookScopeContract.sourceAssertionProjectionSha256 -ceq $expectedHookScopeSourceSha256
)
Check "payload 06 excluded assertion allowlist and reasons are exact" (
    $hookScopeContract -and
    [int]$hookScopeContract.excludedAssertionCount -eq $expectedHookScopeExcluded.Count -and
    ($actualHookScopeExcludedRows -join "`n") -ceq ($expectedHookScopeExcludedRows -join "`n") -and
    (Get-Sha256Text -Text ($actualHookScopeExcludedRows -join "`n")) -ceq $expectedHookScopeExcludedSha256 -and
    [string]$hookScopeContract.excludedAssertionProjectionSha256 -ceq $expectedHookScopeExcludedSha256
) (($actualHookScopeExcludedRows) -join ", ")
Check "payload 06 retained assertion projection is the exact complement" (
    $hookScopeContract -and
    [int]$hookScopeContract.retainedAssertionCount -eq $expectedHookScopeRetainedCount -and
    [int]$hookScopeContract.sourceAssertionCount -eq (
        [int]$hookScopeContract.retainedAssertionCount +
        [int]$hookScopeContract.excludedAssertionCount
    ) -and
    [string]$hookScopeContract.retainedAssertionProjectionSha256 -ceq $expectedHookScopeRetainedSha256
)
$actualHookRetainedMappings = if (
    $hookScopeContract -and
    $hookScopeContract.PSObject.Properties.Name -contains "retainedAssertions"
) {
    @($hookScopeContract.retainedAssertions)
}
else { @() }
$actualHookRetainedNames = @($actualHookRetainedMappings | ForEach-Object {
    [string]$_.name
})
$actualHookEvidenceRows = @($actualHookRetainedMappings | ForEach-Object {
    $cases = @($_.evidenceCases | ForEach-Object { [string]$_ })
    ([string]$_.name) + "`t" + ($cases -join ([char]0x1F))
})
Check "payload 06 retained assertions bind to an independent evidence projection" (
    $hookScopeContract -and
    [string]$hookScopeContract.assertionProjectionKind -ceq
        "ordered-name-to-public-evidence-cases-v1" -and
    $actualHookRetainedMappings.Count -eq $expectedHookScopeRetainedCount -and
    @($actualHookRetainedNames | Sort-Object -Unique).Count -eq
        $expectedHookScopeRetainedCount -and
    (Get-Sha256Text -Text ($actualHookRetainedNames -join "`n")) -ceq
        $expectedHookScopeRetainedSha256 -and
    (Get-Sha256Text -Text ($actualHookEvidenceRows -join "`n")) -ceq
        $expectedHookEvidenceBindingSha256 -and
    [string]$hookScopeContract.retainedEvidenceProjectionSha256 -ceq
        $expectedHookEvidenceBindingSha256
)
$expectedLegacyRemovalProjectionHash = "16F51949FF3DF81A7E33E471E25432034A72AF2136EB3D138FEB6F710E61B58A"
$legacyRemovalProjectionHash = Get-Sha256Text -Text ($legacyRemovalLines -join "`n")
Check "V1 removal projection matches the independent frozen digest" (
    $legacyRemovalLines.Count -eq 27 -and
    $legacyRemovalProjectionHash -ceq $expectedLegacyRemovalProjectionHash -and
    [string]$map.legacyRemovalProjectionSha256 -ceq $expectedLegacyRemovalProjectionHash
) ("count=" + $legacyRemovalLines.Count + "; sha256=" + $legacyRemovalProjectionHash)

$projectionText = @($entries | Sort-Object order | ForEach-Object {
    "{0}|{1}|{2}" -f $_.order, $_.payload, $_.localSha256
}) -join "`n"
$projectionHash = Get-Sha256Text -Text $projectionText
$expectedProjectionHash = "4531B51D514E5286434B46D14C9C7D13CA46E8792334906F3C0059B90B1DA41B"
Check "local payload and hash projection matches independent frozen digest" (
    $projectionHash -ceq $expectedProjectionHash -and
    [string]$map.localProjectionSha256 -ceq $expectedProjectionHash
) $projectionHash

$orders = @($entries | ForEach-Object { [int]$_.order })
$expectedOrders = @(1..23)
Check "mapping orders are exactly 1 through 23" (
    ($orders -join ",") -ceq ($expectedOrders -join ",")
) ($orders -join ",")
Check "payload names are unique" (
    @($entries | Group-Object payload | Where-Object { $_.Count -ne 1 }).Count -eq 0
)
Check "public sources are unique" (
    @($entries | Group-Object publicSource | Where-Object { $_.Count -ne 1 }).Count -eq 0
)
Check "installed destinations are unique" (
    @($entries | Group-Object installedDestination | Where-Object { $_.Count -ne 1 }).Count -eq 0
)

$allowedModes = @(
    "byte-exact",
    "rendered-equivalent",
    "behavior-superset",
    "policy-equivalent",
    "scoped-equivalent"
)
$invalidModes = @($entries | Where-Object { $allowedModes -notcontains [string]$_.mode })
Check "every mapping uses a declared equivalence mode" ($invalidModes.Count -eq 0)
$exactEntries = @($entries | Where-Object { [string]$_.mode -eq "byte-exact" })
Check "portable hardening leaves no byte-exact payload identities" (
    $exactEntries.Count -eq 0
) (($exactEntries | ForEach-Object { [string]$_.payload }) -join ", ")
$misclassifiedExactEntries = @($entries | Where-Object {
    [string]$_.localSha256 -eq [string]$_.publicSha256 -and
    [string]$_.mode -ne "byte-exact"
})
Check "identical local and public hashes use byte-exact mode" ($misclassifiedExactEntries.Count -eq 0) (
    ($misclassifiedExactEntries | ForEach-Object { [string]$_.payload }) -join ", "
)

Check "independent semantic check allowlist covers all 23 payloads" (
    $expectedSemanticChecksByPayload.Count -eq 23
)
$expectedSemanticPayloads = @($expectedSemanticChecksByPayload.Keys | ForEach-Object {
    [string]$_
})
$actualSemanticPayloads = @($entries | ForEach-Object { [string]$_.payload })
Check "semantic check allowlist payload identities and order are exact" (
    ($actualSemanticPayloads -join "`n") -ceq ($expectedSemanticPayloads -join "`n")
) ($actualSemanticPayloads -join ", ")

$expectedSemanticGateByCheck = [Collections.Generic.Dictionary[string,string]]::new(
    [StringComparer]::Ordinal
)
$expectedSemanticGateAssignments.GetEnumerator() | ForEach-Object {
    $expectedSemanticGateByCheck.Add([string]$_.Key, [string]$_.Value)
}
$seenExpectedSemanticChecks = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$duplicateExpectedSemanticChecks = New-Object Collections.Generic.List[string]
$invalidExpectedSemanticChecks = New-Object Collections.Generic.List[string]
foreach ($entry in $entries) {
    $payload = [string]$entry.payload
    $hasSemanticChecks = $entry.PSObject.Properties.Name -contains "semanticChecks"
    $actualSemanticChecks = @()
    if ($hasSemanticChecks) {
        $actualSemanticChecks = @($entry.semanticChecks | ForEach-Object { [string]$_ })
    }
    $expectedSemanticChecks = @($expectedSemanticChecksByPayload[$payload])
    Check ("semantic check array matches independent allowlist: " + $payload) (
        $hasSemanticChecks -and
        ($actualSemanticChecks -join "`n") -ceq ($expectedSemanticChecks -join "`n")
    ) ("expected=" + ($expectedSemanticChecks -join ",") + "; actual=" + ($actualSemanticChecks -join ","))

    if ([string]$entry.mode -eq "byte-exact") {
        Check ("byte-exact mapping declares no semantic marker requirement: " + $payload) (
            $actualSemanticChecks.Count -eq 0
        )
    }
    else {
        Check ("non-byte-exact mapping declares semantic execution evidence: " + $payload) (
            $actualSemanticChecks.Count -gt 0
        )
    }

    foreach ($semanticCheck in $expectedSemanticChecks) {
        $semanticId = [string]$semanticCheck
        if ($semanticId -cnotmatch '^[a-z0-9]+(?:[.-][a-z0-9]+)*$') {
            $invalidExpectedSemanticChecks.Add($semanticId)
        }
        if (-not $seenExpectedSemanticChecks.Add($semanticId)) {
            $duplicateExpectedSemanticChecks.Add($semanticId)
        }
        $expectedGate = if ($expectedSemanticGateByCheck.ContainsKey($semanticId)) {
            $expectedSemanticGateByCheck[$semanticId]
        } else { "" }
        Check ("semantic check gate matches independent allowlist: " + $payload) (
            $expectedGate -and [string]$entry.semanticGate -ceq $expectedGate
        ) ("check=" + $semanticId + "; expected=" + $expectedGate + "; actual=" + [string]$entry.semanticGate)
    }
}
Check "semantic check IDs use the stable marker grammar" (
    $invalidExpectedSemanticChecks.Count -eq 0
) ($invalidExpectedSemanticChecks -join ", ")
Check "semantic check IDs are unique across mapping entries" (
    $duplicateExpectedSemanticChecks.Count -eq 0 -and
    $seenExpectedSemanticChecks.Count -eq 30 -and
    $expectedSemanticGateByCheck.Count -eq 30
) ("duplicates=" + ($duplicateExpectedSemanticChecks -join ",") + "; seen=" + $seenExpectedSemanticChecks.Count + "; gateMap=" + $expectedSemanticGateByCheck.Count)

$gateNames = @($map.semanticGateCatalog.PSObject.Properties | ForEach-Object { $_.Name })
$expectedGateNames = @($expectedSemanticGateCatalog.Keys)
Check "semantic gate catalog contains seven executable gates" ($gateNames.Count -eq 7)
Check "semantic gate catalog names match the independent allowlist" (
    (@($gateNames | Sort-Object) -join "`n") -ceq
    (@($expectedGateNames | Sort-Object) -join "`n")
)
$invalidSemanticGates = @($entries | Where-Object { $gateNames -notcontains [string]$_.semanticGate })
Check "every mapping is bound to a declared semantic gate" ($invalidSemanticGates.Count -eq 0)
foreach ($gateProperty in @($map.semanticGateCatalog.PSObject.Properties)) {
    $gate = $gateProperty.Value
    $expectedGate = $expectedSemanticGateCatalog[$gateProperty.Name]
    Check ("semantic gate script path is safe: " + $gateProperty.Name) (
        (Test-SafeRelativePath -Path ([string]$gate.script)) -and
        (Test-Path -LiteralPath (Join-Path $repoRoot ([string]$gate.script)) -PathType Leaf) -and
        -not [string]::IsNullOrWhiteSpace([string]$gate.expected)
    )
    Check ("semantic gate tuple matches the independent allowlist: " + $gateProperty.Name) (
        $null -ne $expectedGate -and
        [string]$gate.script -ceq [string]$expectedGate["script"] -and
        [string]$gate.expected -ceq [string]$expectedGate["expected"]
    )
}

$supportEntries = @($map.supportInstalls)
Check "support allowlist has exactly 30 entries" ($supportEntries.Count -eq 30)
$supportProjectionText = @($supportEntries | ForEach-Object {
    [string]$_.publicSource + "|" + [string]$_.installedDestination
}) -join "`n"
$supportProjectionSha256 = Get-Sha256Text -Text $supportProjectionText
Check "support source and destination projection matches independent frozen digest" (
    $supportProjectionSha256 -ceq "B51FF007ACDD5E8632AFCA919B0AE5D8A0D7970436465827E34FADB2E8D9F90F"
) $supportProjectionSha256
Check "support source paths are unique except intentional template reuse" (
    @($supportEntries | Group-Object { ([string]$_.publicSource) + "|" + ([string]$_.installedDestination) } | Where-Object { $_.Count -ne 1 }).Count -eq 0
)
Check "support destinations are unique" (
    @($supportEntries | Group-Object installedDestination | Where-Object { $_.Count -ne 1 }).Count -eq 0
)
foreach ($support in $supportEntries) {
    $supportSource = [string]$support.publicSource
    Check ("support source is explicit and present: " + [string]$support.installedDestination) (
        (Test-SafeRelativePath -Path $supportSource) -and
        (Test-Path -LiteralPath (Join-Path $repoRoot $supportSource) -PathType Leaf)
    )
}

$sourcePaths = New-Object Collections.Generic.List[string]
for ($index = 0; $index -lt $entries.Count; $index++) {
    $entry = $entries[$index]
    $sourceRelative = [string]$entry.publicSource
    $sourceSafe = Test-SafeRelativePath -Path $sourceRelative
    Check ("mapping source path is safe: " + [string]$entry.payload) $sourceSafe $sourceRelative
    if (-not $sourceSafe) { continue }
    $sourceFull = [IO.Path]::GetFullPath((Join-Path $repoRoot $sourceRelative))
    $withinRoot = $sourceFull.StartsWith($repoRoot.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase)
    Check ("mapping source stays inside package: " + [string]$entry.payload) $withinRoot $sourceFull
    if (-not $withinRoot) { continue }
    $sourcePaths.Add($sourceFull)
    $sourceExists = Test-Path -LiteralPath $sourceFull -PathType Leaf
    Check ("mapping source exists: " + [string]$entry.payload) $sourceExists $sourceRelative
    if (-not $sourceExists) { continue }

    $expectedHash = ([string]$entry.publicSha256).ToUpperInvariant()
    if ($InjectMappingDrift -and $index -eq 0) {
        $expectedHash = "0" * 64
        Write-Host "MUTATION expected source hash changed"
    }
    $actualHash = Get-Sha256 -Path $sourceFull
    Check ("public source hash is frozen: " + [string]$entry.payload) ($actualHash -ceq $expectedHash) (
        "expected=" + $expectedHash + " actual=" + $actualHash
    )
    Check ("local trace hash is valid: " + [string]$entry.payload) (
        [string]$entry.localSha256 -match "^[A-F0-9]{64}$"
    )
    Check ("equivalence evidence is named: " + [string]$entry.payload) (
        -not [string]::IsNullOrWhiteSpace([string]$entry.evidence)
    )
    if ([string]$entry.mode -eq "byte-exact") {
        Check ("byte-exact local and public hashes match: " + [string]$entry.payload) (
            [string]$entry.localSha256 -ceq [string]$entry.publicSha256
        )
    }
}

$privateHits = New-Object Collections.Generic.List[string]
$userProfilePattern = '(?i)[A-Z]:[\\/]+Users[\\/]+(?!Public(?:[\\/]|$)|Default(?:[\\/]|$)|Default User(?:[\\/]|$)|All Users(?:[\\/]|$)|<[^>]+>)[^\\/\r\n]+'
$nonSystemDrivePattern = '(?i)(?:^|[^A-Z0-9])E:[\\/]'
$slashProfileExample = "C:/Us" + "ers/maintainer/.agent-tools/tool.ps1"
$backslashProfileExample = "C:\Us" + "ers\maintainer\.agent-tools\tool.ps1"
Check "mapped private path detector covers both slash variants" (
    $slashProfileExample -match $userProfilePattern -and
    $backslashProfileExample -match $userProfilePattern
)
foreach ($sourceFull in $sourcePaths) {
    $text = [IO.File]::ReadAllText($sourceFull, [Text.Encoding]::UTF8)
    if ($text -match $userProfilePattern -or $text -match $nonSystemDrivePattern) {
        $privateHits.Add([IO.Path]::GetFullPath($sourceFull))
    }
}
Check "mapped public sources contain no maintainer-private paths" ($privateHits.Count -eq 0) ($privateHits -join ", ")

if (-not $InjectMappingDrift -and -not $InjectSemanticDrift -and
    -not $InjectSupportSubstitution -and -not $InjectRemovalSubstitution -and
    -not $InjectByteExactSubstitution -and
    -not $InjectSemanticCheckSubstitution -and -not $InjectSemanticCheckGateSubstitution -and
    -not $InjectCatalogCaseSetDrift -and -not $InjectHookScopeDrift) {
    $targetRoot = Join-Path $fixtureRoot "steadyagent"
    $codexHome = Join-Path $fixtureRoot "codex"
    $managedConfig = Join-Path $fixtureRoot "managed\requirements.toml"
    $backupRoot = Join-Path $fixtureRoot "backup"
    $gitConfig = Join-Path $fixtureRoot "gitconfig"
    $oldInstallMode = $env:STEADYAGENT_TEST_MODE
    $oldInstallRoot = $env:STEADYAGENT_TEST_ROOT
    try {
        New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
        $packageRoot = Join-Path $fixtureRoot "package"
        Copy-PackageFixture -Destination $packageRoot
        $env:STEADYAGENT_TEST_MODE = "1"
        $env:STEADYAGENT_TEST_ROOT = $fixtureRoot
        $installOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $packageRoot "tools\install.ps1") `
            -TargetRoot $targetRoot `
            -CodexHome $codexHome `
            -ManagedConfigPath $managedConfig `
            -BackupRoot $backupRoot `
            -GitConfigPath $gitConfig `
            -Apply
        $installExit = $LASTEXITCODE
        Check "isolated public installation succeeds" ($installExit -eq 0) (@($installOutput) -join "`n")

        $mappedInstalled = New-Object Collections.Generic.List[string]
        foreach ($entry in $entries) {
            $installed = Get-InstalledPath `
                -Entry $entry `
                -TargetRoot $targetRoot `
                -CodexHome $codexHome `
                -ManagedConfigPath $managedConfig
            $mappedInstalled.Add([IO.Path]::GetFullPath($installed))
            $exists = Test-Path -LiteralPath $installed -PathType Leaf
            Check ("mapped destination is installed: " + [string]$entry.payload) $exists $installed
            if (-not $exists) { continue }
            $source = Join-Path $repoRoot ([string]$entry.publicSource)
            if ([string]$entry.installedDestination -eq "@managedConfig") {
                $template = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8)
                $renderedHome = [IO.Path]::GetFullPath($targetRoot).Replace("\", "\\")
                $expectedText = $template.Replace("%STEADYAGENT_HOME_JSON%", $renderedHome)
                $expectedText = $expectedText.Replace("%STEADYAGENT_HOME%", [IO.Path]::GetFullPath($targetRoot))
                $actualText = [IO.File]::ReadAllText($installed, [Text.Encoding]::UTF8)
                Check ("rendered destination matches contract: " + [string]$entry.payload) (
                    $actualText -ceq $expectedText
                )
            }
            else {
                Check ("installed bytes match public source: " + [string]$entry.payload) (
                    (Get-Sha256 -Path $installed) -ceq (Get-Sha256 -Path $source)
                )
            }
        }
        Check "installed mapped destinations remain unique" (
            @($mappedInstalled | Sort-Object -Unique).Count -eq 23
        )

        $supportInstalled = New-Object Collections.Generic.List[string]
        foreach ($support in $supportEntries) {
            $installed = Get-InstalledPath `
                -Entry $support `
                -TargetRoot $targetRoot `
                -CodexHome $codexHome `
                -ManagedConfigPath $managedConfig
            $supportInstalled.Add([IO.Path]::GetFullPath($installed))
            $exists = Test-Path -LiteralPath $installed -PathType Leaf
            Check ("support destination is installed: " + [string]$support.installedDestination) $exists $installed
            if (-not $exists) { continue }
            $source = Join-Path $repoRoot ([string]$support.publicSource)
            $sourceText = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8)
            if ($sourceText.Contains("%STEADYAGENT_HOME%") -or
                $sourceText.Contains("%STEADYAGENT_HOME_JSON%")) {
                $renderedHome = [IO.Path]::GetFullPath($targetRoot).Replace("\", "\\")
                $expectedText = $sourceText.Replace("%STEADYAGENT_HOME_JSON%", $renderedHome)
                $expectedText = $expectedText.Replace("%STEADYAGENT_HOME%", [IO.Path]::GetFullPath($targetRoot))
                $actualText = [IO.File]::ReadAllText($installed, [Text.Encoding]::UTF8)
                Check ("support rendered bytes match source: " + [string]$support.installedDestination) (
                    $actualText -ceq $expectedText
                )
            }
            else {
                Check ("support installed bytes match source: " + [string]$support.installedDestination) (
                    (Get-Sha256 -Path $installed) -ceq (Get-Sha256 -Path $source)
                )
            }
        }
        Check "installed support destinations remain unique" (
            @($supportInstalled | Sort-Object -Unique).Count -eq [int]$map.supportInstallCount
        )

        $expectedInstalledHookRoot = [IO.Path]::GetFullPath($targetRoot)
        $installedHookSuite = Join-Path $targetRoot "tools\test-agent-hooks.ps1"
        $oldHookGateMode = $env:STEADYAGENT_EQUIVALENCE_TEST_MODE
        try {
            $env:STEADYAGENT_EQUIVALENCE_TEST_MODE = "1"
            $installedHookGateOutput = @(
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installedHookSuite
            )
            $installedHookGateExit = $LASTEXITCODE
        }
        finally {
            if ($null -eq $oldHookGateMode) {
                Remove-Item Env:\STEADYAGENT_EQUIVALENCE_TEST_MODE -ErrorAction SilentlyContinue
            }
            else {
                $env:STEADYAGENT_EQUIVALENCE_TEST_MODE = $oldHookGateMode
            }
        }

        $receiptPath = Join-Path $backupRoot "migration-receipt.json"
        $receiptExists = Test-Path -LiteralPath $receiptPath -PathType Leaf
        Check "installer writes a transaction receipt" $receiptExists
        if ($receiptExists) {
            $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $installs = @($receipt.entries | Where-Object { [string]$_.action -eq "install" })
            $removals = @($receipt.entries | Where-Object { [string]$_.action -eq "remove" })
            Check "receipt explains all 53 installed destinations" ($installs.Count -eq [int]$map.totalInstallCount) ([string]$installs.Count)
            $expectedDestinations = @($mappedInstalled.ToArray()) + @($supportInstalled.ToArray())
            $expectedSet = @($expectedDestinations | ForEach-Object {
                [IO.Path]::GetFullPath($_).ToLowerInvariant()
            } | Sort-Object -Unique)
            $actualSet = @($installs | ForEach-Object {
                [IO.Path]::GetFullPath([string]$_.destination).ToLowerInvariant()
            } | Sort-Object -Unique)
            $missingDestinations = @($expectedSet | Where-Object { $actualSet -notcontains $_ })
            $unexplainedDestinations = @($actualSet | Where-Object { $expectedSet -notcontains $_ })
            Check "mapped plus support destination allowlist is exact" (
                $expectedSet.Count -eq [int]$map.totalInstallCount -and
                $actualSet.Count -eq [int]$map.totalInstallCount -and
                $missingDestinations.Count -eq 0 -and
                $unexplainedDestinations.Count -eq 0
            ) ("missing=" + ($missingDestinations -join ",") + "; unexplained=" + ($unexplainedDestinations -join ","))
            Check "receipt explains all 27 legacy removals" ($removals.Count -eq [int]$map.legacyRemovalCount) ([string]$removals.Count)
        }
    }
    finally {
        if ($null -eq $oldInstallMode) { Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_MODE = $oldInstallMode }
        if ($null -eq $oldInstallRoot) { Remove-Item Env:\STEADYAGENT_TEST_ROOT -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_ROOT = $oldInstallRoot }
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\") + "\"
        $fixtureFull = [IO.Path]::GetFullPath($fixtureRoot)
        if ($fixtureFull.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $fixtureFull).StartsWith("steadyagent-v2-migration-", [StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $fixtureFull -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $InjectMappingDrift -and -not $InjectSemanticDrift -and -not $InjectSupportSubstitution -and
    -not $InjectRemovalSubstitution -and -not $InjectByteExactSubstitution -and
    -not $InjectSemanticCheckSubstitution -and -not $InjectSemanticCheckGateSubstitution -and
    -not $InjectCatalogCaseSetDrift -and -not $InjectHookScopeDrift) {
    $observedSemanticMarkers = New-Object Collections.Generic.List[object]
    $hookGateText = ""
    $semanticGateProperties = @($map.semanticGateCatalog.PSObject.Properties | Sort-Object Name)
    foreach ($gateProperty in $semanticGateProperties) {
        $gate = $gateProperty.Value
        if ([string]$gateProperty.Name -ceq "hooks") {
            $gateOutput = @($installedHookGateOutput)
            $gateExit = $installedHookGateExit
        }
        else {
            $gateOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $repoRoot ([string]$gate.script))
            $gateExit = $LASTEXITCODE
        }
        $gateText = @($gateOutput) -join "`n"
        Check ("semantic behavior gate passes: " + $gateProperty.Name) (
            $gateExit -eq 0 -and $gateText -match [string]$gate.expected
        ) $gateText
        if ([string]$gateProperty.Name -ceq "skills") {
            $expectedCatalogCaseSetLine = (
                "CASESET PASS catalog.required-suite-executed count=" +
                $expectedCatalogDefaultCaseCount + " sha256=" +
                $expectedCatalogDefaultCaseSetSha256
            )
            Check "catalog semantic marker carries the independent 69-case set digest" (
                @($gateText -split '\r?\n' | Where-Object {
                    [string]$_ -ceq $expectedCatalogCaseSetLine
                }).Count -eq 1
            ) $gateText
        }
        if ([string]$gateProperty.Name -ceq "hooks") {
            $hookGateText = $gateText
            $expectedHookCaseSetLine = (
                "CASESET PASS hooks.codex-active-retained-assertions count=" +
                $expectedHookScopeRetainedCount + " sha256=" +
                $expectedHookScopeRetainedSha256 + " binding_sha256=" +
                $expectedHookEvidenceBindingSha256
            )
            Check "Hook semantic marker carries the independent 65-assertion binding digest" (
                @($gateText -split '\r?\n' | Where-Object {
                    [string]$_ -ceq $expectedHookCaseSetLine
                }).Count -eq 1
            ) $gateText
        }
        foreach ($gateLine in @($gateText -split '\r?\n')) {
            if ($gateLine -cmatch '^SEMANTIC PASS (?<id>[a-z0-9]+(?:[.-][a-z0-9]+)*)$') {
                $observedSemanticMarkers.Add([pscustomobject]@{
                    Id = [string]$Matches["id"]
                    Gate = [string]$gateProperty.Name
                })
            }
            elseif ($gateLine.StartsWith("SEMANTIC PASS", [StringComparison]::Ordinal)) {
                $observedSemanticMarkers.Add([pscustomobject]@{
                    Id = "__malformed__:" + $gateLine
                    Gate = [string]$gateProperty.Name
                })
            }
        }
    }

    $semanticMarkerAudit = Get-SemanticMarkerAudit `
        -ObservedMarkers @($observedSemanticMarkers.ToArray()) `
        -ExpectedGateById $expectedSemanticGateByCheck
    Check "semantic execution markers are complete, unique, known, and emitted by the declared gate" (
        [bool]$semanticMarkerAudit.Passed
    ) ([string]$semanticMarkerAudit.Detail)

    $hookEvidenceAudit = Get-HookEvidenceAudit `
        -GateText $hookGateText `
        -RetainedMappings $actualHookRetainedMappings
    Check "all retained Hook assertions bind to the single suite's passing public evidence" (
        [bool]$hookEvidenceAudit.Passed
    ) ([string]$hookEvidenceAudit.Detail)

    if (-not $InternalVerify) {
        $droppedHookCase = "managed template retains SessionStart"
        $droppedHookEvidenceAudit = Get-HookEvidenceAudit `
            -GateText $hookGateText `
            -RetainedMappings $actualHookRetainedMappings `
            -DropCase $droppedHookCase
        Check "missing retained Hook runtime evidence makes the evidence audit red" (
            -not [bool]$droppedHookEvidenceAudit.Passed -and
            [bool]$droppedHookEvidenceAudit.DropApplied -and
            @($droppedHookEvidenceAudit.Missing | Where-Object {
                [string]$_ -like ("*=>" + $droppedHookCase)
            }).Count -gt 0
        ) ([string]$droppedHookEvidenceAudit.Detail)
    }

    if (-not $InternalVerify) {
        $oldMarkerAuditMode = $env:STEADYAGENT_EQUIVALENCE_TEST_MODE
        $oldMarkerFilter = [Environment]::GetEnvironmentVariable(
            "STEADYAGENT_EQUIVALENCE_FILTER_SEMANTIC_MARKER"
        )
        try {
            $filteredMarkerId = "migration.rendered-three-block-unified-matrix"
            $env:STEADYAGENT_EQUIVALENCE_TEST_MODE = "1"
            $env:STEADYAGENT_EQUIVALENCE_FILTER_SEMANTIC_MARKER = $filteredMarkerId
            $filteredSemanticAudit = Get-SemanticMarkerAudit `
                -ObservedMarkers @($observedSemanticMarkers.ToArray()) `
                -ExpectedGateById $expectedSemanticGateByCheck
            Check "missing semantic execution marker makes the evidence gate red" (
                -not [bool]$filteredSemanticAudit.Passed -and
                [bool]$filteredSemanticAudit.FilterApplied -and
                @($filteredSemanticAudit.Missing) -contains $filteredMarkerId
            ) ([string]$filteredSemanticAudit.Detail)
        }
        finally {
            if ($null -eq $oldMarkerAuditMode) {
                Remove-Item Env:\STEADYAGENT_EQUIVALENCE_TEST_MODE -ErrorAction SilentlyContinue
            }
            else {
                $env:STEADYAGENT_EQUIVALENCE_TEST_MODE = $oldMarkerAuditMode
            }
            if ($null -eq $oldMarkerFilter) {
                Remove-Item Env:\STEADYAGENT_EQUIVALENCE_FILTER_SEMANTIC_MARKER -ErrorAction SilentlyContinue
            }
            else {
                $env:STEADYAGENT_EQUIVALENCE_FILTER_SEMANTIC_MARKER = $oldMarkerFilter
            }
        }
    }
}

if (-not $InternalVerify) {
    $hookInvocationLines = @(
        [IO.File]::ReadAllLines($hookInvocationLedgerPath, [Text.Encoding]::UTF8) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    Check "Hook invocation ledger reports exactly one authoritative suite run" (
        $hookInvocationLines.Count -eq 1 -and
        [string]$hookInvocationLines[0] -ceq ("hooks|" + $expectedInstalledHookRoot)
    ) ($hookInvocationLines -join ",")
    Clear-HookInvocationLedger
}

Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

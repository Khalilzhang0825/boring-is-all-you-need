[CmdletBinding()]
param(
    [switch]$InternalVerify,
    [switch]$InjectMappingDrift,
    [switch]$InjectSemanticDrift,
    [switch]$InjectSupportSubstitution
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Passed = 0
$script:Failed = 0
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$mapPath = Join-Path $repoRoot "manifests\local-postimage-equivalence.json"
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("steadyagent-equivalence-" + [guid]::NewGuid().ToString("N"))

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

if (($InjectMappingDrift -or $InjectSemanticDrift -or $InjectSupportSubstitution) -and
    $env:STEADYAGENT_EQUIVALENCE_TEST_MODE -ne "1") {
    throw "Mapping drift injection is available only to the isolated equivalence test."
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
            $supportText -match "RESULT pass=\d+ fail=[1-9]\d*"
        ) $supportText
    }
    finally {
        if ($null -eq $oldMode) { Remove-Item Env:\STEADYAGENT_EQUIVALENCE_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_EQUIVALENCE_TEST_MODE = $oldMode }
    }
}

$map = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json
$entries = @($map.entries)
$expectedSemanticGateCatalog = [ordered]@{
    migration = [ordered]@{ script = "tools/test-v2-migration.ps1"; expected = "fail=0" }
    hooks = [ordered]@{ script = "tools/test-agent-hooks.ps1"; expected = "fail=0" }
    checkpoint = [ordered]@{ script = "tools/test-git-checkpoint.ps1"; expected = "0 failed" }
    skills = [ordered]@{ script = "tools/test-skill-catalog.ps1"; expected = "0 failed" }
    precommit = [ordered]@{ script = "tools/test-pre-commit.ps1"; expected = "0 failed" }
    policy = [ordered]@{ script = "tools/test-equivalence-contract.ps1"; expected = "fail=0" }
    protected_paths = [ordered]@{ script = "tools/test-protected-path-policy.ps1"; expected = "0 failed" }
}
if ($InjectSemanticDrift) {
    $map.semanticGateCatalog.migration.script = "tools/test-equivalence-contract.ps1"
    Write-Host "MUTATION semantic gate catalog substituted"
}
if ($InjectSupportSubstitution) {
    $map.supportInstalls[0].installedDestination = "@codex/unexplained-substitute.md"
    Write-Host "MUTATION support destination substituted"
}
Check "equivalence schema is v1" ([int]$map.schemaVersion -eq 1)
Check "release identity is v2.0.0" ([string]$map.release -eq "v2.0.0")
Check "canonical local manifest SHA-256 is frozen" (
    [string]$map.localPostimageManifestSha256 -eq "A76846A184673C176F2FE2FE22B14835D216CA79824CB2F0ABF583B0F91D89FF"
)
Check "all 23 local postimage entries are mapped" ($entries.Count -eq 23) ([string]$entries.Count)
Check "mapped install count is 23" ([int]$map.mappedInstallCount -eq 23)
Check "support install count is explicitly 29" ([int]$map.supportInstallCount -eq 29)
Check "total install count is explicitly 52" ([int]$map.totalInstallCount -eq 52)
Check "legacy removal count is explicitly 27" ([int]$map.legacyRemovalCount -eq 27)

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

$allowedModes = @("byte-exact", "rendered-equivalent", "behavior-superset", "policy-equivalent")
$invalidModes = @($entries | Where-Object { $allowedModes -notcontains [string]$_.mode })
Check "every mapping uses a declared equivalence mode" ($invalidModes.Count -eq 0)
$exactEntries = @($entries | Where-Object { [string]$_.mode -eq "byte-exact" })
Check "fixed byte-exact surface contains two entries" ($exactEntries.Count -eq 2)

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
Check "support allowlist has exactly 29 entries" ($supportEntries.Count -eq 29)
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
$userProfilePattern = '(?i)[A-Z]:\\Users\\(?!Public(?:\\|$)|Default(?:\\|$)|Default User(?:\\|$)|All Users(?:\\|$)|<[^>]+>)[^\\\r\n]+'
$nonSystemDrivePrefix = "E:" + [char]92
foreach ($sourceFull in $sourcePaths) {
    $text = [IO.File]::ReadAllText($sourceFull, [Text.Encoding]::UTF8)
    if ($text -match $userProfilePattern -or $text.Contains($nonSystemDrivePrefix)) {
        $privateHits.Add([IO.Path]::GetFullPath($sourceFull))
    }
}
Check "mapped public sources contain no maintainer-private paths" ($privateHits.Count -eq 0) ($privateHits -join ", ")

if (-not $InjectMappingDrift -and -not $InjectSemanticDrift) {
    $targetRoot = Join-Path $fixtureRoot "steadyagent"
    $codexHome = Join-Path $fixtureRoot "codex"
    $managedConfig = Join-Path $fixtureRoot "managed\requirements.toml"
    $backupRoot = Join-Path $fixtureRoot "backup"
    $gitConfig = Join-Path $fixtureRoot "gitconfig"
    $oldInstallMode = $env:STEADYAGENT_TEST_MODE
    try {
        New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
        $env:STEADYAGENT_TEST_MODE = "1"
        $installOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "install.ps1") `
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

        $receiptPath = Join-Path $backupRoot "migration-receipt.json"
        $receiptExists = Test-Path -LiteralPath $receiptPath -PathType Leaf
        Check "installer writes a transaction receipt" $receiptExists
        if ($receiptExists) {
            $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $installs = @($receipt.entries | Where-Object { [string]$_.action -eq "install" })
            $removals = @($receipt.entries | Where-Object { [string]$_.action -eq "remove" })
            Check "receipt explains all 52 installed destinations" ($installs.Count -eq [int]$map.totalInstallCount) ([string]$installs.Count)
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
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\") + "\"
        $fixtureFull = [IO.Path]::GetFullPath($fixtureRoot)
        if ($fixtureFull.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $fixtureFull).StartsWith("steadyagent-equivalence-", [StringComparison]::Ordinal)) {
            Remove-Item -LiteralPath $fixtureFull -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $InjectMappingDrift -and -not $InjectSemanticDrift -and -not $InjectSupportSubstitution) {
    foreach ($gateProperty in @($map.semanticGateCatalog.PSObject.Properties | Sort-Object Name)) {
        $gate = $gateProperty.Value
        $gateOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot ([string]$gate.script))
        $gateExit = $LASTEXITCODE
        $gateText = @($gateOutput) -join "`n"
        Check ("semantic behavior gate passes: " + $gateProperty.Name) (
            $gateExit -eq 0 -and $gateText -match [string]$gate.expected
        ) $gateText
    }
}

Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

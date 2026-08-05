[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Query,
    [string]$JsonPath,
    [ValidateSet("Auto", "CodexDesktop", "CodexCli")]
    [string]$HostSurface = "Auto",
    [string]$ThreadId = $env:CODEX_THREAD_ID,
    [string]$CatalogRoot,
    [int]$Top = 12,
    [switch]$NoRebuild,
    [switch]$AllowFixtureCatalog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "skill-catalog-resolver.ps1")
if ([string]::IsNullOrWhiteSpace($CatalogRoot)) {
    $CatalogRoot = Get-DefaultCatalogRoot
}

$catalog = $null

if ($JsonPath) {
    $expectedHost = Resolve-CatalogHostName -HostSurface $HostSurface
    if (-not $AllowFixtureCatalog) {
        [Console]::Error.WriteLine("Custom JsonPath requires AllowFixtureCatalog and is never accepted as Live runtime evidence.")
        exit 2
    }
    if (Test-Path -LiteralPath $JsonPath -PathType Leaf) {
        try { $catalog = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if ($null -eq $catalog -or
        [int]$catalog.schema_version -ne 2 -or
        [string]$catalog.visibility -ne "fixture-confirmed" -or
        [string]$catalog.host -ne $expectedHost -or
        [string]$catalog.thread_id -ne $ThreadId -or
        [string]$catalog.skills_sha256 -ne (Get-CatalogSkillsDigest -Skills @($catalog.skills))) {
        [Console]::Error.WriteLine("Fixture catalog is missing or does not match the requested host/thread.")
        exit 2
    }
} else {
    if ([string]::IsNullOrWhiteSpace([string]$env:CODEX_THREAD_ID)) {
        [Console]::Error.WriteLine("Production catalog search requires CODEX_THREAD_ID from the current Codex task.")
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($ThreadId) -or $ThreadId -cne [string]$env:CODEX_THREAD_ID) {
        [Console]::Error.WriteLine("ThreadId must match CODEX_THREAD_ID from the current Codex task.")
        exit 2
    }
    $expected = $null
    try {
        $expected = Resolve-BoundRolloutFileCatalogSnapshot `
            -HostSurface $HostSurface `
            -ThreadId $ThreadId `
            -CatalogRoot $CatalogRoot
    } catch {
        if ($NoRebuild) {
            [Console]::Error.WriteLine(("Cannot resolve bound rollout-file catalog: {0}" -f $_.Exception.Message))
            exit 2
        }
        & (Join-Path $PSScriptRoot "skill-index.ps1") `
            -HostSurface $HostSurface `
            -ThreadId $ThreadId `
            -CatalogRoot $CatalogRoot | Out-Null
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("Rollout-file catalog initial build failed.")
            exit 2
        }
        try {
            $expected = Resolve-BoundRolloutFileCatalogSnapshot `
                -HostSurface $HostSurface `
                -ThreadId $ThreadId `
                -CatalogRoot $CatalogRoot
        } catch {
            [Console]::Error.WriteLine(("Cannot resolve newly built rollout-file catalog: {0}" -f $_.Exception.Message))
            exit 2
        }
    }
    if (-not (Test-RolloutFileCatalogSnapshot -Expected $expected)) {
        [Console]::Error.WriteLine(("Bound rollout-file catalog or owning rollout evidence is invalid: {0}" -f $expected.SnapshotId))
        exit 2
    }
    $JsonPath = $expected.JsonPath
    $catalog = $expected.Catalog
}

function Convert-CodePointsToText {
    param([int[]]$CodePoints)
    return (($CodePoints | ForEach-Object { [char]::ConvertFromUtf32($_) }) -join "")
}

$queryLower = $Query.ToLowerInvariant()
$termList = New-Object System.Collections.Generic.List[string]
foreach ($term in @($queryLower -split "\s+" | Where-Object { $_.Trim().Length -gt 0 })) {
    $termList.Add($term)
}

$localizedAliases = [ordered]@{}
$localizedAliases[(Convert-CodePointsToText @(0x4EE3,0x7801,0x5BA1,0x67E5))] = @("code", "review")
$localizedAliases[(Convert-CodePointsToText @(0x8868,0x683C))] = @("spreadsheet", "excel", "xlsx")
$localizedAliases[(Convert-CodePointsToText @(0x6587,0x6863))] = @("document", "docx")
$localizedAliases[(Convert-CodePointsToText @(0x5E7B,0x706F,0x7247))] = @("presentation", "slides", "pptx")
$localizedAliases[(Convert-CodePointsToText @(0x8BBA,0x6587))] = @("academic", "paper")
$localizedAliases[(Convert-CodePointsToText @(0x6570,0x636E,0x5206,0x6790))] = @("data", "analytics")

foreach ($alias in $localizedAliases.Keys) {
    if ($queryLower.Contains([string]$alias)) {
        foreach ($expandedTerm in @($localizedAliases[$alias])) {
            $termList.Add([string]$expandedTerm)
        }
    }
}
$terms = @($termList | Select-Object -Unique)
$ranked = foreach ($skill in @($catalog.skills)) {
    $name = [string]$skill.name
    $description = [string]$skill.description
    $nameLower = $name.ToLowerInvariant()
    $descriptionLower = $description.ToLowerInvariant()
    $score = 0
    foreach ($term in $terms) {
        if ($nameLower.Contains($term)) { $score += 5 }
        if ($descriptionLower.Contains($term)) { $score += 2 }
    }
    if ($score -gt 0) {
        [pscustomobject]@{
            score = $score
            name = $name
            source = [string]$skill.source_kind
            description = $description
            path = [string]$skill.path
        }
    }
}

$matches = @($ranked |
    Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "name"; Ascending = $true } |
    Select-Object -First $Top)

foreach ($match in $matches) {
    $skillPath = [string]$match.path
    if (-not [IO.Path]::IsPathRooted($skillPath) -or
        (Split-Path -Leaf $skillPath) -cne "SKILL.md" -or
        -not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        [Console]::Error.WriteLine(
            "Matched skill path is not an existing absolute SKILL.md file; no results were emitted."
        )
        exit 2
    }
}

for ($index = 0; $index -lt $matches.Count; $index++) {
    $match = $matches[$index]
    Write-Output ("Name: " + [string]$match.name)
    Write-Output ("Score: " + [string]$match.score)
    Write-Output ("Source: " + [string]$match.source)
    Write-Output ("Description: " + [string]$match.description)
    Write-Output ("SKILL.md: " + [IO.Path]::GetFullPath([string]$match.path))
    if ($index -lt $matches.Count - 1) { Write-Output "" }
}

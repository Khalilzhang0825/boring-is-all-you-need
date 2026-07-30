[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Query,
    [string]$JsonPath,
    [ValidateSet("Auto", "CodexDesktop", "CodexCli")]
    [string]$HostSurface = "Auto",
    [string]$ThreadId = $env:CODEX_THREAD_ID,
    [string]$CatalogRoot = (Join-Path $env:USERPROFILE ".steadyagent\runtime-skill-catalogs"),
    [int]$Top = 12,
    [switch]$NoRebuild,
    [switch]$AllowFixtureCatalog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "skill-catalog-resolver.ps1")

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
    try {
        $expected = Resolve-RuntimeCatalogSnapshot `
            -HostSurface $HostSurface `
            -ThreadId $ThreadId `
            -CatalogRoot $CatalogRoot
    } catch {
        [Console]::Error.WriteLine(("Cannot resolve current runtime catalog identity: {0}" -f $_.Exception.Message))
        exit 2
    }
    if (-not (Test-RuntimeCatalogSnapshot -Expected $expected)) {
        if ($NoRebuild) {
            [Console]::Error.WriteLine(("Runtime catalog mismatch: expected {0}" -f $expected.SnapshotId))
            exit 2
        }
        & (Join-Path $PSScriptRoot "skill-index.ps1") -HostSurface $HostSurface -ThreadId $ThreadId -CatalogRoot $CatalogRoot -RepairExisting | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-RuntimeCatalogSnapshot -Expected $expected)) {
            [Console]::Error.WriteLine(("Runtime catalog rebuild failed identity verification: {0}" -f $expected.SnapshotId))
            exit 2
        }
    }
    $JsonPath = $expected.JsonPath
    $catalog = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
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

$ranked |
    Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "name"; Ascending = $true } |
    Select-Object -First $Top |
    Format-Table score, name, source, description -AutoSize

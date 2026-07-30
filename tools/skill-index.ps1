[CmdletBinding()]
param(
    [ValidateSet("Auto", "CodexDesktop", "CodexCli")]
    [string]$HostSurface = "Auto",
    [string]$ThreadId = $env:CODEX_THREAD_ID,
    [string]$RolloutPath,
    [switch]$FixtureMode,
    [switch]$RepairExisting,
    [string]$MarkdownPath,
    [string]$JsonPath,
    [string]$CatalogRoot = (Join-Path $env:USERPROFILE ".steadyagent\runtime-skill-catalogs"),
    [int]$MaxDescriptionLength = 220
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot "skill-catalog-resolver.ps1")

function Get-HostVersion {
    param([string]$HostName)
    $binary = $(if ($env:CODEX_BINARY) { $env:CODEX_BINARY } else { "codex" })
    try {
        if ($binary -ne "codex" -and -not (Test-Path -LiteralPath $binary -PathType Leaf)) { return "unknown" }
        $raw = @(& $binary --version 2>$null) -join " "
        if ($raw -match "([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?)") { return $Matches[1] }
    } catch { }
    return "unknown"
}

function Write-AtomicUtf8 {
    param([string]$Path, [string]$Content)
    $directory = Split-Path -Parent $Path
    if (-not $directory) { $directory = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $temp = Join-Path $directory ((Split-Path -Leaf $Path) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::WriteAllText($temp, $Content, (New-Object Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

if ($RolloutPath -and -not $FixtureMode) { throw "RolloutPath is available only with FixtureMode." }
if ($FixtureMode -and -not $RolloutPath) { throw "FixtureMode requires RolloutPath." }
if ($FixtureMode) {
    $hostName = Resolve-CatalogHostName -HostSurface $HostSurface
    $resolvedRollout = [IO.Path]::GetFullPath($RolloutPath)
    if (-not (Test-Path -LiteralPath $resolvedRollout -PathType Leaf)) { throw "Rollout fixture does not exist." }
} else {
    $resolvedRollout = Find-CatalogRollout -ThreadId $ThreadId
}
$rolloutLines = @(Read-CatalogRolloutLines -Path $resolvedRollout)
if (-not $FixtureMode) {
    $hostName = Resolve-CatalogHostForRollout `
        -HostSurface $HostSurface `
        -RolloutPath $resolvedRollout `
        -ThreadId $ThreadId `
        -RolloutLines $rolloutLines
}

$skillsBlock = Get-CatalogSkillsBlock -RolloutPath $resolvedRollout -RolloutLines $rolloutLines
$skills = @(Get-CatalogSkillsFromBlock -Block $skillsBlock -MaxDescriptionLength $MaxDescriptionLength)
$promptHash = Get-CatalogSha256 -Text $skillsBlock
$skillsHash = Get-CatalogSkillsDigest -Skills $skills
$snapshotId = $hostName + ":" + $ThreadId + ":" + $promptHash
$catalog = [pscustomobject][ordered]@{
    schema_version = 2
    snapshot_id = $snapshotId
    host = $hostName
    host_version = Get-HostVersion -HostName $hostName
    visibility = $(if ($FixtureMode) { "fixture-confirmed" } else { "runtime-confirmed" })
    thread_id = $ThreadId
    skills_prompt_sha256 = $promptHash
    skills_sha256 = $skillsHash
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    skills = $skills
}

$json = $catalog | ConvertTo-Json -Depth 6
$markdown = Get-CatalogMarkdown -Catalog $catalog

$defaultOutput = (-not $JsonPath -and -not $MarkdownPath)
if ((-not $JsonPath) -xor (-not $MarkdownPath)) { throw "JsonPath and MarkdownPath must be supplied together." }
if ($defaultOutput) {
    $threadRoot = Join-Path (Join-Path $CatalogRoot $hostName) $ThreadId
    $finalDirectory = Join-Path $threadRoot $promptHash
    $JsonPath = Join-Path $finalDirectory "skill-index.json"
    $MarkdownPath = Join-Path $finalDirectory "skill-index.md"
    $expected = [pscustomobject]@{
        Host = $hostName
        ThreadId = $ThreadId
        PromptHash = $promptHash
        SkillsHash = $skillsHash
        SnapshotId = $snapshotId
        JsonPath = $JsonPath
        MarkdownPath = $MarkdownPath
    }
    $mutexHash = Get-CatalogSha256 -Text ([IO.Path]::GetFullPath($finalDirectory).ToLowerInvariant())
    $mutex = New-Object Threading.Mutex($false, ("Local\CodexSkillCatalog_" + $mutexHash))
    $lockTaken = $false
    try {
        try { $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [Threading.AbandonedMutexException] { $lockTaken = $true }
        if (-not $lockTaken) { throw "Timed out waiting for the runtime catalog publisher lock." }
        if (-not $FixtureMode -and (Test-Path -LiteralPath $finalDirectory -PathType Container) -and
            -not (Test-RuntimeCatalogSnapshot -Expected $expected)) {
            if (-not $RepairExisting) { throw "Existing runtime snapshot is invalid; repair was not authorized." }
            $quarantine = Join-Path $threadRoot (".corrupt." + [guid]::NewGuid().ToString("N"))
            [IO.Directory]::Move($finalDirectory, $quarantine)
            Write-Host ("Quarantined invalid snapshot: {0}" -f $quarantine)
        }
        if (-not (Test-Path -LiteralPath $finalDirectory -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $threadRoot | Out-Null
            $tempDirectory = Join-Path $threadRoot (".tmp." + [guid]::NewGuid().ToString("N"))
            try {
                New-Item -ItemType Directory -Path $tempDirectory | Out-Null
                [IO.File]::WriteAllText((Join-Path $tempDirectory "skill-index.json"), $json, (New-Object Text.UTF8Encoding($true)))
                [IO.File]::WriteAllText((Join-Path $tempDirectory "skill-index.md"), $markdown, (New-Object Text.UTF8Encoding($true)))
                [IO.Directory]::Move($tempDirectory, $finalDirectory)
            } finally {
                if (Test-Path -LiteralPath $tempDirectory) { Remove-Item -LiteralPath $tempDirectory -Recurse -Force }
            }
        }
        if (-not (Test-RuntimeCatalogSnapshot -Expected $expected) -and -not $FixtureMode) {
            throw "Published runtime snapshot failed identity verification."
        }
    } finally {
        if ($lockTaken) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
} else {
    Write-AtomicUtf8 -Path $JsonPath -Content $json
    Write-AtomicUtf8 -Path $MarkdownPath -Content $markdown
}
Write-Host ("Indexed {0} {1} skills for {2}." -f $skills.Count, $catalog.visibility, $hostName)
Write-Host ("Thread: {0}" -f $ThreadId)
Write-Host ("JSON: {0}" -f $JsonPath)

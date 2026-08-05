[CmdletBinding()]
param(
    [switch]$IntegrityOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:Passed = 0
$script:Failed = 0

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

function Remove-MarkdownFencedCode {
    param([string]$Text)
    $insideFence = $false
    $kept = New-Object Collections.Generic.List[string]
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line -match '^\s*(?:`{3,}|~{3,})') {
            $insideFence = -not $insideFence
            $kept.Add("") | Out-Null
            continue
        }
        if ($insideFence) { $kept.Add("") | Out-Null }
        else { $kept.Add([string]$line) | Out-Null }
    }
    return $kept.ToArray() -join "`n"
}

function Run-Gate {
    param([string]$Name, [string]$Path, [string]$Expected)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path
    $code = $LASTEXITCODE
    $text = @($output) -join "`n"
    Check $Name ($code -eq 0 -and $text -match $Expected) $text
}

Push-Location $root
try {
    if ($IntegrityOnly) { Write-Host "MODE integrity-only" }
    else { Write-Host "MODE full" }

    $required = @(
        "README.md",
        "README.zh-CN.md",
        "RELEASE_NOTES.md",
        "SECURITY.md",
        "package-assets.sha256",
        "release-files.txt",
        "templates/codex/AGENTS.md",
        "templates/codex/hooks.empty.json",
        "templates/codex/requirements.managed-hooks.example.toml",
        "manifests/local-postimage-equivalence.json",
        "manifests/v1-codex-owned-files.txt",
        "tools/install.ps1",
        "tools/rollback.ps1",
        "tools/diagnose-install.ps1",
        "tools/validate-phase3.ps1",
        "tools/validate-runtime-slice.ps1",
        "tools/validate-release-archive.ps1",
        ".github/workflows/validate.yml",
        ".github/workflows/release.yml"
    )
    foreach ($relative in $required) {
        Check ("archive asset: " + $relative) (Test-Path -LiteralPath $relative -PathType Leaf)
    }
    Check "archive contains no Git metadata" (-not (Test-Path -LiteralPath (Join-Path $root ".git")))

    $inventoryPath = Join-Path $root "release-files.txt"
    $inventory = @(
        [IO.File]::ReadAllLines($inventoryPath, [Text.Encoding]::UTF8) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $sortedInventory = [string[]]@($inventory)
    [Array]::Sort($sortedInventory, [StringComparer]::Ordinal)
    $inventoryCaseFolded = @($inventory | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $inventoryInvalid = @($inventory | Where-Object {
        [IO.Path]::IsPathRooted($_) -or $_.Contains('\') -or $_ -match '(^|/)[.][.](/|$)'
    })
    $archiveFiles = @(
        Get-ChildItem -LiteralPath $root -Recurse -File -Force |
            ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') }
    )
    [Array]::Sort($archiveFiles, [StringComparer]::Ordinal)
    Check "release inventory is canonical, unique, and complete" (
        $inventory.Count -gt 0 -and
        $inventory.Count -eq $inventoryCaseFolded.Count -and
        $inventoryInvalid.Count -eq 0 -and
        @(Compare-Object $inventory $sortedInventory -SyncWindow 0).Count -eq 0 -and
        @(Compare-Object $inventory $archiveFiles -SyncWindow 0).Count -eq 0
    ) ((Compare-Object $inventory $archiveFiles -SyncWindow 0 | Out-String).Trim())

    $manifestPath = Join-Path $root "package-assets.sha256"
    $manifestLines = @(
        [IO.File]::ReadAllLines($manifestPath, [Text.Encoding]::UTF8) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $manifestPaths = New-Object Collections.Generic.List[string]
    $manifestFailures = New-Object Collections.Generic.List[string]
    foreach ($line in $manifestLines) {
        if ($line -notmatch '^([0-9A-F]{64})  ([^\r\n]+)$') {
            $manifestFailures.Add("format") | Out-Null
            continue
        }
        $expected = $matches[1]
        $relative = $matches[2]
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|/)[.][.](/|$)' -or
            $relative.Contains('\')) {
            $manifestFailures.Add(("path:" + $relative)) | Out-Null
            continue
        }
        $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not $full.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $manifestFailures.Add(("missing:" + $relative)) | Out-Null
            continue
        }
        if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -cne $expected) {
            $manifestFailures.Add(("hash:" + $relative)) | Out-Null
        }
        $manifestPaths.Add($relative) | Out-Null
    }
    $uniquePaths = @($manifestPaths | Sort-Object -Unique)
    $ordinalPaths = @($manifestPaths.ToArray())
    [Array]::Sort($ordinalPaths, [StringComparer]::Ordinal)
    $caseFolded = @($manifestPaths | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    Check "package manifest is 52-entry, unique, and canonical" (
        $manifestLines.Count -eq 52 -and
        $manifestPaths.Count -eq 52 -and
        $uniquePaths.Count -eq 52 -and
        $caseFolded.Count -eq 52 -and
        (@(Compare-Object $manifestPaths $ordinalPaths -SyncWindow 0).Count -eq 0) -and
        $manifestFailures.Count -eq 0
    ) (($manifestFailures.ToArray()) -join "; ")

    $manifestDigest = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $installerText = [IO.File]::ReadAllText((Join-Path $root "tools\install.ps1"), [Text.Encoding]::UTF8)
    Check "installer has one exact package-manifest trust anchor" (
        [regex]::Matches($installerText, [regex]::Escape($manifestDigest)).Count -eq 1
    ) $manifestDigest

    $parseFailures = New-Object Collections.Generic.List[string]
    $encodingFailures = New-Object Collections.Generic.List[string]
    foreach ($scriptFile in @(Get-ChildItem -LiteralPath $root -Recurse -Filter "*.ps1" -File)) {
        $bytes = [IO.File]::ReadAllBytes($scriptFile.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $hasNonAscii = @($bytes | Where-Object { $_ -gt 0x7F }).Count -gt 0
        if ($hasNonAscii -and -not $hasBom) {
            $encodingFailures.Add($scriptFile.FullName.Substring($root.Length + 1)) | Out-Null
        }
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            $scriptFile.FullName,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        if (@($errors).Count -gt 0) {
            $parseFailures.Add($scriptFile.FullName.Substring($root.Length + 1)) | Out-Null
        }
    }
    Check "archive PowerShell parses in Windows PowerShell 5.1" ($parseFailures.Count -eq 0) (
        $parseFailures.ToArray() -join "; "
    )
    Check "non-ASCII PowerShell uses UTF-8 BOM" ($encodingFailures.Count -eq 0) (
        $encodingFailures.ToArray() -join "; "
    )

    $hookPath = Join-Path $root "tools\git-hooks\pre-commit"
    $hookBytes = [IO.File]::ReadAllBytes($hookPath)
    $hookHasBom = $hookBytes.Length -ge 3 -and
        $hookBytes[0] -eq 0xEF -and $hookBytes[1] -eq 0xBB -and $hookBytes[2] -eq 0xBF
    $attributes = [IO.File]::ReadAllText((Join-Path $root ".gitattributes"), [Text.Encoding]::UTF8)
    Check "extensionless Git hook is LF, BOM-free, and attribute-pinned" (
        -not $hookHasBom -and
        -not ($hookBytes -contains 13) -and
        $attributes -match '(?m)^tools/git-hooks/pre-commit\s+.*eol=lf'
    )

    $linkFailures = New-Object Collections.Generic.List[string]
    foreach ($markdown in @(Get-ChildItem -LiteralPath $root -Recurse -Filter "*.md" -File)) {
        $text = Remove-MarkdownFencedCode -Text (
            [IO.File]::ReadAllText($markdown.FullName, [Text.Encoding]::UTF8)
        )
        foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)]+)\)')) {
            $target = [Uri]::UnescapeDataString($match.Groups[1].Value.Trim())
            if ($target -match '^(?i:https?://|mailto:|#)') { continue }
            $target = ($target -split '#', 2)[0]
            if (-not $target) { continue }
            $resolved = [IO.Path]::GetFullPath((Join-Path $markdown.DirectoryName $target))
            if (-not (Test-Path -LiteralPath $resolved)) {
                $linkFailures.Add(
                    $markdown.FullName.Substring($root.Length + 1) + " -> " + $target
                ) | Out-Null
            }
        }
    }
    $fencedCastFixture = "``````powershell`n`$Value = [string](gh api invalid)`n``````"
    Check "archive Markdown link scan excludes fenced PowerShell casts" (
        [regex]::Matches(
            (Remove-MarkdownFencedCode -Text $fencedCastFixture),
            '\[[^\]]+\]\(([^)]+)\)'
        ).Count -eq 0
    )
    Check "archive local Markdown links resolve" ($linkFailures.Count -eq 0) (
        $linkFailures.ToArray() -join "; "
    )

    $claudeFiles = @(Get-ChildItem -LiteralPath (Join-Path $root "templates\claude") -Recurse -File -ErrorAction SilentlyContinue)
    Check "archive ships no Claude template surface" ($claudeFiles.Count -eq 0)

    if (-not $IntegrityOnly) {
        Run-Gate "archive phase-3 behavior suites pass" (Join-Path $root "tools\validate-phase3.ps1") "fail=0"
        Run-Gate "archive Codex runtime slice passes" (Join-Path $root "tools\validate-runtime-slice.ps1") "fail=0"
        Run-Gate "archive equivalence contract passes" (Join-Path $root "tools\test-equivalence-contract.ps1") "fail=0"
        Run-Gate "archive whitespace helper behavior passes" (Join-Path $root "tools\test-release-whitespace.ps1") "fail=0"
    }

    Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}
finally {
    Pop-Location
}

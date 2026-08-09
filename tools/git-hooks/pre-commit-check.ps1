#requires -Version 7.5
[CmdletBinding()]
param(
    [int]$MaxMB = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'protected-path-policy.ps1')
}
catch {
    [Console]::Error.WriteLine("Cannot load protected path policy; commit is blocked.")
    exit 1
}

# Global pre-commit guard. Runs on EVERY commit via core.hooksPath.
# Blocks secret-looking files and oversized blobs across Codex and manual Git.
# Bypass once: git commit --no-verify

$staged = & git -c core.quotepath=false diff --cached --name-only --diff-filter=ACMRT 2>$null
if (-not $staged) { exit 0 }

$blocked = New-Object System.Collections.Generic.List[string]
$credentialName = "(?:" +
    ("api" + "[_-]?key") + "|" +
    ("access" + "[_-]?token") + "|" +
    ("secret" + "[_-]?key") + "|" +
    ("pass" + "word") + ")"
$credentialAssignmentPattern = '(?im)\b' + $credentialName +
    '\b\s*[:=]\s*[''"]?[^\s''"]{8,}'
$privateKeyPattern = '(?im)^-----BEGIN (?:RSA |OPENSSH |EC |DSA )?' +
    ("PRIVATE" + " KEY-----")
foreach ($path in $staged) {
    if (-not $path) { continue }
    $protectedReason = Get-ProtectedPathReason -Path $path
    if ($protectedReason) {
        $blocked.Add("$path  ($protectedReason)")
        continue
    }

    $workingPath = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $path))
    if (-not (Test-Path -LiteralPath $workingPath -PathType Leaf)) {
        $blocked.Add("$path  (working-tree file is unavailable for single-link verification)")
        continue
    }
    try {
        $linkCount = Get-SteadyAgentFileLinkCount -Path $workingPath
    }
    catch {
        $blocked.Add("$path  (cannot bind working-tree file identity)")
        continue
    }
    if ($linkCount -ne 1) {
        $blocked.Add("$path  (working-tree file has multiple hard links)")
        continue
    }

    $blobSpec = ":" + $path
    $sizeText = @(& git cat-file -s $blobSpec 2>$null) -join ""
    if ($LASTEXITCODE -ne 0 -or $sizeText -notmatch '^[0-9]+$') {
        $blocked.Add("$path  (cannot inspect staged blob)")
        continue
    }
    $len = [int64]$sizeText
    if ($len -gt ($MaxMB * 1MB)) {
        $blocked.Add(("{0}  ({1:N1} MB > {2} MB)" -f $path, ($len / 1MB), $MaxMB))
        continue
    }

    $content = @(& git cat-file blob $blobSpec 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        $blocked.Add("$path  (cannot inspect staged blob content)")
        continue
    }
    if ($content -match $credentialAssignmentPattern -or $content -match $privateKeyPattern) {
        $blocked.Add("$path  (Possible secrets: staged content matches a secret pattern)")
    }
}

if ($blocked.Count -gt 0) {
    Write-Host "[pre-commit BLOCKED] Refusing to commit secret-looking or oversized files:"
    foreach ($b in $blocked) { Write-Host "  - $b" }
    Write-Host ""
    Write-Host "If this is intentional, bypass once with:  git commit --no-verify"
    Write-Host "To disable this guard globally:  git config --global --unset core.hooksPath"
    exit 1
}

exit 0

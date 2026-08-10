#requires -Version 7.5
[CmdletBinding()]
param(
    [int]$LargeFileMb = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
    param([string[]]$Arguments)

    $output = & git @Arguments 2>$null
    return [PSCustomObject]@{
        Code = $LASTEXITCODE
        Output = @($output)
    }
}

$rootResult = Invoke-Git @("rev-parse", "--show-toplevel")
if ($rootResult.Code -ne 0) {
    Write-Host "[FAIL] Not a Git repository."
    exit 1
}

$root = ($rootResult.Output -join "").Trim()

Write-Host "== Git Identity =="
Write-Host ("user.name: {0}" -f ((Invoke-Git @("config", "--get", "user.name")).Output -join ""))
Write-Host ("user.email: {0}" -f ((Invoke-Git @("config", "--get", "user.email")).Output -join ""))
Write-Host ("init.defaultBranch: {0}" -f ((Invoke-Git @("config", "--get", "init.defaultBranch")).Output -join ""))
Write-Host ""

Write-Host "== Repository =="
Write-Host ("root: {0}" -f $root)
Write-Host ("branch: {0}" -f ((Invoke-Git @("branch", "--show-current")).Output -join ""))
Write-Host "remotes:"
$remotes = (Invoke-Git @("remote", "-v")).Output
if ($remotes.Count -eq 0) {
    Write-Host "  none"
}
else {
    foreach ($remote in $remotes) {
        Write-Host ("  {0}" -f $remote)
    }
}
Write-Host ""

Write-Host "== Status =="
$status = (Invoke-Git @("status", "--short", "--branch", "--untracked-files=all")).Output
if ($status.Count -eq 0) {
    Write-Host "clean"
}
else {
    foreach ($line in $status) {
        Write-Host $line
    }
}
Write-Host ""

Write-Host "== .gitignore Check =="
$ignorePath = Join-Path $root ".gitignore"
$missing = New-Object System.Collections.Generic.List[string]
foreach ($pattern in @("node_modules/", ".venv/", "dist/", "build/", ".env", "*.log")) {
    if (-not (Test-Path -LiteralPath $ignorePath) -or -not ((Get-Content -LiteralPath $ignorePath -Raw) -match [regex]::Escape($pattern))) {
        $missing.Add($pattern) | Out-Null
    }
}
if ($missing.Count -eq 0) {
    Write-Host "[OK] Common ignore patterns are present."
}
else {
    Write-Host ("[WARN] .gitignore may be missing: {0}" -f ($missing -join ", "))
}
Write-Host ""

Write-Host "== Large Untracked Files =="
$limit = $LargeFileMb * 1MB
$large = New-Object System.Collections.Generic.List[string]
$untracked = (Invoke-Git @("ls-files", "--others", "--exclude-standard")).Output
foreach ($relative in $untracked) {
    $path = Join-Path $root $relative
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and ((Get-Item -LiteralPath $path).Length -gt $limit)) {
        $large.Add($relative) | Out-Null
    }
}
if ($large.Count -eq 0) {
    Write-Host ("none detected above {0} MB" -f $LargeFileMb)
}
else {
    foreach ($file in $large) {
        Write-Host ("[WARN] {0}" -f $file)
    }
}
Write-Host ""
Write-Host "[OK] Git preflight complete."

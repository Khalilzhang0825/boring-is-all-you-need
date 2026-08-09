#requires -Version 7.5
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    $checks.Add([PSCustomObject]@{
        Name = $Name
        Passed = $Passed
        Detail = $Detail
    }) | Out-Null
}

function Invoke-InRepo {
    param(
        [string]$Repo,
        [scriptblock]$Script
    )

    Push-Location $Repo
    try {
        & $Script
    }
    finally {
        Pop-Location
    }
}

$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$hookPath = Join-Path $sourceRoot "tools/hooks/pre-commit.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("steadyagent-hook-smoke-" + [guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    Invoke-InRepo $tempRoot {
        & git init | Out-Null
        & git config user.email "steadyagent@example.invalid"
        & git config user.name "SteadyAgent Test"
        Set-Content -LiteralPath "baseline.txt" -Value "baseline"
        & git add -- baseline.txt
        & git commit -m "baseline" | Out-Null

        Set-Content -LiteralPath "safe.txt" -Value "safe content"
        & git add -- safe.txt
        $safeOutput = & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath
        Add-Check "safe staged file passes hook" ($LASTEXITCODE -eq 0) (($safeOutput | Out-String).Trim())
        & git reset -- safe.txt | Out-Null

        Set-Content -LiteralPath "secret.txt" -Value ("api" + "_key=example")
        & git add -- secret.txt
        $secretOutput = & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath
        Add-Check "secret staged file fails hook" ($LASTEXITCODE -ne 0) (($secretOutput | Out-String).Trim())
        & git reset -- secret.txt | Out-Null

        Set-Content -LiteralPath "staged-secret.txt" -Value ("api" + "_key=example")
        & git add -- staged-secret.txt
        Set-Content -LiteralPath "staged-secret.txt" -Value "safe working tree content"
        $divergentSecretOutput = & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath
        Add-Check "hook scans staged secret instead of working tree" ($LASTEXITCODE -ne 0) (($divergentSecretOutput | Out-String).Trim())
        & git reset -- staged-secret.txt | Out-Null

        Set-Content -LiteralPath "staged-safe.txt" -Value "safe staged content"
        & git add -- staged-safe.txt
        Set-Content -LiteralPath "staged-safe.txt" -Value ("api" + "_key=working-tree-only")
        $divergentSafeOutput = & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath
        Add-Check "hook ignores unstaged working tree secret" ($LASTEXITCODE -eq 0) (($divergentSafeOutput | Out-String).Trim())
        & git reset -- staged-safe.txt | Out-Null

        $largePath = Join-Path $PWD "large.bin"
        [System.IO.File]::WriteAllBytes($largePath, (New-Object byte[] (26MB)))
        & git add -- large.bin
        $largeOutput = & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath
        Add-Check "large staged file fails hook" ($LASTEXITCODE -ne 0) (($largeOutput | Out-String).Trim())
        & git reset -- large.bin | Out-Null

        Rename-Item -LiteralPath "baseline.txt" -NewName "renamed-secret.txt"
        Set-Content -LiteralPath "renamed-secret.txt" -Value ("api" + "_key=renamed")
        & git add -A
        $renameOutput = & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath
        Add-Check "renamed staged file fails hook" ($LASTEXITCODE -ne 0) (($renameOutput | Out-String).Trim())
    }
}
finally {
    $tempBase = [System.IO.Path]::GetTempPath()
    $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTemp.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

$failed = @($checks | Where-Object { -not $_.Passed })
foreach ($check in $checks) {
    $status = if ($check.Passed) { "PASS" } else { "FAIL" }
    $detail = if ($check.Passed) { "OK" } else { $check.Detail }
    Write-Host ("{0} {1} - {2}" -f $status, $check.Name, $detail)
}

Write-Host ""
Write-Host ("RESULT pass={0} fail={1}" -f ($checks.Count - $failed.Count), $failed.Count)

if ($failed.Count -gt 0) {
    exit 1
}

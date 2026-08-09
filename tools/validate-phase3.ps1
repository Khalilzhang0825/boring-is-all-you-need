#requires -Version 7.5
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:Passed = 0
$script:Failed = 0

function Run-Gate {
    param([string]$Name, [string]$Path, [string]$Expected)
    Write-Host ("RUN " + $Name)
    $outputLines = New-Object Collections.Generic.List[string]
    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $Path | ForEach-Object {
        $line = [string]$_
        $outputLines.Add($line) | Out-Null
        Write-Host $line
    }
    $code = $LASTEXITCODE
    $outputText = $outputLines.ToArray() -join "`n"
    if ($code -eq 0 -and $outputText -match $Expected) {
        $script:Passed++
        Write-Host ("PASS " + $Name)
    }
    else {
        $script:Failed++
        Write-Host ("FAIL " + $Name)
        Write-Host $outputText
    }
}

Run-Gate "V2 migration suite" (Join-Path $root "tools\test-v2-migration.ps1") "fail=0"
Run-Gate "Git checkpoint suite" (Join-Path $root "tools\test-git-checkpoint.ps1") "0 failed"
Run-Gate "pre-commit suite" (Join-Path $root "tools\test-pre-commit.ps1") "0 failed"
Run-Gate "runtime skill catalog suite" (Join-Path $root "tools\test-skill-catalog.ps1") "0 failed"
Run-Gate "protected path policy suite" (Join-Path $root "tools\test-protected-path-policy.ps1") "0 failed"

Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

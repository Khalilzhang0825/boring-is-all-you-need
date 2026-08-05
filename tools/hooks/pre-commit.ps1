[CmdletBinding()]
param(
    [Alias("LargeFileMb")]
    [int]$MaxMB = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Compatibility entrypoint for v1 paths. The installed Git Hook invokes the
# single authoritative checker under tools/git-hooks.
$checker = Join-Path (Split-Path -Parent $PSScriptRoot) "git-hooks\pre-commit-check.ps1"
if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) {
    [Console]::Error.WriteLine("Cannot locate the authoritative pre-commit checker; commit is blocked.")
    exit 1
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -MaxMB $MaxMB
exit $LASTEXITCODE

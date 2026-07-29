[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Passed = 0
$script:Failed = 0
$guard = Join-Path $PSScriptRoot "git-hooks\pre-commit-check.ps1"

function Assert-True {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { Write-Host ("PASS  " + $Name); $script:Passed++ }
    else { Write-Host ("FAIL  " + $Name); $script:Failed++ }
}

function Invoke-Guard {
    param([int]$MaxMB = 25)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guard -MaxMB $MaxMB
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) -join "`n" }
}

$base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root = [IO.Path]::GetFullPath((Join-Path $base ("precommit-test-" + [guid]::NewGuid().ToString("N"))))
if (-not $root.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Test root escaped temp." }

try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Push-Location $root
    & git init -q
    & git config user.name "Harness Test"
    & git config user.email "harness@example.invalid"
    Set-Content -LiteralPath "seed.txt" -Value "seed" -Encoding ASCII
    & git add -- "seed.txt"
    & git commit -q -m "seed"

    Set-Content -LiteralPath ".pgpass" -Value "secret" -Encoding ASCII
    & git add -- ".pgpass"
    $result = Invoke-Guard
    Assert-True "pgpass is blocked" ($result.ExitCode -ne 0)
    & git reset -q HEAD -- ".pgpass"
    Remove-Item -LiteralPath ".pgpass" -Force

    Set-Content -LiteralPath "id_ed25519.pub" -Value "fixture public key" -Encoding ASCII
    & git add -- "id_ed25519.pub"
    $result = Invoke-Guard
    Assert-True "SSH public key is allowed" ($result.ExitCode -eq 0)
    & git reset -q HEAD -- "id_ed25519.pub"
    Remove-Item -LiteralPath "id_ed25519.pub" -Force

    [IO.File]::WriteAllBytes((Join-Path $root "large.bin"), (New-Object byte[] (1536KB)))
    & git add -- "large.bin"
    Set-Content -LiteralPath "large.bin" -Value "small working tree" -Encoding ASCII
    $result = Invoke-Guard -MaxMB 1
    Assert-True "large staged blob is blocked after worktree shrinks" ($result.ExitCode -ne 0)
    & git reset -q HEAD -- "large.bin"
    Remove-Item -LiteralPath "large.bin" -Force

    Set-Content -LiteralPath "small.bin" -Value "small staged blob" -Encoding ASCII
    & git add -- "small.bin"
    [IO.File]::WriteAllBytes((Join-Path $root "small.bin"), (New-Object byte[] (1536KB)))
    $result = Invoke-Guard -MaxMB 1
    Assert-True "small staged blob is allowed after worktree grows" ($result.ExitCode -eq 0)
    & git reset -q HEAD -- "small.bin"
    Remove-Item -LiteralPath "small.bin" -Force

    Set-Content -LiteralPath "safe.txt" -Value "safe" -Encoding ASCII
    & git add -- "safe.txt"
    & git commit -q -m "safe"
    & git mv -- "safe.txt" ".env.local"
    $result = Invoke-Guard
    Assert-True "rename to sensitive name is blocked" ($result.ExitCode -ne 0)

    & git reset -q HEAD -- ".env.local" "safe.txt"
    if (Test-Path -LiteralPath ".env.local") {
        Remove-Item -LiteralPath ".env.local" -Force
    }
    & git config core.hooksPath (Join-Path $PSScriptRoot "git-hooks")
    Set-Content -LiteralPath ".pgpass" -Value "secret" -Encoding ASCII
    & git add -- ".pgpass"
    & git commit -q -m "must be blocked by the installed hook entrypoint"
    $hookExitCode = $LASTEXITCODE
    Assert-True "Git executes the packaged pre-commit entrypoint" ($hookExitCode -ne 0)
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) {
        $resolved = [IO.Path]::GetFullPath($root)
        if ($resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved).StartsWith("precommit-test-")) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ("=== Pre-commit test: {0} passed, {1} failed ===" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

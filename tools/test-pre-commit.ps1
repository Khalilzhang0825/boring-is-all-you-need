[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Passed = 0
$script:Failed = 0
$script:Results = @{}
$guard = Join-Path $PSScriptRoot "git-hooks\pre-commit-check.ps1"

function Assert-True {
    param([string]$Name, [bool]$Condition)
    $script:Results[$Name] = $Condition
    if ($Condition) { Write-Host ("PASS  " + $Name); $script:Passed++ }
    else { Write-Host ("FAIL  " + $Name); $script:Failed++ }
}

function Write-SemanticCheck {
    param([string]$Id, [string[]]$Cases)
    $missing = @($Cases | Where-Object {
        -not $script:Results.ContainsKey($_) -or -not [bool]$script:Results[$_]
    })
    if ($missing.Count -eq 0) {
        Write-Host ("SEMANTIC PASS " + $Id)
    } else {
        Write-Host ("FAIL  semantic evidence " + $Id + " missing=" + ($missing -join ","))
        $script:Failed++
    }
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

    Set-Content -LiteralPath ".env" -Value "synthetic secret" -Encoding ASCII
    New-Item -ItemType HardLink -Path "safe-hardlink.txt" -Target ".env" | Out-Null
    & git add -- "safe-hardlink.txt"
    $result = Invoke-Guard
    Assert-True "hardlink alias of protected file is blocked" ($result.ExitCode -ne 0)
    & git reset -q HEAD -- "safe-hardlink.txt"
    Remove-Item -LiteralPath "safe-hardlink.txt" -Force
    Remove-Item -LiteralPath ".env" -Force

    Set-Content -LiteralPath "id_ed25519.pub" -Value "fixture public key" -Encoding ASCII
    & git add -- "id_ed25519.pub"
    $result = Invoke-Guard
    Assert-True "SSH public key is allowed" ($result.ExitCode -eq 0)
    & git reset -q HEAD -- "id_ed25519.pub"
    Remove-Item -LiteralPath "id_ed25519.pub" -Force

    $syntheticToken = ("access" + "_token = synthetic_test_value_123456")
    Set-Content -LiteralPath "notes.txt" -Value $syntheticToken -Encoding ASCII
    & git add -- "notes.txt"
    Set-Content -LiteralPath "notes.txt" -Value "ordinary working-tree notes" -Encoding ASCII
    $result = Invoke-Guard
    Assert-True "synthetic token in ordinary staged blob is blocked" (
        $result.ExitCode -ne 0 -and $result.Output -match "staged content matches a secret pattern"
    )
    & git reset -q HEAD -- "notes.txt"
    Remove-Item -LiteralPath "notes.txt" -Force

    $syntheticSecret = ("api" + "_key=synthetic_test_secret_123456")
    Set-Content -LiteralPath "config.txt" -Value $syntheticSecret -Encoding ASCII
    & git add -- "config.txt"
    $result = Invoke-Guard
    Assert-True "synthetic secret in ordinary staged blob is blocked" (
        $result.ExitCode -ne 0 -and $result.Output -match "staged content matches a secret pattern"
    )
    & git reset -q HEAD -- "config.txt"
    Remove-Item -LiteralPath "config.txt" -Force

    $privateKeyHeader = ("-----BEGIN OPENSSH " + "PRIVATE KEY-----")
    Set-Content -LiteralPath "key-material.txt" -Value @($privateKeyHeader, "synthetic-test-material") -Encoding ASCII
    & git add -- "key-material.txt"
    $result = Invoke-Guard
    Assert-True "synthetic private key in ordinary staged blob is blocked" (
        $result.ExitCode -ne 0 -and $result.Output -match "staged content matches a secret pattern"
    )
    & git reset -q HEAD -- "key-material.txt"
    Remove-Item -LiteralPath "key-material.txt" -Force

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

    & git reset -q HEAD -- ".pgpass"
    Remove-Item -LiteralPath ".pgpass" -Force
    Set-Content -LiteralPath "hook-notes.txt" -Value $syntheticToken -Encoding ASCII
    & git add -- "hook-notes.txt"
    & git commit -q -m "must be blocked by staged content scan"
    $hookContentExitCode = $LASTEXITCODE
    Assert-True "packaged pre-commit blocks synthetic token in ordinary staged blob" (
        $hookContentExitCode -ne 0
    )

    & git reset -q HEAD -- "hook-notes.txt"
    Remove-Item -LiteralPath "hook-notes.txt" -Force
    $localHook = Join-Path $root ".git\hooks\pre-commit"
    $localMarker = Join-Path $root "local-pre-commit.marker"
    $localMarkerSh = $localMarker.Replace("\", "/")
    [IO.File]::WriteAllText(
        $localHook,
        ("#!/bin/sh`nprintf invoked > `"{0}`"`nexit 0`n" -f $localMarkerSh),
        (New-Object Text.UTF8Encoding($false))
    )
    Set-Content -LiteralPath "local-safe.txt" -Value "safe" -Encoding ASCII
    & git add -- "local-safe.txt"
    & git commit -q -m "local hook is chained"
    Assert-True "global hooksPath chains the repository-local pre-commit" (
        $LASTEXITCODE -eq 0 -and
        (Test-Path -LiteralPath $localMarker -PathType Leaf)
    )

    [IO.File]::WriteAllText(
        $localHook,
        "#!/bin/sh`nexit 7`n",
        (New-Object Text.UTF8Encoding($false))
    )
    Set-Content -LiteralPath "local-blocked.txt" -Value "blocked" -Encoding ASCII
    & git add -- "local-blocked.txt"
    & git commit -q -m "local hook must still block"
    Assert-True "repository-local pre-commit failure blocks the commit" ($LASTEXITCODE -ne 0)
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

Write-SemanticCheck -Id "precommit.protected-secret-size" -Cases @(
    "pgpass is blocked",
    "hardlink alias of protected file is blocked",
    "SSH public key is allowed",
    "synthetic token in ordinary staged blob is blocked",
    "synthetic secret in ordinary staged blob is blocked",
    "synthetic private key in ordinary staged blob is blocked",
    "large staged blob is blocked after worktree shrinks",
    "small staged blob is allowed after worktree grows",
    "rename to sensitive name is blocked",
    "Git executes the packaged pre-commit entrypoint",
    "packaged pre-commit blocks synthetic token in ordinary staged blob",
    "global hooksPath chains the repository-local pre-commit",
    "repository-local pre-commit failure blocks the commit"
)
if ($script:Failed -eq 0 -and $script:Results.Count -ge 8) {
    Write-Host "SEMANTIC PASS precommit.local-contract-suite-executed"
} else {
    Write-Host ("FAIL  semantic evidence precommit.local-contract-suite-executed cases=" + $script:Results.Count)
    $script:Failed++
}
Write-Host ("=== Pre-commit test: {0} passed, {1} failed ===" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

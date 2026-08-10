#requires -Version 7.5
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Passed = 0
$script:Failed = 0
$script:Results = @{}
$policy = Join-Path $PSScriptRoot "protected-path-policy.ps1"

function Assert-Equal {
    param(
        [string]$Name,
        $Actual,
        $Expected
    )

    $condition = $Actual -eq $Expected
    $script:Results[$Name] = $condition
    if ($condition) {
        Write-Host ("PASS  " + $Name)
        $script:Passed++
    }
    else {
        Write-Host ("FAIL  {0}: expected [{1}], got [{2}]" -f $Name, $Expected, $Actual)
        $script:Failed++
    }
}

function Write-SemanticPass {
    param([string]$Id, [string[]]$Cases)
    $missingOrFailed = @($Cases | Where-Object {
        -not $script:Results.ContainsKey($_) -or -not [bool]$script:Results[$_]
    })
    if ($missingOrFailed.Count -eq 0) {
        Write-Host ("SEMANTIC PASS " + $Id)
    }
    else {
        Write-Host ("FAIL  semantic evidence " + $Id + " missing_or_failed=" + ($missingOrFailed -join ","))
        $script:Failed++
    }
}

. $policy

$blockedCases = @(
    ".env",
    ".ENV.local",
    "config/id_rsa",
    "certs/client.pem",
    "db/.pgpass",
    "config/service-credentials.json",
    "config/app_secret.yaml",
    "config/.env.",
    "config/.env ",
    "config/.env:stream",
    "config/safe.txt:stream",
    "config/client.pem.",
    "config/client.pem "
)

foreach ($path in $blockedCases) {
    Assert-Equal ("commit policy blocks " + $path) ([bool](Get-ProtectedPathReason -Path $path)) $true
}

$safeCases = @(
    ".env.example",
    "keys/id_ed25519.pub",
    "src/session.ts",
    "docs/authentication.md",
    "config/tokenizer.py",
    "C:\fixture\safe.txt"
)

foreach ($path in $safeCases) {
    Assert-Equal ("commit policy allows " + $path) ([bool](Get-ProtectedPathReason -Path $path)) $false
}

Assert-Equal "runtime policy allows credential documentation" `
    ([bool](Get-ProtectedPathReason -Path "docs/secret_sauce.md" -AllowDocumentationExamples)) `
    $false
Assert-Equal "commit policy blocks credential documentation" `
    ([bool](Get-ProtectedPathReason -Path "docs/secret_sauce.md")) `
    $true

$boundRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "steadyagent-bound-path-" + [guid]::NewGuid().ToString("N")
)
try {
    $victimParent = Join-Path $boundRoot "victim"
    $escapeParent = Join-Path $boundRoot "escape"
    $parkedParent = Join-Path $boundRoot "parked"
    New-Item -ItemType Directory -Path $victimParent -Force | Out-Null
    New-Item -ItemType Directory -Path $escapeParent -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $escapeParent "sentinel.txt"),
        "sentinel`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $destination = Join-Path $victimParent "payload.txt"
    $firstBytes = (New-Object Text.UTF8Encoding($false)).GetBytes("first`n")
    Invoke-SteadyAgentBoundAtomicWrite `
        -Destination $destination `
        -Bytes $firstBytes `
        -RequireMissing
    Assert-Equal "bound write creates a missing file" `
        ([IO.File]::ReadAllText($destination, [Text.Encoding]::UTF8)) `
        "first`n"

    $firstHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    $swapState = @{ Blocked = $false }
    $afterPin = [Action]{
        try {
            [IO.Directory]::Move($victimParent, $parkedParent)
            New-Item -ItemType Junction -Path $victimParent -Target $escapeParent | Out-Null
        }
        catch {
            $swapState.Blocked = $true
        }
    }
    $secondBytes = (New-Object Text.UTF8Encoding($false)).GetBytes("second`n")
    Invoke-SteadyAgentBoundAtomicWrite `
        -Destination $destination `
        -Bytes $secondBytes `
        -ExpectedCurrentSHA256 $firstHash `
        -AfterParentPin $afterPin
    Assert-Equal "bound write blocks parent replacement after pin" $swapState.Blocked $true
    Assert-Equal "bound replacement publishes the new bytes" `
        ([IO.File]::ReadAllText($destination, [Text.Encoding]::UTF8)) `
        "second`n"
    Assert-Equal "bound replacement leaves the escape sentinel unchanged" `
        ([IO.File]::ReadAllText((Join-Path $escapeParent "sentinel.txt"), [Text.Encoding]::UTF8)) `
        "sentinel`n"
    Assert-Equal "bound replacement creates no escape payload" `
        (Test-Path -LiteralPath (Join-Path $escapeParent "payload.txt")) `
        $false

    $secondHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    $deleted = Remove-SteadyAgentBoundFile `
        -Path $destination `
        -ExpectedCurrentSHA256 $secondHash
    Assert-Equal "bound delete removes the verified file" $deleted $true
    Assert-Equal "bound delete leaves no destination" (Test-Path -LiteralPath $destination) $false

    $preexistingDirectory = Join-Path $boundRoot "preexisting-directory"
    New-Item -ItemType Directory -Path $preexistingDirectory | Out-Null
    $preexistingBlocked = $false
    try { New-SteadyAgentOwnedDirectory -Path $preexistingDirectory | Out-Null }
    catch { $preexistingBlocked = $true }
    Assert-Equal "owned directory creation rejects a third-party precreate" $preexistingBlocked $true
    Assert-Equal "owned directory creation preserves the third-party precreate" `
        (Test-Path -LiteralPath $preexistingDirectory -PathType Container) $true

    $replacementDirectory = Join-Path $boundRoot "replacement-directory"
    $replacementState = New-SteadyAgentOwnedDirectory -Path $replacementDirectory
    [IO.Directory]::Delete($replacementDirectory, $false)
    New-Item -ItemType Directory -Path $replacementDirectory | Out-Null
    $replacementBlocked = $false
    try { Remove-SteadyAgentOwnedEmptyDirectory -DirectoryState $replacementState | Out-Null }
    catch { $replacementBlocked = $true }
    $replacementAssertionBlocked = $false
    try { Assert-SteadyAgentOwnedDirectoryIdentity -DirectoryState $replacementState | Out-Null }
    catch { $replacementAssertionBlocked = $true }
    Assert-Equal "owned directory identity assertion rejects a replacement" `
        $replacementAssertionBlocked $true
    Assert-Equal "owned directory deletion rejects an identity replacement" $replacementBlocked $true
    Assert-Equal "owned directory deletion preserves the identity replacement" `
        (Test-Path -LiteralPath $replacementDirectory -PathType Container) $true

    $nonEmptyDirectory = Join-Path $boundRoot "non-empty-directory"
    $nonEmptyState = New-SteadyAgentOwnedDirectory -Path $nonEmptyDirectory
    [IO.File]::WriteAllText((Join-Path $nonEmptyDirectory "foreign.txt"), "foreign")
    $nonEmptyBlocked = $false
    try { Remove-SteadyAgentOwnedEmptyDirectory -DirectoryState $nonEmptyState | Out-Null }
    catch { $nonEmptyBlocked = $true }
    Assert-Equal "owned directory deletion rejects a non-empty directory" $nonEmptyBlocked $true
    Assert-Equal "owned directory deletion preserves foreign contents" `
        (Test-Path -LiteralPath (Join-Path $nonEmptyDirectory "foreign.txt") -PathType Leaf) $true

    $ownedDirectory = Join-Path $boundRoot "owned-directory"
    $ownedState = New-SteadyAgentOwnedDirectory -Path $ownedDirectory
    $ownedRemoved = Remove-SteadyAgentOwnedEmptyDirectory -DirectoryState $ownedState
    Assert-Equal "owned directory deletion removes the same empty directory identity" $ownedRemoved $true
    Assert-Equal "owned directory deletion leaves no owned directory" `
        (Test-Path -LiteralPath $ownedDirectory) $false
}
finally {
    if (Test-Path -LiteralPath $boundRoot) {
        Remove-Item -LiteralPath $boundRoot -Recurse -Force
    }
}

Write-SemanticPass "protected-paths.windows-alias-policy" @(
    "commit policy blocks config/.env.",
    "commit policy blocks config/.env ",
    "commit policy blocks config/.env:stream",
    "commit policy blocks config/safe.txt:stream",
    "commit policy blocks config/client.pem.",
    "commit policy blocks config/client.pem ",
    "commit policy allows C:\fixture\safe.txt"
)
Write-SemanticPass "protected-paths.bound-mutation" @(
    "bound write creates a missing file",
    "bound write blocks parent replacement after pin",
    "bound replacement publishes the new bytes",
    "bound replacement leaves the escape sentinel unchanged",
    "bound replacement creates no escape payload",
    "bound delete removes the verified file",
    "bound delete leaves no destination"
)
Write-SemanticPass "protected-paths.owned-directory" @(
    "owned directory creation rejects a third-party precreate",
    "owned directory creation preserves the third-party precreate",
    "owned directory identity assertion rejects a replacement",
    "owned directory deletion rejects an identity replacement",
    "owned directory deletion preserves the identity replacement",
    "owned directory deletion rejects a non-empty directory",
    "owned directory deletion preserves foreign contents",
    "owned directory deletion removes the same empty directory identity",
    "owned directory deletion leaves no owned directory"
)
if ($script:Failed -eq 0 -and $script:Results.Count -eq 37) {
    Write-Host "SEMANTIC PASS protected-paths.local-contract-suite-executed"
}
else {
    Write-Host (
        "FAIL  semantic evidence protected-paths.local-contract-suite-executed cases=" +
        $script:Results.Count
    )
    $script:Failed++
}
Write-Host ("=== Protected path policy test: {0} passed, {1} failed ===" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

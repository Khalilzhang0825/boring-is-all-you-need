[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Passed = 0
$script:Failed = 0
$policy = Join-Path $PSScriptRoot "protected-path-policy.ps1"

function Assert-Equal {
    param(
        [string]$Name,
        $Actual,
        $Expected
    )

    if ($Actual -eq $Expected) {
        Write-Host ("PASS  " + $Name)
        $script:Passed++
    }
    else {
        Write-Host ("FAIL  {0}: expected [{1}], got [{2}]" -f $Name, $Expected, $Actual)
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
    "config/app_secret.yaml"
)

foreach ($path in $blockedCases) {
    Assert-Equal ("commit policy blocks " + $path) ([bool](Get-ProtectedPathReason -Path $path)) $true
}

$safeCases = @(
    ".env.example",
    "keys/id_ed25519.pub",
    "src/session.ts",
    "docs/authentication.md",
    "config/tokenizer.py"
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

Write-Host ("=== Protected path policy test: {0} passed, {1} failed ===" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0



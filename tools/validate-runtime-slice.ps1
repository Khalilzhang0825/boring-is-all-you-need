[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:Passed = 0
$script:Failed = 0

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) { $script:Passed++; Write-Host ("PASS " + $Name) }
    else { $script:Failed++; Write-Host ("FAIL " + $Name + $(if ($Detail) { " - " + $Detail } else { "" })) }
}

$templatePath = Join-Path $root "templates\codex\requirements.managed-hooks.example.toml"
$template = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
$blocks = ([regex]::Matches($template, '(?m)^\[\[hooks[.][A-Za-z]+[.]hooks\]\]$')).Count
Check "managed template has four hook blocks" ($blocks -eq 4) ("blocks=" + $blocks)
Check "managed template omits high-frequency events" ($template -notmatch "UserPromptSubmit|PermissionRequest|PostToolUse")
foreach ($required in @("agent-hook-context", "agent-hook-command-guard", "agent-hook-file-guard", "agent-hook-precompact")) {
    Check ("managed template includes " + $required) ($template -match [regex]::Escape($required))
}
foreach ($removed in @("agent-hook-prompt-reminder.ps1", "agent-hook-permission-guard.ps1", "agent-hook-posttool-audit.ps1")) {
    Check ("removed hook absent: " + $removed) (-not (Test-Path -LiteralPath (Join-Path $root ("tools\hooks\" + $removed))))
}

foreach ($scriptPath in @(Get-ChildItem -LiteralPath (Join-Path $root "tools\hooks") -Filter "*.ps1" -File)) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($scriptPath.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Check ("PowerShell parses: " + $scriptPath.Name) ($errors.Count -eq 0) (($errors | ForEach-Object Message) -join "; ")
}

$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "tools\test-agent-hooks.ps1")
$code = $LASTEXITCODE
Check "Hook behavior suite passes" ($code -eq 0 -and ($output | Out-String) -match "fail=0") ($output | Out-String)

Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

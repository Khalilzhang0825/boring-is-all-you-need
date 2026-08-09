#requires -Version 7.5
[CmdletBinding()]
param(
    [switch]$SkipHookBehaviorSuite
)

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

function Test-NoWindowsPowerShellLiteral {
    param([string]$Text)
    return $Text -notmatch '(?im)(?:[.]FileName\s*=|Start-Process\b|ProcessStartInfo\s*[(]).*\bpowershell[.]exe\b'
}

$templatePath = Join-Path $root "templates\codex\requirements.managed-hooks.example.toml"
$template = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
$pwshCommand = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue
Check "runtime is PowerShell Core 7.5 or newer" (
    $PSVersionTable.PSEdition -ceq "Core" -and $PSVersionTable.PSVersion -ge [version]"7.5"
) ("edition={0} version={1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
Check "pwsh executable is resolvable" ($null -ne $pwshCommand) $(if ($pwshCommand) { $pwshCommand.Source } else { "missing pwsh.exe" })

$releaseFiles = [IO.File]::ReadAllLines((Join-Path $root "release-files.txt"), [Text.Encoding]::UTF8)
$releaseScripts = @($releaseFiles | Where-Object { $_ -match '[.]ps1$' })
$missingRequires = @($releaseScripts | Where-Object {
    $text = [IO.File]::ReadAllText((Join-Path $root $_), [Text.Encoding]::UTF8)
    $text -notmatch '(?m)^#requires -Version 7[.]5$'
})
Check "all released PowerShell scripts require 7.5" ($missingRequires.Count -eq 0) ($missingRequires -join ", ")

$runtimeInvocationFailures = [Collections.Generic.List[string]]::new()
foreach ($relative in $releaseScripts) {
    $scriptPath = Join-Path $root $relative
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    foreach ($command in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
        if ([string]$command.GetCommandName() -match '^(?i:powershell(?:[.]exe)?)$') {
            $runtimeInvocationFailures.Add($relative + ':' + $command.Extent.StartLineNumber)
        }
    }
    $scriptText = [IO.File]::ReadAllText($scriptPath, [Text.Encoding]::UTF8)
    if ($relative -cne 'tools/test-agent-hooks.ps1' -and
        -not (Test-NoWindowsPowerShellLiteral -Text $scriptText)) {
        $runtimeInvocationFailures.Add($relative + ':WindowsPowerShellLiteral')
    }
}
Check "released scripts never invoke Windows PowerShell" ($runtimeInvocationFailures.Count -eq 0) ($runtimeInvocationFailures -join ", ")
Check "runtime scanner rejects computed Windows PowerShell ProcessStartInfo" (
    -not (Test-NoWindowsPowerShellLiteral -Text (
        '$startInfo.FileName = Join-Path $PSHOME "power' + 'shell.exe"'
    ))
)

$gitHookPath = Join-Path $root 'tools\git-hooks\pre-commit'
$gitHookText = [IO.File]::ReadAllText($gitHookPath, [Text.Encoding]::UTF8)
Check "extensionless Git Hook invokes pwsh" (
    $gitHookText -match '(?m)^pwsh[.]exe\b' -and
    (Test-NoWindowsPowerShellLiteral -Text $gitHookText)
)

$workflowPaths = @(
    Join-Path $root '.github\workflows\validate.yml'
    Join-Path $root '.github\workflows\release.yml'
)
$workflowText = @($workflowPaths | ForEach-Object {
    [IO.File]::ReadAllText($_, [Text.Encoding]::UTF8)
}) -join "`n"
Check "every workflow job asserts PowerShell Core 7.5 or newer" (
    ([regex]::Matches($workflowText, '(?m)^\s+- name: Verify PowerShell 7 runtime\s*$')).Count -eq 4 -and
    ([regex]::Matches($workflowText, '[$]PSVersionTable[.]PSEdition -cne "Core"')).Count -eq 4 -and
    ([regex]::Matches($workflowText, '[$]PSVersionTable[.]PSVersion -lt \[version\]"7[.]5"')).Count -eq 4
)
$workflowJsonWithoutDateKind = @([regex]::Matches(
    $workflowText,
    'ConvertFrom-Json(?!\s+-DateKind\s+String)'
))
Check "workflow JSON parsing preserves date strings" ($workflowJsonWithoutDateKind.Count -eq 0) (
    'missing DateKind count=' + $workflowJsonWithoutDateKind.Count
)

$publicMarkdown = @($releaseFiles | Where-Object { $_ -match '[.]md$' })
$directMarkdownCommands = [Collections.Generic.List[string]]::new()
foreach ($relative in $publicMarkdown) {
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $root $relative), [Text.Encoding]::UTF8)) {
        $lineNumber++
        if ($line -match '^\s*(?:[.]\\|&\s+).*?[.]ps1(?:\s|$)' -or
            $line -match '(?i)^\s*powershell(?:[.]exe)?\s+.*-File\s+.*[.]ps1') {
            $directMarkdownCommands.Add($relative + ':' + $lineNumber) | Out-Null
        }
    }
}
Check "public Markdown PowerShell commands explicitly use pwsh" (
    $directMarkdownCommands.Count -eq 0
) ($directMarkdownCommands -join ', ')

$blocks = ([regex]::Matches($template, '(?m)^\[\[hooks[.][A-Za-z]+[.]hooks\]\]$')).Count
Check "managed template has three hook blocks" ($blocks -eq 3) ("blocks=" + $blocks)
Check "all managed hooks invoke pwsh" (
    ([regex]::Matches($template, '(?m)^command = "pwsh[.]exe ')).Count -eq 3 -and
    $template -notmatch '(?i)command = "powershell(?:[.]exe)? '
)
Check "managed template omits high-frequency events" ($template -notmatch "UserPromptSubmit|PermissionRequest|PostToolUse")
Check "managed template has one unified PreToolUse guard" (
    ([regex]::Matches($template, '(?m)^\[\[hooks[.]PreToolUse\]\]$')).Count -eq 1 -and
    $template -match 'agent-hook-command-guard[.]ps1\\" -GuardMode Unified' -and
    $template -notmatch 'agent-hook-file-guard[.]ps1'
)
foreach ($required in @("agent-hook-context", "agent-hook-command-guard", "agent-hook-precompact")) {
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

if ($SkipHookBehaviorSuite) {
    Check "Hook behavior suite is delegated to the parent semantic gate" $true
}
else {
    $output = & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "tools\test-agent-hooks.ps1")
    $code = $LASTEXITCODE
    Check "Hook behavior suite passes" ($code -eq 0 -and ($output | Out-String) -match "fail=0") ($output | Out-String)
}

Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

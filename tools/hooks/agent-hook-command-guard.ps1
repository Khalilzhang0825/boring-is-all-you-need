[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-LocalGuardDeny {
    @{
        hookSpecificOutput = @{
            hookEventName = "PreToolUse"
            permissionDecision = "deny"
            permissionDecisionReason = "Blocked: command guard could not safely inspect the matched tool input."
        }
    } | ConvertTo-Json -Depth 5 -Compress
}

try {
    . (Join-Path $PSScriptRoot 'agent-hook-utils.ps1')
} catch {
    Write-LocalGuardDeny
    exit 0
}

# PreToolUse guard for Bash AND PowerShell tools (matcher: "Bash|PowerShell").
# Denies destructive commands and secret writes regardless of which shell tool runs them.

try {
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
$raw = $reader.ReadToEnd()
$reader.Dispose()
if (-not $raw) {
    Write-HookDeny -HookEventName "PreToolUse" -Reason "Blocked: command guard received an empty hook event."
    exit 0
}

try {
    $event = $raw | ConvertFrom-Json
}
catch {
    Write-HookDeny -HookEventName "PreToolUse" -Reason "Blocked: command guard could not parse the hook event."
    exit 0
}

if (Test-ParallelToolName -Name (Get-HookToolName -Object $event)) {
    $parallelError = Get-HookParallelValidationError -Event $event -GuardKind Command
    if ($parallelError) {
        Write-HookDeny -HookEventName "PreToolUse" -Reason (
            "Blocked: command guard could not fully inspect the parallel tool tree ({0})." -f $parallelError
        )
        exit 0
    }
}

try {
    $commands = @(Get-HookCommands -Event $event)
}
catch {
    Write-HookDeny -HookEventName "PreToolUse" -Reason "Blocked: command guard could not safely inspect the matched tool input."
    exit 0
}
if ($commands.Count -eq 0) {
    $toolNames = @(Get-HookToolNames -Event $event)
    $leafToolNames = @($toolNames | Where-Object { -not (Test-ParallelToolName -Name $_) })
    $hasShellTool = @($leafToolNames | Where-Object { Test-ShellToolName -Name $_ }).Count -gt 0
    $hasOnlyNamedNonShellTools = ($leafToolNames.Count -gt 0 -and -not $hasShellTool)
    if ($hasOnlyNamedNonShellTools) {
        exit 0
    }
    Write-HookDeny -HookEventName "PreToolUse" -Reason "Blocked: command guard could not extract a command from a matched shell event."
    exit 0
}

$reason = $null
$blockedCommand = $null

foreach ($candidate in $commands) {
    $candidateReason = Test-DangerousCommand -Command $candidate
    if ($candidateReason) {
        $reason = $candidateReason
        $blockedCommand = $candidate
        break
    }
}

if ($reason) {
    try {
        Write-GuardAuditRecord `
            -GuardName "command-guard" `
            -Reason $reason `
            -ToolName (Get-HookToolName -Object $event) `
            -RawInput $blockedCommand
    } catch { }
    Write-HookDeny -HookEventName "PreToolUse" -Reason $reason
}
} catch {
    Write-LocalGuardDeny
    exit 0
}

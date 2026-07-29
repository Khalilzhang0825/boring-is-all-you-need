[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-LocalGuardDeny {
    @{
        hookSpecificOutput = @{
            hookEventName = "PreToolUse"
            permissionDecision = "deny"
            permissionDecisionReason = "Blocked: file guard could not safely inspect the matched tool input."
        }
    } | ConvertTo-Json -Depth 5 -Compress
}

try {
    . (Join-Path $PSScriptRoot 'agent-hook-utils.ps1')
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'protected-path-policy.ps1')
} catch {
    Write-LocalGuardDeny
    exit 0
}

# PreToolUse guard for Edit/Write/MultiEdit. Blocks edits to .git internals and
# real secret files. Patterns are anchored to file names / extensions to avoid
# false positives on ordinary code (session.ts, tokenizer.py, cookie.js, etc.).

try {
$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
$raw = $reader.ReadToEnd()
$reader.Dispose()
if (-not $raw) {
    Write-HookDeny -HookEventName "PreToolUse" -Reason "Blocked: file guard received an empty hook event."
    exit 0
}

try {
    $event = $raw | ConvertFrom-Json
}
catch {
    Write-HookDeny -HookEventName "PreToolUse" -Reason "Blocked: file guard could not parse the hook event."
    exit 0
}

if (Test-ParallelToolName -Name (Get-HookToolName -Object $event)) {
    $parallelError = Get-HookParallelValidationError -Event $event -GuardKind File
    if ($parallelError) {
        Write-HookDeny -HookEventName "PreToolUse" -Reason (
            "Blocked: file guard could not fully inspect the parallel tool tree ({0})." -f $parallelError
        )
        exit 0
    }
}

try {
    $paths = @(Get-HookPaths -Event $event)
}
catch {
    Write-HookDeny -HookEventName "PreToolUse" -Reason "Blocked: file guard could not safely inspect the matched tool input."
    exit 0
}

if ($paths.Count -eq 0) {
    $toolNames = @(Get-HookToolNames -Event $event)
    $leafToolNames = @($toolNames | Where-Object { -not (Test-ParallelToolName -Name $_) })
    $hasFileTool = @($leafToolNames | Where-Object { Test-FileToolName -Name $_ }).Count -gt 0
    $hasOnlyNamedNonFileTools = ($leafToolNames.Count -gt 0 -and -not $hasFileTool)
    if ($hasOnlyNamedNonFileTools) {
        exit 0
    }
    Write-HookDeny -HookEventName "PreToolUse" -Reason "Blocked: file guard could not extract a path from a matched file event."
    exit 0
}

$reason = $null
$blockedPath = $null

foreach ($path in $paths) {
    $normalized = $path -replace "\\", "/"
    $leaf = Split-Path -Leaf $normalized

    if ($normalized -match '(?i)(^|/)\.git($|/)') {
        $reason = "Blocked: direct edits inside .git are not allowed."
    }
    else {
        $protectedReason = Get-ProtectedPathReason -Path $path -AllowDocumentationExamples
        if ($protectedReason) {
            $reason = "Blocked: {0}. Ask the user before editing secrets." -f $protectedReason
        }
    }

    if ($reason) {
        $blockedPath = $path
        break
    }
}

if ($reason) {
    try {
        Write-GuardAuditRecord `
            -GuardName "file-guard" `
            -Reason $reason `
            -ToolName (Get-HookToolName -Object $event) `
            -RawInput $blockedPath
    } catch { }
    Write-HookDeny -HookEventName "PreToolUse" -Reason $reason
}
} catch {
    Write-LocalGuardDeny
    exit 0
}

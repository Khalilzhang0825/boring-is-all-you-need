[CmdletBinding()]
param(
    [ValidateSet("Unified", "Command", "File")]
    [string]$GuardMode = "Command",
    [ValidateSet("Enforce", "Audit")]
    [string]$EnforcementMode = "Enforce"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$guardLabel = switch ($GuardMode) {
    "Command" { "command guard" }
    "File" { "file guard" }
    default { "unified guard" }
}

function Write-LocalGuardDeny {
    if ($EnforcementMode -eq "Audit") { return }
    @{
        hookSpecificOutput = @{
            hookEventName = "PreToolUse"
            permissionDecision = "deny"
            permissionDecisionReason = (
                "Blocked: {0} could not safely inspect the matched tool input." -f $guardLabel
            )
        }
    } | ConvertTo-Json -Depth 5 -Compress
}

try {
    . (Join-Path $PSScriptRoot 'agent-hook-utils.ps1')
    $script:SteadyAgentGuardEnforcementMode = $EnforcementMode
    if ($GuardMode -ne "Command") {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'protected-path-policy.ps1')
    }
} catch {
    Write-LocalGuardDeny
    exit 0
}

# Unified PreToolUse guard. The managed runtime invokes this process once for
# shell tools, file-edit tools, and mixed parallel wrappers. Compatibility
# callers may select one legacy guard surface with -GuardMode. Audit mode logs
# recognized risks but never returns a deny decision; authorization remains in
# the agent/user working contract.

try {
    $inputResult = Read-BoundedHookInput
    if ($inputResult.Exceeded) {
        Write-HookDeny -HookEventName "PreToolUse" -Reason (
            "Blocked: {0} hook input exceeds the safe byte limit." -f $guardLabel
        )
        exit 0
    }
    $raw = [string]$inputResult.Text
    if (-not $raw) {
        Write-HookDeny -HookEventName "PreToolUse" -Reason (
            "Blocked: {0} received an empty hook event." -f $guardLabel
        )
        exit 0
    }

    try {
        $event = $raw | ConvertFrom-Json
    }
    catch {
        Write-HookDeny -HookEventName "PreToolUse" -Reason (
            "Blocked: {0} could not parse the hook event." -f $guardLabel
        )
        exit 0
    }

    $checkCommands = $GuardMode -ne "File"
    $checkFiles = $GuardMode -ne "Command"
    $topToolName = Get-HookToolName -Object $event

    if (Test-ParallelToolName -Name $topToolName) {
        if ($checkCommands) {
            $parallelError = Get-HookParallelValidationError -Event $event -GuardKind Command
            if ($parallelError) {
                Write-HookDeny -HookEventName "PreToolUse" -Reason (
                    "Blocked: {0} could not fully inspect the parallel tool tree ({1})." -f
                        $guardLabel, $parallelError
                )
                exit 0
            }
        }
        if ($checkFiles) {
            $parallelError = Get-HookParallelValidationError -Event $event -GuardKind File
            if ($parallelError) {
                Write-HookDeny -HookEventName "PreToolUse" -Reason (
                    "Blocked: {0} could not fully inspect the parallel tool tree ({1})." -f
                        $guardLabel, $parallelError
                )
                exit 0
            }
        }
    }

    try {
        $toolNames = @(Get-HookToolNames -Event $event)
        $leafToolNames = @($toolNames | Where-Object {
            -not (Test-ParallelToolName -Name $_)
        })
    }
    catch {
        Write-HookDeny -HookEventName "PreToolUse" -Reason (
            "Blocked: {0} could not safely inspect the matched tool input." -f $guardLabel
        )
        exit 0
    }

    $hasShellTool = @($leafToolNames | Where-Object {
        Test-ShellToolName -Name $_
    }).Count -gt 0
    $hasFileTool = @($leafToolNames | Where-Object {
        Test-FileToolName -Name $_
    }).Count -gt 0

    if ($checkCommands -and $hasShellTool) {
        try {
            $commands = @(Get-HookCommands -Event $event)
        }
        catch {
            Write-HookDeny -HookEventName "PreToolUse" -Reason (
                "Blocked: {0} could not safely inspect the matched tool input." -f $guardLabel
            )
            exit 0
        }
        if ($commands.Count -eq 0) {
            Write-HookDeny -HookEventName "PreToolUse" -Reason (
                "Blocked: {0} could not extract a command from a matched shell event." -f $guardLabel
            )
            exit 0
        }

        try {
            $protectedRemovalRoots = @(Get-HookWorkingDirectories -Event $event)
        }
        catch {
            Write-HookDeny -HookEventName "PreToolUse" -Reason (
                "Blocked: {0} could not safely inspect the matched working directory." -f $guardLabel
            )
            exit 0
        }

        foreach ($candidate in $commands) {
            $reason = Test-DangerousCommand `
                -Command $candidate -ProtectedRemovalRoots $protectedRemovalRoots
            if (-not $reason) { continue }
            try {
                Write-GuardAuditRecord `
                    -GuardName $(if ($GuardMode -eq "Command") { "command-guard" } else { "unified-guard" }) `
                    -Reason $reason `
                    -ToolName $topToolName `
                    -RawInput $candidate
            } catch { }
            Write-HookDeny -HookEventName "PreToolUse" -Reason $reason
            if ($EnforcementMode -eq "Enforce") { exit 0 }
        }
    }

    if ($checkFiles -and $hasFileTool) {
        try {
            $paths = @(Get-HookPaths -Event $event)
        }
        catch {
            Write-HookDeny -HookEventName "PreToolUse" -Reason (
                "Blocked: {0} could not safely inspect the matched tool input." -f $guardLabel
            )
            exit 0
        }
        if ($paths.Count -eq 0) {
            Write-HookDeny -HookEventName "PreToolUse" -Reason (
                "Blocked: {0} could not extract a path from a matched file event." -f $guardLabel
            )
            exit 0
        }

        foreach ($path in $paths) {
            $normalized = $path -replace "\\", "/"
            $reason = $null
            if ($normalized -match '(?i)(^|/)\.git($|/)') {
                $reason = "Blocked: direct edits inside .git are not allowed."
            }
            else {
                $protectedReason = Get-ProtectedPathReason `
                    -Path $path -AllowDocumentationExamples
                if ($protectedReason) {
                    $reason = "Blocked: {0}. Ask the user before editing secrets." -f $protectedReason
                }
            }
            if (-not $reason) { continue }
            try {
                Write-GuardAuditRecord `
                    -GuardName $(if ($GuardMode -eq "File") { "file-guard" } else { "unified-guard" }) `
                    -Reason $reason `
                    -ToolName $topToolName `
                    -RawInput $path
            } catch { }
            Write-HookDeny -HookEventName "PreToolUse" -Reason $reason
            if ($EnforcementMode -eq "Enforce") { exit 0 }
        }
    }

    if ($leafToolNames.Count -eq 0) {
        Write-HookDeny -HookEventName "PreToolUse" -Reason (
            "Blocked: {0} could not safely inspect the matched tool input." -f $guardLabel
        )
    }
} catch {
    Write-LocalGuardDeny
    exit 0
}

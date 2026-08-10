#requires -Version 7.5
[CmdletBinding()]
param()

# Compatibility entry point for existing direct callers. The managed runtime
# uses agent-hook-command-guard.ps1 in Unified mode and starts only one process.
$unifiedGuard = Join-Path $PSScriptRoot 'agent-hook-command-guard.ps1'
if (-not (Test-Path -LiteralPath $unifiedGuard -PathType Leaf)) {
    @{
        hookSpecificOutput = @{
            hookEventName = "PreToolUse"
            permissionDecision = "deny"
            permissionDecisionReason = "Blocked: file guard could not safely inspect the matched tool input."
        }
    } | ConvertTo-Json -Depth 5 -Compress
    exit 0
}
& $unifiedGuard -GuardMode File

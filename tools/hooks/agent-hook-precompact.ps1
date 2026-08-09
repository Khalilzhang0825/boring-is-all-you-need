#requires -Version 7.5
[CmdletBinding()]
param()

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("[PRE-COMPACT] Compaction is about to run. Preserve current goal, decisions, progress, next steps, pending verification, constraints, and do-not items.")
$lines.Add("Ensure PROJECT_STATE.md or .agent/state.md is current before compaction; SessionStart can re-inject it after compaction.")
$text = ($lines -join "`n")

@{
    systemMessage = $text
} | ConvertTo-Json -Depth 5 -Compress

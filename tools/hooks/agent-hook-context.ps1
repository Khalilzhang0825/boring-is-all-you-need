[CmdletBinding()]
param()

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$source = ""
$cwd = ""
try {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    $reader.Dispose()
    if ($raw) {
        $event = $raw | ConvertFrom-Json
        if ($event.PSObject.Properties.Name -contains "source") { $source = [string]$event.source }
        if ($event.PSObject.Properties.Name -contains "cwd") { $cwd = [string]$event.cwd }
    }
} catch { }

function Find-StateFile {
    param([string]$StartDirectory)
    if (-not $StartDirectory) { return $null }
    $dir = $StartDirectory
    for ($depth = 0; $depth -lt 8 -and $dir; $depth++) {
        foreach ($candidate in @(
            (Join-Path $dir "PROJECT_STATE.md"),
            (Join-Path $dir ".agent/state.md")
        )) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("SteadyAgent Codex host contract:")
$lines.Add("- Read the closest AGENTS.md plus project state before editing.")
$lines.Add("- Keep context lean; load detailed rules only when needed.")
$lines.Add("- Run preflight before edits and verify before claiming completion.")
$lines.Add("- Multi-file changes alone do not require independent review; use review for real risk or an explicit request.")
$lines.Add("- Use explicit-file checkpoint commits; do not push unless asked.")

if ($source -eq "compact" -or $source -eq "resume") {
    $lines.Add("")
    $stateFile = Find-StateFile -StartDirectory $cwd
    if ($stateFile) {
        $lines.Add(("[TASK STATE restored after {0}] source = {1}. Treat this as current working state:" -f $source, $stateFile))
        $lines.Add("--- TASK STATE ---")
        $stateLines = [System.IO.File]::ReadAllLines($stateFile, [System.Text.Encoding]::UTF8)
        $max = 120
        $n = [Math]::Min($stateLines.Count, $max)
        for ($i = 0; $i -lt $n; $i++) { $lines.Add($stateLines[$i]) }
        if ($stateLines.Count -gt $max) { $lines.Add(("... [truncated {0} more lines; open the file if needed]" -f ($stateLines.Count - $max))) }
        $lines.Add("--- end TASK STATE ---")
    }
    else {
        $lines.Add(("[TASK STATE] No PROJECT_STATE.md or .agent/state.md found from {0}. If mid-task, rebuild state from durable logs instead of trusting the summary alone." -f $cwd))
    }
}

$text = ($lines -join "`n")
@{
    hookSpecificOutput = @{
        hookEventName = "SessionStart"
        additionalContext = $text
    }
} | ConvertTo-Json -Depth 5 -Compress

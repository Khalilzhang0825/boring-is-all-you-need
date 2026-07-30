[CmdletBinding()]
param([string]$SteadyAgentHome = "")

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

if (-not $SteadyAgentHome) {
    $SteadyAgentHome = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}
else {
    $SteadyAgentHome = [IO.Path]::GetFullPath($SteadyAgentHome)
}

$source = ""
$cwd = ""
try {
    $reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    $reader.Dispose()
    if ($raw) {
        $event = $raw | ConvertFrom-Json
        if ($event.PSObject.Properties.Name -contains "source") { $source = [string]$event.source }
        if ($event.PSObject.Properties.Name -contains "cwd") { $cwd = [string]$event.cwd }
    }
}
catch { }

function Find-StateFile {
    param([string]$StartDirectory)
    if (-not $StartDirectory) { return $null }
    $directory = $StartDirectory
    for ($depth = 0; $depth -lt 8 -and $directory; $depth++) {
        foreach ($candidate in @(
            (Join-Path $directory "PROJECT_STATE.md"),
            (Join-Path $directory ".agent/state.md")
        )) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
        $parent = Split-Path -Parent $directory
        if ($parent -eq $directory) { break }
        $directory = $parent
    }
    return $null
}

function Get-CavemanStatusLine {
    param([string]$Root)
    $mode = "lite"
    $sourceLabel = "SteadyAgent default"
    $configPath = Join-Path $Root "config\caveman.json"
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($config.PSObject.Properties.Name -contains "defaultMode" -and [string]$config.defaultMode) {
                $mode = [string]$config.defaultMode
                $sourceLabel = "local config defaultMode"
            }
        }
        catch { }
    }
    if ($mode -eq "off") {
        return "Caveman startup status report: OFF, mode off, source: " + $sourceLabel + "."
    }
    return "Caveman startup status report: ON, mode " + $mode + ", source: " + $sourceLabel + "."
}

function Add-LessonsIndex {
    param(
        [Collections.Generic.List[string]]$Lines,
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $titles = New-Object Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("### ")) {
            $title = $trimmed.Substring(4).Trim()
            if ($title) { $titles.Add($title) }
        }
    }
    if ($titles.Count -eq 0) { return }
    $Lines.Add("")
    $Lines.Add(("Known pitfalls to avoid (full detail in {0}):" -f $Path))
    $budget = 300
    $shown = 0
    $selected = New-Object Collections.Generic.List[string]
    for ($index = 0; $index -lt $titles.Count; $index++) {
        $candidate = "  {0}. {1}" -f ($index + 1), $titles[$index]
        $remaining = $titles.Count - ($shown + 1)
        $projection = @($selected) + @($candidate)
        if ($remaining -gt 0) {
            $projection += "  ... {0} more pitfall title(s); see lessons.md" -f $remaining
        }
        if (($projection -join "`n").Length -gt $budget) { break }
        $selected.Add($candidate)
        $shown++
    }
    foreach ($item in $selected) { $Lines.Add($item) }
    if ($titles.Count -gt $shown) {
        $Lines.Add(("  ... {0} more pitfall title(s); see lessons.md" -f ($titles.Count - $shown)))
    }
}

$lines = New-Object Collections.Generic.List[string]
$lines.Add("SteadyAgent Codex host contract:")
$lines.Add("- Read the closest AGENTS.md plus project state before editing.")
$lines.Add("- Keep context lean; load detailed rules only when needed.")
$lines.Add("- Run preflight before edits and verify before claiming completion.")
$lines.Add("- Multi-file changes alone do not require independent review; use review for real risk or an explicit request.")
$lines.Add("- Use explicit-file checkpoint commits; do not push unless asked.")

if ($source -eq "startup" -or -not $source) {
    $lines.Add("")
    $lines.Add("[CAVEMAN STARTUP STATUS]")
    $lines.Add((Get-CavemanStatusLine -Root $SteadyAgentHome))
    $lines.Add("Required visible opening for the first assistant response in this new conversation: address the user, report Caveman enabled/disabled and mode in one short sentence, then answer.")
}

Add-LessonsIndex -Lines $lines -Path (Join-Path $SteadyAgentHome "rules\lessons.md")

if ($source -eq "compact" -or $source -eq "resume") {
    $lines.Add("")
    $stateFile = Find-StateFile -StartDirectory $cwd
    if ($stateFile) {
        $lines.Add(("[TASK STATE restored after {0}] source = {1}. Treat this as current working state:" -f $source, $stateFile))
        $lines.Add("--- TASK STATE ---")
        $stateLines = [IO.File]::ReadAllLines($stateFile, [Text.Encoding]::UTF8)
        $maximum = 120
        $count = [Math]::Min($stateLines.Count, $maximum)
        for ($index = 0; $index -lt $count; $index++) { $lines.Add($stateLines[$index]) }
        if ($stateLines.Count -gt $maximum) {
            $lines.Add(("... [truncated {0} more lines; open the file if needed]" -f ($stateLines.Count - $maximum)))
        }
        $lines.Add("--- end TASK STATE ---")
    }
    else {
        $lines.Add(("[TASK STATE] No PROJECT_STATE.md or .agent/state.md found from {0}. If mid-task, rebuild state from durable logs instead of trusting the summary alone." -f $cwd))
    }
}

$reviewMarker = Join-Path $SteadyAgentHome ".harness-last-review"
$reviewDue = $true
$daysSince = $null
try {
    if (Test-Path -LiteralPath $reviewMarker -PathType Leaf) {
        $rawMarker = Get-Content -LiteralPath $reviewMarker -Raw -Encoding UTF8
        $parsed = [datetime]::MinValue
        if ($rawMarker -and [datetime]::TryParseExact(
            $rawMarker.Trim(),
            "yyyy-MM-dd",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$parsed
        )) {
            $daysSince = [int]((Get-Date) - $parsed).TotalDays
            $reviewDue = ([Math]::Abs($daysSince) -ge 90)
        }
    }
}
catch { $reviewDue = $true }
if ($reviewDue) {
    $lines.Add("")
    if ($null -ne $daysSince) {
        $lines.Add(("[HARNESS-REVIEW DUE] Last config review {0} days ago. Run the checklist in rules\harness-review.md." -f $daysSince))
    }
    else {
        $lines.Add("[HARNESS-REVIEW DUE] No valid config review on record. Run the checklist in rules\harness-review.md.")
    }
}

@{
    hookSpecificOutput = @{
        hookEventName = "SessionStart"
        additionalContext = ($lines -join "`n")
    }
} | ConvertTo-Json -Depth 5 -Compress

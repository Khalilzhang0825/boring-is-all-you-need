[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "skill-catalog-resolver.ps1")

$script:Passed = 0
$script:Failed = 0
$script:Results = @{}
$script:AssertionNames = New-Object Collections.Generic.List[string]
$script:RequiredDefaultCaseCount = 69
$script:RequiredRolloutFileCanaryCaseCount = 76
$script:RequiredDefaultCaseSetSha256 = "EF25BDC297AA7402B1EC8D3B42A6F7B70C9EA94CA92FA336AD280301BD4134E7"
$script:RequiredRolloutFileCanaryCaseSetSha256 = "6AAF6F06C85B1165317DAA376BE3F371885A8293632BAB6B64402388C353A13A"
$script:RequiredDefaultCases = @(
    "Desktop rollout cannot be labeled CLI",
    "CLI rollout cannot be labeled Desktop",
    "Repeated rollout metadata rejects a blank originator",
    "Repeated rollout metadata rejects inconsistent originators",
    "Repeated rollout metadata accepts one consistent originator",
    "Rollout metadata rejects a foreign owning thread",
    "Rollout metadata accepts inherited parent history without changing owner host",
    "Inherited history with the same skills catalog remains usable",
    "Inherited history with a distinct skills catalog fails closed",
    "Two distinct skills catalogs in one input part fail closed",
    "Case-only distinct skills catalogs fail closed",
    "A complete skills catalog followed by a dangling tag fails closed",
    "Rollout rejects a malformed later skills line",
    "Rollout rejects a malformed session metadata line",
    "rollout-file snapshot binds host and skills to one captured rollout read",
    "rollout-file snapshot rejects inconsistent owner metadata appended before its read",
    "catalog fixture builds",
    "schema v2",
    "snapshot id present",
    "fixture visibility is explicit",
    "thread id retained",
    "exact advertised count",
    "unadvertised file excluded",
    "rollout prompt description used",
    "block scalar marker not indexed",
    "qualified plugin name retained",
    "prompt hash present",
    "skills digest present",
    "JSON and Markdown content agree",
    "search accepts matching catalog",
    "Chinese review query resolves code-review",
    "search ignores filesystem path",
    "stale thread fails closed",
    "malformed block fails closed",
    "failed rebuild preserves prior JSON",
    "RolloutPath cannot self-certify production evidence",
    "thread A publishes independently",
    "thread B publishes independently",
    "thread catalogs use different directories",
    "same-thread concurrent publishers both succeed",
    "same-thread concurrent publish yields one snapshot",
    "same-thread concurrent publish leaves no temp directory",
    "temp-directory detector catches production naming",
    "synthetic rollout file is labeled rollout-file-confirmed",
    "production catalog freezes canonical rollout evidence",
    "bound production search does not rediscover the sessions tree",
    "bound production search ignores unrelated malformed growth",
    "bound production search rejects rollout replacement",
    "bound production search rejects rollout truncation",
    "bound production search rejects frozen skills drift",
    "bound production search accepts repeated identical skills evidence",
    "bound production search rejects appended distinct skills evidence",
    "bound production search rejects appended session identity drift",
    "production discovery requires CODEX_THREAD_ID",
    "synthetic production discovery rejects a caller-supplied wrong host",
    "production search requires CODEX_THREAD_ID",
    "production search rejects a caller-supplied wrong thread",
    "default index catalog follows the installed tools parent",
    "default search catalog follows the installed tools parent",
    "resolver default catalog follows the installed tools parent",
    "strict diagnosis validates rollout-file-confirmed catalog consistency",
    "strict diagnosis requires manual Codex Live acceptance",
    "strict diagnosis never promotes filesystem times or runtime-confirmed evidence",
    "Catalog metadata retains owning task start timestamp",
    "Inherited parent timestamp cannot replace owning task timestamp",
    "Strict catalog timing rejects missing task timestamp",
    "Strict catalog timing rejects invalid task timestamp",
    "Strict catalog timing rejects an old task",
    "Strict catalog timing accepts a newer task"
)
$script:RequiredRolloutFileCanaryCases = @(
    "actual rollout rejects caller-supplied wrong host",
    "actual rollout publishes rollout-file-confirmed evidence",
    "concurrent tampered Markdown searches both fail closed",
    "tampered Markdown is not rewritten or quarantined",
    "restoring canonical Markdown restores search",
    "damaged snapshot fails closed",
    "damaged snapshot is not rewritten or quarantined"
)

function Test-ExactCaseSet {
    param([string[]]$Actual, [string[]]$Expected)
    if (@($Actual).Count -ne @($Expected).Count) { return $false }
    if (@($Actual | Select-Object -Unique).Count -ne @($Actual).Count) { return $false }
    $actualSorted = [string[]]@($Actual)
    $expectedSorted = [string[]]@($Expected)
    [Array]::Sort($actualSorted, [StringComparer]::Ordinal)
    [Array]::Sort($expectedSorted, [StringComparer]::Ordinal)
    for ($index = 0; $index -lt $actualSorted.Count; $index++) {
        if ([string]$actualSorted[$index] -cne [string]$expectedSorted[$index]) {
            return $false
        }
    }
    return $true
}

function Get-CatalogCaseSetSha256 {
    param([string[]]$Cases)
    $canonical = [string[]]@($Cases)
    [Array]::Sort($canonical, [StringComparer]::Ordinal)
    $text = $canonical -join [char]10
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition)
    $script:AssertionNames.Add($Name) | Out-Null
    $script:Results[$Name] = $Condition
    if ($Condition) {
        Write-Host ("PASS  {0}" -f $Name)
        $script:Passed++
    } else {
        Write-Host ("FAIL  {0}" -f $Name)
        $script:Failed++
    }
}

function Write-SemanticCheck {
    param([string]$Id, [string[]]$Cases)
    $missing = @($Cases | Where-Object {
        -not $script:Results.ContainsKey($_) -or -not [bool]$script:Results[$_]
    })
    if ($missing.Count -eq 0) {
        Write-Host ("SEMANTIC PASS " + $Id)
    } else {
        Write-Host ("FAIL  semantic evidence " + $Id + " missing=" + ($missing -join ","))
        $script:Failed++
    }
}

function Start-ScriptProcess {
    param([string]$ScriptPath, [string[]]$Arguments)
    $quoted = @($Arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' })
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" ' + ($quoted -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return [Diagnostics.Process]::Start($psi)
}

function Complete-ScriptProcess {
    param([Diagnostics.Process]$Process)
    $stdout = $Process.StandardOutput.ReadToEnd()
    $stderr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $Process.ExitCode
        Output = $stdout
        Error = $stderr
    }
}

function Invoke-Script {
    param([string]$ScriptPath, [string[]]$Arguments)
    $process = Start-ScriptProcess -ScriptPath $ScriptPath -Arguments $Arguments
    return Complete-ScriptProcess -Process $process
}

$diagnoseText = Get-Content -LiteralPath (Join-Path $PSScriptRoot "diagnose-install.ps1") -Raw -Encoding UTF8
Assert-True "strict diagnosis validates rollout-file-confirmed catalog consistency" (
    $diagnoseText -match "Test-RolloutFileCatalogSnapshot" -and
    $diagnoseText -match "current task rollout-file-confirmed catalog is internally consistent"
)
Assert-True "strict diagnosis requires manual Codex Live acceptance" (
    $diagnoseText -match "manual Codex Live acceptance is still required" -and
    $diagnoseText -match "rollout/config files cannot prove Live activation"
)
Assert-True "strict diagnosis never promotes filesystem times or runtime-confirmed evidence" (
    $diagnoseText -notmatch "CreationTimeUtc" -and
    $diagnoseText -notmatch "runtime-confirmed" -and
    $diagnoseText -match "Assert-CatalogSessionStartedAfterReceipt"
)

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ("skill-catalog-test-" + [guid]::NewGuid().ToString("N"))
$testRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $testRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Test root escaped the system temp directory."
}

try {
    $root0 = Join-Path $testRoot "root0"
    $root1 = Join-Path $testRoot "root1"
    $alphaDir = Join-Path $root0 "alpha"
    $codeReviewDir = Join-Path $root0 "code-review"
    $betaDir = Join-Path $root1 "bundle\skills\beta"
    $hiddenDir = Join-Path $root0 "path-only-token"
    New-Item -ItemType Directory -Force -Path $alphaDir, $codeReviewDir, $betaDir, $hiddenDir | Out-Null
    Set-Content -LiteralPath (Join-Path $alphaDir "SKILL.md") -Encoding UTF8 -Value @(
        "---"
        "name: alpha"
        "description: Alpha fixture for runtime lookup."
        "---"
        "# Alpha"
    )
    Set-Content -LiteralPath (Join-Path $codeReviewDir "SKILL.md") -Encoding UTF8 -Value @(
        "---"
        "name: code-review"
        "description: Review code changes against standards and specs."
        "---"
        "# Code Review"
    )
    Set-Content -LiteralPath (Join-Path $betaDir "SKILL.md") -Encoding UTF8 -Value @(
        "---"
        "name: beta"
        "description: >"
        "  Frontmatter block scalar must not replace the runtime prompt description."
        "---"
        "# Beta"
    )
    Set-Content -LiteralPath (Join-Path $hiddenDir "SKILL.md") -Encoding UTF8 -Value @(
        "---"
        "name: hidden"
        "description: Must not be discovered by filesystem scanning."
        "---"
        "# Hidden"
    )

    $skillsText = @"
<skills_instructions>
## Skills
### Skill roots
- ``r0`` = ``$($root0 -replace '\\','/')``
- ``r1`` = ``$($root1 -replace '\\','/')``
### Available skills
- alpha: prompt description (file: r0/alpha/SKILL.md)
- pluginx:beta: prompt description (file: r1/bundle/skills/beta/SKILL.md)
- code-review: Review code changes against standards and specs. (file: r0/code-review/SKILL.md)
</skills_instructions>
"@
    $fixture = Join-Path $testRoot "runtime.jsonl"
    $event = [ordered]@{
        type = "response_item"
        payload = [ordered]@{
            type = "message"
            role = "developer"
            content = @([ordered]@{ type = "input_text"; text = $skillsText })
        }
    }
    Set-Content -LiteralPath $fixture -Encoding UTF8 -Value ($event | ConvertTo-Json -Compress -Depth 8)

    $desktopRollout = Join-Path $testRoot "desktop-session.jsonl"
    $cliRollout = Join-Path $testRoot "cli-session.jsonl"
    $blankOriginatorRollout = Join-Path $testRoot "blank-originator-session.jsonl"
    $inconsistentOriginatorRollout = Join-Path $testRoot "inconsistent-originator-session.jsonl"
    $repeatedOriginatorRollout = Join-Path $testRoot "repeated-originator-session.jsonl"
    $foreignThreadRollout = Join-Path $testRoot "foreign-thread-session.jsonl"
    $inheritedThreadRollout = Join-Path $testRoot "inherited-thread-session.jsonl"
    $inheritedDifferentCatalogRollout = Join-Path $testRoot "inherited-different-catalog-session.jsonl"
    $samePartDistinctCatalogRollout = Join-Path $testRoot "same-part-distinct-catalog-session.jsonl"
    $caseDistinctCatalogRollout = Join-Path $testRoot "case-distinct-catalog-session.jsonl"
    $danglingCatalogTagRollout = Join-Path $testRoot "dangling-catalog-tag-session.jsonl"
    $malformedSkillsRollout = Join-Path $testRoot "malformed-skills-session.jsonl"
    $malformedMetadataRollout = Join-Path $testRoot "malformed-metadata-session.jsonl"
    $singleReadRollout = Join-Path $testRoot "single-read-session.jsonl"
    $timestampedRollout = Join-Path $testRoot "timestamped-session.jsonl"
    Set-Content -LiteralPath $desktopRollout -Encoding UTF8 -Value (
        @{ type = "session_meta"; payload = @{ id = "desktop-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4
    )
    Set-Content -LiteralPath $cliRollout -Encoding UTF8 -Value (
        @{ type = "session_meta"; payload = @{ id = "cli-thread"; originator = "codex-tui" } } |
            ConvertTo-Json -Compress -Depth 4
    )
    Set-Content -LiteralPath $blankOriginatorRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "blank-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        (@{ type = "session_meta"; payload = @{ id = "blank-thread"; originator = "" } } |
            ConvertTo-Json -Compress -Depth 4)
    )
    Set-Content -LiteralPath $inconsistentOriginatorRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "inconsistent-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        (@{ type = "session_meta"; payload = @{ id = "inconsistent-thread"; originator = "codex-tui" } } |
            ConvertTo-Json -Compress -Depth 4)
    )
    Set-Content -LiteralPath $repeatedOriginatorRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "repeated-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        (@{ type = "session_meta"; payload = @{ id = "repeated-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
    )
    $skillsEventLine = $event | ConvertTo-Json -Compress -Depth 8
    $differentSkillsEventLine = $skillsEventLine.Replace(
        "Review code changes against standards and specs.",
        "Review an inherited catalog with different content."
    )
    $differentSkillsText = $skillsText.Replace(
        "Review code changes against standards and specs.",
        "Review an inherited catalog with different content."
    )
    $samePartDistinctEventLine = ([ordered]@{
        type = "response_item"
        payload = [ordered]@{
            type = "message"
            role = "developer"
            content = @([ordered]@{
                type = "input_text"
                text = $skillsText + "`n" + $differentSkillsText
            })
        }
    } | ConvertTo-Json -Compress -Depth 8)
    $caseDistinctSkillsText = $skillsText.Replace("code-review", "Code-Review")
    $caseDistinctEventLine = ([ordered]@{
        type = "response_item"
        payload = [ordered]@{
            type = "message"
            role = "developer"
            content = @([ordered]@{
                type = "input_text"
                text = $skillsText + "`n" + $caseDistinctSkillsText
            })
        }
    } | ConvertTo-Json -Compress -Depth 8)
    $danglingCatalogTagEventLine = ([ordered]@{
        type = "response_item"
        payload = [ordered]@{
            type = "message"
            role = "developer"
            content = @([ordered]@{
                type = "input_text"
                text = $skillsText + "`n<skills_instructions>"
            })
        }
    } | ConvertTo-Json -Compress -Depth 8)
    Set-Content -LiteralPath $foreignThreadRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "foreign-thread"; originator = "codex-tui" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
        (@{ type = "session_meta"; payload = @{ id = "victim-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
    )
    Set-Content -LiteralPath $inheritedThreadRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "child-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
        (@{ type = "session_meta"; payload = @{ id = "parent-thread"; originator = "codex-tui" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
    )
    Set-Content -LiteralPath $inheritedDifferentCatalogRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "child-different-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
        (@{ type = "session_meta"; payload = @{ id = "parent-different-thread"; originator = "codex-tui" } } |
            ConvertTo-Json -Compress -Depth 4)
        $differentSkillsEventLine
    )
    Set-Content -LiteralPath $samePartDistinctCatalogRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "same-part-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $samePartDistinctEventLine
    )
    Set-Content -LiteralPath $caseDistinctCatalogRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "case-distinct-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $caseDistinctEventLine
    )
    Set-Content -LiteralPath $danglingCatalogTagRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "dangling-tag-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $danglingCatalogTagEventLine
    )
    Set-Content -LiteralPath $malformedSkillsRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "malformed-skills-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
        '{"type":"response_item"'
    )
    Set-Content -LiteralPath $malformedMetadataRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "malformed-metadata-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
        '{"type":"session_meta"'
    )
    Set-Content -LiteralPath $singleReadRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "single-read-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
    )
    Set-Content -LiteralPath $timestampedRollout -Encoding UTF8 -Value @(
        (@{ timestamp = "2026-08-03T12:00:01.0000000Z"; type = "session_meta"; payload = @{ id = "timestamped-thread"; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
        (@{ timestamp = "2026-08-03T13:00:01.0000000Z"; type = "session_meta"; payload = @{ id = "parent-thread"; originator = "codex-tui" } } |
            ConvertTo-Json -Compress -Depth 4)
    )
    $desktopMismatchBlocked = $false
    $cliMismatchBlocked = $false
    $blankOriginatorBlocked = $false
    $inconsistentOriginatorBlocked = $false
    $foreignThreadBlocked = $false
    $inheritedThreadHost = $null
    $inheritedDifferentCatalogBlocked = $false
    $samePartDistinctCatalogBlocked = $false
    $caseDistinctCatalogBlocked = $false
    $danglingCatalogTagBlocked = $false
    $malformedSkillsBlocked = $false
    $malformedMetadataBlocked = $false
    try {
        Resolve-CatalogHostForRollout -HostSurface "CodexCli" -RolloutPath $desktopRollout -ThreadId "desktop-thread" | Out-Null
    }
    catch { $desktopMismatchBlocked = $true }
    try {
        Resolve-CatalogHostForRollout -HostSurface "CodexDesktop" -RolloutPath $cliRollout -ThreadId "cli-thread" | Out-Null
    }
    catch { $cliMismatchBlocked = $true }
    try {
        Resolve-CatalogHostForRollout -HostSurface "Auto" -RolloutPath $blankOriginatorRollout -ThreadId "blank-thread" | Out-Null
    }
    catch { $blankOriginatorBlocked = $true }
    try {
        Resolve-CatalogHostForRollout -HostSurface "Auto" -RolloutPath $inconsistentOriginatorRollout -ThreadId "inconsistent-thread" | Out-Null
    }
    catch { $inconsistentOriginatorBlocked = $true }
    try {
        Resolve-CatalogHostForRollout -HostSurface "Auto" -RolloutPath $foreignThreadRollout -ThreadId "victim-thread" | Out-Null
    }
    catch { $foreignThreadBlocked = $true }
    $inheritedThreadHost = Resolve-CatalogHostForRollout `
        -HostSurface "Auto" `
        -RolloutPath $inheritedThreadRollout `
        -ThreadId "child-thread"
    try {
        Get-CatalogSkillsBlock -RolloutPath $inheritedDifferentCatalogRollout | Out-Null
    }
    catch { $inheritedDifferentCatalogBlocked = $true }
    try {
        Get-CatalogSkillsBlock -RolloutPath $samePartDistinctCatalogRollout | Out-Null
    }
    catch { $samePartDistinctCatalogBlocked = $true }
    try {
        Get-CatalogSkillsBlock -RolloutPath $caseDistinctCatalogRollout | Out-Null
    }
    catch { $caseDistinctCatalogBlocked = $true }
    try {
        Get-CatalogSkillsBlock -RolloutPath $danglingCatalogTagRollout | Out-Null
    }
    catch { $danglingCatalogTagBlocked = $true }
    try {
        Resolve-CatalogHostForRollout -HostSurface "Auto" -RolloutPath $malformedSkillsRollout -ThreadId "malformed-skills-thread" | Out-Null
    }
    catch { $malformedSkillsBlocked = $true }
    try {
        Resolve-CatalogHostForRollout -HostSurface "Auto" -RolloutPath $malformedMetadataRollout -ThreadId "malformed-metadata-thread" | Out-Null
    }
    catch { $malformedMetadataBlocked = $true }
    $repeatedOriginatorHost = Resolve-CatalogHostForRollout -HostSurface "Auto" -RolloutPath $repeatedOriginatorRollout -ThreadId "repeated-thread"
    Assert-True "Desktop rollout cannot be labeled CLI" $desktopMismatchBlocked
    Assert-True "CLI rollout cannot be labeled Desktop" $cliMismatchBlocked
    Assert-True "Repeated rollout metadata rejects a blank originator" $blankOriginatorBlocked
    Assert-True "Repeated rollout metadata rejects inconsistent originators" $inconsistentOriginatorBlocked
    Assert-True "Repeated rollout metadata accepts one consistent originator" ($repeatedOriginatorHost -eq "codex-desktop")
    Assert-True "Rollout metadata rejects a foreign owning thread" $foreignThreadBlocked
    Assert-True "Rollout metadata accepts inherited parent history without changing owner host" (
        $inheritedThreadHost -eq "codex-desktop"
    )
    Assert-True "Inherited history with the same skills catalog remains usable" (
        -not [string]::IsNullOrWhiteSpace((Get-CatalogSkillsBlock -RolloutPath $inheritedThreadRollout))
    )
    Assert-True "Inherited history with a distinct skills catalog fails closed" $inheritedDifferentCatalogBlocked
    Assert-True "Two distinct skills catalogs in one input part fail closed" $samePartDistinctCatalogBlocked
    Assert-True "Case-only distinct skills catalogs fail closed" $caseDistinctCatalogBlocked
    Assert-True "A complete skills catalog followed by a dangling tag fails closed" $danglingCatalogTagBlocked
    Assert-True "Rollout rejects a malformed later skills line" $malformedSkillsBlocked
    Assert-True "Rollout rejects a malformed session metadata line" $malformedMetadataBlocked

    $timestampedMetadata = Get-CatalogSessionMetadata `
        -RolloutPath $timestampedRollout `
        -ThreadId "timestamped-thread"
    $metadataStartedUtc = $null
    if ($timestampedMetadata.PSObject.Properties.Name -contains "started_utc") {
        $metadataStartedUtc = [string]$timestampedMetadata.started_utc
    }
    Assert-True "Catalog metadata retains owning task start timestamp" (
        $metadataStartedUtc -eq "2026-08-03T12:00:01.0000000Z"
    )
    Assert-True "Inherited parent timestamp cannot replace owning task timestamp" (
        $metadataStartedUtc -ne "2026-08-03T13:00:01.0000000Z"
    )

    $timingGuard = Get-Command Assert-CatalogSessionStartedAfterReceipt -ErrorAction SilentlyContinue
    $missingTimestampBlocked = $false
    $invalidTimestampBlocked = $false
    $oldTaskBlocked = $false
    $newTaskAccepted = $false
    if ($timingGuard) {
        try { Assert-CatalogSessionStartedAfterReceipt -SessionStartedUtc "" -ReceiptCompletedUtc "2026-08-03T12:00:00Z" }
        catch { $missingTimestampBlocked = $true }
        try { Assert-CatalogSessionStartedAfterReceipt -SessionStartedUtc "not-a-time" -ReceiptCompletedUtc "2026-08-03T12:00:00Z" }
        catch { $invalidTimestampBlocked = $true }
        try { Assert-CatalogSessionStartedAfterReceipt -SessionStartedUtc "2026-08-03T11:59:59Z" -ReceiptCompletedUtc "2026-08-03T12:00:00Z" }
        catch { $oldTaskBlocked = $true }
        try {
            Assert-CatalogSessionStartedAfterReceipt -SessionStartedUtc "2026-08-03T12:00:01Z" -ReceiptCompletedUtc "2026-08-03T12:00:00Z"
            $newTaskAccepted = $true
        }
        catch { }
    }
    Assert-True "Strict catalog timing rejects missing task timestamp" $missingTimestampBlocked
    Assert-True "Strict catalog timing rejects invalid task timestamp" $invalidTimestampBlocked
    Assert-True "Strict catalog timing rejects an old task" $oldTaskBlocked
    Assert-True "Strict catalog timing accepts a newer task" $newTaskAccepted

    $capturedRolloutLines = @(Read-CatalogRolloutLines -Path $singleReadRollout)
    Add-Content -LiteralPath $singleReadRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = "single-read-thread"; originator = "codex-tui" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
    )
    $oldCatalogTestMode = $env:STEADYAGENT_TEST_MODE
    $singleReadSnapshot = $null
    $changedRolloutBlocked = $false
    try {
        $env:STEADYAGENT_TEST_MODE = "1"
        $singleReadSnapshot = Resolve-RolloutFileCatalogSnapshot `
            -HostSurface "Auto" `
            -ThreadId "single-read-thread" `
            -CatalogRoot (Join-Path $testRoot "single-read-catalog") `
            -RolloutPath $singleReadRollout `
            -RolloutLines $capturedRolloutLines
        try {
            Resolve-RolloutFileCatalogSnapshot `
                -HostSurface "Auto" `
                -ThreadId "single-read-thread" `
                -CatalogRoot (Join-Path $testRoot "changed-catalog") `
                -RolloutPath $singleReadRollout | Out-Null
        }
        catch { $changedRolloutBlocked = $true }
    }
    finally {
        if ($null -eq $oldCatalogTestMode) { Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_MODE = $oldCatalogTestMode }
    }
    Assert-True "rollout-file snapshot binds host and skills to one captured rollout read" (
        $null -ne $singleReadSnapshot -and
        [string]$singleReadSnapshot.Host -eq "codex-desktop" -and
        [string]$singleReadSnapshot.ThreadId -eq "single-read-thread"
    )
    Assert-True "rollout-file snapshot rejects inconsistent owner metadata appended before its read" $changedRolloutBlocked

    $jsonPath = Join-Path $testRoot "skill-index.json"
    $markdownPath = Join-Path $testRoot "skill-index.md"
    $indexScript = Join-Path $PSScriptRoot "skill-index.ps1"
    $searchScript = Join-Path $PSScriptRoot "skill-search.ps1"
    $indexArgs = @(
        "-HostSurface", "CodexDesktop",
        "-FixtureMode",
        "-ThreadId", "fixture-thread",
        "-RolloutPath", $fixture,
        "-JsonPath", $jsonPath,
        "-MarkdownPath", $markdownPath
    )
    $result = Invoke-Script -ScriptPath $indexScript -Arguments $indexArgs
    Assert-True "catalog fixture builds" ($result.ExitCode -eq 0)

    $catalog = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    Assert-True "schema v2" ([int]$catalog.schema_version -eq 2)
    Assert-True "snapshot id present" ([string]$catalog.snapshot_id -match "^codex-desktop:fixture-thread:[A-F0-9]{64}$")
    Assert-True "fixture visibility is explicit" ([string]$catalog.visibility -eq "fixture-confirmed")
    Assert-True "thread id retained" ([string]$catalog.thread_id -eq "fixture-thread")
    Assert-True "exact advertised count" (@($catalog.skills).Count -eq 3)
    Assert-True "unadvertised file excluded" (-not (@($catalog.skills.name) -contains "hidden"))
    Assert-True "rollout prompt description used" ([string]$catalog.skills[0].description -eq "prompt description")
    Assert-True "block scalar marker not indexed" (-not (@($catalog.skills.description) -contains ">"))
    Assert-True "qualified plugin name retained" (@($catalog.skills.name) -contains "pluginx:beta")
    Assert-True "prompt hash present" ([string]$catalog.skills_prompt_sha256 -match "^[A-F0-9]{64}$")
    Assert-True "skills digest present" ([string]$catalog.skills_sha256 -match "^[A-F0-9]{64}$")
    $markdown = Get-Content -LiteralPath $markdownPath -Raw -Encoding UTF8
    Assert-True "JSON and Markdown content agree" ($markdown -ceq (Get-CatalogMarkdown -Catalog $catalog))

    $search = Invoke-Script -ScriptPath $searchScript -Arguments @(
        "-Query", "alpha",
        "-JsonPath", $jsonPath,
        "-HostSurface", "CodexDesktop",
        "-ThreadId", "fixture-thread"
        "-AllowFixtureCatalog"
    )
    $searchSkillPaths = @(
        $search.Output -split '\r?\n' |
            Where-Object { $_.StartsWith("SKILL.md: ", [StringComparison]::Ordinal) } |
            ForEach-Object { $_.Substring("SKILL.md: ".Length) }
    )
    $returnedAlphaPath = if ($searchSkillPaths.Count -eq 1) {
        [string]$searchSkillPaths[0]
    } else { "" }
    $returnedAlphaContent = if ($returnedAlphaPath -and
        (Test-Path -LiteralPath $returnedAlphaPath -PathType Leaf)) {
        [IO.File]::ReadAllText($returnedAlphaPath, [Text.Encoding]::UTF8)
    } else { "" }
    $allMatchesSearch = Invoke-Script -ScriptPath $searchScript -Arguments @(
        "-Query", "a",
        "-JsonPath", $jsonPath,
        "-HostSurface", "CodexDesktop",
        "-ThreadId", "fixture-thread",
        "-AllowFixtureCatalog"
    )
    $allMatchPaths = @(
        $allMatchesSearch.Output -split '\r?\n' |
            Where-Object { $_.StartsWith("SKILL.md: ", [StringComparison]::Ordinal) } |
            ForEach-Object { $_.Substring("SKILL.md: ".Length) }
    )
    $expectedMatchContent = @{}
    $expectedMatchContent[[IO.Path]::GetFullPath((Join-Path $alphaDir "SKILL.md"))] =
        ((@("---", "name: alpha", "description: Alpha fixture for runtime lookup.", "---", "# Alpha") -join [Environment]::NewLine) + [Environment]::NewLine)
    $expectedMatchContent[[IO.Path]::GetFullPath((Join-Path $codeReviewDir "SKILL.md"))] =
        ((@("---", "name: code-review", "description: Review code changes against standards and specs.", "---", "# Code Review") -join [Environment]::NewLine) + [Environment]::NewLine)
    $expectedMatchContent[[IO.Path]::GetFullPath((Join-Path $betaDir "SKILL.md"))] =
        ((@("---", "name: beta", "description: >", "  Frontmatter block scalar must not replace the runtime prompt description.", "---", "# Beta") -join [Environment]::NewLine) + [Environment]::NewLine)
    $allMatchesAreCompleteFiles = $allMatchesSearch.ExitCode -eq 0 -and
        $allMatchPaths.Count -eq $expectedMatchContent.Count
    foreach ($matchPath in $allMatchPaths) {
        $allMatchesAreCompleteFiles = $allMatchesAreCompleteFiles -and
            [IO.Path]::IsPathRooted($matchPath) -and
            (Split-Path -Leaf $matchPath) -ceq "SKILL.md" -and
            (Test-Path -LiteralPath $matchPath -PathType Leaf) -and
            $expectedMatchContent.ContainsKey($matchPath) -and
            [IO.File]::ReadAllText($matchPath, [Text.Encoding]::UTF8) -ceq
                [string]$expectedMatchContent[$matchPath]
    }

    $missingPathCatalog = $catalog | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $missingPathCatalog.skills[0].path = Join-Path $testRoot "missing\SKILL.md"
    $missingPathCatalog.skills_sha256 = Get-CatalogSkillsDigest -Skills @($missingPathCatalog.skills)
    $missingPathJson = Join-Path $testRoot "missing-path.json"
    [IO.File]::WriteAllText(
        $missingPathJson,
        (($missingPathCatalog | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
        (New-Object Text.UTF8Encoding($false))
    )
    $missingPathSearch = Invoke-Script -ScriptPath $searchScript -Arguments @(
        "-Query", "a",
        "-JsonPath", $missingPathJson,
        "-HostSurface", "CodexDesktop",
        "-ThreadId", "fixture-thread",
        "-AllowFixtureCatalog"
    )
    $missingPathFailsWithoutPartialOutput = $missingPathSearch.ExitCode -ne 0 -and
        $missingPathSearch.Output -notmatch '(?m)^(?:Name|SKILL[.]md): '
    Assert-True "search accepts matching catalog" (
        $search.ExitCode -eq 0 -and
        $search.Output -match "alpha" -and
        $searchSkillPaths.Count -eq 1 -and
        [IO.Path]::IsPathRooted($returnedAlphaPath) -and
        (Split-Path -Leaf $returnedAlphaPath) -ceq "SKILL.md" -and
        $returnedAlphaPath -and
        (Test-Path -LiteralPath $returnedAlphaPath -PathType Leaf) -and
        $returnedAlphaContent -match '(?s)^---\r?\nname: alpha\r?\ndescription: Alpha fixture for runtime lookup[.]\r?\n---\r?\n# Alpha\r?\n?$' -and
        $allMatchesAreCompleteFiles -and
        $missingPathFailsWithoutPartialOutput
    )

    $chineseCodeReview = (
        [string][char]0x4EE3 +
        [string][char]0x7801 +
        [string][char]0x5BA1 +
        [string][char]0x67E5
    )
    $localizedSearch = Invoke-Script -ScriptPath $searchScript -Arguments @(
        "-Query", $chineseCodeReview,
        "-JsonPath", $jsonPath,
        "-HostSurface", "CodexDesktop",
        "-ThreadId", "fixture-thread",
        "-AllowFixtureCatalog"
    )
    Assert-True "Chinese review query resolves code-review" (
        $localizedSearch.ExitCode -eq 0 -and $localizedSearch.Output -match "code-review"
    )

    $pathSearch = Invoke-Script -ScriptPath $searchScript -Arguments @(
        "-Query", "path-only-token",
        "-JsonPath", $jsonPath,
        "-HostSurface", "CodexDesktop",
        "-ThreadId", "fixture-thread"
        "-AllowFixtureCatalog"
    )
    Assert-True "search ignores filesystem path" ($pathSearch.ExitCode -eq 0 -and $pathSearch.Output -notmatch "hidden")

    $stale = Invoke-Script -ScriptPath $searchScript -Arguments @(
        "-Query", "alpha",
        "-JsonPath", $jsonPath,
        "-HostSurface", "CodexDesktop",
        "-ThreadId", "other-thread",
        "-AllowFixtureCatalog",
        "-NoRebuild"
    )
    Assert-True "stale thread fails closed" ($stale.ExitCode -ne 0)

    $before = [IO.File]::ReadAllBytes($jsonPath)
    Set-Content -LiteralPath $fixture -Encoding UTF8 -Value '{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<skills_instructions>broken</skills_instructions>"}]}}'
    $invalid = Invoke-Script -ScriptPath $indexScript -Arguments $indexArgs
    $after = [IO.File]::ReadAllBytes($jsonPath)
    Assert-True "malformed block fails closed" ($invalid.ExitCode -ne 0)
    Assert-True "failed rebuild preserves prior JSON" ([Convert]::ToBase64String($before) -eq [Convert]::ToBase64String($after))

    Set-Content -LiteralPath $fixture -Encoding UTF8 -Value ($event | ConvertTo-Json -Compress -Depth 8)
    $productionWithFixturePath = Invoke-Script -ScriptPath $indexScript -Arguments @(
        "-HostSurface", "CodexDesktop",
        "-ThreadId", "fixture-thread",
        "-RolloutPath", $fixture,
        "-JsonPath", (Join-Path $testRoot "forbidden.json"),
        "-MarkdownPath", (Join-Path $testRoot "forbidden.md")
    )
    Assert-True "RolloutPath cannot self-certify production evidence" ($productionWithFixturePath.ExitCode -ne 0)

    $isolatedRoot = Join-Path $testRoot "catalogs"
    $threadA = Invoke-Script -ScriptPath $indexScript -Arguments @(
        "-HostSurface", "CodexDesktop",
        "-FixtureMode",
        "-ThreadId", "thread-a",
        "-RolloutPath", $fixture,
        "-CatalogRoot", $isolatedRoot
    )
    $threadB = Invoke-Script -ScriptPath $indexScript -Arguments @(
        "-HostSurface", "CodexDesktop",
        "-FixtureMode",
        "-ThreadId", "thread-b",
        "-RolloutPath", $fixture,
        "-CatalogRoot", $isolatedRoot
    )
    $catalogA = @(Get-ChildItem -LiteralPath (Join-Path $isolatedRoot "codex-desktop\thread-a") -Recurse -Filter "skill-index.json" -File)
    $catalogB = @(Get-ChildItem -LiteralPath (Join-Path $isolatedRoot "codex-desktop\thread-b") -Recurse -Filter "skill-index.json" -File)
    Assert-True "thread A publishes independently" ($threadA.ExitCode -eq 0 -and $catalogA.Count -eq 1)
    Assert-True "thread B publishes independently" ($threadB.ExitCode -eq 0 -and $catalogB.Count -eq 1)
    Assert-True "thread catalogs use different directories" ($catalogA[0].Directory.Parent.FullName -ne $catalogB[0].Directory.Parent.FullName)

    $concurrentArgs = @(
        "-HostSurface", "CodexDesktop",
        "-FixtureMode",
        "-ThreadId", "thread-concurrent",
        "-RolloutPath", $fixture,
        "-CatalogRoot", $isolatedRoot
    )
    $processOne = Start-ScriptProcess -ScriptPath $indexScript -Arguments $concurrentArgs
    $processTwo = Start-ScriptProcess -ScriptPath $indexScript -Arguments $concurrentArgs
    $concurrentOne = Complete-ScriptProcess -Process $processOne
    $concurrentTwo = Complete-ScriptProcess -Process $processTwo
    $concurrentCatalogs = @(Get-ChildItem -LiteralPath (Join-Path $isolatedRoot "codex-desktop\thread-concurrent") -Recurse -Filter "skill-index.json" -File)
    $leftoverTemps = @(Get-ChildItem -LiteralPath (Join-Path $isolatedRoot "codex-desktop\thread-concurrent") -Recurse -Directory | Where-Object { $_.Name -match "^[.]tmp[.]" })
    Assert-True "same-thread concurrent publishers both succeed" ($concurrentOne.ExitCode -eq 0 -and $concurrentTwo.ExitCode -eq 0)
    Assert-True "same-thread concurrent publish yields one snapshot" ($concurrentCatalogs.Count -eq 1)
    Assert-True "same-thread concurrent publish leaves no temp directory" ($leftoverTemps.Count -eq 0)
    $deliberateTemp = Join-Path (Join-Path $isolatedRoot "codex-desktop\thread-concurrent") ".tmp.injected"
    New-Item -ItemType Directory -Path $deliberateTemp | Out-Null
    $detectedTemps = @(Get-ChildItem -LiteralPath (Join-Path $isolatedRoot "codex-desktop\thread-concurrent") -Recurse -Directory | Where-Object { $_.Name -match "^[.]tmp[.]" })
    Assert-True "temp-directory detector catches production naming" ($detectedTemps.Count -eq 1)
    Remove-Item -LiteralPath $deliberateTemp -Force

    $syntheticThreadId = "synthetic-production-thread"
    $syntheticCodexHome = Join-Path $testRoot "synthetic-codex-home"
    $syntheticSessions = Join-Path $syntheticCodexHome "sessions\2026\07\29"
    $syntheticRollout = Join-Path $syntheticSessions ("rollout-" + $syntheticThreadId + ".jsonl")
    $syntheticCatalogRoot = Join-Path $testRoot "synthetic-production-catalogs"
    $syntheticMismatchRoot = Join-Path $testRoot "synthetic-production-mismatch"
    New-Item -ItemType Directory -Path $syntheticSessions -Force | Out-Null
    Set-Content -LiteralPath $syntheticRollout -Encoding UTF8 -Value @(
        (@{ type = "session_meta"; payload = @{ id = $syntheticThreadId; originator = "Codex Desktop" } } |
            ConvertTo-Json -Compress -Depth 4)
        $skillsEventLine
    )
    function New-BoundCatalogMutationFixture {
        param([string]$Suffix)
        $threadId = "bound-mutation-" + $Suffix
        $codexHome = Join-Path $testRoot ("bound-home-" + $Suffix)
        $sessions = Join-Path $codexHome "sessions\2026\08\04"
        $rollout = Join-Path $sessions ("rollout-" + $threadId + ".jsonl")
        $catalogRoot = Join-Path $testRoot ("bound-catalog-" + $Suffix)
        New-Item -ItemType Directory -Path $sessions -Force | Out-Null
        Set-Content -LiteralPath $rollout -Encoding UTF8 -Value @(
            (@{ type = "session_meta"; payload = @{ id = $threadId; originator = "Codex Desktop" } } |
                ConvertTo-Json -Compress -Depth 4)
            $skillsEventLine
        )
        $env:CODEX_HOME = $codexHome
        $env:CODEX_THREAD_ID = $threadId
        $build = Invoke-Script -ScriptPath $indexScript -Arguments @(
            "-HostSurface", "CodexDesktop",
            "-ThreadId", $threadId,
            "-CatalogRoot", $catalogRoot
        )
        if ($build.ExitCode -ne 0) { throw ("Bound mutation fixture build failed: " + $build.Error) }
        return [pscustomobject]@{
            ThreadId = $threadId
            CodexHome = $codexHome
            Rollout = $rollout
            CatalogRoot = $catalogRoot
        }
    }

    function Invoke-BoundCatalogMutationSearch {
        param([object]$Fixture)
        $emptyHome = Join-Path $testRoot ("empty-home-" + [string]$Fixture.ThreadId)
        New-Item -ItemType Directory -Path (Join-Path $emptyHome "sessions") -Force | Out-Null
        $env:CODEX_HOME = $emptyHome
        $env:CODEX_THREAD_ID = [string]$Fixture.ThreadId
        return Invoke-Script -ScriptPath $searchScript -Arguments @(
            "-Query", "review",
            "-HostSurface", "CodexDesktop",
            "-ThreadId", [string]$Fixture.ThreadId,
            "-CatalogRoot", [string]$Fixture.CatalogRoot,
            "-NoRebuild"
        )
    }
    $oldSyntheticCodexHome = $env:CODEX_HOME
    $oldSyntheticThreadId = $env:CODEX_THREAD_ID
    try {
        $env:CODEX_HOME = $syntheticCodexHome
        Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue
        $syntheticWithoutThread = Invoke-Script -ScriptPath $indexScript -Arguments @(
            "-HostSurface", "CodexDesktop",
            "-ThreadId", $syntheticThreadId,
            "-CatalogRoot", $syntheticCatalogRoot
        )
        $env:CODEX_THREAD_ID = $syntheticThreadId
        $syntheticMismatch = Invoke-Script -ScriptPath $indexScript -Arguments @(
            "-HostSurface", "CodexCli",
            "-ThreadId", $syntheticThreadId,
            "-CatalogRoot", $syntheticMismatchRoot
        )
        $syntheticProduction = Invoke-Script -ScriptPath $indexScript -Arguments @(
            "-HostSurface", "CodexDesktop",
            "-ThreadId", $syntheticThreadId,
            "-CatalogRoot", $syntheticCatalogRoot
        )
        $emptyCodexHome = Join-Path $testRoot "empty-codex-home"
        New-Item -ItemType Directory -Path (Join-Path $emptyCodexHome "sessions") -Force | Out-Null
        $env:CODEX_HOME = $emptyCodexHome
        $boundSearchWithoutDiscovery = Invoke-Script -ScriptPath $searchScript -Arguments @(
            "-Query", "review",
            "-HostSurface", "CodexDesktop",
            "-ThreadId", $syntheticThreadId,
            "-CatalogRoot", $syntheticCatalogRoot,
            "-NoRebuild"
        )
        $syntheticOriginalBytes = [IO.File]::ReadAllBytes($syntheticRollout)
        Add-Content -LiteralPath $syntheticRollout -Encoding UTF8 -Value '{"type":"event_msg","payload":'
        $boundSearchWithMalformedGrowth = Invoke-Script -ScriptPath $searchScript -Arguments @(
            "-Query", "review",
            "-HostSurface", "CodexDesktop",
            "-ThreadId", $syntheticThreadId,
            "-CatalogRoot", $syntheticCatalogRoot,
            "-NoRebuild"
        )
        [IO.File]::WriteAllBytes($syntheticRollout, $syntheticOriginalBytes)

        $replacementFixture = New-BoundCatalogMutationFixture -Suffix "replace"
        $replacementBytes = [IO.File]::ReadAllBytes($replacementFixture.Rollout)
        [IO.File]::Delete($replacementFixture.Rollout)
        [IO.File]::WriteAllBytes($replacementFixture.Rollout, $replacementBytes)
        $replacementSearch = Invoke-BoundCatalogMutationSearch -Fixture $replacementFixture

        $truncationFixture = New-BoundCatalogMutationFixture -Suffix "truncate"
        $truncationBytes = [IO.File]::ReadAllBytes($truncationFixture.Rollout)
        [IO.File]::WriteAllBytes(
            $truncationFixture.Rollout,
            $truncationBytes[0..([Math]::Floor($truncationBytes.Length / 2))]
        )
        $truncationSearch = Invoke-BoundCatalogMutationSearch -Fixture $truncationFixture

        $frozenDriftFixture = New-BoundCatalogMutationFixture -Suffix "frozen-drift"
        $frozenDriftText = [IO.File]::ReadAllText($frozenDriftFixture.Rollout, [Text.Encoding]::UTF8).Replace(
            "Review code changes against standards and specs.",
            "Drifted review description."
        )
        [IO.File]::WriteAllText($frozenDriftFixture.Rollout, $frozenDriftText, (New-Object Text.UTF8Encoding($true)))
        $frozenDriftSearch = Invoke-BoundCatalogMutationSearch -Fixture $frozenDriftFixture

        $identicalFixture = New-BoundCatalogMutationFixture -Suffix "identical"
        Add-Content -LiteralPath $identicalFixture.Rollout -Encoding UTF8 -Value $skillsEventLine
        $identicalSearch = Invoke-BoundCatalogMutationSearch -Fixture $identicalFixture

        $distinctFixture = New-BoundCatalogMutationFixture -Suffix "distinct"
        Add-Content -LiteralPath $distinctFixture.Rollout -Encoding UTF8 -Value $differentSkillsEventLine
        $distinctSearch = Invoke-BoundCatalogMutationSearch -Fixture $distinctFixture

        $sessionDriftFixture = New-BoundCatalogMutationFixture -Suffix "session-drift"
        Add-Content -LiteralPath $sessionDriftFixture.Rollout -Encoding UTF8 -Value (
            @{ type = "session_meta"; payload = @{ id = $sessionDriftFixture.ThreadId; originator = "codex-tui" } } |
                ConvertTo-Json -Compress -Depth 4
        )
        $sessionDriftSearch = Invoke-BoundCatalogMutationSearch -Fixture $sessionDriftFixture
        $env:CODEX_HOME = $syntheticCodexHome
        Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue
        $searchWithoutThread = Invoke-Script -ScriptPath $searchScript -Arguments @(
            "-Query", "review",
            "-HostSurface", "CodexDesktop",
            "-ThreadId", $syntheticThreadId,
            "-CatalogRoot", $syntheticCatalogRoot,
            "-NoRebuild"
        )
        $env:CODEX_THREAD_ID = "different-current-task"
        $searchWrongThread = Invoke-Script -ScriptPath $searchScript -Arguments @(
            "-Query", "review",
            "-HostSurface", "CodexDesktop",
            "-ThreadId", $syntheticThreadId,
            "-CatalogRoot", $syntheticCatalogRoot,
            "-NoRebuild"
        )
    }
    finally {
        if ($null -eq $oldSyntheticCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $oldSyntheticCodexHome }
        if ($null -eq $oldSyntheticThreadId) { Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue }
        else { $env:CODEX_THREAD_ID = $oldSyntheticThreadId }
    }
    $syntheticProductionJson = @(
        Get-ChildItem -LiteralPath $syntheticCatalogRoot -Recurse -Filter "skill-index.json" -File -ErrorAction SilentlyContinue
    )
    $syntheticProductionCatalog = if ($syntheticProductionJson.Count -eq 1) {
        Get-Content -LiteralPath $syntheticProductionJson[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }
    Assert-True "synthetic rollout file is labeled rollout-file-confirmed" (
        $syntheticProduction.ExitCode -eq 0 -and
        $syntheticProductionJson.Count -eq 1 -and
        [string]$syntheticProductionCatalog.visibility -eq "rollout-file-confirmed" -and
        [string]$syntheticProductionCatalog.host -eq "codex-desktop" -and
        [string]$syntheticProductionCatalog.thread_id -eq $syntheticThreadId
    ) $syntheticProduction.Output
    Assert-True "production catalog freezes canonical rollout evidence" (
        [string]$syntheticProductionCatalog.rollout_binding.canonical_path -ceq [IO.Path]::GetFullPath($syntheticRollout) -and
        [string]$syntheticProductionCatalog.rollout_binding.file_identity -match '^[A-F0-9]{8}:[A-F0-9]{16}$' -and
        [long]$syntheticProductionCatalog.rollout_binding.evidence_prefix_length -gt 0 -and
        [string]$syntheticProductionCatalog.rollout_binding.evidence_prefix_sha256 -match '^[A-F0-9]{64}$' -and
        [string]$syntheticProductionCatalog.rollout_binding.session_meta_sha256 -match '^[A-F0-9]{64}$' -and
        [string]$syntheticProductionCatalog.rollout_binding.skills_block_sha256 -ceq
            [string]$syntheticProductionCatalog.skills_prompt_sha256 -and
        [string]$syntheticProductionCatalog.rollout_binding_sha256 -ceq
            (Get-CatalogRolloutBindingDigest -Binding $syntheticProductionCatalog.rollout_binding)
    )
    Assert-True "bound production search does not rediscover the sessions tree" (
        $boundSearchWithoutDiscovery.ExitCode -eq 0 -and
        $boundSearchWithoutDiscovery.Output -match "code-review"
    ) $boundSearchWithoutDiscovery.Error
    if ($boundSearchWithoutDiscovery.ExitCode -ne 0) {
        Write-Host ("TRACE bound search: " + $boundSearchWithoutDiscovery.Error)
    }
    Assert-True "bound production search ignores unrelated malformed growth" (
        $boundSearchWithMalformedGrowth.ExitCode -eq 0 -and
        $boundSearchWithMalformedGrowth.Output -match "code-review"
    )
    Assert-True "bound production search rejects rollout replacement" ($replacementSearch.ExitCode -ne 0)
    Assert-True "bound production search rejects rollout truncation" ($truncationSearch.ExitCode -ne 0)
    Assert-True "bound production search rejects frozen skills drift" ($frozenDriftSearch.ExitCode -ne 0)
    Assert-True "bound production search accepts repeated identical skills evidence" (
        $identicalSearch.ExitCode -eq 0 -and $identicalSearch.Output -match "code-review"
    )
    Assert-True "bound production search rejects appended distinct skills evidence" ($distinctSearch.ExitCode -ne 0)
    Assert-True "bound production search rejects appended session identity drift" ($sessionDriftSearch.ExitCode -ne 0)
    Assert-True "production discovery requires CODEX_THREAD_ID" (
        $syntheticWithoutThread.ExitCode -ne 0 -and
        $syntheticWithoutThread.Error -match "CODEX_THREAD_ID"
    ) $syntheticWithoutThread.Output
    Assert-True "synthetic production discovery rejects a caller-supplied wrong host" (
        $syntheticMismatch.ExitCode -ne 0 -and
        -not (Test-Path -LiteralPath $syntheticMismatchRoot)
    ) $syntheticMismatch.Output
    Assert-True "production search requires CODEX_THREAD_ID" (
        $searchWithoutThread.ExitCode -ne 0 -and
        $searchWithoutThread.Error -match "CODEX_THREAD_ID"
    ) $searchWithoutThread.Output
    Assert-True "production search rejects a caller-supplied wrong thread" (
        $searchWrongThread.ExitCode -ne 0 -and
        $searchWrongThread.Error -match "CODEX_THREAD_ID"
    ) $searchWrongThread.Output

    $installedRoot = Join-Path $testRoot "custom-installed-root"
    $installedTools = Join-Path $installedRoot "tools"
    $installedCatalogRoot = Join-Path $installedRoot "runtime-skill-catalogs"
    $decoyProfile = Join-Path $testRoot "decoy-user-profile"
    $decoyCatalogRoot = Join-Path $decoyProfile ".steadyagent\runtime-skill-catalogs"
    $decoySearchProfile = Join-Path $testRoot "decoy-search-user-profile"
    $decoySearchCatalogRoot = Join-Path $decoySearchProfile ".steadyagent\runtime-skill-catalogs"
    New-Item -ItemType Directory -Force `
        -Path $installedTools, $decoyProfile, $decoySearchProfile | Out-Null
    Copy-Item -LiteralPath $indexScript -Destination (Join-Path $installedTools "skill-index.ps1")
    Copy-Item -LiteralPath $searchScript -Destination (Join-Path $installedTools "skill-search.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "skill-catalog-resolver.ps1") `
        -Destination (Join-Path $installedTools "skill-catalog-resolver.ps1")
    $installedIndex = Join-Path $installedTools "skill-index.ps1"
    $installedSearch = Join-Path $installedTools "skill-search.ps1"
    $oldInstalledUserProfile = $env:USERPROFILE
    $oldInstalledCodexHome = $env:CODEX_HOME
    $oldInstalledThreadId = $env:CODEX_THREAD_ID
    $oldInstalledCatalogTestMode = $env:STEADYAGENT_TEST_MODE
    try {
        $env:USERPROFILE = $decoyProfile
        $env:CODEX_HOME = $syntheticCodexHome
        $env:CODEX_THREAD_ID = $syntheticThreadId
        $defaultInstalledIndex = Invoke-Script -ScriptPath $installedIndex -Arguments @(
            "-HostSurface", "CodexDesktop",
            "-ThreadId", $syntheticThreadId
        )
        $defaultInstalledCatalogs = @(
            Get-ChildItem -LiteralPath $installedCatalogRoot -Recurse `
                -Filter "skill-index.json" -File -ErrorAction SilentlyContinue
        )
        Assert-True "default index catalog follows the installed tools parent" (
            $defaultInstalledIndex.ExitCode -eq 0 -and
            $defaultInstalledCatalogs.Count -eq 1 -and
            -not (Test-Path -LiteralPath $decoyCatalogRoot)
        )

        if (-not (Test-Path -LiteralPath $installedCatalogRoot -PathType Container)) {
            $explicitInstalledIndex = Invoke-Script -ScriptPath $installedIndex -Arguments @(
                "-HostSurface", "CodexDesktop",
                "-ThreadId", $syntheticThreadId,
                "-CatalogRoot", $installedCatalogRoot
            )
            if ($explicitInstalledIndex.ExitCode -ne 0) {
                throw ("Explicit installed-layout catalog setup failed: " + $explicitInstalledIndex.Error)
            }
        }
        $env:USERPROFILE = $decoySearchProfile
        $defaultInstalledSearch = Invoke-Script -ScriptPath $installedSearch -Arguments @(
            "-Query", "alpha",
            "-HostSurface", "CodexDesktop",
            "-ThreadId", $syntheticThreadId,
            "-NoRebuild"
        )
        Assert-True "default search catalog follows the installed tools parent" (
            $defaultInstalledSearch.ExitCode -eq 0 -and
            $defaultInstalledSearch.Output -match "alpha" -and
            -not (Test-Path -LiteralPath $decoySearchCatalogRoot)
        )
        if ($defaultInstalledSearch.ExitCode -ne 0) {
            Write-Host ("TRACE installed search: " + $defaultInstalledSearch.Error)
        }

        $env:STEADYAGENT_TEST_MODE = "1"
        . (Join-Path $installedTools "skill-catalog-resolver.ps1")
        $defaultResolvedSnapshot = Resolve-RolloutFileCatalogSnapshot `
            -HostSurface "CodexDesktop" `
            -ThreadId $syntheticThreadId `
            -RolloutPath $syntheticRollout `
            -RolloutLines @(Read-CatalogRolloutLines -Path $syntheticRollout)
        Assert-True "resolver default catalog follows the installed tools parent" (
            [IO.Path]::GetFullPath([string]$defaultResolvedSnapshot.Directory).StartsWith(
                ([IO.Path]::GetFullPath($installedCatalogRoot).TrimEnd("\") + "\"),
                [StringComparison]::OrdinalIgnoreCase
            )
        )
    }
    finally {
        if ($null -eq $oldInstalledUserProfile) {
            Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue
        } else {
            $env:USERPROFILE = $oldInstalledUserProfile
        }
        if ($null -eq $oldInstalledCodexHome) {
            Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
        } else {
            $env:CODEX_HOME = $oldInstalledCodexHome
        }
        if ($null -eq $oldInstalledThreadId) {
            Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue
        } else {
            $env:CODEX_THREAD_ID = $oldInstalledThreadId
        }
        if ($null -eq $oldInstalledCatalogTestMode) {
            Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
        } else {
            $env:STEADYAGENT_TEST_MODE = $oldInstalledCatalogTestMode
        }
    }

    if ([string]$env:STEADYAGENT_RUN_ROLLOUT_FILE_CANARY -eq "1") {
        if (-not $env:CODEX_THREAD_ID) {
            throw "STEADYAGENT_RUN_ROLLOUT_FILE_CANARY=1 requires CODEX_THREAD_ID."
        }
        $productionRoot = Join-Path $testRoot "production-catalogs"
        $productionRollout = Find-CatalogRollout -ThreadId $env:CODEX_THREAD_ID
        $actualProductionHost = Resolve-CatalogHostForRollout -HostSurface "Auto" -RolloutPath $productionRollout -ThreadId $env:CODEX_THREAD_ID
        $wrongSurface = if ($actualProductionHost -eq "codex-desktop") { "CodexCli" } else { "CodexDesktop" }
        $mismatchRoot = Join-Path $testRoot "mismatched-host"
        $mismatchBuild = Invoke-Script -ScriptPath $indexScript -Arguments @(
            "-HostSurface", $wrongSurface,
            "-ThreadId", $env:CODEX_THREAD_ID,
            "-CatalogRoot", $mismatchRoot
        )
        Assert-True "actual rollout rejects caller-supplied wrong host" (
            $mismatchBuild.ExitCode -ne 0 -and
            @(Get-ChildItem -LiteralPath $mismatchRoot -Recurse -Filter "skill-index.json" -File -ErrorAction SilentlyContinue).Count -eq 0
        )
        $productionBuild = Invoke-Script -ScriptPath $indexScript -Arguments @(
            "-HostSurface", $(if ($actualProductionHost -eq "codex-desktop") { "CodexDesktop" } else { "CodexCli" }),
            "-ThreadId", $env:CODEX_THREAD_ID,
            "-CatalogRoot", $productionRoot
        )
        $productionJson = @(Get-ChildItem -LiteralPath $productionRoot -Recurse -Filter "skill-index.json" -File)
        if ($productionBuild.ExitCode -ne 0) { Write-Host ("TRACE production build error: " + $productionBuild.Error) }
        $productionCatalog = if ($productionJson.Count -eq 1) {
            Get-Content -LiteralPath $productionJson[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } else { $null }
        Assert-True "actual rollout publishes rollout-file-confirmed evidence" (
            $productionBuild.ExitCode -eq 0 -and
            $productionJson.Count -eq 1 -and
            [string]$productionCatalog.visibility -eq "rollout-file-confirmed"
        )
        if ($productionBuild.ExitCode -ne 0 -or $productionJson.Count -ne 1) { throw "Production catalog fixture could not be built." }
        $productionMarkdown = Join-Path $productionJson[0].Directory.FullName "skill-index.md"
        Add-Content -LiteralPath $productionMarkdown -Value "tampered markdown body"
        $repairArgs = @(
            "-Query", "review",
            "-HostSurface", $(if ($actualProductionHost -eq "codex-desktop") { "CodexDesktop" } else { "CodexCli" }),
            "-ThreadId", $env:CODEX_THREAD_ID,
            "-CatalogRoot", $productionRoot
        )
        $repairProcessOne = Start-ScriptProcess -ScriptPath $searchScript -Arguments $repairArgs
        $repairProcessTwo = Start-ScriptProcess -ScriptPath $searchScript -Arguments $repairArgs
        $repairOne = Complete-ScriptProcess -Process $repairProcessOne
        $repairTwo = Complete-ScriptProcess -Process $repairProcessTwo
        $threadRoot = Join-Path $productionRoot ($actualProductionHost + "\" + $env:CODEX_THREAD_ID)
        $markdownQuarantine = @(Get-ChildItem -LiteralPath $threadRoot -Directory | Where-Object { $_.Name -match "[.]corrupt[.]" })
        $tamperedMarkdown = [IO.File]::ReadAllText($productionMarkdown, [Text.Encoding]::UTF8)
        Assert-True "concurrent tampered Markdown searches both fail closed" (
            $repairOne.ExitCode -ne 0 -and $repairTwo.ExitCode -ne 0
        )
        Assert-True "tampered Markdown is not rewritten or quarantined" (
            $markdownQuarantine.Count -eq 0 -and $tamperedMarkdown -match "tampered markdown body"
        )
        [IO.File]::WriteAllText(
            $productionMarkdown,
            (Get-CatalogMarkdown -Catalog $productionCatalog),
            (New-Object Text.UTF8Encoding($true))
        )
        $restoredSearch = Invoke-Script -ScriptPath $searchScript -Arguments $repairArgs
        Assert-True "restoring canonical Markdown restores search" ($restoredSearch.ExitCode -eq 0)

        $damaged = Get-Content -LiteralPath $productionJson[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $damaged.skills[0].name = "tampered-name"
        [IO.File]::WriteAllText($productionJson[0].FullName, ($damaged | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($true)))
        $repairSearch = Invoke-Script -ScriptPath $searchScript -Arguments @(
            "-Query", "review",
            "-HostSurface", $(if ($actualProductionHost -eq "codex-desktop") { "CodexDesktop" } else { "CodexCli" }),
            "-ThreadId", $env:CODEX_THREAD_ID,
            "-CatalogRoot", $productionRoot
        )
        if ($repairSearch.ExitCode -eq 0) { Write-Host ("TRACE damaged search unexpectedly succeeded") }
        $quarantined = @(Get-ChildItem -LiteralPath $threadRoot -Directory | Where-Object { $_.Name -match "[.]corrupt[.]" })
        $stillDamaged = Get-Content -LiteralPath $productionJson[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True "damaged snapshot fails closed" ($repairSearch.ExitCode -ne 0)
        Assert-True "damaged snapshot is not rewritten or quarantined" (
            $quarantined.Count -eq 0 -and [string]$stillDamaged.skills[0].name -eq "tampered-name"
        )
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved).StartsWith("skill-catalog-test-")) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-SemanticCheck -Id "catalog.resolver-bound-identity" -Cases @(
    "Desktop rollout cannot be labeled CLI",
    "CLI rollout cannot be labeled Desktop",
    "rollout-file snapshot binds host and skills to one captured rollout read",
    "rollout-file snapshot rejects inconsistent owner metadata appended before its read"
)
Write-SemanticCheck -Id "catalog.index-atomic-publication" -Cases @(
    "thread A publishes independently",
    "thread B publishes independently",
    "same-thread concurrent publishers both succeed",
    "same-thread concurrent publish yields one snapshot",
    "same-thread concurrent publish leaves no temp directory"
)
Write-SemanticCheck -Id "catalog.search-bound-fixture-isolation" -Cases @(
    "search accepts matching catalog",
    "Chinese review query resolves code-review",
    "stale thread fails closed",
    "RolloutPath cannot self-certify production evidence"
)
switch ([string]$env:STEADYAGENT_TEST_CATALOG_CASESET_MUTATION) {
    "missing" {
        [void]$script:Results.Remove("schema v2")
        [void]$script:AssertionNames.Remove("schema v2")
    }
    "substitute" {
        [void]$script:Results.Remove("schema v2")
        $script:Results["schema v2 substituted"] = $true
        $caseIndex = $script:AssertionNames.IndexOf("schema v2")
        if ($caseIndex -ge 0) { $script:AssertionNames[$caseIndex] = "schema v2 substituted" }
    }
    "duplicate" {
        $script:AssertionNames.Add("schema v2") | Out-Null
    }
    "coupled-missing" {
        [void]$script:Results.Remove("schema v2")
        [void]$script:AssertionNames.Remove("schema v2")
        $script:RequiredDefaultCases = @(
            $script:RequiredDefaultCases | Where-Object { $_ -cne "schema v2" }
        )
        $script:Passed--
    }
    "coupled-substitute" {
        [void]$script:Results.Remove("schema v2")
        $script:Results["schema v2 substituted"] = $true
        $caseIndex = $script:AssertionNames.IndexOf("schema v2")
        if ($caseIndex -ge 0) { $script:AssertionNames[$caseIndex] = "schema v2 substituted" }
        $requiredIndex = [Array]::IndexOf($script:RequiredDefaultCases, "schema v2")
        if ($requiredIndex -ge 0) {
            $script:RequiredDefaultCases[$requiredIndex] = "schema v2 substituted"
        }
    }
    "coupled-rollout-file-missing" {
        if ([string]$env:STEADYAGENT_RUN_ROLLOUT_FILE_CANARY -eq "1") {
            $canaryCase = "damaged snapshot is not rewritten or quarantined"
            [void]$script:Results.Remove($canaryCase)
            [void]$script:AssertionNames.Remove($canaryCase)
            $script:RequiredRolloutFileCanaryCases = @(
                $script:RequiredRolloutFileCanaryCases | Where-Object { $_ -cne $canaryCase }
            )
            $script:Passed--
        }
    }
}
$requiredCases = @($script:RequiredDefaultCases)
if ([string]$env:STEADYAGENT_RUN_ROLLOUT_FILE_CANARY -eq "1") {
    $requiredCases += @($script:RequiredRolloutFileCanaryCases)
}
$requiredCaseCount = if (
    [string]$env:STEADYAGENT_RUN_ROLLOUT_FILE_CANARY -eq "1"
) { $script:RequiredRolloutFileCanaryCaseCount } else { $script:RequiredDefaultCaseCount }
$requiredCaseSetSha256 = if (
    [string]$env:STEADYAGENT_RUN_ROLLOUT_FILE_CANARY -eq "1"
) { $script:RequiredRolloutFileCanaryCaseSetSha256 } else { $script:RequiredDefaultCaseSetSha256 }
$requiredContractFrozen = (
    $requiredCases.Count -eq $requiredCaseCount -and
    (Get-CatalogCaseSetSha256 -Cases $requiredCases) -ceq $requiredCaseSetSha256
)
$assertionSetExact = Test-ExactCaseSet `
    -Actual @($script:AssertionNames.ToArray()) -Expected $requiredCases
$resultSetExact = Test-ExactCaseSet `
    -Actual @($script:Results.Keys | ForEach-Object { [string]$_ }) -Expected $requiredCases
$assertionDigestFrozen = (
    (Get-CatalogCaseSetSha256 -Cases @($script:AssertionNames.ToArray())) -ceq
    $requiredCaseSetSha256
)
$resultDigestFrozen = (
    (Get-CatalogCaseSetSha256 -Cases @(
        $script:Results.Keys | ForEach-Object { [string]$_ }
    )) -ceq $requiredCaseSetSha256
)
$allRequiredCasesPassed = @($requiredCases | Where-Object {
    -not $script:Results.ContainsKey($_) -or -not [bool]$script:Results[$_]
}).Count -eq 0
if ($script:Failed -eq 0 -and
    $script:Passed -eq $requiredCaseCount -and
    $requiredContractFrozen -and
    $assertionSetExact -and
    $resultSetExact -and
    $assertionDigestFrozen -and
    $resultDigestFrozen -and
    $allRequiredCasesPassed) {
    Write-Host (
        "CASESET PASS catalog.required-suite-executed count=" +
        $requiredCaseCount + " sha256=" + $requiredCaseSetSha256
    )
    Write-Host "SEMANTIC PASS catalog.required-suite-executed"
} else {
    $actualCaseSetSha256 = Get-CatalogCaseSetSha256 -Cases @($script:AssertionNames.ToArray())
    Write-Host (
        "FAIL  semantic evidence catalog.required-suite-executed expected=" +
        $requiredCaseCount + " assertions=" + $script:AssertionNames.Count +
        " results=" + $script:Results.Count + " actual_sha256=" + $actualCaseSetSha256
    )
    $script:Failed++
}
Write-Host ("=== Skill catalog test: {0} passed, {1} failed ===" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "skill-catalog-resolver.ps1")

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        Write-Host ("PASS  {0}" -f $Name)
        $script:Passed++
    } else {
        Write-Host ("FAIL  {0}" -f $Name)
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
        $singleReadSnapshot = Resolve-RuntimeCatalogSnapshot `
            -HostSurface "Auto" `
            -ThreadId "single-read-thread" `
            -CatalogRoot (Join-Path $testRoot "single-read-catalog") `
            -RolloutPath $singleReadRollout `
            -RolloutLines $capturedRolloutLines
        try {
            Resolve-RuntimeCatalogSnapshot `
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
    Assert-True "runtime snapshot binds host and skills to one captured rollout read" (
        $null -ne $singleReadSnapshot -and
        [string]$singleReadSnapshot.Host -eq "codex-desktop" -and
        [string]$singleReadSnapshot.ThreadId -eq "single-read-thread"
    )
    Assert-True "runtime snapshot rejects inconsistent owner metadata appended before its read" $changedRolloutBlocked

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
    Assert-True "runtime fixture builds" ($result.ExitCode -eq 0)

    $catalog = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    Assert-True "schema v2" ([int]$catalog.schema_version -eq 2)
    Assert-True "snapshot id present" ([string]$catalog.snapshot_id -match "^codex-desktop:fixture-thread:[A-F0-9]{64}$")
    Assert-True "fixture visibility is explicit" ([string]$catalog.visibility -eq "fixture-confirmed")
    Assert-True "thread id retained" ([string]$catalog.thread_id -eq "fixture-thread")
    Assert-True "exact advertised count" (@($catalog.skills).Count -eq 3)
    Assert-True "unadvertised file excluded" (-not (@($catalog.skills.name) -contains "hidden"))
    Assert-True "runtime prompt description used" ([string]$catalog.skills[0].description -eq "prompt description")
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
    Assert-True "search accepts matching catalog" ($search.ExitCode -eq 0 -and $search.Output -match "alpha")

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
    Assert-True "RolloutPath cannot self-certify production runtime" ($productionWithFixturePath.ExitCode -ne 0)

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
    $oldSyntheticCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $syntheticCodexHome
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
    }
    finally {
        if ($null -eq $oldSyntheticCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $oldSyntheticCodexHome }
    }
    $syntheticProductionJson = @(
        Get-ChildItem -LiteralPath $syntheticCatalogRoot -Recurse -Filter "skill-index.json" -File -ErrorAction SilentlyContinue
    )
    $syntheticProductionCatalog = if ($syntheticProductionJson.Count -eq 1) {
        Get-Content -LiteralPath $syntheticProductionJson[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }
    Assert-True "synthetic production discovery rejects a caller-supplied wrong host" (
        $syntheticMismatch.ExitCode -ne 0 -and
        @(Get-ChildItem -LiteralPath $syntheticMismatchRoot -Recurse -Filter "skill-index.json" -File -ErrorAction SilentlyContinue).Count -eq 0
    )
    Assert-True "synthetic production discovery builds without CODEX_THREAD_ID" (
        $syntheticProduction.ExitCode -eq 0 -and
        $syntheticProductionJson.Count -eq 1 -and
        [string]$syntheticProductionCatalog.visibility -eq "runtime-confirmed" -and
        [string]$syntheticProductionCatalog.host -eq "codex-desktop" -and
        [string]$syntheticProductionCatalog.thread_id -eq $syntheticThreadId
    ) $syntheticProduction.Output

    if ([string]$env:STEADYAGENT_RUN_LIVE_CATALOG_CANARY -eq "1") {
        if (-not $env:CODEX_THREAD_ID) {
            throw "STEADYAGENT_RUN_LIVE_CATALOG_CANARY=1 requires CODEX_THREAD_ID."
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
        Assert-True "production fixture builds from actual rollout identity" ($productionBuild.ExitCode -eq 0 -and $productionJson.Count -eq 1)
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
        $rebuiltCatalog = Get-Content -LiteralPath $productionJson[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $rebuiltMarkdown = [IO.File]::ReadAllText($productionMarkdown, [Text.Encoding]::UTF8)
        Assert-True "concurrent Markdown repair searches both succeed" ($repairOne.ExitCode -eq 0 -and $repairTwo.ExitCode -eq 0)
        Assert-True "tampered Markdown is quarantined once" ($markdownQuarantine.Count -eq 1)
        Assert-True "rebuilt Markdown matches canonical renderer" ($rebuiltMarkdown -ceq (Get-CatalogMarkdown -Catalog $rebuiltCatalog))

        $damaged = Get-Content -LiteralPath $productionJson[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $damaged.skills[0].name = "tampered-name"
        [IO.File]::WriteAllText($productionJson[0].FullName, ($damaged | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($true)))
        $repairSearch = Invoke-Script -ScriptPath $searchScript -Arguments @(
            "-Query", "review",
            "-HostSurface", $(if ($actualProductionHost -eq "codex-desktop") { "CodexDesktop" } else { "CodexCli" }),
            "-ThreadId", $env:CODEX_THREAD_ID,
            "-CatalogRoot", $productionRoot
        )
        if ($repairSearch.ExitCode -ne 0) { Write-Host ("TRACE repair search error: " + $repairSearch.Error) }
        $quarantined = @(Get-ChildItem -LiteralPath $threadRoot -Directory | Where-Object { $_.Name -match "[.]corrupt[.]" })
        $repairedJson = @(Get-ChildItem -LiteralPath $threadRoot -Directory | Where-Object { $_.Name -match "^[A-F0-9]{64}$" } | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter "skill-index.json" -File })
        $repaired = Get-Content -LiteralPath $repairedJson[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True "damaged snapshot is quarantined and rebuilt" ($repairSearch.ExitCode -eq 0 -and $quarantined.Count -eq 2)
        Assert-True "rebuilt snapshot restores skills digest" ([string]$repaired.skills_sha256 -eq (Get-CatalogSkillsDigest -Skills @($repaired.skills)))
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

Write-Host ("=== Skill catalog test: {0} passed, {1} failed ===" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

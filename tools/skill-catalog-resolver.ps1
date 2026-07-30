[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function Resolve-CatalogHostName {
    param([string]$HostSurface = "Auto")
    if ($HostSurface -eq "Auto") {
        if ($env:CODEX_INTERNAL_ORIGINATOR_OVERRIDE -eq "Codex Desktop") { return "codex-desktop" }
        return "codex-cli"
    }
    if ($HostSurface -eq "CodexDesktop") { return "codex-desktop" }
    if ($HostSurface -eq "CodexCli") { return "codex-cli" }
    throw "Unknown catalog host surface."
}

function Read-CatalogRolloutLines {
    param([string]$Path)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        while (-not $reader.EndOfStream) { $reader.ReadLine() }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function ConvertFrom-CatalogRolloutJson {
    param([string]$Text, [int]$LineNumber)
    try {
        return $Text | ConvertFrom-Json
    }
    catch {
        throw ("Rollout contains malformed JSONL at line {0}." -f $LineNumber)
    }
}

function Get-CatalogSessionMetadata {
    param(
        [string]$RolloutPath,
        [string]$ThreadId,
        [string[]]$RolloutLines
    )
    if ([string]::IsNullOrWhiteSpace($ThreadId)) { throw "ThreadId is required." }
    $lines = if ($PSBoundParameters.ContainsKey("RolloutLines")) {
        @($RolloutLines)
    } else {
        @(Read-CatalogRolloutLines -Path $RolloutPath)
    }
    $matches = New-Object Collections.Generic.List[object]
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        $jsonLine = ([string]$line).TrimStart([char]0xFEFF)
        if (-not $jsonLine) { continue }
        $event = ConvertFrom-CatalogRolloutJson -Text $jsonLine -LineNumber $lineNumber
        if ([string]$event.type -ne "session_meta") { continue }
        $matches.Add($event.payload)
    }
    if ($matches.Count -eq 0) {
        throw ("No session_meta was found for thread {0}." -f $ThreadId)
    }
    $owner = $matches[0]
    $ownerThreadId = [string]$owner.id
    $ownerOriginator = [string]$owner.originator
    if ([string]::IsNullOrWhiteSpace($ownerThreadId) -or $ownerThreadId -ne $ThreadId) {
        throw ("The owning session metadata does not match thread {0}." -f $ThreadId)
    }
    if ([string]::IsNullOrWhiteSpace($ownerOriginator)) {
        throw "Rollout session metadata has no originator."
    }
    $ownerMatches = 0
    foreach ($match in $matches) {
        $observedThreadId = [string]$match.id
        $originator = [string]$match.originator
        if ([string]::IsNullOrWhiteSpace($observedThreadId) -or
            [string]::IsNullOrWhiteSpace($originator)) {
            throw "Rollout session metadata has a missing id or originator."
        }
        Resolve-CatalogHostFromOriginator -Originator $originator | Out-Null
        if ($observedThreadId -eq $ThreadId) {
            $ownerMatches++
            if ($originator -ne $ownerOriginator) {
                throw "Rollout session metadata has inconsistent owner originators."
            }
        }
    }
    return [pscustomobject]@{
        id = $ThreadId
        originator = $ownerOriginator
        observed_count = $ownerMatches
        inherited_count = $matches.Count - $ownerMatches
    }
}

function Resolve-CatalogHostFromOriginator {
    param([string]$Originator)
    if ($Originator -eq "Codex Desktop") { return "codex-desktop" }
    if ($Originator -eq "codex-tui" -or $Originator -eq "Codex CLI") { return "codex-cli" }
    throw ("Unknown Codex rollout originator: " + $Originator)
}

function Resolve-CatalogHostForRollout {
    param(
        [string]$HostSurface,
        [string]$RolloutPath,
        [string]$ThreadId,
        [string[]]$RolloutLines
    )
    $lines = if ($PSBoundParameters.ContainsKey("RolloutLines")) {
        @($RolloutLines)
    } else {
        @(Read-CatalogRolloutLines -Path $RolloutPath)
    }
    $metadata = Get-CatalogSessionMetadata -RolloutPath $RolloutPath -ThreadId $ThreadId -RolloutLines $lines
    $actualHost = Resolve-CatalogHostFromOriginator -Originator ([string]$metadata.originator)
    if ($HostSurface -eq "Auto") { return $actualHost }
    $requestedHost = Resolve-CatalogHostName -HostSurface $HostSurface
    if ($requestedHost -ne $actualHost) {
        throw ("Requested host {0} does not match rollout originator {1} ({2})." -f $requestedHost, $metadata.originator, $actualHost)
    }
    return $actualHost
}

function Find-CatalogRollout {
    param([string]$ThreadId)
    if (-not $ThreadId) { throw "CODEX_THREAD_ID is required." }
    $codexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" })
    $sessions = Join-Path $codexHome "sessions"
    $matches = @(Get-ChildItem -LiteralPath $sessions -Recurse -File -Filter ("rollout-*" + $ThreadId + ".jsonl") -ErrorAction Stop)
    if ($matches.Count -ne 1) { throw ("Expected one rollout for thread {0}; found {1}." -f $ThreadId, $matches.Count) }
    return $matches[0].FullName
}

function Get-CatalogSkillsBlock {
    param([string]$RolloutPath, [string[]]$RolloutLines)
    $lines = if ($PSBoundParameters.ContainsKey("RolloutLines")) {
        @($RolloutLines)
    } else {
        @(Read-CatalogRolloutLines -Path $RolloutPath)
    }
    $blocks = New-Object Collections.Generic.List[string]
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        $jsonLine = ([string]$line).TrimStart([char]0xFEFF)
        if (-not $jsonLine) { continue }
        $event = ConvertFrom-CatalogRolloutJson -Text $jsonLine -LineNumber $lineNumber
        if ([string]$event.type -ne "response_item" -or
            [string]$event.payload.type -ne "message" -or
            [string]$event.payload.role -ne "developer") { continue }
        foreach ($part in @($event.payload.content)) {
            if ([string]$part.type -ne "input_text") { continue }
            $text = [string]$part.text
            $openCount = [regex]::Matches($text, [regex]::Escape("<skills_instructions>")).Count
            $closeCount = [regex]::Matches($text, [regex]::Escape("</skills_instructions>")).Count
            if ($openCount -eq 0 -and $closeCount -eq 0) { continue }
            if ($openCount -eq 0 -or $openCount -ne $closeCount) {
                throw "Rollout contains an incomplete skills_instructions tag structure."
            }
            $matches = [regex]::Matches($text, "(?s)<skills_instructions>(.*?)</skills_instructions>")
            if ($matches.Count -ne $openCount) {
                throw "Rollout contains an ambiguous skills_instructions tag structure."
            }
            foreach ($match in $matches) {
                $normalized = ($match.Groups[1].Value -replace "`r`n", "`n" -replace "`r", "`n").Trim()
                $blocks.Add($normalized)
            }
        }
    }
    if ($blocks.Count -eq 0) { throw "No complete skills_instructions block was found." }
    $uniqueBlocks = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($block in $blocks) { [void]$uniqueBlocks.Add($block) }
    if ($uniqueBlocks.Count -ne 1) {
        throw "Rollout contains multiple distinct skills_instructions blocks."
    }
    return $blocks[0]
}

function Get-CatalogSha256 {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace("-", "")
    } finally { $sha.Dispose() }
}

function Get-CatalogFrontmatterName {
    param([string]$Path)
    $lines = @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8) | Select-Object -First 100)
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne "---") {
        return Split-Path -Leaf (Split-Path -Parent $Path)
    }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "---") { break }
        if ($lines[$i] -match "^\s*name\s*:\s*(.*)\s*$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return Split-Path -Leaf (Split-Path -Parent $Path)
}

function Test-CatalogPathWithinRoot {
    param([string]$Path, [string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
    return [IO.Path]::GetFullPath($Path).StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)
}

function Get-CatalogSourceMetadata {
    param([string]$Path)
    $normalized = $Path -replace "\\", "/"
    $plugin = ""
    $version = ""
    $kind = "user-skill"
    if ($normalized -match "/plugins/cache/(openai-curated-remote|openai-bundled|openai-primary-runtime)/([^/]+)/([^/]+)/") {
        $provider = $Matches[1]
        $plugin = $Matches[2]
        $version = $Matches[3]
        if ($provider -eq "openai-curated-remote") { $kind = "remote-plugin" } else { $kind = "bundled-plugin" }
    } elseif ($normalized -match "/skills/[.]system/") {
        $kind = "system-skill"
    } elseif ($normalized -match "/[.]agents/skills/") {
        $kind = "shared-user-skill"
    }
    return [pscustomobject]@{ Kind = $kind; Plugin = $plugin; Version = $version }
}

function Get-CatalogSkillsFromBlock {
    param([string]$Block, [int]$MaxDescriptionLength = 220)
    $roots = @{}
    $entries = New-Object Collections.Generic.List[object]
    $section = ""
    foreach ($line in ($Block -split "`n")) {
        if ($line.Trim() -eq "### Skill roots") { $section = "roots"; continue }
        if ($line.Trim() -eq "### Available skills") { $section = "skills"; continue }
        if ($line -match "^###\s" -and $section) { $section = ""; continue }
        if ($section -eq "roots" -and $line -match '^\s*-\s*`?([A-Za-z][A-Za-z0-9_-]*)`?\s*=\s*`?([^`]+?)`?\s*$') {
            $alias = $Matches[1]
            $root = [IO.Path]::GetFullPath($Matches[2].Trim())
            if ($roots.ContainsKey($alias)) { throw "Duplicate skill root alias." }
            $roots[$alias] = $root
            continue
        }
        if ($section -eq "skills" -and $line -match '^\s*-\s*(.+?):\s+(.*?)\s+\(file:\s*([^)]+)\)\s*$') {
            $advertisedName = $Matches[1].Trim()
            $description = $Matches[2].Trim()
            $reference = $Matches[3].Trim() -replace "/", "\"
            if ($reference -notmatch '^([A-Za-z][A-Za-z0-9_-]*)\\(.+)$') { throw "Skill file reference has no valid root alias." }
            $alias = $Matches[1]
            $relative = $Matches[2]
            if (-not $roots.ContainsKey($alias)) { throw "Skill file references a missing root alias." }
            $path = [IO.Path]::GetFullPath((Join-Path $roots[$alias] $relative))
            if (-not (Test-CatalogPathWithinRoot -Path $path -Root $roots[$alias])) { throw "Skill path escapes its declared root." }
            if ((Split-Path -Leaf $path) -ne "SKILL.md" -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Advertised skill file is missing or is not SKILL.md."
            }
            $leafName = Get-CatalogFrontmatterName -Path $path
            if ($advertisedName -ne $leafName -and -not $advertisedName.EndsWith(":" + $leafName, [StringComparison]::Ordinal)) {
                throw ("Advertised skill name does not match frontmatter: {0} vs {1}." -f $advertisedName, $leafName)
            }
            if ($description.Length -gt $MaxDescriptionLength) {
                $description = $description.Substring(0, $MaxDescriptionLength - 3) + "..."
            }
            $source = Get-CatalogSourceMetadata -Path $path
            $entries.Add([pscustomobject][ordered]@{
                name = $advertisedName
                description = $description
                path = $path
                source_kind = $source.Kind
                plugin = $source.Plugin
                version = $source.Version
            })
        }
    }
    if ($roots.Count -eq 0 -or $entries.Count -eq 0) { throw "Skills block is incomplete." }
    if (@($entries | Group-Object name | Where-Object { $_.Count -gt 1 }).Count -gt 0 -or
        @($entries | Group-Object path | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
        throw "Duplicate skill name or path."
    }
    return @($entries | Sort-Object name)
}

function Get-CatalogSkillsDigest {
    param([object[]]$Skills)
    $canonical = @($Skills | Sort-Object name | ForEach-Object {
        [pscustomobject][ordered]@{
            name = [string]$_.name
            description = [string]$_.description
            path = [IO.Path]::GetFullPath([string]$_.path)
            source_kind = [string]$_.source_kind
            plugin = [string]$_.plugin
            version = [string]$_.version
        }
    }) | ConvertTo-Json -Depth 4 -Compress
    return Get-CatalogSha256 -Text $canonical
}

function Get-CatalogMarkdown {
    param([object]$Catalog)
    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendLine("# Runtime Skill Catalog")
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine(("Host: {0}  " -f $Catalog.host))
    [void]$builder.AppendLine(("Visibility: {0}  " -f $Catalog.visibility))
    [void]$builder.AppendLine(("Thread: {0}  " -f $Catalog.thread_id))
    [void]$builder.AppendLine(("Snapshot: {0}  " -f $Catalog.snapshot_id))
    [void]$builder.AppendLine(("Skills digest: {0}  " -f $Catalog.skills_sha256))
    [void]$builder.AppendLine(("Generated: {0}  " -f $Catalog.generated_at))
    [void]$builder.AppendLine(("Total skills: {0}" -f @($Catalog.skills).Count))
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("Generated from the current runtime prompt. Do not edit by hand.")
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("| Name | Source | Description | Path |")
    [void]$builder.AppendLine("| --- | --- | --- | --- |")
    foreach ($skill in @($Catalog.skills)) {
        $description = ([string]$skill.description -replace "\r?\n", " " -replace "\|", "/")
        $path = ([string]$skill.path -replace "\|", "/")
        [void]$builder.AppendLine(("| {0} | {1} | {2} | {3} |" -f $skill.name, $skill.source_kind, $description, $path))
    }
    return $builder.ToString()
}

function Resolve-RuntimeCatalogSnapshot {
    param(
        [ValidateSet("Auto", "CodexDesktop", "CodexCli")]
        [string]$HostSurface = "Auto",
        [string]$ThreadId,
        [string]$CatalogRoot = (Join-Path $env:USERPROFILE ".steadyagent\runtime-skill-catalogs"),
        [string]$RolloutPath,
        [string[]]$RolloutLines
    )
    $hasInjectedRollout = $PSBoundParameters.ContainsKey("RolloutPath") -or $PSBoundParameters.ContainsKey("RolloutLines")
    if ($hasInjectedRollout -and $env:STEADYAGENT_TEST_MODE -ne "1") {
        throw "Explicit rollout snapshots are available only to isolated tests."
    }
    if ($PSBoundParameters.ContainsKey("RolloutLines") -and -not $RolloutPath) {
        throw "Explicit rollout lines require RolloutPath."
    }
    $rollout = if ($RolloutPath) {
        [IO.Path]::GetFullPath($RolloutPath)
    } else {
        Find-CatalogRollout -ThreadId $ThreadId
    }
    if (-not (Test-Path -LiteralPath $rollout -PathType Leaf)) { throw "Rollout does not exist." }
    $lines = if ($PSBoundParameters.ContainsKey("RolloutLines")) {
        @($RolloutLines)
    } else {
        @(Read-CatalogRolloutLines -Path $rollout)
    }
    $actualHost = Resolve-CatalogHostForRollout `
        -HostSurface $HostSurface `
        -RolloutPath $rollout `
        -ThreadId $ThreadId `
        -RolloutLines $lines
    $block = Get-CatalogSkillsBlock -RolloutPath $rollout -RolloutLines $lines
    $hash = Get-CatalogSha256 -Text $block
    $skills = @(Get-CatalogSkillsFromBlock -Block $block)
    $skillsHash = Get-CatalogSkillsDigest -Skills $skills
    $directory = Join-Path (Join-Path (Join-Path $CatalogRoot $actualHost) $ThreadId) $hash
    return [pscustomobject]@{
        Host = $actualHost
        ThreadId = $ThreadId
        PromptHash = $hash
        SkillsHash = $skillsHash
        SnapshotId = $actualHost + ":" + $ThreadId + ":" + $hash
        Directory = $directory
        JsonPath = Join-Path $directory "skill-index.json"
        MarkdownPath = Join-Path $directory "skill-index.md"
        RolloutPath = $rollout
        Skills = $skills
    }
}

function Test-RuntimeCatalogSnapshot {
    param([object]$Expected)
    if (-not (Test-Path -LiteralPath $Expected.JsonPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Expected.MarkdownPath -PathType Leaf)) { return $false }
    try {
        $catalog = Get-Content -LiteralPath $Expected.JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $markdown = [IO.File]::ReadAllText($Expected.MarkdownPath, [Text.Encoding]::UTF8)
        $actualSkillsHash = Get-CatalogSkillsDigest -Skills @($catalog.skills)
        $expectedMarkdown = Get-CatalogMarkdown -Catalog $catalog
        return ([int]$catalog.schema_version -eq 2 -and
            [string]$catalog.visibility -eq "runtime-confirmed" -and
            [string]$catalog.host -eq [string]$Expected.Host -and
            [string]$catalog.thread_id -eq [string]$Expected.ThreadId -and
            [string]$catalog.skills_prompt_sha256 -eq [string]$Expected.PromptHash -and
            [string]$catalog.skills_sha256 -eq [string]$Expected.SkillsHash -and
            $actualSkillsHash -eq [string]$Expected.SkillsHash -and
            [string]$catalog.snapshot_id -eq [string]$Expected.SnapshotId -and
            (Split-Path -Leaf (Split-Path -Parent $Expected.JsonPath)) -eq [string]$Expected.PromptHash -and
            $markdown -ceq $expectedMarkdown -and
            @($catalog.skills).Count -gt 0)
    } catch {
        return $false
    }
}

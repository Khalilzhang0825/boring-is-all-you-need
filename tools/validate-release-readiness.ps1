[CmdletBinding()]
param([switch]$AllowDirty)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:Passed = 0
$script:Failed = 0

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) { $script:Passed++; Write-Host ("PASS " + $Name) }
    else { $script:Failed++; Write-Host ("FAIL " + $Name + $(if ($Detail) { " - " + $Detail } else { "" })) }
}

function Run-Gate {
    param([string]$Name, [string]$Path)
    Write-Host ("RUN " + $Name)
    $outputLines = New-Object Collections.Generic.List[string]
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path | ForEach-Object {
        $line = [string]$_
        $outputLines.Add($line) | Out-Null
        Write-Host $line
    }
    $code = $LASTEXITCODE
    $outputText = $outputLines.ToArray() -join "`n"
    Check $Name ($code -eq 0 -and $outputText -match "fail=0") $outputText
}

Push-Location $root
try {
    $status = @(git status --porcelain)
    if ($AllowDirty) { Check "WIP dirtiness explicitly allowed" $true }
    else { Check "release checkout is clean" ($status.Count -eq 0) ($status -join "; ") }

    $required = @(
        "README.md", "README.zh-CN.md", "RELEASE_NOTES.md", "LICENSE", "SECURITY.md", "CONTRIBUTING.md",
        "templates/codex/AGENTS.md", "templates/codex/hooks.empty.json", "templates/codex/requirements.managed-hooks.example.toml",
        "manifests/v1-codex-owned-files.txt", "manifests/local-postimage-equivalence.json",
        "rules/workflow-routing.md", "rules/verification.md", "rules/review-gates.md", "rules/context-management.md", "rules/safety-boundaries.md", "rules/skill-routing.md",
        "rules/HARNESS-GUIDE.md", "rules/harness-review.md", "rules/lessons.md",
        "tools/install.ps1", "tools/rollback.ps1", "tools/diagnose-install.ps1", "tools/test-v2-migration.ps1", "tools/test-agent-hooks.ps1",
        "tools/git-checkpoint.ps1", "tools/test-git-checkpoint.ps1", "tools/test-pre-commit.ps1",
        "tools/skill-catalog-resolver.ps1", "tools/skill-index.ps1", "tools/skill-search.ps1", "tools/test-skill-catalog.ps1",
        "tools/protected-path-policy.ps1", "tools/test-protected-path-policy.ps1", "tools/test-local-equivalence.ps1", "tools/test-equivalence-contract.ps1",
        "tools/git-hooks/pre-commit", "tools/git-hooks/pre-commit-check.ps1",
        "tools/validate-runtime-slice.ps1", "tools/validate-phase3.ps1", "tools/validate-release-readiness.ps1",
        ".github/workflows/validate.yml", "docs/release-checklist.md", "docs/github-publication-runbook.md"
    )
    foreach ($path in $required) { Check ("required asset: " + $path) (Test-Path -LiteralPath $path) }

    foreach ($removed in @(
        "CLAUDE.md", "skills/steadyagent-workflow/references/claude-code-practices.md",
        "tools/hooks/agent-hook-prompt-reminder.ps1", "tools/hooks/agent-hook-permission-guard.ps1",
        "tools/hooks/agent-hook-posttool-audit.ps1", "tools/enable-codex-hooks.ps1"
    )) {
        Check ("V2 removed asset absent: " + $removed) (-not (Test-Path -LiteralPath $removed))
    }
    $legacyTemplateFiles = @(Get-ChildItem -LiteralPath "templates\claude" -Recurse -File -ErrorAction SilentlyContinue)
    Check "V2 Claude template files are absent" ($legacyTemplateFiles.Count -eq 0) (($legacyTemplateFiles | ForEach-Object FullName) -join ", ")

    $readme = [IO.File]::ReadAllText((Join-Path $root "README.md"), [Text.Encoding]::UTF8)
    $readmeZh = [IO.File]::ReadAllText((Join-Path $root "README.zh-CN.md"), [Text.Encoding]::UTF8)
    $releaseNotes = [IO.File]::ReadAllText((Join-Path $root "RELEASE_NOTES.md"), [Text.Encoding]::UTF8)
    $securityPolicy = [IO.File]::ReadAllText((Join-Path $root "SECURITY.md"), [Text.Encoding]::UTF8)
    Check "English README declares v2.0.0" ($readme -match "v2[.]0[.]0")
    Check "Chinese README declares v2.0.0" ($readmeZh -match "v2[.]0[.]0")
    Check "English README documents dry-run and explicit replacement" ($readme -match "dry-run" -and $readme -match "ReplaceExistingWorkflow")
    Check "Chinese README documents dry-run and explicit replacement" ($readmeZh -match "dry-run" -and $readmeZh -match "ReplaceExistingWorkflow")
    Check "English README documents receipt rollback" ($readme -match "rollback[.]ps1" -and $readme -match "zero writes")
    Check "Chinese README documents receipt rollback" ($readmeZh -match "rollback[.]ps1" -and $readmeZh -match "fail closed")
    Check "README explains the Codex-only maintainer decision" ($readme -match "Why Codex only" -and $readme -match "maintainer's own experience")
    $hasChineseDecisionHeading = [bool]($readmeZh -match "Codex")
    $hasChineseExperienceBoundary = [bool]($readmeZh -match "Anthropic")
    Check "Chinese README explains the Codex-only maintainer decision" ($hasChineseDecisionHeading -and $hasChineseExperienceBoundary)
    Check "release notes contain exact v2.0.0 heading" ($releaseNotes -match "(?m)^## v2[.]0[.]0$")
    Check "security policy targets V2 replacement syntax" (
        $securityPolicy -match "V2" -and
        $securityPolicy -match "ReplaceExistingWorkflow" -and
        $securityPolicy -notmatch "-Overwrite|public v1 line"
    )
    Check "security policy has a concrete private reporting route" (
        $securityPolicy -match "security/advisories/new" -and
        $securityPolicy -match "Report a vulnerability"
    )
    $runbook = [IO.File]::ReadAllText((Join-Path $root "docs\github-publication-runbook.md"), [Text.Encoding]::UTF8)
    $runbookZh = [IO.File]::ReadAllText((Join-Path $root "docs\github-publication-runbook.zh-CN.md"), [Text.Encoding]::UTF8)
    $checklist = [IO.File]::ReadAllText((Join-Path $root "docs\release-checklist.md"), [Text.Encoding]::UTF8)
    $checklistZh = [IO.File]::ReadAllText((Join-Path $root "docs\release-checklist.zh-CN.md"), [Text.Encoding]::UTF8)
    Check "publication runbook targets v2.0.0" ($runbook -match "Tag: v2[.]0[.]0" -and $runbook -notmatch "Tag: v1[.]0[.]0|Title: SteadyAgent v1[.]0[.]0")
    Check "Chinese publication runbook targets v2.0.0" ($runbookZh -match "Tag: v2[.]0[.]0" -and $runbookZh -notmatch "Tag: v1[.]0[.]0|Title: SteadyAgent v1[.]0[.]0")
    Check "release checklist targets V2" ($checklist -match "SteadyAgent V2" -and $checklist -notmatch "SteadyAgent v1")
    Check "Chinese release checklist targets V2" ($checklistZh -match "SteadyAgent V2" -and $checklistZh -notmatch "SteadyAgent v1")
    Check "release checklists require private reporting and Codex Live verification" (
        $checklist -match "Private Vulnerability Reporting" -and
        $checklist -match "Codex managed hooks" -and
        $checklist -notmatch "host-specific hook differences" -and
        $checklistZh -match "Private Vulnerability Reporting" -and
        $checklistZh -match "Codex managed hooks"
    )
    $bugTemplate = [IO.File]::ReadAllText((Join-Path $root ".github\ISSUE_TEMPLATE\bug_report.yml"), [Text.Encoding]::UTF8)
    Check "bug report host choices are Codex-only" ($bugTemplate -match "Codex Desktop" -and $bugTemplate -notmatch "Claude Code|Both")

    $installerText = [IO.File]::ReadAllText((Join-Path $root "tools\install.ps1"), [Text.Encoding]::UTF8)
    $rollbackText = [IO.File]::ReadAllText((Join-Path $root "tools\rollback.ps1"), [Text.Encoding]::UTF8)
    Check "installer ships rollback without a legacy host selector" ($installerText -match '"rollback[.]ps1"' -and $installerText -notmatch "HostTarget|Claude")
    Check "install and rollback share one session-wide migration mutex" (
        $installerText -match 'Local\\SteadyAgentV2Migration' -and
        $rollbackText -match 'Local\\SteadyAgentV2Migration'
    )
    Check "installer updates migration receipts atomically" (
        $installerText -match "function Write-Utf8NoBomAtomic" -and
        $installerText -notmatch 'Write-Utf8NoBom -Path \(Join-Path \$backupFull "migration-receipt[.]json"\)'
    )
    $diagnoseText = [IO.File]::ReadAllText((Join-Path $root "tools\diagnose-install.ps1"), [Text.Encoding]::UTF8)
    Check "diagnosis requires the exact rendered managed matrix" (
        $diagnoseText -match "active managed config exactly matches the rendered V2 matrix" -and
        $diagnoseText -match "codex-requirements[.]expected[.]toml"
    )
    $legacyManifestLines = @([IO.File]::ReadAllLines((Join-Path $root "manifests\v1-codex-owned-files.txt"), [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
    $legacyManifestUnique = @($legacyManifestLines | Sort-Object -Unique)
    $legacyManifestInvalid = @($legacyManifestLines | Where-Object { [IO.Path]::IsPathRooted($_) -or $_ -match '(^|[\\/])[.][.]([\\/]|$)' })
    Check "V1-owned manifest is unique and path-safe" ($legacyManifestLines.Count -eq $legacyManifestUnique.Count -and $legacyManifestInvalid.Count -eq 0)
    Check "V1-owned manifest covers legacy activator, rules, hooks, docs, and removed skill reference" (
        $legacyManifestLines -contains "tools/enable-codex-hooks.ps1" -and
        $legacyManifestLines -contains "rules/workflow-routing.md" -and
        $legacyManifestLines -contains "tools/hooks/agent-hook-prompt-reminder.ps1" -and
        $legacyManifestLines -contains "docs/activation-guide.md" -and
        $legacyManifestLines -contains "skills/steadyagent-workflow/references/claude-code-practices.md"
    )
    $preCommitBytes = [IO.File]::ReadAllBytes((Join-Path $root "tools\git-hooks\pre-commit"))
    $hasBom = $preCommitBytes.Length -ge 3 -and $preCommitBytes[0] -eq 0xEF -and $preCommitBytes[1] -eq 0xBB -and $preCommitBytes[2] -eq 0xBF
    Check "Git hook entrypoint is LF and BOM-free" (-not $hasBom -and -not ($preCommitBytes -contains 13))

    $files = @(rg --files -g "!*.png" -g "!*.jpg" -g "!*.gif" -g "!*.ico" -g "!.agent/**")
    $privateHits = New-Object Collections.Generic.List[string]
    $secretHits = New-Object Collections.Generic.List[string]
    $nonSystemDrivePrefix = "E:" + [char]92
    $userProfilePattern = '(?i)[A-Z]:\\Users\\(?!Public(?:\\|$)|Default(?:\\|$)|Default User(?:\\|$)|All Users(?:\\|$)|<[^>]+>)[^\\\r\n]+'
    $emailPattern = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
    foreach ($relative in $files) {
        $full = Join-Path $root $relative
        try { $text = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8) } catch { continue }
        $publicEmails = @([regex]::Matches($text, $emailPattern) | Where-Object {
            $_.Value -notmatch '(?i)@(example[.]invalid|example[.]com|example[.]org|example[.]net)$'
        })
        if ($text -match $userProfilePattern -or $publicEmails.Count -gt 0 -or $text.Contains($nonSystemDrivePrefix)) {
            $privateHits.Add($relative)
        }
        if ($text -match '(?i)(api[_-]?key|token|password)\s*[:=]\s*["''][A-Za-z0-9_-]{12,}') { $secretHits.Add($relative) }
    }
    Check "public files contain no maintainer-private absolute paths" ($privateHits.Count -eq 0) ($privateHits -join ", ")
    Check "public files contain no obvious secrets" ($secretHits.Count -eq 0) ($secretHits -join ", ")

    $parseFailures = New-Object Collections.Generic.List[string]
    $encodingFailures = New-Object Collections.Generic.List[string]
    foreach ($scriptFile in @(Get-ChildItem -LiteralPath $root -Recurse -Filter "*.ps1" -File | Where-Object { $_.FullName -notmatch '[\\/][.]git[\\/]' })) {
        $scriptBytes = [IO.File]::ReadAllBytes($scriptFile.FullName)
        $scriptHasBom = $scriptBytes.Length -ge 3 -and $scriptBytes[0] -eq 0xEF -and $scriptBytes[1] -eq 0xBB -and $scriptBytes[2] -eq 0xBF
        $scriptHasNonAscii = @($scriptBytes | Where-Object { $_ -gt 0x7F }).Count -gt 0
        if ($scriptHasNonAscii -and -not $scriptHasBom) { $encodingFailures.Add($scriptFile.FullName) }
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) { $parseFailures.Add($scriptFile.FullName) }
    }
    Check "all PowerShell files parse under Windows PowerShell" ($parseFailures.Count -eq 0) ($parseFailures -join ", ")
    Check "PowerShell files with non-ASCII text use UTF-8 BOM" ($encodingFailures.Count -eq 0) ($encodingFailures -join ", ")

    $linkFailures = New-Object Collections.Generic.List[string]
    foreach ($markdown in @(Get-ChildItem -LiteralPath $root -Recurse -Filter "*.md" -File | Where-Object { $_.FullName -notmatch '[\\/][.]git[\\/]|[\\/][.]agent[\\/]' })) {
        $text = [IO.File]::ReadAllText($markdown.FullName, [Text.Encoding]::UTF8)
        foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)')) {
            $target = $match.Groups[1].Value
            if ($target -match '^(?i:https?://|mailto:|#)') { continue }
            $resolved = [IO.Path]::GetFullPath((Join-Path $markdown.DirectoryName $target))
            if (-not (Test-Path -LiteralPath $resolved)) { $linkFailures.Add(($markdown.FullName + " -> " + $target)) }
        }
    }
    Check "local Markdown links resolve" ($linkFailures.Count -eq 0) ($linkFailures -join "; ")

    Run-Gate "Codex runtime slice passes" (Join-Path $root "tools\validate-runtime-slice.ps1")
    Run-Gate "23-item local equivalence gate passes" (Join-Path $root "tools\test-local-equivalence.ps1")

    $workflow = [IO.File]::ReadAllText((Join-Path $root ".github\workflows\validate.yml"), [Text.Encoding]::UTF8)
    Check "GitHub Actions runs on Windows" ($workflow -match "windows-latest")
    Check "GitHub Actions runs release readiness" ($workflow -match "validate-release-readiness[.]ps1")
    Check "GitHub Actions release gate has a bounded timeout" ($workflow -match "timeout-minutes:\s*\d+")

    Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}
finally {
    Pop-Location
}

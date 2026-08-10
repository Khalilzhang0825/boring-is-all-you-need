#requires -Version 7.5
[CmdletBinding()]
param(
    [switch]$AllowDirty,
    [string]$BaseRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:Passed = 0
$script:Failed = 0
$hookInvocationLedgerPath = Join-Path ([IO.Path]::GetTempPath()) (
    "steadyagent-hook-invocation-" + [guid]::NewGuid().ToString("N") + ".log"
)
$oldHookInvocationLedger = [Environment]::GetEnvironmentVariable(
    "STEADYAGENT_HOOK_INVOCATION_LEDGER"
)
$oldEquivalenceTestMode = [Environment]::GetEnvironmentVariable(
    "STEADYAGENT_EQUIVALENCE_TEST_MODE"
)

try {
    . (Join-Path $PSScriptRoot "release-whitespace.ps1")
}
catch {
    [Console]::Error.WriteLine("Cannot load the release whitespace helper.")
    exit 1
}

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) { $script:Passed++; Write-Host ("PASS " + $Name) }
    else { $script:Failed++; Write-Host ("FAIL " + $Name + $(if ($Detail) { " - " + $Detail } else { "" })) }
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Remove-MarkdownFencedCode {
    param([string]$Text)
    $insideFence = $false
    $kept = New-Object Collections.Generic.List[string]
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line -match '^\s*(?:`{3,}|~{3,})') {
            $insideFence = -not $insideFence
            $kept.Add("") | Out-Null
            continue
        }
        if ($insideFence) { $kept.Add("") | Out-Null }
        else { $kept.Add([string]$line) | Out-Null }
    }
    return $kept.ToArray() -join "`n"
}

function Run-Gate {
    param(
        [string]$Name,
        [string]$Path,
        [string[]]$Arguments = @()
    )
    Write-Host ("RUN " + $Name)
    $outputLines = New-Object Collections.Generic.List[string]
    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments | ForEach-Object {
        $line = [string]$_
        $outputLines.Add($line) | Out-Null
        Write-Host $line
    }
    $code = $LASTEXITCODE
    $outputText = $outputLines.ToArray() -join "`n"
    Check $Name ($code -eq 0 -and $outputText -match "fail=0") $outputText
}

function Get-ReleaseBaseRef {
    param([string]$Requested)
    $candidate = $Requested
    if (-not $candidate -and $env:STEADYAGENT_RELEASE_BASE_REF) {
        $candidate = $env:STEADYAGENT_RELEASE_BASE_REF
    }
    if (-not $candidate) {
        $candidate = "f80c05c4b79e069ee3a35db3c09a8f870bca0b59"
    }
    if ($candidate -match '^0{40}$') {
        $candidate = "f80c05c4b79e069ee3a35db3c09a8f870bca0b59"
    }
    return $candidate
}

Push-Location $root
try {
    $ledgerStream = [IO.File]::Open(
        $hookInvocationLedgerPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read
    )
    $ledgerStream.Dispose()
    $env:STEADYAGENT_HOOK_INVOCATION_LEDGER = $hookInvocationLedgerPath
    $env:STEADYAGENT_EQUIVALENCE_TEST_MODE = "1"
    $status = @(git status --porcelain)
    if ($AllowDirty) { Check "WIP dirtiness explicitly allowed" $true }
    else { Check "release checkout is clean" ($status.Count -eq 0) ($status -join "; ") }

    $inventory = @(
        [IO.File]::ReadAllLines((Join-Path $root "release-files.txt"), [Text.Encoding]::UTF8) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $repositoryFiles = @(git ls-files --cached)
    if ($AllowDirty) {
        $repositoryFiles += @(git ls-files --others --exclude-standard)
    }
    $repositoryFiles = [string[]]@($repositoryFiles | Sort-Object -Unique)
    [Array]::Sort($repositoryFiles, [StringComparer]::Ordinal)
    Check "release inventory exactly matches the public repository files" (
        @(Compare-Object $inventory $repositoryFiles -SyncWindow 0).Count -eq 0
    ) ((Compare-Object $inventory $repositoryFiles -SyncWindow 0 | Out-String).Trim())

    $releaseBaseRef = Get-ReleaseBaseRef -Requested $BaseRef
    $whitespaceResult = Test-ReleaseWhitespace -Repository $root -BaseRef $releaseBaseRef -AllowDirty:$AllowDirty
    Check "release whitespace base resolves" ([bool]$whitespaceResult.BaseCommit) $releaseBaseRef
    Check "release whitespace merge-base resolves" ([bool]$whitespaceResult.MergeBase) $releaseBaseRef
    Check "release branch diff has no whitespace errors" (
        $whitespaceResult.Code -eq 0
    ) (($whitespaceResult.Output -split "`r?`n") -join "; ")

    $required = @(
        "README.md", "README.zh-CN.md", "RELEASE_NOTES.md", "LICENSE", "SECURITY.md", "CONTRIBUTING.md", "release-files.txt",
        "templates/codex/AGENTS.md", "templates/codex/hooks.empty.json", "templates/codex/requirements.managed-hooks.example.toml",
        "package-assets.sha256", "manifests/v1-codex-owned-files.txt", "manifests/local-postimage-equivalence.json",
        "rules/workflow-routing.md", "rules/verification.md", "rules/review-gates.md", "rules/context-management.md", "rules/safety-boundaries.md", "rules/skill-routing.md",
        "rules/HARNESS-GUIDE.md", "rules/harness-review.md", "rules/lessons.md",
        "tools/install.ps1", "tools/rollback.ps1", "tools/diagnose-install.ps1", "tools/test-v2-migration.ps1", "tools/test-agent-hooks.ps1",
        "tools/git-checkpoint.ps1", "tools/test-git-checkpoint.ps1", "tools/test-pre-commit.ps1",
        "tools/skill-catalog-resolver.ps1", "tools/skill-index.ps1", "tools/skill-search.ps1", "tools/test-skill-catalog.ps1",
        "tools/protected-path-policy.ps1", "tools/test-protected-path-policy.ps1", "tools/test-local-equivalence.ps1", "tools/test-equivalence-contract.ps1",
        "tools/release-whitespace.ps1", "tools/test-release-whitespace.ps1", "tools/test-release-workflow.ps1",
        "tools/git-hooks/pre-commit", "tools/git-hooks/pre-commit-check.ps1",
        "tools/validate-runtime-slice.ps1", "tools/validate-phase3.ps1",
        "tools/validate-release-readiness.ps1", "tools/validate-release-archive.ps1",
        ".github/workflows/validate.yml", ".github/workflows/release.yml",
        "docs/release-checklist.md", "docs/release-checklist.zh-CN.md",
        "docs/github-publication-runbook.md", "docs/github-publication-runbook.zh-CN.md"
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
    Check "English README declares v3.0.1" ($readme -match "v3[.]0[.]1")
    Check "Chinese README declares v3.0.1" ($readmeZh -match "v3[.]0[.]1")
    Check "English README documents dry-run and explicit replacement" ($readme -match "dry-run" -and $readme -match "ReplaceExistingWorkflow")
    Check "Chinese README documents dry-run and explicit replacement" ($readmeZh -match "dry-run" -and $readmeZh -match "ReplaceExistingWorkflow")
    Check "READMEs document ordinary and elevated migration compatibility" (
        $readme -match "both ordinary and elevated PowerShell are supported" -and
        $readme -match '52-source `package-assets[.]sha256`' -and
        $readme -match "never trigger UAC, change ACLs, or take ownership" -and
        $readmeZh -match "同时支持普通和提权 token" -and
        $readmeZh -match '52 项源资产 `package-assets[.]sha256`' -and
        $readmeZh -match "不会主动触发 UAC、修改 ACL 或接管 owner"
    )
    $currentContractText = @(
        $readme,
        $readmeZh,
        @(Get-ChildItem -LiteralPath (Join-Path $root "docs") -Filter "*.md" -File | ForEach-Object {
            [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
        }),
        [IO.File]::ReadAllText((Join-Path $root "rules\safety-boundaries.md"), [Text.Encoding]::UTF8)
    ) -join "`n"
    Check "current public contract contains no elevated-token refusal" (
        $currentContractText -notmatch '(?i)refuse(?:s|d)? (?:an )?elevated|must run (?:from|in) (?:a )?non-elevated|do not elevate|never elevate' -and
        $currentContractText -notmatch '拒绝管理员 token|不要提权|只允许当前非提权|必须在非提权|同一非提权|管理员锁定的.*(?:不受支持|unsupported)'
    )
    Check "English README scopes dry-run writes and discloses temporary staging" (
        $readme -match "zero target, config, backup, receipt, or state writes" -and
        $readme -match "ephemeral system-temp staging" -and
        $readme -notmatch "without writing files"
    )
    Check "Chinese README scopes dry-run writes and discloses temporary staging" (
        $readmeZh -match "不会写入目标、配置、备份、收据或状态" -and
        $readmeZh -match "系统临时目录中完成短暂 staging" -and
        $readmeZh -notmatch "不会写入文件"
    )
    Check "English README documents receipt rollback" ($readme -match "rollback[.]ps1" -and $readme -match "zero writes")
    Check "Chinese README documents receipt rollback" ($readmeZh -match "rollback[.]ps1" -and $readmeZh -match "fail closed")
    Check "READMEs scope byte-exact recovery and exclude filesystem metadata" (
        $readme -match "managed-file byte content and existence" -and
        $readme -match "ACLs, owners, file attributes, timestamps, or alternate data streams" -and
        $readmeZh -match "managed 文件的字节内容与存在性" -and
        $readmeZh -match "ACL、owner、文件属性、时间戳或 alternate data streams"
    )
    Check "READMEs disclose repository-local pre-commit chaining and global replacement" (
        $readme -match "chains an executable repository-local" -and
        $readme -match 'pre-existing global `core[.]hooksPath`' -and
        $readmeZh -match "链接执行仓库自身的可执行" -and
        $readmeZh -match '原先存在不同的全局 `core[.]hooksPath`'
    )
    Check "README explains the neutral Codex-only support boundary" (
        $readme -match "Why Codex only" -and
        $readme -match "supports Codex Desktop only" -and
        $readme -match "migration tombstones" -and
        $readme -notmatch "terminated the maintainer|welcome mat"
    )
    Check "Chinese README explains the neutral Codex-only support boundary" (
        $readmeZh -match "只支持 Codex Desktop" -and
        $readmeZh -match "迁移 tombstone" -and
        $readmeZh -notmatch "账户被封|擦门牌"
    )
    Check "release notes contain exact v3.0.1 heading" ($releaseNotes -match "(?m)^## v3[.]0[.]1$")
    Check "release notes scope in-place upgrade to verified v2.0.2" (
        $releaseNotes -match 'verified v2[.]0[.]2 installations can upgrade in place' -and
        $releaseNotes -match 'v2[.]0[.]0 and v2[.]0[.]1 require receipt-bound rollback'
    )
    Check "release notes use the elevated-compatible V1 replacement command" (
        $releaseNotes -match 'install[.]ps1 -Apply -ReplaceExistingWorkflow' -and
        $releaseNotes -match 'ordinary or administrator PowerShell' -and
        $releaseNotes -notmatch 'AcknowledgeTrustedElevationSession|RequireProtectedRecovery'
    )
    Check "security policy targets the latest stable release line" (
        $securityPolicy -match "latest stable release line" -and
        $securityPolicy -match "ReplaceExistingWorkflow" -and
        $securityPolicy -notmatch "-Overwrite|public v1 line|current public V2 line"
    )
    Check "README documents the verified v2.0.2 upgrade boundary" (
        $readme -match 'verified v2[.]0[.]2 installation' -and
        $readme -match 'Direct receipt-bound upgrade from v2[.]0[.]0 or v2[.]0[.]1 is not supported' -and
        $readmeZh -match '已验证的 v2[.]0[.]2 安装可原地升级' -and
        $readmeZh -match '不支持从 v2[.]0[.]0 或 v2[.]0[.]1 直接执行 receipt-bound 原地升级'
    )
    Check "README binds the v3 candidate snapshot to the final validation date and clean commit layer" (
        $readme -match '2026-08-10 from a clean committed tree' -and
        $readme -match 'local clean-commit release-candidate results' -and
        $readmeZh -match '2026-08-10 在 PowerShell 7[.]6[.]4 的干净已提交工作树上验证' -and
        $readmeZh -match '本地干净提交态的发行候选结果'
    )
    Check "security policy has a concrete private reporting route" (
        $securityPolicy -match "security/advisories/new" -and
        $securityPolicy -match "Report a vulnerability"
    )
    $runbook = [IO.File]::ReadAllText((Join-Path $root "docs\github-publication-runbook.md"), [Text.Encoding]::UTF8)
    $runbookZh = [IO.File]::ReadAllText((Join-Path $root "docs\github-publication-runbook.zh-CN.md"), [Text.Encoding]::UTF8)
    $checklist = [IO.File]::ReadAllText((Join-Path $root "docs\release-checklist.md"), [Text.Encoding]::UTF8)
    $checklistZh = [IO.File]::ReadAllText((Join-Path $root "docs\release-checklist.zh-CN.md"), [Text.Encoding]::UTF8)
    $gettingStarted = [IO.File]::ReadAllText((Join-Path $root "docs\getting-started.md"), [Text.Encoding]::UTF8)
    $gettingStartedZh = [IO.File]::ReadAllText((Join-Path $root "docs\getting-started.zh-CN.md"), [Text.Encoding]::UTF8)
    Check "getting-started docs preserve the v2.0.2 direct-upgrade boundary" (
        $gettingStarted -match 'verified v2[.]0[.]2 installation' -and
        $gettingStarted -match 'Direct receipt-bound upgrade from v2[.]0[.]0 or v2[.]0[.]1 is not supported' -and
        $gettingStartedZh -match '已验证的 v2[.]0[.]2 安装' -and
        $gettingStartedZh -match '不支持从 v2[.]0[.]0 或 v2[.]0[.]1 直接执行 receipt-bound 原地升级'
    )
    $attestationDocs = @($readme, $readmeZh, $gettingStarted, $gettingStartedZh, $runbook, $runbookZh)
    Check "publication runbook targets v3.0.1" ($runbook -match "Tag: v3[.]0[.]1" -and $runbook -notmatch "Tag: v1[.]0[.]0|Title: SteadyAgent v1[.]0[.]0")
    Check "Chinese publication runbook targets v3.0.1" ($runbookZh -match "Tag: v3[.]0[.]1" -and $runbookZh -notmatch "Tag: v1[.]0[.]0|Title: SteadyAgent v1[.]0[.]0")
    Check "release checklist targets v3.0.1" ($checklist -match "Boring Is All You Need v3[.]0[.]1" -and $checklist -notmatch "Boring Is All You Need v2")
    Check "Chinese release checklist targets v3.0.1" ($checklistZh -match "Boring Is All You Need v3[.]0[.]1" -and $checklistZh -notmatch "Boring Is All You Need v2")
    Check "release checklists require private reporting and Codex Live verification" (
        $checklist -match "Private Vulnerability Reporting" -and
        $checklist -match "Codex managed hooks" -and
        $checklist -notmatch "host-specific hook differences" -and
        $checklistZh -match "Private Vulnerability Reporting" -and
        $checklistZh -match "Codex managed hooks"
    )
    Check "release checklists use the frozen V1 whitespace baseline" (
        $checklist -match 'git diff --check f80c05c4b79e069ee3a35db3c09a8f870bca0b59[.][.][.]HEAD' -and
        $checklistZh -match 'git diff --check f80c05c4b79e069ee3a35db3c09a8f870bca0b59[.][.][.]HEAD'
    )
    Check "release docs require attestation, digest, and fresh extraction verification" (
        $readme -match 'gh attestation verify' -and
        $readmeZh -match 'gh attestation verify' -and
        $readme -match 'signer-workflow' -and
        $readmeZh -match 'signer-workflow' -and
        @($attestationDocs | Where-Object {
            $_ -match [regex]::Escape('$ReviewedSha') -and
            $_ -match [regex]::Escape('--source-digest $ReviewedSha') -and
            $_ -match '\$ReviewedSha\s*=\s*\[string\]\$Provenance[.]reviewedCommit' -and
            $_ -match 'boring-is-all-you-need-v3[.]0[.]1[.]provenance[.]json' -and
            $_ -notmatch '<recorded reviewed commit>|<记录的已审查 commit>'
        }).Count -eq 6 -and
        $runbook -match 'validate-release-archive[.]ps1' -and
        $runbookZh -match 'validate-release-archive[.]ps1' -and
        $checklist -match 'attested workflow artifact' -and
        $checklistZh -match 'tagged、attested'
    )
    Check "all copyable release verification blocks fail closed on gh errors before extraction" (
        @($attestationDocs | Where-Object {
            $_ -match '(?m)^gh attestation verify --help \| Out-Null\r?\nif \(\$LASTEXITCODE -ne 0\) \{ throw ' -and
            $_ -match '(?m)^gh release download v3[.]0[.]1[^\r\n]*\r?\nif \(\$LASTEXITCODE -ne 0\) \{ throw ' -and
            $_ -match '(?ms)^gh attestation verify [.]\\boring-is-all-you-need-v3[.]0[.]1[.]zip .*?^  --source-digest \$ReviewedSha\r?\nif \(\$LASTEXITCODE -ne 0\) \{ throw [^\r\n]+\}\r?\nExpand-Archive'
        }).Count -eq $attestationDocs.Count
    )
    Check "public receipt examples contain no angle-bracket receipt or backup placeholders" (
        @($attestationDocs | Where-Object {
            $_ -notmatch '<[^>\r\n]*(receipt|backup|收据|备份)[^>\r\n]*>'
        }).Count -eq $attestationDocs.Count
    )
    Check "release docs preserve V1 and V2 history and reject unsupported rewrite paths" (
        $runbook -match 'V3 preserves the public V1 and V2 history' -and
        $runbookZh -match 'V3 保留公开的 V1 与 V2 历史' -and
        $runbook -notmatch 'Clean-History Rewrite|orphan/root|force-update' -and
        $runbookZh -notmatch 'Clean-History Rewrite|orphan/root|force-update'
    )
    Check "release runbooks check tag identity and native exits before push" (
        @(@($runbook, $runbookZh) | Where-Object {
            $_ -match 'git rev-parse "refs/tags/\$Tag\^\{commit\}"' -and
            $_ -match 'git ls-remote --exit-code --tags origin' -and
            $_ -match '(?m)^\s*git tag \$Tag \$ReviewedSha\r?\n\s*if \(\$LASTEXITCODE -ne 0\) \{ throw ' -and
            $_ -match '(?m)^\s*git push origin "refs/tags/\$Tag:refs/tags/\$Tag"\r?\n\s*if \(\$LASTEXITCODE -ne 0\) \{ throw '
        }).Count -eq 2
    )
    Check "release runbooks recover partial drafts only by captured exact ID" (
        @(@($runbook, $runbookZh) | Where-Object {
            $_ -match '\$CapturedReleaseId' -and
            $_ -match 'gh run download \$RunId' -and
            $_ -match '--method DELETE "repos/\$Repository/releases/\$CapturedReleaseId"' -and
            $_ -match 'Get-ReleaseById -ReleaseId \$CapturedReleaseId' -and
            $_ -notmatch 'gh release delete'
        }).Count -eq 2
    )
    Check "release runbooks publish only a revalidated captured exact draft" (
        @(@($runbook, $runbookZh) | Where-Object {
            $_ -match 'Assert-ExactReleaseDraft' -and
            $_ -match '--method PATCH "repos/\$Repository/releases/\$CapturedReleaseId" -F draft=false' -and
            $_ -match 'Get-ReleaseById -ReleaseId \$CapturedReleaseId' -and
            $_ -match '(?s)Assert-TagPublicationGuards -Repository \$Repository -Tag \$Tag.*?draft=false.*?Assert-TagPublicationGuards -Repository \$Repository -Tag \$Tag' -and
            $_ -match '\$PostPublishTagSha' -and
            $_ -match '\$PostPublishMainSha' -and
            $_ -match '-not \[bool\]\$state[.]immutable' -and
            $_ -notmatch 'gh release edit'
        }).Count -eq 2
    )
    Check "release runbooks require immutable releases and an exact no-bypass tag guard" (
        @(@($runbook, $runbookZh) | Where-Object {
            $_ -match 'repos/\$Repository/immutable-releases' -and
            $_ -match 'repos/\$Repository/rulesets[?]targets=tag&per_page=100' -and
            $_ -match '\$BypassProperty\s*=\s*\$Ruleset[.]PSObject[.]Properties\[''bypass_actors''\]' -and
            $_ -match '\$null -ne \$BypassProperty[.]Value' -and
            $_ -match '\$Excludes[.]Count -eq 0' -and
            $_ -match '\$RuleTypes -ccontains "update"' -and
            $_ -match '\$RuleTypes -ccontains "deletion"'
        }).Count -eq 2
    )
    $harnessReviewText = [IO.File]::ReadAllText(
        (Join-Path $root "rules\harness-review.md"),
        [Text.Encoding]::UTF8
    )
    Check "operational release and Harness docs contain no actionable angle placeholders" (
        @(@($runbook, $runbookZh) | Where-Object {
            $_ -notmatch '<(?:branch|commit|successful-receipt)>'
        }).Count -eq 2 -and
        $harnessReviewText -notmatch '<(?:branch|commit|successful-receipt)>' -and
        $harnessReviewText -match 'Read-Host "Successful migration receipt path"'
    )
    Check "release docs describe the three-job strict draft state machine" (
        $readme -match 'Three least-privilege GitHub Actions jobs' -and
        $readmeZh -match '三个最小权限 GitHub Actions job' -and
        $gettingStarted -match 'separate least-privilege build/validation, attestation, and draft-creation jobs' -and
        $gettingStartedZh -match '三个最小权限 job' -and
        $runbook -match 'three pinned, Node-24-native, least-privilege jobs' -and
        $runbookZh -match '三个固定版本、Node-24-native、最小权限 job' -and
        $checklist -match 'captured release ID' -and
        $checklistZh -match '捕获的 release ID'
    )
    Check "user docs expose rollback manual reconciliation and strict test-root names" (
        $readme -match 'rollback_incomplete' -and
        $readmeZh -match 'rollback_incomplete' -and
        $securityPolicy -match 'steadyagent-v2-migration-<32 lowercase hex>' -and
        $checklist -match 'rollback_incomplete' -and
        $checklistZh -match 'rollback_incomplete'
    )
    $installedSafetyRules = [IO.File]::ReadAllText((Join-Path $root "rules\safety-boundaries.md"), [Text.Encoding]::UTF8)
    Check "installed safety rules freeze both strict test-root contracts" (
        $installedSafetyRules -match 'steadyagent-v2-migration-<32 lowercase hex>' -and
        $installedSafetyRules -match 'steadyagent-git-checkpoint-<32 lowercase hex>' -and
        $installedSafetyRules -match 'non-reparse'
    )
    $workflowExamples = [IO.File]::ReadAllText((Join-Path $root "docs\workflow-examples.md"), [Text.Encoding]::UTF8)
    $workflowExamplesZh = [IO.File]::ReadAllText((Join-Path $root "docs\workflow-examples.zh-CN.md"), [Text.Encoding]::UTF8)
    Check "workflow examples use risk-based independent review triggers" (
        $workflowExamples -match "explicitly asks" -and
        $workflowExamples -match "specific material risk" -and
        $workflowExamples -match "file count alone is not a trigger" -and
        $workflowExamplesZh -match "明确要求" -and
        $workflowExamplesZh -match "具体实质风险" -and
        $workflowExamplesZh -match "文件数量本身不是触发条件"
    )
    $bugTemplate = [IO.File]::ReadAllText((Join-Path $root ".github\ISSUE_TEMPLATE\bug_report.yml"), [Text.Encoding]::UTF8)
    Check "bug report host choices are Codex-only" ($bugTemplate -match "Codex Desktop" -and $bugTemplate -notmatch "Claude Code|Both")

    $installerText = [IO.File]::ReadAllText((Join-Path $root "tools\install.ps1"), [Text.Encoding]::UTF8)
    $rollbackText = [IO.File]::ReadAllText((Join-Path $root "tools\rollback.ps1"), [Text.Encoding]::UTF8)
    $migrationRuntimePath = Join-Path $root "tools\migration-runtime.ps1"
    $migrationRuntimeText = [IO.File]::ReadAllText($migrationRuntimePath, [Text.Encoding]::UTF8)
    $migrationRuntimeHash = (Get-FileHash -LiteralPath $migrationRuntimePath -Algorithm SHA256).Hash
    $boundPolicyText = [IO.File]::ReadAllText((Join-Path $root "tools\protected-path-policy.ps1"), [Text.Encoding]::UTF8)
    $packageManifestPath = Join-Path $root "package-assets.sha256"
    $packageManifestBytes = [IO.File]::ReadAllBytes($packageManifestPath)
    $packageManifestHash = (Get-FileHash -LiteralPath $packageManifestPath -Algorithm SHA256).Hash
    $packageAnchorMatches = [regex]::Matches(
        $installerText,
        '\$expectedPackageManifestSha256\s*=\s*"(?<hash>[0-9A-F]{64})"'
    )
    Check "installer has one package asset trust anchor" (
        $packageAnchorMatches.Count -eq 1 -and
        $packageAnchorMatches[0].Groups["hash"].Value -ceq $packageManifestHash
    )
    $packageManifestText = [Text.Encoding]::UTF8.GetString($packageManifestBytes)
    $packageManifestLines = if ($packageManifestText.EndsWith("`n")) {
        @($packageManifestText.Substring(0, $packageManifestText.Length - 1).Split("`n"))
    }
    else { @() }
    $packageManifestFormatValid = (
        $packageManifestBytes.Length -gt 0 -and
        -not ($packageManifestBytes.Length -ge 3 -and
            $packageManifestBytes[0] -eq 0xEF -and
            $packageManifestBytes[1] -eq 0xBB -and
            $packageManifestBytes[2] -eq 0xBF) -and
        -not $packageManifestText.Contains("`r") -and
        $packageManifestLines.Count -eq 52
    )
    $packagePaths = New-Object Collections.Generic.List[string]
    $packageHashesMatch = $packageManifestFormatValid
    foreach ($line in $packageManifestLines) {
        if ($line -notmatch '^(?<hash>[0-9A-F]{64})  (?<path>[A-Za-z0-9._/-]+)$') {
            $packageHashesMatch = $false
            continue
        }
        $relative = [string]$Matches.path
        $packagePaths.Add($relative) | Out-Null
        $assetPath = Join-Path $root $relative.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash -cne
                [string]$Matches.hash) {
            $packageHashesMatch = $false
        }
    }
    $sortedPackagePaths = [string[]]@($packagePaths)
    [Array]::Sort($sortedPackagePaths, [StringComparer]::Ordinal)
    Check "package asset manifest is canonical and matches all 52 source bytes" (
        $packageHashesMatch -and
        $packagePaths.Count -eq @($packagePaths | Sort-Object -Unique).Count -and
        ($packagePaths -join "`n") -ceq ($sortedPackagePaths -join "`n") -and
        $packagePaths -notcontains "package-assets.sha256" -and
        $packagePaths -notcontains "tools/install.ps1"
    )
    Check "installer snapshots verified source bytes before staging" (
        $installerText -match 'Read-TrustedPackageSnapshot' -and
        $installerText -match 'Get-Sha256Bytes -Bytes \$finalBytes' -and
        $installerText -match 'Package staging verification failed' -and
        $installerText -notmatch '\[IO[.]File\]::Copy\(\$item[.]Source,\s*\$stagePath' -and
        $installerText -notmatch '\[IO[.]File\]::ReadAllText\(\$item[.]Source'
    )
    $migrationRuntimeAnchorPattern = [regex]::Escape(
        '$expectedMigrationRuntimeSha256 = "' + $migrationRuntimeHash + '"'
    )
    Check "install and rollback freeze the shared migration runtime before loading" (
        ([regex]::Matches($installerText, $migrationRuntimeAnchorPattern)).Count -eq 1 -and
        ([regex]::Matches($rollbackText, $migrationRuntimeAnchorPattern)).Count -eq 1 -and
        $installerText -match 'Migration runtime path is a reparse point' -and
        $rollbackText -match 'Migration runtime path is a reparse point' -and
        $installerText -match [regex]::Escape('. $migrationRuntimeBlock') -and
        $rollbackText -match [regex]::Escape('. $migrationRuntimeBlock')
    )
    Check "production install and rollback permit elevated execution" (
        $installerText -notmatch 'must run from a non-elevated PowerShell session' -and
        $rollbackText -notmatch 'Rollback requires a non-elevated PowerShell process' -and
        $installerText -notmatch 'STEADYAGENT_ALLOW_ELEVATED_FIXTURE' -and
        $rollbackText -notmatch 'STEADYAGENT_ALLOW_ELEVATED_FIXTURE' -and
        $installerText -notmatch 'AcknowledgeTrustedElevationSession|RequireProtectedRecovery|RecoveryRoot|TestRecoverySddl' -and
        $rollbackText -notmatch 'AcknowledgeTrustedElevationSession|RequireProtectedRecovery|TestRecoverySddl'
    )
    Check "installer ships rollback without a legacy host selector" ($installerText -match '"rollback[.]ps1"' -and $installerText -notmatch "HostTarget|Claude")
    $machineMutexPattern = [regex]::Escape("Global\SteadyAgentV2Migration")
    $fixtureMutexPattern = [regex]::Escape("Local\SteadyAgentV2MigrationTest_")
    $fixtureMutexHashPattern = '(?s)\$canonicalTestRoot\s*=\s*\[IO[.]Path\]::GetFullPath\(\$TestRoot\).*?ToLowerInvariant\(\).*?Get-Sha256Text -Text \$canonicalTestRoot'
    Check "production migration mutex is machine-wide and test mutexes are fixture-root-scoped" (
        $installerText -match $machineMutexPattern -and
        $rollbackText -match $machineMutexPattern -and
        $installerText -match $fixtureMutexPattern -and
        $rollbackText -match $fixtureMutexPattern -and
        $installerText -match $fixtureMutexHashPattern -and
        $rollbackText -match $fixtureMutexHashPattern
    )
    Check "installer durably publishes migration snapshots and receipts" (
        $migrationRuntimeText -match "function Write-Utf8NoBomAtomic" -and
        $migrationRuntimeText -match 'Invoke-SteadyAgentBoundAtomicWrite' -and
        $boundPolicyText -match 'FILE_FLAG_WRITE_THROUGH' -and
        $boundPolicyText -match 'Flush\(true\)' -and
        $installerText -match 'Write-MigrationReceipt -Receipt \$receipt -Path \$receiptPath' -and
        $installerText -match 'created_directories = @\(\)' -and
        $installerText -match '(?s)\$directoryStagePath = Join-Path \$backupFull.*?\$stagedDirectoryState = New-SteadyAgentOwnedDirectory -Path \$directoryStagePath.*?\$directoryState = \[pscustomobject\].*?volume_serial = \[string\]\$stagedDirectoryState[.]volume_serial.*?file_id = \[string\]\$stagedDirectoryState[.]file_id.*?\$createdDirectories[.]Add\(\$directoryState\).*?\$receipt[.]created_directories = @\(.*?Write-MigrationReceipt -Receipt \$receipt -Path \$receiptPath.*?Write-ActiveReceiptPointer -TargetRoot \$targetFull -ReceiptPath \$receiptPath.*?Publish-SteadyAgentOwnedDirectory.*?-StagingPath \$directoryStagePath.*?-DirectoryState \$directoryState' -and
        $installerText -notmatch 'Write-Utf8NoBom -Path \(Join-Path \$backupFull "migration-receipt[.]json"\)'
    )
    Check "installer and rollback expose hard-interruption recovery contract" (
        $installerText -match '\[int\]\$InjectHardKillAfterOperation' -and
        $installerText -match '\[switch\]\$InjectHardKillAfterGitActivation' -and
        $rollbackText -match '"applied", "applying"' -and
        $rollbackText -match 'Rollback tool identity does not match the receipt install contract' -and
        $rollbackText -match 'rollback_incomplete'
    )
    Check "test-only migration controls require a confined temp fixture root" (
        $installerText -match 'STEADYAGENT_TEST_MODE requires STEADYAGENT_TEST_ROOT' -and
        $rollbackText -match 'STEADYAGENT_TEST_MODE requires STEADYAGENT_TEST_ROOT' -and
        $installerText -match 'under the system temp directory' -and
        $rollbackText -match 'under the system temp directory' -and
        $installerText -match 'Test-mode path escaped STEADYAGENT_TEST_ROOT' -and
        $rollbackText -match 'Test-mode path escaped STEADYAGENT_TEST_ROOT'
    )
    $diagnoseText = [IO.File]::ReadAllText((Join-Path $root "tools\diagnose-install.ps1"), [Text.Encoding]::UTF8)
    Check "diagnosis requires the exact rendered managed matrix" (
        $diagnoseText -match "active managed config exactly matches the rendered V3 matrix" -and
        $diagnoseText -match "codex-requirements[.]expected[.]toml"
    )
    Check "diagnosis supports receipt-bound verification of all installed bytes" (
        $diagnoseText -match '\[string\]\$ReceiptPath' -and
        $diagnoseText -match '\[switch\]\$RequireInstalledBytes' -and
        $diagnoseText -match 'Invoke-ReceiptBoundByteVerification' -and
        $diagnoseText -match '53 receipt-bound installed hashes'
    )
    Check "production surface contains no protected-recovery elevation path" (
        $installerText -notmatch 'New-ProtectedRecoveryCapsule|SteadyAgent\\recovery' -and
        $rollbackText -notmatch 'Assert-ProtectedRecoveryPath|protected recovery capsule'
    )
    $safetyText = [IO.File]::ReadAllText((Join-Path $root "rules\safety-boundaries.md"), [Text.Encoding]::UTF8)
    Check "public safety contract permits ordinary and elevated migration" (
        $safetyText -match 'support both ordinary and elevated user tokens' -and
        $safetyText -match 'never request UAC, change ACLs, or take ownership' -and
        $safetyText -match 'integrity, not identity or authorization'
    )
    Check "public safety contract discloses package and same-user trust roots" (
        $safetyText -match '52-source `package-assets[.]sha256`' -and
        $safetyText -match 'pre-launch trust root' -and
        $safetyText -match 'do not sandbox malware running as that user'
    )
    $checkpointText = [IO.File]::ReadAllText(
        (Join-Path $root "tools\git-checkpoint.ps1"),
        [Text.Encoding]::UTF8
    )
    Check "checkpoint publication has crash recovery and ref identity binding" (
        $checkpointText -match 'steadyagent-checkpoint-journal[.]json' -and
        $checkpointText -match 'Recover-CheckpointTransaction' -and
        $checkpointText -match 'Get-CheckpointHeadIdentity' -and
        $checkpointText -match 'update-ref'
    )
    $legacyManifestLines = @(
        [IO.File]::ReadAllLines(
            (Join-Path $root "manifests\v1-codex-owned-files.txt"),
            [Text.Encoding]::UTF8
        ) |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    $legacyManifestUnique = @($legacyManifestLines | Sort-Object -Unique)
    $legacyManifestInvalid = @($legacyManifestLines | Where-Object { [IO.Path]::IsPathRooted($_) -or $_ -match '(^|[\\/])[.][.]([\\/]|$)' })
    Check "V1-owned manifest is exactly 27 unique path-safe entries" (
        $legacyManifestLines.Count -eq 27 -and
        $legacyManifestLines.Count -eq $legacyManifestUnique.Count -and
        $legacyManifestInvalid.Count -eq 0
    )
    $expectedLegacyRemovalProjectionHash = "16F51949FF3DF81A7E33E471E25432034A72AF2136EB3D138FEB6F710E61B58A"
    $legacyRemovalProjectionHash = Get-Sha256Text -Text ($legacyManifestLines -join "`n")
    $equivalenceMap = [IO.File]::ReadAllText(
        (Join-Path $root "manifests\local-postimage-equivalence.json"),
        [Text.Encoding]::UTF8
    ) | ConvertFrom-Json -DateKind String
    Check "V1-owned removal projection matches the independent frozen digest" (
        $legacyRemovalProjectionHash -ceq $expectedLegacyRemovalProjectionHash -and
        [string]$equivalenceMap.legacyRemovalProjectionSha256 -ceq $expectedLegacyRemovalProjectionHash
    ) $legacyRemovalProjectionHash
    $byteExactPayloads = @(
        $equivalenceMap.entries |
            Where-Object { [string]$_.mode -eq "byte-exact" } |
            Sort-Object order |
            ForEach-Object { [string]$_.payload }
    )
    Check "portable hardening leaves no byte-exact payload identities" (
        $byteExactPayloads.Count -eq 0
    ) ($byteExactPayloads -join ", ")
    Check "V1-owned manifest covers legacy activator, rules, hooks, docs, and removed skill reference" (
        $legacyManifestLines -contains "tools/enable-codex-hooks.ps1" -and
        $legacyManifestLines -contains "rules/workflow-routing.md" -and
        $legacyManifestLines -contains "tools/hooks/agent-hook-prompt-reminder.ps1" -and
        $legacyManifestLines -contains "docs/activation-guide.md" -and
        $legacyManifestLines -contains "skills/steadyagent-workflow/references/claude-code-practices.md"
    )
    $preCommitBytes = [IO.File]::ReadAllBytes((Join-Path $root "tools\git-hooks\pre-commit"))
    $hasBom = $preCommitBytes.Length -ge 3 -and $preCommitBytes[0] -eq 0xEF -and $preCommitBytes[1] -eq 0xBB -and $preCommitBytes[2] -eq 0xBF
    $preCommitEolAttribute = [string](& git check-attr eol -- "tools/git-hooks/pre-commit")
    Check "extensionless Git hook is pinned to LF in attributes" ($preCommitEolAttribute -match ':\s+eol:\s+lf$') $preCommitEolAttribute
    Check "Git hook entrypoint is LF and BOM-free" (-not $hasBom -and -not ($preCommitBytes -contains 13))

    $files = @($inventory | Where-Object {
        [IO.Path]::GetExtension([string]$_) -notin @(".png", ".jpg", ".jpeg", ".gif", ".ico")
    })
    $privateHits = New-Object Collections.Generic.List[string]
    $secretHits = New-Object Collections.Generic.List[string]
    $nonSystemDrivePattern = '(?i)(?:^|[^A-Z0-9])E:[\\/]'
    $userProfilePattern = '(?i)[A-Z]:[\\/]+Users[\\/]+(?!Public(?:[\\/]|$)|Default(?:[\\/]|$)|Default User(?:[\\/]|$)|All Users(?:[\\/]|$)|<[^>]+>)[^\\/\r\n]+'
    $emailPattern = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
    $slashProfileExample = "C:/Us" + "ers/maintainer/.agent-tools/tool.ps1"
    $backslashProfileExample = "C:\Us" + "ers\maintainer\.agent-tools\tool.ps1"
    Check "private path detector covers slash variants and hidden release inventory" (
        $slashProfileExample -match $userProfilePattern -and
        $backslashProfileExample -match $userProfilePattern -and
        $inventory -contains ".github/workflows/release.yml"
    )
    foreach ($relative in $files) {
        $full = Join-Path $root $relative
        try { $text = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8) } catch { continue }
        $publicEmails = @([regex]::Matches($text, $emailPattern) | Where-Object {
            $_.Value -notmatch '(?i)@(example[.]invalid|example[.]com|example[.]org|example[.]net)$'
        })
        if ($text -match $userProfilePattern -or $publicEmails.Count -gt 0 -or $text -match $nonSystemDrivePattern) {
            $privateHits.Add($relative)
        }
        if ($text -match '(?i)(api[_-]?key|token|password)\s*[:=]\s*["''][A-Za-z0-9_-]{12,}') { $secretHits.Add($relative) }
    }
    Check "public files contain no maintainer-private absolute paths" ($privateHits.Count -eq 0) ($privateHits -join ", ")
    Check "public files contain no obvious secrets" ($secretHits.Count -eq 0) ($secretHits -join ", ")

    $parseFailures = New-Object Collections.Generic.List[string]
    $encodingFailures = New-Object Collections.Generic.List[string]
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    foreach ($scriptFile in @(Get-ChildItem -LiteralPath $root -Recurse -Filter "*.ps1" -File | Where-Object { $_.FullName -notmatch '[\\/][.]git[\\/]' })) {
        $scriptBytes = [IO.File]::ReadAllBytes($scriptFile.FullName)
        $scriptHasBom = $scriptBytes.Length -ge 3 -and $scriptBytes[0] -eq 0xEF -and $scriptBytes[1] -eq 0xBB -and $scriptBytes[2] -eq 0xBF
        try { $strictUtf8.GetString($scriptBytes) | Out-Null }
        catch { $encodingFailures.Add($scriptFile.FullName) }
        if ($scriptHasBom) { $encodingFailures.Add($scriptFile.FullName) }
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) { $parseFailures.Add($scriptFile.FullName) }
    }
    Check "all PowerShell files parse under PowerShell 7.5+" ($parseFailures.Count -eq 0) ($parseFailures -join ", ")
    Check "PowerShell files use strict UTF-8 without BOM" ($encodingFailures.Count -eq 0) ($encodingFailures -join ", ")

    $linkFailures = New-Object Collections.Generic.List[string]
    foreach ($markdown in @(Get-ChildItem -LiteralPath $root -Recurse -Filter "*.md" -File | Where-Object { $_.FullName -notmatch '[\\/][.]git[\\/]|[\\/][.]agent[\\/]' })) {
        $text = Remove-MarkdownFencedCode -Text (
            [IO.File]::ReadAllText($markdown.FullName, [Text.Encoding]::UTF8)
        )
        foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)')) {
            $target = $match.Groups[1].Value
            if ($target -match '^(?i:https?://|mailto:|#)') { continue }
            $resolved = [IO.Path]::GetFullPath((Join-Path $markdown.DirectoryName $target))
            if (-not (Test-Path -LiteralPath $resolved)) { $linkFailures.Add(($markdown.FullName + " -> " + $target)) }
        }
    }
    $fencedCastFixture = "``````powershell`n`$Value = [string](gh api invalid)`n``````"
    Check "Markdown link scan excludes fenced PowerShell casts" (
        [regex]::Matches(
            (Remove-MarkdownFencedCode -Text $fencedCastFixture),
            '\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)'
        ).Count -eq 0
    )
    Check "local Markdown links resolve" ($linkFailures.Count -eq 0) ($linkFailures -join "; ")

    Run-Gate "release whitespace behavior suite passes" (Join-Path $root "tools\test-release-whitespace.ps1")
    Run-Gate "release workflow state machine passes" (Join-Path $root "tools\test-release-workflow.ps1")
    Run-Gate "Codex runtime slice passes" (Join-Path $root "tools\validate-runtime-slice.ps1") @("-SkipHookBehaviorSuite")
    Run-Gate "23-item local equivalence gate passes" (Join-Path $root "tools\test-local-equivalence.ps1")
    $hookInvocationLines = @(
        [IO.File]::ReadAllLines($hookInvocationLedgerPath, [Text.Encoding]::UTF8) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    Check "release gate owns exactly one installed Hook suite invocation" (
        $hookInvocationLines.Count -eq 1 -and
        [string]$hookInvocationLines[0] -match '^hooks[|].+[\\/]steadyagent$' -and
        -not ([string]$hookInvocationLines[0]).Equals(
            ("hooks|" + $root),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) ($hookInvocationLines -join ",")

    $workflow = [IO.File]::ReadAllText((Join-Path $root ".github\workflows\validate.yml"), [Text.Encoding]::UTF8)
    $releaseWorkflow = [IO.File]::ReadAllText((Join-Path $root ".github\workflows\release.yml"), [Text.Encoding]::UTF8)
    Check "GitHub Actions runs on Windows" ($workflow -match "windows-latest")
    Check "GitHub Actions runs release readiness" ($workflow -match "validate-release-readiness[.]ps1")
    Check "GitHub Actions needs no elevated-only fixture bypass" (
        $workflow -notmatch 'STEADYAGENT_ALLOW_ELEVATED_FIXTURE' -and
        $releaseWorkflow -notmatch 'STEADYAGENT_ALLOW_ELEVATED_FIXTURE'
    )
    Check "GitHub Actions release gate has one reviewed 60-minute timeout" (
        ([regex]::Matches($workflow, '(?m)^\s*timeout-minutes:\s*60\s*$')).Count -eq 1
    )
    Check "GitHub Actions fetches history and supplies a release base" (
        $workflow -match "fetch-depth:\s*0" -and
        $workflow -match "STEADYAGENT_RELEASE_BASE_REF" -and
        $workflow -match 'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd' -and
        $workflow -match '(?m)^\s*FORCE_JAVASCRIPT_ACTIONS_TO_NODE24:\s*["'']?true["'']?\s*$'
    )
    Check "release workflow is exact-tag and draft-only" (
        $releaseWorkflow -match '(?m)^\s+- v3[.]0[.]1\s*$' -and
        $releaseWorkflow -match 'gh api --method POST "repos/\$env:GH_REPO/releases"' -and
        $releaseWorkflow -match 'draft\s*=\s*\$true' -and
        $releaseWorkflow -match 'exact draft already exists' -and
        $releaseWorkflow -notmatch '(?m)^\s+- [''"]?v[*]'
    )
    $attestJobText = [regex]::Match(
        $releaseWorkflow,
        '(?ms)^  attest-reviewed-archive:\s*(?<job>.*?)(?=^  create-draft:)'
    ).Groups['job'].Value
    $draftJobText = [regex]::Match(
        $releaseWorkflow,
        '(?ms)^  create-draft:\s*(?<job>.*)\z'
    ).Groups['job'].Value
    Check "release workflow pins every action and grants only job-scoped release permissions" (
        $releaseWorkflow -match 'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd' -and
        $releaseWorkflow -match 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' -and
        $releaseWorkflow -match 'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c' -and
        $releaseWorkflow -match 'actions/attest@508db95dd578ae2727ebd6217d5ba78e4fbda05d' -and
        $releaseWorkflow -match '(?m)^\s*FORCE_JAVASCRIPT_ACTIONS_TO_NODE24:\s*["'']?true["'']?\s*$' -and
        $releaseWorkflow -match '(?m)^permissions:\s*\{\}\s*$' -and
        $attestJobText -match 'contents:\s*read' -and
        $attestJobText -match 'id-token:\s*write' -and
        $attestJobText -match 'attestations:\s*write' -and
        $attestJobText -notmatch 'contents:\s*write' -and
        $draftJobText -match 'contents:\s*write' -and
        $draftJobText -notmatch 'id-token:\s*write|attestations:\s*write'
    )
    Check "release workflow separates read-only validation from minimal publication" (
        $releaseWorkflow -match '(?m)^\s*build-and-validate:\s*$' -and
        $releaseWorkflow -match '(?m)^\s*attest-reviewed-archive:\s*$' -and
        $releaseWorkflow -match '(?m)^\s*create-draft:\s*$' -and
        $releaseWorkflow -match 'persist-credentials:\s*false' -and
        $releaseWorkflow -match 'archive-sha256' -and
        $releaseWorkflow -match 'needs[.]build-and-validate[.]outputs[.]archive-sha256' -and
        $releaseWorkflow -match 'cancel-in-progress:\s*false'
    )
    Check "release workflow gates, no-Git-validates, attests, and publishes the same tagged archive" (
        $releaseWorkflow -match 'validate-release-readiness[.]ps1' -and
        $releaseWorkflow -match 'validate-release-archive[.]ps1' -and
        $releaseWorkflow -match 'git archive' -and
        $releaseWorkflow -match 'refs/remotes/origin/main' -and
        $releaseWorkflow -match 'subject-path:\s*dist/boring-is-all-you-need-v3[.]0[.]1[.]zip' -and
        $releaseWorkflow -match '[.]\\dist\\boring-is-all-you-need-v3[.]0[.]1[.]zip' -and
        $releaseWorkflow -match 'boring-is-all-you-need-v3[.]0[.]1[.]provenance[.]json' -and
        $releaseWorkflow -match 'releaseBodySha256' -and
        $releaseWorkflow -match 'RELEASE_BODY[.]md'
    )
    Check "release workflow freezes V1 lineage and explicit publication repository context" (
        $releaseWorkflow -match 'f80c05c4b79e069ee3a35db3c09a8f870bca0b59' -and
        $releaseWorkflow -match '7641ff9ff8c372036766541d565b81e44e1f8704' -and
        $releaseWorkflow -match 'merge-base --is-ancestor' -and
        $releaseWorkflow -match 'GH_REPO' -and
        $releaseWorkflow -match 'gh release view[\s\S]*-R' -and
        $releaseWorkflow -match 'gh release download[\s\S]*-R' -and
        $releaseWorkflow -match 'gh release upload[\s\S]*-R' -and
        $releaseWorkflow -match 'repos/\$env:GH_REPO/releases'
    )
    Check "release workflow revalidates live tag and main around draft creation" (
        $releaseWorkflow -match 'release-sha' -and
        $releaseWorkflow -match 'needs[.]build-and-validate[.]outputs[.]release-sha' -and
        ([regex]::Matches($releaseWorkflow, 'Assert-LiveReleaseRefs')).Count -ge 4 -and
        $releaseWorkflow -match 'git/ref/tags/' -and
        $releaseWorkflow -match 'git/ref/heads/main' -and
        $releaseWorkflow -match 'git/tags/'
    )
    Check "release workflow makes exact draft retries and post-create ref races recoverable" (
        $draftJobText -match 'Test-ExactRecoverableDraft' -and
        $draftJobText -match 'body,isDraft,isPrerelease,databaseId,assets' -and
        $draftJobText -match 'gh release download' -and
        $draftJobText -match 'Get-FileHash -LiteralPath \$sidecarPath' -and
        $draftJobText -match 'Get-FileHash -LiteralPath \$provenancePath' -and
        $draftJobText -match 'retry is complete' -and
        $draftJobText -match 'createdReleaseId' -and
        $draftJobText -match '\$finalDraft\s*=\s*Get-LiveDraftState' -and
        $draftJobText -match '\[int64\]\$finalDraft[.]databaseId\s*-ne\s*\$createdReleaseId' -and
        $draftJobText -match 'gh api --method DELETE "repos/\$env:GH_REPO/releases/\$createdReleaseId"' -and
        $draftJobText -notmatch 'gh release delete' -and
        $draftJobText -match 'safe to retry' -and
        $draftJobText -match 'preserve it for manual review'
    )

    Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}
finally {
    if ($null -eq $oldHookInvocationLedger) {
        Remove-Item Env:\STEADYAGENT_HOOK_INVOCATION_LEDGER -ErrorAction SilentlyContinue
    }
    else {
        $env:STEADYAGENT_HOOK_INVOCATION_LEDGER = $oldHookInvocationLedger
    }
    if ($null -eq $oldEquivalenceTestMode) {
        Remove-Item Env:\STEADYAGENT_EQUIVALENCE_TEST_MODE -ErrorAction SilentlyContinue
    }
    else {
        $env:STEADYAGENT_EQUIVALENCE_TEST_MODE = $oldEquivalenceTestMode
    }
    if (Test-Path -LiteralPath $hookInvocationLedgerPath -PathType Leaf) {
        Remove-Item -LiteralPath $hookInvocationLedgerPath -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}

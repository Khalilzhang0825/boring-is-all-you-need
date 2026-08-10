# GitHub Publication Runbook

前置条件：`git` 与当前版 `gh` 已认证，`origin` 指向
`Khalilzhang0825/boring-is-all-you-need`，maintainer 有权限推送已审查分支并创建受保护的
`v3.0.1` tag，仓库 Actions 允许写 contents、OIDC token 与 attestations。

本文件用于本地 release-readiness 通过后、公开 push / tag / release 前的最终执行。

## 必备本地证据

在干净 working tree 根目录运行：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

该聚合门持有唯一一次安装副本 Hook 套件调用，并已包含 phase、runtime、migration、equivalence、checkpoint、pre-commit 与 skill-catalog 子门；不要再把子门作为独立发布必跑项重复执行。

记录命令输出、GitHub Actions run URL、release URL、tag、目标 commit 和 repository metadata update notes。

发行包必须由 `.github/workflows/release.yml` 从精确的 `v3.0.1` tag 构建；不得上传本地临时组装的替代压缩包。

## Maintainer Approval

只有得到 maintainer 明确批准后，才执行公开 GitHub 写操作；approval boundary: explicit maintainer approval。

批准项必须包括：

- 目标仓库
- 目标分支
- tag name
- target commit
- release type

## Push And PR

只有得到 maintainer 明确批准后才运行：

```powershell
$Branch = ([string](git branch --show-current)).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Branch)) {
  throw "无法解析当前分支。"
}
git check-ref-format --branch $Branch
if ($LASTEXITCODE -ne 0) { throw "当前分支名不可发布。" }
git push -u origin ("refs/heads/{0}:refs/heads/{0}" -f $Branch)
if ($LASTEXITCODE -ne 0) { throw "分支 push 失败。" }
```

普通改动应先开 PR，等待 GitHub Actions 通过后再 merge。

V3 保留公开的 V1 与 V2 历史。history rewrite、orphan commit、force-push、release replacement 与 tag replacement 均不属于本次发布流程。
workflow 将 `v1.0.0` 冻结到
`f80c05c4b79e069ee3a35db3c09a8f870bca0b59`，要求它是发行候选的祖先，并要求
仓库只有一个固定 root：`7641ff9ff8c372036766541d565b81e44e1f8704`。

## Repository Metadata

推荐 GitHub description：

```text
Boring Is All You Need: a Codex Desktop workflow replacement with transactional migration, audit-only managed hooks, risk-based review, scoped checkpoint commits, and release evidence.
```

推荐 topics：

```text
ai-agents, coding-agents, codex, codex-desktop, agents-md, developer-tools, powershell, workflow-automation, prompt-engineering
```

## Release

只有 maintainer 明确批准 tag/release、版本号、发布类型和目标 commit 后，才可以创建或替换 tag / GitHub release。

Release template：

```text
Tag: v3.0.1
Title: Boring Is All You Need v3.0.1
Target commit: 由下方命令解析并验证的精确 `$ReviewedSha`
```

已审查 commit 合并到 `main` 且仍为当前 tip 后，精确创建并推送 tag：

```powershell
$Tag = "v3.0.1"
$ReviewedSha = git rev-parse origin/main
if ($LASTEXITCODE -ne 0 -or $ReviewedSha.Trim() -notmatch '^[0-9a-f]{40}$') { throw "无法解析 origin/main。" }
$ReviewedSha = ([string]$ReviewedSha).Trim()
$HeadSha = git rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $HeadSha.Trim() -ne $ReviewedSha) { throw "HEAD 不是 origin/main。" }

function Get-RemoteTagCommit {
  $lines = @(git ls-remote --exit-code --tags origin "refs/tags/$Tag" "refs/tags/$Tag^{}")
  $code = $LASTEXITCODE
  if ($code -eq 2) { return $null }
  if ($code -ne 0) { throw "无法检查远端 release tag。" }
  $peeled = @($lines | Where-Object { $_ -match '\^\{\}$' })
  $selected = if ($peeled.Count -eq 1) { $peeled[0] } elseif ($lines.Count -eq 1) { $lines[0] } else { throw "远端 release tag 解析结果不唯一。" }
  $sha = ($selected -split '\s+')[0]
  $sha = [string]$sha
  if ($sha -notmatch '^[0-9a-f]{40}$') { throw "远端 release tag 未解析到 commit。" }
  return $sha
}

$LocalTagCommit = git rev-parse --verify --quiet "refs/tags/$Tag^{commit}"
$LocalTagCommit = [string]$LocalTagCommit
$LocalTagExit = $LASTEXITCODE
if ($LocalTagExit -eq 1) {
  git tag $Tag $ReviewedSha
  if ($LASTEXITCODE -ne 0) { throw "无法创建指向已审查 commit 的本地 release tag。" }
} elseif ($LocalTagExit -ne 0) {
  throw "无法检查本地 release tag。"
}
$LocalTagCommit = git rev-parse "refs/tags/$Tag^{commit}"
$LocalTagCommit = [string]$LocalTagCommit
if ($LASTEXITCODE -ne 0 -or $LocalTagCommit.Trim() -ne $ReviewedSha) { throw "本地 release tag 未指向已审查 commit。" }

$RemoteTagCommit = Get-RemoteTagCommit
if ($null -ne $RemoteTagCommit -and $RemoteTagCommit -ne $ReviewedSha) { throw "远端 release tag 已指向其他 commit。" }
if ($null -eq $RemoteTagCommit) {
  git push origin "refs/tags/$Tag:refs/tags/$Tag"
  if ($LASTEXITCODE -ne 0) { throw "无法推送已审查 release tag。" }
  $RemoteTagCommit = Get-RemoteTagCommit
  if ($RemoteTagCommit -ne $ReviewedSha) { throw "推送后的 release tag 未回读为已审查 commit。" }
} else {
  Write-Host "远端 release tag 已指向已审查 commit；未执行 tag 写入。"
}
```

已审查 commit 合并到 `main` 且仍是当前 tip 后，推送精确的 `v3.0.1` tag 会触发三个固定版本、Node-24-native、最小权限 job，并由精确 release concurrency group 串行化。只读 build job 从冻结的 V1 whitespace 基线重新运行干净 tag-checkout 门、生成 `boring-is-all-you-need-v3.0.1.zip`、在没有 `.git` 的精确解压包上运行验证，并传递 SHA-256 绑定的 bundle；attestation job 仅拥有 read、OIDC 与 attestation 权限并证明该 archive；contents-write job 只创建显示 reviewed commit 的 **draft** GitHub Release。它在创建前后重新解析 live lightweight/annotated tag 与 `main`。重跑只接受标题、正文和 archive、checksum、机器可读 provenance 三个 asset 字节均精确一致、且不是 prerelease 的 draft；其他既有 release 全部保留供人工检查。上传后还会读回 live release，强制 captured release ID、draft 状态、正文、资产、摘要、tag 与 `main` 全部精确一致。若创建后 refs 漂移，只有 live draft 仍匹配本次 run 捕获的 release ID 且保持 exact 时才自动清理。

发布草稿前运行：

```powershell
gh attestation verify --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "当前 GitHub CLI 不提供 attestation verify。" }
gh release download v3.0.1 -R Khalilzhang0825/boring-is-all-you-need -p "boring-is-all-you-need-v3.0.1.*"
if ($LASTEXITCODE -ne 0) { throw "无法下载精确的 v3.0.1 release assets。" }
$Provenance = Get-Content -Raw .\boring-is-all-you-need-v3.0.1.provenance.json | ConvertFrom-Json
$ReviewedSha = [string]$Provenance.reviewedCommit
$Expected = (Get-Content -Raw .\boring-is-all-you-need-v3.0.1.zip.sha256).Split(" ")[0].Trim()
$Actual = (Get-FileHash .\boring-is-all-you-need-v3.0.1.zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ([int]$Provenance.schemaVersion -ne 1 -or
    [string]$Provenance.releaseTag -cne "v3.0.1" -or
    $ReviewedSha -notmatch '^[0-9a-f]{40}$' -or
    [string]$Provenance.archiveName -cne "boring-is-all-you-need-v3.0.1.zip" -or
    [string]$Provenance.archiveSha256 -cne $Actual -or
    $Expected -cne $Actual -or
    [string]$Provenance.sourceRepository -cne "Khalilzhang0825/boring-is-all-you-need" -or
    [string]$Provenance.sourceRef -cne "refs/tags/v3.0.1" -or
    [string]$Provenance.signerWorkflow -cne "Khalilzhang0825/boring-is-all-you-need/.github/workflows/release.yml") {
  throw "Release provenance or digest mismatch."
}
gh attestation verify .\boring-is-all-you-need-v3.0.1.zip `
  -R Khalilzhang0825/boring-is-all-you-need `
  --signer-workflow Khalilzhang0825/boring-is-all-you-need/.github/workflows/release.yml `
  --source-ref refs/tags/v3.0.1 `
  --source-digest $ReviewedSha
if ($LASTEXITCODE -ne 0) { throw "Release attestation 验证失败；不得解压或运行该 archive。" }
Expand-Archive .\boring-is-all-you-need-v3.0.1.zip .\release-check
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\release-check\boring-is-all-you-need-v3.0.1\tools\validate-release-archive.ps1
```

如果 `gh attestation verify --help` 失败，先安装或更新当前 [GitHub CLI](https://cli.github.com/)。在线 attestation 验证需要访问 GitHub；不能把同源 sidecar 单独当成来源证明。

若失败的 workflow 留下 partial draft，不得盲目重跑。只有 maintainer 明确批准后，
才能用失败 run 保留的 bundle 证明该 draft 确实是此 run 产生且未变化的 partial
output。下面的恢复流程会捕获数字 ID、把每个现有 asset 与 workflow bundle
逐字节核对、删除前立即按同一 ID 回读，只删除该 ID，并在保留并发 replacement
的同时确认旧 ID 已消失：

```powershell
$Repository = "Khalilzhang0825/boring-is-all-you-need"
$Tag = "v3.0.1"
$RunIdText = Read-Host "粘贴失败的 release workflow run ID"
$RunId = 0L
if (-not [long]::TryParse($RunIdText, [ref]$RunId) -or $RunId -le 0) { throw "Workflow run ID 无效。" }
$ExpectedRoot = Join-Path $env:TEMP ("steadyagent-release-recovery-" + [guid]::NewGuid().ToString("N"))
$RemoteRoot = Join-Path $ExpectedRoot "remote"
New-Item -ItemType Directory -Path $RemoteRoot -Force | Out-Null
gh run download $RunId -R $Repository -n boring-is-all-you-need-v3.0.1-release-bundle -D $ExpectedRoot
if ($LASTEXITCODE -ne 0) { throw "无法下载失败 run 的已审查 bundle。" }

function Get-ReleaseById {
  param([long]$ReleaseId)
  $json = gh api "repos/$Repository/releases/$ReleaseId"
  if ($LASTEXITCODE -ne 0) { throw "无法读取 release ID $ReleaseId。" }
  return ($json | ConvertFrom-Json)
}
function Get-ReleaseProjection {
  param([object]$State)
  $assets = @($State.assets | Sort-Object name | ForEach-Object {
    [ordered]@{ id = [long]$_.id; name = [string]$_.name; size = [long]$_.size; digest = [string]$_.digest; updated_at = [string]$_.updated_at }
  })
  return ([ordered]@{
    id = [long]$State.id; draft = [bool]$State.draft; prerelease = [bool]$State.prerelease
    tag_name = [string]$State.tag_name; name = [string]$State.name; body = [string]$State.body; assets = $assets
  } | ConvertTo-Json -Depth 5 -Compress)
}

$tagJson = gh api "repos/$Repository/releases/tags/$Tag"
if ($LASTEXITCODE -ne 0) { throw "无法按 tag 读取 partial draft。" }
$CapturedDraft = $tagJson | ConvertFrom-Json
$CapturedReleaseId = [long]$CapturedDraft.id
$ExpectedBody = [IO.File]::ReadAllText((Join-Path $ExpectedRoot "RELEASE_BODY.md"), [Text.Encoding]::UTF8)
$ExpectedAssetNames = @(
  "boring-is-all-you-need-v3.0.1.provenance.json",
  "boring-is-all-you-need-v3.0.1.zip",
  "boring-is-all-you-need-v3.0.1.zip.sha256"
)
$CapturedAssetNames = @($CapturedDraft.assets | ForEach-Object { [string]$_.name } | Sort-Object)
if ($CapturedReleaseId -le 0 -or -not [bool]$CapturedDraft.draft -or [bool]$CapturedDraft.prerelease -or
    [string]$CapturedDraft.tag_name -cne $Tag -or [string]$CapturedDraft.name -cne "Boring Is All You Need v3.0.1" -or
    [string]$CapturedDraft.body -cne $ExpectedBody -or $CapturedAssetNames.Count -ge 3 -or
    @($CapturedAssetNames | Where-Object { $ExpectedAssetNames -notcontains $_ }).Count -ne 0 -or
    @($CapturedAssetNames | Sort-Object -Unique).Count -ne $CapturedAssetNames.Count) {
  throw "Live release 不是该失败 run 创建的精确 partial draft。"
}
foreach ($assetName in $CapturedAssetNames) {
  gh release download $Tag -R $Repository -D $RemoteRoot -p $assetName
  if ($LASTEXITCODE -ne 0) { throw "无法下载 partial draft asset $assetName。" }
  $expectedPath = Join-Path $ExpectedRoot $assetName
  $remotePath = Join-Path $RemoteRoot $assetName
  if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf) -or
      (Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash -cne
      (Get-FileHash -LiteralPath $remotePath -Algorithm SHA256).Hash) {
    throw "Partial draft asset $assetName 不是字节精确版本。"
  }
}
$CapturedProjection = Get-ReleaseProjection -State $CapturedDraft
$BeforeDelete = Get-ReleaseById -ReleaseId $CapturedReleaseId
if ((Get-ReleaseProjection -State $BeforeDelete) -cne $CapturedProjection) { throw "Captured draft 在删除前已变化；必须保留。" }
gh api --method DELETE "repos/$Repository/releases/$CapturedReleaseId"
if ($LASTEXITCODE -ne 0) { throw "无法删除捕获的 partial draft ID。" }
$allJson = gh api --paginate --slurp "repos/$Repository/releases?per_page=100"
if ($LASTEXITCODE -ne 0) { throw "无法确认 captured release ID 已删除。" }
$allReleases = @($allJson | ConvertFrom-Json | ForEach-Object { $_ | ForEach-Object { $_ } })
if (@($allReleases | Where-Object { [long]$_.id -eq $CapturedReleaseId }).Count -ne 0) { throw "Captured release ID 仍然存在。" }
$replacement = @($allReleases | Where-Object { [string]$_.tag_name -ceq $Tag -and [long]$_.id -ne $CapturedReleaseId })
if ($replacement.Count -gt 0) { Write-Host "已保留 replacement release，等待人工检查。" }
gh run rerun $RunId --failed -R $Repository
if ($LASTEXITCODE -ne 0) { throw "无法重跑失败的 workflow jobs。" }
```

Release 草稿正文应包含：

- 本次变更
- 已包含的公开资产
- validation results
- known limits
- workflow 生成的 reviewed commit

只有 workflow 绿色、attestation 验证通过、摘要一致，且无 `.git` 的 archive validator 报告 `fail=0` 后，才能发布草稿。另需确认 tag 的 fresh clone 能通过依赖 Git 的 clean release gate。公开前必须再次解析 live tag 与 `main`，并要求二者都等于记录的已审查 commit。Attestation 证明来源，不代表代码绝对没有漏洞。

```powershell
$Repository = "Khalilzhang0825/boring-is-all-you-need"
$Tag = "v3.0.1"
$Provenance = Get-Content -Raw .\boring-is-all-you-need-v3.0.1.provenance.json | ConvertFrom-Json
$ReviewedSha = [string]$Provenance.reviewedCommit
$ExpectedAssetNames = @(
  "boring-is-all-you-need-v3.0.1.provenance.json",
  "boring-is-all-you-need-v3.0.1.zip",
  "boring-is-all-you-need-v3.0.1.zip.sha256"
)
$ReleaseNotes = [IO.File]::ReadAllText((Resolve-Path .\RELEASE_NOTES.md), [Text.Encoding]::UTF8).TrimEnd([char[]]"`r`n")
$ExpectedBody = $ReleaseNotes + "`n`n## Verified provenance`n`nReviewed commit: $ReviewedSha`nSource ref: refs/tags/v3.0.1`n"
$ExpectedBodyHash = [BitConverter]::ToString(
  [Security.Cryptography.SHA256]::Create().ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($ExpectedBody))
).Replace("-", "").ToLowerInvariant()
if ([string]$Provenance.releaseBodySha256 -cne $ExpectedBodyHash) { throw "本地 release body 与 provenance 不一致。" }

function Get-ReleaseById {
  param([long]$ReleaseId)
  $json = gh api "repos/$Repository/releases/$ReleaseId"
  if ($LASTEXITCODE -ne 0) { throw "无法读取 release ID $ReleaseId。" }
  return ($json | ConvertFrom-Json)
}
function Get-ReleaseProjection {
  param([object]$State)
  $assets = @($State.assets | Sort-Object name | ForEach-Object {
    [ordered]@{ id = [long]$_.id; name = [string]$_.name; size = [long]$_.size; digest = [string]$_.digest; updated_at = [string]$_.updated_at }
  })
  return ([ordered]@{
    id = [long]$State.id; draft = [bool]$State.draft; prerelease = [bool]$State.prerelease
    tag_name = [string]$State.tag_name; name = [string]$State.name; body = [string]$State.body; assets = $assets
  } | ConvertTo-Json -Depth 5 -Compress)
}
function Assert-ExactReleaseDraft {
  param([object]$State, [long]$ReleaseId)
  $assetNames = @($State.assets | ForEach-Object { [string]$_.name } | Sort-Object)
  if ([long]$State.id -ne $ReleaseId -or -not [bool]$State.draft -or [bool]$State.prerelease -or
      [string]$State.tag_name -cne $Tag -or [string]$State.name -cne "Boring Is All You Need v3.0.1" -or
      [string]$State.body -cne $ExpectedBody -or ($assetNames -join "|") -cne
      "boring-is-all-you-need-v3.0.1.provenance.json|boring-is-all-you-need-v3.0.1.zip|boring-is-all-you-need-v3.0.1.zip.sha256") {
    throw "Captured release 不是精确的已审查 draft。"
  }
}

$tagJson = gh api "repos/$Repository/releases/tags/$Tag"
if ($LASTEXITCODE -ne 0) { throw "无法按 tag 读取已审查 draft。" }
$CapturedDraft = $tagJson | ConvertFrom-Json
$CapturedReleaseId = [long]$CapturedDraft.id
Assert-ExactReleaseDraft -State $CapturedDraft -ReleaseId $CapturedReleaseId
$CapturedProjection = Get-ReleaseProjection -State $CapturedDraft
$CapturedAssetProjection = @($CapturedDraft.assets | Sort-Object name | ForEach-Object {
  [ordered]@{ id = [long]$_.id; name = [string]$_.name; size = [long]$_.size; digest = [string]$_.digest; updated_at = [string]$_.updated_at }
}) | ConvertTo-Json -Depth 4 -Compress
$RemoteRoot = Join-Path $env:TEMP ("steadyagent-publish-check-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $RemoteRoot -Force | Out-Null
foreach ($assetName in $ExpectedAssetNames) {
  gh release download $Tag -R $Repository -D $RemoteRoot -p $assetName
  if ($LASTEXITCODE -ne 0) { throw "无法下载 draft asset $assetName。" }
  if ((Get-FileHash -LiteralPath (Join-Path $RemoteRoot $assetName) -Algorithm SHA256).Hash -cne
      (Get-FileHash -LiteralPath (Resolve-Path (".\" + $assetName)) -Algorithm SHA256).Hash) {
    throw "Draft asset $assetName 在验证后发生变化。"
  }
}
function Assert-TagPublicationGuards {
  param([string]$Repository, [string]$Tag)
  $ImmutableJson = gh api -H "X-GitHub-Api-Version: 2026-03-10" "repos/$Repository/immutable-releases"
  if ($LASTEXITCODE -ne 0) { throw "未启用 immutable releases，或无法验证其状态。" }
  $ImmutableState = $ImmutableJson | ConvertFrom-Json
  if (-not [bool]$ImmutableState.enabled) { throw "发布前必须启用 immutable releases。" }
  $RulesetSummariesJson = gh api -H "X-GitHub-Api-Version: 2026-03-10" `
    "repos/$Repository/rulesets?targets=tag&per_page=100"
  if ($LASTEXITCODE -ne 0) { throw "无法枚举 tag ruleset。" }
  $ExactTagRef = "refs/tags/$Tag"
  $ExactGuardFound = $false
  foreach ($summary in @($RulesetSummariesJson | ConvertFrom-Json)) {
    $RulesetJson = gh api -H "X-GitHub-Api-Version: 2026-03-10" `
      "repos/$Repository/rulesets/$([long]$summary.id)"
    if ($LASTEXITCODE -ne 0) { throw "无法读取 tag ruleset。" }
    $Ruleset = $RulesetJson | ConvertFrom-Json
    $Includes = @($Ruleset.conditions.ref_name.include | ForEach-Object { [string]$_ })
    $Excludes = @($Ruleset.conditions.ref_name.exclude | ForEach-Object { [string]$_ })
    $RuleTypes = @($Ruleset.rules | ForEach-Object { [string]$_.type })
    $BypassProperty = $Ruleset.PSObject.Properties['bypass_actors']
    $HasExplicitNoBypass = (
      $null -ne $BypassProperty -and
      $null -ne $BypassProperty.Value -and
      @($BypassProperty.Value).Count -eq 0
    )
    if ([string]$Ruleset.target -ceq "tag" -and
        [string]$Ruleset.enforcement -ceq "active" -and
        $HasExplicitNoBypass -and
        $Includes -ccontains $ExactTagRef -and
        $Excludes.Count -eq 0 -and
        $RuleTypes -ccontains "update" -and
        $RuleTypes -ccontains "deletion") {
      $ExactGuardFound = $true
    }
  }
  if (-not $ExactGuardFound) {
    throw "必须存在 active、无 bypass、阻止精确 release tag 更新与删除的 tag ruleset。"
  }
}
Assert-TagPublicationGuards -Repository $Repository -Tag $Tag
$BeforePublish = Get-ReleaseById -ReleaseId $CapturedReleaseId
Assert-ExactReleaseDraft -State $BeforePublish -ReleaseId $CapturedReleaseId
if ((Get-ReleaseProjection -State $BeforePublish) -cne $CapturedProjection) { throw "Captured draft 在发布前已变化。" }
$LiveTagSha = gh api "repos/$Repository/commits/$Tag" --jq .sha
$LiveTagSha = [string]$LiveTagSha
if ($LASTEXITCODE -ne 0) { throw "无法解析 live release tag。" }
$LiveMainSha = gh api "repos/$Repository/commits/main" --jq .sha
$LiveMainSha = [string]$LiveMainSha
if ($LASTEXITCODE -ne 0) { throw "无法解析 live main。" }
if ($LiveTagSha.Trim() -ne $ReviewedSha -or $LiveMainSha.Trim() -ne $ReviewedSha) {
  throw "Live v3.0.1 或 main 已偏离已审查 commit。"
}
$publishedJson = gh api --method PATCH "repos/$Repository/releases/$CapturedReleaseId" -F draft=false
if ($LASTEXITCODE -ne 0) { throw "无法发布 captured release ID。" }
$Published = $publishedJson | ConvertFrom-Json
Assert-TagPublicationGuards -Repository $Repository -Tag $Tag
$PostPublishTagSha = [string](gh api "repos/$Repository/commits/$Tag" --jq .sha)
if ($LASTEXITCODE -ne 0) { throw "无法解析发布后的 release tag。" }
$PostPublishMainSha = [string](gh api "repos/$Repository/commits/main" --jq .sha)
if ($LASTEXITCODE -ne 0) { throw "无法解析发布后的 main。" }
if ($PostPublishTagSha.Trim() -ne $ReviewedSha -or $PostPublishMainSha.Trim() -ne $ReviewedSha) {
  throw "发布窗口内 ref 发生移动；保留 immutable release 证据并进入 incident review。"
}
$Readback = Get-ReleaseById -ReleaseId $CapturedReleaseId
foreach ($state in @($Published, $Readback)) {
  $assetNames = @($state.assets | ForEach-Object { [string]$_.name } | Sort-Object)
  $assetProjection = @($state.assets | Sort-Object name | ForEach-Object {
    [ordered]@{ id = [long]$_.id; name = [string]$_.name; size = [long]$_.size; digest = [string]$_.digest; updated_at = [string]$_.updated_at }
  }) | ConvertTo-Json -Depth 4 -Compress
  if ([long]$state.id -ne $CapturedReleaseId -or [bool]$state.draft -or [bool]$state.prerelease -or
      -not [bool]$state.immutable -or
      [string]$state.tag_name -cne $Tag -or [string]$state.name -cne "Boring Is All You Need v3.0.1" -or
      [string]$state.body -cne $ExpectedBody -or ($assetNames -join "|") -cne
      "boring-is-all-you-need-v3.0.1.provenance.json|boring-is-all-you-need-v3.0.1.zip|boring-is-all-you-need-v3.0.1.zip.sha256" -or
      $assetProjection -cne $CapturedAssetProjection) {
    throw "发布后的 release 回读不精确。"
  }
}
```

发布前必须由 GitHub Live 同时证明仓库已启用 immutable releases，并存在针对 `refs/tags/v3.0.1` 的精确、active、无 bypass、禁止 update/deletion 的 tag ruleset。发布后立即再次回读同一组 guard、tag SHA、main SHA、immutable flag、captured release ID、body 与 assets。不得弱化或绕过这些 guard；若发布后回读失败，应保留 immutable release 并进入 incident review，不得删除或复用 tag。

## 发布后检查

- 确认 README 在 GitHub 正常渲染。
- 确认 GitHub Actions 通过。
- 确认 release workflow 使用固定 action commit，且 attestation 可针对 `Khalilzhang0825/boring-is-all-you-need` 验证。
- 确认下载压缩包与 SHA-256 sidecar 一致，并且 fresh extraction 能通过 `validate-release-archive.ps1`。
- 确认 tag 的 fresh clone 能通过依赖 Git 的 `validate-release-readiness.ps1`。
- 确认 release 页面指向正确 tag 和 target commit。
- 确认 repository description 和 topics 已更新。
- 确认公开页面没有 private paths、local-only claims 或 maintainer-only state。
- 保存 PR URL、GitHub Actions run URL、release URL、tag、commit hash、repository metadata update notes 和验证输出，形成发布审计链。

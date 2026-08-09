# Boring Is All You Need 快速开始

Boring Is All You Need 只支持 Windows 上的 Codex Desktop。

## 1. 下载、验证并解压发行包

安装或更新当前 [GitHub CLI](https://cli.github.com/)，然后下载并验证 archive、checksum 与机器可读 provenance 三个 release asset：

Release workflow 将 build/validation、attestation 与 draft 创建拆为三个最小权限 job。重跑只接受显示 reviewed commit 的正文及三个 asset 均精确一致、且不是 prerelease 的 draft；ref 竞态清理绑定本次 run 创建的 release ID。

```powershell
gh attestation verify --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "当前 GitHub CLI 不提供 attestation verify。" }
gh release download v3.0.0 -R Khalilzhang0825/boring-is-all-you-need -p "boring-is-all-you-need-v3.0.0.*"
if ($LASTEXITCODE -ne 0) { throw "无法下载精确的 v3.0.0 release assets。" }
$Provenance = Get-Content -Raw .\boring-is-all-you-need-v3.0.0.provenance.json | ConvertFrom-Json
$ReviewedSha = [string]$Provenance.reviewedCommit
$Expected = (Get-Content -Raw .\boring-is-all-you-need-v3.0.0.zip.sha256).Split(" ")[0].Trim()
$Actual = (Get-FileHash .\boring-is-all-you-need-v3.0.0.zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ([int]$Provenance.schemaVersion -ne 1 -or
    [string]$Provenance.releaseTag -cne "v3.0.0" -or
    $ReviewedSha -notmatch '^[0-9a-f]{40}$' -or
    [string]$Provenance.archiveName -cne "boring-is-all-you-need-v3.0.0.zip" -or
    [string]$Provenance.archiveSha256 -cne $Actual -or
    $Expected -cne $Actual -or
    [string]$Provenance.sourceRepository -cne "Khalilzhang0825/boring-is-all-you-need" -or
    [string]$Provenance.sourceRef -cne "refs/tags/v3.0.0" -or
    [string]$Provenance.signerWorkflow -cne "Khalilzhang0825/boring-is-all-you-need/.github/workflows/release.yml") {
  throw "Release provenance or digest mismatch."
}
gh attestation verify .\boring-is-all-you-need-v3.0.0.zip `
  -R Khalilzhang0825/boring-is-all-you-need `
  --signer-workflow Khalilzhang0825/boring-is-all-you-need/.github/workflows/release.yml `
  --source-ref refs/tags/v3.0.0 `
  --source-digest $ReviewedSha
if ($LASTEXITCODE -ne 0) { throw "Release attestation 验证失败；不得解压或运行该 archive。" }
Expand-Archive .\boring-is-all-you-need-v3.0.0.zip .\boring-is-all-you-need-v3.0.0-release
Set-Location .\boring-is-all-you-need-v3.0.0-release\boring-is-all-you-need-v3.0.0
```

若 GitHub CLI 不提供 `attestation verify`、provenance 字段未绑定 reviewed commit 与 archive digest、来源验证失败或 checksum 不同，立即停止。

## 2. 验证解压包

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-archive.ps1 -IntegrityOnly
```

该快速完整性 archive gate 不依赖 `.git`，会检查 release inventory、manifest 与哈希、PowerShell 解析和编码、Hook 格式、文档链接以及 Codex-only 边界。CI 和维护者会运行包含行为、runtime、等价性与空白检查重套件在内的默认完整发布门，并在 tag 的 fresh clone 中另行运行依赖 Git 的 clean release gate。

## 3. 预览

> **运行环境：** 可以使用普通或管理员 PowerShell，也支持配置了 `[windows] sandbox = "elevated"` 的 Codex 任务。当前 token 必须已经能够更新全部目标。

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1
```

默认是 dry-run：不写入目标、配置、备份、收据或状态，只使用正常退出时会删除的系统临时 staging。

## 4. 应用

全新安装：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply
```

替换已有工作流：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply -ReplaceExistingWorkflow
```

可以使用普通或管理员 PowerShell。Apply 与 rollback 接受提权 token，但不会主动请求 UAC、修改 ACL 或接管 owner。当前 token 必须能够更新默认 `%ProgramData%\OpenAI\Codex\requirements.toml`。

## 5. 重启并诊断

重启 Codex Desktop，打开一个新的 Codex 任务，并让 Codex 在该任务的终端中运行以下代码块。该任务必须提供自身的 `CODEX_THREAD_ID`：

```powershell
$ReceiptPath = Read-Host "粘贴 install.ps1 在 'Recovery receipt:' 后输出的精确路径"
if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "安装器输出的恢复收据路径无效。" }
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
$SteadyAgentRoot = Join-Path $HOME ".steadyagent"
if ([string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { throw "请从新启动的 Codex 任务运行此审计。" }
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-index.ps1" -ThreadId $env:CODEX_THREAD_ID
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\diagnose-install.ps1" -ReceiptPath $ReceiptPath -RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity
```

`-RequireInstalledBytes` 会把全部 53 个安装文件绑定到成功迁移的收据；`-RequireRuntimeCatalog` 只验证与 `CODEX_THREAD_ID` 绑定、内部一致的 `rollout-file-confirmed` catalog；它不能证明当前宿主或 Live 已启用。因此严格诊断即使成功，也会输出 `WARN manual Codex Live acceptance is still required`。`-RequireGitIdentity` 核验 checkpoint 身份合同。必须重启 Codex Desktop、打开真实新任务，并观察 SessionStart 与一个受控 Hook 行为，才能完成 Live 验收。

## 6. 必要时回滚

使用安装后的 rollback 工具，以及安装器在首次目标写入前输出的收据。先预览，再在普通或管理员 PowerShell 中 Apply：

```powershell
$ReceiptPath = Read-Host "粘贴 install.ps1 在 'Recovery receipt:' 后输出的精确路径"
if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "安装器输出的恢复收据路径无效。" }
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath $ReceiptPath
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath $ReceiptPath -Apply
```

rollback 可以在普通或管理员 PowerShell 中运行。若安装过程很早就被强制中止，安装后副本可能尚不存在；请使用同一个已验证解压包中的 `tools\rollback.ps1`。精确原态/安装后态组成的混合状态可以恢复；第三种目标状态、快照漂移、收据漂移或未知 Git Hook 状态会在写入前停止。

rollback 会在首次受控写入前发布 `rollback-journal.json`。若退出码为 3 或
报告 `rollback_incomplete`，保留全部收据、备份、journal、目标和 Git
证据并进行人工哈希对账；不得编辑证据或盲目重试。

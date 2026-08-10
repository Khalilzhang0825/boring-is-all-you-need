# Boring Is All You Need

<p align="center">
  <img src="assets/boring-is-all-you-need-logo.png" width="180" alt="Boring Is All You Need Logo">
</p>

**让 Agent 的工作变得无聊：用证据交付，而不是凭感觉相信 AI。**

Boring Is All You Need `v3.0.1` 是面向 Windows 的本地优先 Codex Desktop Harness。它用一个小而可恢复的闭环替换现有 Codex 工作流：理解、计划、测试、修改、验证、只审查真实风险，最后对显式文件创建 checkpoint。

这里的“无聊”就是功能：Agent 不应临场发明权限、静默扩大范围、凭一句“测试通过”宣布完成，或把工作流留在半迁移状态。本项目把这些决定固化成确定性脚本、收据、哈希、回滚路径与发行门禁。

[English README](README.md)

## 为什么它比 V1 更好

| 维度 | legacy SteadyAgent v1 | Boring Is All You Need v3 |
| --- | --- | --- |
| 支持宿主 | 同时包含 Codex 与 Claude 能力面 | 只支持 Codex Desktop，合同单一且可审计 |
| 常驻 runtime | 更多按事件拆分的 Hook | 精确 3 个 block：`SessionStart`、统一 `PreToolUse`、`PreCompact` |
| 安装方式 | 生成工作流文件 | 默认 dry-run；冲突检查、快照、收据、原子 Apply 与 rollback 组成同一事务 |
| Git checkpoint | 范围化提交工具 | 隔离 index/对象区、暂存对象复核、锁、ref/index CAS 与崩溃恢复 |
| 审查策略 | 可能因改动规模触发 | 只因明确审查请求或实质风险触发，不按文件数量判断 |
| 验证闭环 | 宿主配置形态与 smoke | 52 项源信任清单、23 项等价图、负向变异、clean clone 与无 Git archive 门 |
| 发行证据 | 本地发布检查 | 精确 tag Windows workflow、SHA-256 sidecar、机器可读 provenance、attestation 与 draft-only 发布 |

## 安装后能带来什么实质变化

它不是一段更长的提示词，也不是只要求 Codex“认真一点”。它是在 Codex 原有工作外侧增加一层小而确定的执行与证据闭环。

| 优势 | 为什么有实际价值 |
| --- | --- |
| **足够轻量** | 日常热路径只有 3 个 Hook block；一次匹配事件只启动一个统一 guard 进程；SessionStart 有 800 字符硬上限；重型等价与发行测试不会在普通对话中运行。 |
| **由用户授权，不被二次否决** | 安装和回滚先预览再写入；支持普通与管理员 token；递归检查嵌套 command/file 输入并尽力审计，但 Hook 不返回 deny；破坏性或外部操作仍须在工作合同中明确授权。 |
| **不打扰已有工作** | 保护无关与 untracked 文件；不会把用户已经 staged 的内容混进 checkpoint；只提交显式路径；已有可执行仓库级 pre-commit Hook 会被链接执行，而不是静默覆盖。 |
| **可恢复** | 迁移快照、durable receipt、原子替换、rollback journal 和前后态哈希，让半安装或强制中止变成可分类、可续跑、可对账的问题，而不是凭记忆猜怎么恢复。 |
| **证据闭环** | “已实现”“测试通过”“已 push”“重启后 Live”是不同状态。Harness 要求先有复现或 red check，再给最小 green check，并用 Git/runtime 证据支撑对应结论。 |
| **长任务不断片** | 压缩前把目标、决策、剩余工作和禁止项写入项目状态；压缩后重新读取事实源，不把模糊 summary 当作完成事实。 |

实际收益是更少的返工、更少的误删误提交，以及更少“看起来完成、其实没有证据”的回复。下列内容展示的是行为合同，不承诺每个模型都逐字输出相同文案。

### 例 1：“修复这个 bug，然后提交”

**没有 Harness 时，常见输出：**

```text
问题已经修复并提交，测试全部通过。
```

这句话没有说明是否真正复现、跑了哪些测试、是否混入用户原有 staged 文件，也没有给出可核对的 commit。

**安装 Boring Is All You Need 后，目标输出：**

```text
原因：空输入进入 parseConfig() 时没有补默认值。
改动：仅 src/config.ts 与 tests/config.test.ts。
验证：聚焦回归 12/12；typecheck 通过。
Git：已创建 checkpoint 8f31c2a；用户原有 notes.md 仍保持 untracked。
剩余风险：当前 Linux 主机未运行 Windows 集成套件。
```

区别不在于话更多，而在于范围、证据、剩余风险和 Git 状态都明确且可以独立核对。

### 例 2：“整理一下，然后推上去”

| 时刻 | 没有 Harness | 有 Boring Is All You Need |
| --- | --- | --- |
| 修改前 | 可能直接开始重写 | 先检查仓库规则、分支、dirty state、`.gitignore` 与失败证据 |
| 修改中 | 容易顺手扩大到相邻重构 | 只保留关闭当前目标所需的最小改动，保护无关工作 |
| 提交前 | 可能直接 blanket staging | 复查 diff，通过隔离 index 只 checkpoint 显式文件 |
| push 前 | 可能把“继续”理解为授权 | 只有用户明确要求 push、同步或发布时才执行 |
| 最终报告 | 一句“完成” | 分开说明已修改、本地验证、已提交、已推送、已发布、重启后 Live |

### 例 3：危险命令藏在 parallel 嵌套调用里

普通的浅层检查可能漏掉 batch payload 深处的风险叶子。统一 `PreToolUse` Hook 会递归遍历 command 与 file 两类叶子，包括嵌套 parallel 调用。标准 managed 安装使用 Audit 模式：识别到的风险会尽力记录，但即使相关 payload malformed 或未知，也不会返回 deny。审计日志不保存可能敏感的原始命令，只记录固定原因、规范化工具名与输入 SHA-256。

删除授权与运行时路径校验仍由 agent 与用户决定，Hook 不再假装能从命令文本推断聊天授权。因此，在标准 managed runtime 中，已授权的递归删除、普通目录改名、常规 `git push` 和文件编辑不会再被第二层 Hook 策略拒绝。

需要确定性命令拦截的维护者仍可显式选择 `-EnforcementMode Enforce`。该可选模式下，规范 PowerShell `Remove-Item` 可对唯一且已验证的 `-LiteralPath` 递归删除；严格字面量与同一命令内单次赋值变量形式可以通过，歧义或受保护目标仍 fail closed。

## 本地验证快照

v3.0.1 发行候选于 2026-08-10 在 PowerShell 7.6.4 的干净已提交工作树上验证。聚合入口为 `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1`；精确 tag workflow 还会在创建 draft release 前再次运行同一门禁，并验证解压后的 `git archive`。

| 门禁 | 结果 |
| --- | ---: |
| 完整 release readiness | `153/0` |
| 安装后本机 postimage 等价性 | `430/0` |
| 事务式迁移与回滚 | `344/0` |
| 可崩溃恢复的 Git checkpoint | `333/0` |
| Managed Hook 行为 | `294/0` |
| Runtime skill catalog | `69/0` |
| Release workflow 状态机 | `43/0` |
| 精确无 Git release archive | `33/0` |

日常 runtime 仍刻意保持轻量：每个匹配事件只启动一个统一 `PreToolUse` PowerShell 进程；SessionStart 实际约 610 字符，并有 800 字符硬上限。v3.0.1 候选通过 `tools\test-agent-hooks.ps1` 在维护者机器上取得 5 次端到端冷启动中位数 1,425.6 ms、最大值 1,726.7 ms，包含 PowerShell 7 进程启动；这不是跨机器延迟承诺。重型等价和 archive 套件只在维护者/CI 发行门中运行，不会塞进普通对话热路径。

这些是本地干净提交态的发行候选结果，不代表 GitHub Actions、attestation 或用户重启后的 Codex runtime 已经 Live。发行 workflow 与下方安装后诊断分别验证这些层级。

GitHub-hosted Windows runner 使用管理员 token。安装、rollback 与 CI fixture 现在都允许在提权 token 下运行；测试路径覆盖仍必须同时满足 `STEADYAGENT_TEST_MODE=1` 与严格隔离的系统临时目录测试根。

## 3.0.1 的核心变化

- 唯一支持宿主为 Codex Desktop。
- 常驻 runtime 精简为 3 个 managed hook block：一个 `SessionStart`、一个仅审计的统一 `PreToolUse`、一个 `PreCompact`。
- 不安装 `UserPromptSubmit`、`PermissionRequest` 或 `PostToolUse`。
- 文件数量本身不再触发独立审查。
- 统一的 Command/File Hook 会在一个 PowerShell 进程内同时递归检查嵌套 parallel 中的两类叶子；标准 managed Audit 模式永远不返回 deny。
- Guard 日志只记录固定原因、规范化工具名和输入 SHA-256。
- Git checkpoint 使用隔离 index 与对象隔离区、显式文件、暂存对象与范围复核，以及单写者锁。
- checkpoint CLI 保留维护者工作流中由人明确批准的 `-All` 初始 checkpoint 能力；标准 managed 审计 Hook 不授予该权限，agent 仍须遵循工作合同中的显式范围。
- 全新安装及 V1→V2 迁移均采用事务：预览、冲突检查、备份、原子应用、验证、收据和失败回滚。
- 已加载的 installer 会锚定规范化的 52 项源资产 `package-assets.sha256`，并且只安装一次性读取且哈希匹配的字节。
- Apply 与 rollback 同时支持普通和提权 token；脚本不会主动请求 UAC、修改 ACL 或接管 owner，只使用启动它们时已有的 token。
- 版本化 V1 资产清单会在明确授权替换时移除旧 Codex 发行面，并可通过同一收据完整恢复。
- 冻结的 23 项等价清单把维护者已审查的本机 Codex-active 能力逐一映射到可移植公开源与安装目标。本机 Hook smoke 项另行冻结了 63 条保留断言和 10 条明确排除的 Claude、已移除事件或已移除 Caveman 行为断言；这是范围明确的等价，不表示 V3 会重新发布被排除的 V1 能力面。
- 包内包含线程绑定的 skill 索引与检索，但不会发布维护者的 runtime catalog、线程 ID 或私人路径。
- SessionStart 只输出可移植 lessons 标题、真正到期的 90 天 Harness 维护提醒，以及 resume/compact 状态；不注入 Caveman 行为。fresh install 以已安装 context Hook 的 mtime 作为首次复查基线，不会立即告警。

## 为什么只发布 Codex

V3 只支持 Codex Desktop。单一宿主意味着只有一份可以完整测试的 runtime 合同；其他 agent 宿主及其 runtime、模板、settings 与 Hook 能力不属于 V3 的支持和安装合同。

另外，据维护者说明，其 Anthropic 账号被封。这个供应商锁定案例进一步强化了收缩范围的决定；一份支持矩阵的学费已经够了。

V1 与 V2 历史版本仍保留在 Git 历史中。V3 归档只保留证明替换与范围等价所必需的 V1 迁移 tombstone 和明确排除的断言证据；不会安装或支持 Claude runtime、模板、settings 或 Hooks。

## 为什么部分技术标识仍是 `steadyagent`

公开产品与仓库名称已经统一为 Boring Is All You Need。安装根目录 `$HOME\.steadyagent`、`STEADYAGENT_*` 测试变量、receipt schema、mutex 名称以及 `steadyagent-workflow` skill ID 继续作为稳定兼容协议保留。这样才能识别、替换、审计并回滚现有 V1 安装，不会在旁边再创建第二套工作流。它们不代表第二个产品或第二套 runtime。

## 运行前验证发行包

v3.0.1 正式发布后，受支持的发行输入将是该 GitHub Release 附带的 `boring-is-all-you-need-v3.0.1.zip`。三个最小权限 GitHub Actions job 会从精确的 `v3.0.1` tag 构建并做无 Git 验证、为已审查 archive digest 生成 attestation，再创建 draft release。重跑只接受显示 reviewed commit 的正文和三个 asset 文件均字节一致、且不是 prerelease 的 draft；创建后 ref 竞态只按本次 run 捕获的 release ID 清理。

同时下载 archive、checksum 与机器可读 provenance 三个资产，解压或运行 `install.ps1` 前直接运行以下可复制验证：

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
Expand-Archive .\boring-is-all-you-need-v3.0.1.zip .\boring-is-all-you-need-v3.0.1-release
Set-Location .\boring-is-all-you-need-v3.0.1-release\boring-is-all-you-need-v3.0.1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-archive.ps1 -IntegrityOnly
```

`-IntegrityOnly` 是普通用户使用的快速完整性门：检查精确 release inventory、package manifest 与哈希、PowerShell 7.5+ 解析和严格 UTF-8 编码、Hook 文件格式、本地文档链接以及 Codex-only 归档边界。CI 和维护者会不带该开关运行默认命令，执行包括行为、runtime、等价性与空白检查重套件在内的完整发布门。

这要求安装当前 [GitHub CLI](https://cli.github.com/)、能够访问 GitHub API，并且 `gh` 已提供 `attestation verify`。签名 attestation 与独立下载的 provenance asset 会把压缩包绑定到 GitHub 仓库、精确 signer workflow、tag ref、reviewed commit 与 SHA-256；release body 会显示同一 commit。它们不代表代码绝对没有漏洞。若无法完成验证或验证失败，应把下载物视为不可信并停止运行。

## 安全的一键迁移

> **安装环境：** 下列命令同时支持普通 PowerShell 和管理员 PowerShell，也支持配置了 `[windows] sandbox = "elevated"` 的 Codex 任务。脚本不会主动请求 UAC、修改 ACL 或接管 owner；当前 token 必须已经能够更新全部目标。

安装器默认只做 dry-run：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1
```

它会列出所有目标、现有冲突、managed Hook 替换和 Git Hook 变化，且不会写入目标、配置、备份、收据或状态。Dry-run 会在系统临时目录中完成短暂 staging，并在正常退出时删除；进程被中断时最多只会留下该 staging 目录。

确认计划后，全新安装：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply
```

已验证的 v2.0.2 安装可原地升级：先检查默认 dry-run，再显式授权替换：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply -ReplaceExistingWorkflow
```

不支持从 v2.0.0 或 v2.0.1 直接执行 receipt-bound 原地升级。请使用对应已安装版本的 `rollback.ps1` 和 active receipt 完成回滚并核验恢复，再全新安装 v3.0.1；保留原 receipt 与备份证据。

替换 legacy SteadyAgent v1 或已有自定义 Codex 工作流：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply -ReplaceExistingWorkflow
```

可以在普通或管理员 PowerShell 中运行。Boring Is All You Need 不再拒绝提权 Apply 与 rollback，但仍不会主动触发 UAC、修改 ACL 或接管 owner；当前 token 必须已经能够更新 `%ProgramData%\OpenAI\Codex\requirements.toml` 与其他计划目标。`managed` 表示 Codex 的配置机制，不表示能抵抗同用户恶意软件。

安装器会：

1. 验证规范 package manifest，一次性读取每项可信源字节，再按当前机器渲染可移植包；
2. 写入前验证全部源与目标；
3. 未明确授权替换时阻断未知差异；
4. durable 保存每个现有目标及原 Git Hook 路径，并在首次目标或 Git 写入前写入、输出 `applying` 恢复收据；
5. 备份并移除旧 Codex 位置中已知的 V1-owned 文件；
6. 在全机器唯一的 Boring Is All You Need 迁移互斥锁下原子应用；
7. 逐项并全量验证最终结果；
8. 任一步失败时恢复全部已变更目标；
9. durable 将机器可读的 `migration-receipt.json` 推进到 `applied`。

安装器不会修改模型或推理强度。

安装后的全局 `core.hooksPath` 会先运行 Boring Is All You Need staged-file guard，再链接执行仓库自身的可执行 `.git/hooks/pre-commit`。若原先存在不同的全局 `core.hooksPath`，它仍是必须审阅的替换冲突：只有检查 dry-run 后才使用 `-ReplaceExistingWorkflow`，并通过收据恢复原值。

使用安装后的 rollback 工具与安装时输出的收据：

```powershell
$SteadyAgentRoot = Join-Path $HOME ".steadyagent"
$ReceiptPath = Read-Host "粘贴 install.ps1 在 'Recovery receipt:' 后输出的精确路径"
if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "安装器输出的恢复收据路径无效。" }
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\rollback.ps1" -ReceiptPath $ReceiptPath
# 审阅预览后，在普通或管理员 PowerShell 中运行：
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\rollback.ps1" -ReceiptPath $ReceiptPath -Apply
```

rollback 可以在普通或管理员 PowerShell 中运行。若进程在安装后的 rollback 副本出现前被强制中止，请改用同一个已验证解压发行包中的 `tools\rollback.ps1`；`applying` 收据会绑定该脚本应安装字节的精确哈希。回滚器在写入前把每个目标和 active Git Hook 路径分类为精确原态或精确安装后态；任何第三种状态、收据漂移或快照漂移都会以零写入停止，合法混合状态会事务式恢复 managed 文件的字节内容与存在性，以及记录的 `core.hooksPath` 值和 fixture Git-config 字节。迁移不会捕获或恢复 ACL、owner、文件属性、时间戳或 alternate data streams。

rollback 会在首次文件或 Git 变更前发布 durable
`rollback-journal.json`，因此强制中止后仍能确定性续跑或补偿。若退出码为 3
或收据进入 `rollback_incomplete`，必须保留收据、备份、journal、当前目标和
Git 配置；不得编辑或盲目重试，必须按记录哈希人工对账。测试迁移根必须位于
系统临时目录下，basename 严格为
`steadyagent-v2-migration-<32 位小写十六进制>`。

## 安装后

重启 Codex Desktop，打开一个新的 Codex 任务，并让 Codex 在该任务的终端中运行下面的代码块。不要把它粘贴到无关的普通 PowerShell 会话：skill index 必须绑定新任务的 `CODEX_THREAD_ID`。代码块会先验证该身份，再强制核验 Hooks、runtime catalog 和 Git identity：

```powershell
$SteadyAgentRoot = Join-Path $HOME ".steadyagent"
$ReceiptPath = Read-Host "粘贴 install.ps1 在 'Recovery receipt:' 后输出的精确路径"
if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "安装器输出的恢复收据路径无效。" }
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
if ([string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { throw "请从新启动的 Codex 任务运行此审计。" }
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-index.ps1" -ThreadId $env:CODEX_THREAD_ID
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\diagnose-install.ps1" -ReceiptPath $ReceiptPath -RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity
```

catalog 工具会从自身所在的 `tools` 目录推导安装根目录，并默认写入
`Join-Path $SteadyAgentRoot "runtime-skill-catalogs"`。

预期结果：

```text
WARN manual Codex Live acceptance is still required
RESULT pass=<n> warn=1 fail=0
```

诊断会检查安装资产、空用户 hooks、包含一个统一 `PreToolUse` 的精确 3-block managed 矩阵、所有已知 V1-owned Codex 文件均已移除、渲染路径、active Git Hook 路径以及安装后的 Hook smoke。`-RequireRuntimeCatalog` 只验证与 `CODEX_THREAD_ID` 绑定、内部一致的 `rollout-file-confirmed` catalog；它不能证明当前宿主或 Live 已启用。必须重启 Codex Desktop、打开真实新任务，并观察 SessionStart 与一个受控 Hook 行为，才能完成 Live 验收。

## 日常闭环

```text
understand -> plan -> red check -> smallest change -> green check -> review when risk requires it -> checkpoint
```

Boring Is All You Need 要求 Codex：

- 修改前检查仓库；
- 修复前先诊断；
- 保护用户已有和无关改动；
- 运行最小相关验证；
- 只有明确审查请求或实质风险才调用 fresh reviewer；
- checkpoint 只包含显式文件；
- 未授权时不 push、发布、部署、迁移、安装或执行破坏性操作；
- 压缩前固化状态，恢复后重新读取。

## 主要命令

| 命令 | 作用 |
| --- | --- |
| `tools/install.ps1` | Dry-run 或事务式迁移 Codex 工作流。 |
| `tools/rollback.ps1` | Dry-run 或按收据事务式恢复已完成迁移。 |
| `tools/diagnose-install.ps1` | 验证安装资产和 active managed hooks。 |
| `tools/test-v2-migration.ps1` | 验证全新安装、替换、冲突和回滚。 |
| `tools/test-agent-hooks.ps1` | 验证 SessionStart、Guard、日志和 PreCompact。 |
| `tools/test-git-checkpoint.ps1` | 验证显式文件及人工明确批准的全范围 checkpoint 事务。 |
| `tools/test-pre-commit.ps1` | 验证 staged 密钥和大文件防线。 |
| `tools/skill-index.ps1` | 生成绑定宿主、线程、prompt 和 digest 的 runtime skill catalog。 |
| `tools/skill-search.ps1` | 只检索与当前任务身份绑定的 `rollout-file-confirmed` catalog；这不能证明当前宿主或 Live 已启用。 |
| `tools/test-local-equivalence.ps1` | 验证本机到公开包 23/23 映射，并证明故意篡改会变红。 |
| `tools/validate-release-readiness.ps1` | 运行完整 V3 发布门。 |
| `tools/validate-release-archive.ps1` | 在不依赖 `.git` 的情况下验证精确解压后的 release asset；用户使用 `-IntegrityOnly`，CI 和维护者运行默认完整门。 |

## Runtime 架构

| 层级 | 职责 |
| --- | --- |
| `templates/codex/AGENTS.md` | Codex 常驻短合同。 |
| `rules/` | 渐进式 workflow、verification、review、skill、context 和 safety 规则。 |
| `tools/hooks/` | 标准 managed 仅审计、可选强制的命令/文件检查，以及状态注入和 PreCompact 提醒。 |
| `tools/git-checkpoint.ps1` | 限定范围、可恢复的本地提交。 |
| `tools/git-hooks/` | 全局 pre-commit 防线。 |
| `tools/skill-*.ps1` | 可移植的 runtime skill catalog 发布和检索。 |
| `manifests/local-postimage-equivalence.json` | 冻结的 23 项本机到公开包能力合同。 |
| `skills/steadyagent-workflow/` | 用户显式调用的通用工作流 skill。 |
| `tools/install.ps1` | 可移植渲染与事务迁移引擎。 |
| `tools/rollback.ps1` | 收据绑定、漂移感知的事务恢复工具。 |

Hooks 用于减少常见误操作，不是完整安全沙箱；人工授权和项目级验证仍然必要。

## 发布验证

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

发布门覆盖 PowerShell 7.5+ 语法和运行时身份、公开路径和密钥、Codex-only 资产、文档链接、迁移 fixture、Hook、checkpoint/pre-commit、runtime skill catalog、带红→绿证明的 23/23 等价合同、全新安装、安装后诊断以及发布元数据。

## 兼容性

- Windows 10/11
- PowerShell 7.5 或更高版本（`pwsh.exe`）
- Codex Desktop managed hooks
- Git for Windows

Windows PowerShell 5.1、Linux、macOS、其他 coding agent 和 Anthropic 产品不属于 V3 支持合同。

## License

MIT。见 [LICENSE](LICENSE)。

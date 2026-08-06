# Boring Is All You Need 工具

所有命令面向 Windows PowerShell 5.1。

```powershell
.\tools\install.ps1
.\tools\install.ps1 -Apply
.\tools\install.ps1 -Apply -ReplaceExistingWorkflow
# 先粘贴成功 Apply 时 installer 精确输出的 $SteadyAgentRoot 与 $ReceiptPath 赋值。
if (-not (Test-Path variable:SteadyAgentRoot) -or -not (Test-Path variable:ReceiptPath)) { throw "请先粘贴 installer 输出的精确审计赋值。" }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\rollback.ps1" -ReceiptPath $ReceiptPath
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\rollback.ps1" -ReceiptPath $ReceiptPath -Apply
if ([string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { throw "请从新启动的 Codex 任务运行此审计。" }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-index.ps1" -ThreadId $env:CODEX_THREAD_ID
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\diagnose-install.ps1" -ReceiptPath $ReceiptPath -RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity
.\tools\test-v2-migration.ps1
.\tools\test-agent-hooks.ps1
.\tools\test-git-checkpoint.ps1
.\tools\test-pre-commit.ps1
.\tools\skill-index.ps1
.\tools\skill-search.ps1 -Query "代码审查"
.\tools\test-skill-catalog.ps1
.\tools\test-protected-path-policy.ps1
.\tools\test-local-equivalence.ps1
.\tools\validate-release-readiness.ps1
.\tools\validate-release-archive.ps1
```

`install.ps1` 默认 dry-run。Apply 同时支持普通和提权会话；当前 token 无法更新任一目标时 fail closed，不请求 UAC，也不修改 ACL 或接管 owner。已加载的 installer 会在 staging 前验证规范化的 52 项源资产 `package-assets.sha256` 摘要。自定义根路径只用于隔离测试：必须同时设置 `STEADYAGENT_TEST_MODE=1`，并把 `STEADYAGENT_TEST_ROOT` 指向系统临时目录下现有、basename 严格为 `steadyagent-v2-migration-<32 位小写十六进制>` 的隔离根。发行包源目录、目标、Codex、managed 配置、备份、显式 Git 配置及实际调用工具路径均须位于该测试根中，并在适用处保持两两分离。

成功 Apply 会先输出 `Backup and rollback receipt:`，再输出精确的 `$SteadyAgentRoot`、`$ReceiptPath` 赋值。应保存并原样粘贴这些赋值，不得自行拼接备份路径。如果事务已经进入 `applied`，但成功输出丢失，可从同一个已验证解压发行包重新运行不带 `-Apply` 的 `tools\install.ps1`；already-installed 路径会解析唯一且完整性有效的 active receipt pointer，以零写入重新输出这些赋值。中断的 `applying` 事务不存在 active applied pointer，必须使用此前已输出的恢复收据。

`rollback.ps1` 默认 dry-run，同时支持普通和提权运行。它既能恢复 `applied` 收据，也能恢复 durable `applying` 收据记录的精确混合状态。这里的精确指 managed 文件字节内容/存在性与记录的 Git 值/config 字节；ACL、owner、属性、时间戳和 alternate data streams 不会被捕获或恢复。若强制中止过早、安装后副本尚不存在，只有同一已验证发行包中且脚本哈希等于收据预期 rollback 字节的脚本才会被接受。收据哈希证明完整性，不证明身份；生产回滚目标绑定到 active 安装合同。

rollback 在首次受控写入前把进入态 durable 记录到
`rollback-journal.json`。退出码 3 或 `rollback_incomplete` 表示必须人工
对账；保留收据、备份、journal、目标和 Git 证据，不得盲目重试。

`git-checkpoint.ps1` 要求真实 index 为空，并选择仓库相对显式 `-Files` 或由人主动执行的 `-All`。两种模式都先写入隔离 index 与对象隔离区，经过受保护路径、暂存 blob 大小和 pre-commit 门，再次复核精确范围与暂存对象；全部通过后才发布必要对象、commit，并以 compare-and-swap 完成 index。发布前被阻止的事务会删除隔离区，不把候选对象写入仓库对象库。Codex command guard 会阻止 agent 调用批量 `-All`；该能力只保留给工具路径外由人批准的初始 checkpoint。

checkpoint fault injection 必须同时具备 `STEADYAGENT_TEST_MODE=1` 和系统
临时目录下现有、basename 为
`steadyagent-git-checkpoint-<32 位小写十六进制>` 的
`STEADYAGENT_TEST_ROOT`。仓库、common/worktree Git 目录、object store、
index 与 injection payload 路径都会在事务恢复前被限制到该根内。

重启 Codex Desktop 后，打开新任务，并用该任务的 `CODEX_THREAD_ID` 运行 `skill-index.ps1`。随后由 `diagnose-install.ps1` 检查安装包、已配置的 Codex 矩阵及内部一致的 rollout-file catalog：`-ReceiptPath` 绑定成功迁移收据，`-RequireInstalledBytes` 核验全部 53 项安装哈希，`-RequireHooksActive` 强制要求 managed 矩阵，`-RequireRuntimeCatalog` 检查 `rollout-file-confirmed` 证据，`-RequireGitIdentity` 核验 checkpoint 身份。严格 catalog 门要求 owning task 的 `session_meta` 时间戳严格晚于收据 `completed_utc`；缺失、无效、旧任务或只有继承时间证据都会 fail closed。严格命令会有意警告：仍需在真实新任务中人工观察 Hook，才能完成 Live 验收。

`skill-index.ps1` 只在首次生成时发现并完整解析 owning rollout，读取其中明示的 skill，并发布 `rollout-file-confirmed` 不可变快照。快照固化 rollout 规范路径、Windows 文件身份、有限证据前缀摘要、owning `session_meta` 摘要、skills block 摘要，以及宿主、线程、prompt 与 skill digest。此后 `skill-search.ps1` 直接打开已绑定路径，核验文件身份和冻结前缀，只解析新增内容中可能改变 session 或 skills 证据的行；正常检索不再递归发现 sessions 树，也不再重复解析持续增长的完整 JSONL。rollout 被替换、截断、冻结前缀漂移、追加不同 skills block 或追加 session 身份证据时均 fail closed；无关增长及重复的相同 skills block 仍可通过。search 会为每个匹配项输出可复制的绝对 `SKILL.md` 路径；只要任一匹配路径不是现存绝对 `SKILL.md` 文件，就不会输出部分结果。生产或 fixture catalog 都不能作为当前宿主或 Live 证据。

`test-skill-catalog.ps1` 默认只使用隔离的合成 `CODEX_HOME`，保证结果可重复。设置 `STEADYAGENT_RUN_ROLLOUT_FILE_CANARY=1` 后才追加当前 Codex rollout 文件检查；该可选 canary 要求存在 `CODEX_THREAD_ID`，仍只属于文件证据而非 Live 验收，也不属于仓库门或 GitHub Actions 发行门。

`test-local-equivalence.ps1` 验证全部 23 项映射，执行每个绑定的语义测试，在隔离目录执行真实安装，并将收据与权威的 23 项映射及 30 项支持目标闭包（53 项安装记录）和 27 项移除记录（收据总计 80 项）做集合对比。它会先证明 source hash、语义门和支持目标替换三种篡改都会使门禁变红。

`validate-release-readiness.ps1` 是依赖 Git 的干净 tag-checkout 发布门。`validate-release-archive.ps1` 只能从精确解压后的 release 根目录运行，不依赖 `.git`，且不会安装进 `TargetRoot`；它会验证 52 项 package closure、PowerShell/编码与本地链接合同，再运行可移植行为套件。

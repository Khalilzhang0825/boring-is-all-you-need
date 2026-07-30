# SteadyAgent 2 工具

所有命令面向 Windows PowerShell 5.1。

```powershell
.\tools\install.ps1
.\tools\install.ps1 -Apply
.\tools\install.ps1 -Apply -ReplaceExistingWorkflow
.\tools\rollback.ps1 -ReceiptPath "<备份目录>\migration-receipt.json"
.\tools\rollback.ps1 -ReceiptPath "<备份目录>\migration-receipt.json" -Apply
.\tools\diagnose-install.ps1 -RequireHooksActive
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
```

`install.ps1` 默认 dry-run。自定义根路径用于测试和受控部署；发行包源目录、目标、Codex、managed 配置、备份及显式 Git 配置路径必须两两分离（不得相等或互为祖先/后代）。全部 injection 参数只有在 `STEADYAGENT_TEST_MODE=1` 时可用，且仅服务于隔离回归 fixture。

`rollback.ps1` 默认 dry-run，只接受已应用且已安装文件、快照、Git Hook 路径仍匹配的 V2 收据。只使用你自己的安装生成的收据。

`git-checkpoint.ps1` 要求真实 index 为空并传入仓库相对显式文件。它在隔离 index 中暂存、运行 pre-commit、复核精确范围，并通过 compare-and-swap 发布提交。

`diagnose-install.ps1` 检查安装包和精确 active Codex 矩阵。`-RequireHooksActive` 会把缺失 managed 配置升级为失败。

`skill-index.ps1` 从当前 Codex rollout 读取 runtime 明示的 skill，并发布绑定宿主、线程、prompt 与 digest 的不可变快照。`skill-search.ps1` 检索前会核验该身份；自定义 catalog 必须显式进入 fixture 模式，且不能作为 Live 证据。

`test-skill-catalog.ps1` 默认只使用隔离的合成 `CODEX_HOME`，保证结果可重复。设置 `STEADYAGENT_RUN_LIVE_CATALOG_CANARY=1` 后才追加当前 Codex rollout 检查；该可选 canary 要求存在 `CODEX_THREAD_ID`，不属于仓库门或 GitHub Actions 发行门。

`test-local-equivalence.ps1` 验证全部 23 项映射，执行每个绑定的语义测试，在隔离目录执行真实安装，将收据与 23 项映射及 29 项支持目标的精确 allowlist 做集合对比，并先证明 source hash、语义门和支持目标替换三种篡改都会使门禁变红。

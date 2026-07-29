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
.\tools\validate-release-readiness.ps1
```

`install.ps1` 默认 dry-run。自定义根路径用于测试和受控部署；全部 injection 参数只有在 `STEADYAGENT_TEST_MODE=1` 时可用，且仅服务于隔离回归 fixture。

`rollback.ps1` 默认 dry-run，只接受已应用且已安装文件、快照、Git Hook 路径仍匹配的 V2 收据。只使用你自己的安装生成的收据。

`git-checkpoint.ps1` 要求真实 index 为空并传入仓库相对显式文件。它在隔离 index 中暂存、运行 pre-commit、复核精确范围，并通过 compare-and-swap 发布提交。

`diagnose-install.ps1` 检查安装包和精确 active Codex 矩阵。`-RequireHooksActive` 会把缺失 managed 配置升级为失败。

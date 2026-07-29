# Codex 启用与迁移

V2 的 `install.ps1` 同时负责资产安装和 Codex managed Hook 启用。

## Dry-run

不带 `-Apply` 运行，检查全部目标和冲突。此时不会修改文件、Git 设置或 managed 配置。

## 授权事务

`-Apply` 授权全新安装；`-Apply -ReplaceExistingWorkflow` 额外授权替换已有差异和 `core.hooksPath`。

事务会渲染 staging、验证路径、保存原文件、原子写入、逐项及全量验证、启用 pre-commit，并生成回滚收据。任何失败都会恢复已写文件和原 Git Hook 路径。

使用 `-ReplaceExistingWorkflow` 时，还会把版本化的 `manifests/v1-codex-owned-files.txt` 作为事务 tombstone 清单：只备份并移除 `CodexHome` 下精确匹配的 SteadyAgent V1-owned 路径，不扫描或删除未知文件。

## 已完成迁移的回滚

使用已安装的 `rollback.ps1` 和本次生成的收据。回滚器同样默认 dry-run；审阅完整恢复/删除计划后再加 `-Apply`。只要收据、快照、已安装文件或 `core.hooksPath` 发生漂移，回滚就会 fail closed。不要运行不可信来源的收据。

## Managed 配置

默认 active 目标为 `%ProgramData%\OpenAI\Codex\requirements.toml`，通常需要管理员权限。测试可以传入 `-ManagedConfigPath`、`-TargetRoot`、`-CodexHome`、`-BackupRoot` 和 `-GitConfigPath` 保持隔离。

## Live 验收

重启 Codex Desktop，运行 `diagnose-install.ps1 -RequireHooksActive`，再在一次性仓库确认：

- 安全命令正常；
- 危险 Git fixture 在执行前被拒绝；
- `.env` 编辑 fixture 被拒绝；
- compact/resume 恢复状态标记；
- 低风险多文件任务不会仅因文件数量触发审查；
- 明确请求审查会调用 fresh reviewer。

不要在真实仓库执行破坏性探针。

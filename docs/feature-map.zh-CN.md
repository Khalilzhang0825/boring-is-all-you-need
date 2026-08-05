# Boring Is All You Need 功能地图

| 功能 | 实现 | 安装位置 | 验证 |
| --- | --- | --- | --- |
| Codex 合同 | `templates/codex/AGENTS.md` | `$HOME\.codex\AGENTS.md` | 检查渲染文件。 |
| 渐进规则 | `rules/` | `$HOME\.steadyagent\rules\` | 安装后诊断。 |
| Workflow skill | `skills/steadyagent-workflow/` | `$HOME\.codex\skills\steadyagent-workflow\` | 安装后诊断。 |
| 3-block managed runtime | Codex requirements 模板 | `%ProgramData%\OpenAI\Codex\requirements.toml` | 精确矩阵诊断。 |
| 统一 Command/File Guard | `tools/hooks/` | `$HOME\.steadyagent\tools\hooks\` | 单进程 ledger 与 `test-agent-hooks.ps1`。 |
| 状态恢复 | context/precompact Hooks | Hook runtime | compact/resume fixture 与 Live probe。 |
| 敏感路径策略 | `tools/protected-path-policy.ps1` | `$HOME\.steadyagent\tools\` | Guard、checkpoint、pre-commit 测试。 |
| 显式 checkpoint | `tools/git-checkpoint.ps1` | `$HOME\.steadyagent\tools\` | `test-git-checkpoint.ps1`。 |
| Pre-commit 防线 | `tools/git-hooks/` | `$HOME\.steadyagent\tools\git-hooks\` | `test-pre-commit.ps1`。 |
| Rollout-file skill catalog | `tools/skill-index.ps1`、`tools/skill-search.ps1` | `$HOME\.steadyagent\tools\` 及本机生成快照 | `test-skill-catalog.ps1`；证据仅为 `rollout-file-confirmed`，不是 Live。 |
| 23 项本机等价合同 | `manifests/local-postimage-equivalence.json` | `$HOME\.steadyagent\manifests\` | `test-local-equivalence.ps1` 红→绿门禁。 |
| 包源可信校验 | `package-assets.sha256` 与 installer 内嵌摘要 | staging 前的已加载 checkout | 52 项源闭包、源文件篡改及 manifest 篡改迁移测试。 |
| 事务迁移 | `tools/install.ps1` | checkout 中运行 | `test-v2-migration.ps1`。 |
| V1-owned tombstone | `manifests/v1-codex-owned-files.txt` | `$HOME\.steadyagent\manifests\` | 完整 V1 fixture 与安装后诊断。 |
| 收据回滚 | `tools/rollback.ps1` | `$HOME\.steadyagent\tools\`，或早期崩溃恢复时的同一已验证发行包 | durable `applying`/`applied` 收据、精确混合状态、快照、脚本身份、非提权 token 及零写入测试。 |
| 安装配置与 rollout-file 诊断 | `tools/skill-index.ps1`、`tools/diagnose-install.ps1` | 具有 `CODEX_THREAD_ID` 的新 Codex 任务 | 先运行 `skill-index.ps1 -ThreadId $env:CODEX_THREAD_ID`，再运行 `-RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity`；还需在该真实任务人工观察 Hook 行为，才能完成 Live 验收。 |
| 发布门 | `tools/validate-release-readiness.ps1` | 仓库 | 干净发布验证。 |
| 解压包发布门 | `tools/validate-release-archive.ps1` | Release ZIP | 无 Git 的包闭包与可移植行为验证。 |

安装和宿主启用属于同一个显式事务；Codex 在任务启动时注册 managed Hooks，因此仍需重启。

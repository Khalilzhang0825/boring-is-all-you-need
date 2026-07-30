# SteadyAgent 2 功能地图

| 功能 | 实现 | 安装位置 | 验证 |
| --- | --- | --- | --- |
| Codex 合同 | `templates/codex/AGENTS.md` | `$HOME\.codex\AGENTS.md` | 检查渲染文件。 |
| 渐进规则 | `rules/` | `$HOME\.steadyagent\rules\` | 安装后诊断。 |
| Workflow skill | `skills/steadyagent-workflow/` | `$HOME\.codex\skills\steadyagent-workflow\` | 安装后诊断。 |
| 4-block managed runtime | Codex requirements 模板 | `%ProgramData%\OpenAI\Codex\requirements.toml` | 精确矩阵诊断。 |
| Command/File Guard | `tools/hooks/` | `$HOME\.steadyagent\tools\hooks\` | `test-agent-hooks.ps1`。 |
| 状态恢复 | context/precompact Hooks | Hook runtime | compact/resume fixture 与 Live probe。 |
| 敏感路径策略 | `tools/protected-path-policy.ps1` | `$HOME\.steadyagent\tools\` | Guard、checkpoint、pre-commit 测试。 |
| 显式 checkpoint | `tools/git-checkpoint.ps1` | `$HOME\.steadyagent\tools\` | `test-git-checkpoint.ps1`。 |
| Pre-commit 防线 | `tools/git-hooks/` | `$HOME\.steadyagent\tools\git-hooks\` | `test-pre-commit.ps1`。 |
| Runtime skill catalog | `tools/skill-index.ps1`、`tools/skill-search.ps1` | `$HOME\.steadyagent\tools\` 及本机生成快照 | `test-skill-catalog.ps1`。 |
| 23 项本机等价合同 | `manifests/local-postimage-equivalence.json` | `$HOME\.steadyagent\manifests\` | `test-local-equivalence.ps1` 红→绿门禁。 |
| 事务迁移 | `tools/install.ps1` | checkout 中运行 | `test-v2-migration.ps1`。 |
| V1-owned tombstone | `manifests/v1-codex-owned-files.txt` | `$HOME\.steadyagent\manifests\` | 完整 V1 fixture 与安装后诊断。 |
| 收据回滚 | `tools/rollback.ps1` | `$HOME\.steadyagent\tools\` | `test-v2-migration.ps1`。 |
| Active 诊断 | `tools/diagnose-install.ps1` | `$HOME\.steadyagent\tools\` | `-RequireHooksActive`。 |
| 发布门 | `tools/validate-release-readiness.ps1` | 仓库 | 干净发布验证。 |

安装和宿主启用属于同一个显式事务；Codex 在任务启动时注册 managed Hooks，因此仍需重启。

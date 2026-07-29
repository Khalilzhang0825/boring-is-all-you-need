# SteadyAgent 2 Feature Map

| Feature | Implementation | Installed location | Verification |
| --- | --- | --- | --- |
| Codex contract | `templates/codex/AGENTS.md` | `$HOME\.codex\AGENTS.md` | Inspect rendered file. |
| Progressive rules | `rules/` | `$HOME\.steadyagent\rules\` | Installed diagnosis. |
| Workflow skill | `skills/steadyagent-workflow/` | `$HOME\.codex\skills\steadyagent-workflow\` | Installed diagnosis. |
| Four-block managed runtime | `templates/codex/requirements.managed-hooks.example.toml` | `%ProgramData%\OpenAI\Codex\requirements.toml` | Exact matrix diagnosis. |
| Command/file Guards | `tools/hooks/` | `$HOME\.steadyagent\tools\hooks\` | `test-agent-hooks.ps1`. |
| State recovery | `agent-hook-context.ps1`, `agent-hook-precompact.ps1` | Hook runtime | Compact/resume fixture and Live probe. |
| Sensitive path policy | `tools/protected-path-policy.ps1` | `$HOME\.steadyagent\tools\` | Guard, checkpoint, and pre-commit tests. |
| Explicit checkpoint | `tools/git-checkpoint.ps1` | `$HOME\.steadyagent\tools\` | `test-git-checkpoint.ps1`. |
| Pre-commit defense | `tools/git-hooks/` | `$HOME\.steadyagent\tools\git-hooks\` | `test-pre-commit.ps1`. |
| Transactional migration | `tools/install.ps1` | Runs from checkout | `test-v2-migration.ps1`. |
| V1-owned tombstones | `manifests/v1-codex-owned-files.txt` | `$HOME\.steadyagent\manifests\` | Full V1 fixture and installed diagnosis. |
| Receipt rollback | `tools/rollback.ps1` | `$HOME\.steadyagent\tools\` | `test-v2-migration.ps1`. |
| Active installation diagnosis | `tools/diagnose-install.ps1` | `$HOME\.steadyagent\tools\` | `-RequireHooksActive`. |
| Public release gate | `tools/validate-release-readiness.ps1` | Repository | Clean release validation. |

Installation and host activation are part of the same explicit transaction. A restart remains necessary because Codex registers managed Hooks at task startup.

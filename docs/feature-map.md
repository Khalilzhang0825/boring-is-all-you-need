# Boring Is All You Need Feature Map

| Feature | Implementation | Installed location | Verification |
| --- | --- | --- | --- |
| Codex contract | `templates/codex/AGENTS.md` | `$HOME\.codex\AGENTS.md` | Inspect rendered file. |
| Progressive rules | `rules/` | `$HOME\.steadyagent\rules\` | Installed diagnosis. |
| Workflow skill | `skills/steadyagent-workflow/` | `$HOME\.codex\skills\steadyagent-workflow\` | Installed diagnosis. |
| Three-block managed runtime | `templates/codex/requirements.managed-hooks.example.toml` | `%ProgramData%\OpenAI\Codex\requirements.toml` | Exact matrix diagnosis. |
| Unified command/file Guard | `tools/hooks/` | `$HOME\.steadyagent\tools\hooks\` | Single-process ledger plus `test-agent-hooks.ps1`. |
| State recovery | `agent-hook-context.ps1`, `agent-hook-precompact.ps1` | Hook runtime | Compact/resume fixture and Live probe. |
| Sensitive path policy | `tools/protected-path-policy.ps1` | `$HOME\.steadyagent\tools\` | Guard, checkpoint, and pre-commit tests. |
| Explicit checkpoint | `tools/git-checkpoint.ps1` | `$HOME\.steadyagent\tools\` | `test-git-checkpoint.ps1`. |
| Pre-commit defense | `tools/git-hooks/` | `$HOME\.steadyagent\tools\git-hooks\` | `test-pre-commit.ps1`. |
| Rollout-file skill catalog | `tools/skill-index.ps1`, `tools/skill-search.ps1` | `$HOME\.steadyagent\tools\` plus generated local snapshots | `test-skill-catalog.ps1`; evidence is `rollout-file-confirmed`, never Live. |
| 23-item local equivalence | `manifests/local-postimage-equivalence.json` | `$HOME\.steadyagent\manifests\` | `test-local-equivalence.ps1` red-to-green gate. |
| Package source trust | `package-assets.sha256` plus the embedded installer digest | Loaded checkout before staging | 52-source closure, tampered-source, and tampered-manifest migration tests. |
| Transactional migration | `tools/install.ps1` | Runs from checkout | `test-v2-migration.ps1`. |
| V1-owned tombstones | `manifests/v1-codex-owned-files.txt` | `$HOME\.steadyagent\manifests\` | Full V1 fixture and installed diagnosis. |
| Receipt rollback | `tools/rollback.ps1` | `$HOME\.steadyagent\tools\` or same verified release package during early-crash recovery | durable `applying`/`applied` receipt, exact mixed-state, snapshot, script-identity, non-elevated-token and zero-write tests. |
| Installed configuration and rollout-file diagnosis | `tools/skill-index.ps1`, `tools/diagnose-install.ps1` | New Codex task with `CODEX_THREAD_ID` | Run `skill-index.ps1 -ThreadId $env:CODEX_THREAD_ID`, then `-RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity`; perform manual Hook observations in that real task for Live acceptance. |
| Public release gate | `tools/validate-release-readiness.ps1` | Repository | Clean release validation. |
| Extracted archive gate | `tools/validate-release-archive.ps1` | Release ZIP | No-Git package closure and portable behavior validation. |

Installation and host activation are part of the same explicit transaction. A restart remains necessary because Codex registers managed Hooks at task startup.

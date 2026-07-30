# Harness Review and Maintenance

Run this review every three to six months, after a material model/runtime
change, or when SessionStart emits `[HARNESS-REVIEW DUE]`. Its purpose is to
remove configuration written for old models or one-off failures before that
configuration becomes drag.

After completing the review, write the current UTC date as `yyyy-MM-dd` to
`$HOME\.steadyagent\.harness-last-review`.

## 1. Process the lessons inbox

- Review each candidate in the project or user lessons inbox.
- Promote only repeated, general failures with a concrete countermeasure.
- Delete or archive one-off and obsolete candidates only after confirming the
  exact target and recovery boundary.

## 2. Prune lessons

- Remove guidance written only for an obsolete model, tool, or interface.
- Relax or remove rules that now over-constrain the current model.
- Keep title-level reminders concise; preserve detailed evidence in the
  appropriate rule, test, or project record.

## 3. Prune rules and skills

- Merge duplicated or unused rules.
- Identify unused or duplicate skills, but do not archive or remove them
  without explicit user approval and a recovery plan.
- Recheck that skill routing keeps ordinary tasks lightweight and top-level
  orchestration explicit.
- Rebuild the runtime catalog only from a restarted task's advertised skills;
  an older task cannot claim new Live visibility.
- Run `tools\skill-index.ps1`, then run
  `tools\diagnose-install.ps1 -RequireRuntimeCatalog`.
- Inventory `$HOME\.steadyagent\runtime-skill-catalogs\codex-desktop\`
  read-only: directory count, total size, oldest/newest write time, and exact
  candidates older than 180 days. Do not delete automatically.

## 4. Review Harness infrastructure

- Run `tools\test-agent-hooks.ps1` after any Hook change.
- Confirm the active managed configuration is still the exact four-block
  Codex-only matrix.
- Review MCP allowlists and connected capabilities for actual continued need.
- Inspect cache, downloads, and logs by size, age, and metadata only. Do not
  reconstruct raw commands, file contents, or paths from privacy-preserving
  guard audit records.
- Reconsider model and effort settings, but never change them as part of this
  review without explicit authorization.
- Run `tools\diagnose-install.ps1 -RequireHooksActive -RequireRuntimeCatalog
  -RequireGitIdentity`.

## 5. Close the review

- Record conclusions, changes, validation, residual risk, and Git state.
- Update `$HOME\.steadyagent\.harness-last-review` with the current UTC date.
- Do not push, publish, delete inventories, or mutate external systems without
  explicit authorization.

## Release candidate scoring

For a frozen public release, use fresh read-only reviewers across security,
engineering, and specification. Findings come before scores. Any P0-P3 blocks
release. Every named critical subscore and each axis must be at least 9.5/10;
an average cannot hide a lower score. Reviewers must report commands, limits,
branch, HEAD, worktree, staging, and remote-write status.

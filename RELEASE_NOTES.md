# Release Notes

## v2.0.0

SteadyAgent 2 is a breaking, Codex-only release.

- replaces the dual-host V1 package with a Codex Desktop workflow migration;
- installs exactly four managed Hook blocks;
- removes UserPromptSubmit, PermissionRequest, PostToolUse and all Claude release assets;
- changes independent review from file-count-based to material-risk-based;
- hardens nested Guard parsing, audit privacy, sensitive path classification, checkpoint isolation and pre-commit checks;
- adds dry-run-first transactional installation, V1 conflict detection, explicit replacement authorization, full backup, atomic apply, final verification, and receipt-driven successful-migration rollback;
- adds a versioned V1-owned-file tombstone manifest so authorized replacement removes the old Codex release surface and the same receipt restores it;
- activates the scoped global pre-commit path as part of the same authorized transaction;
- adds portable, thread-bound runtime skill indexing and search without shipping local runtime state;
- retains portable Caveman lite reporting, lessons-title injection, 90-day Harness maintenance reminders, strict runtime-catalog/Git-identity diagnosis, and the three-to-six-month maintenance checklist;
- freezes a 23-item local-postimage equivalence map with byte-exact, rendered-equivalent, behavior-superset, and policy-equivalent evidence;
- adds dedicated migration, Hook, checkpoint, pre-commit, skill-catalog, protected-path and local-equivalence regression suites.

V1 users must preview the migration and then run `tools/install.ps1 -Apply -ReplaceExistingWorkflow`. Restart Codex Desktop and require a clean diagnosis before trusting Live Hooks.

## v1.0.0

SteadyAgent v1 turns the original personal workflow into a public, bilingual, Windows-first agent harness for Codex and Claude Code.

### Included

- English and Chinese README entrypoints.
- Public Codex and Claude Code templates.
- Progressive workflow, verification, review, context, and safety rules.
- PowerShell tools for dry-run install, Git preflight, checkpoint commits, hook smoke tests, and release validation.
- Public hook runtime scripts for SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, and PreCompact.
- Release-readiness gate that validates a fresh workspace snapshot, rendered host configs, installed hook smoke tests, local Markdown links, and public release assets.
- MIT license, contribution guide, security policy, issue templates, PR template, release checklist, and resume case study.

### Known Limits

- The first release is Windows-first and PowerShell-based.
- Codex and Claude Code expose different hook surfaces; the docs describe those differences instead of promising identical enforcement.
- The release gate validates generated config shape and installed hook smoke tests, but it does not install into a user's real global Codex or Claude Code configuration.

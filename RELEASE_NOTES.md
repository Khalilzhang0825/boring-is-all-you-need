# Release Notes

## v2.0.0

SteadyAgent 2 is a breaking, Codex-only release.

- replaces the dual-host V1 package with a Codex Desktop workflow migration;
- installs exactly three managed Hook blocks: one `SessionStart`, one unified `PreToolUse`, and one `PreCompact`;
- removes UserPromptSubmit, PermissionRequest and PostToolUse, and removes Claude runtime, templates, settings and Hooks from the V2 installation surface; V1 tombstones and excluded-assertion metadata remain only as migration and verification evidence;
- changes independent review from file-count-based to material-risk-based;
- hardens nested Guard parsing (including PowerShell Unicode parameter dashes), audit privacy, sensitive path classification, checkpoint index/object isolation, staged-object checks, pre-commit checks, and release whitespace checks against inherited Git config, attributes, excludes, and fsmonitor;
- makes checkpoint publication crash-recoverable with a per-worktree journal, captured symbolic-ref identity, compare-and-swap attachment, and fail-closed third-party index/ref handling;
- adds dry-run-first transactional installation, V1 conflict detection, explicit replacement, a 52-source installer-anchored package manifest, durable pre-write snapshots and `applying` receipt, atomic apply, final verification, and journal-driven recovery from hard interruptions during both installation and rollback;
- binds diagnosis to all 53 installed hashes and makes production Apply/rollback non-elevated-only: no UAC, ACL changes, owner takeover, or administrator process touching user-writable migration paths; test-only roots and injections require both `STEADYAGENT_TEST_MODE=1` and an existing isolated `STEADYAGENT_TEST_ROOT` named `steadyagent-v2-migration-<32 lowercase hex>` under the system temp directory;
- adds a versioned V1-owned-file tombstone manifest so authorized replacement removes the old Codex release surface and the same receipt restores it;
- activates the scoped global pre-commit path as part of the same authorized transaction, runs the SteadyAgent guard first, and chains executable repository-local pre-commit hooks;
- adds portable, thread-bound runtime skill indexing and search without shipping local runtime state; production tools discover the fixed `$HOME\.steadyagent` installation root from their installed location;
- retains dynamic Caveman lite reporting, lessons-title injection, due-only 90-day Harness maintenance reminders with a fresh-install mtime baseline, strict runtime-catalog/Git-identity diagnosis, and the three-to-six-month maintenance checklist;
- freezes a 23-item local-postimage equivalence map with rendered-equivalent, behavior-superset, scoped-equivalent, and policy-equivalent evidence, plus an exact 65-assertion retained Hook-to-public-evidence binding;
- adds dedicated migration, Hook, checkpoint, pre-commit, skill-catalog, protected-path and local-equivalence regression suites.
- pins the release jobs to reviewed Node-24-native action commits, serializes the exact tag workflow, and publishes a machine-readable provenance asset plus a release body that expose the reviewed commit; draft creation finishes only after live ID, body, assets, digests, tag, and `main` read back exactly.

V1 users must preview the migration and then run `tools/install.ps1 -Apply -ReplaceExistingWorkflow` from an ordinary, non-elevated PowerShell session. Administrator-locked managed configuration is explicitly unsupported in this release. Restart Codex Desktop and require a clean diagnosis before trusting Live Hooks.

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

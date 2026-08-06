# Safety Boundaries

Never run destructive Git or broad deletion commands by default. Never overwrite unrelated user work or write secrets, credentials, private keys, connection strings, or sensitive vulnerability details.

Explicit authorization is required before push, publish, deploy, dependency installation, migration, bulk rename/delete, or external writes. Resolve exact targets with read-only checks first.

The Hook cannot infer conversational authorization or an external variable's runtime value from command text. In enforcement mode, recursive PowerShell deletion may use canonical `Remove-Item` with exactly one `-LiteralPath`, expressed as either a nested absolute local literal or a variable assigned once in the same top-level command text from that same kind of literal and referenced only by `Remove-Item`. External, reassigned, compound-written, conditional, scoped, protected/system, expression, array, relative, multi-target, alias, and unsupported forms remain rejected.

When a user explicitly accepts the risk and requests no second Hook veto, `-EnforcementMode Audit` makes a best-effort attempt to record recognized risks but never returns a deny decision. Authorization and target verification then stay solely in the agent/user working contract.

Ordinary `git push` may proceed after that authorization. Force, mirror, remote-ref deletion, and prune forms remain separately guarded because they rewrite or remove remote history rather than publishing the reviewed branch normally.

Codex managed guards block common dangerous command and secret-file edits before execution unless the user has explicitly selected audit mode. Guard logs contain only timestamp, fixed reason, normalized tool name, and input SHA-256—never raw commands, patches, file content, or complete target paths.

The command guard is a deterministic mistake-prevention layer, not an adversarial sandbox. The pre-commit and explicit-file checkpoint gates remain required. Unknown matched payloads and unknown nested parallel wrappers fail closed in enforcement mode and pass without a deny decision in explicitly selected audit mode.

Apply and rollback support both ordinary and elevated user tokens. They use the active token as-is and never request UAC, change ACLs, or take ownership. A target that the active token cannot update is still refused. Cooperative same-user guards prevent mistakes; they do not sandbox malware running as that user.

The loaded installer anchors the canonical 52-source `package-assets.sha256` digest and stages only once-read matching bytes. Before the first target or Git write, it durably publishes and reads back original snapshots plus an `applying` receipt. Hard-interruption recovery writes only when every target and Git state is exactly original or exactly post-install; any third state fails closed. The official distribution channel or a separately verified installer digest remains the pre-launch trust root. Receipt hashes prove byte integrity, not identity or authorization.

Test-only path overrides and fault injection require both `STEADYAGENT_TEST_MODE=1` and an existing, non-reparse `STEADYAGENT_TEST_ROOT` below the system temp directory. Installer, rollback, diagnosis, package, receipt, target, configuration, backup, and migration Git fixtures require the exact basename `steadyagent-v2-migration-<32 lowercase hex>` and must remain inside that root. Checkpoint Git-mutation fixtures require the separate exact basename `steadyagent-git-checkpoint-<32 lowercase hex>`; their repository, common/worktree Git directories, objects, index, and injected mutation paths must all remain inside that root.

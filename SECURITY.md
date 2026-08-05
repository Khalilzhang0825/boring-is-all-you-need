# Security Policy

SteadyAgent is a workflow harness, not a security product. Its hooks and scripts reduce common local workflow mistakes, but they cannot guarantee complete secret detection or command safety.

## Supported Versions

The current public V2 line is the only supported release line.

## Reporting A Security Issue

Do not open a public issue with exploit details, private tokens, credentials, or sensitive local paths. Submit sensitive reports through GitHub's [Report a vulnerability](https://github.com/Khalilzhang0825/steadyagent/security/advisories/new) form. The release checklist requires this private channel to be enabled and verified before publication.

If that form is unavailable, open a minimal public issue stating only that the private reporting channel is unavailable. Do not include vulnerability details or sensitive data; the maintainer will establish a private follow-up channel.

## Scope

Useful reports include:

- guardrail hooks that fail to block a documented dangerous action
- scripts that can accidentally stage or publish private files
- documentation that encourages unsafe setup
- examples that include secrets, credentials, or private machine paths

Out of scope:

- model jailbreaks unrelated to this repository
- requests for guaranteed secret detection
- attacks that require a malicious local user with full filesystem access
- attempts to treat cooperative same-user guardrails or a user-writable Codex managed configuration as a sandbox against malware running as that same user

## Local Safety Boundary

Always review generated install plans before applying them. SteadyAgent defaults to dry-run installation and refuses to replace differing targets unless `-Apply -ReplaceExistingWorkflow` is explicitly passed. Apply and rollback refuse elevated execution before migration writes; they never request UAC, change ACLs, or take ownership. The default managed target is supported only when the current non-elevated user token can update it. The loaded installer anchors `package-assets.sha256`, verifies all 51 unique source files, and stages only the once-read matching bytes; the official distribution channel or a separately verified installer digest remains the pre-launch trust root. Before the first target or Git write, Apply durably writes and reads back original snapshots plus an `applying` receipt. Recovery accepts only exact original/post-install managed-file byte/existence and recorded Git states and fails closed on a third state. It does not capture or restore ACLs, owners, file attributes, timestamps, or alternate data streams. Receipt hashes are integrity checks, not identity or authorization.

Migration custom roots, explicit Git-config paths, and fault injections are not production controls. They require both `STEADYAGENT_TEST_MODE=1` and an existing isolated `STEADYAGENT_TEST_ROOT` below the system temp directory whose basename is exactly `steadyagent-v2-migration-<32 lowercase hex>`; every test-scoped package, receipt, target, configuration, and tool path must remain inside that root. Checkpoint fault injections use the same double gate but require `steadyagent-git-checkpoint-<32 lowercase hex>` and contain the repository, common/worktree Git directories, object store, index, and injected path inside it before any recovery or Git write.

Rollback publishes a receipt-bound durable journal before changing files or Git
configuration. Exit code 3 or `rollback_incomplete` is an explicit manual
reconciliation boundary: preserve the receipt, backups, journal, current
targets, and Git configuration; do not edit evidence or blindly retry.

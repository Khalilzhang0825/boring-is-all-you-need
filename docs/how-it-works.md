# How Boring Is All You Need Works

Boring Is All You Need combines six small layers around Codex Desktop:

1. a short `AGENTS.md` contract;
2. progressive rules loaded only when relevant;
3. an explicit reusable workflow skill;
4. deterministic PowerShell tools;
5. three managed lifecycle Hooks, including one unified `PreToolUse` process;
6. release and migration validation.

The intended loop is:

```text
understand -> plan -> red check -> smallest change -> green check -> risk-based review -> checkpoint
```

Judgment and authorization stay in the agent and user conversation. The standard managed `PreToolUse` Hook audits recognized command and file risks without denying them. Deterministic write boundaries—staged secrets, explicit checkpoint scope, migration conflicts, rollback, and active Hook shape—remain enforced by scripts.

The loaded installer verifies a canonical 52-source package-manifest digest, reads each matching source once, and renders only those trusted bytes into staging. It validates the complete plan, detects conflicts, durably snapshots originals, and durably writes and reads back an `applying` receipt before the first target or Git write. It then writes atomically under a machine-wide Boring Is All You Need migration lock, verifies the final state, and advances the receipt to `applied`. A repeated Apply exits with zero target/config/backup/receipt/state writes when every managed byte, removal, and active Hook value already matches. Normal failures restore immediately; after a hard interruption, rollback classifies every target and Git state as exact original or exact post-install, durably journals its own entering state before writing, restores a valid mixed state, and resumes or compensates after a rollback hard stop. Exact target state covers managed-file byte content/existence and recorded Git value/config bytes, not ACLs, owners, attributes, timestamps, or alternate data streams. A third state is refused before writing, while `rollback_incomplete` is a preserved-evidence manual reconciliation boundary. The distribution channel or a separately verified installer digest remains the trust root for the installer itself. The migration receipt binds the recovery plan and byte-integrity evidence; its hash is not authentication. Apply and rollback use the current ordinary or elevated token as-is and never request UAC, change ACLs, or take ownership; same-user workflow guards remain cooperative rather than an adversarial sandbox.

The runtime stays light by avoiding per-prompt and post-tool Hooks. SessionStart injects only dynamic Caveman status, lesson titles, due review reminders, and task state when needed; the static contract stays in `AGENTS.md`. Independent review is based on material risk rather than file count.

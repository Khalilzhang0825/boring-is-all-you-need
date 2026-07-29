# How SteadyAgent 2 Works

SteadyAgent combines six small layers around Codex Desktop:

1. a short `AGENTS.md` contract;
2. progressive rules loaded only when relevant;
3. an explicit reusable workflow skill;
4. deterministic PowerShell tools;
5. four managed lifecycle Hooks;
6. release and migration validation.

The intended loop is:

```text
understand -> plan -> red check -> smallest change -> green check -> risk-based review -> checkpoint
```

Judgment stays in the agent and user conversation. Deterministic boundaries—dangerous commands, protected files, staged secrets, explicit checkpoint scope, migration conflicts, rollback, and active Hook shape—live in scripts.

The installer renders machine paths into staging, validates the complete plan, detects conflicts, snapshots originals, writes atomically under a session-wide SteadyAgent migration lock, verifies the final state, and restores on failure. The migration receipt is the recovery authority.

The runtime stays light by avoiding per-prompt and post-tool Hooks. SessionStart injects only the short contract and task state when needed. Independent review is based on material risk rather than file count.

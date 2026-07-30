# SteadyAgent 2 Hook Runtime

The Codex runtime contains exactly four managed Hook blocks:

| Event | Behavior |
| --- | --- |
| `SessionStart` | Injects the Codex contract, Caveman lite status, lessons headings, the 90-day Harness review reminder, and restores `PROJECT_STATE.md` or `.agent/state.md` after resume/compact. |
| `PreToolUse` | Recursively inspects matched shell calls and denies dangerous commands. |
| `PreToolUse` | Recursively inspects matched file edits and denies protected paths. |
| `PreCompact` | Reminds the agent to persist current state. |

There are no per-prompt, permission-request, or post-tool Hooks in V2.

Matched malformed input, incomplete relevant leaves, and unknown nested parallel schemas fail closed. Named unrelated tools produce no decision.

Guard logs contain timestamp, fixed reason, normalized tool name, and input SHA-256 only. Raw commands, paths, patches, and file content are never logged.

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-agent-hooks.ps1
```

Script tests prove runtime behavior but not host registration. Restart Codex and run installed diagnosis for Live acceptance.

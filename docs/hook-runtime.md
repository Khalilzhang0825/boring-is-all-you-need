# Boring Is All You Need Hook Runtime

The Codex runtime contains exactly three managed Hook blocks:

| Event | Behavior |
| --- | --- |
| `SessionStart` | Injects only dynamic Caveman status, lesson headings, a due 90-day Harness review reminder, and state restored from `PROJECT_STATE.md` or `.agent/state.md` after resume/compact. A fresh install without a review marker uses the installed context Hook mtime as its first 90-day baseline. |
| `PreToolUse` | In one PowerShell process, recursively inspects matched shell and file-edit leaves and denies dangerous commands or protected paths. Mixed parallel wrappers are checked for both kinds of leaf; incomplete relevant input fails closed. |
| `PreCompact` | Reminds the agent to persist current state. |

There are no per-prompt, permission-request, or post-tool Hooks in V2.

Matched malformed input, incomplete relevant leaves, and unknown nested parallel schemas fail closed. Named unrelated tools produce no decision. The Hook suite records the exact managed invocation count for ordinary shell, file-edit, and mixed parallel events, and reports a broad Windows PowerShell 5.1 cold-start budget to catch duplicate launches or obvious regressions without using a tight wall-clock threshold.

Guard logs contain timestamp, fixed reason, normalized tool name, and input SHA-256 only. Raw commands, paths, patches, and file content are never logged.

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-agent-hooks.ps1
```

Script tests prove packaged behavior but not host registration. Restart Codex, run installed diagnosis for configuration and rollout-file evidence, then observe SessionStart and one controlled Hook behavior in the real new task for Live acceptance.

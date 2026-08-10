# Boring Is All You Need Hook Runtime

The Codex runtime contains exactly three managed Hook blocks:

| Event | Behavior |
| --- | --- |
| `SessionStart` | Injects only lesson headings, a due 90-day Harness review reminder, and state restored from `PROJECT_STATE.md` or `.agent/state.md` after resume/compact. It does not inject Caveman behavior. A fresh install without a review marker uses the installed context Hook mtime as its first 90-day baseline. |
| `PreToolUse` | In one PowerShell process, recursively inspects matched shell and file-edit leaves. The standard managed command uses `-EnforcementMode Audit`, records recognized risks best-effort, and never returns a deny decision. |
| `PreCompact` | Reminds the agent to persist current state. |

There are no per-prompt, permission-request, or post-tool Hooks in V3.

Matched malformed input, incomplete relevant leaves, and unknown nested parallel schemas pass without a deny decision in the standard managed Audit mode. Maintainers may explicitly select `-EnforcementMode Enforce`, where the same cases fail closed. Named unrelated tools produce no decision. The Hook suite records the exact managed invocation count for ordinary shell, file-edit, and mixed parallel events, and reports a broad PowerShell 7 cold-start budget to catch duplicate launches or obvious regressions without using a tight wall-clock threshold.

Guard logs contain timestamp, fixed reason, normalized tool name, and input SHA-256 only. Raw commands, paths, patches, and file content are never logged.

Run:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-agent-hooks.ps1
```

Script tests prove packaged behavior but not host registration. Restart Codex, run installed diagnosis for configuration and rollout-file evidence, then observe SessionStart and one controlled Hook behavior in the real new task for Live acceptance.

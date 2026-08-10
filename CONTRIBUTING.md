# Contributing

Boring Is All You Need is a local-first harness for AI coding workflows. Contributions should improve reliability, portability, documentation clarity, or verification evidence.

## Before Opening A Pull Request

Run the release gate from the repository root:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

While preparing an uncommitted change, use the WIP mode so the gate validates staged and untracked files explicitly:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1 -AllowDirty
```

For focused changes, also run the smaller gate that matches the touched area:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-phase3.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-runtime-slice.ps1
```

## Pull Request Expectations

- Keep changes scoped to one clear workflow, script, template, or documentation goal.
- Update both English and Chinese docs when the user-facing behavior changes.
- Prefer deterministic scripts or hooks over instructions when behavior must be enforced.
- Include the validation commands and results in the PR description.
- Do not include private paths, tokens, local credentials, logs, or generated dependency folders.

## Adding New Runtime Behavior

New guardrails should be observable through public tests. Add one failing validation check first, implement the smallest behavior that makes it pass, then run the relevant gate again.

# Workflow Examples

These examples show how to ask for work after Boring Is All You Need is installed. You do not need to mention every internal file. Ask for the outcome, then ask the agent to use the project's workflow.

## Universal Starter Prompt

Use this when you are unsure whether the host loaded the instructions automatically:

```text
Use the Boring Is All You Need workflow for this repository. Inspect first, keep the change scoped, run the smallest relevant validation, and end with changed files, verification, remaining risks, and Git status.
```

Expected behavior:

- The agent reads relevant files before editing.
- It gives a short plan for complex or risky work.
- It avoids unrelated refactors.
- It verifies the smallest relevant behavior.
- It reports evidence instead of only saying the task is done.

## Example 1: Bug Fix

Prompt:

```text
The login test is failing. Use the Boring Is All You Need workflow to investigate, find the smallest fix, run the relevant test, and checkpoint only after the diff is reviewed.
```

Expected agent flow:

1. Inspect the failing test and related code.
2. Reproduce the failure or identify observable evidence.
3. Explain the suspected cause before editing.
4. Patch only the relevant files.
5. Run the targeted test or the closest available check.
6. Report the changed files, validation result, risk, and Git status.

Good final report:

```text
Changed: src/auth/session.ts and tests/auth/session.test.ts.
Verified: npm test -- tests/auth/session.test.ts passed.
Risk: only the remembered-session path was covered; full auth regression suite was not run.
Git: clean after checkpoint.
```

## Example 2: Feature Work

Prompt:

```text
Add a dark-mode toggle to the settings page. Use the Boring Is All You Need workflow: inspect existing UI patterns, give me a short plan, implement the smallest complete version, run the relevant checks, and report residual risk.
```

Expected agent flow:

1. Inspect existing settings components, style conventions, and tests.
2. Define the behavior in a short plan.
3. Reuse existing UI patterns instead of inventing a separate design system.
4. Add focused tests if the codebase already has a matching test pattern.
5. Run lint, type check, unit test, or browser verification depending on the project.
6. Request independent review before checkpoint when the maintainer explicitly asks for it, the work is high risk, or the agent identifies a specific material risk; file count alone is not a trigger.

## Example 3: Code Review Before Editing

Prompt:

```text
Review this branch before we change anything. Use the Boring Is All You Need review style: findings first, order by severity, cite file and line, then list test gaps and residual risk.
```

Expected agent flow:

1. Read the diff and the relevant surrounding code.
2. Lead with concrete findings, not a summary.
3. Separate bugs from style preferences.
4. Include file and line references.
5. Mention missing tests or unverified behavior.
6. Avoid changing files unless you explicitly ask for fixes.

## Example 4: Long Task Resume

Prompt:

```text
Continue the migration from the last checkpoint. Use the Boring Is All You Need workflow: first read the project state file, verify Git status, summarize current progress, then continue with the next smallest step.
```

Expected agent flow:

1. Read `PROJECT_STATE.md` or `.agent/state.md` if present.
2. Run Git preflight.
3. Reconcile the state file with the current working tree.
4. Continue from the documented next step instead of restarting from memory.
5. Update the state file before any context handoff or compaction.

Use this for multi-hour work, release preparation, migrations, and tasks that may be interrupted.

## Example 5: Release Check

Prompt:

```text
Check whether this repository is ready for a public release. Use the Boring Is All You Need workflow: run the release-readiness gate, inspect any failure, and do not push or tag unless I explicitly approve.
```

Expected agent flow:

1. Run the release gate:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

2. If the tree intentionally has work in progress, use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1 -AllowDirty
```

3. Explain failures as concrete missing files, broken links, stale release wording, hook smoke test failures, or naming residue.
4. Do not publish, retag, or rewrite remote history without explicit approval.

## What A Good Boring Is All You Need Response Contains

At the end of a task, the response should include:

- changed files
- validation commands and results
- open risks or skipped checks
- Git status
- whether anything was not completed

For larger tasks, it should also include the review result and the next step.

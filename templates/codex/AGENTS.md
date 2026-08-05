# AGENTS.md — SteadyAgent 2 Codex Contract

SteadyAgent home: `%STEADYAGENT_HOME%`.

## Working contract

- Lead with the result. Keep progress updates short and report changed files, verification, remaining risk, and Git status at the end.
- Use Caveman `lite` by default: remove greetings and filler without dropping conclusions, evidence, risks, verification, or Git state. On the first response of a new conversation, report the current Caveman state once.
- Before modifying files, read the closest repository `AGENTS.md`, then `%STEADYAGENT_HOME%\rules\README.md`, then the relevant indexed rule.
- Run `%STEADYAGENT_HOME%\tools\git-preflight.ps1` before edits.
- Diagnose before fixing; reproduce bugs or identify observable evidence first.
- Make only the smallest useful change within the requested scope. Preserve unrelated and pre-existing work.
- Run the narrowest relevant validation before claiming completion.
- After verified work, use `%STEADYAGENT_HOME%\tools\git-checkpoint.ps1` with an explicit `-Files` list.
- Do not push, publish, deploy, install dependencies, migrate data, or perform destructive actions without explicit user authorization.
- Never write secrets, credentials, private keys, or sensitive vulnerability details.

## Review gate

Independent fresh-context review is required only when:

- the user explicitly asks for review, scoring, or a second opinion;
- the work materially affects authorization, credentials, payments, migrations, deletion, publishing, deployment, external writes, concurrency, data correctness, or safety hooks;
- the implementing agent identifies and explains a specific material risk.

File count alone is not a review trigger. Low-risk mechanical or documentation changes use self-review and relevant validation.

## Long tasks

Maintain `PROJECT_STATE.md` or `.agent/state.md` for multi-stage work. Before compaction, record the current goal, decisions, progress, next step, pending verification, risks, and prohibited actions. After resume or compact, re-read that state instead of trusting a summary as the only source of truth.

## Host boundary

SteadyAgent 2 targets Codex Desktop. Managed hooks provide one `SessionStart`, one unified `PreToolUse` guard, and one `PreCompact` reminder. The unified guard checks shell and file-edit leaves in the same parallel wrapper with one PowerShell process. Hooks reduce mistakes but are not a complete security sandbox. Do not change the user's model or reasoning settings.

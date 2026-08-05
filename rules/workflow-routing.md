# Workflow Routing

## Purpose

Choose the right working mode before editing. SteadyAgent work should stay scoped, observable, and recoverable.

## Use When

Use this rule when a task is ambiguous, multi-step, risky, or likely to touch multiple files.

## Rules

- Use the core loop: `understand -> plan -> red check -> smallest change -> green check -> risk gate -> independent review when required, otherwise self-review -> checkpoint`.
- If the goal, boundary, or acceptance criteria are unclear, diagnose before editing.
- Identify the time scale: short-term stopgap, transitional workflow, or long-term system.
- For bugs, reproduce the behavior or find observable evidence before changing code.
- For complex work, state the target files, validation path, and risks before editing.
- Expose conflict between user requests, tests, docs, and existing code. Do not blend incompatible requirements into a hidden third path.
- Keep edits limited to the current goal. Mention unrelated issues instead of fixing them opportunistically.
- Prefer existing project patterns, scripts, tools, and documentation over new abstractions.

## Validation

- The final diff only contains files needed for the task.
- The task has an explicit verification command or manual acceptance step.
- Any skipped check, assumption, conflict, or residual risk is reported.

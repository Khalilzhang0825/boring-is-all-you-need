---
name: steadyagent-workflow
description: Local-first Codex workflow for planning, debugging, reviewing, refactoring, improving AGENTS.md, building skills, publishing agent harness repositories, or running complex multi-step coding tasks that need staged diagnosis, context control, verification loops, review strategy, release evidence, and anti-overengineering guardrails.
---

# Boring Is All You Need Workflow

Use this skill to structure non-trivial AI coding agent work. Keep the main context lean: use this file for the workflow, and load references only when the task needs them.

## Decision Gate

- Simple task: answer or edit directly, then verify with the smallest useful check.
- Ambiguous task: diagnose first; state missing information, assumptions, and likely paths.
- Bug task: reproduce or find observable evidence before proposing a fix.
- Multi-step task: use the staged workflow below.
- Rule, prompt, release, or skill design: keep permanent instructions short and move detailed knowledge to references.

## Staged Workflow

1. Diagnose
   - Read the current AGENTS.md, README, task docs, and directly relevant code.
   - Identify the time scale: short-term stopgap, transitional workflow, or long-term system.
   - Surface conflicts instead of blending incompatible requirements or conventions.

2. Plan
   - State goal, scope, likely files, verification, and risks.
   - Prefer the smallest viable path.
   - For multiple viable approaches, list tradeoffs and recommend one.

3. Implement
   - Make surgical changes only.
   - Reuse existing patterns, scripts, tools, skills, and APIs.
   - Avoid new dependencies unless existing capabilities are insufficient.

4. Verify
   - Verify behavior, not just test status.
   - Use the smallest relevant tests, static checks, render checks, or manual acceptance steps.
   - If verification fails, analyze why before changing direction.

5. Review
   - For risky work, run an independent review or subagent pass.
   - Check edge cases, permissions, concurrency, caching, migration, rollback, and test gaps.
   - Record only durable decisions and validation results.
6. Checkpoint
   - Re-run the relevant gate.
   - Review Git status and diff.
   - Create a scoped checkpoint commit when validation passes.

## Reference Loading

Load only what the task needs:

- `references/operating-principles.md`: when designing workflows, AGENTS.md, stage gates, or long-running collaboration rules.
- `references/karpathy-guardrails.md`: when writing, reviewing, refactoring, or debugging code and overengineering/scope creep is a risk.
- `references/mnilax-extensions.md`: when tasks involve conflicting conventions, flaky tests, long loops, partial failures, or deterministic runtime decisions.
- `references/prompt-recipes.md`: when the user asks for reusable prompts or when a task would benefit from a precise prompt template.

## Output Shape

- Use Markdown for short answers, checklists, and simple command guidance.
- Use HTML artifacts for dense comparisons, specs, PR/diff explainers, technical reports, design prototypes, diagrams, or temporary editors with export/copy output.
- For long tasks, include checkpoints and stop to realign after budget exhaustion, repeated failure, or changed assumptions.

## Subagent Strategy

Use subagents when work benefits from isolation, parallelism, or a fresh perspective:

- read-only codebase research across many files
- independent review before finalizing
- parallel work on independent files or modules
- staged pipelines such as research -> plan -> implement -> test

Do not use subagents for small tasks, strong sequential dependencies, same-file parallel edits, or work that requires agents to coordinate directly.

## Completion Criteria

Before claiming completion:

- The task goal is met.
- Verification evidence is available.
- Partial failures, skipped steps, and residual risks are explicit.
- Any durable rule or workflow learning is recorded in the right layer: AGENTS.md for always-on rules, this skill for workflow, references for detailed knowledge.

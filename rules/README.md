# Boring Is All You Need Rules

These files are progressive rules for AI coding agents. Keep always-on templates short, then load only the rule that matches the current task.

## Rule Index

- `workflow-routing.md`: choose the right mode, expose conflicts, and keep work scoped.
- `skill-routing.md`: keep skill discovery explicit, lightweight, and evidence-bound.
- `verification.md`: choose checks that prove behavior, not confidence.
- `review-gates.md`: decide when independent review and scoring are required.
- `context-management.md`: recover long tasks after interruption or compaction.
- `safety-boundaries.md`: handle destructive actions, secrets, install, push, publish, and host differences.
- `lessons.md`: repeated portable pitfalls whose headings are injected at SessionStart.
- `harness-review.md`: periodic three-to-six-month Harness maintenance and release review contract.

## Use Pattern

1. Start with `templates/codex/AGENTS.md`.
2. Copy the template together with the `rules/` directory, or adjust the rule paths after copying.
3. Load one rule file when the task requires it.
4. Keep project-specific details in the project repository, not in the public template.
5. Add new rules only when they map to a repeated failure mode.

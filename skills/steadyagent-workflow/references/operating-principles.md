# Operating Principles

Use this reference when designing Codex workflows, AGENTS.md files, stage gates, or long-running collaboration rules.

## Core Rules

1. Converge before expanding. If the goal, boundary, or path is unclear, diagnose first.
2. Identify the time scale: short-term stopgap, transitional workflow, or long-term system.
3. Match the mode to the stage: diagnose, plan, implement, verify, then review.
4. Structure requests and outputs around goal, constraints, path, risks, and acceptance criteria.
5. Persist stage agreements in documents, but keep them short and useful.
6. Verify outcomes with tests, checks, or minimal acceptance steps.
7. Confirm temporary fallback plans before implementation, including risk and recovery.
8. After context compaction or long interruption, reread the necessary documents and realign.
9. If an experiment fails, analyze the cause before switching approaches.
10. Before investing in a new direction, run a small feasibility check.

## Context Layers

- Always-on rules: AGENTS.md.
- Reusable workflow: this skill.
- Detailed knowledge: references.
- Task state: project docs or task notes.

Keep the always-on layer short. If a rule is not needed in most sessions, put it in a reference or task document.

## Time-Scale Decisions

Short-term stopgap:
- Use the smallest reversible fix.
- Verify quickly.
- Document risk and recovery.

Transitional workflow:
- Convert repeated friction into a reusable rule, prompt, command, or skill.
- Keep feedback loops short.
- Avoid platform work before the pattern is proven.

Long-term system:
- Define ownership, governance, update cadence, and validation metrics.
- Prefer layered context, skills, hooks, plugins, MCP, and LSP over one large prompt.
- Review rules every 3-6 months or after major model/tool changes.

## Failure Handling

- Do not report skipped, partial, or failed work as success.
- If requirements, tests, or conventions conflict, report the conflict and ask or recommend a path.
- Test pass is not the final goal; correct behavior is.
- Deterministic runtime decisions such as retry policy, thresholds, routing, permissions, and escalation rules should be code or configuration, not model judgment.

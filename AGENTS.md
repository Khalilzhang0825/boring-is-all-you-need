# AGENTS.md - Boring Is All You Need Codex Guide

This file gives Codex a compact project map for contributing to Boring Is All You Need.

## Project Intent

Boring Is All You Need is a local-first harness for AI coding agents. It packages concise instructions, progressive rules, validation scripts, lifecycle hook examples, and release evidence so agent-assisted development is easier to scope, verify, review, and recover.

## Working Rules

- Keep changes scoped to the requested workflow, tool, template, or documentation surface.
- Read the nearest project guide, relevant docs, and directly touched scripts before editing.
- Prefer deterministic scripts, tests, and hooks over longer instructions when behavior must be enforced.
- Preserve the public release surface: no private paths, local credentials, unpublished plans, or maintainer-only notes.
- Keep English as the default public surface; update the paired Chinese docs when user-facing behavior changes.
- Use `rg` or `rg --files` for repository search.

## Validation

Run the smallest relevant gate before committing:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

Focused checks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-phase3.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-runtime-slice.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-agent-hooks.ps1
```

Use `-AllowDirty` with `validate-release-readiness.ps1` only while reviewing an intentional work-in-progress tree.

## Release Discipline

- Do not publish, retag, or rewrite remote history without explicit maintainer approval.
- Treat `v1.0.0` and later releases as audited artifacts: clean history, reproducible validation, and clear release notes.
- Use [docs/github-publication-runbook.md](docs/github-publication-runbook.md) for public release steps.

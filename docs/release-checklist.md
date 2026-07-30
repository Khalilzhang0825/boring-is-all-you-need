# Release Checklist

Use this checklist before publishing the SteadyAgent V2 tag or GitHub release.

## Required Gates

Run these from a clean repository checkout:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-phase3.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-runtime-slice.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-local-equivalence.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

The release-readiness gate includes a fresh-checkout style snapshot, transactional V2 migration, rendered Codex config checks, installed diagnosis, Hook/checkpoint/pre-commit/skill-catalog tests, the 23-item local equivalence contract with a deliberate red mutation, local Markdown links, and public asset checks.

During local WIP before the checkpoint commit, use `-AllowDirty` to validate the current uncommitted release surface. For final release evidence, run the command without `-AllowDirty` from a clean checkout.

## Manual Review

- Confirm `README.md` and `README.zh-CN.md` describe the same V2 surface.
- Confirm `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, and `RELEASE_NOTES.md` are present.
- Confirm `.github/` templates and the validation workflow are present.
- Confirm the public skill path is `skills/steadyagent-workflow/`.
- Confirm `manifests/local-postimage-equivalence.json` remains 23/23 and the equivalence gate reports no missing, drifted, or unexplained destinations.
- Confirm [docs/github-publication-runbook.md](github-publication-runbook.md) is followed before any remote push, PR, tag, or GitHub release.
- Enable GitHub Private Vulnerability Reporting and verify the repository's **Report a vulnerability** link opens before publication.
- Confirm `git diff --check` has no whitespace errors.
- Confirm `git status --short` is clean after the checkpoint commit.
- Do not push, tag, or publish until the maintainer explicitly approves the release.

## Release Evidence To Save

- Validation command outputs.
- Independent review score and findings.
- Checkpoint commit hash.
- PR URL, GitHub Actions URL, release URL, and repository metadata update notes after publication.
- Known limits: Windows-first scripts, Codex managed hooks require restart-time Live verification, and automated validation does not install into a real global Codex configuration.

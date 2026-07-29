# GitHub Publication Runbook

Use this runbook after local release-readiness passes and before any public push, tag, release, or history rewrite.

## Required Local Evidence

Run from a clean working tree:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-phase3.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-runtime-slice.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-agent-hooks.ps1
```

Record the command output, GitHub Actions run URL, release URL, tag, target commit, and repository metadata update notes.

## Maintainer Approval

Only run public GitHub writes after explicit maintainer approval.

Required approval items:

- target repository
- target branch
- tag name
- target commit
- release type
- whether the operation rewrites history

## Push And PR

Only run after explicit maintainer approval:

```powershell
git push -u origin <branch>
```

For normal changes, open a PR and let GitHub Actions run before merge.

For a clean-history release rewrite, use an orphan commit or equivalent Git data API workflow, then force-update the default branch only after local validation and independent review pass.

## Clean-History Rewrite

Use this path only when the maintainer explicitly approves a history rewrite.

Required sequence:

1. Create a local backup ref for the old default branch.
2. Create the clean orphan/root commit from the reviewed release tree.
3. Delete stale remote branches that would expose old checkpoint history, especially temporary `codex/*` release branches.
4. Delete or replace the existing GitHub release before replacing its tag.
5. Delete and recreate the release tag so it points at the clean commit.
6. Force-update the default branch to the clean commit.
7. Recreate the GitHub release from the clean tag.
8. Run a fresh clone verification from an empty directory.

Fresh clone verification must check:

```powershell
git branch -r
git tag -l
git log --all --oneline
git log --all --grep "<private checkpoint label>"
```

Also run the public residue scan and release gate from the fresh clone:

```powershell
$patterns = @("zsh" + "-agent-rules", "validate-phase[0-2]", "v1" + "-migration-plan", "release" + "-plan")
foreach ($pattern in $patterns) { rg -n $pattern . }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

The rewrite is not complete until the default branch, `v2.0.0` tag, GitHub release, remote branch list, and fresh clone history all point only at the clean public artifact.

## Repository Metadata

Recommended GitHub description:

```text
SteadyAgent 2: a Codex Desktop workflow replacement with transactional migration, fail-closed safety hooks, risk-based review, checkpoint commits, and release evidence.
```

Recommended topics:

```text
ai-agents, coding-agents, codex, codex-desktop, agents-md, developer-tools, powershell, workflow-automation, prompt-engineering
```

## Release

Do not create or replace a tag or GitHub release until explicit maintainer approval confirms the tag name, release type, and target commit.

Release template:

```text
Tag: v2.0.0
Title: SteadyAgent v2.0.0
Target commit: <commit>
```

Release body should include:

- what changed
- included public assets
- validation results
- known limits

## Post-Publish Checks

- Confirm README renders on GitHub.
- Confirm GitHub Actions is green.
- Confirm release page links to the correct tag and target commit.
- Confirm repository description and topics are updated.
- Confirm no private paths, local-only claims, or maintainer-only state appear in public pages.
- Save the PR URL, GitHub Actions run URL, release URL, tag, commit hash, repository metadata update notes, and validation outputs as the release audit trail.

# Release Checklist

Use this checklist before publishing the Boring Is All You Need v3.0.0 tag or GitHub release.

## Required Gates

Run these from a clean repository checkout:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

This is the single aggregate gate. It already includes phase validation, the runtime slice, a fresh-checkout style snapshot, transactional V2 migration, rendered Codex config checks, installed diagnosis, Hook/checkpoint/pre-commit/skill-catalog tests, the 23-item local equivalence contract with deliberate red mutations, the mock-`gh` release state-machine suite, merge-base-to-final-worktree whitespace validation that checks tracked paths directly and untracked files through bounded no-index subprocesses without staging or creating Git objects, local Markdown links, and public asset checks. Do not rerun its child gates as separate release requirements.

During local WIP before the checkpoint commit, use `-AllowDirty` to validate the current uncommitted release surface. For final release evidence, run the command without `-AllowDirty` from a clean checkout.

## Manual Review

- Confirm `README.md` and `README.zh-CN.md` describe the same V3 surface.
- Confirm `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, and `RELEASE_NOTES.md` are present.
- Confirm `.github/` templates and the validation workflow are present.
- Confirm the public skill path is `skills/steadyagent-workflow/`.
- Confirm `manifests/local-postimage-equivalence.json` remains 23/23 and the equivalence gate reports no missing, drifted, or unexplained destinations. Payload 06 must remain `scoped-equivalent`, with the frozen 73-assertion source partitioned into 63 retained Codex-active assertions and ten explicit Claude, removed-event, or removed-Caveman-behavior exclusions.
- Confirm `package-assets.sha256` has exactly 52 canonical source entries, every source hash matches, and the single digest embedded in `install.ps1` matches the manifest.
- Confirm `.github/workflows/release.yml` is restricted to the exact `v3.0.0` tag at the current `origin/main`, pins reviewed Node-24-native actions, forces Node 24, serializes the exact release without cancelling an active run, separates read-only validation, attestation, and draft creation into three least-privilege jobs, reruns the clean tag-checkout gate, and re-resolves live tag/main immediately before and after draft creation. Retry may accept only a non-prerelease draft whose title, reviewed-commit body, and three assets are byte-exact. Post-upload readback must also require the captured release ID; post-create ref-race cleanup may delete only that ID, while a concurrent replacement is preserved.
- Confirm the workflow freezes the audited `v1.0.0` commit and single repository root, proves V1 ancestry, and passes explicit `GH_REPO`/`-R` context to every publication command.
- Confirm every copyable GitHub CLI sequence checks `$LASTEXITCODE` after capability probing, asset download, and attestation verification; derive `$ReviewedSha` from the downloaded machine-readable provenance asset, strictly bind its repository, tag ref, signer workflow, archive name and digest, verify the archive through `--source-digest $ReviewedSha`, match the SHA-256 sidecar, and never extract before all native-command guards pass.
- Confirm local and remote `v3.0.0` tags are either absent or resolve exactly to the reviewed `origin/main` commit, every native Git command is exit-checked, and an existing exact remote tag is preserved without a write.
- Confirm `release-files.txt` exactly matches the tagged repository and extracted archive, with no extra public files or Git metadata. Partial-draft recovery must use the failed run's retained bundle, capture the numeric release ID, revalidate the exact draft/body and every present asset digest immediately before deleting only that ID, confirm that ID is absent, and preserve any concurrent replacement before rerunning failed jobs.
- Confirm final publication captures the reviewed draft's numeric ID, immediately revalidates its exact body, three byte-exact assets and asset metadata/digests plus live tag/main, publishes only by PATCHing that ID, and reads the same published ID back with the exact body and asset snapshot.
- Confirm production Apply and rollback support ordinary and elevated tokens, never request UAC, and contain no protected-recovery production entrypoint.
- Confirm Apply durably writes and reads back snapshots plus an `applying` receipt before its first target or Git write; operation-1, mid-apply, and post-Git-activation hard-kill fixtures must recover managed-file byte content/existence and recorded Git value/config bytes. ACLs, owners, attributes, timestamps, and alternate data streams are outside the snapshot contract.
- Confirm migration test-only roots and injections require both `STEADYAGENT_TEST_MODE=1` and an existing isolated `STEADYAGENT_TEST_ROOT` below system temp named exactly `steadyagent-v2-migration-<32 lowercase hex>`, with package, tool, receipt, target, config, and Git paths confined to it; checkpoint injections independently require `steadyagent-git-checkpoint-<32 lowercase hex>` and contain every Git role before recovery.
- Confirm rollback publishes a durable journal before its first controlled write, resumes operation-1/mid/Git hard kills, and treats exit 3 or `rollback_incomplete` as a preserved-evidence manual reconciliation boundary.
- Confirm all examples support ordinary and administrator PowerShell, while making clear that the scripts do not request UAC, change ACLs, or take ownership. Do not treat a receipt hash as authentication.
- Confirm restart-time diagnosis runs from a new Codex task with `CODEX_THREAD_ID`: first `skill-index.ps1 -ThreadId $env:CODEX_THREAD_ID`, then the successful receipt with `-RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity`. Repository tests are not a substitute for this Live canary.
- Confirm [docs/github-publication-runbook.md](github-publication-runbook.md) is followed before any remote push, PR, tag, or GitHub release.
- Enable GitHub Private Vulnerability Reporting and verify the repository's **Report a vulnerability** link opens before publication.
- Before publishing the captured draft, require GitHub Live evidence that immutable releases are enabled and an exact active tag ruleset with no bypass actors blocks update and deletion of `refs/tags/v3.0.0`; retain the pre/post-publication guard and ref readbacks.
- Confirm `git diff --check f80c05c4b79e069ee3a35db3c09a8f870bca0b59...HEAD` has no whitespace errors across the complete v3.0.0 release change range.
- Confirm `git status --short` is clean after the checkpoint commit.
- Do not push, tag, or publish until the maintainer explicitly approves the release.
- Do not substitute a locally built archive for the tagged, attested workflow artifact.
- V3 preserves V1 and V2 history; orphan commits, force-push, tag replacement, and release replacement are outside this release.

## Release Evidence To Save

- Validation command outputs.
- Independent review score and findings.
- Checkpoint commit hash.
- PR URL, GitHub Actions URL, release URL, and repository metadata update notes after publication.
- Known limits: Windows-first scripts, Codex managed hooks require restart-time Live verification, automated validation does not install into a real global Codex configuration, and same-user guardrails are cooperative rather than an adversarial sandbox.

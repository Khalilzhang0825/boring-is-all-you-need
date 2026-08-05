# Boring Is All You Need Tools

All commands target Windows PowerShell 5.1.

```powershell
.\tools\install.ps1
.\tools\install.ps1 -Apply
.\tools\install.ps1 -Apply -ReplaceExistingWorkflow
# Paste the exact $SteadyAgentRoot and $ReceiptPath assignments printed by a successful Apply.
if (-not (Test-Path variable:SteadyAgentRoot) -or -not (Test-Path variable:ReceiptPath)) { throw "Paste the installer's exact audit assignments first." }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\rollback.ps1" -ReceiptPath $ReceiptPath
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\rollback.ps1" -ReceiptPath $ReceiptPath -Apply
if ([string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { throw "Run this audit from a newly started Codex task." }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-index.ps1" -ThreadId $env:CODEX_THREAD_ID
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\diagnose-install.ps1" -ReceiptPath $ReceiptPath -RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity
.\tools\test-v2-migration.ps1
.\tools\test-agent-hooks.ps1
.\tools\test-git-checkpoint.ps1
.\tools\test-pre-commit.ps1
.\tools\skill-index.ps1
.\tools\skill-search.ps1 -Query "code review"
.\tools\test-skill-catalog.ps1
.\tools\test-protected-path-policy.ps1
.\tools\test-local-equivalence.ps1
.\tools\validate-release-readiness.ps1
.\tools\validate-release-archive.ps1
```

`install.ps1` is dry-run by default. Apply must run non-elevated and fails closed if the current token cannot update a target; it never requests UAC or changes ACLs. The loaded installer verifies the canonical 52-source `package-assets.sha256` digest before staging. Custom roots are isolated-test-only: both `STEADYAGENT_TEST_MODE=1` and an existing `STEADYAGENT_TEST_ROOT` below the system temp directory, named exactly `steadyagent-v2-migration-<32 lowercase hex>`, are required. The package source, target, Codex, managed-config, backup, explicit Git-config, and invoked tool paths must stay inside that test root and remain pairwise disjoint where required.

A successful Apply prints `Backup and rollback receipt:` followed by exact `$SteadyAgentRoot` and `$ReceiptPath` assignments. Preserve and paste those assignments; do not reconstruct a backup path. If the successful output was lost after the transaction reached `applied`, rerun `tools\install.ps1` without `-Apply` from the same verified extracted release package. The already-installed path resolves the unique integrity-valid active receipt pointer and reprints the assignments with zero writes. An interrupted `applying` transaction has no active applied pointer: use its already-printed recovery receipt instead.

`rollback.ps1` is dry-run by default and refuses elevated execution. It recovers both `applied` receipts and exact mixed states recorded by a durable `applying` receipt. Exact means managed-file byte content/existence plus the recorded Git value/config bytes; ACLs, owners, attributes, timestamps, and alternate data streams are not captured or restored. If an early hard stop occurred before the installed copy existed, the same verified release-package script is accepted only when its hash matches the receipt's expected rollback bytes. Receipt hashes prove integrity, not identity; rollback binds production destinations to the active non-elevated installation contract.

Before its first controlled write, rollback durably records its entering state in
`rollback-journal.json`. Exit code 3 or `rollback_incomplete` requires manual
reconciliation; preserve all receipt, backup, journal, target, and Git evidence
and do not blindly retry.

`git-checkpoint.ps1` requires an empty real index and either explicit repository-relative `-Files` or a deliberate human-operated `-All`. Both modes stage into an isolated index and quarantined object directory, run the protected-path, staged-blob-size, and pre-commit gates, recheck exact scope and staged objects, and only then publish the required objects, commit, and complete index through compare-and-swap. A blocked pre-publication transaction removes its quarantine without writing candidate objects into the repository object store. The Codex command guard blocks agents from invoking blanket `-All`; it remains available for a human-approved initial checkpoint outside that tool path.

Checkpoint fault injections require `STEADYAGENT_TEST_MODE=1` plus an existing
system-temp `STEADYAGENT_TEST_ROOT` named
`steadyagent-git-checkpoint-<32 lowercase hex>`. Repository, common/worktree Git
directories, object store, index, and injection payload paths are validated
inside that root before transaction recovery.

After restarting Codex Desktop, open a new task and run `skill-index.ps1` with that task's `CODEX_THREAD_ID`. `diagnose-install.ps1` then checks the installed package, configured Codex matrix, and internally consistent rollout-file catalog. Pass the successful migration receipt with `-ReceiptPath`; `-RequireInstalledBytes` verifies all 53 installed hashes, `-RequireHooksActive` requires the managed matrix, `-RequireRuntimeCatalog` checks `rollout-file-confirmed` evidence, and `-RequireGitIdentity` verifies checkpoint identity. The strict catalog gate requires the owning task `session_meta` timestamp to be strictly later than the receipt `completed_utc`; missing, invalid, old-task, or inherited-only timing fails closed. The strict command intentionally warns that manual Hook observations in the real new task are still required for Live acceptance.

`skill-index.ps1` discovers and fully parses the owning rollout once, accepts only advertised skill entries, and publishes an immutable `rollout-file-confirmed` snapshot. The snapshot freezes the canonical rollout path, Windows file identity, bounded evidence-prefix digest, owning `session_meta` digest, skills-block digest, host, thread, prompt, and skill digest. `skill-search.ps1` then opens that bound path directly: it verifies the pinned file identity and frozen prefix, and parses only newly appended lines that can change session or skills evidence. It does not recursively rediscover the sessions tree or reparse the growing JSONL on each normal search. Replacement, truncation, prefix drift, distinct appended skills evidence, or appended session identity evidence fails closed; normal unrelated growth and a repeated identical skills block remain valid. Search prints a copyable absolute `SKILL.md` path for every match and emits no partial result if any matched path is not an existing absolute `SKILL.md` file. Neither production nor fixture catalogs count as current-host or Live evidence.

`test-skill-catalog.ps1` is deterministic by default and uses an isolated synthetic `CODEX_HOME`. Set `STEADYAGENT_RUN_ROLLOUT_FILE_CANARY=1` to append a check against the current Codex rollout file; that optional canary requires `CODEX_THREAD_ID`, remains file evidence rather than Live acceptance, and is not part of the repository or GitHub Actions release gate.

`test-local-equivalence.ps1` validates all 23 mappings, executes every bound semantic suite, performs an isolated real installation, and compares the receipt with the authoritative 23 mapped plus 30 support destination closure (53 installed entries) plus 27 removals (80 total receipt entries). It first proves that source-hash, semantic-gate, and support-substitution mutations make the gate fail.

`validate-release-readiness.ps1` is the Git-aware clean tag-checkout gate. `validate-release-archive.ps1` is the no-Git counterpart used from the exact extracted release root; it is a release-only tool and is not installed into `TargetRoot`. It verifies the 52-source package closure, PowerShell/encoding and local-link contracts, then runs the portable behavior suites.

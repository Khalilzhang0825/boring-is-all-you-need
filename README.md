# Boring Is All You Need

<p align="center">
  <img src="assets/boring-is-all-you-need-logo.png" width="180" alt="Boring Is All You Need logo">
</p>

**Make agent work boring. Ship with evidence, not vibes.**

Boring Is All You Need `v3.0.0` is a local-first Codex Desktop harness for Windows. It replaces an existing Codex workflow with one small, recoverable loop: understand, plan, test, change, verify, review real risk, and checkpoint explicit files.

“Boring” is the feature. An agent should not improvise permissions, silently broaden scope, declare success from vibes, or leave a half-applied workflow behind. This project turns those decisions into deterministic scripts, receipts, hashes, rollback paths, and release gates.

[中文说明](README.zh-CN.md)

## Why this is better than V1

| Area | Legacy SteadyAgent v1 | Boring Is All You Need v3 |
| --- | --- | --- |
| Supported host | Codex plus Claude surfaces | Codex Desktop only, with one auditable contract |
| Always-on runtime | More event-specific hooks | Exactly three blocks: `SessionStart`, unified `PreToolUse`, `PreCompact` |
| Installation | Generated workflow files | Dry-run-first transaction with conflict detection, snapshots, receipt, atomic apply, and rollback |
| Git checkpoint | Scoped commit helper | Isolated index and object quarantine, staged-object validation, locks, ref/index CAS, and crash recovery |
| Review policy | Could be triggered by change size | Triggered by explicit review requests or material risk, not file count |
| Verification | Host-shape and smoke validation | 52-source trust manifest, 23-item equivalence map, negative mutations, clean-clone and no-Git archive gates |
| Release proof | Local release checks | Exact-tag Windows workflow, SHA-256 sidecar, machine-readable provenance, attestation, and draft-only publication |

## What you gain in real work

This is not a bigger prompt that asks Codex to “be careful.” It is a small execution and evidence layer around the work Codex already does.

| Advantage | Why it is practical |
| --- | --- |
| **Lightweight by design** | The live path contains only three Hook blocks. A matched tool event starts one unified guard process, SessionStart stays below an 800-character ceiling, and heavyweight equivalence/release tests never run during ordinary prompts. |
| **Authorized by the user, not vetoed twice** | Install and rollback preview before writing; both ordinary and elevated PowerShell are supported; nested command/file inputs are inspected and logged best-effort without a Hook deny; destructive or external actions still require explicit authority in the working contract. |
| **Non-invasive** | The workflow preserves unrelated and untracked files, refuses to absorb an existing staged index into a checkpoint, commits explicit paths, and chains an existing executable repository-local pre-commit Hook. |
| **Recoverable** | Migration snapshots, a durable receipt, atomic replacement, a rollback journal, and exact before/after hashes turn a partial install or hard stop into a classified recovery problem instead of guesswork. |
| **Evidence-driven** | “Implemented,” “tests passed,” “pushed,” and “Live after restart” are separate states. The harness asks for a reproduction or red check, the narrowest green check, and concrete Git/runtime evidence before claiming the corresponding result. |
| **Context-resilient** | Before compaction, current goals, decisions, remaining work, and prohibitions are written to project state; after compaction, Codex reloads that state instead of trusting a vague summary. |

The practical effect is less cleanup and fewer false-finish messages. These examples are illustrative behavior contracts, not claims that every model response will use identical wording.

### Example: “Fix the bug and commit it”

**Without the harness:**

```text
Fixed the issue and committed the changes.
Tests pass.
```

That answer may hide whether the bug was reproduced, which tests ran, whether unrelated staged files were included, and whether the commit actually exists.

**With Boring Is All You Need:**

```text
Cause: the empty input reaches parseConfig() without the required default.
Changed: src/config.ts and tests/config.test.ts only.
Verified: focused regression 12/12; typecheck passed.
Git: checkpoint 8f31c2a created; pre-existing notes.md remains untracked.
Remaining risk: the Windows integration suite was not run on this Linux host.
```

The useful difference is not verbosity. It is that scope, evidence, residual risk, and Git state are explicit and independently checkable.

### Example: “Clean this up and push it”

| Moment | Without a harness | With Boring Is All You Need |
| --- | --- | --- |
| Before editing | May start rewriting immediately | Inspects repository instructions, branch, dirty state, `.gitignore`, and the failure evidence first |
| During editing | May broaden into adjacent refactors | Keeps the smallest change that closes the stated goal and preserves unrelated work |
| Before commit | May use blanket staging | Rechecks the diff and checkpoints an explicit file list through an isolated index |
| Before push | May treat “continue” as permission | Pushes only when the user explicitly authorizes push/sync/release |
| Final report | “Done” | Separates changed, locally verified, committed, pushed, released, and post-restart Live states |

### Example: a risky command hidden inside a parallel tool call

Without recursive inspection, a risky leaf can be missed when it is nested in a batch payload. The unified `PreToolUse` Hook walks both command and file leaves, including nested parallel calls. The standard managed installation runs it in Audit mode: recognized risks are recorded best-effort, but even malformed or unknown relevant payloads do not produce a deny decision. The audit record keeps only a fixed reason, normalized tool name, and input SHA-256 instead of the raw potentially sensitive command.

Deletion authorization and runtime path verification remain agent/user decisions rather than claims inferred by the Hook. This means an authorized recursive delete, normal directory rename, ordinary `git push`, or file edit is not rejected by a second Hook policy in the standard managed runtime.

Maintainers who want deterministic command blocking can explicitly opt into `-EnforcementMode Enforce`. In that optional mode, canonical PowerShell `Remove-Item` may recurse with exactly one verified `-LiteralPath`; strict literal and same-command single-assignment variable forms are accepted, while ambiguous or protected targets fail closed.

## Local validation snapshot

The v3.0.0 release candidate is validated on PowerShell 7.6.4 on 2026-08-10 from a clean committed tree. The aggregate entrypoint is `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1`; the exact-tag workflow reruns the same gate plus the extracted `git archive` validation before it can create a draft release.

| Gate | Result |
| --- | ---: |
| Complete release readiness | `153/0` |
| Installed local-postimage equivalence | `430/0` |
| Transactional migration and rollback | `344/0` |
| Crash-recoverable Git checkpoint | `333/0` |
| Managed Hook behavior | `294/0` |
| Runtime skill catalog | `69/0` |
| Release workflow state machine | `43/0` |
| Exact no-Git release archive | `33/0` |

The daily runtime remains deliberately small: one unified `PreToolUse` PowerShell process per matched event and a SessionStart payload around 610 characters with an enforced 800-character ceiling. On the v3.0.0 candidate, `tools\test-agent-hooks.ps1` measured five end-to-end cold starts at a 1,425.6 ms median and 1,726.7 ms maximum on the maintainer's machine, including PowerShell 7 process startup; this is not a cross-machine latency guarantee. Heavy equivalence and archive suites run only in maintainer/CI release gates, not during ordinary prompts.

These are local clean-commit release-candidate results, not a claim that GitHub Actions, attestation, or a user's post-restart Codex runtime is Live. The release workflow and the post-install diagnosis below establish those separate layers.

GitHub-hosted Windows runners execute with an administrator token. Install, rollback, and CI fixtures therefore exercise the same supported elevated-token path; isolated custom fixture roots still require `STEADYAGENT_TEST_MODE=1` and a strict system-temp test root.

## What changed in 3.0.0

- Codex Desktop is the only supported host.
- The runtime is reduced to exactly three managed hook blocks: one `SessionStart`, one audit-only unified `PreToolUse` inspection, and one `PreCompact`.
- `UserPromptSubmit`, `PermissionRequest`, and `PostToolUse` are not installed.
- File count alone no longer triggers independent review.
- One unified command/file Hook recursively inspects both kinds of leaf in nested parallel calls, starts one PowerShell process per matched event, and never returns a deny decision in the standard managed Audit mode.
- Guard logs contain only a fixed reason, normalized tool name, and input SHA-256.
- Git checkpointing uses an isolated index and object quarantine, explicit files, staged-object and scope revalidation, and a single-writer lock.
- The checkpoint CLI retains the maintainer workflow's deliberate `-All` option for a human-approved initial checkpoint; the standard managed audit Hook does not grant that authority, so agents still require the working contract's explicit scope.
- Installation and V1 migration are transactional: preview, conflict detection, backup, atomic apply, verification, receipt, and rollback.
- The loaded installer anchors a canonical 52-source `package-assets.sha256` manifest and installs only the once-read bytes that match it.
- Apply and rollback support either an ordinary or elevated token. They use only the token that launched them and never request UAC, change ACLs, or take ownership.
- A versioned V1-owned-file manifest removes the old Codex release surface during authorized replacement and restores it from the same receipt if rolled back.
- A frozen 23-item equivalence manifest maps every Codex-active capability in the maintainer's reviewed local postimage to a portable public source and installed destination. The local Hook smoke item separately freezes 63 retained assertions and ten explicit Claude, removed-event, or removed-Caveman-behavior exclusions; it is scoped equivalence, not a claim that V3 republishes the excluded V1 surfaces.
- Thread-bound skill indexing and search are included without publishing the maintainer's runtime catalog, session IDs, or private paths.
- SessionStart emits only portable lesson headings, due 90-day Harness maintenance reminders, and resume/compact state. It does not inject Caveman behavior. A fresh install uses the installed context Hook mtime as its first review baseline instead of warning immediately.

## Why Codex only

V3 supports Codex Desktop only. One host gives the project one runtime contract that can be tested completely; other agent hosts and their runtime, template, settings, and Hook surfaces are outside the V3 support and installation contract.

Separately, the maintainer reports that Anthropic suspended their account. That vendor-lock-in lesson reinforced the scope decision; one support matrix is enough tuition.

Historical V1 and V2 releases remain in Git history. The V3 archive retains only the V1 migration tombstones and explicit excluded-assertion evidence needed to prove replacement and scoped equivalence; it does not install or support a Claude runtime, templates, settings, or Hooks.

## Why some technical names still say `steadyagent`

The public product and repository are Boring Is All You Need. The installed root `$HOME\.steadyagent`, `STEADYAGENT_*` test variables, receipt schema, mutex names, and `steadyagent-workflow` skill identifier remain stable compatibility identifiers. Keeping them lets an existing V1 installation be detected, replaced, audited, and rolled back without creating a second installation beside it. They are not a second product or a second runtime.

## Verify the release before running it

Once v3.0.0 is published, the supported release input will be the `boring-is-all-you-need-v3.0.0.zip` asset attached to that GitHub release. Three least-privilege GitHub Actions jobs build and no-Git-validate it from the exact `v3.0.0` tag, attest the reviewed archive digest, and create the draft release. A retry accepts only a non-prerelease draft whose reviewed-commit body and three asset files are byte-exact; post-create ref-race cleanup is limited to the release ID created by that run.

Download the archive, checksum, and machine-readable provenance assets, then run this copyable verification before extracting or running `install.ps1`:

```powershell
gh attestation verify --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI does not provide attestation verification." }
gh release download v3.0.0 -R Khalilzhang0825/boring-is-all-you-need -p "boring-is-all-you-need-v3.0.0.*"
if ($LASTEXITCODE -ne 0) { throw "Could not download the exact v3.0.0 release assets." }
$Provenance = Get-Content -Raw .\boring-is-all-you-need-v3.0.0.provenance.json | ConvertFrom-Json
$ReviewedSha = [string]$Provenance.reviewedCommit
$Expected = (Get-Content -Raw .\boring-is-all-you-need-v3.0.0.zip.sha256).Split(" ")[0].Trim()
$Actual = (Get-FileHash .\boring-is-all-you-need-v3.0.0.zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ([int]$Provenance.schemaVersion -ne 1 -or
    [string]$Provenance.releaseTag -cne "v3.0.0" -or
    $ReviewedSha -notmatch '^[0-9a-f]{40}$' -or
    [string]$Provenance.archiveName -cne "boring-is-all-you-need-v3.0.0.zip" -or
    [string]$Provenance.archiveSha256 -cne $Actual -or
    $Expected -cne $Actual -or
    [string]$Provenance.sourceRepository -cne "Khalilzhang0825/boring-is-all-you-need" -or
    [string]$Provenance.sourceRef -cne "refs/tags/v3.0.0" -or
    [string]$Provenance.signerWorkflow -cne "Khalilzhang0825/boring-is-all-you-need/.github/workflows/release.yml") {
  throw "Release provenance or digest mismatch."
}
gh attestation verify .\boring-is-all-you-need-v3.0.0.zip `
  -R Khalilzhang0825/boring-is-all-you-need `
  --signer-workflow Khalilzhang0825/boring-is-all-you-need/.github/workflows/release.yml `
  --source-ref refs/tags/v3.0.0 `
  --source-digest $ReviewedSha
if ($LASTEXITCODE -ne 0) { throw "Release attestation verification failed; do not extract or run this archive." }
Expand-Archive .\boring-is-all-you-need-v3.0.0.zip .\boring-is-all-you-need-v3.0.0-release
Set-Location .\boring-is-all-you-need-v3.0.0-release\boring-is-all-you-need-v3.0.0
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-archive.ps1 -IntegrityOnly
```

`-IntegrityOnly` is the ordinary-user quick gate: it checks the exact release inventory, package manifest and hashes, PowerShell 7.5+ parsing and strict UTF-8 encoding, Hook file format, local documentation links, and the Codex-only archive boundary. CI and maintainers run the default command without this switch as the full release gate, including the heavier behavioral, runtime, equivalence, and whitespace suites.

This requires a current [GitHub CLI](https://cli.github.com/), an authenticated or public GitHub API connection, and a `gh` build that exposes `attestation verify`. The signed attestation and independently downloaded provenance asset bind the archive to its GitHub repository, exact signer workflow, tag ref, reviewed commit, and SHA-256; the release body displays that same commit. They do not prove the code is vulnerability-free. If verification is unavailable or fails, treat the download as untrusted and do not run it.

## Safety first

> **Installation environment:** the commands below support both ordinary and administrator PowerShell, including Codex tasks configured with `[windows] sandbox = "elevated"`. The scripts do not request UAC, change ACLs, or take ownership; the active token must already be able to update every destination.

The installer is dry-run by default:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1
```

It shows every destination, existing conflict, managed Hook replacement, and Git Hook change with zero target, config, backup, receipt, or state writes. Dry-run renders into an ephemeral system-temp staging directory and removes it on normal exit; an interrupted process can leave only that staging directory behind.

After reviewing the plan, perform a fresh installation:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply
```

To upgrade a verified v2.0.2 installation in place, review the default dry-run first, then explicitly authorize replacement:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply -ReplaceExistingWorkflow
```

Direct receipt-bound upgrade from v2.0.0 or v2.0.1 is not supported. Use that installed release's `rollback.ps1` with its active receipt, verify the restoration, and then perform a fresh v3.0.0 installation; preserve the receipt and backup evidence.

To replace an existing legacy SteadyAgent v1 or custom Codex workflow:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply -ReplaceExistingWorkflow
```

Run these commands from either ordinary or administrator PowerShell. Boring Is All You Need no longer rejects an elevated Apply or rollback. The scripts still never trigger UAC, change ACLs, or take ownership, so the active token must already be able to update `%ProgramData%\OpenAI\Codex\requirements.toml` and the other planned destinations. `managed` describes the Codex configuration mechanism, not protection against malicious software running as the same user.

The installer:

1. verifies the canonical package manifest, reads each trusted source byte sequence once, and renders the portable package for the current machine;
2. validates every source and destination before writing;
3. blocks unknown existing differences unless replacement was explicitly authorized;
4. durably snapshots every existing target and the previous Git Hook path, then writes and prints an `applying` recovery receipt before the first target or Git write;
5. backs up and removes known V1-owned files from the old Codex location;
6. applies files atomically under a machine-wide Boring Is All You Need migration mutex;
7. verifies every write and the complete final plan;
8. restores all changed targets if any step fails;
9. durably advances the machine-readable `migration-receipt.json` to `applied`.

It does not change the user's model or reasoning settings.

The installed global `core.hooksPath` runs the project's staged-file guard first and then chains an executable repository-local `.git/hooks/pre-commit` when one exists. A differing pre-existing global `core.hooksPath` is still a reviewed replacement conflict: use `-ReplaceExistingWorkflow` only after inspecting the dry-run, and use the receipt to restore it.

Use the installed rollback tool and the receipt path printed by the installation:

```powershell
$SteadyAgentRoot = Join-Path $HOME ".steadyagent"
$ReceiptPath = Read-Host "Paste the exact path printed after 'Recovery receipt:' by install.ps1"
if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "The printed recovery receipt path is invalid." }
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\rollback.ps1" -ReceiptPath $ReceiptPath
# After reviewing the preview, run from the same PowerShell session:
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\rollback.ps1" -ReceiptPath $ReceiptPath -Apply
```

Rollback may run from either an ordinary or administrator PowerShell session. If the process was hard-stopped before the installed rollback copy existed, run `tools\rollback.ps1` from the same verified extracted release package instead; the `applying` receipt binds that script's exact installed hash. Rollback classifies every target and the active Git Hook path as exact original or exact post-install state before writing. Any third state, receipt drift, or snapshot drift stops with zero writes; a valid mixed state transactionally restores managed-file byte content and existence plus the recorded `core.hooksPath` value and fixture Git-config bytes. The migration does not capture or restore ACLs, owners, file attributes, timestamps, or alternate data streams.

Rollback publishes a durable `rollback-journal.json` before its first file or
Git change, so a hard stop can resume or compensate deterministically. If it
reports exit code 3 or projects `rollback_incomplete`, preserve the receipt,
backup, journal, current targets, and Git configuration. Do not edit them or
blindly retry; manual reconciliation against the recorded hashes is required.
Test-only migration roots must be named
`steadyagent-v2-migration-<32 lowercase hex>` under the system temp directory.

## After installation

Restart Codex Desktop, open a new Codex task, and ask Codex to run the following block in that task's terminal. Do not paste it into an unrelated PowerShell session: the skill index must bind to the new task's `CODEX_THREAD_ID`. The block first verifies that identity, then requires Hooks, runtime catalog, and Git identity:

```powershell
$SteadyAgentRoot = Join-Path $HOME ".steadyagent"
$ReceiptPath = Read-Host "Paste the exact path printed after 'Recovery receipt:' by install.ps1"
if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "The printed recovery receipt path is invalid." }
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
if ([string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { throw "Run this audit from a newly started Codex task." }
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-index.ps1" -ThreadId $env:CODEX_THREAD_ID
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\diagnose-install.ps1" -ReceiptPath $ReceiptPath -RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity
```

The catalog tools default to
`Join-Path $SteadyAgentRoot "runtime-skill-catalogs"` by deriving the install
root from their own `tools` directory.

Expected result:

```text
WARN manual Codex Live acceptance is still required
RESULT pass=<n> warn=1 fail=0
```

The diagnosis verifies installed assets, empty user hooks, the exact three-block managed matrix with one unified `PreToolUse`, every known V1-owned Codex file is absent, rendered paths, the active Git Hook path, and the installed Hook smoke suite. `-RequireRuntimeCatalog` validates only an internally consistent `rollout-file-confirmed` catalog bound to `CODEX_THREAD_ID`; it does not prove current-host or Live activation. Restart Codex Desktop, open a real new task, and observe SessionStart plus one controlled Hook behavior to establish Live acceptance.

## Daily workflow

```text
understand -> plan -> red check -> smallest change -> green check -> review when risk requires it -> checkpoint
```

Boring Is All You Need instructs Codex to:

- inspect the repository before editing;
- diagnose before fixing;
- preserve unrelated work;
- run the narrowest relevant validation;
- call a fresh reviewer only for explicit review requests or material risk;
- checkpoint only explicit files;
- avoid push, publish, deployment, migration, installation, and destructive actions without authorization;
- preserve task state before compaction and restore it afterward.

## Main commands

| Command | Purpose |
| --- | --- |
| `tools/install.ps1` | Dry-run or transactionally migrate the Codex workflow. |
| `tools/rollback.ps1` | Dry-run or transactionally restore a completed migration receipt. |
| `tools/diagnose-install.ps1` | Verify installed assets and active Codex managed hooks. |
| `tools/test-v2-migration.ps1` | Exercise fresh install, replacement, conflict, and rollback fixtures. |
| `tools/test-agent-hooks.ps1` | Verify SessionStart, guards, logs, and PreCompact behavior. |
| `tools/test-git-checkpoint.ps1` | Verify explicit-file and deliberate all-scope checkpoint transactions. |
| `tools/test-pre-commit.ps1` | Verify staged secret and oversized-blob protection. |
| `tools/skill-index.ps1` | Build a host-, thread-, prompt-, and digest-bound runtime skill catalog. |
| `tools/skill-search.ps1` | Search only a `rollout-file-confirmed` catalog bound to the current task identity; this does not prove current-host or Live activation. |
| `tools/test-local-equivalence.ps1` | Prove the 23/23 local-to-public mapping, including a deliberate red mutation. |
| `tools/validate-release-readiness.ps1` | Run the complete public V3 release gate. |
| `tools/validate-release-archive.ps1` | Validate the exact extracted release asset without requiring `.git`; users select `-IntegrityOnly`, while CI and maintainers run the full default gate. |

## Runtime architecture

| Layer | Responsibility |
| --- | --- |
| `templates/codex/AGENTS.md` | Short always-on Codex contract. |
| `rules/` | Progressive workflow, verification, review, skill, context, and safety rules. |
| `tools/hooks/` | Audit-only managed command/file inspection with optional enforcement, SessionStart state injection, and PreCompact reminder. |
| `tools/git-checkpoint.ps1` | Scoped and recoverable local commits. |
| `tools/git-hooks/` | Global pre-commit defense. |
| `tools/skill-*.ps1` | Portable runtime skill catalog publication and search. |
| `manifests/local-postimage-equivalence.json` | Frozen 23-item local-to-public capability contract. |
| `skills/steadyagent-workflow/` | Explicit reusable Boring Is All You Need workflow skill. |
| `tools/install.ps1` | Portable renderer and transactional migration engine. |
| `tools/rollback.ps1` | Receipt-bound, drift-aware transaction reversal. |

Hooks reduce common mistakes but are not a complete security sandbox. Human authorization and repository-specific validation remain necessary.

## Release validation

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

The release gate checks PowerShell 7.5+ syntax and runtime identity, public paths and secrets, Codex-only assets, documentation links, migration fixtures, Hook behavior, checkpoint/pre-commit behavior, runtime skill catalogs, the 23/23 equivalence contract with red-to-green proof, fresh installation, installed diagnosis, and release metadata.

## Compatibility

- Windows 10/11
- PowerShell 7.5 or newer (`pwsh.exe`)
- Codex Desktop managed hooks
- Git for Windows

Windows PowerShell 5.1, Linux, macOS, other coding agents, and Anthropic products are not part of the V3 support contract.

## License

MIT. See [LICENSE](LICENSE).

# Boring Is All You Need Harness Guide

This guide describes the installed Codex-only workflow surface. It is a runtime
reference, not proof that a particular Codex Desktop process has reloaded the
managed configuration.

## Runtime layers

1. `%ProgramData%\OpenAI\Codex\requirements.toml` registers exactly three managed
   Hook blocks: one `SessionStart`, one audit-only unified `PreToolUse`, and one `PreCompact`.
2. `AGENTS.md` provides the short always-on operating contract.
3. `rules\` contains progressive workflow, verification, review, context,
   safety, and skill-routing rules.
4. `tools\hooks\` contains audit-only managed command and file inspection with
   optional enforcement, state injection, and compaction reminders.
5. `tools\git-checkpoint.ps1` creates scoped local checkpoint commits through an
   isolated index and explicit file list.
6. `tools\git-hooks\` provides staged secret and oversized-blob checks.
7. `tools\skill-index.ps1` and `tools\skill-search.ps1` create and query a
   thread-bound catalog from the skills advertised in the active Codex rollout.
8. SessionStart reports Caveman lite, injects headings from `rules\lessons.md`,
   and emits a review reminder when `.harness-last-review` is invalid or at
   least 90 days old. A fresh install without the marker uses the installed
   context Hook mtime as its first 90-day baseline.

## Normal workflow

```text
understand -> plan -> red check -> smallest change -> green check
           -> risk-triggered review -> explicit-file checkpoint
```

- Diagnose before fixing.
- Preserve unrelated work.
- Use the narrowest meaningful validation, then expand in proportion to risk.
- Independent review is required when the user asks for it or when a concrete
  material risk has been identified; file count alone is not a trigger.
- Push, publish, deployment, installation, migration, and destructive actions
  require explicit authorization.

## Rollout-file skill catalog

The catalog is derived only when every complete `skills_instructions` block in
one captured rollout read normalizes to the same content. Missing, incomplete,
or distinct blocks fail closed; inherited parent history never changes the
owning thread or host. The publisher binds every snapshot to the host and
thread claimed by that file, plus prompt SHA-256 and canonical skill digest.
Production output is labeled `rollout-file-confirmed`; it proves internal file
consistency, not current host activation. A custom rollout or catalog is
accepted only in explicit fixture mode and never becomes Live evidence.

```powershell
$SteadyAgentRoot = Join-Path $HOME ".steadyagent"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-index.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-search.ps1" -Query "code review"
```

Rollout-file catalog snapshots are generated data under
`Join-Path $SteadyAgentRoot "runtime-skill-catalogs"`; they are not distributed
in the package. By default, each catalog tool derives that location from the
parent of its installed `tools` directory. `-CatalogRoot` remains available as
an explicit override.

## Validation and evidence boundaries

Run the installed diagnosis after restarting Codex Desktop:

```powershell
$SteadyAgentRoot = Read-Host "Paste the exact SteadyAgentRoot path printed by install.ps1"
$ReceiptPath = Read-Host "Paste the exact migration receipt path printed by install.ps1"
if (-not (Test-Path -LiteralPath "$SteadyAgentRoot\tools\diagnose-install.ps1" -PathType Leaf)) {
    throw "The installed diagnosis tool was not found under SteadyAgentRoot."
}
if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
    throw "The migration receipt was not found."
}
if ([string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) {
    throw "Run this cold strict audit from a newly started Codex task."
}
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-index.ps1" -ThreadId $env:CODEX_THREAD_ID
if ($LASTEXITCODE -ne 0) { throw "The task-bound skill catalog could not be built." }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\diagnose-install.ps1" -ReceiptPath $ReceiptPath -RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity
if ($LASTEXITCODE -ne 0) { throw "Strict installed diagnosis failed." }
```

Repository tests, fixture tests, and strict diagnosis prove package,
configuration, and rollout-file consistency. They do not prove that a Codex
Desktop process reloaded its managed Hook configuration. Only behavior observed
in a real post-restart Codex task can establish that Live fact.

## Recovery

Before compaction, write objective, decisions, progress, next step, remaining
validation, and forbidden actions to `PROJECT_STATE.md` or
`.agent\state.md`. After compaction, treat the summary as a cache and restore
from that state file and repository facts.

Installer and rollback operations are dry-run by default. Apply only after
reviewing the preview, and use either ordinary or administrator PowerShell.
Both tools accept elevated execution without requesting UAC; they
never request UAC, change ACLs, or take ownership. Before its first target or
Git write, Apply durably writes and reads back original snapshots plus an
`applying` receipt. After a hard interruption, rollback accepts only exact
original/post-install mixed state and refuses any third state before writing.
If the installed rollback copy does not yet exist, use the same verified
extracted release package. The transaction receipt binds its expected script and recovery
bytes, but receipt hashes prove integrity, not identity.

## Periodic maintenance

Run `rules\harness-review.md` every three to six months or after a material
model/runtime change. It covers the lessons inbox, rule and skill pruning,
180-day runtime catalog inventory, MCP allowlists, privacy-preserving log
metadata, cache candidates, and model/effort review. It never authorizes
automatic deletion, model changes, or external writes.

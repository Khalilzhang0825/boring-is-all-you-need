# Harness Review and Maintenance

Run this review every three to six months, after a material model/runtime
change, or when SessionStart emits `[HARNESS-REVIEW DUE]`. Its purpose is to
remove configuration written for old models or one-off failures before that
configuration becomes drag.

Let `SteadyAgentRoot` mean the production installation root
`Join-Path $HOME ".steadyagent"`. Production installation does not accept a
custom root. After completing the review, write the current UTC date as
`yyyy-MM-dd` to `Join-Path $SteadyAgentRoot ".harness-last-review"`.

## 1. Process the lessons inbox

- Review each candidate in the project or user lessons inbox.
- Promote only repeated, general failures with a concrete countermeasure.
- Delete or archive one-off and obsolete candidates only after confirming the
  exact target and recovery boundary.

## 2. Prune lessons

- Remove guidance written only for an obsolete model, tool, or interface.
- Relax or remove rules that now over-constrain the current model.
- Keep title-level reminders concise; preserve detailed evidence in the
  appropriate rule, test, or project record.

## 3. Prune rules and skills

- Merge duplicated or unused rules.
- Identify unused or duplicate skills, but do not archive or remove them
  without explicit user approval and a recovery plan.
- Recheck that skill routing keeps ordinary tasks lightweight and top-level
  orchestration explicit.
- Rebuild the runtime catalog only from a restarted task's advertised skills;
  an older task cannot claim new Live visibility.
- Run `Join-Path $SteadyAgentRoot "tools\skill-index.ps1"`, then run
  `Join-Path $SteadyAgentRoot "tools\diagnose-install.ps1"` with
  the successful migration `-ReceiptPath`, `-RequireInstalledBytes`, and
  `-RequireRuntimeCatalog`.
- Inventory `Join-Path $SteadyAgentRoot
  "runtime-skill-catalogs\codex-desktop"` read-only: directory count, total
  size, oldest/newest write time, and exact candidates older than 180 days. Do
  not delete automatically.

## 4. Review Harness infrastructure

- Run `tools\test-agent-hooks.ps1` after any Hook change.
- Confirm the active managed configuration is still the exact three-block
  Codex-only matrix with one unified `PreToolUse`.
- Review MCP allowlists and connected capabilities for actual continued need.
- Inspect cache, downloads, and logs by size, age, and metadata only. Do not
  reconstruct raw commands, file contents, or paths from privacy-preserving
  guard audit records.
- Reconsider model and effort settings, but never change them as part of this
  review without explicit authorization.
- Resolve the installed root and successful receipt explicitly, then run the
  strict diagnosis without a path placeholder:

  ```powershell
  $SteadyAgentRoot = Read-Host "Installed SteadyAgent root"
  $ReceiptPath = Read-Host "Successful migration receipt path"
  if ([string]::IsNullOrWhiteSpace($SteadyAgentRoot) -or
      -not (Test-Path -LiteralPath $SteadyAgentRoot -PathType Container)) {
    throw "The installed SteadyAgent root is missing."
  }
  if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or
      -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
    throw "The successful migration receipt is missing."
  }
  if ([string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) {
    throw "Run this audit from a newly started Codex task."
  }
  & (Join-Path $SteadyAgentRoot "tools\skill-index.ps1") `
    -ThreadId $env:CODEX_THREAD_ID
  if ($LASTEXITCODE -ne 0) { throw "Runtime catalog creation failed." }
  & (Join-Path $SteadyAgentRoot "tools\diagnose-install.ps1") `
    -ReceiptPath $ReceiptPath `
    -RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog `
    -RequireGitIdentity
  if ($LASTEXITCODE -ne 0) { throw "Strict diagnosis failed." }
  ```

## 5. Close the review

- Record conclusions, changes, validation, residual risk, and Git state.
- Update `Join-Path $SteadyAgentRoot ".harness-last-review"` with the current UTC
  date.
- Do not push, publish, delete inventories, or mutate external systems without
  explicit authorization.

## Release candidate scoring

For a frozen public release, use fresh read-only reviewers across security,
engineering, and specification. Findings come before scores. Any P0-P3 blocks
release. Every named critical subscore and each axis must be at least 9.5/10;
an average cannot hide a lower score. Reviewers must report commands, limits,
branch, HEAD, worktree, staging, and remote-write status.

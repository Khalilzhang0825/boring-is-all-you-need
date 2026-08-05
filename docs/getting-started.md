# Getting Started with Boring Is All You Need

Boring Is All You Need supports Codex Desktop on Windows.

## 1. Download, verify, and extract the release

Install or update the current [GitHub CLI](https://cli.github.com/), then download and verify the archive, checksum, and machine-readable provenance assets:

The release workflow uses separate least-privilege build/validation, attestation, and draft-creation jobs. A retry accepts only a non-prerelease draft with the exact reviewed-commit body and all three byte-exact assets; ref-race cleanup is bound to the release ID created by that run.

```powershell
gh attestation verify --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI does not provide attestation verification." }
gh release download v2.0.0 -R Khalilzhang0825/boring-is-all-you-need -p "boring-is-all-you-need-v2.0.0.*"
if ($LASTEXITCODE -ne 0) { throw "Could not download the exact v2.0.0 release assets." }
$Provenance = Get-Content -Raw .\boring-is-all-you-need-v2.0.0.provenance.json | ConvertFrom-Json
$ReviewedSha = [string]$Provenance.reviewedCommit
$Expected = (Get-Content -Raw .\boring-is-all-you-need-v2.0.0.zip.sha256).Split(" ")[0].Trim()
$Actual = (Get-FileHash .\boring-is-all-you-need-v2.0.0.zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ([int]$Provenance.schemaVersion -ne 1 -or
    [string]$Provenance.releaseTag -cne "v2.0.0" -or
    $ReviewedSha -notmatch '^[0-9a-f]{40}$' -or
    [string]$Provenance.archiveName -cne "boring-is-all-you-need-v2.0.0.zip" -or
    [string]$Provenance.archiveSha256 -cne $Actual -or
    $Expected -cne $Actual -or
    [string]$Provenance.sourceRepository -cne "Khalilzhang0825/boring-is-all-you-need" -or
    [string]$Provenance.sourceRef -cne "refs/tags/v2.0.0" -or
    [string]$Provenance.signerWorkflow -cne "Khalilzhang0825/boring-is-all-you-need/.github/workflows/release.yml") {
  throw "Release provenance or digest mismatch."
}
gh attestation verify .\boring-is-all-you-need-v2.0.0.zip `
  -R Khalilzhang0825/boring-is-all-you-need `
  --signer-workflow Khalilzhang0825/boring-is-all-you-need/.github/workflows/release.yml `
  --source-ref refs/tags/v2.0.0 `
  --source-digest $ReviewedSha
if ($LASTEXITCODE -ne 0) { throw "Release attestation verification failed; do not extract or run this archive." }
Expand-Archive .\boring-is-all-you-need-v2.0.0.zip .\boring-is-all-you-need-v2.0.0-release
Set-Location .\boring-is-all-you-need-v2.0.0-release\boring-is-all-you-need-v2.0.0
```

Stop if the GitHub CLI does not expose `attestation verify`, the provenance fields do not bind the reviewed commit and archive digest, attestation verification fails, or the checksum differs.

## 2. Validate the extracted archive

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-archive.ps1 -IntegrityOnly
```

This quick integrity-only archive gate does not require `.git`. It checks the release inventory, manifest and hashes, PowerShell parsing and encoding, Hook format, documentation links, and Codex-only boundary. CI and maintainers run the full default archive gate, including the heavyweight behavior, runtime, equivalence, and whitespace suites, and separately run the Git-aware clean release gate from a fresh clone of the tag.

## 3. Preview

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1
```

Dry-run is the default. It writes no target, config, backup, receipt, or state files; it uses ephemeral system-temp staging that is removed on normal exit.

## 4. Apply

Fresh installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply
```

Replace an existing workflow:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply -ReplaceExistingWorkflow
```

Use an ordinary, non-elevated PowerShell window. Apply and rollback refuse an elevated token. If the current user cannot update the default `%ProgramData%\OpenAI\Codex\requirements.toml`, this release reports the machine as unsupported instead of requesting elevation or changing ACLs.

## 5. Restart and diagnose

Restart Codex Desktop, open a new Codex task, and ask Codex to run this block in that task's terminal. The task must expose its own `CODEX_THREAD_ID`:

```powershell
$ReceiptPath = Read-Host "Paste the exact path printed after 'Recovery receipt:' by install.ps1"
if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "The printed recovery receipt path is invalid." }
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
$SteadyAgentRoot = Join-Path $HOME ".steadyagent"
if ([string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { throw "Run this audit from a newly started Codex task." }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-index.ps1" -ThreadId $env:CODEX_THREAD_ID
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\diagnose-install.ps1" -ReceiptPath $ReceiptPath -RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity
```

`-RequireInstalledBytes` binds all 53 installed files to the successful migration receipt. `-RequireRuntimeCatalog` validates only an internally consistent `rollout-file-confirmed` catalog bound to `CODEX_THREAD_ID`; it does not prove current-host or Live activation. A successful strict diagnosis therefore emits `WARN manual Codex Live acceptance is still required`. `-RequireGitIdentity` verifies the checkpoint identity contract. Restart Codex Desktop, open a real new task, and observe SessionStart plus one controlled Hook behavior to establish Live acceptance.

## 6. Roll back if needed

Use the installed rollback tool with the receipt printed before the installation's first target write. Preview first, then apply from the same non-elevated user session:

```powershell
$ReceiptPath = Read-Host "Paste the exact path printed after 'Recovery receipt:' by install.ps1"
if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "The printed recovery receipt path is invalid." }
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath $ReceiptPath
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath $ReceiptPath -Apply
```

Do not elevate rollback. After an early hard stop, the installed copy might not exist; use `tools\rollback.ps1` from the same verified extracted package. Exact original/post-install mixed states are recoverable. A third target state, snapshot drift, receipt drift, or unknown Git Hook state stops before writing.

Rollback publishes `rollback-journal.json` before its first controlled write.
If it exits 3 or reports `rollback_incomplete`, preserve every receipt, backup,
journal, target, and Git artifact and perform manual hash reconciliation; do not
edit evidence or retry blindly.

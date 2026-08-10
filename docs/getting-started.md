# Getting Started with Boring Is All You Need

Boring Is All You Need supports Codex Desktop on Windows.

## 1. Download, verify, and extract the release

Install or update the current [GitHub CLI](https://cli.github.com/), then download and verify the archive, checksum, and machine-readable provenance assets:

The release workflow uses separate least-privilege build/validation, attestation, and draft-creation jobs. A retry accepts only a non-prerelease draft with the exact reviewed-commit body and all three byte-exact assets; ref-race cleanup is bound to the release ID created by that run.

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
```

Stop if the GitHub CLI does not expose `attestation verify`, the provenance fields do not bind the reviewed commit and archive digest, attestation verification fails, or the checksum differs.

## 2. Validate the extracted archive

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-archive.ps1 -IntegrityOnly
```

This quick integrity-only archive gate does not require `.git`. It checks the release inventory, manifest and hashes, PowerShell parsing and encoding, Hook format, documentation links, and Codex-only boundary. CI and maintainers run the full default archive gate, including the heavyweight behavior, runtime, equivalence, and whitespace suites, and separately run the Git-aware clean release gate from a fresh clone of the tag.

## 3. Preview

> **Supported shell:** use either ordinary or administrator PowerShell. A Codex task configured with `[windows] sandbox = "elevated"` is also supported. The active token must already be able to update every destination.

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1
```

Dry-run is the default. It writes no target, config, backup, receipt, or state files; it uses ephemeral system-temp staging that is removed on normal exit.

## 4. Apply

Fresh installation:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply
```

Upgrade a verified v2.0.2 installation, or replace a legacy V1/custom workflow:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply -ReplaceExistingWorkflow
```

Direct receipt-bound upgrade from v2.0.0 or v2.0.1 is not supported. Use that installed release's receipt-bound rollback first, verify restoration, and then perform a fresh v3.0.0 installation. Preserve the receipt and backup evidence.

Use ordinary or administrator PowerShell. Apply and rollback accept an elevated token but do not request UAC, change ACLs, or take ownership. The active token must be able to update the default `%ProgramData%\OpenAI\Codex\requirements.toml`.

## 5. Restart and diagnose

Restart Codex Desktop, open a new Codex task, and ask Codex to run this block in that task's terminal. The task must expose its own `CODEX_THREAD_ID`:

```powershell
$ReceiptPath = Read-Host "Paste the exact path printed after 'Recovery receipt:' by install.ps1"
if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "The printed recovery receipt path is invalid." }
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
$SteadyAgentRoot = Join-Path $HOME ".steadyagent"
if ([string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { throw "Run this audit from a newly started Codex task." }
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-index.ps1" -ThreadId $env:CODEX_THREAD_ID
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\diagnose-install.ps1" -ReceiptPath $ReceiptPath -RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity
```

`-RequireInstalledBytes` binds all 53 installed files to the successful migration receipt. `-RequireRuntimeCatalog` validates only an internally consistent `rollout-file-confirmed` catalog bound to `CODEX_THREAD_ID`; it does not prove current-host or Live activation. A successful strict diagnosis therefore emits `WARN manual Codex Live acceptance is still required`. `-RequireGitIdentity` verifies the checkpoint identity contract. Restart Codex Desktop, open a real new task, and observe SessionStart plus one controlled Hook behavior to establish Live acceptance.

## 6. Roll back if needed

Use the installed rollback tool with the receipt printed before the installation's first target write. Preview first, then apply from the same PowerShell session:

```powershell
$ReceiptPath = Read-Host "Paste the exact path printed after 'Recovery receipt:' by install.ps1"
if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "The printed recovery receipt path is invalid." }
$ReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath $ReceiptPath
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath $ReceiptPath -Apply
```

Rollback supports both ordinary and administrator PowerShell. After an early hard stop, the installed copy might not exist; use `tools\rollback.ps1` from the same verified extracted package. Exact original/post-install mixed states are recoverable. A third target state, snapshot drift, receipt drift, or unknown Git Hook state stops before writing.

Rollback publishes `rollback-journal.json` before its first controlled write.
If it exits 3 or reports `rollback_incomplete`, preserve every receipt, backup,
journal, target, and Git artifact and perform manual hash reconciliation; do not
edit evidence or retry blindly.

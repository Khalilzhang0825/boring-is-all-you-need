# Getting Started with SteadyAgent 2

SteadyAgent 2 supports Codex Desktop on Windows.

## 1. Validate the checkout

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

## 2. Preview

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1
```

Dry-run is the default and writes nothing.

## 3. Apply

Fresh installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply
```

Replace an existing workflow:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply -ReplaceExistingWorkflow
```

Use an elevated PowerShell window when writing the default `%ProgramData%\OpenAI\Codex\requirements.toml`.

## 4. Restart and diagnose

Restart Codex Desktop, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\diagnose-install.ps1" -RequireHooksActive
```

Do not treat installed files or script smoke tests as proof that an old Codex task loaded new managed Hooks. A restarted task and `fail=0` diagnosis are required.

## 5. Roll back if needed

Use the receipt path printed by the installer. Preview first, then add `-Apply`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath "<backup>\migration-receipt.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath "<backup>\migration-receipt.json" -Apply
```

Rollback stops before writing if an installed file, removed V1 path, snapshot, or Git Hook path drifted.

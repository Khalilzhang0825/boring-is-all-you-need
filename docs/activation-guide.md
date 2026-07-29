# Codex Activation and Migration

`install.ps1` is both the asset installer and the Codex managed-Hook activator in V2.

## Dry-run

Run without `-Apply`. Review every destination and conflict. Zero files, Git settings, or managed configuration are changed.

## Authorized transaction

`-Apply` permits a fresh install. `-Apply -ReplaceExistingWorkflow` additionally permits replacement of differing existing targets and `core.hooksPath`.

The transaction stages rendered assets, validates paths, snapshots originals, writes atomically, verifies each write and the complete plan, activates the Git pre-commit path, and emits a rollback receipt. Any failure restores written files and the previous Git Hook path.

During `-ReplaceExistingWorkflow`, the versioned `manifests/v1-codex-owned-files.txt` list is also applied as transactional tombstones. Only exact SteadyAgent V1-owned paths under `CodexHome` are backed up and removed; unknown files are not swept.

## Completed-migration rollback

Run the installed `rollback.ps1` with the generated receipt. It is also dry-run by default; add `-Apply` only after reviewing the full restore/remove plan. The rollback is fail-closed if the receipt, a snapshot, an installed file, or `core.hooksPath` has drifted. Never run a receipt from an untrusted source.

## Managed configuration

The default active target is `%ProgramData%\OpenAI\Codex\requirements.toml`, which normally requires Administrator rights. Tests may use `-ManagedConfigPath`, `-TargetRoot`, `-CodexHome`, `-BackupRoot`, and `-GitConfigPath` to stay isolated.

## Live acceptance

Restart Codex Desktop. Run `diagnose-install.ps1 -RequireHooksActive`, then use a disposable repository to confirm:

- a harmless command proceeds;
- a destructive Git fixture is denied before execution;
- an `.env` edit fixture is denied;
- compact/resume restores a known state marker;
- a low-risk multi-file task does not trigger review only because of file count;
- an explicit review request does trigger a fresh reviewer.

Never run a destructive probe in a real repository.

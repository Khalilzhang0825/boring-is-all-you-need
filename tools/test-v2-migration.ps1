[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Passed = 0
$script:Failed = 0
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$installer = Join-Path $PSScriptRoot "install.ps1"
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("steadyagent-v2-migration-" + [guid]::NewGuid().ToString("N"))

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        $script:Passed++
        Write-Host ("PASS " + $Name)
    }
    else {
        $script:Failed++
        Write-Host ("FAIL " + $Name + $(if ($Detail) { " - " + $Detail } else { "" }))
    }
}

function Invoke-Installer {
    param(
        [string]$CaseRoot,
        [switch]$Apply,
        [switch]$ReplaceExistingWorkflow,
        [int]$InjectFailureAfter = 0,
        [int]$InjectPostWriteFailureAt = 0,
        [string]$InjectTargetMutationPath,
        [string]$InjectGitHooksMutationValue
    )

    $targetRoot = Join-Path $CaseRoot "steadyagent"
    $codexHome = Join-Path $CaseRoot "codex"
    $managedPath = Join-Path $CaseRoot "managed/requirements.toml"
    $backupRoot = Join-Path $CaseRoot "backup"
    $gitConfigPath = Join-Path $CaseRoot "gitconfig"
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installer,
        "-TargetRoot", $targetRoot,
        "-CodexHome", $codexHome,
        "-ManagedConfigPath", $managedPath,
        "-BackupRoot", $backupRoot,
        "-GitConfigPath", $gitConfigPath
    )
    if ($Apply) { $arguments += "-Apply" }
    if ($ReplaceExistingWorkflow) { $arguments += "-ReplaceExistingWorkflow" }
    if ($InjectFailureAfter -gt 0) { $arguments += @("-InjectFailureAfter", [string]$InjectFailureAfter) }
    if ($InjectPostWriteFailureAt -gt 0) { $arguments += @("-InjectPostWriteFailureAt", [string]$InjectPostWriteFailureAt) }
    if ($InjectTargetMutationPath) { $arguments += @("-InjectTargetMutationPath", $InjectTargetMutationPath) }
    if ($InjectGitHooksMutationValue) { $arguments += @("-InjectGitHooksMutationValue", $InjectGitHooksMutationValue) }

    $output = & powershell.exe @arguments
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output | Out-String)
        TargetRoot = $targetRoot
        CodexHome = $codexHome
        ManagedPath = $managedPath
        BackupRoot = $backupRoot
        GitConfigPath = $gitConfigPath
    }
}

function Test-BackupContainsText {
    param([string]$Root, [string]$Expected)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File)) {
        try {
            if ((Get-Content -Raw -LiteralPath $file.FullName) -eq $Expected) { return $true }
        }
        catch { }
    }
    return $false
}

function Invoke-ReceiptRollback {
    param(
        [pscustomobject]$InstallResult,
        [string]$ReceiptPath,
        [string]$InjectTargetMutationPath
    )
    $receiptPath = if ($ReceiptPath) { $ReceiptPath } else { Join-Path $InstallResult.BackupRoot "migration-receipt.json" }
    $installedRollbackTool = Join-Path $InstallResult.TargetRoot "tools\rollback.ps1"
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installedRollbackTool,
        "-ReceiptPath", $receiptPath,
        "-GitConfigPath", $InstallResult.GitConfigPath,
        "-Apply"
    )
    if ($InjectTargetMutationPath) { $arguments += @("-InjectTargetMutationPath", $InjectTargetMutationPath) }
    $output = & powershell.exe @arguments
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output | Out-String)
    }
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

    $dryCase = Join-Path $fixtureRoot "dry"
    $dry = Invoke-Installer -CaseRoot $dryCase
    Assert-True "dry-run exits successfully" ($dry.ExitCode -eq 0) $dry.Output
    Assert-True "dry-run identifies V2 migration" ($dry.Output -match "DRY-RUN SteadyAgent 2[.]0[.]0 migration") $dry.Output
    Assert-True "dry-run performs zero writes" (-not (Test-Path -LiteralPath $dryCase)) $dry.Output

    $freshCase = Join-Path $fixtureRoot "fresh"
    $fresh = Invoke-Installer -CaseRoot $freshCase -Apply
    Assert-True "fresh install succeeds" ($fresh.ExitCode -eq 0) $fresh.Output
    Assert-True "fresh install writes Codex AGENTS" (Test-Path -LiteralPath (Join-Path $fresh.CodexHome "AGENTS.md"))
    Assert-True "fresh install writes empty user hooks" (Test-Path -LiteralPath (Join-Path $fresh.CodexHome "hooks.json"))
    Assert-True "fresh install writes managed config" (Test-Path -LiteralPath $fresh.ManagedPath)
    Assert-True "fresh install writes migration receipt" (Test-Path -LiteralPath (Join-Path $fresh.BackupRoot "migration-receipt.json"))
    $freshHooksPath = & git config --file $fresh.GitConfigPath --get core.hooksPath
    Assert-True "fresh install activates global pre-commit path" ($LASTEXITCODE -eq 0 -and $freshHooksPath -eq (Join-Path $fresh.TargetRoot "tools\git-hooks")) ([string]$freshHooksPath)
    if (Test-Path -LiteralPath $fresh.ManagedPath) {
        $managed = [IO.File]::ReadAllText($fresh.ManagedPath, [Text.Encoding]::UTF8)
        $blockCount = ([regex]::Matches($managed, '(?m)^\[\[hooks[.][A-Za-z]+[.]hooks\]\]$')).Count
        Assert-True "managed config has exact four blocks" ($blockCount -eq 4) ("blocks=" + $blockCount)
        Assert-True "managed config omits high-frequency events" ($managed -notmatch "UserPromptSubmit|PermissionRequest|PostToolUse")
    }
    $installedDiagnose = Join-Path $fresh.TargetRoot "tools/diagnose-install.ps1"
    $diagnoseOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installedDiagnose `
        -TargetRoot $fresh.TargetRoot `
        -CodexHome $fresh.CodexHome `
        -ManagedConfigPath $fresh.ManagedPath `
        -GitConfigPath $fresh.GitConfigPath `
        -RequireHooksActive
    $diagnoseCode = $LASTEXITCODE
    Assert-True "installed V2 diagnosis passes" ($diagnoseCode -eq 0 -and ($diagnoseOutput | Out-String) -match "fail=0") ($diagnoseOutput | Out-String)
    $wrongManagedPath = Join-Path $freshCase "wrong-requirements.toml"
    $wrongManagedText = [IO.File]::ReadAllText($fresh.ManagedPath, [Text.Encoding]::UTF8).Replace('matcher = "manual|auto"', 'matcher = "manual"')
    [IO.File]::WriteAllText($wrongManagedPath, $wrongManagedText, (New-Object Text.UTF8Encoding($false)))
    $wrongDiagnoseOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installedDiagnose `
        -TargetRoot $fresh.TargetRoot `
        -CodexHome $fresh.CodexHome `
        -ManagedConfigPath $wrongManagedPath `
        -GitConfigPath $fresh.GitConfigPath `
        -RequireHooksActive
    $wrongDiagnoseCode = $LASTEXITCODE
    Assert-True "installed diagnosis rejects a wrong managed matcher" (
        $wrongDiagnoseCode -ne 0 -and ($wrongDiagnoseOutput | Out-String) -match "fail=[1-9]"
    ) ($wrongDiagnoseOutput | Out-String)
    Assert-True "removed V1 high-frequency hooks are not installed at the V2 root" (
        -not (Test-Path -LiteralPath (Join-Path $fresh.TargetRoot "tools/hooks/agent-hook-prompt-reminder.ps1")) -and
        -not (Test-Path -LiteralPath (Join-Path $fresh.TargetRoot "tools/hooks/agent-hook-permission-guard.ps1")) -and
        -not (Test-Path -LiteralPath (Join-Path $fresh.TargetRoot "tools/hooks/agent-hook-posttool-audit.ps1"))
    )
    $outsidePath = Join-Path $freshCase "outside.txt"
    [IO.File]::WriteAllText($outsidePath, "outside-safe", [Text.Encoding]::UTF8)
    $maliciousReceiptPath = Join-Path $fresh.BackupRoot "untrusted-receipt.json"
    $maliciousReceipt = [IO.File]::ReadAllText((Join-Path $fresh.BackupRoot "migration-receipt.json"), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $maliciousReceipt.entries[0].destination = $outsidePath
    [IO.File]::WriteAllText($maliciousReceiptPath, (($maliciousReceipt | ConvertTo-Json -Depth 6) + "`n"), (New-Object Text.UTF8Encoding($false)))
    $untrustedRollback = Invoke-ReceiptRollback -InstallResult $fresh -ReceiptPath $maliciousReceiptPath
    Assert-True "rollback rejects a receipt destination outside declared roots" ($untrustedRollback.ExitCode -ne 0) $untrustedRollback.Output
    Assert-True "rejected receipt leaves outside file unchanged" ((Get-Content -Raw -LiteralPath $outsidePath) -eq "outside-safe")
    $freshManagedHash = (Get-FileHash -LiteralPath $fresh.ManagedPath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText((Join-Path $fresh.CodexHome "AGENTS.md"), "post-install-drift", [Text.Encoding]::UTF8)
    $driftRollback = Invoke-ReceiptRollback -InstallResult $fresh
    Assert-True "rollback fails closed when an installed file drifted" ($driftRollback.ExitCode -ne 0) $driftRollback.Output
    Assert-True "drifted rollback performs zero writes" (
        (Get-Content -Raw -LiteralPath (Join-Path $fresh.CodexHome "AGENTS.md")) -eq "post-install-drift" -and
        (Get-FileHash -LiteralPath $fresh.ManagedPath -Algorithm SHA256).Hash -eq $freshManagedHash
    )

    $conflictCase = Join-Path $fixtureRoot "conflict"
    $conflictCodex = Join-Path $conflictCase "codex"
    $conflictManaged = Join-Path $conflictCase "managed/requirements.toml"
    New-Item -ItemType Directory -Path $conflictCodex -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $conflictManaged) -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $conflictCodex "AGENTS.md"), "custom-agent", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($conflictManaged, "custom-managed", [Text.Encoding]::UTF8)
    & git config --file (Join-Path $conflictCase "gitconfig") core.hooksPath "custom-hooks"
    $conflict = Invoke-Installer -CaseRoot $conflictCase -Apply
    Assert-True "unknown existing workflow fails closed" ($conflict.ExitCode -ne 0) $conflict.Output
    Assert-True "conflict preserves AGENTS" ((Get-Content -Raw -LiteralPath (Join-Path $conflictCodex "AGENTS.md")) -eq "custom-agent")
    Assert-True "conflict preserves managed config" ((Get-Content -Raw -LiteralPath $conflictManaged) -eq "custom-managed")
    Assert-True "conflict preserves Git hooks path" ((& git config --file $conflict.GitConfigPath --get core.hooksPath) -eq "custom-hooks")

    $migrateCase = Join-Path $fixtureRoot "migrate"
    $migrateCodex = Join-Path $migrateCase "codex"
    $migrateManaged = Join-Path $migrateCase "managed/requirements.toml"
    New-Item -ItemType Directory -Path $migrateCodex -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $migrateManaged) -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $migrateCodex "AGENTS.md"), "legacy-agent", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $migrateCodex "hooks.json"), '{"hooks":{"PostToolUse":[]}}', [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($migrateManaged, "legacy-managed", [Text.Encoding]::UTF8)
    New-Item -ItemType Directory -Path (Join-Path $migrateCodex "rules") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $migrateCodex "tools/hooks") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $migrateCodex "docs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $migrateCodex "skills/steadyagent-workflow/references") -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $migrateCodex "rules/workflow-routing.md"), "legacy-rule", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $migrateCodex "tools/hooks/agent-hook-prompt-reminder.ps1"), "legacy-hook", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $migrateCodex "tools/enable-codex-hooks.ps1"), "legacy-enabler", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $migrateCodex "docs/activation-guide.md"), "legacy-doc", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $migrateCodex "skills/steadyagent-workflow/references/claude-code-practices.md"), "legacy-skill-reference", [Text.Encoding]::UTF8)
    $migrate = Invoke-Installer -CaseRoot $migrateCase -Apply -ReplaceExistingWorkflow
    Assert-True "authorized V1 migration succeeds" ($migrate.ExitCode -eq 0) $migrate.Output
    Assert-True "migration receipt records replaced targets" (Test-Path -LiteralPath (Join-Path $migrate.BackupRoot "migration-receipt.json"))
    Assert-True "migration backup preserves legacy AGENTS" (Test-BackupContainsText -Root $migrate.BackupRoot -Expected "legacy-agent")
    Assert-True "migration backup preserves legacy managed config" (Test-BackupContainsText -Root $migrate.BackupRoot -Expected "legacy-managed")
    Assert-True "migration removes known V1 Codex files" (
        -not (Test-Path -LiteralPath (Join-Path $migrateCodex "rules/workflow-routing.md")) -and
        -not (Test-Path -LiteralPath (Join-Path $migrateCodex "tools/hooks/agent-hook-prompt-reminder.ps1")) -and
        -not (Test-Path -LiteralPath (Join-Path $migrateCodex "tools/enable-codex-hooks.ps1")) -and
        -not (Test-Path -LiteralPath (Join-Path $migrateCodex "docs/activation-guide.md")) -and
        -not (Test-Path -LiteralPath (Join-Path $migrateCodex "skills/steadyagent-workflow/references/claude-code-practices.md"))
    )
    $migrateReceipt = [IO.File]::ReadAllText((Join-Path $migrate.BackupRoot "migration-receipt.json"), [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-True "migration receipt records created rules directory" (
        @($migrateReceipt.created_directories) -contains (Join-Path $migrate.TargetRoot "rules")
    ) (@($migrateReceipt.created_directories) -join "; ")
    $installedAgentsHash = (Get-FileHash -LiteralPath (Join-Path $migrate.CodexHome "AGENTS.md") -Algorithm SHA256).Hash
    $heldRollbackMutex = New-Object Threading.Mutex($true, "Local\SteadyAgentV2Migration")
    try {
        $blockedReceiptRollback = Invoke-ReceiptRollback -InstallResult $migrate
        Assert-True "shared migration mutex blocks receipt rollback" ($blockedReceiptRollback.ExitCode -ne 0) $blockedReceiptRollback.Output
        Assert-True "blocked receipt rollback performs zero target writes" (
            (Get-FileHash -LiteralPath (Join-Path $migrate.CodexHome "AGENTS.md") -Algorithm SHA256).Hash -eq $installedAgentsHash
        )
    }
    finally {
        $heldRollbackMutex.ReleaseMutex()
        $heldRollbackMutex.Dispose()
    }
    $receiptRollback = Invoke-ReceiptRollback -InstallResult $migrate
    Assert-True "successful migration can be rolled back from its receipt" ($receiptRollback.ExitCode -eq 0) $receiptRollback.Output
    Assert-True "receipt rollback restores legacy AGENTS" ((Get-Content -Raw -LiteralPath (Join-Path $migrate.CodexHome "AGENTS.md")) -eq "legacy-agent")
    Assert-True "receipt rollback restores legacy user hooks" ((Get-Content -Raw -LiteralPath (Join-Path $migrate.CodexHome "hooks.json")) -eq '{"hooks":{"PostToolUse":[]}}')
    Assert-True "receipt rollback restores legacy managed config" ((Get-Content -Raw -LiteralPath $migrate.ManagedPath) -eq "legacy-managed")
    Assert-True "receipt rollback restores known V1 Codex files" (
        (Get-Content -Raw -LiteralPath (Join-Path $migrateCodex "rules/workflow-routing.md")) -eq "legacy-rule" -and
        (Get-Content -Raw -LiteralPath (Join-Path $migrateCodex "tools/hooks/agent-hook-prompt-reminder.ps1")) -eq "legacy-hook" -and
        (Get-Content -Raw -LiteralPath (Join-Path $migrateCodex "tools/enable-codex-hooks.ps1")) -eq "legacy-enabler" -and
        (Get-Content -Raw -LiteralPath (Join-Path $migrateCodex "docs/activation-guide.md")) -eq "legacy-doc" -and
        (Get-Content -Raw -LiteralPath (Join-Path $migrateCodex "skills/steadyagent-workflow/references/claude-code-practices.md")) -eq "legacy-skill-reference"
    )
    $restoredHooksPath = & git config --file $migrate.GitConfigPath --get core.hooksPath
    Assert-True "receipt rollback restores the previous Git hooks path" ($LASTEXITCODE -ne 0 -and -not $restoredHooksPath) ([string]$restoredHooksPath)
    Assert-True "receipt rollback removes a V2-created file" (-not (Test-Path -LiteralPath (Join-Path $migrate.TargetRoot "rules/review-gates.md")))
    $remainingTargetEntries = if (Test-Path -LiteralPath $migrate.TargetRoot) {
        @(Get-ChildItem -LiteralPath $migrate.TargetRoot -Recurse -Force | ForEach-Object FullName) -join "; "
    } else { "" }
    Assert-True "receipt rollback removes V2-created directory tree" (-not (Test-Path -LiteralPath $migrate.TargetRoot)) $remainingTargetEntries

    $raceCase = Join-Path $fixtureRoot "race"
    $raceTarget = Join-Path $raceCase "steadyagent"
    $raceCodex = Join-Path $raceCase "codex"
    New-Item -ItemType Directory -Path $raceCodex -Force | Out-Null
    $renderedAgents = [IO.File]::ReadAllText((Join-Path $repoRoot "templates/codex/AGENTS.md"), [Text.Encoding]::UTF8)
    $renderedAgents = $renderedAgents.Replace("%STEADYAGENT_HOME%", $raceTarget)
    [IO.File]::WriteAllText((Join-Path $raceCodex "AGENTS.md"), $renderedAgents, (New-Object Text.UTF8Encoding($false)))
    $env:STEADYAGENT_TEST_MODE = "1"
    try {
        $race = Invoke-Installer -CaseRoot $raceCase -Apply -InjectTargetMutationPath (Join-Path $raceCodex "AGENTS.md")
    }
    finally {
        Remove-Item Env:STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
    }
    Assert-True "target drift between plan and write fails closed" ($race.ExitCode -ne 0) $race.Output
    Assert-True "target drift is preserved instead of overwritten" ((Get-Content -Raw -LiteralPath (Join-Path $raceCodex "AGENTS.md")) -eq "injected-external-drift")

    $gitRaceCase = Join-Path $fixtureRoot "git-race"
    $env:STEADYAGENT_TEST_MODE = "1"
    try {
        $gitRace = Invoke-Installer -CaseRoot $gitRaceCase -Apply -InjectGitHooksMutationValue "external-hooks"
    }
    finally {
        Remove-Item Env:STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
    }
    Assert-True "Git hooks drift between plan and write fails closed" ($gitRace.ExitCode -ne 0) $gitRace.Output
    Assert-True "Git hooks drift is preserved instead of overwritten" (
        (& git config --file $gitRace.GitConfigPath --get core.hooksPath) -eq "external-hooks"
    )

    $heldMigrationMutex = New-Object Threading.Mutex($true, "Local\SteadyAgentV2Migration")
    try {
        $overlapCase = Join-Path $fixtureRoot "overlap-lock"
        $overlap = Invoke-Installer -CaseRoot $overlapCase -Apply
        Assert-True "shared migration mutex blocks a partially overlapping installer" ($overlap.ExitCode -ne 0) $overlap.Output
        Assert-True "blocked overlapping installer performs zero target writes" (-not (Test-Path -LiteralPath $overlapCase)) $overlap.Output
    }
    finally {
        $heldMigrationMutex.ReleaseMutex()
        $heldMigrationMutex.Dispose()
    }

    $postWriteCase = Join-Path $fixtureRoot "post-write-failure"
    $postWriteCodex = Join-Path $postWriteCase "codex"
    New-Item -ItemType Directory -Path $postWriteCodex -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $postWriteCodex "AGENTS.md"), "post-write-original", [Text.Encoding]::UTF8)
    $env:STEADYAGENT_TEST_MODE = "1"
    try {
        $postWrite = Invoke-Installer -CaseRoot $postWriteCase -Apply -ReplaceExistingWorkflow -InjectPostWriteFailureAt 1
    }
    finally {
        Remove-Item Env:STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
    }
    Assert-True "post-write verification failure returns nonzero" ($postWrite.ExitCode -ne 0) $postWrite.Output
    Assert-True "post-write failure restores the current mutated target" (
        (Get-Content -Raw -LiteralPath (Join-Path $postWriteCodex "AGENTS.md")) -eq "post-write-original"
    )

    $rollbackRaceCase = Join-Path $fixtureRoot "rollback-race"
    $rollbackRace = Invoke-Installer -CaseRoot $rollbackRaceCase -Apply
    Assert-True "rollback race fixture installs successfully" ($rollbackRace.ExitCode -eq 0) $rollbackRace.Output
    $rollbackRaceReceiptPath = Join-Path $rollbackRace.BackupRoot "migration-receipt.json"
    $rollbackRaceReceipt = [IO.File]::ReadAllText($rollbackRaceReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $firstInstalledEntry = @($rollbackRaceReceipt.entries | Where-Object { $_.action -eq "install" })[0]
    $env:STEADYAGENT_TEST_MODE = "1"
    try {
        $rollbackRaceResult = Invoke-ReceiptRollback -InstallResult $rollbackRace -InjectTargetMutationPath $rollbackRace.ManagedPath
    }
    finally {
        Remove-Item Env:STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
    }
    Assert-True "rollback detects drift immediately before a later restore" ($rollbackRaceResult.ExitCode -ne 0) $rollbackRaceResult.Output
    Assert-True "rollback preserves the immediate external drift" (
        (Get-Content -Raw -LiteralPath $rollbackRace.ManagedPath) -eq "injected-rollback-drift"
    )
    Assert-True "blocked rollback reapplies earlier installed state" (
        (Get-FileHash -LiteralPath $firstInstalledEntry.destination -Algorithm SHA256).Hash -eq $firstInstalledEntry.installed_sha256
    )

    $rollbackCase = Join-Path $fixtureRoot "rollback"
    $rollbackCodex = Join-Path $rollbackCase "codex"
    $rollbackManaged = Join-Path $rollbackCase "managed/requirements.toml"
    New-Item -ItemType Directory -Path $rollbackCodex -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $rollbackManaged) -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $rollbackCodex "AGENTS.md"), "rollback-agent", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($rollbackManaged, "rollback-managed", [Text.Encoding]::UTF8)
    & git config --file (Join-Path $rollbackCase "gitconfig") core.hooksPath "rollback-hooks"
    $env:STEADYAGENT_TEST_MODE = "1"
    try {
        $rollback = Invoke-Installer -CaseRoot $rollbackCase -Apply -ReplaceExistingWorkflow -InjectFailureAfter 2
    }
    finally {
        Remove-Item Env:STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
    }
    Assert-True "injected migration failure returns nonzero" ($rollback.ExitCode -ne 0) $rollback.Output
    Assert-True "rollback restores original AGENTS" ((Get-Content -Raw -LiteralPath (Join-Path $rollbackCodex "AGENTS.md")) -eq "rollback-agent")
    Assert-True "rollback restores original managed config" ((Get-Content -Raw -LiteralPath $rollbackManaged) -eq "rollback-managed")
    Assert-True "rollback restores original Git hooks path" ((& git config --file $rollback.GitConfigPath --get core.hooksPath) -eq "rollback-hooks")

    Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

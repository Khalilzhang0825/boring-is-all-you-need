[CmdletBinding()]
param([switch]$RefactorContractOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Passed = 0
$script:Failed = 0
$script:Results = @{}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$sourceInstaller = Join-Path $PSScriptRoot "install.ps1"
$installer = $null
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("steadyagent-v2-migration-" + [guid]::NewGuid().ToString("N"))
$expectedV1RemovalRelativePaths = @(
    "requirements.managed-hooks.example.toml",
    "rules/README.md",
    "rules/README.zh-CN.md",
    "rules/context-management.md",
    "rules/review-gates.md",
    "rules/safety-boundaries.md",
    "rules/verification.md",
    "rules/workflow-routing.md",
    "tools/enable-codex-hooks.ps1",
    "tools/hooks/agent-hook-command-guard.ps1",
    "tools/hooks/agent-hook-context.ps1",
    "tools/hooks/agent-hook-file-guard.ps1",
    "tools/hooks/agent-hook-permission-guard.ps1",
    "tools/hooks/agent-hook-posttool-audit.ps1",
    "tools/hooks/agent-hook-precompact.ps1",
    "tools/hooks/agent-hook-prompt-reminder.ps1",
    "tools/hooks/agent-hook-utils.ps1",
    "tools/hooks/pre-commit.ps1",
    "tools/test-agent-hooks.ps1",
    "tools/diagnose-install.ps1",
    "docs/activation-guide.md",
    "docs/activation-guide.zh-CN.md",
    "docs/feature-map.md",
    "docs/feature-map.zh-CN.md",
    "docs/hook-runtime.md",
    "docs/hook-runtime.zh-CN.md",
    "skills/steadyagent-workflow/references/claude-code-practices.md"
)
$expectedV2InstallProjection = @(
    "install|codex|AGENTS.md",
    "install|codex|hooks.json",
    "install|codex|skills/steadyagent-workflow/agents/openai.yaml",
    "install|codex|skills/steadyagent-workflow/references/karpathy-guardrails.md",
    "install|codex|skills/steadyagent-workflow/references/mnilax-extensions.md",
    "install|codex|skills/steadyagent-workflow/references/operating-principles.md",
    "install|codex|skills/steadyagent-workflow/references/prompt-recipes.md",
    "install|codex|skills/steadyagent-workflow/SKILL.md",
    "install|managed|requirements.toml",
    "install|target|docs/activation-guide.md",
    "install|target|docs/activation-guide.zh-CN.md",
    "install|target|docs/feature-map.md",
    "install|target|docs/feature-map.zh-CN.md",
    "install|target|docs/hook-runtime.md",
    "install|target|docs/hook-runtime.zh-CN.md",
    "install|target|docs/tools.md",
    "install|target|docs/tools.zh-CN.md",
    "install|target|manifests/codex-requirements.expected.toml",
    "install|target|manifests/local-postimage-equivalence.json",
    "install|target|manifests/v1-codex-owned-files.txt",
    "install|target|rules/context-management.md",
    "install|target|rules/HARNESS-GUIDE.md",
    "install|target|rules/harness-review.md",
    "install|target|rules/lessons.md",
    "install|target|rules/README.md",
    "install|target|rules/README.zh-CN.md",
    "install|target|rules/review-gates.md",
    "install|target|rules/safety-boundaries.md",
    "install|target|rules/skill-routing.md",
    "install|target|rules/verification.md",
    "install|target|rules/workflow-routing.md",
    "install|target|tools/diagnose-install.ps1",
    "install|target|tools/git-checkpoint.ps1",
    "install|target|tools/git-hooks/pre-commit",
    "install|target|tools/git-hooks/pre-commit-check.ps1",
    "install|target|tools/git-preflight.ps1",
    "install|target|tools/migration-runtime.ps1",
    "install|target|tools/hooks/agent-hook-command-guard.ps1",
    "install|target|tools/hooks/agent-hook-context.ps1",
    "install|target|tools/hooks/agent-hook-file-guard.ps1",
    "install|target|tools/hooks/agent-hook-precompact.ps1",
    "install|target|tools/hooks/agent-hook-utils.ps1",
    "install|target|tools/hooks/pre-commit.ps1",
    "install|target|tools/protected-path-policy.ps1",
    "install|target|tools/rollback.ps1",
    "install|target|tools/skill-catalog-resolver.ps1",
    "install|target|tools/skill-index.ps1",
    "install|target|tools/skill-search.ps1",
    "install|target|tools/test-agent-hooks.ps1",
    "install|target|tools/test-git-checkpoint.ps1",
    "install|target|tools/test-pre-commit.ps1",
    "install|target|tools/test-protected-path-policy.ps1",
    "install|target|tools/test-skill-catalog.ps1"
)

$expectedSharedMigrationRuntimeFunctions = @(
    "Assert-NoReparsePath",
    "ConvertTo-ReceiptIntegrityValue",
    "Get-ActiveReceiptPointerIntegritySha256",
    "Get-ActiveReceiptPointerPath",
    "Get-ReceiptIntegritySha256",
    "Get-Sha256Bytes",
    "Get-Sha256Text",
    "Get-SortedProjectionSha256",
    "Invoke-TestHardKill",
    "Test-IsProcessElevated",
    "Test-PathTreeOverlap",
    "Test-PathWithinRoot",
    "Write-MigrationReceipt",
    "Write-Utf8NoBomAtomic"
)
$expectedIntentionalMigrationDivergences = @(
    "Assert-SteadyAgentMigrationMutexSecurity",
    "Copy-Atomically",
    "Get-GitHooksPath",
    "New-SteadyAgentMigrationMutex",
    "Set-GitConfigBytesCas"
)

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    $script:Results[$Name] = $Condition
    if ($Condition) {
        $script:Passed++
        Write-Host ("PASS " + $Name)
    }
    else {
        $script:Failed++
        Write-Host ("FAIL " + $Name + $(if ($Detail) { " - " + $Detail } else { "" }))
    }
}

function Write-SemanticCheck {
    param([string]$Id, [string[]]$Cases)
    $missing = @($Cases | Where-Object {
        -not $script:Results.ContainsKey($_) -or -not [bool]$script:Results[$_]
    })
    if ($missing.Count -eq 0) {
        Write-Host ("SEMANTIC PASS " + $Id)
    }
    else {
        Write-Host ("FAIL semantic evidence " + $Id + " missing=" + ($missing -join ","))
        $script:Failed++
    }
}

function Get-ScriptFunctionMap {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        [IO.Path]::GetFullPath($Path),
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        throw ("PowerShell parse failed: " + ($errors | Out-String))
    }
    $map = @{}
    foreach ($function in @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true))) {
        $map[[string]$function.Name] = [string]$function.Extent.Text
    }
    return $map
}

function Test-MigrationRuntimeRefactorContract {
    $runtimePath = Join-Path $PSScriptRoot "migration-runtime.ps1"
    $installPath = Join-Path $PSScriptRoot "install.ps1"
    $rollbackPath = Join-Path $PSScriptRoot "rollback.ps1"
    $runtimeExists = Test-Path -LiteralPath $runtimePath -PathType Leaf
    Assert-True "shared migration runtime exists as one sibling module" $runtimeExists
    if (-not $runtimeExists) { return }

    $installFunctions = Get-ScriptFunctionMap -Path $installPath
    $rollbackFunctions = Get-ScriptFunctionMap -Path $rollbackPath
    $runtimeFunctions = Get-ScriptFunctionMap -Path $runtimePath
    $remainingShared = @(
        $installFunctions.Keys |
            Where-Object { $rollbackFunctions.ContainsKey($_) } |
            Sort-Object
    )
    Assert-True "only the five intentional install rollback divergences remain duplicated" (
        ($remainingShared -join "`n") -ceq
        (($expectedIntentionalMigrationDivergences | Sort-Object) -join "`n")
    ) ($remainingShared -join ",")
    Assert-True "shared migration runtime owns exactly the fourteen byte-identical primitives" (
        (($runtimeFunctions.Keys | Sort-Object) -join "`n") -ceq
        (($expectedSharedMigrationRuntimeFunctions | Sort-Object) -join "`n")
    ) (($runtimeFunctions.Keys | Sort-Object) -join ",")

    $runtimeHash = (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash
    $installSource = [IO.File]::ReadAllText($installPath, [Text.Encoding]::UTF8)
    $rollbackSource = [IO.File]::ReadAllText($rollbackPath, [Text.Encoding]::UTF8)
    foreach ($entry in @(
        [pscustomobject]@{ Name = "install"; Source = $installSource },
        [pscustomobject]@{ Name = "rollback"; Source = $rollbackSource }
    )) {
        Assert-True ($entry.Name + " freezes and verifies the sibling runtime before loading it") (
            $entry.Source -match [regex]::Escape('$expectedMigrationRuntimeSha256 = "' + $runtimeHash + '"') -and
            $entry.Source -match "Migration runtime (is missing|path is a reparse point|integrity verification failed)" -and
            $entry.Source -match [regex]::Escape('. $migrationRuntimeBlock')
        )
        Assert-True ($entry.Name + " documents all five intentional local divergences") (
            @($expectedIntentionalMigrationDivergences | Where-Object {
                $entry.Source -notmatch (
                    "(?m)^# Intentionally local: .*\r?\nfunction " + [regex]::Escape($_) + "\b"
                )
            }).Count -eq 0
        )
    }
    $diagnoseSource = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "diagnose-install.ps1"),
        [Text.Encoding]::UTF8
    )
    Assert-True "strict diagnosis pins every trusted parent directory through execution" (
        $diagnoseSource -match "SteadyAgent[.]DiagnosePinnedDirectory" -and
        $diagnoseSource -match "DirectoryPins" -and
        $diagnoseSource -match "FILE_FLAG_OPEN_REPARSE_POINT"
    )
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-TestMigrationMutexName {
    param([string]$TestRoot)
    $canonicalTestRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\', '/').ToLowerInvariant()
    return "Local\SteadyAgentV2MigrationTest_" +
        (Get-Sha256Text -Text $canonicalTestRoot).ToLowerInvariant()
}

function Get-RollbackJournalIntegritySha256 {
    param([object]$Journal)
    $saved = $Journal.journal_integrity_sha256
    $Journal.journal_integrity_sha256 = $null
    try {
        return Get-Sha256Text -Text ($Journal | ConvertTo-Json -Depth 10 -Compress)
    }
    finally {
        $Journal.journal_integrity_sha256 = $saved
    }
}

function Get-ManagedSurfaceFingerprint {
    param(
        [string[]]$Roots,
        [string[]]$Files
    )
    $lines = New-Object Collections.Generic.List[string]
    foreach ($root in @($Roots | Sort-Object -Unique)) {
        $rootFull = [IO.Path]::GetFullPath($root)
        if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
            $lines.Add(("ROOT-MISSING|" + $rootFull)) | Out-Null
            continue
        }
        $lines.Add(("ROOT|" + $rootFull)) | Out-Null
        foreach ($item in @(Get-ChildItem -LiteralPath $rootFull -Recurse -Force | Sort-Object FullName)) {
            $relative = $item.FullName.Substring($rootFull.TrimEnd('\').Length + 1).Replace('\', '/')
            if ($item.PSIsContainer) {
                $lines.Add(("DIR|" + $rootFull + "|" + $relative)) | Out-Null
            }
            else {
                $lines.Add((
                    "FILE|" + $rootFull + "|" + $relative + "|" +
                    (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
                )) | Out-Null
            }
        }
    }
    foreach ($file in @($Files | Sort-Object -Unique)) {
        $fileFull = [IO.Path]::GetFullPath($file)
        if (Test-Path -LiteralPath $fileFull -PathType Leaf) {
            $lines.Add((
                "SINGLE|" + $fileFull + "|" +
                (Get-FileHash -LiteralPath $fileFull -Algorithm SHA256).Hash
            )) | Out-Null
        }
        else {
            $lines.Add(("SINGLE-MISSING|" + $fileFull)) | Out-Null
        }
    }
    return Get-Sha256Text -Text ($lines -join "`n")
}

function ConvertTo-ReceiptIntegrityValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "<null>" }
    if ($Value -is [bool]) { return $(if ([bool]$Value) { "true" } else { "false" }) }
    return [string]$Value
}

function Get-ReceiptIntegritySha256 {
    param([object]$Receipt)
    $lines = New-Object Collections.Generic.List[string]
    foreach ($name in @(
        "schema_version",
        "steadyagent_version",
        "created_utc",
        "completed_utc",
        "restored_utc",
        "failure",
        "status",
        "target_root",
        "codex_home",
        "managed_config",
        "git_config",
        "git_config_existed_before",
        "git_config_before_sha256",
        "git_config_after_sha256",
        "git_config_before_snapshot_name",
        "git_config_before_snapshot_sha256",
        "git_config_after_snapshot_name",
        "git_config_after_snapshot_sha256",
        "git_hooks_path_before",
        "git_hooks_path_after",
        "git_hooks_path_before_snapshot_name",
        "git_hooks_path_before_snapshot_sha256",
        "install_operation_count",
        "remove_operation_count",
        "install_projection_sha256",
        "removal_projection_sha256"
    )) {
        $value = if ($Receipt.PSObject.Properties.Name -contains $name) { $Receipt.$name } else { $null }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-ReceiptIntegrityValue -Value $value)))
        $lines.Add($name + "=" + $encoded) | Out-Null
    }
    $directories = @()
    if ($Receipt.PSObject.Properties.Name -contains "created_directories") {
        $directories = @($Receipt.created_directories)
    }
    $lines.Add("created_directories.count=" + $directories.Count) | Out-Null
    for ($index = 0; $index -lt $directories.Count; $index++) {
        foreach ($name in @("path", "volume_serial", "file_id")) {
            $encoded = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes(
                    (ConvertTo-ReceiptIntegrityValue -Value $directories[$index].$name)
                )
            )
            $lines.Add(("created_directories[{0}].{1}={2}" -f $index, $name, $encoded)) | Out-Null
        }
    }
    $entries = @()
    if ($Receipt.PSObject.Properties.Name -contains "entries") {
        $entries = @($Receipt.entries)
    }
    $lines.Add("entries.count=" + $entries.Count) | Out-Null
    for ($entryIndex = 0; $entryIndex -lt $entries.Count; $entryIndex++) {
        foreach ($name in @(
            "action",
            "destination",
            "existed",
            "snapshot_name",
            "original_sha256",
            "installed_sha256"
        )) {
            $entry = $entries[$entryIndex]
            $value = if ($entry.PSObject.Properties.Name -contains $name) { $entry.$name } else { $null }
            $encoded = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes((ConvertTo-ReceiptIntegrityValue -Value $value))
            )
            $lines.Add(("entries[{0}].{1}={2}" -f $entryIndex, $name, $encoded)) | Out-Null
        }
    }
    return Get-Sha256Text -Text ($lines -join "`n")
}

function Update-ReceiptIntegrity {
    param([object]$Receipt)
    foreach ($name in @("completed_utc", "restored_utc", "failure")) {
        if ($Receipt.PSObject.Properties.Name -notcontains $name) {
            Add-Member -InputObject $Receipt -NotePropertyName $name -NotePropertyValue $null
        }
    }
    $hash = Get-ReceiptIntegritySha256 -Receipt $Receipt
    if ($Receipt.PSObject.Properties.Name -contains "receipt_integrity_sha256") {
        $Receipt.receipt_integrity_sha256 = $hash
    }
    else {
        Add-Member -InputObject $Receipt -NotePropertyName "receipt_integrity_sha256" -NotePropertyValue $hash
    }
}

function Copy-PackageFixture {
    param([string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $manifestPath = Join-Path $repoRoot "package-assets.sha256"
    $relativePaths = @(
        [IO.File]::ReadAllLines($manifestPath, [Text.Encoding]::UTF8) |
            ForEach-Object {
                if ($_ -notmatch '^[0-9A-F]{64}  (?<path>.+)$') {
                    throw "Package fixture manifest line is invalid."
                }
                [string]$Matches.path
            }
    )
    $fixtureRelativePaths = [string[]]@($relativePaths)
    [Array]::Sort($fixtureRelativePaths, [StringComparer]::Ordinal)
    foreach ($relative in @($fixtureRelativePaths + @("package-assets.sha256", "tools/install.ps1"))) {
        $source = Join-Path $repoRoot $relative.Replace('/', '\')
        $target = Join-Path $Destination $relative.Replace('/', '\')
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [IO.File]::Copy($source, $target, $false)
    }
    $records = @($fixtureRelativePaths | ForEach-Object {
        (Get-FileHash -LiteralPath (Join-Path $Destination $_.Replace('/', '\')) -Algorithm SHA256).Hash +
            "  " + $_
    })
    [Array]::Sort(
        $records,
        [Comparison[string]]{
            param($left, $right)
            [StringComparer]::Ordinal.Compare($left.Substring(66), $right.Substring(66))
        }
    )
    $manifestText = ($records -join "`n") + "`n"
    $fixtureManifestPath = Join-Path $Destination "package-assets.sha256"
    [IO.File]::WriteAllText(
        $fixtureManifestPath,
        $manifestText,
        (New-Object Text.UTF8Encoding($false))
    )
    $fixtureManifestHash = (Get-FileHash -LiteralPath $fixtureManifestPath -Algorithm SHA256).Hash
    $fixtureInstallerPath = Join-Path $Destination "tools\install.ps1"
    $fixtureInstallerText = [IO.File]::ReadAllText($fixtureInstallerPath, [Text.Encoding]::UTF8)
    $fixtureInstallerText = [regex]::Replace(
        $fixtureInstallerText,
        '(?m)([$]expectedPackageManifestSha256\s*=\s*")[0-9A-F]{64}(")',
        ('${1}' + $fixtureManifestHash + '${2}'),
        1
    )
    $fixtureInstallerText = [regex]::Replace(
        $fixtureInstallerText,
        '(?m)([$]expectedPackageAssetCount\s*=\s*)[0-9]+',
        ('${1}' + $fixtureRelativePaths.Count),
        1
    )
    [IO.File]::WriteAllText(
        $fixtureInstallerPath,
        $fixtureInstallerText,
        (New-Object Text.UTF8Encoding($false))
    )
}

function Get-ReceiptOperationProjection {
    param(
        [object[]]$Entries,
        [string]$TargetRoot,
        [string]$CodexHome,
        [string]$ManagedConfig
    )
    $targetPrefix = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\') + '\'
    $codexPrefix = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\') + '\'
    $managedFull = [IO.Path]::GetFullPath($ManagedConfig)
    $projection = @()
    foreach ($entry in $Entries) {
        $destination = [IO.Path]::GetFullPath([string]$entry.destination)
        $role = $null
        $relative = $null
        if ($destination.Equals($managedFull, [StringComparison]::OrdinalIgnoreCase)) {
            $role = "managed"
            $relative = "requirements.toml"
        }
        elseif ($destination.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $role = "target"
            $relative = $destination.Substring($targetPrefix.Length).Replace('\', '/')
        }
        elseif ($destination.StartsWith($codexPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $role = "codex"
            $relative = $destination.Substring($codexPrefix.Length).Replace('\', '/')
        }
        else {
            $role = "outside"
            $relative = $destination.Replace('\', '/')
        }
        $projection += (([string]$entry.action).ToLowerInvariant() + "|" + $role + "|" + $relative)
    }
    return @($projection)
}

function Invoke-Installer {
    param(
        [string]$CaseRoot,
        [switch]$Apply,
        [switch]$ReplaceExistingWorkflow,
        [int]$InjectFailureAfter = 0,
        [int]$InjectPostWriteFailureAt = 0,
        [int]$InjectSnapshotMutationAt = 0,
        [int]$InjectSnapshotCopyFailureAt = 0,
        [int]$InjectHardKillAfterOperation = 0,
        [switch]$InjectHardKillAfterGitActivation,
        [ValidateSet("after-old-rename", "after-publish", "after-delete-rename")]
        [string]$InjectAtomicHardKillPhase,
        [int]$InjectAtomicHardKillAt = 0,
        [ValidateSet("after-stage-create", "after-receipt-before-pointer", "after-receipt", "after-publish")]
        [string]$InjectDirectoryHardKillPhase,
        [int]$InjectDirectoryHardKillAt = 0,
        [switch]$InjectHardKillAfterAppliedReceipt,
        [string]$InjectGitConfigCasMutationValue,
        [switch]$InjectRemovalSubstitution,
        [switch]$InjectMutexFailure,
        [switch]$InjectAutomaticRollbackFailure,
        [switch]$TestAsElevated,
        [int]$InjectJunctionSwapAt = 0,
        [string]$InjectJunctionParkedRoot,
        [string]$InjectJunctionEscapeRoot,
        [string]$InjectTargetMutationPath,
        [string]$InjectGitHooksMutationValue,
        [string]$CustomTargetRoot,
        [string]$CustomCodexHome,
        [string]$CustomBackupRoot,
        [string]$CustomManagedConfigPath,
        [string]$CustomGitConfigPath,
        [string]$InstallerPath,
        [string]$TestRootOverride,
        [switch]$OmitTestRoot
    )

    $effectiveInstaller = if ($InstallerPath) { $InstallerPath } else { $installer }
    $targetRoot = if ($CustomTargetRoot) { $CustomTargetRoot } else { Join-Path $CaseRoot "steadyagent" }
    $codexHome = if ($CustomCodexHome) { $CustomCodexHome } else { Join-Path $CaseRoot "codex" }
    $managedPath = if ($CustomManagedConfigPath) { $CustomManagedConfigPath } else { Join-Path $CaseRoot "managed/requirements.toml" }
    $backupRoot = if ($CustomBackupRoot) { $CustomBackupRoot } else { Join-Path $CaseRoot "backup" }
    $gitConfigPath = if ($CustomGitConfigPath) { $CustomGitConfigPath } else { Join-Path $CaseRoot "gitconfig" }
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $effectiveInstaller,
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
    if ($InjectSnapshotMutationAt -gt 0) { $arguments += @("-InjectSnapshotMutationAt", [string]$InjectSnapshotMutationAt) }
    if ($InjectSnapshotCopyFailureAt -gt 0) {
        $arguments += @("-InjectSnapshotCopyFailureAt", [string]$InjectSnapshotCopyFailureAt)
    }
    if ($InjectHardKillAfterOperation -gt 0) {
        $arguments += @("-InjectHardKillAfterOperation", [string]$InjectHardKillAfterOperation)
    }
    if ($InjectHardKillAfterGitActivation) { $arguments += "-InjectHardKillAfterGitActivation" }
    if ($InjectAtomicHardKillPhase) {
        $arguments += @(
            "-InjectAtomicHardKillPhase", $InjectAtomicHardKillPhase,
            "-InjectAtomicHardKillAt", [string]$InjectAtomicHardKillAt
        )
    }
    if ($InjectDirectoryHardKillPhase) {
        $arguments += @(
            "-InjectDirectoryHardKillPhase", $InjectDirectoryHardKillPhase,
            "-InjectDirectoryHardKillAt", [string]$InjectDirectoryHardKillAt
        )
    }
    if ($InjectHardKillAfterAppliedReceipt) { $arguments += "-InjectHardKillAfterAppliedReceipt" }
    if ($InjectGitConfigCasMutationValue) {
        $arguments += @("-InjectGitConfigCasMutationValue", $InjectGitConfigCasMutationValue)
    }
    if ($InjectRemovalSubstitution) { $arguments += "-InjectRemovalSubstitution" }
    if ($InjectMutexFailure) { $arguments += "-InjectMutexFailure" }
    if ($InjectAutomaticRollbackFailure) { $arguments += "-InjectAutomaticRollbackFailure" }
    if ($TestAsElevated) { $arguments += "-TestAsElevated" }
    if ($InjectJunctionSwapAt -gt 0) {
        $arguments += @("-InjectJunctionSwapAt", [string]$InjectJunctionSwapAt)
    }
    if ($InjectJunctionParkedRoot) {
        $arguments += @("-InjectJunctionParkedRoot", $InjectJunctionParkedRoot)
    }
    if ($InjectJunctionEscapeRoot) {
        $arguments += @("-InjectJunctionEscapeRoot", $InjectJunctionEscapeRoot)
    }
    if ($InjectTargetMutationPath) { $arguments += @("-InjectTargetMutationPath", $InjectTargetMutationPath) }
    if ($InjectGitHooksMutationValue) { $arguments += @("-InjectGitHooksMutationValue", $InjectGitHooksMutationValue) }
    $errorPath = Join-Path ([IO.Path]::GetTempPath()) ("steadyagent-v2-migration-error-" + [guid]::NewGuid().ToString("N") + ".log")
    $oldMigrationTestMode = $env:STEADYAGENT_TEST_MODE
    $oldMigrationTestRoot = $env:STEADYAGENT_TEST_ROOT
    try {
        $env:STEADYAGENT_TEST_MODE = "1"
        if ($OmitTestRoot) {
            Remove-Item Env:\STEADYAGENT_TEST_ROOT -ErrorAction SilentlyContinue
        }
        else {
            $env:STEADYAGENT_TEST_ROOT = $(if ($TestRootOverride) { $TestRootOverride } else { $fixtureRoot })
        }
        $savedErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & powershell.exe @arguments 2>$errorPath
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        $errorOutput = if (Test-Path -LiteralPath $errorPath -PathType Leaf) {
            @(Get-Content -LiteralPath $errorPath)
        }
        else { @() }
    }
    finally {
        if ($null -eq $oldMigrationTestMode) { Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_MODE = $oldMigrationTestMode }
        if ($null -eq $oldMigrationTestRoot) { Remove-Item Env:\STEADYAGENT_TEST_ROOT -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_ROOT = $oldMigrationTestRoot }
        if (Test-Path -LiteralPath $errorPath) {
            Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
        }
    }
    $combinedOutput = ((@($output) + @($errorOutput)) | Out-String)
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $combinedOutput
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

function Test-ManagedTomlBasicStrings {
    param([string]$Text)
    $assignmentPattern = '^(windows_managed_dir|command)\s*=\s*"(?:[^"\\\x00-\x1F\x7F]|\\(?:["\\bfnrt]|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}))*"\s*$'
    $matched = 0
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line -notmatch '^(windows_managed_dir|command)\s*=') { continue }
        if ($line -notmatch $assignmentPattern) { return $false }
        $matched++
    }
    return $matched -eq 4
}

function Invoke-ReceiptRollback {
    param(
        [pscustomobject]$InstallResult,
        [string]$ReceiptPath,
        [string]$RollbackPath,
        [string]$InjectTargetMutationPath,
        [string]$InjectSnapshotMutationPath,
        [switch]$InjectMutexFailure,
        [int]$InjectFailureAfterRestore = 0,
        [switch]$InjectReapplyFailure,
        [int]$InjectHardKillAfterRollbackOperation = 0,
        [switch]$InjectHardKillAfterGitRestore,
        [string]$InjectGitConfigCasMutationValue,
        [int]$InjectHardKillAfterCompensationOperation = 0,
        [switch]$InjectHardKillBeforeJournalFinalizing,
        [switch]$InjectHardKillAfterJournalFinalizing,
        [switch]$InjectHardKillAfterReceiptFinalize,
        [switch]$InjectHardKillAfterJournalCompleted,
        [switch]$InjectCompletedJournalWriteFailure,
        [int]$InjectJunctionSwapAt = 0,
        [string]$InjectJunctionParkedRoot,
        [string]$InjectJunctionEscapeRoot,
        [switch]$DryRun,
        [switch]$TestAsElevated
    )
    $receiptPath = if ($ReceiptPath) {
        $ReceiptPath
    }
    else {
        Join-Path $InstallResult.BackupRoot "migration-receipt.json"
    }
    $installedRollbackTool = if ($RollbackPath) {
        $RollbackPath
    }
    else {
        Join-Path $InstallResult.TargetRoot "tools\rollback.ps1"
    }
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installedRollbackTool,
        "-ReceiptPath", $receiptPath,
        "-GitConfigPath", $InstallResult.GitConfigPath
    )
    if (-not $DryRun) { $arguments += "-Apply" }
    if ($TestAsElevated) { $arguments += "-TestAsElevated" }
    if ($InjectTargetMutationPath) { $arguments += @("-InjectTargetMutationPath", $InjectTargetMutationPath) }
    if ($InjectSnapshotMutationPath) { $arguments += @("-InjectSnapshotMutationPath", $InjectSnapshotMutationPath) }
    if ($InjectMutexFailure) { $arguments += "-InjectMutexFailure" }
    if ($InjectFailureAfterRestore -gt 0) {
        $arguments += @("-InjectFailureAfterRestore", [string]$InjectFailureAfterRestore)
    }
    if ($InjectReapplyFailure) { $arguments += "-InjectReapplyFailure" }
    if ($InjectHardKillAfterRollbackOperation -gt 0) {
        $arguments += @(
            "-InjectHardKillAfterRollbackOperation",
            [string]$InjectHardKillAfterRollbackOperation
        )
    }
    if ($InjectHardKillAfterGitRestore) {
        $arguments += "-InjectHardKillAfterGitRestore"
    }
    if ($InjectGitConfigCasMutationValue) {
        $arguments += @("-InjectGitConfigCasMutationValue", $InjectGitConfigCasMutationValue)
    }
    if ($InjectHardKillAfterCompensationOperation -gt 0) {
        $arguments += @(
            "-InjectHardKillAfterCompensationOperation",
            [string]$InjectHardKillAfterCompensationOperation
        )
    }
    if ($InjectHardKillBeforeJournalFinalizing) {
        $arguments += "-InjectHardKillBeforeJournalFinalizing"
    }
    if ($InjectHardKillAfterJournalFinalizing) {
        $arguments += "-InjectHardKillAfterJournalFinalizing"
    }
    if ($InjectHardKillAfterReceiptFinalize) {
        $arguments += "-InjectHardKillAfterReceiptFinalize"
    }
    if ($InjectHardKillAfterJournalCompleted) {
        $arguments += "-InjectHardKillAfterJournalCompleted"
    }
    if ($InjectCompletedJournalWriteFailure) {
        $arguments += "-InjectCompletedJournalWriteFailure"
    }
    if ($InjectJunctionSwapAt -gt 0) {
        $arguments += @("-InjectJunctionSwapAt", [string]$InjectJunctionSwapAt)
    }
    if ($InjectJunctionParkedRoot) {
        $arguments += @("-InjectJunctionParkedRoot", $InjectJunctionParkedRoot)
    }
    if ($InjectJunctionEscapeRoot) {
        $arguments += @("-InjectJunctionEscapeRoot", $InjectJunctionEscapeRoot)
    }
    $errorPath = Join-Path ([IO.Path]::GetTempPath()) (
        "steadyagent-v2-rollback-error-" + [guid]::NewGuid().ToString("N") + ".log"
    )
    $oldMigrationTestMode = $env:STEADYAGENT_TEST_MODE
    $oldMigrationTestRoot = $env:STEADYAGENT_TEST_ROOT
    try {
        $env:STEADYAGENT_TEST_MODE = "1"
        $env:STEADYAGENT_TEST_ROOT = $fixtureRoot
        $savedErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & powershell.exe @arguments 2>$errorPath
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        $errorOutput = if (Test-Path -LiteralPath $errorPath -PathType Leaf) {
            @(Get-Content -LiteralPath $errorPath)
        }
        else { @() }
    }
    finally {
        if ($null -eq $oldMigrationTestMode) { Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_MODE = $oldMigrationTestMode }
        if ($null -eq $oldMigrationTestRoot) { Remove-Item Env:\STEADYAGENT_TEST_ROOT -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_ROOT = $oldMigrationTestRoot }
        if (Test-Path -LiteralPath $errorPath) {
            Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
        }
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ((@($output) + @($errorOutput)) | Out-String)
    }
}

function Start-ReceiptRollbackAuthorityBarrier {
    param(
        [pscustomobject]$InstallResult,
        [string]$RollbackPath,
        [string]$ReadyPath,
        [string]$ContinuePath
    )
    $receiptPath = Join-Path $InstallResult.BackupRoot "migration-receipt.json"
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $RollbackPath,
        "-ReceiptPath", $receiptPath,
        "-GitConfigPath", $InstallResult.GitConfigPath,
        "-Apply",
        "-InjectAuthorityBarrierReadyPath", $ReadyPath,
        "-InjectAuthorityBarrierContinuePath", $ContinuePath
    )
    if (@($arguments | Where-Object { [string]$_ -match '\s' }).Count -gt 0) {
        throw "Authority barrier fixture paths must not contain whitespace."
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = $arguments -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables["STEADYAGENT_TEST_MODE"] = "1"
    $startInfo.EnvironmentVariables["STEADYAGENT_TEST_ROOT"] = $fixtureRoot
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start the authority barrier rollback fixture." }
    return [pscustomobject]@{
        Process = $process
    }
}

function Invoke-TamperedReceiptRollbackFixture {
    param(
        [string]$Name,
        [scriptblock]$Prepare,
        [scriptblock]$Mutate,
        [switch]$Rehash,
        [string]$ActiveHooksOverride
    )
    $caseRoot = Join-Path $fixtureRoot ("tamper-" + $Name)
    if ($Prepare) { & $Prepare $caseRoot }
    $installed = Invoke-Installer -CaseRoot $caseRoot -Apply -ReplaceExistingWorkflow
    if ($installed.ExitCode -ne 0) {
        return [pscustomobject]@{
            InstallExitCode = $installed.ExitCode
            RollbackExitCode = -1
            ZeroTargetWrites = $false
            Output = $installed.Output
        }
    }
    $sourceReceiptPath = Join-Path $installed.BackupRoot "migration-receipt.json"
    $tamperedReceiptPath = Join-Path $installed.BackupRoot ("tampered-" + $Name + ".json")
    $receipt = [IO.File]::ReadAllText($sourceReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    & $Mutate $receipt $installed
    if ($Rehash) { Update-ReceiptIntegrity -Receipt $receipt }
    [IO.File]::WriteAllText(
        $tamperedReceiptPath,
        (($receipt | ConvertTo-Json -Depth 7) + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )
    if ($ActiveHooksOverride) {
        & git config --file $installed.GitConfigPath core.hooksPath $ActiveHooksOverride
        if ($LASTEXITCODE -ne 0) { throw "Could not set tamper fixture Hook path." }
    }
    $sentinelPath = Join-Path $installed.TargetRoot "rules\review-gates.md"
    $sentinelHash = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
    $rollback = Invoke-ReceiptRollback -InstallResult $installed -ReceiptPath $tamperedReceiptPath
    $zeroTargetWrites = (
        (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -and
        (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash -eq $sentinelHash
    )
    return [pscustomobject]@{
        InstallExitCode = $installed.ExitCode
        RollbackExitCode = $rollback.ExitCode
        ZeroTargetWrites = $zeroTargetWrites
        Output = $rollback.Output
    }
}

function Invoke-StrictDiagnosisFixture {
    param(
        [string]$DiagnosePath,
        [pscustomobject]$InstallResult,
        [string]$SyntheticCodexHome,
        [string]$ThreadId,
        [switch]$SkipSmoke
    )
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $DiagnosePath,
        "-TargetRoot", $InstallResult.TargetRoot,
        "-CodexHome", $InstallResult.CodexHome,
        "-ManagedConfigPath", $InstallResult.ManagedPath,
        "-GitConfigPath", $InstallResult.GitConfigPath,
        "-ReceiptPath", (Join-Path $InstallResult.BackupRoot "migration-receipt.json"),
        "-RequireInstalledBytes",
        "-RequireHooksActive",
        "-RequireRuntimeCatalog",
        "-RequireGitIdentity"
    )
    if ($SkipSmoke) { $arguments += "-SkipSmoke" }
    $oldCodexHome = $env:CODEX_HOME
    $oldThreadId = $env:CODEX_THREAD_ID
    $oldMigrationTestMode = $env:STEADYAGENT_TEST_MODE
    $oldMigrationTestRoot = $env:STEADYAGENT_TEST_ROOT
    try {
        $env:CODEX_HOME = $SyntheticCodexHome
        $env:CODEX_THREAD_ID = $ThreadId
        $env:STEADYAGENT_TEST_MODE = "1"
        $env:STEADYAGENT_TEST_ROOT = $fixtureRoot
        $output = & powershell.exe @arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($null -eq $oldCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $oldCodexHome }
        if ($null -eq $oldThreadId) { Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue }
        else { $env:CODEX_THREAD_ID = $oldThreadId }
        if ($null -eq $oldMigrationTestMode) { Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_MODE = $oldMigrationTestMode }
        if ($null -eq $oldMigrationTestRoot) { Remove-Item Env:\STEADYAGENT_TEST_ROOT -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_ROOT = $oldMigrationTestRoot }
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (@($output) -join "`n")
    }
}

function Invoke-InstalledBytesDiagnosisFixture {
    param(
        [string]$DiagnosePath,
        [pscustomobject]$InstallResult
    )
    $errorPath = Join-Path $fixtureRoot ("diagnose-installed-bytes-" + [guid]::NewGuid().ToString("N") + ".log")
    $oldMigrationTestMode = $env:STEADYAGENT_TEST_MODE
    $oldMigrationTestRoot = $env:STEADYAGENT_TEST_ROOT
    try {
        $env:STEADYAGENT_TEST_MODE = "1"
        $env:STEADYAGENT_TEST_ROOT = $fixtureRoot
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File $DiagnosePath `
            -TargetRoot $InstallResult.TargetRoot `
            -CodexHome $InstallResult.CodexHome `
            -ManagedConfigPath $InstallResult.ManagedPath `
            -GitConfigPath $InstallResult.GitConfigPath `
            -ReceiptPath (Join-Path $InstallResult.BackupRoot "migration-receipt.json") `
            -RequireInstalledBytes `
            -SkipSmoke 2>$errorPath
        $exitCode = $LASTEXITCODE
        $errorOutput = @(Get-Content -LiteralPath $errorPath -ErrorAction SilentlyContinue)
    }
    finally {
        if ($null -eq $oldMigrationTestMode) { Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_MODE = $oldMigrationTestMode }
        if ($null -eq $oldMigrationTestRoot) { Remove-Item Env:\STEADYAGENT_TEST_ROOT -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_ROOT = $oldMigrationTestRoot }
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (@($output) + @($errorOutput) -join "`n")
    }
}

Test-MigrationRuntimeRefactorContract
if ($RefactorContractOnly) {
    Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    $testPackageRoot = Join-Path $fixtureRoot "package"
    Copy-PackageFixture -Destination $testPackageRoot
    $installer = Join-Path $testPackageRoot "tools\install.ps1"
    . (Join-Path $testPackageRoot "tools\protected-path-policy.ps1")

    $missingRuntimePackage = Join-Path $fixtureRoot "missing-runtime-package"
    Copy-PackageFixture -Destination $missingRuntimePackage
    [IO.File]::Delete((Join-Path $missingRuntimePackage "tools\migration-runtime.ps1"))
    $missingRuntimeCase = Join-Path $fixtureRoot "missing-runtime-install"
    $missingRuntimeInstall = Invoke-Installer `
        -CaseRoot $missingRuntimeCase `
        -Apply `
        -InstallerPath (Join-Path $missingRuntimePackage "tools\install.ps1")
    Assert-True "installer rejects a missing frozen migration runtime before writes" (
        $missingRuntimeInstall.ExitCode -ne 0 -and
        $missingRuntimeInstall.Output -match "Migration runtime is missing"
    ) $missingRuntimeInstall.Output
    Assert-True "missing installer runtime rejection performs zero migration writes" (
        -not (Test-Path -LiteralPath $missingRuntimeCase)
    ) $missingRuntimeInstall.Output

    $tamperedRuntimePackage = Join-Path $fixtureRoot "tampered-runtime-package"
    Copy-PackageFixture -Destination $tamperedRuntimePackage
    [IO.File]::AppendAllText(
        (Join-Path $tamperedRuntimePackage "tools\migration-runtime.ps1"),
        "`n# tampered",
        (New-Object Text.UTF8Encoding($false))
    )
    $tamperedRuntimeCase = Join-Path $fixtureRoot "tampered-runtime-install"
    $tamperedRuntimeInstall = Invoke-Installer `
        -CaseRoot $tamperedRuntimeCase `
        -Apply `
        -InstallerPath (Join-Path $tamperedRuntimePackage "tools\install.ps1")
    Assert-True "installer rejects a tampered frozen migration runtime before writes" (
        $tamperedRuntimeInstall.ExitCode -ne 0 -and
        $tamperedRuntimeInstall.Output -match "Migration runtime integrity verification failed"
    ) $tamperedRuntimeInstall.Output
    Assert-True "tampered installer runtime rejection performs zero migration writes" (
        -not (Test-Path -LiteralPath $tamperedRuntimeCase)
    ) $tamperedRuntimeInstall.Output

    $reparseRuntimePackage = Join-Path $fixtureRoot "reparse-runtime-package"
    Copy-PackageFixture -Destination $reparseRuntimePackage
    $reparseRuntimePhysicalTools = Join-Path $fixtureRoot "reparse-runtime-physical-tools"
    [IO.Directory]::Move(
        (Join-Path $reparseRuntimePackage "tools"),
        $reparseRuntimePhysicalTools
    )
    New-Item `
        -ItemType Junction `
        -Path (Join-Path $reparseRuntimePackage "tools") `
        -Target $reparseRuntimePhysicalTools | Out-Null
    $reparseRuntimeCase = Join-Path $fixtureRoot "reparse-runtime-install"
    $reparseRuntimeInstall = Invoke-Installer `
        -CaseRoot $reparseRuntimeCase `
        -Apply `
        -InstallerPath (Join-Path $reparseRuntimePackage "tools\install.ps1")
    Assert-True "installer rejects a reparse-point migration runtime path before writes" (
        $reparseRuntimeInstall.ExitCode -ne 0 -and
        $reparseRuntimeInstall.Output -match "Migration runtime path is a reparse point"
    ) $reparseRuntimeInstall.Output
    Assert-True "reparse installer runtime rejection performs zero migration writes" (
        -not (Test-Path -LiteralPath $reparseRuntimeCase)
    ) $reparseRuntimeInstall.Output

    $runtimeRollbackReceipt = Join-Path $fixtureRoot "runtime-preflight-receipt.json"
    [IO.File]::WriteAllText(
        $runtimeRollbackReceipt,
        "runtime-preflight-sentinel",
        (New-Object Text.UTF8Encoding($false))
    )
    $runtimeRollbackReceiptHash = (
        Get-FileHash -LiteralPath $runtimeRollbackReceipt -Algorithm SHA256
    ).Hash
    $runtimeRollbackResult = [pscustomobject]@{
        BackupRoot = $fixtureRoot
        TargetRoot = (Join-Path $fixtureRoot "runtime-rollback-target")
        GitConfigPath = (Join-Path $fixtureRoot "runtime-rollback-gitconfig")
    }
    foreach ($runtimeRollbackFixture in @(
        [pscustomobject]@{ Name = "missing"; Mode = "missing" },
        [pscustomobject]@{ Name = "tampered"; Mode = "tampered" },
        [pscustomobject]@{ Name = "reparse"; Mode = "reparse" }
    )) {
        $runtimeRollbackToolRoot = Join-Path $fixtureRoot (
            "runtime-rollback-tool-" + $runtimeRollbackFixture.Name
        )
        New-Item -ItemType Directory -Path $runtimeRollbackToolRoot -Force | Out-Null
        [IO.File]::Copy(
            (Join-Path $PSScriptRoot "rollback.ps1"),
            (Join-Path $runtimeRollbackToolRoot "rollback.ps1"),
            $false
        )
        if ($runtimeRollbackFixture.Mode -ne "missing") {
            [IO.File]::Copy(
                (Join-Path $PSScriptRoot "migration-runtime.ps1"),
                (Join-Path $runtimeRollbackToolRoot "migration-runtime.ps1"),
                $false
            )
        }
        if ($runtimeRollbackFixture.Mode -eq "tampered") {
            [IO.File]::AppendAllText(
                (Join-Path $runtimeRollbackToolRoot "migration-runtime.ps1"),
                "`n# tampered",
                (New-Object Text.UTF8Encoding($false))
            )
        }
        $runtimeRollbackPath = Join-Path $runtimeRollbackToolRoot "rollback.ps1"
        if ($runtimeRollbackFixture.Mode -eq "reparse") {
            $runtimeRollbackPhysicalRoot = $runtimeRollbackToolRoot + "-physical"
            [IO.Directory]::Move($runtimeRollbackToolRoot, $runtimeRollbackPhysicalRoot)
            New-Item `
                -ItemType Junction `
                -Path $runtimeRollbackToolRoot `
                -Target $runtimeRollbackPhysicalRoot | Out-Null
        }
        $runtimeRollback = Invoke-ReceiptRollback `
            -InstallResult $runtimeRollbackResult `
            -ReceiptPath $runtimeRollbackReceipt `
            -RollbackPath $runtimeRollbackPath
        $expectedRuntimeFailure = switch ($runtimeRollbackFixture.Mode) {
            "missing" { "Migration runtime is missing" }
            "tampered" { "Migration runtime integrity verification failed" }
            "reparse" { "Migration runtime path is a reparse point" }
        }
        Assert-True (
            "rollback rejects a " + $runtimeRollbackFixture.Name +
            " frozen migration runtime before writes"
        ) (
            $runtimeRollback.ExitCode -ne 0 -and
            $runtimeRollback.Output -match [regex]::Escape($expectedRuntimeFailure)
        ) $runtimeRollback.Output
        Assert-True (
            $runtimeRollbackFixture.Name +
            " rollback runtime rejection performs zero migration writes"
        ) (
            (Get-FileHash -LiteralPath $runtimeRollbackReceipt -Algorithm SHA256).Hash -ceq
                $runtimeRollbackReceiptHash -and
            -not (Test-Path -LiteralPath $runtimeRollbackResult.TargetRoot) -and
            -not (Test-Path -LiteralPath $runtimeRollbackResult.GitConfigPath)
        ) $runtimeRollback.Output
    }

    $missingTestRootCase = Join-Path $fixtureRoot "missing-test-root"
    $missingTestRoot = Invoke-Installer `
        -CaseRoot $missingTestRootCase `
        -InstallerPath $sourceInstaller `
        -OmitTestRoot
    Assert-True "test mode alone cannot unlock installer fixture paths" (
        $missingTestRoot.ExitCode -ne 0 -and
        $missingTestRoot.Output -match "STEADYAGENT_TEST_ROOT"
    ) $missingTestRoot.Output
    Assert-True "missing test root rejection performs zero writes" (
        -not (Test-Path -LiteralPath $missingTestRootCase)
    )

    $outsidePackageCase = Join-Path $fixtureRoot "outside-package"
    $outsidePackage = Invoke-Installer `
        -CaseRoot $outsidePackageCase `
        -InstallerPath $sourceInstaller
    Assert-True "test mode requires an independent package copy inside its fixture root" (
        $outsidePackage.ExitCode -ne 0 -and
        $outsidePackage.Output -match "escaped STEADYAGENT_TEST_ROOT"
    ) $outsidePackage.Output
    Assert-True "outside package rejection performs zero writes" (
        -not (Test-Path -LiteralPath $outsidePackageCase)
    )

    $assetTamperPackage = Join-Path $fixtureRoot "asset-tamper-package"
    Copy-PackageFixture -Destination $assetTamperPackage
    [IO.File]::AppendAllText(
        (Join-Path $assetTamperPackage "rules\safety-boundaries.md"),
        "`nasset-tamper",
        (New-Object Text.UTF8Encoding($false))
    )
    $assetTamperCase = Join-Path $fixtureRoot "asset-tamper-case"
    $assetTamper = Invoke-Installer `
        -CaseRoot $assetTamperCase `
        -Apply `
        -InstallerPath (Join-Path $assetTamperPackage "tools\install.ps1")
    Assert-True "package asset tamper fails against the installer trust anchor" (
        $assetTamper.ExitCode -ne 0 -and
        $assetTamper.Output -match "Package asset hash mismatch"
    ) $assetTamper.Output
    Assert-True "package asset tamper performs zero case writes" (
        -not (Test-Path -LiteralPath $assetTamperCase)
    ) $assetTamper.Output

    $manifestTamperPackage = Join-Path $fixtureRoot "manifest-tamper-package"
    Copy-PackageFixture -Destination $manifestTamperPackage
    [IO.File]::AppendAllText(
        (Join-Path $manifestTamperPackage "package-assets.sha256"),
        " ",
        (New-Object Text.UTF8Encoding($false))
    )
    $manifestTamperCase = Join-Path $fixtureRoot "manifest-tamper-case"
    $manifestTamper = Invoke-Installer `
        -CaseRoot $manifestTamperCase `
        -Apply `
        -InstallerPath (Join-Path $manifestTamperPackage "tools\install.ps1")
    Assert-True "package manifest tamper fails against the embedded digest" (
        $manifestTamper.ExitCode -ne 0 -and
        $manifestTamper.Output -match "installer trust anchor"
    ) $manifestTamper.Output
    Assert-True "package manifest tamper performs zero case writes" (
        -not (Test-Path -LiteralPath $manifestTamperCase)
    ) $manifestTamper.Output

    $dryCase = Join-Path $fixtureRoot "dry"
    $dry = Invoke-Installer -CaseRoot $dryCase
    Assert-True "dry-run exits successfully" ($dry.ExitCode -eq 0) $dry.Output
    Assert-True "dry-run identifies V2 migration" ($dry.Output -match "DRY-RUN Boring Is All You Need v2[.]0[.]0 migration") $dry.Output
    Assert-True "dry-run performs zero writes" (-not (Test-Path -LiteralPath $dryCase)) $dry.Output
    Assert-True "dry-run reports zero target config state writes rather than zero filesystem writes" (
        $dry.Output -match "0 target/config/backup/receipt/state writes" -and
        $dry.Output -match "temporary staging"
    ) $dry.Output
    Assert-True "fresh dry-run renders the concrete operation and conflict counts" (
        $dry.Output -match (
            "Plan: 80 operations; 0 existing conflict[(]s[)]; " +
            "0 target/config/backup/receipt/state writes[.]"
        )
    ) $dry.Output
    $expectedDryHooksPath = Join-Path $dry.TargetRoot "tools\git-hooks"
    Assert-True "fresh dry-run renders the Git hooksPath before and after values" (
        $dry.Output -match (
            "WOULD SET Git core[.]hooksPath: <unset> -> " +
            [regex]::Escape($expectedDryHooksPath)
        )
    ) $dry.Output

    $simulatedElevatedInstallCase = Join-Path $fixtureRoot "simulated-elevated-install"
    New-Item -ItemType Directory -Path $simulatedElevatedInstallCase -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $simulatedElevatedInstallCase "sentinel.txt"),
        "must-not-change",
        (New-Object Text.UTF8Encoding($false))
    )
    $simulatedElevatedInstallBefore = Get-ManagedSurfaceFingerprint `
        -Roots @($simulatedElevatedInstallCase) `
        -Files @()
    $simulatedElevatedInstall = Invoke-Installer `
        -CaseRoot $simulatedElevatedInstallCase `
        -Apply `
        -TestAsElevated
    Assert-True "simulated elevated install apply fails closed" (
        $simulatedElevatedInstall.ExitCode -ne 0 -and
        $simulatedElevatedInstall.Output -match "non-elevated PowerShell session" -and
        $simulatedElevatedInstall.Output -match "outside Codex Desktop" -and
        $simulatedElevatedInstall.Output -match '\[windows\] sandbox = "elevated"' -and
        $simulatedElevatedInstall.Output -match "Run as administrator"
    ) $simulatedElevatedInstall.Output
    Assert-True "simulated elevated install apply performs zero case writes" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($simulatedElevatedInstallCase) `
            -Files @()) -eq $simulatedElevatedInstallBefore
    ) $simulatedElevatedInstall.Output

    $snapshotFailureCase = Join-Path $fixtureRoot "pre-receipt-snapshot-failure"
    $snapshotFailureCodex = Join-Path $snapshotFailureCase "codex"
    New-Item -ItemType Directory -Path $snapshotFailureCodex -Force | Out-Null
    $snapshotFailureTarget = Join-Path $snapshotFailureCodex "AGENTS.md"
    [IO.File]::WriteAllText($snapshotFailureTarget, "snapshot-preimage`n", (New-Object Text.UTF8Encoding($false)))
    $snapshotFailureBefore = Get-ManagedSurfaceFingerprint `
        -Roots @($snapshotFailureCodex) `
        -Files @((Join-Path $snapshotFailureCase "gitconfig"))
    $snapshotFailure = Invoke-Installer `
        -CaseRoot $snapshotFailureCase `
        -Apply `
        -ReplaceExistingWorkflow `
        -InjectSnapshotCopyFailureAt 1
    $snapshotFailureAfter = Get-ManagedSurfaceFingerprint `
        -Roots @($snapshotFailureCodex) `
        -Files @((Join-Path $snapshotFailureCase "gitconfig"))
    Assert-True "pre-receipt snapshot failure exits before target writes" (
        $snapshotFailure.ExitCode -eq 2 -and
        $snapshotFailureBefore -ceq $snapshotFailureAfter
    ) $snapshotFailure.Output
    Assert-True "pre-receipt snapshot failure removes its orphan backup" (
        -not (Test-Path -LiteralPath $snapshotFailure.BackupRoot)
    ) $snapshotFailure.Output

    $firstWriteCrashCase = Join-Path $fixtureRoot "hard-kill-after-first-write"
    $firstWriteCrashPreimage = Get-ManagedSurfaceFingerprint `
        -Roots @(
            (Join-Path $firstWriteCrashCase "codex"),
            (Join-Path $firstWriteCrashCase "steadyagent")
        ) `
        -Files @(
            (Join-Path $firstWriteCrashCase "managed\requirements.toml"),
            (Join-Path $firstWriteCrashCase "gitconfig")
        )
    $firstWriteCrash = Invoke-Installer `
        -CaseRoot $firstWriteCrashCase `
        -Apply `
        -InjectHardKillAfterOperation 1
    Assert-True "hard kill after the first target write leaves an applying receipt" (
        $firstWriteCrash.ExitCode -ne 0 -and
        (Test-Path -LiteralPath (Join-Path $firstWriteCrash.BackupRoot "migration-receipt.json") -PathType Leaf)
    ) $firstWriteCrash.Output
    Assert-True "first-write crash does not depend on an installed rollback tool" (
        -not (Test-Path -LiteralPath (Join-Path $firstWriteCrash.TargetRoot "tools\rollback.ps1"))
    )
    $firstWriteRecovery = Invoke-ReceiptRollback `
        -InstallResult $firstWriteCrash `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "package rollback tool can recover a first-write crash" (
        $firstWriteRecovery.ExitCode -eq 0
    ) $firstWriteRecovery.Output

    $reentryCrashCase = Join-Path $fixtureRoot "hard-kill-reentry-guard"
    $reentryCrash = Invoke-Installer `
        -CaseRoot $reentryCrashCase `
        -Apply `
        -InjectHardKillAfterOperation 1
    $reentryReceiptPath = Join-Path $reentryCrash.BackupRoot "migration-receipt.json"
    $reentryPointer = @(
        Get-ChildItem -LiteralPath $reentryCrashCase `
            -Filter ".steadyagent-active-receipt-*.json" -File -Force
    )
    Assert-True "hard-kill applying receipt is published through one active pointer" (
        $reentryCrash.ExitCode -ne 0 -and
        $reentryPointer.Count -eq 1 -and
        (Test-Path -LiteralPath $reentryReceiptPath -PathType Leaf)
    ) $reentryCrash.Output
    $reentryBefore = Get-ManagedSurfaceFingerprint -Roots @($reentryCrashCase) -Files @()
    $reentryAttempt = Invoke-Installer `
        -CaseRoot $reentryCrashCase `
        -CustomBackupRoot (Join-Path $reentryCrashCase "backup-rerun") `
        -Apply `
        -ReplaceExistingWorkflow
    Assert-True "installer reentry refuses an active applying receipt and prints recovery evidence" (
        $reentryAttempt.ExitCode -eq 3 -and
        $reentryAttempt.Output -match [regex]::Escape($reentryReceiptPath) -and
        $reentryAttempt.Output -match "active applying receipt" -and
        $reentryAttempt.Output -match "Do not blindly retry"
    ) $reentryAttempt.Output
    Assert-True "refused installer reentry performs zero managed or evidence writes" (
        (Get-ManagedSurfaceFingerprint -Roots @($reentryCrashCase) -Files @()) -ceq
            $reentryBefore -and
        -not (Test-Path -LiteralPath (Join-Path $reentryCrashCase "backup-rerun"))
    ) $reentryAttempt.Output
    $reentryRecovery = Invoke-ReceiptRollback `
        -InstallResult $reentryCrash `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "original applying receipt remains recoverable after refused installer reentry" (
        $reentryRecovery.ExitCode -eq 0
    ) $reentryRecovery.Output

    $automaticRollbackFailureCase = Join-Path $fixtureRoot "automatic-rollback-incomplete"
    $automaticRollbackFailure = Invoke-Installer `
        -CaseRoot $automaticRollbackFailureCase `
        -Apply `
        -InjectFailureAfter 1 `
        -InjectAutomaticRollbackFailure
    $automaticFailureReceipt = Join-Path $automaticRollbackFailure.BackupRoot "migration-receipt.json"
    Assert-True "automatic rollback incomplete returns manual-recovery exit 3" (
        $automaticRollbackFailure.ExitCode -eq 3
    ) $automaticRollbackFailure.Output
    Assert-True "automatic rollback incomplete repeats durable recovery evidence and no-blind-retry warning" (
        $automaticRollbackFailure.Output -match [regex]::Escape($automaticFailureReceipt) -and
        $automaticRollbackFailure.Output -match "Recovery journal/state" -and
        $automaticRollbackFailure.Output -match "Preserve the backup root" -and
        $automaticRollbackFailure.Output -match "Do not blindly retry"
    ) $automaticRollbackFailure.Output
    Assert-True "first-write crash recovery restores every managed surface" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($firstWriteCrash.CodexHome, $firstWriteCrash.TargetRoot) `
            -Files @($firstWriteCrash.ManagedPath, $firstWriteCrash.GitConfigPath)) -eq
            $firstWriteCrashPreimage
    ) $firstWriteRecovery.Output

    foreach ($atomicCrashPhase in @("after-old-rename", "after-publish")) {
        $atomicCrashCase = Join-Path $fixtureRoot ("atomic-crash-" + $atomicCrashPhase)
        $atomicCrashCodex = Join-Path $atomicCrashCase "codex"
        New-Item -ItemType Directory -Path $atomicCrashCodex -Force | Out-Null
        $atomicCrashAgent = Join-Path $atomicCrashCodex "AGENTS.md"
        [IO.File]::WriteAllText(
            $atomicCrashAgent,
            ("atomic-preimage-" + $atomicCrashPhase + "`n"),
            (New-Object Text.UTF8Encoding($false))
        )
        $atomicCrashPreimage = Get-ManagedSurfaceFingerprint `
            -Roots @($atomicCrashCodex, (Join-Path $atomicCrashCase "steadyagent")) `
            -Files @(
                (Join-Path $atomicCrashCase "managed\requirements.toml"),
                (Join-Path $atomicCrashCase "gitconfig")
            )
        $atomicCrash = Invoke-Installer `
            -CaseRoot $atomicCrashCase `
            -Apply `
            -ReplaceExistingWorkflow `
            -InjectAtomicHardKillPhase $atomicCrashPhase `
            -InjectAtomicHardKillAt 1
        $atomicReceipt = Join-Path $atomicCrash.BackupRoot "migration-receipt.json"
        Assert-True ("atomic hard kill leaves an applying receipt: " + $atomicCrashPhase) (
            $atomicCrash.ExitCode -ne 0 -and
            (Test-Path -LiteralPath $atomicReceipt -PathType Leaf)
        ) $atomicCrash.Output
        $atomicDryRunBefore = Get-ManagedSurfaceFingerprint -Roots @($atomicCrashCase) -Files @()
        $atomicDryRun = Invoke-ReceiptRollback `
            -InstallResult $atomicCrash `
            -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1") `
            -DryRun
        Assert-True ("atomic pending rollback dry-run reports recovery without writes: " + $atomicCrashPhase) (
            $atomicDryRun.ExitCode -eq 0 -and
            $atomicDryRun.Output -match "PENDING BOUND RECOVERY" -and
            $atomicDryRun.Output -match "0 writes" -and
            (Get-ManagedSurfaceFingerprint -Roots @($atomicCrashCase) -Files @()) -ceq
                $atomicDryRunBefore
        ) $atomicDryRun.Output
        $atomicRecovery = Invoke-ReceiptRollback `
            -InstallResult $atomicCrash `
            -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
        Assert-True ("rollback repairs and restores atomic subtransaction: " + $atomicCrashPhase) (
            $atomicRecovery.ExitCode -eq 0 -and
            (Get-ManagedSurfaceFingerprint `
                -Roots @($atomicCrash.CodexHome, $atomicCrash.TargetRoot) `
                -Files @($atomicCrash.ManagedPath, $atomicCrash.GitConfigPath)) -eq
                $atomicCrashPreimage
        ) $atomicRecovery.Output
        $atomicArtifacts = @(
            Get-ChildItem -LiteralPath $atomicCrashCase -Recurse -Force -File |
                Where-Object { $_.Name -like ".steadyagent-v2-atomic-*" }
        )
        Assert-True ("atomic crash recovery removes durable mutation artifacts: " + $atomicCrashPhase) (
            $atomicArtifacts.Count -eq 0
        ) (($atomicArtifacts | Select-Object -ExpandProperty FullName) -join "`n")
    }

    $atomicMutexCase = Join-Path $fixtureRoot "atomic-pending-mutex-boundary"
    $atomicMutexCodex = Join-Path $atomicMutexCase "codex"
    New-Item -ItemType Directory -Path $atomicMutexCodex -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $atomicMutexCodex "AGENTS.md"),
        "atomic-mutex-preimage`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $atomicMutexCrash = Invoke-Installer `
        -CaseRoot $atomicMutexCase `
        -Apply `
        -ReplaceExistingWorkflow `
        -InjectAtomicHardKillPhase "after-old-rename" `
        -InjectAtomicHardKillAt 1
    $atomicMutexBefore = Get-ManagedSurfaceFingerprint -Roots @($atomicMutexCase) -Files @()
    $atomicMutexBlocked = Invoke-ReceiptRollback `
        -InstallResult $atomicMutexCrash `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1") `
        -InjectMutexFailure
    Assert-True "mutex refusal cannot repair a pending bound mutation" (
        $atomicMutexBlocked.ExitCode -ne 0 -and
        $atomicMutexBlocked.Output -match "mutex" -and
        (Get-ManagedSurfaceFingerprint -Roots @($atomicMutexCase) -Files @()) -ceq
            $atomicMutexBefore
    ) $atomicMutexBlocked.Output
    $atomicMutexRecovery = Invoke-ReceiptRollback `
        -InstallResult $atomicMutexCrash `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "pending bound mutation remains recoverable after mutex refusal" (
        $atomicMutexRecovery.ExitCode -eq 0
    ) $atomicMutexRecovery.Output

    $atomicDeleteCase = Join-Path $fixtureRoot "atomic-crash-after-delete-rename"
    $atomicDeleteCodex = Join-Path $atomicDeleteCase "codex"
    New-Item -ItemType Directory -Path $atomicDeleteCodex -Force | Out-Null
    $atomicDeleteTarget = Join-Path $atomicDeleteCodex "requirements.managed-hooks.example.toml"
    [IO.File]::WriteAllText(
        $atomicDeleteTarget,
        "atomic-delete-preimage`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $atomicDeletePreimage = Get-ManagedSurfaceFingerprint `
        -Roots @($atomicDeleteCodex, (Join-Path $atomicDeleteCase "steadyagent")) `
        -Files @(
            (Join-Path $atomicDeleteCase "managed\requirements.toml"),
            (Join-Path $atomicDeleteCase "gitconfig")
        )
    $atomicDeleteCrash = Invoke-Installer `
        -CaseRoot $atomicDeleteCase `
        -Apply `
        -ReplaceExistingWorkflow `
        -InjectAtomicHardKillPhase "after-delete-rename" `
        -InjectAtomicHardKillAt 54
    $atomicDeleteRecovery = Invoke-ReceiptRollback `
        -InstallResult $atomicDeleteCrash `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "rollback repairs a hard kill inside bound delete" (
        $atomicDeleteCrash.ExitCode -ne 0 -and
        $atomicDeleteRecovery.ExitCode -eq 0 -and
        (Get-ManagedSurfaceFingerprint `
            -Roots @($atomicDeleteCrash.CodexHome, $atomicDeleteCrash.TargetRoot) `
            -Files @($atomicDeleteCrash.ManagedPath, $atomicDeleteCrash.GitConfigPath)) -eq
            $atomicDeletePreimage
    ) $atomicDeleteRecovery.Output
    Assert-True "bound delete crash recovery leaves no mutation artifacts" (
        @(Get-ChildItem -LiteralPath $atomicDeleteCase -Recurse -Force -File |
            Where-Object { $_.Name -like ".steadyagent-v2-atomic-*" }).Count -eq 0
    )

    foreach ($directoryCrashPhase in @(
        "after-stage-create",
        "after-receipt-before-pointer",
        "after-receipt",
        "after-publish"
    )) {
        $directoryCrashCase = Join-Path $fixtureRoot ("directory-crash-" + $directoryCrashPhase)
        $directoryCrashTarget = Join-Path $directoryCrashCase "steadyagent"
        $directoryCrashCodex = Join-Path $directoryCrashCase "codex"
        $directoryCrashManaged = Join-Path $directoryCrashCase "managed\requirements.toml"
        $directoryCrashGitConfig = Join-Path $directoryCrashCase "gitconfig"
        $directoryCrashPreimage = Get-ManagedSurfaceFingerprint `
            -Roots @($directoryCrashCodex, $directoryCrashTarget) `
            -Files @($directoryCrashManaged, $directoryCrashGitConfig)
        $directoryCrash = Invoke-Installer `
            -CaseRoot $directoryCrashCase `
            -Apply `
            -InjectDirectoryHardKillPhase $directoryCrashPhase `
            -InjectDirectoryHardKillAt 1
        $directoryCrashReceiptPath = Join-Path $directoryCrash.BackupRoot "migration-receipt.json"
        $directoryCrashReceipt = if (Test-Path -LiteralPath $directoryCrashReceiptPath -PathType Leaf) {
            [IO.File]::ReadAllText($directoryCrashReceiptPath, [Text.Encoding]::UTF8) |
                ConvertFrom-Json
        }
        else { $null }
        Assert-True ("directory publication hard kill leaves an applying receipt: " + $directoryCrashPhase) (
            $directoryCrash.ExitCode -ne 0 -and
            $directoryCrashReceipt -and
            [string]$directoryCrashReceipt.status -eq "applying"
        ) $directoryCrash.Output

        [object[]]$recordedDirectories = @()
        if ($directoryCrashReceipt) {
            $recordedDirectories = @($directoryCrashReceipt.created_directories)
        }
        $directoryCrashStateIsConsistent = switch ($directoryCrashPhase) {
            "after-stage-create" {
                $recordedDirectories.Count -eq 0 -and
                -not (Test-Path -LiteralPath $directoryCrashTarget)
            }
            { $_ -in @("after-receipt-before-pointer", "after-receipt") } {
                $recordedDirectories.Count -eq 1 -and
                -not (Test-Path -LiteralPath ([string]$recordedDirectories[0].path))
            }
            "after-publish" {
                if ($recordedDirectories.Count -ne 1 -or
                    -not (Test-Path -LiteralPath ([string]$recordedDirectories[0].path) -PathType Container)) {
                    $false
                }
                else {
                    $publishedIdentity = Get-SteadyAgentDirectoryIdentity `
                        -Path ([string]$recordedDirectories[0].path)
                    [string]$publishedIdentity.volume_serial -ceq
                        [string]$recordedDirectories[0].volume_serial -and
                    [string]$publishedIdentity.file_id -ceq
                        [string]$recordedDirectories[0].file_id
                }
            }
        }
        Assert-True ("directory publication crash state matches its receipt: " + $directoryCrashPhase) `
            $directoryCrashStateIsConsistent

        $directoryCrashRollback = Invoke-ReceiptRollback `
            -InstallResult $directoryCrash `
            -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
        Assert-True ("directory publication hard kill rollback restores preimage: " + $directoryCrashPhase) (
            $directoryCrashRollback.ExitCode -eq 0 -and
            (Get-ManagedSurfaceFingerprint `
                -Roots @($directoryCrashCodex, $directoryCrashTarget) `
                -Files @($directoryCrashManaged, $directoryCrashGitConfig)) -ceq
                $directoryCrashPreimage
        ) $directoryCrashRollback.Output
        if ($directoryCrashPhase -eq "after-receipt-before-pointer") {
            Assert-True "stale directory receipt pointer is removed by rollback" (
                @(Get-ChildItem -LiteralPath $directoryCrashCase `
                    -Filter ".steadyagent-active-receipt-*.json" -File -Force).Count -eq 0
            ) $directoryCrashRollback.Output
        }
    }

    $appliedPointerCrashCase = Join-Path $fixtureRoot "applied-receipt-pointer-crash"
    $appliedPointerTarget = Join-Path $appliedPointerCrashCase "steadyagent"
    $appliedPointerCodex = Join-Path $appliedPointerCrashCase "codex"
    $appliedPointerManaged = Join-Path $appliedPointerCrashCase "managed\requirements.toml"
    $appliedPointerGitConfig = Join-Path $appliedPointerCrashCase "gitconfig"
    $appliedPointerPreimage = Get-ManagedSurfaceFingerprint `
        -Roots @($appliedPointerCodex, $appliedPointerTarget) `
        -Files @($appliedPointerManaged, $appliedPointerGitConfig)
    $appliedPointerCrash = Invoke-Installer `
        -CaseRoot $appliedPointerCrashCase `
        -Apply `
        -InjectHardKillAfterAppliedReceipt
    $appliedPointerReceiptPath = Join-Path $appliedPointerCrash.BackupRoot "migration-receipt.json"
    $appliedPointerReceipt = [IO.File]::ReadAllText(
        $appliedPointerReceiptPath,
        [Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    $appliedPointerFile = @(
        Get-ChildItem -LiteralPath $appliedPointerCrashCase `
            -Filter ".steadyagent-active-receipt-*.json" -File -Force
    )
    $appliedPointerState = [IO.File]::ReadAllText(
        $appliedPointerFile[0].FullName,
        [Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    Assert-True "hard kill between applied receipt and pointer leaves a valid applied receipt" (
        $appliedPointerCrash.ExitCode -ne 0 -and
        [string]$appliedPointerReceipt.status -eq "applied"
    ) $appliedPointerCrash.Output
    Assert-True "applied receipt hard kill leaves exactly one stale same-receipt pointer" (
        $appliedPointerFile.Count -eq 1 -and
        [IO.Path]::GetFullPath([string]$appliedPointerState.receipts[0].path).Equals(
            [IO.Path]::GetFullPath($appliedPointerReceiptPath),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [string]$appliedPointerState.receipts[0].sha256 -cne
            (Get-FileHash -LiteralPath $appliedPointerReceiptPath -Algorithm SHA256).Hash
    )
    $appliedPointerRollback = Invoke-ReceiptRollback `
        -InstallResult $appliedPointerCrash `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "rollback accepts and removes the stale same-receipt pointer" (
        $appliedPointerRollback.ExitCode -eq 0 -and
        @(Get-ChildItem -LiteralPath $appliedPointerCrashCase `
            -Filter ".steadyagent-active-receipt-*.json" -File -Force).Count -eq 0 -and
        (Get-ManagedSurfaceFingerprint `
            -Roots @($appliedPointerCodex, $appliedPointerTarget) `
            -Files @($appliedPointerManaged, $appliedPointerGitConfig)) -ceq
                $appliedPointerPreimage
    ) $appliedPointerRollback.Output
    $appliedPointerRetry = Invoke-Installer `
        -CaseRoot $appliedPointerCrashCase `
        -CustomBackupRoot (Join-Path $appliedPointerCrashCase "backup-retry") `
        -Apply
    Assert-True "install can proceed after stale same-receipt pointer recovery" (
        $appliedPointerRetry.ExitCode -eq 0
    ) $appliedPointerRetry.Output

    $authorityRaceCase = Join-Path $fixtureRoot "rollback-authority-race"
    $authorityRaceInstall = Invoke-Installer -CaseRoot $authorityRaceCase -Apply
    $authorityReadyPath = Join-Path $authorityRaceCase "authority-ready.signal"
    $authorityContinuePath = Join-Path $authorityRaceCase "authority-continue.signal"
    $authorityRollbackPath = Join-Path $testPackageRoot "tools\rollback.ps1"
    $authorityWaiter = Start-ReceiptRollbackAuthorityBarrier `
        -InstallResult $authorityRaceInstall `
        -RollbackPath $authorityRollbackPath `
        -ReadyPath $authorityReadyPath `
        -ContinuePath $authorityContinuePath
    $authorityReadyDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $authorityReadyPath -PathType Leaf) -and
        -not $authorityWaiter.Process.HasExited) {
        if ([DateTime]::UtcNow -ge $authorityReadyDeadline) { break }
        Start-Sleep -Milliseconds 20
    }
    Assert-True "rollback authority barrier reaches the exact pre-mutex seam" (
        Test-Path -LiteralPath $authorityReadyPath -PathType Leaf
    )
    $authorityFirstRollback = Invoke-ReceiptRollback `
        -InstallResult $authorityRaceInstall `
        -RollbackPath $authorityRollbackPath
    $authorityReplacement = Invoke-Installer `
        -CaseRoot $authorityRaceCase `
        -CustomBackupRoot (Join-Path $authorityRaceCase "backup-replacement") `
        -Apply
    $authorityReplacementPointer = @(
        Get-ChildItem -LiteralPath $authorityRaceCase `
            -Filter ".steadyagent-active-receipt-*.json" -File -Force
    )[0].FullName
    $authorityReplacementReceipt = Join-Path $authorityReplacement.BackupRoot "migration-receipt.json"
    $authorityReplacementFingerprint = Get-ManagedSurfaceFingerprint `
        -Roots @($authorityReplacement.CodexHome, $authorityReplacement.TargetRoot) `
        -Files @($authorityReplacement.ManagedPath, $authorityReplacement.GitConfigPath)
    $authorityReplacementPointerHash = (
        Get-FileHash -LiteralPath $authorityReplacementPointer -Algorithm SHA256
    ).Hash
    $authorityReplacementReceiptHash = (
        Get-FileHash -LiteralPath $authorityReplacementReceipt -Algorithm SHA256
    ).Hash
    [IO.File]::WriteAllText(
        $authorityContinuePath,
        "continue`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $authorityWaitCompleted = $authorityWaiter.Process.WaitForExit(30000)
    $authorityWaiterStdout = $authorityWaiter.Process.StandardOutput.ReadToEnd()
    $authorityWaiterStderr = $authorityWaiter.Process.StandardError.ReadToEnd()
    if ($authorityWaitCompleted) { $authorityWaiter.Process.WaitForExit() }
    $authorityWaiter.Process.Refresh()
    $authorityWaiterOutput = @($authorityWaiterStdout, $authorityWaiterStderr) -join "`n"
    $authorityBarrierDetail = (
        "first={0}; replacement={1}; wait={2}; exited={3}; exit={4}; output={5}" -f
        $authorityFirstRollback.ExitCode,
        $authorityReplacement.ExitCode,
        $authorityWaitCompleted,
        $authorityWaiter.Process.HasExited,
        $(if ($authorityWaiter.Process.HasExited) { $authorityWaiter.Process.ExitCode } else { -999 }),
        $authorityWaiterOutput
    )
    Assert-True "stale rollback authority is rejected after mutex acquisition" (
        $authorityFirstRollback.ExitCode -eq 0 -and
        $authorityReplacement.ExitCode -eq 0 -and
        $authorityWaitCompleted -and
        $authorityWaiter.Process.HasExited -and
        $authorityWaiter.Process.ExitCode -eq 2 -and
        $authorityWaiterOutput -match "authority changed before mutex acquisition"
    ) $authorityBarrierDetail
    Assert-True "stale rollback authority cannot modify the replacement transaction" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($authorityReplacement.CodexHome, $authorityReplacement.TargetRoot) `
            -Files @($authorityReplacement.ManagedPath, $authorityReplacement.GitConfigPath)) -ceq
                $authorityReplacementFingerprint -and
        (Get-FileHash -LiteralPath $authorityReplacementPointer -Algorithm SHA256).Hash -ceq
            $authorityReplacementPointerHash -and
        (Get-FileHash -LiteralPath $authorityReplacementReceipt -Algorithm SHA256).Hash -ceq
            $authorityReplacementReceiptHash
    ) $authorityWaiterOutput

    $midCrashCase = Join-Path $fixtureRoot "hard-kill-mid-apply"
    $midCrashCodex = Join-Path $midCrashCase "codex"
    $midCrashManaged = Join-Path $midCrashCase "managed\requirements.toml"
    $midCrashGitConfig = Join-Path $midCrashCase "gitconfig"
    New-Item -ItemType Directory -Path (Join-Path $midCrashCodex "rules") -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $midCrashManaged) -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $midCrashCodex "AGENTS.md"), "mid-crash-agent", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText(
        (Join-Path $midCrashCodex "rules\workflow-routing.md"),
        "mid-crash-v1-rule",
        [Text.Encoding]::UTF8
    )
    [IO.File]::WriteAllText($midCrashManaged, "mid-crash-managed", [Text.Encoding]::UTF8)
    & git config --file $midCrashGitConfig core.hooksPath "mid-crash-hooks"
    $midCrashPreimage = Get-ManagedSurfaceFingerprint `
        -Roots @($midCrashCodex, (Join-Path $midCrashCase "steadyagent")) `
        -Files @($midCrashManaged, $midCrashGitConfig)
    $midCrash = Invoke-Installer `
        -CaseRoot $midCrashCase `
        -Apply `
        -ReplaceExistingWorkflow `
        -InjectHardKillAfterOperation 40
    $midCrashReceiptPath = Join-Path $midCrash.BackupRoot "migration-receipt.json"
    $midCrashReceipt = if (Test-Path -LiteralPath $midCrashReceiptPath -PathType Leaf) {
        [IO.File]::ReadAllText($midCrashReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    else { $null }
    Assert-True "hard kill during file apply leaves an applying recovery receipt" (
        $midCrash.ExitCode -ne 0 -and
        $midCrashReceipt -and
        [string]$midCrashReceipt.status -eq "applying" -and
        $null -eq $midCrashReceipt.completed_utc -and
        $midCrash.Output -match [regex]::Escape($midCrashReceiptPath)
    ) $midCrash.Output
    Assert-True "applying receipt records only actually created directory identities" (
        $midCrashReceipt -and
        @($midCrashReceipt.created_directories).Count -gt 0 -and
        @($midCrashReceipt.created_directories | Where-Object {
            [string]$_.path -and
            [string]$_.volume_serial -match '^[0-9A-F]{8}$' -and
            [string]$_.file_id -match '^[0-9A-F]{16}$'
        }).Count -eq @($midCrashReceipt.created_directories).Count
    )
    $midCrashRollbackTool = Join-Path $midCrash.TargetRoot "tools\rollback.ps1"
    Assert-True "mid-apply hard kill lands the official rollback tool before later operations" (
        Test-Path -LiteralPath $midCrashRollbackTool -PathType Leaf
    )
    $midCrashOriginalStates = 0
    $midCrashPostStates = 0
    $midCrashUnknownStates = 0
    foreach ($entry in @($midCrashReceipt.entries)) {
        $destination = [string]$entry.destination
        $exists = Test-Path -LiteralPath $destination -PathType Leaf
        $hash = if ($exists) { (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash } else { $null }
        if ([string]$entry.action -eq "install" -and $exists -and
            $hash -eq [string]$entry.installed_sha256) {
            $midCrashPostStates++
        }
        elseif ([string]$entry.action -eq "remove" -and -not $exists) {
            $midCrashPostStates++
        }
        elseif ([bool]$entry.existed -and $exists -and
            $hash -eq [string]$entry.original_sha256) {
            $midCrashOriginalStates++
        }
        elseif (-not [bool]$entry.existed -and -not $exists) {
            $midCrashOriginalStates++
        }
        else {
            $midCrashUnknownStates++
        }
    }
    Assert-True "mid-apply hard kill leaves only a known mixed original-post state" (
        $midCrashOriginalStates -gt 0 -and
        $midCrashPostStates -gt 0 -and
        $midCrashUnknownStates -eq 0
    ) (
        "original=" + $midCrashOriginalStates +
        "; post=" + $midCrashPostStates +
        "; unknown=" + $midCrashUnknownStates
    )

    $midCrashMixedFingerprint = Get-ManagedSurfaceFingerprint `
        -Roots @($midCrash.CodexHome, $midCrash.TargetRoot) `
        -Files @($midCrash.ManagedPath, $midCrash.GitConfigPath)
    $midCrashDryRun = Invoke-ReceiptRollback -InstallResult $midCrash -DryRun
    Assert-True "applying receipt rollback dry-run succeeds" (
        $midCrashDryRun.ExitCode -eq 0 -and
        $midCrashDryRun.Output -match "DRY-RUN Boring Is All You Need v2[.]0[.]0 rollback"
    ) $midCrashDryRun.Output
    Assert-True "applying receipt rollback dry-run performs zero writes" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($midCrash.CodexHome, $midCrash.TargetRoot) `
            -Files @($midCrash.ManagedPath, $midCrash.GitConfigPath)) -eq
            $midCrashMixedFingerprint
    ) $midCrashDryRun.Output

    $heldApplyingMutex = New-Object Threading.Mutex(
        $true,
        (Get-TestMigrationMutexName -TestRoot $fixtureRoot)
    )
    try {
        $blockedApplyingRollback = Invoke-ReceiptRollback -InstallResult $midCrash
        Assert-True "fixture-scoped mutex blocks applying receipt recovery" (
            $blockedApplyingRollback.ExitCode -ne 0
        ) $blockedApplyingRollback.Output
        Assert-True "blocked applying receipt recovery performs zero writes" (
            (Get-ManagedSurfaceFingerprint `
                -Roots @($midCrash.CodexHome, $midCrash.TargetRoot) `
                -Files @($midCrash.ManagedPath, $midCrash.GitConfigPath)) -eq
                $midCrashMixedFingerprint
        ) $blockedApplyingRollback.Output
    }
    finally {
        $heldApplyingMutex.ReleaseMutex()
        $heldApplyingMutex.Dispose()
    }

    $midCrashReceiptBytes = [IO.File]::ReadAllBytes($midCrashReceiptPath)
    $midCrashTamperedReceipt = (
        [IO.File]::ReadAllText($midCrashReceiptPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    $midCrashTamperedReceipt.failure = "tampered"
    [IO.File]::WriteAllText(
        $midCrashReceiptPath,
        (($midCrashTamperedReceipt | ConvertTo-Json -Depth 7) + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )
    $tamperedApplyingRollback = Invoke-ReceiptRollback -InstallResult $midCrash
    Assert-True "rollback rejects a tampered applying receipt" (
        $tamperedApplyingRollback.ExitCode -ne 0 -and
        $tamperedApplyingRollback.Output -match "integrity"
    ) $tamperedApplyingRollback.Output
    Assert-True "tampered applying receipt rejection performs zero target writes" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($midCrash.CodexHome, $midCrash.TargetRoot) `
            -Files @($midCrash.ManagedPath, $midCrash.GitConfigPath)) -eq
            $midCrashMixedFingerprint
    ) $tamperedApplyingRollback.Output
    [IO.File]::WriteAllBytes($midCrashReceiptPath, $midCrashReceiptBytes)

    $midCrashPostEntry = @(
        $midCrashReceipt.entries |
            Where-Object {
                [string]$_.action -eq "install" -and
                (Test-Path -LiteralPath ([string]$_.destination) -PathType Leaf) -and
                (Get-FileHash -LiteralPath ([string]$_.destination) -Algorithm SHA256).Hash -eq
                    [string]$_.installed_sha256
            }
    )[0]
    $midCrashPostPath = [string]$midCrashPostEntry.destination
    $midCrashPostBytes = [IO.File]::ReadAllBytes($midCrashPostPath)
    [IO.File]::WriteAllText($midCrashPostPath, "unknown-applying-target-drift", [Text.Encoding]::UTF8)
    $driftedApplyingRollback = Invoke-ReceiptRollback -InstallResult $midCrash
    Assert-True "rollback rejects unknown target drift in an applying receipt" (
        $driftedApplyingRollback.ExitCode -ne 0 -and
        $driftedApplyingRollback.Output -match "known original or post-install state"
    ) $driftedApplyingRollback.Output
    [IO.File]::WriteAllBytes($midCrashPostPath, $midCrashPostBytes)
    Assert-True "applying target drift rejection performs zero other writes" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($midCrash.CodexHome, $midCrash.TargetRoot) `
            -Files @($midCrash.ManagedPath, $midCrash.GitConfigPath)) -eq
            $midCrashMixedFingerprint
    ) $driftedApplyingRollback.Output

    $midCrashSnapshotEntry = @($midCrashReceipt.entries | Where-Object { [bool]$_.existed })[0]
    $midCrashSnapshotPath = Join-Path $midCrash.BackupRoot ([string]$midCrashSnapshotEntry.snapshot_name)
    $midCrashSnapshotBytes = [IO.File]::ReadAllBytes($midCrashSnapshotPath)
    [IO.File]::WriteAllText($midCrashSnapshotPath, "unknown-snapshot-drift", [Text.Encoding]::UTF8)
    $snapshotDriftApplyingRollback = Invoke-ReceiptRollback -InstallResult $midCrash
    Assert-True "rollback rejects snapshot drift for an applying receipt" (
        $snapshotDriftApplyingRollback.ExitCode -ne 0 -and
        $snapshotDriftApplyingRollback.Output -match "Snapshot verification failed"
    ) $snapshotDriftApplyingRollback.Output
    Assert-True "applying snapshot drift rejection performs zero target writes" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($midCrash.CodexHome, $midCrash.TargetRoot) `
            -Files @($midCrash.ManagedPath, $midCrash.GitConfigPath)) -eq
            $midCrashMixedFingerprint
    ) $snapshotDriftApplyingRollback.Output
    [IO.File]::WriteAllBytes($midCrashSnapshotPath, $midCrashSnapshotBytes)

    $failedApplyingRollback = Invoke-ReceiptRollback `
        -InstallResult $midCrash `
        -InjectFailureAfterRestore 2
    Assert-True "injected applying recovery failure returns nonzero" (
        $failedApplyingRollback.ExitCode -ne 0 -and
        $failedApplyingRollback.Output -match "Injected rollback recovery failure"
    ) $failedApplyingRollback.Output
    Assert-True "failed applying recovery reapplies the exact entering mixed state" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($midCrash.CodexHome, $midCrash.TargetRoot) `
            -Files @($midCrash.ManagedPath, $midCrash.GitConfigPath)) -eq
            $midCrashMixedFingerprint
    ) $failedApplyingRollback.Output

    $midCrashRecovery = Invoke-ReceiptRollback -InstallResult $midCrash
    Assert-True "applying receipt can restore the complete preimage" (
        $midCrashRecovery.ExitCode -eq 0
    ) $midCrashRecovery.Output
    $midCrashRecoveredReceipt = (
        [IO.File]::ReadAllText($midCrashReceiptPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    Assert-True "successful applying recovery publishes an integrity-valid rolled-back receipt" (
        [string]$midCrashRecoveredReceipt.status -eq "rolled_back" -and
        $null -eq $midCrashRecoveredReceipt.completed_utc -and
        [string]$midCrashRecoveredReceipt.restored_utc -and
        [string]$midCrashRecoveredReceipt.receipt_integrity_sha256 -ceq
            (Get-ReceiptIntegritySha256 -Receipt $midCrashRecoveredReceipt)
    )
    Assert-True "mid-apply crash recovery restores every managed surface" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($midCrashCodex, $midCrash.TargetRoot) `
            -Files @($midCrashManaged, $midCrashGitConfig)) -eq
            $midCrashPreimage
    ) $midCrashRecovery.Output

    $gitCasCase = Join-Path $fixtureRoot "git-config-cas-race"
    $gitCasConfig = Join-Path $gitCasCase "gitconfig"
    New-Item -ItemType Directory -Path $gitCasCase -Force | Out-Null
    & git config --file $gitCasConfig core.hooksPath "git-cas-original"
    if ($LASTEXITCODE -ne 0) { throw "Could not prepare Git config CAS fixture." }
    $gitCasTargetPreimage = Get-ManagedSurfaceFingerprint `
        -Roots @(
            (Join-Path $gitCasCase "codex"),
            (Join-Path $gitCasCase "steadyagent")
        ) `
        -Files @((Join-Path $gitCasCase "managed\requirements.toml"))
    $gitCasRace = Invoke-Installer `
        -CaseRoot $gitCasCase `
        -Apply `
        -ReplaceExistingWorkflow `
        -InjectGitConfigCasMutationValue "git-cas-third-party"
    $gitCasReceiptPath = Join-Path $gitCasRace.BackupRoot "migration-receipt.json"
    $gitCasReceipt = if (Test-Path -LiteralPath $gitCasReceiptPath -PathType Leaf) {
        [IO.File]::ReadAllText($gitCasReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    else { $null }
    $gitCasObserved = & git config --file $gitCasConfig --get core.hooksPath
    Assert-True "Git config CAS rejects a third-party value in the final write window" (
        $gitCasRace.ExitCode -ne 0 -and
        $gitCasReceipt -and
        [string]$gitCasReceipt.status -eq "rollback_incomplete" -and
        [string]$gitCasReceipt.failure -match "Git config changed before bound activation"
    ) $gitCasRace.Output
    Assert-True "Git config CAS preserves the third-party value" (
        $LASTEXITCODE -eq 0 -and $gitCasObserved -ceq "git-cas-third-party"
    ) $gitCasRace.Output
    Assert-True "Git config CAS rejection restores all non-Git targets" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($gitCasRace.CodexHome, $gitCasRace.TargetRoot) `
            -Files @($gitCasRace.ManagedPath)) -eq $gitCasTargetPreimage
    ) $gitCasRace.Output

    $gitCrashCase = Join-Path $fixtureRoot "hard-kill-after-git"
    $gitCrashCodex = Join-Path $gitCrashCase "codex"
    $gitCrashManaged = Join-Path $gitCrashCase "managed\requirements.toml"
    $gitCrashGitConfig = Join-Path $gitCrashCase "gitconfig"
    New-Item -ItemType Directory -Path $gitCrashCodex -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $gitCrashManaged) -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $gitCrashCodex "AGENTS.md"), "git-crash-agent", [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($gitCrashManaged, "git-crash-managed", [Text.Encoding]::UTF8)
    & git config --file $gitCrashGitConfig core.hooksPath "git-crash-hooks"
    $gitCrashPreimage = Get-ManagedSurfaceFingerprint `
        -Roots @($gitCrashCodex, (Join-Path $gitCrashCase "steadyagent")) `
        -Files @($gitCrashManaged, $gitCrashGitConfig)
    $gitCrash = Invoke-Installer `
        -CaseRoot $gitCrashCase `
        -Apply `
        -ReplaceExistingWorkflow `
        -InjectHardKillAfterGitActivation
    $gitCrashReceiptPath = Join-Path $gitCrash.BackupRoot "migration-receipt.json"
    $gitCrashReceipt = if (Test-Path -LiteralPath $gitCrashReceiptPath -PathType Leaf) {
        [IO.File]::ReadAllText($gitCrashReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    else { $null }
    Assert-True "hard kill after Git activation preserves an applying receipt" (
        $gitCrash.ExitCode -ne 0 -and
        $gitCrashReceipt -and
        [string]$gitCrashReceipt.status -eq "applying" -and
        $null -eq $gitCrashReceipt.completed_utc
    ) $gitCrash.Output
    Assert-True "Git-activation crash occurs after all target postimages" (
        @($gitCrashReceipt.entries | Where-Object {
            if ([string]$_.action -eq "install") {
                -not (Test-Path -LiteralPath ([string]$_.destination) -PathType Leaf) -or
                (Get-FileHash -LiteralPath ([string]$_.destination) -Algorithm SHA256).Hash -ne
                    [string]$_.installed_sha256
            }
            else {
                Test-Path -LiteralPath ([string]$_.destination)
            }
        }).Count -eq 0 -and
        (& git config --file $gitCrashGitConfig --get core.hooksPath) -eq
            [string]$gitCrashReceipt.git_hooks_path_after
    )
    $gitCrashRecovery = Invoke-ReceiptRollback -InstallResult $gitCrash
    Assert-True "post-Git-activation applying receipt can be recovered" (
        $gitCrashRecovery.ExitCode -eq 0
    ) $gitCrashRecovery.Output
    Assert-True "post-Git-activation crash recovery restores every managed surface" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($gitCrashCodex, $gitCrash.TargetRoot) `
            -Files @($gitCrashManaged, $gitCrashGitConfig)) -eq
            $gitCrashPreimage
    ) $gitCrashRecovery.Output

    $rollbackGitCasCase = Join-Path $fixtureRoot "rollback-git-config-cas-race"
    $rollbackGitCasConfig = Join-Path $rollbackGitCasCase "gitconfig"
    New-Item -ItemType Directory -Path $rollbackGitCasCase -Force | Out-Null
    & git config --file $rollbackGitCasConfig core.hooksPath "rollback-git-cas-original"
    if ($LASTEXITCODE -ne 0) { throw "Could not prepare rollback Git CAS fixture." }
    $rollbackGitCasInstall = Invoke-Installer `
        -CaseRoot $rollbackGitCasCase `
        -Apply `
        -ReplaceExistingWorkflow
    $rollbackGitCasPostimage = Get-ManagedSurfaceFingerprint `
        -Roots @($rollbackGitCasInstall.CodexHome, $rollbackGitCasInstall.TargetRoot) `
        -Files @($rollbackGitCasInstall.ManagedPath)
    $rollbackGitCas = Invoke-ReceiptRollback `
        -InstallResult $rollbackGitCasInstall `
        -InjectGitConfigCasMutationValue "rollback-git-cas-third-party"
    $rollbackGitCasObserved = & git config --file $rollbackGitCasConfig --get core.hooksPath
    Assert-True "rollback Git config CAS rejects a third-party value in the final window" (
        $rollbackGitCas.ExitCode -ne 0 -and
        $rollbackGitCas.Output -match "Git config changed before bound restoration"
    ) $rollbackGitCas.Output
    Assert-True "rollback Git config CAS preserves the third-party value" (
        $LASTEXITCODE -eq 0 -and $rollbackGitCasObserved -ceq "rollback-git-cas-third-party"
    ) $rollbackGitCas.Output
    Assert-True "failed rollback Git CAS compensates all non-Git targets" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($rollbackGitCasInstall.CodexHome, $rollbackGitCasInstall.TargetRoot) `
            -Files @($rollbackGitCasInstall.ManagedPath)) -eq $rollbackGitCasPostimage
    ) $rollbackGitCas.Output

    $incompleteRecoveryCase = Join-Path $fixtureRoot "incomplete-applying-recovery"
    $incompleteRecoveryInstall = Invoke-Installer `
        -CaseRoot $incompleteRecoveryCase `
        -Apply `
        -InjectHardKillAfterOperation 40
    $incompleteRecoveryReceiptPath = Join-Path $incompleteRecoveryInstall.BackupRoot "migration-receipt.json"
    $incompleteRecovery = Invoke-ReceiptRollback `
        -InstallResult $incompleteRecoveryInstall `
        -InjectFailureAfterRestore 1 `
        -InjectReapplyFailure
    $incompleteRecoveryReceipt = (
        [IO.File]::ReadAllText($incompleteRecoveryReceiptPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    Assert-True "incomplete applying recovery returns the manual-recovery exit code" (
        $incompleteRecovery.ExitCode -eq 3
    ) $incompleteRecovery.Output
    Assert-True "incomplete applying recovery durably publishes rollback-incomplete" (
        [string]$incompleteRecoveryReceipt.status -eq "rollback_incomplete" -and
        [string]$incompleteRecoveryReceipt.failure -match "compensation was incomplete" -and
        [string]$incompleteRecoveryReceipt.receipt_integrity_sha256 -ceq
            (Get-ReceiptIntegritySha256 -Receipt $incompleteRecoveryReceipt)
    ) $incompleteRecovery.Output
    $incompleteRecoveryJournalPath = Join-Path `
        $incompleteRecoveryInstall.BackupRoot "rollback-journal.json"
    $incompleteRecoveryReceiptHash = (
        Get-FileHash -LiteralPath $incompleteRecoveryReceiptPath -Algorithm SHA256
    ).Hash
    $incompleteRecoveryJournalHash = (
        Get-FileHash -LiteralPath $incompleteRecoveryJournalPath -Algorithm SHA256
    ).Hash
    $incompleteRecoverySurface = Get-ManagedSurfaceFingerprint `
        -Roots @($incompleteRecoveryInstall.CodexHome, $incompleteRecoveryInstall.TargetRoot) `
        -Files @($incompleteRecoveryInstall.ManagedPath, $incompleteRecoveryInstall.GitConfigPath)
    $incompleteRecoveryRetry = Invoke-ReceiptRollback `
        -InstallResult $incompleteRecoveryInstall
    Assert-True "rollback-incomplete retry preserves the manual-recovery exit code" (
        $incompleteRecoveryRetry.ExitCode -eq 3 -and
        $incompleteRecoveryRetry.Output -match "requires manual recovery"
    ) $incompleteRecoveryRetry.Output
    Assert-True "rollback-incomplete retry makes zero managed or evidence writes" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($incompleteRecoveryInstall.CodexHome, $incompleteRecoveryInstall.TargetRoot) `
            -Files @($incompleteRecoveryInstall.ManagedPath, $incompleteRecoveryInstall.GitConfigPath)) -ceq
                $incompleteRecoverySurface -and
        (Get-FileHash -LiteralPath $incompleteRecoveryReceiptPath -Algorithm SHA256).Hash -ceq
            $incompleteRecoveryReceiptHash -and
        (Get-FileHash -LiteralPath $incompleteRecoveryJournalPath -Algorithm SHA256).Hash -ceq
            $incompleteRecoveryJournalHash
    ) $incompleteRecoveryRetry.Output

    $removalSubstitutionCase = Join-Path $fixtureRoot "removal-substitution"
    $oldMigrationTestMode = $env:STEADYAGENT_TEST_MODE
    try {
        $env:STEADYAGENT_TEST_MODE = "1"
        $removalSubstitution = Invoke-Installer `
            -CaseRoot $removalSubstitutionCase `
            -Apply `
            -InjectRemovalSubstitution
    }
    finally {
        if ($null -eq $oldMigrationTestMode) { Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_MODE = $oldMigrationTestMode }
    }
    Assert-True "installer rejects an equal-count V1 removal substitution" (
        $removalSubstitution.ExitCode -ne 0 -and
        $removalSubstitution.Output -match "V1 removal manifest projection mismatch"
    ) $removalSubstitution.Output
    Assert-True "rejected V1 removal substitution performs zero case writes" (
        -not (Test-Path -LiteralPath $removalSubstitutionCase)
    )

    $mutexUnavailableCase = Join-Path $fixtureRoot "mutex-unavailable"
    $oldMigrationTestMode = $env:STEADYAGENT_TEST_MODE
    try {
        $env:STEADYAGENT_TEST_MODE = "1"
        $mutexUnavailable = Invoke-Installer `
            -CaseRoot $mutexUnavailableCase `
            -Apply `
            -InjectMutexFailure
    }
    finally {
        if ($null -eq $oldMigrationTestMode) { Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_MODE = $oldMigrationTestMode }
    }
    Assert-True "unavailable machine-wide migration mutex fails closed" (
        $mutexUnavailable.ExitCode -ne 0 -and
        $mutexUnavailable.Output -match "machine-wide migration mutex"
    ) $mutexUnavailable.Output
    Assert-True "unavailable machine-wide mutex performs zero case writes" (
        -not (Test-Path -LiteralPath $mutexUnavailableCase)
    )
    $installerSource = [IO.File]::ReadAllText($installer, [Text.Encoding]::UTF8)
    $rollbackSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "rollback.ps1"), [Text.Encoding]::UTF8)
    Assert-True "production migration lock remains machine-wide while fixtures are root-scoped" (
        $installerSource -match [regex]::Escape("Global\SteadyAgentV2Migration") -and
        $rollbackSource -match [regex]::Escape("Global\SteadyAgentV2Migration") -and
        $installerSource -match [regex]::Escape("Local\SteadyAgentV2MigrationTest_") -and
        $rollbackSource -match [regex]::Escape("Local\SteadyAgentV2MigrationTest_")
    )
    Assert-True "fixture mutex helper canonicalizes Windows path case and trailing separators" (
        (Get-TestMigrationMutexName -TestRoot $fixtureRoot) -ceq
        (Get-TestMigrationMutexName -TestRoot ($fixtureRoot.ToUpperInvariant() + '\'))
    )
    Assert-True "migration mutex excludes unrelated authenticated users" (
        $installerSource -match [regex]::Escape("[Security.Principal.WindowsIdentity]::GetCurrent().User") -and
        $rollbackSource -match [regex]::Escape("[Security.Principal.WindowsIdentity]::GetCurrent().User") -and
        $installerSource -notmatch "AuthenticatedUserSid" -and
        $rollbackSource -notmatch "AuthenticatedUserSid" -and
        $installerSource -match "Assert-SteadyAgentMigrationMutexSecurity" -and
        $rollbackSource -match "Assert-SteadyAgentMigrationMutexSecurity" -and
        $installerSource -match "AreAccessRulesProtected" -and
        $rollbackSource -match "AreAccessRulesProtected"
    )
    Assert-True "production migration rejects elevation outside the exact GitHub fixture contract" (
        $installerSource -match "non-elevated PowerShell session" -and
        $installerSource -match [regex]::Escape('$TestAsElevated -or ($isProcessElevated -and -not $allowElevatedFixture)') -and
        $installerSource -match 'STEADYAGENT_ALLOW_ELEVATED_FIXTURE' -and
        $installerSource -match 'GITHUB_ACTIONS' -and $installerSource -match 'RUNNER_OS' -and
        $rollbackSource -match "non-elevated PowerShell process" -and
        $rollbackSource -match [regex]::Escape('$TestAsElevated -or ($isProcessElevated -and -not $allowElevatedFixture)') -and
        $rollbackSource -match 'STEADYAGENT_ALLOW_ELEVATED_FIXTURE' -and
        $rollbackSource -match 'GITHUB_ACTIONS' -and $rollbackSource -match 'RUNNER_OS'
    )
    Assert-True "production migration exposes no protected recovery capsule entry point" (
        $installerSource -notmatch "AcknowledgeTrustedElevationSession|RequireProtectedRecovery|RecoveryRoot|TestRecoverySddl|InjectProtectedReceipt|SteadyAgent\\recovery|Protected recovery receipt|recovery capsule" -and
        $rollbackSource -notmatch "AcknowledgeTrustedElevationSession|RequireProtectedRecovery|RecoveryRoot|TestRecoverySddl|InjectProtectedReceipt|SteadyAgent\\recovery|Protected recovery receipt|recovery capsule"
    )

    $apostropheCase = Join-Path $fixtureRoot "O'Connor"
    $apostropheInstall = Invoke-Installer -CaseRoot $apostropheCase -Apply
    $apostropheManagedText = if (Test-Path -LiteralPath $apostropheInstall.ManagedPath -PathType Leaf) {
        [IO.File]::ReadAllText($apostropheInstall.ManagedPath, [Text.Encoding]::UTF8)
    } else { "" }
    Assert-True "apostrophe path install succeeds" ($apostropheInstall.ExitCode -eq 0) $apostropheInstall.Output
    Assert-True "apostrophe path renders valid TOML basic strings" (
        (Test-ManagedTomlBasicStrings -Text $apostropheManagedText) -and
        $apostropheManagedText.Contains("O'Connor") -and
        -not $apostropheManagedText.Contains("%STEADYAGENT_HOME")
    ) $apostropheManagedText

    $packageReadmePath = Join-Path $repoRoot "README.md"
    $packageReadmeHash = (Get-FileHash -LiteralPath $packageReadmePath -Algorithm SHA256).Hash
    $packageManagedCase = Join-Path $fixtureRoot "package-managed-overlap"
    $packageManaged = Invoke-Installer -CaseRoot $packageManagedCase -CustomManagedConfigPath $packageReadmePath
    Assert-True "ManagedConfigPath cannot overlap PackageRoot" ($packageManaged.ExitCode -ne 0) $packageManaged.Output
    Assert-True "rejected package managed overlap performs zero writes" (
        (Get-FileHash -LiteralPath $packageReadmePath -Algorithm SHA256).Hash -eq $packageReadmeHash -and
        -not (Test-Path -LiteralPath $packageManagedCase)
    )

    $packageTargetCase = Join-Path $fixtureRoot "package-target-overlap"
    $packageTarget = Invoke-Installer -CaseRoot $packageTargetCase -CustomTargetRoot $repoRoot
    Assert-True "TargetRoot cannot equal PackageRoot" ($packageTarget.ExitCode -ne 0) $packageTarget.Output
    Assert-True "rejected package target overlap performs zero writes" (
        (Get-FileHash -LiteralPath $packageReadmePath -Algorithm SHA256).Hash -eq $packageReadmeHash -and
        -not (Test-Path -LiteralPath $packageTargetCase)
    )

    $packageBackupCase = Join-Path $fixtureRoot "package-backup-overlap"
    $packageBackupPath = Join-Path $repoRoot (".steadyagent-test-backup-" + [guid]::NewGuid().ToString("N"))
    $packageBackup = Invoke-Installer -CaseRoot $packageBackupCase -CustomBackupRoot $packageBackupPath
    Assert-True "BackupRoot cannot be inside PackageRoot" ($packageBackup.ExitCode -ne 0) $packageBackup.Output
    Assert-True "rejected package backup overlap performs zero writes" (
        -not (Test-Path -LiteralPath $packageBackupPath) -and
        -not (Test-Path -LiteralPath $packageBackupCase)
    )

    $backupEqualsTargetCase = Join-Path $fixtureRoot "backup-equals-target"
    $backupEqualsTargetPath = Join-Path $backupEqualsTargetCase "shared"
    $backupEqualsTarget = Invoke-Installer -CaseRoot $backupEqualsTargetCase `
        -CustomTargetRoot $backupEqualsTargetPath `
        -CustomBackupRoot $backupEqualsTargetPath
    Assert-True "BackupRoot cannot equal TargetRoot" ($backupEqualsTarget.ExitCode -ne 0) $backupEqualsTarget.Output
    Assert-True "rejected TargetRoot overlap performs zero writes" (-not (Test-Path -LiteralPath $backupEqualsTargetCase))

    $backupEqualsCodexCase = Join-Path $fixtureRoot "backup-equals-codex"
    $backupEqualsCodexPath = Join-Path $backupEqualsCodexCase "shared"
    $backupEqualsCodex = Invoke-Installer -CaseRoot $backupEqualsCodexCase `
        -CustomCodexHome $backupEqualsCodexPath `
        -CustomBackupRoot $backupEqualsCodexPath
    Assert-True "BackupRoot cannot equal CodexHome" ($backupEqualsCodex.ExitCode -ne 0) $backupEqualsCodex.Output
    Assert-True "rejected CodexHome overlap performs zero writes" (-not (Test-Path -LiteralPath $backupEqualsCodexCase))

    $backupAncestorCase = Join-Path $fixtureRoot "backup-ancestor"
    $backupAncestor = Invoke-Installer -CaseRoot $backupAncestorCase `
        -CustomTargetRoot (Join-Path $backupAncestorCase "nested/steadyagent") `
        -CustomCodexHome (Join-Path $fixtureRoot "backup-ancestor-codex") `
        -CustomBackupRoot $backupAncestorCase
    Assert-True "BackupRoot cannot contain TargetRoot" ($backupAncestor.ExitCode -ne 0) $backupAncestor.Output
    Assert-True "rejected backup ancestor performs zero writes" (-not (Test-Path -LiteralPath $backupAncestorCase))

    $backupCodexAncestorCase = Join-Path $fixtureRoot "backup-codex-ancestor"
    $backupCodexAncestor = Invoke-Installer -CaseRoot $backupCodexAncestorCase `
        -CustomTargetRoot (Join-Path $fixtureRoot "backup-codex-ancestor-target") `
        -CustomCodexHome (Join-Path $backupCodexAncestorCase "nested/codex") `
        -CustomBackupRoot $backupCodexAncestorCase
    Assert-True "BackupRoot cannot contain CodexHome" ($backupCodexAncestor.ExitCode -ne 0) $backupCodexAncestor.Output
    Assert-True "rejected Codex ancestor performs zero writes" (-not (Test-Path -LiteralPath $backupCodexAncestorCase))

    $backupEqualsManagedCase = Join-Path $fixtureRoot "backup-equals-managed"
    $backupEqualsManagedPath = Join-Path $backupEqualsManagedCase "shared"
    $backupEqualsManaged = Invoke-Installer -CaseRoot $backupEqualsManagedCase `
        -CustomBackupRoot $backupEqualsManagedPath `
        -CustomManagedConfigPath $backupEqualsManagedPath
    Assert-True "BackupRoot cannot equal ManagedConfigPath" ($backupEqualsManaged.ExitCode -ne 0) $backupEqualsManaged.Output
    Assert-True "rejected managed equality performs zero writes" (-not (Test-Path -LiteralPath $backupEqualsManagedCase))

    $backupContainsManagedCase = Join-Path $fixtureRoot "backup-contains-managed"
    $backupContainsManaged = Invoke-Installer -CaseRoot $backupContainsManagedCase `
        -CustomBackupRoot (Join-Path $backupContainsManagedCase "backup") `
        -CustomManagedConfigPath (Join-Path $backupContainsManagedCase "backup/requirements.toml")
    Assert-True "BackupRoot cannot contain ManagedConfigPath" ($backupContainsManaged.ExitCode -ne 0) $backupContainsManaged.Output
    Assert-True "rejected managed descendant performs zero writes" (-not (Test-Path -LiteralPath $backupContainsManagedCase))

    $backupEqualsGitCase = Join-Path $fixtureRoot "backup-equals-git"
    $backupEqualsGitPath = Join-Path $backupEqualsGitCase "shared"
    $backupEqualsGit = Invoke-Installer -CaseRoot $backupEqualsGitCase `
        -CustomBackupRoot $backupEqualsGitPath `
        -CustomGitConfigPath $backupEqualsGitPath
    Assert-True "BackupRoot cannot equal GitConfigPath" ($backupEqualsGit.ExitCode -ne 0) $backupEqualsGit.Output
    Assert-True "rejected Git config equality performs zero writes" (-not (Test-Path -LiteralPath $backupEqualsGitCase))

    $targetContainsManagedCase = Join-Path $fixtureRoot "target-contains-managed"
    $targetContainsManagedRoot = Join-Path $targetContainsManagedCase "steadyagent"
    $targetContainsManaged = Invoke-Installer -CaseRoot $targetContainsManagedCase `
        -CustomTargetRoot $targetContainsManagedRoot `
        -CustomManagedConfigPath (Join-Path $targetContainsManagedRoot "requirements.toml")
    Assert-True "TargetRoot cannot contain ManagedConfigPath" ($targetContainsManaged.ExitCode -ne 0) $targetContainsManaged.Output
    Assert-True "rejected active file overlap performs zero writes" (-not (Test-Path -LiteralPath $targetContainsManagedCase))

    $junctionSwapCase = Join-Path $fixtureRoot "junction-swap-publish"
    $junctionEscapeRoot = Join-Path $junctionSwapCase "escape-target"
    $junctionParkedRoot = Join-Path $junctionSwapCase "parked-target"
    New-Item -ItemType Directory -Path $junctionEscapeRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $junctionEscapeRoot "sentinel.txt"),
        "escape-sentinel`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $junctionEscapeBefore = Get-ManagedSurfaceFingerprint `
        -Roots @($junctionEscapeRoot) `
        -Files @()
    $junctionSwap = Invoke-Installer `
        -CaseRoot $junctionSwapCase `
        -Apply `
        -InjectJunctionSwapAt 1 `
        -InjectJunctionParkedRoot $junctionParkedRoot `
        -InjectJunctionEscapeRoot $junctionEscapeRoot
    Assert-True "install publish blocks a junction swap after validation" (
        $junctionSwap.ExitCode -eq 0 -and
        $junctionSwap.Output -match "TEST junction swap blocked"
    ) $junctionSwap.Output
    Assert-True "blocked install junction swap leaves the escape tree byte-identical" (
        (Get-ManagedSurfaceFingerprint -Roots @($junctionEscapeRoot) -Files @()) -ceq
            $junctionEscapeBefore
    ) $junctionSwap.Output

    $skillRoutingCase = Join-Path $fixtureRoot "skill-routing-clean-session"
    $skillRoutingHome = Join-Path $skillRoutingCase "home"
    $skillRoutingTarget = Join-Path $skillRoutingHome ".steadyagent"
    New-Item -ItemType Directory -Path $skillRoutingHome -Force | Out-Null
    $skillRoutingInstall = Invoke-Installer `
        -CaseRoot $skillRoutingCase `
        -Apply `
        -CustomTargetRoot $skillRoutingTarget
    Assert-True "production-shaped skill routing fixture installs successfully" (
        $skillRoutingInstall.ExitCode -eq 0
    ) $skillRoutingInstall.Output
    $skillRoutingProbePath = Join-Path $skillRoutingCase "probe-installed-skill-search.ps1"
    [IO.File]::WriteAllText(
        $skillRoutingProbePath,
        @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not [string]::IsNullOrWhiteSpace($env:STEADYAGENT_HOME)) { exit 10 }
$SteadyAgentRoot = Join-Path $HOME ".steadyagent"
$SkillSearch = Join-Path $SteadyAgentRoot "tools\skill-search.ps1"
if (-not (Test-Path -LiteralPath $SkillSearch -PathType Leaf)) { exit 11 }
$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $SkillSearch,
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count -ne 0) { exit 12 }
Write-Output ([IO.Path]::GetFullPath($SkillSearch))
'@,
        (New-Object Text.UTF8Encoding($false))
    )
    $skillProbeStart = New-Object Diagnostics.ProcessStartInfo
    $skillProbeStart.FileName = Join-Path $PSHOME "powershell.exe"
    $skillProbeStart.Arguments = (
        '-NoProfile -ExecutionPolicy Bypass -File "' + $skillRoutingProbePath + '"'
    )
    $skillProbeStart.UseShellExecute = $false
    $skillProbeStart.CreateNoWindow = $true
    $skillProbeStart.RedirectStandardOutput = $true
    $skillProbeStart.RedirectStandardError = $true
    if ($skillProbeStart.EnvironmentVariables.ContainsKey("STEADYAGENT_HOME")) {
        $skillProbeStart.EnvironmentVariables.Remove("STEADYAGENT_HOME")
    }
    $skillRoutingHomeFull = [IO.Path]::GetFullPath($skillRoutingHome)
    $skillRoutingHomeDrive = [IO.Path]::GetPathRoot($skillRoutingHomeFull).TrimEnd("\")
    $skillProbeStart.EnvironmentVariables["USERPROFILE"] = $skillRoutingHomeFull
    $skillProbeStart.EnvironmentVariables["HOMEDRIVE"] = $skillRoutingHomeDrive
    $skillProbeStart.EnvironmentVariables["HOMEPATH"] =
        $skillRoutingHomeFull.Substring($skillRoutingHomeDrive.Length)
    $skillProbeProcess = New-Object Diagnostics.Process
    try {
        $skillProbeProcess.StartInfo = $skillProbeStart
        if (-not $skillProbeProcess.Start()) { throw "Could not start the skill routing probe." }
        $skillProbeOutput = $skillProbeProcess.StandardOutput.ReadToEnd().Trim()
        $skillProbeError = $skillProbeProcess.StandardError.ReadToEnd().Trim()
        $skillProbeProcess.WaitForExit()
        Assert-True "installed skill routing resolves in a clean session without STEADYAGENT_HOME" (
            $skillProbeProcess.ExitCode -eq 0 -and
            [IO.Path]::GetFullPath($skillProbeOutput).Equals(
                (Join-Path $skillRoutingTarget "tools\skill-search.ps1"),
                [StringComparison]::OrdinalIgnoreCase
            )
        ) ($skillProbeError + "; " + $skillProbeOutput)
    }
    finally {
        $skillProbeProcess.Dispose()
    }

    $freshCase = Join-Path $fixtureRoot "fresh"
    New-Item -ItemType Directory -Path $freshCase -Force | Out-Null
    $freshIdentityConfig = Join-Path $freshCase "gitconfig"
    & git config --file $freshIdentityConfig user.name "Strict Diagnosis Fixture"
    & git config --file $freshIdentityConfig user.email "strict-diagnosis@example.invalid"
    if ($LASTEXITCODE -ne 0) { throw "Could not prepare the fresh Git identity fixture." }
    $fresh = Invoke-Installer -CaseRoot $freshCase -Apply
    Assert-True "fresh install succeeds" ($fresh.ExitCode -eq 0) $fresh.Output
    Assert-True "successful install prints the canonical new-task strict audit" (
        $fresh.Output -match [regex]::Escape((Join-Path $fresh.BackupRoot "migration-receipt.json")) -and
        $fresh.Output -match 'CODEX_THREAD_ID' -and
        $fresh.Output -match 'skill-index[.]ps1' -and
        $fresh.Output -match 'RequireInstalledBytes' -and
        $fresh.Output -match 'RequireHooksActive' -and
        $fresh.Output -match 'RequireRuntimeCatalog' -and
        $fresh.Output -match 'RequireGitIdentity'
    ) $fresh.Output
    Assert-True "non-elevated custom fixture uses its reviewed backup receipt" (
        Test-Path -LiteralPath (Join-Path $fresh.BackupRoot "migration-receipt.json") -PathType Leaf
    ) $fresh.Output
    Assert-True "fresh install writes Codex AGENTS" (Test-Path -LiteralPath (Join-Path $fresh.CodexHome "AGENTS.md"))
    Assert-True "fresh install writes empty user hooks" (Test-Path -LiteralPath (Join-Path $fresh.CodexHome "hooks.json"))
    Assert-True "fresh install writes managed config" (Test-Path -LiteralPath $fresh.ManagedPath)
    Assert-True "fresh install writes migration receipt" (Test-Path -LiteralPath (Join-Path $fresh.BackupRoot "migration-receipt.json"))
    $activeReceiptPointers = @(
        Get-ChildItem -LiteralPath $freshCase -Filter ".steadyagent-active-receipt-*.json" -File -Force
    )
    Assert-True "fresh install writes one integrity-protected active receipt pointer" (
        $activeReceiptPointers.Count -eq 1 -and
        ([IO.File]::ReadAllText($activeReceiptPointers[0].FullName, [Text.Encoding]::UTF8) |
            ConvertFrom-Json).pointer_integrity_sha256 -match '^[0-9A-F]{64}$'
    ) (($activeReceiptPointers | Select-Object -ExpandProperty FullName) -join "`n")
    $freshHooksPath = & git config --file $fresh.GitConfigPath --get core.hooksPath
    Assert-True "fresh install activates global pre-commit path" ($LASTEXITCODE -eq 0 -and $freshHooksPath -eq (Join-Path $fresh.TargetRoot "tools\git-hooks")) ([string]$freshHooksPath)
    $freshWriteProjectionBefore = @(
        Get-ChildItem -LiteralPath $freshCase -Recurse -Force |
            Sort-Object FullName |
            ForEach-Object {
                $length = if ($_.PSIsContainer) { 0 } else { $_.Length }
                $_.FullName + "|" + $_.LastWriteTimeUtc.Ticks + "|" + $length
            }
    ) -join "`n"
    $freshReceiptHashBefore = (
        Get-FileHash -LiteralPath (Join-Path $fresh.BackupRoot "migration-receipt.json") -Algorithm SHA256
    ).Hash
    $secondBackupRoot = Join-Path $freshCase "backup-second-apply"
    $secondApply = Invoke-Installer `
        -CaseRoot $freshCase `
        -Apply `
        -CustomBackupRoot $secondBackupRoot
    $freshWriteProjectionAfter = @(
        Get-ChildItem -LiteralPath $freshCase -Recurse -Force |
            Sort-Object FullName |
            ForEach-Object {
                $length = if ($_.PSIsContainer) { 0 } else { $_.Length }
                $_.FullName + "|" + $_.LastWriteTimeUtc.Ticks + "|" + $length
            }
    ) -join "`n"
    Assert-True "second Apply reports already installed" (
        $secondApply.ExitCode -eq 0 -and
        $secondApply.Output -match "already installed" -and
        $secondApply.Output -match [regex]::Escape((Join-Path $fresh.BackupRoot "migration-receipt.json")) -and
        $secondApply.Output -match "CODEX_THREAD_ID" -and
        $secondApply.Output -match "RequireRuntimeCatalog"
    ) $secondApply.Output
    Assert-True "second Apply performs zero managed or evidence writes" (
        -not (Test-Path -LiteralPath $secondBackupRoot) -and
        $freshWriteProjectionAfter -ceq $freshWriteProjectionBefore -and
        (Get-FileHash -LiteralPath (Join-Path $fresh.BackupRoot "migration-receipt.json") -Algorithm SHA256).Hash -ceq $freshReceiptHashBefore
    ) $secondApply.Output

    $activePointerPath = $activeReceiptPointers[0].FullName
    $activePointerBytes = [IO.File]::ReadAllBytes($activePointerPath)
    $damagedActivePointer = [IO.File]::ReadAllText($activePointerPath, [Text.Encoding]::UTF8) |
        ConvertFrom-Json
    $damagedActivePointer.pointer_integrity_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    [IO.File]::WriteAllText(
        $activePointerPath,
        (($damagedActivePointer | ConvertTo-Json -Depth 6) + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )
    try {
        $damagedPointerApply = Invoke-Installer `
            -CaseRoot $freshCase `
            -Apply `
            -CustomBackupRoot (Join-Path $freshCase "backup-damaged-pointer")
    }
    finally {
        [IO.File]::WriteAllBytes($activePointerPath, $activePointerBytes)
    }
    Assert-True "idempotent Apply rejects a damaged active receipt pointer" (
        $damagedPointerApply.ExitCode -ne 0 -and
        $damagedPointerApply.Output -match "pointer"
    ) $damagedPointerApply.Output

    $duplicatePointerPath = $activePointerPath + ".duplicate"
    [IO.File]::Copy($activePointerPath, $duplicatePointerPath, $false)
    try {
        $ambiguousPointerApply = Invoke-Installer `
            -CaseRoot $freshCase `
            -Apply `
            -CustomBackupRoot (Join-Path $freshCase "backup-ambiguous-pointer")
    }
    finally {
        Remove-Item -LiteralPath $duplicatePointerPath -Force -ErrorAction SilentlyContinue
    }
    Assert-True "idempotent Apply rejects multiple active receipt candidates" (
        $ambiguousPointerApply.ExitCode -ne 0 -and
        $ambiguousPointerApply.Output -match "missing or ambiguous"
    ) $ambiguousPointerApply.Output
    $freshBeforeOutsideRollback = Get-ManagedSurfaceFingerprint `
        -Roots @($freshCase) `
        -Files @()
    $outsideRollbackTool = Invoke-ReceiptRollback `
        -InstallResult $fresh `
        -RollbackPath (Join-Path $repoRoot "tools\rollback.ps1") `
        -DryRun
    Assert-True "test rollback requires its tool inside STEADYAGENT_TEST_ROOT" (
        $outsideRollbackTool.ExitCode -ne 0 -and
        $outsideRollbackTool.Output -match "escaped STEADYAGENT_TEST_ROOT"
    ) $outsideRollbackTool.Output
    Assert-True "outside rollback tool rejection performs zero writes" (
        (Get-ManagedSurfaceFingerprint -Roots @($freshCase) -Files @()) -eq
            $freshBeforeOutsideRollback
    ) $outsideRollbackTool.Output
    $simulatedElevatedRollbackBefore = Get-ManagedSurfaceFingerprint `
        -Roots @($freshCase) `
        -Files @()
    $simulatedElevatedRollbackApply = Invoke-ReceiptRollback `
        -InstallResult $fresh `
        -TestAsElevated
    Assert-True "simulated elevated rollback apply fails closed" (
        $simulatedElevatedRollbackApply.ExitCode -ne 0 -and
        $simulatedElevatedRollbackApply.Output -match "non-elevated PowerShell process"
    ) $simulatedElevatedRollbackApply.Output
    Assert-True "simulated elevated rollback apply performs zero case writes" (
        (Get-ManagedSurfaceFingerprint -Roots @($freshCase) -Files @()) -eq
            $simulatedElevatedRollbackBefore
    ) $simulatedElevatedRollbackApply.Output
    $simulatedElevatedRollbackDryRun = Invoke-ReceiptRollback `
        -InstallResult $fresh `
        -DryRun `
        -TestAsElevated
    Assert-True "simulated elevated rollback dry-run fails closed" (
        $simulatedElevatedRollbackDryRun.ExitCode -ne 0 -and
        $simulatedElevatedRollbackDryRun.Output -match "non-elevated PowerShell process"
    ) $simulatedElevatedRollbackDryRun.Output
    Assert-True "simulated elevated rollback dry-run performs zero case writes" (
        (Get-ManagedSurfaceFingerprint -Roots @($freshCase) -Files @()) -eq
            $simulatedElevatedRollbackBefore
    ) $simulatedElevatedRollbackDryRun.Output
    if (Test-Path -LiteralPath $fresh.ManagedPath) {
        $managed = [IO.File]::ReadAllText($fresh.ManagedPath, [Text.Encoding]::UTF8)
        $blockCount = ([regex]::Matches($managed, '(?m)^\[\[hooks[.][A-Za-z]+[.]hooks\]\]$')).Count
        $preToolUseBlockCount = ([regex]::Matches(
            $managed,
            '(?m)^\[\[hooks[.]PreToolUse[.]hooks\]\]$'
        )).Count
        Assert-True "managed config has exact three blocks and one unified PreToolUse" (
            $blockCount -eq 3 -and $preToolUseBlockCount -eq 1
        ) ("blocks=" + $blockCount + " pretool=" + $preToolUseBlockCount)
        Assert-True "managed config omits high-frequency events" ($managed -notmatch "UserPromptSubmit|PermissionRequest|PostToolUse")
    }
    $installedDiagnose = Join-Path $fresh.TargetRoot "tools/diagnose-install.ps1"
    $strictThreadId = "strict-diagnose-thread"
    $syntheticCodexHome = Join-Path $freshCase "catalog-codex-home"
    $syntheticSessions = Join-Path $syntheticCodexHome "sessions\2026\07\30"
    New-Item -ItemType Directory -Path $syntheticSessions -Force | Out-Null
    $strictRolloutPath = Join-Path $syntheticSessions ("rollout-fixture-" + $strictThreadId + ".jsonl")
    $skillRootForPrompt = ((Join-Path $fresh.CodexHome "skills") -replace "\\", "/")
    $strictSkillsText = @"
<skills_instructions>
## Skills
### Skill roots
- ``r0`` = ``$skillRootForPrompt``
### Available skills
- steadyagent-workflow: Installed Boring Is All You Need workflow fixture. (file: r0/steadyagent-workflow/SKILL.md)
</skills_instructions>
"@
    $strictReceipt = [IO.File]::ReadAllText(
        (Join-Path $fresh.BackupRoot "migration-receipt.json"),
        [Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    $strictSessionStartedUtc = (
        [DateTimeOffset]::Parse([string]$strictReceipt.completed_utc).ToUniversalTime().AddSeconds(1)
    ).ToString("o")
    $strictSessionLine = (
        [ordered]@{
            timestamp = $strictSessionStartedUtc
            type = "session_meta"
            payload = [ordered]@{ id = $strictThreadId; originator = "Codex Desktop" }
        } |
            ConvertTo-Json -Compress -Depth 4
    )
    $strictSkillsLine = (
        [ordered]@{
            type = "response_item"
            payload = [ordered]@{
                type = "message"
                role = "developer"
                content = @([ordered]@{ type = "input_text"; text = $strictSkillsText })
            }
        } | ConvertTo-Json -Compress -Depth 8
    )
    [IO.File]::WriteAllLines(
        $strictRolloutPath,
        @($strictSessionLine, $strictSkillsLine),
        (New-Object Text.UTF8Encoding($true))
    )
    $strictCatalogRoot = Join-Path $fresh.TargetRoot "runtime-skill-catalogs"
    $installedSkillIndex = Join-Path $fresh.TargetRoot "tools\skill-index.ps1"
    $oldSyntheticCodexHome = $env:CODEX_HOME
    $oldStrictThreadId = $env:CODEX_THREAD_ID
    try {
        $env:CODEX_HOME = $syntheticCodexHome
        $env:CODEX_THREAD_ID = $strictThreadId
        $catalogBuildOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installedSkillIndex `
            -HostSurface CodexDesktop `
            -ThreadId $strictThreadId
        $catalogBuildCode = $LASTEXITCODE
    }
    finally {
        if ($null -eq $oldSyntheticCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $oldSyntheticCodexHome }
        if ($null -eq $oldStrictThreadId) { Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue }
        else { $env:CODEX_THREAD_ID = $oldStrictThreadId }
    }
    $strictCatalogJsonFiles = @(
        Get-ChildItem -LiteralPath $strictCatalogRoot -Recurse -Filter "skill-index.json" -File -ErrorAction SilentlyContinue
    )
    $strictCatalog = if ($strictCatalogJsonFiles.Count -eq 1) {
        Get-Content -LiteralPath $strictCatalogJsonFiles[0].FullName -Raw -Encoding UTF8 |
            ConvertFrom-Json
    }
    else { $null }
    $strictCatalogVisibility = if ($null -ne $strictCatalog) {
        [string]$strictCatalog.visibility
    }
    else { "" }
    Assert-True "strict catalog fixture builds as rollout-file-confirmed" (
        $catalogBuildCode -eq 0 -and
        $strictCatalogJsonFiles.Count -eq 1 -and
        $strictCatalogVisibility -eq "rollout-file-confirmed"
    ) (@($catalogBuildOutput) -join "`n")
    Assert-True "custom TargetRoot catalog works without CatalogRoot override" (
        $catalogBuildCode -eq 0 -and
        $strictCatalogJsonFiles.Count -eq 1 -and
        [IO.Path]::GetFullPath($strictCatalogJsonFiles[0].FullName).StartsWith(
            ([IO.Path]::GetFullPath($fresh.TargetRoot).TrimEnd("\") + "\"),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) (@($catalogBuildOutput) -join "`n")

    $strictRolloutFile = Get-Item -LiteralPath $strictRolloutPath
    $strictRolloutFile.CreationTimeUtc = [DateTime]::SpecifyKind(
        [DateTime]::Parse("2000-01-01T00:00:00"),
        [DateTimeKind]::Utc
    )
    $diagnoseResult = Invoke-StrictDiagnosisFixture `
        -DiagnosePath $installedDiagnose `
        -InstallResult $fresh `
        -SyntheticCodexHome $syntheticCodexHome `
        -ThreadId $strictThreadId `
        -SkipSmoke
    $diagnoseCode = $diagnoseResult.ExitCode
    $diagnoseText = $diagnoseResult.Output
    $diagnoseWarnings = @($diagnoseText -split '\r?\n' | Where-Object {
        [string]$_ -match '^WARN '
    })
    Assert-True "strict diagnosis keeps rollout timestamps below Live evidence" (
        $diagnoseCode -eq 0 -and
        $diagnoseText -match "RESULT pass=\d+ warn=2 fail=0" -and
        $diagnoseText -notmatch "started before migration completed" -and
        $diagnoseWarnings.Count -eq 2 -and
        $diagnoseWarnings -contains "WARN installed hook smoke - skipped" -and
        @($diagnoseWarnings | Where-Object {
            [string]$_ -like "WARN manual Codex Live acceptance is still required*"
        }).Count -eq 1
    ) $diagnoseText
    Assert-True "strict diagnosis accepts a task started after receipt completion" (
        $diagnoseCode -eq 0 -and
        $diagnoseText -notmatch "Owning session_meta timestamp|did not start after"
    ) $diagnoseText

    $writeStrictRollout = {
        param([object]$SessionEvent)
        [IO.File]::WriteAllLines(
            $strictRolloutPath,
            @(
                ($SessionEvent | ConvertTo-Json -Compress -Depth 6),
                $strictSkillsLine
            ),
            (New-Object Text.UTF8Encoding($true))
        )
    }
    $strictTimingCases = @(
        [pscustomobject]@{
            Name = "strict diagnosis rejects a task started before receipt completion"
            SessionEvent = [ordered]@{
                timestamp = ([DateTimeOffset]::Parse([string]$strictReceipt.completed_utc).ToUniversalTime().AddSeconds(-1)).ToString("o")
                type = "session_meta"
                payload = [ordered]@{ id = $strictThreadId; originator = "Codex Desktop" }
            }
            Pattern = "did not start after"
        },
        [pscustomobject]@{
            Name = "strict diagnosis rejects a missing owning task timestamp"
            SessionEvent = [ordered]@{
                type = "session_meta"
                payload = [ordered]@{ id = $strictThreadId; originator = "Codex Desktop" }
            }
            Pattern = "Owning session_meta timestamp"
        },
        [pscustomobject]@{
            Name = "strict diagnosis rejects an invalid owning task timestamp"
            SessionEvent = [ordered]@{
                timestamp = "not-a-time"
                type = "session_meta"
                payload = [ordered]@{ id = $strictThreadId; originator = "Codex Desktop" }
            }
            Pattern = "Owning session_meta timestamp"
        },
        [pscustomobject]@{
            Name = "strict diagnosis rejects a timestamp found only in parent metadata"
            SessionEvent = [ordered]@{
                type = "session_meta"
                payload = [ordered]@{
                    id = $strictThreadId
                    originator = "Codex Desktop"
                    timestamp = $strictSessionStartedUtc
                }
            }
            Pattern = "Owning session_meta timestamp"
        }
    )
    try {
        foreach ($timingCase in $strictTimingCases) {
            & $writeStrictRollout $timingCase.SessionEvent
            $timingDiagnosis = Invoke-StrictDiagnosisFixture `
                -DiagnosePath $installedDiagnose `
                -InstallResult $fresh `
                -SyntheticCodexHome $syntheticCodexHome `
                -ThreadId $strictThreadId `
                -SkipSmoke
            Assert-True $timingCase.Name (
                $timingDiagnosis.ExitCode -ne 0 -and
                $timingDiagnosis.Output -match $timingCase.Pattern -and
                $timingDiagnosis.Output -match "fail=[1-9]"
            ) $timingDiagnosis.Output
        }
    }
    finally {
        & $writeStrictRollout ([ordered]@{
            timestamp = $strictSessionStartedUtc
            type = "session_meta"
            payload = [ordered]@{ id = $strictThreadId; originator = "Codex Desktop" }
        })
    }

    $runtimeReceiptPath = Join-Path $fresh.BackupRoot "migration-receipt.json"
    $runtimeReceiptReplacementPath = Join-Path $fresh.BackupRoot "runtime-receipt-replacement.json"
    $runtimeReceiptParkedPath = Join-Path $fresh.BackupRoot "runtime-receipt-original.parked"
    $runtimeReceiptReplacement = (
        [IO.File]::ReadAllText($runtimeReceiptPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    $verifiedCompletedUtc = [DateTimeOffset]::Parse(
        [string]$runtimeReceiptReplacement.completed_utc
    ).ToUniversalTime()
    $runtimeReceiptReplacement.completed_utc = $verifiedCompletedUtc.AddSeconds(-2).ToString("o")
    Update-ReceiptIntegrity -Receipt $runtimeReceiptReplacement
    [IO.File]::WriteAllText(
        $runtimeReceiptReplacementPath,
        (($runtimeReceiptReplacement | ConvertTo-Json -Depth 7) + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )
    $receiptSwapThreadId = "strict-receipt-swap-thread"
    $receiptSwapRolloutPath = Join-Path $syntheticSessions (
        "rollout-fixture-" + $receiptSwapThreadId + ".jsonl"
    )
    $receiptSwapSessionLine = ([ordered]@{
        timestamp = $verifiedCompletedUtc.AddSeconds(-1).ToString("o")
        type = "session_meta"
        payload = [ordered]@{ id = $receiptSwapThreadId; originator = "Codex Desktop" }
    } | ConvertTo-Json -Compress -Depth 6)
    [IO.File]::WriteAllLines(
        $receiptSwapRolloutPath,
        @($receiptSwapSessionLine, $strictSkillsLine),
        (New-Object Text.UTF8Encoding($true))
    )
    $oldReceiptSwapCodexHome = $env:CODEX_HOME
    $oldReceiptSwapThreadId = $env:CODEX_THREAD_ID
    try {
        $env:CODEX_HOME = $syntheticCodexHome
        $env:CODEX_THREAD_ID = $receiptSwapThreadId
        $receiptSwapCatalogBuildOutput = & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $installedSkillIndex `
            -HostSurface CodexDesktop `
            -ThreadId $receiptSwapThreadId
        $receiptSwapCatalogBuildCode = $LASTEXITCODE
    }
    finally {
        if ($null -eq $oldReceiptSwapCodexHome) {
            Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue
        }
        else { $env:CODEX_HOME = $oldReceiptSwapCodexHome }
        if ($null -eq $oldReceiptSwapThreadId) {
            Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue
        }
        else { $env:CODEX_THREAD_ID = $oldReceiptSwapThreadId }
    }
    $oldRuntimeReceiptSwapSource = $env:STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_SOURCE
    $oldRuntimeReceiptSwapParked = $env:STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_PARKED
    try {
        $env:STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_SOURCE = $runtimeReceiptReplacementPath
        $env:STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_PARKED = $runtimeReceiptParkedPath
        $runtimeReceiptSwapDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $receiptSwapThreadId `
            -SkipSmoke
    }
    finally {
        if ($null -eq $oldRuntimeReceiptSwapSource) {
            Remove-Item Env:\STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_SOURCE -ErrorAction SilentlyContinue
        }
        else {
            $env:STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_SOURCE = $oldRuntimeReceiptSwapSource
        }
        if ($null -eq $oldRuntimeReceiptSwapParked) {
            Remove-Item Env:\STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_PARKED -ErrorAction SilentlyContinue
        }
        else {
            $env:STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_PARKED = $oldRuntimeReceiptSwapParked
        }
        if ([IO.File]::Exists($runtimeReceiptParkedPath)) {
            if ([IO.File]::Exists($runtimeReceiptPath)) { [IO.File]::Delete($runtimeReceiptPath) }
            [IO.File]::Move($runtimeReceiptParkedPath, $runtimeReceiptPath)
        }
        & $writeStrictRollout ([ordered]@{
            timestamp = $strictSessionStartedUtc
            type = "session_meta"
            payload = [ordered]@{ id = $strictThreadId; originator = "Codex Desktop" }
        })
    }
    Assert-True "runtime catalog uses the verified receipt time after a path swap" (
        $receiptSwapCatalogBuildCode -eq 0 -and
        $runtimeReceiptSwapDiagnosis.ExitCode -ne 0 -and
        $runtimeReceiptSwapDiagnosis.Output -match
            "TEST diagnose receipt swapped after verified rollback child" -and
        $runtimeReceiptSwapDiagnosis.Output -match "did not start after" -and
        $runtimeReceiptSwapDiagnosis.Output -match "fail=[1-9]"
    ) ((@($receiptSwapCatalogBuildOutput) + @($runtimeReceiptSwapDiagnosis.Output)) -join "`n")

    Assert-True "strict diagnosis enumerates the frozen installed PowerShell set" (
        $diagnoseText -match "installed PowerShell asset set is frozen.*count=21"
    ) $diagnoseText
    Assert-True "strict diagnosis enumerates the complete installed asset set" (
        $diagnoseText -match "complete installed asset set is frozen.*count=53"
    ) $diagnoseText
    Assert-True "strict diagnosis verifies all receipt-bound installed bytes" (
        $diagnoseText -match
            "PASS receipt-bound exact installed bytes.*53 receipt-bound installed hashes"
    ) $diagnoseText

    $diagnoseParentParked = Join-Path $freshCase "diagnose-parent-parked"
    $oldDiagnoseParentSwap = $env:STEADYAGENT_TEST_DIAGNOSE_PARENT_SWAP
    $oldDiagnoseParentParked = $env:STEADYAGENT_TEST_DIAGNOSE_PARENT_PARKED
    try {
        $env:STEADYAGENT_TEST_DIAGNOSE_PARENT_SWAP = "1"
        $env:STEADYAGENT_TEST_DIAGNOSE_PARENT_PARKED = $diagnoseParentParked
        $diagnoseParentSwap = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
    }
    finally {
        if ($null -eq $oldDiagnoseParentSwap) {
            Remove-Item Env:\STEADYAGENT_TEST_DIAGNOSE_PARENT_SWAP -ErrorAction SilentlyContinue
        }
        else { $env:STEADYAGENT_TEST_DIAGNOSE_PARENT_SWAP = $oldDiagnoseParentSwap }
        if ($null -eq $oldDiagnoseParentParked) {
            Remove-Item Env:\STEADYAGENT_TEST_DIAGNOSE_PARENT_PARKED -ErrorAction SilentlyContinue
        }
        else { $env:STEADYAGENT_TEST_DIAGNOSE_PARENT_PARKED = $oldDiagnoseParentParked }
    }
    Assert-True "strict diagnosis pins parent authority against rename and junction exchange" (
        $diagnoseParentSwap.ExitCode -eq 0 -and
        $diagnoseParentSwap.Output -match
            "TEST diagnose parent rename/junction exchange blocked by pinned authority" -and
        -not (Test-Path -LiteralPath $diagnoseParentParked) -and
        (Test-Path -LiteralPath (Join-Path $fresh.TargetRoot "tools") -PathType Container)
    ) $diagnoseParentSwap.Output

    $publicSkipErrorPath = Join-Path $fixtureRoot "public-skip-smoke-error.log"
    $savedPublicSkipErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $publicSkipOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File $installedDiagnose `
            -TargetRoot $fresh.TargetRoot `
            -CodexHome $fresh.CodexHome `
            -ManagedConfigPath $fresh.ManagedPath `
            -GitConfigPath $fresh.GitConfigPath `
            -SkipSmoke 2>$publicSkipErrorPath
        $publicSkipCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPublicSkipErrorAction
    }
    $publicSkipText = (@($publicSkipOutput) + @(
        Get-Content -LiteralPath $publicSkipErrorPath -ErrorAction SilentlyContinue
    )) -join "`n"
    Assert-True "public diagnosis cannot bypass the installed Hook smoke" (
        $publicSkipCode -ne 0 -and
        $publicSkipText -match "available only to isolated Boring Is All You Need tests"
    ) $publicSkipText

    $installedCheckpointPath = Join-Path $fresh.TargetRoot "tools\git-checkpoint.ps1"
    $installedCheckpointBytes = [IO.File]::ReadAllBytes($installedCheckpointPath)
    Remove-Item -LiteralPath $installedCheckpointPath -Force
    try {
        $missingCheckpointDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
    }
    finally {
        [IO.File]::WriteAllBytes($installedCheckpointPath, $installedCheckpointBytes)
    }
    Assert-True "strict diagnosis rejects a missing installed checkpoint tool" (
        $missingCheckpointDiagnosis.ExitCode -ne 0 -and
        $missingCheckpointDiagnosis.Output -match "git-checkpoint[.]ps1" -and
        $missingCheckpointDiagnosis.Output -match "fail=[1-9]"
    ) $missingCheckpointDiagnosis.Output

    [IO.File]::WriteAllText(
        $installedCheckpointPath,
        "function Broken {",
        (New-Object Text.UTF8Encoding($false))
    )
    try {
        $corruptCheckpointDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
    }
    finally {
        [IO.File]::WriteAllBytes($installedCheckpointPath, $installedCheckpointBytes)
    }
    Assert-True "strict diagnosis rejects a corrupt installed checkpoint tool" (
        $corruptCheckpointDiagnosis.ExitCode -ne 0 -and
        $corruptCheckpointDiagnosis.Output -match "git-checkpoint[.]ps1" -and
        $corruptCheckpointDiagnosis.Output -match "syntax" -and
        $corruptCheckpointDiagnosis.Output -match "fail=[1-9]"
    ) $corruptCheckpointDiagnosis.Output

    $installedPolicyPath = Join-Path $fresh.TargetRoot "tools\protected-path-policy.ps1"
    $installedPolicyBytes = [IO.File]::ReadAllBytes($installedPolicyPath)
    [IO.File]::AppendAllText(
        $installedPolicyPath,
        "`n# syntax-valid byte drift fixture`n",
        (New-Object Text.UTF8Encoding($false))
    )
    try {
        $syntaxValidDriftDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
    }
    finally {
        [IO.File]::WriteAllBytes($installedPolicyPath, $installedPolicyBytes)
    }
    Assert-True "strict diagnosis rejects syntax-valid installed PowerShell byte drift" (
        $syntaxValidDriftDiagnosis.ExitCode -ne 0 -and
        $syntaxValidDriftDiagnosis.Output -match "FAIL receipt-bound exact installed bytes" -and
        $syntaxValidDriftDiagnosis.Output -match "fail=[1-9]"
    ) $syntaxValidDriftDiagnosis.Output

    $installedRollbackPath = Join-Path $fresh.TargetRoot "tools\rollback.ps1"
    $installedRollbackBytes = [IO.File]::ReadAllBytes($installedRollbackPath)
    $rollbackPreexecutionSentinel = Join-Path $fixtureRoot "rollback-preexecution-sentinel.txt"
    $escapedRollbackSentinel = $rollbackPreexecutionSentinel.Replace("'", "''")
    $forgedRollback = @"
[CmdletBinding()]
param([string]`$ReceiptPath, [string]`$GitConfigPath)
[IO.File]::WriteAllText('$escapedRollbackSentinel', 'executed', [Text.Encoding]::UTF8)
Write-Host 'STABLE INSTALLED PROJECTION VERIFIED receipt=applied entries=80 pending=0'
Write-Host 'DRY-RUN Boring Is All You Need v2.0.0 rollback: 80 files; 0 writes.'
exit 0
"@
    [IO.File]::WriteAllText(
        $installedRollbackPath,
        $forgedRollback,
        (New-Object Text.UTF8Encoding($false))
    )
    try {
        $forgedRollbackDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
    }
    finally {
        [IO.File]::WriteAllBytes($installedRollbackPath, $installedRollbackBytes)
    }
    Assert-True "strict diagnosis rejects a forged rollback before executing it" (
        $forgedRollbackDiagnosis.ExitCode -ne 0 -and
        $forgedRollbackDiagnosis.Output -match "FAIL receipt-bound exact installed bytes" -and
        -not (Test-Path -LiteralPath $rollbackPreexecutionSentinel)
    ) $forgedRollbackDiagnosis.Output

    $installedNonPowerShellAssetPath = Join-Path $fresh.TargetRoot "docs\tools.zh-CN.md"
    $installedNonPowerShellAssetBytes = [IO.File]::ReadAllBytes($installedNonPowerShellAssetPath)
    [IO.File]::AppendAllText(
        $installedNonPowerShellAssetPath,
        "`n<!-- byte drift fixture -->`n",
        (New-Object Text.UTF8Encoding($false))
    )
    try {
        $markdownDriftDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
    }
    finally {
        [IO.File]::WriteAllBytes(
            $installedNonPowerShellAssetPath,
            $installedNonPowerShellAssetBytes
        )
    }
    Assert-True "strict diagnosis rejects installed Markdown byte drift" (
        $markdownDriftDiagnosis.ExitCode -ne 0 -and
        $markdownDriftDiagnosis.Output -match "FAIL receipt-bound exact installed bytes" -and
        $markdownDriftDiagnosis.Output -match "fail=[1-9]"
    ) $markdownDriftDiagnosis.Output

    Remove-Item -LiteralPath $installedNonPowerShellAssetPath -Force
    try {
        $missingNonPowerShellDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
    }
    finally {
        [IO.File]::WriteAllBytes(
            $installedNonPowerShellAssetPath,
            $installedNonPowerShellAssetBytes
        )
    }
    Assert-True "strict diagnosis rejects a missing installed non-PowerShell asset" (
        $missingNonPowerShellDiagnosis.ExitCode -ne 0 -and
        $missingNonPowerShellDiagnosis.Output -match "docs[\\/]tools[.]zh-CN[.]md" -and
        $missingNonPowerShellDiagnosis.Output -match "fail=[1-9]"
    ) $missingNonPowerShellDiagnosis.Output

    $strictCatalogJsonPath = $strictCatalogJsonFiles[0].FullName
    $strictCatalogBytes = [IO.File]::ReadAllBytes($strictCatalogJsonPath)
    $damagedCatalog = [IO.File]::ReadAllText($strictCatalogJsonPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $damagedCatalog.skills[0].name = "damaged-semantic-catalog"
    [IO.File]::WriteAllText(
        $strictCatalogJsonPath,
        ($damagedCatalog | ConvertTo-Json -Depth 8),
        (New-Object Text.UTF8Encoding($true))
    )
    try {
        $damagedCatalogDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
        $damagedCatalogOutput = $damagedCatalogDiagnosis.Output
        $damagedCatalogCode = $damagedCatalogDiagnosis.ExitCode
    }
    finally {
        [IO.File]::WriteAllBytes($strictCatalogJsonPath, $strictCatalogBytes)
    }
    Assert-True "strict diagnosis rejects a damaged runtime catalog" (
        $damagedCatalogCode -ne 0 -and $damagedCatalogOutput -match "fail=[1-9]"
    ) $damagedCatalogOutput

    $installedReviewPath = Join-Path $fresh.TargetRoot "rules\review-gates.md"
    $installedReviewText = [IO.File]::ReadAllText($installedReviewPath, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText(
        $installedReviewPath,
        $installedReviewText.Replace("material risk", "material drift"),
        (New-Object Text.UTF8Encoding($false))
    )
    try {
        $damagedPolicyDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
        $damagedPolicyOutput = $damagedPolicyDiagnosis.Output
        $damagedPolicyCode = $damagedPolicyDiagnosis.ExitCode
    }
    finally {
        [IO.File]::WriteAllText(
            $installedReviewPath,
            $installedReviewText,
            (New-Object Text.UTF8Encoding($false))
        )
    }
    Assert-True "strict diagnosis rejects a damaged review and skill contract" (
        $damagedPolicyCode -ne 0 -and $damagedPolicyOutput -match "fail=[1-9]"
    ) $damagedPolicyOutput

    & git config --file $fresh.GitConfigPath --unset user.email
    try {
        $missingIdentityDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
        $missingIdentityOutput = $missingIdentityDiagnosis.Output
        $missingIdentityCode = $missingIdentityDiagnosis.ExitCode
    }
    finally {
        & git config --file $fresh.GitConfigPath user.email "strict-diagnosis@example.invalid"
    }
    Assert-True "strict diagnosis rejects missing Git identity" (
        $missingIdentityCode -ne 0 -and $missingIdentityOutput -match "fail=[1-9]"
    ) $missingIdentityOutput

    & git config --file $fresh.GitConfigPath user.name "   "
    & git config --file $fresh.GitConfigPath user.email "   "
    try {
        $blankIdentityDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
    }
    finally {
        & git config --file $fresh.GitConfigPath user.name "Strict Diagnosis Fixture"
        & git config --file $fresh.GitConfigPath user.email "strict-diagnosis@example.invalid"
    }
    Assert-True "strict diagnosis rejects whitespace-only Git identity" (
        $blankIdentityDiagnosis.ExitCode -ne 0 -and
        $blankIdentityDiagnosis.Output -match "fail=[1-9]"
    ) $blankIdentityDiagnosis.Output

    $invalidIdentityName = "invalid-identity-name-secret <forbidden>"
    $invalidIdentityEmail = "invalid-identity-email-secret"
    & git config --file $fresh.GitConfigPath user.name $invalidIdentityName
    & git config --file $fresh.GitConfigPath user.email $invalidIdentityEmail
    try {
        $invalidIdentityDiagnosis = Invoke-StrictDiagnosisFixture `
            -DiagnosePath $installedDiagnose `
            -InstallResult $fresh `
            -SyntheticCodexHome $syntheticCodexHome `
            -ThreadId $strictThreadId `
            -SkipSmoke
    }
    finally {
        & git config --file $fresh.GitConfigPath user.name "Strict Diagnosis Fixture"
        & git config --file $fresh.GitConfigPath user.email "strict-diagnosis@example.invalid"
    }
    Assert-True "strict diagnosis rejects syntactically invalid Git identity" (
        $invalidIdentityDiagnosis.ExitCode -ne 0 -and
        $invalidIdentityDiagnosis.Output -match "fail=[1-9]"
    ) $invalidIdentityDiagnosis.Output
    Assert-True "Git identity diagnosis never echoes identity values" (
        $invalidIdentityDiagnosis.Output -notmatch [regex]::Escape($invalidIdentityName) -and
        $invalidIdentityDiagnosis.Output -notmatch [regex]::Escape($invalidIdentityEmail)
    ) $invalidIdentityDiagnosis.Output
    $installedDiagnoseSource = [IO.File]::ReadAllText($installedDiagnose, [Text.Encoding]::UTF8)
    Assert-True "strict identity validation uses both Git author and committer var contracts" (
        $installedDiagnoseSource -match "GIT_AUTHOR_IDENT" -and
        $installedDiagnoseSource -match "GIT_COMMITTER_IDENT"
    )

    $wrongManagedPath = Join-Path $freshCase "wrong-requirements.toml"
    $wrongManagedText = [IO.File]::ReadAllText($fresh.ManagedPath, [Text.Encoding]::UTF8).Replace('matcher = "manual|auto"', 'matcher = "manual"')
    [IO.File]::WriteAllText($wrongManagedPath, $wrongManagedText, (New-Object Text.UTF8Encoding($false)))
    $oldWrongDiagnoseTestMode = $env:STEADYAGENT_TEST_MODE
    $oldWrongDiagnoseTestRoot = $env:STEADYAGENT_TEST_ROOT
    try {
        $env:STEADYAGENT_TEST_MODE = "1"
        $env:STEADYAGENT_TEST_ROOT = $fixtureRoot
        $wrongDiagnoseOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installedDiagnose `
            -TargetRoot $fresh.TargetRoot `
            -CodexHome $fresh.CodexHome `
            -ManagedConfigPath $wrongManagedPath `
            -GitConfigPath $fresh.GitConfigPath `
            -RequireHooksActive `
            -SkipSmoke
        $wrongDiagnoseCode = $LASTEXITCODE
    }
    finally {
        if ($null -eq $oldWrongDiagnoseTestMode) {
            Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
        }
        else { $env:STEADYAGENT_TEST_MODE = $oldWrongDiagnoseTestMode }
        if ($null -eq $oldWrongDiagnoseTestRoot) {
            Remove-Item Env:\STEADYAGENT_TEST_ROOT -ErrorAction SilentlyContinue
        }
        else { $env:STEADYAGENT_TEST_ROOT = $oldWrongDiagnoseTestRoot }
    }
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
    $migrateLegacyContent = @{}
    for ($legacyIndex = 0; $legacyIndex -lt $expectedV1RemovalRelativePaths.Count; $legacyIndex++) {
        $legacyRelative = [string]$expectedV1RemovalRelativePaths[$legacyIndex]
        $legacyDestination = Join-Path $migrateCodex $legacyRelative
        New-Item -ItemType Directory -Path (Split-Path -Parent $legacyDestination) -Force | Out-Null
        $legacyContent = "legacy-removal-{0:D2}" -f ($legacyIndex + 1)
        [IO.File]::WriteAllText($legacyDestination, $legacyContent, [Text.Encoding]::UTF8)
        $migrateLegacyContent[$legacyRelative] = $legacyContent
    }
    $migrate = Invoke-Installer -CaseRoot $migrateCase -Apply -ReplaceExistingWorkflow
    Assert-True "authorized V1 migration succeeds" ($migrate.ExitCode -eq 0) $migrate.Output
    Assert-True "migration receipt records replaced targets" (Test-Path -LiteralPath (Join-Path $migrate.BackupRoot "migration-receipt.json"))
    Assert-True "migration backup preserves legacy AGENTS" (Test-BackupContainsText -Root $migrate.BackupRoot -Expected "legacy-agent")
    Assert-True "migration backup preserves legacy managed config" (Test-BackupContainsText -Root $migrate.BackupRoot -Expected "legacy-managed")
    $remainingV1RemovalPaths = @($expectedV1RemovalRelativePaths | Where-Object {
        Test-Path -LiteralPath (Join-Path $migrateCodex $_)
    })
    Assert-True "migration removes the exact 27-item V1 Codex surface" (
        $remainingV1RemovalPaths.Count -eq 0
    ) ($remainingV1RemovalPaths -join "; ")
    $migrateReceipt = [IO.File]::ReadAllText((Join-Path $migrate.BackupRoot "migration-receipt.json"), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $receiptInstallEntries = @($migrateReceipt.entries | Where-Object { [string]$_.action -eq "install" })
    $actualInstallProjection = @(
        Get-ReceiptOperationProjection `
            -Entries $receiptInstallEntries `
            -TargetRoot $migrate.TargetRoot `
            -CodexHome $migrate.CodexHome `
            -ManagedConfig $migrate.ManagedPath |
            ForEach-Object { $_.ToLowerInvariant() }
    )
    $expectedInstallProjectionLower = @($expectedV2InstallProjection | ForEach-Object { $_.ToLowerInvariant() })
    $missingInstallProjection = @($expectedInstallProjectionLower | Where-Object {
        $actualInstallProjection -notcontains $_
    })
    $unexpectedInstallProjection = @($actualInstallProjection | Where-Object {
        $expectedInstallProjectionLower -notcontains $_
    })
    Assert-True "migration receipt install set is exactly the frozen 53 destinations" (
        $receiptInstallEntries.Count -eq 53 -and
        @($actualInstallProjection | Sort-Object -Unique).Count -eq 53 -and
        $missingInstallProjection.Count -eq 0 -and
        $unexpectedInstallProjection.Count -eq 0
    ) (
        "missing=" + ($missingInstallProjection -join ",") +
        "; unexpected=" + ($unexpectedInstallProjection -join ",")
    )
    $receiptRemovalEntries = @($migrateReceipt.entries | Where-Object { [string]$_.action -eq "remove" })
    $expectedRemovalDestinations = @($expectedV1RemovalRelativePaths | ForEach-Object {
        [IO.Path]::GetFullPath((Join-Path $migrateCodex $_)).ToLowerInvariant()
    })
    $actualRemovalDestinations = @($receiptRemovalEntries | ForEach-Object {
        [IO.Path]::GetFullPath([string]$_.destination).ToLowerInvariant()
    })
    $missingRemovalDestinations = @($expectedRemovalDestinations | Where-Object {
        $actualRemovalDestinations -notcontains $_
    })
    $unexpectedRemovalDestinations = @($actualRemovalDestinations | Where-Object {
        $expectedRemovalDestinations -notcontains $_
    })
    Assert-True "migration receipt removal set is exactly the fixed 27 destinations" (
        $receiptRemovalEntries.Count -eq 27 -and
        @($actualRemovalDestinations | Sort-Object -Unique).Count -eq 27 -and
        $missingRemovalDestinations.Count -eq 0 -and
        $unexpectedRemovalDestinations.Count -eq 0
    ) (
        "missing=" + ($missingRemovalDestinations -join ",") +
        "; unexpected=" + ($unexpectedRemovalDestinations -join ",")
    )
    Assert-True "migration receipt records created rules directory" (
        @($migrateReceipt.created_directories | Where-Object {
            [string]$_.path -ceq (Join-Path $migrate.TargetRoot "rules") -and
            [string]$_.volume_serial -match '^[0-9A-F]{8}$' -and
            [string]$_.file_id -match '^[0-9A-F]{16}$'
        }).Count -eq 1
    ) (@($migrateReceipt.created_directories | ConvertTo-Json -Compress) -join "; ")

    $directoryIdentityReceipt = Invoke-TamperedReceiptRollbackFixture `
        -Name "created-directory-identity" `
        -Rehash `
        -Mutate {
            param($receipt, $installed)
            $receipt.created_directories[0].file_id = "0000000000000000"
        }
    Assert-True "rollback rejects a replaced created-directory identity before writes" (
        $directoryIdentityReceipt.InstallExitCode -eq 0 -and
        $directoryIdentityReceipt.RollbackExitCode -ne 0 -and
        $directoryIdentityReceipt.Output -match "ownership identity changed"
    ) $directoryIdentityReceipt.Output
    Assert-True "created-directory identity rejection performs zero target writes" `
        $directoryIdentityReceipt.ZeroTargetWrites

    $extraReceipt = Invoke-TamperedReceiptRollbackFixture `
        -Name "extra-entry" `
        -Rehash `
        -Mutate {
            param($receipt, $installed)
            $sourceEntry = @($receipt.entries)[0]
            $extraPath = Join-Path $installed.TargetRoot "extra-installed.ps1"
            [IO.File]::Copy([string]$sourceEntry.destination, $extraPath, $false)
            $extraEntry = [pscustomobject][ordered]@{
                action = "install"
                destination = $extraPath
                existed = $false
                snapshot_name = $null
                original_sha256 = $null
                installed_sha256 = (Get-FileHash -LiteralPath $extraPath -Algorithm SHA256).Hash
            }
            $receipt.entries = @($receipt.entries) + @($extraEntry)
        }
    Assert-True "rollback rejects a receipt with an extra install entry" (
        $extraReceipt.InstallExitCode -eq 0 -and
        $extraReceipt.RollbackExitCode -ne 0 -and
        $extraReceipt.Output -match "Receipt operation contract mismatch"
    ) $extraReceipt.Output
    Assert-True "extra-entry rejection performs zero target writes" $extraReceipt.ZeroTargetWrites

    $missingReceipt = Invoke-TamperedReceiptRollbackFixture `
        -Name "missing-entry" `
        -Rehash `
        -Mutate {
            param($receipt, $installed)
            $allEntries = @($receipt.entries)
            $receipt.entries = @($allEntries[0..($allEntries.Count - 2)])
        }
    Assert-True "rollback rejects a receipt with a missing install entry" (
        $missingReceipt.InstallExitCode -eq 0 -and
        $missingReceipt.RollbackExitCode -ne 0 -and
        $missingReceipt.Output -match "Receipt operation contract mismatch"
    ) $missingReceipt.Output
    Assert-True "missing-entry rejection performs zero target writes" $missingReceipt.ZeroTargetWrites

    $substitutedReceipt = Invoke-TamperedReceiptRollbackFixture `
        -Name "equal-count-substitution" `
        -Rehash `
        -Mutate {
            param($receipt, $installed)
            $entry = @($receipt.entries)[0]
            $substitutePath = Join-Path $installed.CodexHome "substituted-agent.md"
            [IO.File]::Copy([string]$entry.destination, $substitutePath, $false)
            $entry.destination = $substitutePath
            $entry.existed = $false
            $entry.snapshot_name = $null
            $entry.original_sha256 = $null
            $entry.installed_sha256 = (Get-FileHash -LiteralPath $substitutePath -Algorithm SHA256).Hash
        }
    Assert-True "rollback rejects an equal-count install destination substitution" (
        $substitutedReceipt.InstallExitCode -eq 0 -and
        $substitutedReceipt.RollbackExitCode -ne 0 -and
        $substitutedReceipt.Output -match "Receipt install operation contract mismatch"
    ) $substitutedReceipt.Output
    Assert-True "equal-count substitution rejection performs zero target writes" $substitutedReceipt.ZeroTargetWrites

    $duplicateSnapshotReceipt = Invoke-TamperedReceiptRollbackFixture `
        -Name "duplicate-snapshot" `
        -Rehash `
        -Prepare {
            param($caseRoot)
            $codexHome = Join-Path $caseRoot "codex"
            New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $codexHome "AGENTS.md"), "legacy-agents", [Text.Encoding]::UTF8)
            [IO.File]::WriteAllText((Join-Path $codexHome "hooks.json"), '{"hooks":{"PostToolUse":[]}}', [Text.Encoding]::UTF8)
        } `
        -Mutate {
            param($receipt, $installed)
            $existingEntries = @($receipt.entries | Where-Object { [bool]$_.existed })
            if ($existingEntries.Count -lt 2) { throw "Duplicate snapshot fixture requires two originals." }
            $existingEntries[1].snapshot_name = [string]$existingEntries[0].snapshot_name
            $existingEntries[1].original_sha256 = [string]$existingEntries[0].original_sha256
        }
    Assert-True "rollback rejects duplicate snapshot references" (
        $duplicateSnapshotReceipt.InstallExitCode -eq 0 -and
        $duplicateSnapshotReceipt.RollbackExitCode -ne 0 -and
        $duplicateSnapshotReceipt.Output -match "snapshot"
    ) $duplicateSnapshotReceipt.Output
    Assert-True "duplicate snapshot rejection performs zero target writes" $duplicateSnapshotReceipt.ZeroTargetWrites

    $gitBeforeReceipt = Invoke-TamperedReceiptRollbackFixture `
        -Name "git-before" `
        -Rehash `
        -Mutate {
            param($receipt, $installed)
            $receipt.git_hooks_path_before = "tampered-before-hooks"
        }
    Assert-True "rollback rejects a tampered Git before value" (
        $gitBeforeReceipt.InstallExitCode -eq 0 -and
        $gitBeforeReceipt.RollbackExitCode -ne 0 -and
        $gitBeforeReceipt.Output -match "Git before value does not match its install snapshot"
    ) $gitBeforeReceipt.Output
    Assert-True "Git before tamper rejection performs zero target writes" $gitBeforeReceipt.ZeroTargetWrites

    $gitAfterReceipt = Invoke-TamperedReceiptRollbackFixture `
        -Name "git-after" `
        -Rehash `
        -ActiveHooksOverride "tampered-after-hooks" `
        -Mutate {
            param($receipt, $installed)
            $receipt.git_hooks_path_after = "tampered-after-hooks"
        }
    Assert-True "rollback rejects a tampered Git after value even when active Git matches it" (
        $gitAfterReceipt.InstallExitCode -eq 0 -and
        $gitAfterReceipt.RollbackExitCode -ne 0 -and
        $gitAfterReceipt.Output -match "Receipt Git after value"
    ) $gitAfterReceipt.Output
    Assert-True "Git after tamper rejection performs zero target writes" $gitAfterReceipt.ZeroTargetWrites

    $installedAgentsHash = (Get-FileHash -LiteralPath (Join-Path $migrate.CodexHome "AGENTS.md") -Algorithm SHA256).Hash
    $oldMigrationTestMode = $env:STEADYAGENT_TEST_MODE
    try {
        $env:STEADYAGENT_TEST_MODE = "1"
        $mutexFailureRollback = Invoke-ReceiptRollback -InstallResult $migrate -InjectMutexFailure
    }
    finally {
        if ($null -eq $oldMigrationTestMode) { Remove-Item Env:\STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:STEADYAGENT_TEST_MODE = $oldMigrationTestMode }
    }
    Assert-True "rollback fails closed when the machine-wide mutex is unavailable" (
        $mutexFailureRollback.ExitCode -ne 0 -and
        $mutexFailureRollback.Output -match "machine-wide migration mutex"
    ) $mutexFailureRollback.Output
    Assert-True "rollback mutex failure performs zero target writes" (
        (Get-FileHash -LiteralPath (Join-Path $migrate.CodexHome "AGENTS.md") -Algorithm SHA256).Hash -eq $installedAgentsHash
    )

    $heldRollbackMutex = New-Object Threading.Mutex(
        $true,
        (Get-TestMigrationMutexName -TestRoot $fixtureRoot)
    )
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
    $failedV1Restores = @($expectedV1RemovalRelativePaths | Where-Object {
        $restoredPath = Join-Path $migrateCodex $_
        -not (Test-Path -LiteralPath $restoredPath -PathType Leaf) -or
        [IO.File]::ReadAllText($restoredPath, [Text.Encoding]::UTF8) -cne [string]$migrateLegacyContent[$_]
    })
    Assert-True "receipt rollback restores the exact 27-item V1 Codex surface" (
        $failedV1Restores.Count -eq 0
    ) ($failedV1Restores -join "; ")
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

    $heldMigrationMutex = New-Object Threading.Mutex(
        $true,
        (Get-TestMigrationMutexName -TestRoot $fixtureRoot)
    )
    try {
        $overlapCase = Join-Path $fixtureRoot "overlap-lock"
        $overlap = Invoke-Installer -CaseRoot $overlapCase -Apply
        Assert-True "shared migration mutex blocks a partially overlapping installer" ($overlap.ExitCode -ne 0) $overlap.Output
        Assert-True "blocked overlapping installer performs zero target writes" (-not (Test-Path -LiteralPath $overlapCase)) $overlap.Output
        $mixedCaseRoot = $fixtureRoot.ToUpperInvariant()
        $mixedCaseCase = Join-Path $fixtureRoot "mixed-case-lock"
        $mixedCase = Invoke-Installer `
            -CaseRoot $mixedCaseCase `
            -Apply `
            -TestRootOverride $mixedCaseRoot
        Assert-True "fixture mutex uses Windows case-insensitive path identity" (
            $mixedCase.ExitCode -ne 0 -and
            (($mixedCase.Output -replace '\s+', '') -match
                [regex]::Escape(('Another Boring Is All You Need install or rollback transaction is active' -replace '\s+', '')))
        ) $mixedCase.Output
        Assert-True "mixed-case mutex collision performs zero target writes" (
            -not (Test-Path -LiteralPath $mixedCaseCase)
        ) $mixedCase.Output
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

    $installSnapshotRaceCase = Join-Path $fixtureRoot "install-snapshot-race"
    $installSnapshotRaceCodex = Join-Path $installSnapshotRaceCase "codex"
    New-Item -ItemType Directory -Path $installSnapshotRaceCodex -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $installSnapshotRaceCodex "AGENTS.md"), "snapshot-original", [Text.Encoding]::UTF8)
    $env:STEADYAGENT_TEST_MODE = "1"
    try {
        $installSnapshotRace = Invoke-Installer -CaseRoot $installSnapshotRaceCase `
            -Apply `
            -ReplaceExistingWorkflow `
            -InjectPostWriteFailureAt 1 `
            -InjectSnapshotMutationAt 1
    }
    finally {
        Remove-Item Env:STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
    }
    $installSnapshotRaceReceipt = [IO.File]::ReadAllText(
        (Join-Path $installSnapshotRace.BackupRoot "migration-receipt.json"),
        [Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    $installSnapshotRaceEntry = @($installSnapshotRaceReceipt.entries)[0]
    Assert-True "automatic rollback rejects a changed original snapshot" ($installSnapshotRace.ExitCode -ne 0) $installSnapshotRace.Output
    Assert-True "changed snapshot cannot overwrite the installed target" (
        (Get-FileHash -LiteralPath $installSnapshotRaceEntry.destination -Algorithm SHA256).Hash -eq
        $installSnapshotRaceEntry.installed_sha256
    )
    Assert-True "changed automatic-rollback snapshot is recorded as incomplete" (
        [string]$installSnapshotRaceReceipt.status -eq "rollback_incomplete"
    )

    $snapshotCommitRaceCase = Join-Path $fixtureRoot "snapshot-commit-race"
    $snapshotCommitRaceCodex = Join-Path $snapshotCommitRaceCase "codex"
    New-Item -ItemType Directory -Path $snapshotCommitRaceCodex -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $snapshotCommitRaceCodex "AGENTS.md"), "commit-snapshot-original", [Text.Encoding]::UTF8)
    $env:STEADYAGENT_TEST_MODE = "1"
    try {
        $snapshotCommitRace = Invoke-Installer -CaseRoot $snapshotCommitRaceCase `
            -Apply `
            -ReplaceExistingWorkflow `
            -InjectSnapshotMutationAt 1
    }
    finally {
        Remove-Item Env:STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
    }
    $snapshotCommitRaceReceipt = [IO.File]::ReadAllText(
        (Join-Path $snapshotCommitRace.BackupRoot "migration-receipt.json"),
        [Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    $snapshotCommitRaceEntry = @($snapshotCommitRaceReceipt.entries)[0]
    Assert-True "final snapshot verification rejects mutation-only drift" ($snapshotCommitRace.ExitCode -ne 0) $snapshotCommitRace.Output
    Assert-True "mutation-only drift never produces an applied receipt" (
        [string]$snapshotCommitRaceReceipt.status -eq "rollback_incomplete"
    )
    Assert-True "mutation-only drift cannot restore corrupted snapshot content" (
        (Get-FileHash -LiteralPath $snapshotCommitRaceEntry.destination -Algorithm SHA256).Hash -eq
        $snapshotCommitRaceEntry.installed_sha256
    )

    $receiptSnapshotRaceCase = Join-Path $fixtureRoot "receipt-snapshot-race"
    $receiptSnapshotRaceCodex = Join-Path $receiptSnapshotRaceCase "codex"
    New-Item -ItemType Directory -Path $receiptSnapshotRaceCodex -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $receiptSnapshotRaceCodex "AGENTS.md"), "receipt-snapshot-original", [Text.Encoding]::UTF8)
    $receiptSnapshotRace = Invoke-Installer -CaseRoot $receiptSnapshotRaceCase -Apply -ReplaceExistingWorkflow
    Assert-True "receipt snapshot race fixture installs successfully" ($receiptSnapshotRace.ExitCode -eq 0) $receiptSnapshotRace.Output
    $receiptSnapshotRaceReceiptPath = Join-Path $receiptSnapshotRace.BackupRoot "migration-receipt.json"
    $receiptSnapshotRaceReceipt = [IO.File]::ReadAllText($receiptSnapshotRaceReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $receiptSnapshotRaceEntry = @($receiptSnapshotRaceReceipt.entries | Where-Object { $_.existed })[0]
    $receiptSnapshotRacePath = Join-Path $receiptSnapshotRace.BackupRoot ([string]$receiptSnapshotRaceEntry.snapshot_name)
    $env:STEADYAGENT_TEST_MODE = "1"
    try {
        $receiptSnapshotRaceResult = Invoke-ReceiptRollback `
            -InstallResult $receiptSnapshotRace `
            -InjectSnapshotMutationPath $receiptSnapshotRacePath
    }
    finally {
        Remove-Item Env:STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
    }
    Assert-True "receipt rollback rejects a snapshot changed after validation" ($receiptSnapshotRaceResult.ExitCode -ne 0) $receiptSnapshotRaceResult.Output
    Assert-True "rejected snapshot race performs zero target writes" (
        (Get-FileHash -LiteralPath $receiptSnapshotRaceEntry.destination -Algorithm SHA256).Hash -eq
        $receiptSnapshotRaceEntry.installed_sha256
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
    Assert-True "rollback detects drift immediately before a later restore" (
        $rollbackRaceResult.ExitCode -ne 0 -and
        $rollbackRaceResult.Output -match "changed immediately before restoration"
    ) $rollbackRaceResult.Output
    Assert-True "rollback preserves the immediate external drift" (
        (Get-Content -Raw -LiteralPath $rollbackRace.ManagedPath) -eq "injected-rollback-drift"
    ) $rollbackRaceResult.Output
    Assert-True "blocked rollback reapplies earlier installed state" (
        (Get-FileHash -LiteralPath $firstInstalledEntry.destination -Algorithm SHA256).Hash -eq $firstInstalledEntry.installed_sha256
    )

    $rollbackJunctionCase = Join-Path $fixtureRoot "rollback-junction-swap"
    $rollbackJunctionInstall = Invoke-Installer -CaseRoot $rollbackJunctionCase -Apply
    Assert-True "rollback junction fixture installs successfully" (
        $rollbackJunctionInstall.ExitCode -eq 0
    ) $rollbackJunctionInstall.Output
    $rollbackJunctionEscapeRoot = Join-Path $rollbackJunctionCase "rollback-escape"
    $rollbackJunctionParkedRoot = Join-Path $rollbackJunctionCase "rollback-parked"
    New-Item -ItemType Directory -Path $rollbackJunctionEscapeRoot -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $rollbackJunctionEscapeRoot "sentinel.txt"),
        "rollback-escape-sentinel`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $rollbackJunctionEscapeBefore = Get-ManagedSurfaceFingerprint `
        -Roots @($rollbackJunctionEscapeRoot) `
        -Files @()
    $rollbackJunctionResult = Invoke-ReceiptRollback `
        -InstallResult $rollbackJunctionInstall `
        -InjectJunctionSwapAt 1 `
        -InjectJunctionParkedRoot $rollbackJunctionParkedRoot `
        -InjectJunctionEscapeRoot $rollbackJunctionEscapeRoot
    Assert-True "rollback mutation blocks a junction swap after validation" (
        $rollbackJunctionResult.ExitCode -eq 0 -and
        $rollbackJunctionResult.Output -match "TEST rollback junction swap blocked"
    ) $rollbackJunctionResult.Output
    Assert-True "blocked rollback junction swap leaves the escape tree byte-identical" (
        (Get-ManagedSurfaceFingerprint `
            -Roots @($rollbackJunctionEscapeRoot) `
            -Files @()) -ceq $rollbackJunctionEscapeBefore -and
        -not (Test-Path -LiteralPath $rollbackJunctionParkedRoot)
    ) $rollbackJunctionResult.Output

    $rollbackHardKillCase = Join-Path $fixtureRoot "rollback-hard-kill-op1"
    $rollbackHardKillInstall = Invoke-Installer -CaseRoot $rollbackHardKillCase -Apply
    Assert-True "rollback hard-kill fixture installs successfully" (
        $rollbackHardKillInstall.ExitCode -eq 0
    ) $rollbackHardKillInstall.Output
    $rollbackHardKillReceiptPath = Join-Path $rollbackHardKillInstall.BackupRoot "migration-receipt.json"
    $rollbackHardKillReceiptBefore = (
        Get-FileHash -LiteralPath $rollbackHardKillReceiptPath -Algorithm SHA256
    ).Hash
    $rollbackHardKill = Invoke-ReceiptRollback `
        -InstallResult $rollbackHardKillInstall `
        -InjectHardKillAfterRollbackOperation 1
    $rollbackHardKillJournalPath = Join-Path $rollbackHardKillInstall.BackupRoot "rollback-journal.json"
    $rollbackHardKillJournal = if (
        Test-Path -LiteralPath $rollbackHardKillJournalPath -PathType Leaf
    ) {
        [IO.File]::ReadAllText(
            $rollbackHardKillJournalPath,
            [Text.Encoding]::UTF8
        ) | ConvertFrom-Json
    }
    else { $null }
    Assert-True "hard kill after rollback op1 leaves a rolling-back sidecar journal" (
        $rollbackHardKill.ExitCode -ne 0 -and
        $rollbackHardKillJournal -and
        [string]$rollbackHardKillJournal.state -eq "rolling_back"
    ) $rollbackHardKill.Output
    Assert-True "active rollback journal leaves the schema2 receipt byte-identical" (
        (Get-FileHash -LiteralPath $rollbackHardKillReceiptPath -Algorithm SHA256).Hash -ceq
            $rollbackHardKillReceiptBefore
    )
    $rollbackHardKillDiagnosis = Invoke-InstalledBytesDiagnosisFixture `
        -DiagnosePath (Join-Path $testPackageRoot "tools\diagnose-install.ps1") `
        -InstallResult $rollbackHardKillInstall
    Assert-True "strict installed-byte diagnosis rejects a rollback middle state" (
        $rollbackHardKillDiagnosis.ExitCode -ne 0 -and
        $rollbackHardKillDiagnosis.Output -match "FAIL receipt-bound exact installed bytes" -and
        $rollbackHardKillDiagnosis.Output -match "fail=[1-9]"
    ) $rollbackHardKillDiagnosis.Output
    $rollbackHardKillJournalBytes = [IO.File]::ReadAllBytes($rollbackHardKillJournalPath)
    $rollbackHardKillJournal.snapshot_set_sha256 = "0" * 64
    $rollbackHardKillJournal.journal_integrity_sha256 = (
        Get-RollbackJournalIntegritySha256 -Journal $rollbackHardKillJournal
    )
    [IO.File]::WriteAllText(
        $rollbackHardKillJournalPath,
        (($rollbackHardKillJournal | ConvertTo-Json -Depth 10) + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )
    $rollbackSnapshotSetTamper = Invoke-ReceiptRollback `
        -InstallResult $rollbackHardKillInstall `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "rollback journal rejects a recomputed-integrity snapshot-set substitution" (
        $rollbackSnapshotSetTamper.ExitCode -ne 0 -and
        $rollbackSnapshotSetTamper.Output -match "snapshot-set verification failed"
    ) $rollbackSnapshotSetTamper.Output
    [IO.File]::WriteAllBytes($rollbackHardKillJournalPath, $rollbackHardKillJournalBytes)
    $rollbackHardKillRecovery = Invoke-ReceiptRollback `
        -InstallResult $rollbackHardKillInstall `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "rolling-back sidecar recovery converges after rollback op1 hard kill" (
        $rollbackHardKillRecovery.ExitCode -eq 0
    ) $rollbackHardKillRecovery.Output

    $finalizeFailureCase = Join-Path $fixtureRoot "rollback-finalize-journal-failure"
    $finalizeFailureTarget = Join-Path $finalizeFailureCase "steadyagent"
    $finalizeFailureCodex = Join-Path $finalizeFailureCase "codex"
    $finalizeFailureManaged = Join-Path $finalizeFailureCase "managed/requirements.toml"
    $finalizeFailureGitConfig = Join-Path $finalizeFailureCase "gitconfig"
    $finalizeFailureInstall = Invoke-Installer -CaseRoot $finalizeFailureCase -Apply
    Assert-True "completed-journal failure fixture installs successfully" (
        $finalizeFailureInstall.ExitCode -eq 0
    ) $finalizeFailureInstall.Output
    $finalizeFailureResult = Invoke-ReceiptRollback `
        -InstallResult $finalizeFailureInstall `
        -InjectCompletedJournalWriteFailure
    $finalizeFailureReceiptPath = Join-Path $finalizeFailureInstall.BackupRoot "migration-receipt.json"
    $finalizeFailureJournalPath = Join-Path $finalizeFailureInstall.BackupRoot "rollback-journal.json"
    $finalizeFailureReceipt = (
        [IO.File]::ReadAllText($finalizeFailureReceiptPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    $finalizeFailureJournal = (
        [IO.File]::ReadAllText($finalizeFailureJournalPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    $finalizeFailureSurface = Get-ManagedSurfaceFingerprint `
        -Roots @($finalizeFailureCodex, $finalizeFailureTarget) `
        -Files @($finalizeFailureManaged, $finalizeFailureGitConfig)
    $finalizeFailureTargetsRestored = $true
    foreach ($entry in @($finalizeFailureReceipt.entries)) {
        $destination = [string]$entry.destination
        if ([bool]$entry.existed) {
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or
                (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne
                    [string]$entry.original_sha256) {
                $finalizeFailureTargetsRestored = $false
                break
            }
        }
        elseif (Test-Path -LiteralPath $destination) {
            $finalizeFailureTargetsRestored = $false
            break
        }
    }
    $finalizeFailureGitHooks = @(
        & git config --file $finalizeFailureGitConfig --get core.hooksPath
    )
    Assert-True "completed-journal write failure returns a retryable refusal" (
        $finalizeFailureResult.ExitCode -eq 2 -and
        $finalizeFailureResult.Output -match "finalized" -and
        $finalizeFailureResult.Output -match "retry"
    ) $finalizeFailureResult.Output
    Assert-True "completed-journal write failure keeps an integrity-valid finalized receipt" (
        [string]$finalizeFailureReceipt.status -eq "restored" -and
        [string]$finalizeFailureReceipt.receipt_integrity_sha256 -ceq
            (Get-ReceiptIntegritySha256 -Receipt $finalizeFailureReceipt)
    ) $finalizeFailureResult.Output
    Assert-True "completed-journal write failure keeps the journal finalizing" (
        [string]$finalizeFailureJournal.state -eq "finalizing" -and
        [string]$finalizeFailureJournal.journal_integrity_sha256 -ceq
            (Get-RollbackJournalIntegritySha256 -Journal $finalizeFailureJournal)
    ) $finalizeFailureResult.Output
    Assert-True "completed-journal write failure never compensates restored targets" (
        $finalizeFailureTargetsRestored -and
        $finalizeFailureGitHooks.Count -eq 0
    ) $finalizeFailureResult.Output
    $finalizeFailurePointers = @(
        Get-ChildItem -LiteralPath $finalizeFailureCase `
            -Filter ".steadyagent-active-receipt-*.json" -File -Force
    )
    $finalizeFailureBeforeReentry = Get-ManagedSurfaceFingerprint `
        -Roots @($finalizeFailureCase) `
        -Files @()
    $finalizeFailureReentry = Invoke-Installer `
        -CaseRoot $finalizeFailureCase `
        -CustomBackupRoot (Join-Path $finalizeFailureCase "backup-rerun") `
        -Apply `
        -ReplaceExistingWorkflow
    Assert-True "finalizing rollback retains active authority and blocks installer reentry" (
        $finalizeFailurePointers.Count -eq 1 -and
        $finalizeFailureReentry.ExitCode -eq 3 -and
        $finalizeFailureReentry.Output -match "rollback journal" -and
        $finalizeFailureReentry.Output -match "not completed"
    ) $finalizeFailureReentry.Output
    Assert-True "blocked finalizing rollback reentry performs zero writes" (
        (Get-ManagedSurfaceFingerprint -Roots @($finalizeFailureCase) -Files @()) -ceq
            $finalizeFailureBeforeReentry -and
        -not (Test-Path -LiteralPath (Join-Path $finalizeFailureCase "backup-rerun"))
    ) $finalizeFailureReentry.Output
    $finalizeFailureReceiptHash = (
        Get-FileHash -LiteralPath $finalizeFailureReceiptPath -Algorithm SHA256
    ).Hash
    $finalizeFailureRetry = Invoke-ReceiptRollback `
        -InstallResult $finalizeFailureInstall `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    $finalizeFailureCompletedJournal = (
        [IO.File]::ReadAllText($finalizeFailureJournalPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    Assert-True "finalizing rollback retry converges to completed" (
        $finalizeFailureRetry.ExitCode -eq 0 -and
        [string]$finalizeFailureCompletedJournal.state -eq "completed"
    ) $finalizeFailureRetry.Output
    Assert-True "finalizing rollback retry preserves receipt bytes and restored targets" (
        (Get-FileHash -LiteralPath $finalizeFailureReceiptPath -Algorithm SHA256).Hash -ceq
            $finalizeFailureReceiptHash -and
        (Get-ManagedSurfaceFingerprint `
            -Roots @($finalizeFailureCodex, $finalizeFailureTarget) `
            -Files @($finalizeFailureManaged, $finalizeFailureGitConfig)) -ceq
                $finalizeFailureSurface
    ) $finalizeFailureRetry.Output
    $completedReceiptHash = (
        Get-FileHash -LiteralPath $finalizeFailureReceiptPath -Algorithm SHA256
    ).Hash
    $completedJournalHash = (
        Get-FileHash -LiteralPath $finalizeFailureJournalPath -Algorithm SHA256
    ).Hash
    $completedSurface = Get-ManagedSurfaceFingerprint `
        -Roots @($finalizeFailureCodex, $finalizeFailureTarget) `
        -Files @($finalizeFailureManaged, $finalizeFailureGitConfig)
    $finalizeFailureCompletedPreview = Invoke-ReceiptRollback `
        -InstallResult $finalizeFailureInstall `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1") `
        -DryRun
    Assert-True "completed rollback preview is an idempotent zero-write success" (
        $finalizeFailureCompletedPreview.ExitCode -eq 0 -and
        $finalizeFailureCompletedPreview.Output -match "already completed; 0 writes" -and
        (Get-FileHash -LiteralPath $finalizeFailureReceiptPath -Algorithm SHA256).Hash -ceq
            $completedReceiptHash -and
        (Get-FileHash -LiteralPath $finalizeFailureJournalPath -Algorithm SHA256).Hash -ceq
            $completedJournalHash -and
        (Get-ManagedSurfaceFingerprint `
            -Roots @($finalizeFailureCodex, $finalizeFailureTarget) `
            -Files @($finalizeFailureManaged, $finalizeFailureGitConfig)) -ceq
                $completedSurface
    ) $finalizeFailureCompletedPreview.Output
    $finalizeFailureCompletedRetry = Invoke-ReceiptRollback `
        -InstallResult $finalizeFailureInstall `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "completed rollback retry is a zero-write success" (
        $finalizeFailureCompletedRetry.ExitCode -eq 0 -and
        $finalizeFailureCompletedRetry.Output -match "already completed" -and
        (Get-FileHash -LiteralPath $finalizeFailureReceiptPath -Algorithm SHA256).Hash -ceq
            $completedReceiptHash -and
        (Get-FileHash -LiteralPath $finalizeFailureJournalPath -Algorithm SHA256).Hash -ceq
            $completedJournalHash -and
        (Get-ManagedSurfaceFingerprint `
            -Roots @($finalizeFailureCodex, $finalizeFailureTarget) `
            -Files @($finalizeFailureManaged, $finalizeFailureGitConfig)) -ceq
                $completedSurface
    ) $finalizeFailureCompletedRetry.Output

    $finalizeHardKillCase = Join-Path $fixtureRoot "rollback-finalize-hard-kill"
    $finalizeHardKillInstall = Invoke-Installer -CaseRoot $finalizeHardKillCase -Apply
    Assert-True "receipt-finalize hard-kill fixture installs successfully" (
        $finalizeHardKillInstall.ExitCode -eq 0
    ) $finalizeHardKillInstall.Output
    $finalizeHardKillResult = Invoke-ReceiptRollback `
        -InstallResult $finalizeHardKillInstall `
        -InjectHardKillAfterReceiptFinalize
    $finalizeHardKillReceiptPath = Join-Path $finalizeHardKillInstall.BackupRoot "migration-receipt.json"
    $finalizeHardKillJournalPath = Join-Path $finalizeHardKillInstall.BackupRoot "rollback-journal.json"
    $finalizeHardKillReceipt = (
        [IO.File]::ReadAllText($finalizeHardKillReceiptPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    $finalizeHardKillJournal = (
        [IO.File]::ReadAllText($finalizeHardKillJournalPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    Assert-True "hard kill after receipt finalize preserves monotonic finalizing state" (
        $finalizeHardKillResult.ExitCode -ne 0 -and
        [string]$finalizeHardKillReceipt.status -eq "restored" -and
        [string]$finalizeHardKillJournal.state -eq "finalizing"
    ) $finalizeHardKillResult.Output
    $finalizeHardKillRecovery = Invoke-ReceiptRollback `
        -InstallResult $finalizeHardKillInstall `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    $finalizeHardKillCompleted = (
        [IO.File]::ReadAllText($finalizeHardKillJournalPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    Assert-True "receipt-finalize hard-kill retry converges to completed" (
        $finalizeHardKillRecovery.ExitCode -eq 0 -and
        [string]$finalizeHardKillCompleted.state -eq "completed" -and
        @(Get-ChildItem -LiteralPath $finalizeHardKillCase `
            -Filter ".steadyagent-active-receipt-*.json" -File -Force).Count -eq 0
    ) $finalizeHardKillRecovery.Output

    foreach ($finalizingPhase in @(
        [pscustomobject]@{
            Name = "before-journal-finalizing"
            SwitchName = "InjectHardKillBeforeJournalFinalizing"
            ExpectedJournalState = "rolling_back"
        },
        [pscustomobject]@{
            Name = "after-journal-finalizing"
            SwitchName = "InjectHardKillAfterJournalFinalizing"
            ExpectedJournalState = "finalizing"
        }
    )) {
        $phaseCase = Join-Path $fixtureRoot ("rollback-" + $finalizingPhase.Name)
        $phaseInstall = Invoke-Installer -CaseRoot $phaseCase -Apply
        $phaseRollbackArguments = @{
            InstallResult = $phaseInstall
            RollbackPath = (Join-Path $testPackageRoot "tools\rollback.ps1")
        }
        $phaseRollbackArguments[[string]$finalizingPhase.SwitchName] = $true
        $phaseHardKill = Invoke-ReceiptRollback @phaseRollbackArguments
        $phaseJournalPath = Join-Path $phaseInstall.BackupRoot "rollback-journal.json"
        $phaseReceiptPath = Join-Path $phaseInstall.BackupRoot "migration-receipt.json"
        $phaseJournal = if (Test-Path -LiteralPath $phaseJournalPath -PathType Leaf) {
            [IO.File]::ReadAllText($phaseJournalPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        } else { $null }
        $phaseReceipt = [IO.File]::ReadAllText($phaseReceiptPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
        $phasePointers = @(
            Get-ChildItem -LiteralPath $phaseCase `
                -Filter ".steadyagent-active-receipt-*.json" -File -Force
        )
        Assert-True ("rollback hard kill retains active authority: " + $finalizingPhase.Name) (
            $phaseInstall.ExitCode -eq 0 -and
            $phaseHardKill.ExitCode -ne 0 -and
            $phasePointers.Count -eq 1 -and
            $null -ne $phaseJournal -and
            [string]$phaseJournal.state -eq [string]$finalizingPhase.ExpectedJournalState -and
            [string]$phaseReceipt.status -eq "applied"
        ) $phaseHardKill.Output
        $phaseBeforeReentry = Get-ManagedSurfaceFingerprint -Roots @($phaseCase) -Files @()
        $phaseReentry = Invoke-Installer `
            -CaseRoot $phaseCase `
            -CustomBackupRoot (Join-Path $phaseCase "backup-rerun") `
            -Apply `
            -ReplaceExistingWorkflow
        Assert-True ("pending rollback blocks installer reentry: " + $finalizingPhase.Name) (
            $phaseReentry.ExitCode -eq 3 -and
            $phaseReentry.Output -match "rollback journal" -and
            $phaseReentry.Output -match "not completed" -and
            (Get-ManagedSurfaceFingerprint -Roots @($phaseCase) -Files @()) -ceq
                $phaseBeforeReentry -and
            -not (Test-Path -LiteralPath (Join-Path $phaseCase "backup-rerun"))
        ) $phaseReentry.Output
        $phaseRecovery = Invoke-ReceiptRollback `
            -InstallResult $phaseInstall `
            -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
        Assert-True ("pending rollback retry completes and releases authority: " + $finalizingPhase.Name) (
            $phaseRecovery.ExitCode -eq 0 -and
            @(Get-ChildItem -LiteralPath $phaseCase `
                -Filter ".steadyagent-active-receipt-*.json" -File -Force).Count -eq 0
        ) $phaseRecovery.Output
    }

    $completedPointerCase = Join-Path $fixtureRoot "rollback-completed-pointer-hard-kill"
    $completedPointerInstall = Invoke-Installer -CaseRoot $completedPointerCase -Apply
    $completedPointerKill = Invoke-ReceiptRollback `
        -InstallResult $completedPointerInstall `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1") `
        -InjectHardKillAfterJournalCompleted
    $completedPointerJournal = [IO.File]::ReadAllText(
        (Join-Path $completedPointerInstall.BackupRoot "rollback-journal.json"),
        [Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    Assert-True "completed journal hard kill retains recoverable active pointer" (
        $completedPointerInstall.ExitCode -eq 0 -and
        $completedPointerKill.ExitCode -ne 0 -and
        [string]$completedPointerJournal.state -eq "completed" -and
        @(Get-ChildItem -LiteralPath $completedPointerCase `
            -Filter ".steadyagent-active-receipt-*.json" -File -Force).Count -eq 1
    ) $completedPointerKill.Output
    $completedPointerRecovery = Invoke-ReceiptRollback `
        -InstallResult $completedPointerInstall `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "completed journal retry releases active pointer authority" (
        $completedPointerRecovery.ExitCode -eq 0 -and
        @(Get-ChildItem -LiteralPath $completedPointerCase `
            -Filter ".steadyagent-active-receipt-*.json" -File -Force).Count -eq 0
    ) $completedPointerRecovery.Output

    $compensationHardKillCase = Join-Path $fixtureRoot "rollback-compensation-hard-kill"
    $compensationHardKillInstall = Invoke-Installer -CaseRoot $compensationHardKillCase -Apply
    Assert-True "rollback compensation hard-kill fixture installs successfully" (
        $compensationHardKillInstall.ExitCode -eq 0
    ) $compensationHardKillInstall.Output
    $compensationEnteringFingerprint = Get-ManagedSurfaceFingerprint `
        -Roots @($compensationHardKillInstall.CodexHome, $compensationHardKillInstall.TargetRoot) `
        -Files @($compensationHardKillInstall.ManagedPath, $compensationHardKillInstall.GitConfigPath)
    $compensationHardKill = Invoke-ReceiptRollback `
        -InstallResult $compensationHardKillInstall `
        -InjectFailureAfterRestore 3 `
        -InjectHardKillAfterCompensationOperation 1
    $compensationJournalPath = Join-Path $compensationHardKillInstall.BackupRoot "rollback-journal.json"
    $compensationJournal = (
        [IO.File]::ReadAllText($compensationJournalPath, [Text.Encoding]::UTF8) |
            ConvertFrom-Json
    )
    Assert-True "hard kill during rollback compensation leaves compensating journal state" (
        $compensationHardKill.ExitCode -ne 0 -and
        [string]$compensationJournal.state -eq "compensating"
    ) $compensationHardKill.Output
    $compensationResume = Invoke-ReceiptRollback `
        -InstallResult $compensationHardKillInstall `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "compensating journal resumes to exact entering state before retry" (
        $compensationResume.ExitCode -eq 2 -and
        $compensationResume.Output -match "compensation completed" -and
        (Get-ManagedSurfaceFingerprint `
            -Roots @($compensationHardKillInstall.CodexHome, $compensationHardKillInstall.TargetRoot) `
            -Files @($compensationHardKillInstall.ManagedPath, $compensationHardKillInstall.GitConfigPath)) -ceq
                $compensationEnteringFingerprint
    ) $compensationResume.Output
    $compensationRetry = Invoke-ReceiptRollback `
        -InstallResult $compensationHardKillInstall `
        -RollbackPath (Join-Path $testPackageRoot "tools\rollback.ps1")
    Assert-True "compensated rollback can be explicitly retried to completion" (
        $compensationRetry.ExitCode -eq 0
    ) $compensationRetry.Output

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

    Write-SemanticCheck -Id "migration.rendered-three-block-unified-matrix" -Cases @(
        "install publish blocks a junction swap after validation",
        "blocked install junction swap leaves the escape tree byte-identical",
        "production-shaped skill routing fixture installs successfully",
        "installed skill routing resolves in a clean session without STEADYAGENT_HOME",
        "rollback junction fixture installs successfully",
        "rollback mutation blocks a junction swap after validation",
        "blocked rollback junction swap leaves the escape tree byte-identical",
        "fresh install succeeds",
        "fresh install writes one integrity-protected active receipt pointer",
        "second Apply reports already installed",
        "second Apply performs zero managed or evidence writes",
        "idempotent Apply rejects a damaged active receipt pointer",
        "idempotent Apply rejects multiple active receipt candidates",
        "package asset tamper fails against the installer trust anchor",
        "package asset tamper performs zero case writes",
        "package manifest tamper fails against the embedded digest",
        "package manifest tamper performs zero case writes",
        "installer rejects a missing frozen migration runtime before writes",
        "missing installer runtime rejection performs zero migration writes",
        "installer rejects a tampered frozen migration runtime before writes",
        "tampered installer runtime rejection performs zero migration writes",
        "installer rejects a reparse-point migration runtime path before writes",
        "reparse installer runtime rejection performs zero migration writes",
        "rollback rejects a missing frozen migration runtime before writes",
        "missing rollback runtime rejection performs zero migration writes",
        "rollback rejects a tampered frozen migration runtime before writes",
        "tampered rollback runtime rejection performs zero migration writes",
        "rollback rejects a reparse frozen migration runtime before writes",
        "reparse rollback runtime rejection performs zero migration writes",
        "test mode alone cannot unlock installer fixture paths",
        "test mode requires an independent package copy inside its fixture root",
        "hard kill after the first target write leaves an applying receipt",
        "package rollback tool can recover a first-write crash",
        "hard-kill applying receipt is published through one active pointer",
        "installer reentry refuses an active applying receipt and prints recovery evidence",
        "refused installer reentry performs zero managed or evidence writes",
        "original applying receipt remains recoverable after refused installer reentry",
        "automatic rollback incomplete returns manual-recovery exit 3",
        "automatic rollback incomplete repeats durable recovery evidence and no-blind-retry warning",
        "rollback repairs and restores atomic subtransaction: after-old-rename",
        "atomic pending rollback dry-run reports recovery without writes: after-old-rename",
        "atomic crash recovery removes durable mutation artifacts: after-old-rename",
        "rollback repairs and restores atomic subtransaction: after-publish",
        "atomic pending rollback dry-run reports recovery without writes: after-publish",
        "atomic crash recovery removes durable mutation artifacts: after-publish",
        "mutex refusal cannot repair a pending bound mutation",
        "pending bound mutation remains recoverable after mutex refusal",
        "rollback repairs a hard kill inside bound delete",
        "bound delete crash recovery leaves no mutation artifacts",
        "directory publication hard kill leaves an applying receipt: after-stage-create",
        "directory publication crash state matches its receipt: after-stage-create",
        "directory publication hard kill rollback restores preimage: after-stage-create",
        "directory publication hard kill leaves an applying receipt: after-receipt-before-pointer",
        "directory publication crash state matches its receipt: after-receipt-before-pointer",
        "directory publication hard kill rollback restores preimage: after-receipt-before-pointer",
        "stale directory receipt pointer is removed by rollback",
        "directory publication hard kill leaves an applying receipt: after-receipt",
        "directory publication crash state matches its receipt: after-receipt",
        "directory publication hard kill rollback restores preimage: after-receipt",
        "directory publication hard kill leaves an applying receipt: after-publish",
        "directory publication crash state matches its receipt: after-publish",
        "directory publication hard kill rollback restores preimage: after-publish",
        "hard kill between applied receipt and pointer leaves a valid applied receipt",
        "applied receipt hard kill leaves exactly one stale same-receipt pointer",
        "rollback accepts and removes the stale same-receipt pointer",
        "install can proceed after stale same-receipt pointer recovery",
        "rollback authority barrier reaches the exact pre-mutex seam",
        "stale rollback authority is rejected after mutex acquisition",
        "stale rollback authority cannot modify the replacement transaction",
        "hard kill during file apply leaves an applying recovery receipt",
        "applying receipt records only actually created directory identities",
        "mid-apply hard kill leaves only a known mixed original-post state",
        "applying receipt rollback dry-run performs zero writes",
        "failed applying recovery reapplies the exact entering mixed state",
        "applying receipt can restore the complete preimage",
        "successful applying recovery publishes an integrity-valid rolled-back receipt",
        "hard kill after Git activation preserves an applying receipt",
        "post-Git-activation applying receipt can be recovered",
        "Git config CAS rejects a third-party value in the final write window",
        "Git config CAS preserves the third-party value",
        "Git config CAS rejection restores all non-Git targets",
        "rollback Git config CAS rejects a third-party value in the final window",
        "rollback Git config CAS preserves the third-party value",
        "failed rollback Git CAS compensates all non-Git targets",
        "incomplete applying recovery durably publishes rollback-incomplete",
        "managed config has exact three blocks and one unified PreToolUse",
        "managed config omits high-frequency events",
        "installed diagnosis rejects a wrong managed matcher",
        "migration receipt install set is exactly the frozen 53 destinations",
        "migration receipt removal set is exactly the fixed 27 destinations",
        "migration receipt records created rules directory",
        "rollback rejects a replaced created-directory identity before writes",
        "created-directory identity rejection performs zero target writes",
        "rollback rejects a receipt with an extra install entry",
        "rollback rejects a receipt with a missing install entry",
        "rollback rejects an equal-count install destination substitution",
        "rollback rejects duplicate snapshot references",
        "rollback rejects a tampered Git before value",
        "rollback rejects a tampered Git after value even when active Git matches it",
        "production migration lock remains machine-wide while fixtures are root-scoped",
        "migration mutex excludes unrelated authenticated users",
        "unavailable machine-wide migration mutex fails closed",
        "rollback fails closed when the machine-wide mutex is unavailable",
        "production migration rejects elevation outside the exact GitHub fixture contract",
        "production migration exposes no protected recovery capsule entry point",
        "simulated elevated install apply fails closed",
        "simulated elevated install apply performs zero case writes",
        "pre-receipt snapshot failure exits before target writes",
        "pre-receipt snapshot failure removes its orphan backup",
        "simulated elevated rollback apply fails closed",
        "simulated elevated rollback apply performs zero case writes",
        "simulated elevated rollback dry-run fails closed",
        "simulated elevated rollback dry-run performs zero case writes",
        "test rollback requires its tool inside STEADYAGENT_TEST_ROOT",
        "non-elevated custom fixture uses its reviewed backup receipt",
        "second Apply reports already installed",
        "second Apply performs zero managed or evidence writes",
        "completed-journal failure fixture installs successfully",
        "completed-journal write failure returns a retryable refusal",
        "completed-journal write failure keeps an integrity-valid finalized receipt",
        "completed-journal write failure keeps the journal finalizing",
        "completed-journal write failure never compensates restored targets",
        "finalizing rollback retry converges to completed",
        "finalizing rollback retry preserves receipt bytes and restored targets",
        "completed rollback retry is a zero-write success",
        "completed rollback preview is an idempotent zero-write success",
        "receipt-finalize hard-kill fixture installs successfully",
        "hard kill after receipt finalize preserves monotonic finalizing state",
        "receipt-finalize hard-kill retry converges to completed",
        "rollback journal rejects a recomputed-integrity snapshot-set substitution",
        "rollback-incomplete retry preserves the manual-recovery exit code",
        "rollback-incomplete retry makes zero managed or evidence writes",
        "hard kill during rollback compensation leaves compensating journal state",
        "compensating journal resumes to exact entering state before retry",
        "compensated rollback can be explicitly retried to completion"
    )
    Write-SemanticCheck -Id "diagnose.strict-installed-contract" -Cases @(
        "strict catalog fixture builds as rollout-file-confirmed",
        "strict diagnosis keeps rollout timestamps below Live evidence",
        "strict diagnosis accepts a task started after receipt completion",
        "strict diagnosis rejects a task started before receipt completion",
        "strict diagnosis rejects a missing owning task timestamp",
        "strict diagnosis rejects an invalid owning task timestamp",
        "strict diagnosis rejects a timestamp found only in parent metadata",
        "runtime catalog uses the verified receipt time after a path swap",
        "strict diagnosis enumerates the frozen installed PowerShell set",
        "strict diagnosis enumerates the complete installed asset set",
        "strict diagnosis verifies all receipt-bound installed bytes",
        "strict diagnosis pins parent authority against rename and junction exchange",
        "public diagnosis cannot bypass the installed Hook smoke",
        "strict diagnosis rejects a missing installed checkpoint tool",
        "strict diagnosis rejects a corrupt installed checkpoint tool",
        "strict diagnosis rejects a forged rollback before executing it",
        "strict diagnosis rejects a missing installed non-PowerShell asset",
        "strict diagnosis rejects a damaged runtime catalog",
        "strict diagnosis rejects a damaged review and skill contract",
        "strict diagnosis rejects missing Git identity",
        "strict diagnosis rejects whitespace-only Git identity",
        "strict diagnosis rejects syntactically invalid Git identity",
        "Git identity diagnosis never echoes identity values",
        "strict identity validation uses both Git author and committer var contracts"
    )
    Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

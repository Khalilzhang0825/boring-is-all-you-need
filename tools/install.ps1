[CmdletBinding()]
param(
    [string]$TargetRoot = (Join-Path $HOME ".steadyagent"),
    [string]$CodexHome = (Join-Path $HOME ".codex"),
    [string]$ManagedConfigPath,
    [string]$BackupRoot,
    [string]$GitConfigPath,
    [switch]$Apply,
    [switch]$ReplaceExistingWorkflow,
    [int]$InjectFailureAfter = 0,
    [int]$InjectPostWriteFailureAt = 0,
    [string]$InjectTargetMutationPath,
    [string]$InjectGitHooksMutationValue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$version = "2.0.0"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

if (-not $ManagedConfigPath) {
    $programDataRoot = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
    $ManagedConfigPath = Join-Path $programDataRoot "OpenAI\Codex\requirements.toml"
}
if (-not $BackupRoot) {
    $backupParent = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($TargetRoot))) ".steadyagent-backups"
    $BackupRoot = Join-Path $backupParent ((Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "-" + [guid]::NewGuid().ToString("N"))
}

function Get-RelativePathV2 {
    param([string]$Base, [string]$Path)
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("Source escaped package root: " + $Path)
    }
    return $pathFull.Substring($baseFull.Length)
}

function Assert-NoReparsePath {
    param([string]$Path, [switch]$AllowMissingLeaf)
    $cursor = [IO.Path]::GetFullPath($Path)
    if ($AllowMissingLeaf -and -not (Test-Path -LiteralPath $cursor)) {
        $cursor = Split-Path -Parent $cursor
    }
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ("Reparse point rejected: " + $cursor)
            }
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-Utf8NoBomAtomic {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    $temp = Join-Path $parent (".steadyagent-v2-receipt-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Copy-Atomically {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw ("Destination parent missing: " + $parent)
    }
    $temp = Join-Path $parent (".steadyagent-v2-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::Copy($Source, $temp, $false)
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-GitHooksPath {
    if ($GitConfigPath) { Assert-NoReparsePath -Path $GitConfigPath -AllowMissingLeaf }
    if ($GitConfigPath) {
        $value = & git config --file $GitConfigPath --get core.hooksPath
    }
    else {
        $value = & git config --global --get core.hooksPath
    }
    if ($LASTEXITCODE -eq 0) { return [string]$value }
    return $null
}

function Set-GitHooksPath {
    param([AllowNull()][string]$Value)
    if ($GitConfigPath) { Assert-NoReparsePath -Path $GitConfigPath -AllowMissingLeaf }
    if ($GitConfigPath) {
        $parent = Split-Path -Parent ([IO.Path]::GetFullPath($GitConfigPath))
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if ([string]::IsNullOrEmpty($Value)) {
            & git config --file $GitConfigPath --unset core.hooksPath
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 5) { throw "Could not unset fixture Git hooks path." }
        }
        else {
            & git config --file $GitConfigPath core.hooksPath $Value
            if ($LASTEXITCODE -ne 0) { throw "Could not set fixture Git hooks path." }
        }
    }
    else {
        if ([string]::IsNullOrEmpty($Value)) {
            & git config --global --unset core.hooksPath
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 5) { throw "Could not unset global Git hooks path." }
        }
        else {
            & git config --global core.hooksPath $Value
            if ($LASTEXITCODE -ne 0) { throw "Could not set global Git hooks path." }
        }
    }
}

function Add-PlanFile {
    param(
        [Collections.Generic.List[object]]$Plan,
        [string]$Source,
        [string]$Destination,
        [switch]$Render
    )
    $Plan.Add([pscustomobject]@{
        Source = [IO.Path]::GetFullPath($Source)
        Destination = [IO.Path]::GetFullPath($Destination)
        Render = [bool]$Render
    }) | Out-Null
}

function Add-PlanTree {
    param(
        [Collections.Generic.List[object]]$Plan,
        [string]$SourceRoot,
        [string]$DestinationRoot
    )
    foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File | Sort-Object FullName)) {
        $relative = Get-RelativePathV2 -Base $SourceRoot -Path $file.FullName
        Add-PlanFile -Plan $Plan -Source $file.FullName -Destination (Join-Path $DestinationRoot $relative)
    }
}

function Get-OperationConflicts {
    param([object[]]$Operations)
    $found = @()
    foreach ($item in $Operations) {
        if ($item.Action -eq "remove") {
            if (Test-Path -LiteralPath $item.Destination -PathType Leaf) {
                $found += $item.Destination
            }
            elseif (Test-Path -LiteralPath $item.Destination) {
                throw ("Removal target is not a regular file: " + $item.Destination)
            }
            continue
        }
        if (Test-Path -LiteralPath $item.Destination -PathType Leaf) {
            $currentHash = (Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash
            if ($currentHash -ne $item.DesiredHash) { $found += $item.Destination }
        }
        elseif (Test-Path -LiteralPath $item.Destination) {
            throw ("Destination is not a regular file: " + $item.Destination)
        }
    }
    return @($found)
}

$targetFull = [IO.Path]::GetFullPath($TargetRoot)
$codexFull = [IO.Path]::GetFullPath($CodexHome)
$managedFull = [IO.Path]::GetFullPath($ManagedConfigPath)
$backupFull = [IO.Path]::GetFullPath($BackupRoot)
foreach ($path in @($repoRoot, $targetFull, $codexFull, $managedFull, $backupFull)) {
    Assert-NoReparsePath -Path $path -AllowMissingLeaf
}

if (($InjectFailureAfter -gt 0 -or $InjectPostWriteFailureAt -gt 0 -or
     $InjectTargetMutationPath -or $InjectGitHooksMutationValue) -and
    $env:STEADYAGENT_TEST_MODE -ne "1") {
    throw "Failure and mutation injection are available only in the isolated migration test."
}
if ($targetFull.Equals($codexFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "TargetRoot and CodexHome must be different directories."
}
if ($backupFull.StartsWith($targetFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $backupFull.StartsWith($codexFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "BackupRoot must be outside the installation and Codex roots."
}

$plan = New-Object Collections.Generic.List[object]
$removals = New-Object Collections.Generic.List[object]
Add-PlanFile -Plan $plan -Source (Join-Path $repoRoot "templates\codex\AGENTS.md") -Destination (Join-Path $codexFull "AGENTS.md") -Render
Add-PlanFile -Plan $plan -Source (Join-Path $repoRoot "templates\codex\hooks.empty.json") -Destination (Join-Path $codexFull "hooks.json") -Render
Add-PlanFile -Plan $plan -Source (Join-Path $repoRoot "templates\codex\requirements.managed-hooks.example.toml") -Destination $managedFull -Render
Add-PlanTree -Plan $plan -SourceRoot (Join-Path $repoRoot "rules") -DestinationRoot (Join-Path $targetFull "rules")
Add-PlanTree -Plan $plan -SourceRoot (Join-Path $repoRoot "manifests") -DestinationRoot (Join-Path $targetFull "manifests")
Add-PlanFile -Plan $plan `
    -Source (Join-Path $repoRoot "templates\codex\requirements.managed-hooks.example.toml") `
    -Destination (Join-Path $targetFull "manifests\codex-requirements.expected.toml") `
    -Render
Add-PlanTree -Plan $plan -SourceRoot (Join-Path $repoRoot "skills\steadyagent-workflow") -DestinationRoot (Join-Path $codexFull "skills\steadyagent-workflow")
Add-PlanTree -Plan $plan -SourceRoot (Join-Path $repoRoot "tools\hooks") -DestinationRoot (Join-Path $targetFull "tools\hooks")
foreach ($toolName in @(
    "diagnose-install.ps1",
    "git-checkpoint.ps1",
    "git-preflight.ps1",
    "protected-path-policy.ps1",
    "rollback.ps1",
    "test-agent-hooks.ps1"
)) {
    Add-PlanFile -Plan $plan -Source (Join-Path $repoRoot ("tools\" + $toolName)) -Destination (Join-Path $targetFull ("tools\" + $toolName))
}
Add-PlanTree -Plan $plan -SourceRoot (Join-Path $repoRoot "tools\git-hooks") -DestinationRoot (Join-Path $targetFull "tools\git-hooks")
foreach ($docName in @(
    "activation-guide.md",
    "activation-guide.zh-CN.md",
    "feature-map.md",
    "feature-map.zh-CN.md",
    "hook-runtime.md",
    "hook-runtime.zh-CN.md",
    "tools.md",
    "tools.zh-CN.md"
)) {
    Add-PlanFile -Plan $plan -Source (Join-Path $repoRoot ("docs\" + $docName)) -Destination (Join-Path $targetFull ("docs\" + $docName))
}
$legacyManifestPath = Join-Path $repoRoot "manifests\v1-codex-owned-files.txt"
foreach ($line in @([IO.File]::ReadAllLines($legacyManifestPath, [Text.Encoding]::UTF8))) {
    $relative = $line.Trim()
    if (-not $relative) { continue }
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])[.][.]([\\/]|$)') {
        throw ("Invalid V1 manifest path: " + $relative)
    }
    $destination = [IO.Path]::GetFullPath((Join-Path $codexFull $relative))
    if (-not $destination.StartsWith($codexFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw ("V1 manifest escaped CodexHome: " + $relative)
    }
    $removals.Add([pscustomobject]@{
        Action = "remove"
        Source = $null
        Destination = $destination
        Render = $false
        StagePath = $null
        DesiredHash = $null
    }) | Out-Null
}

$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ("steadyagent-v2-stage-" + [guid]::NewGuid().ToString("N"))
$mutex = $null
$lockTaken = $false
$written = 0
$createdDirectories = New-Object Collections.Generic.List[string]
$snapshots = New-Object Collections.Generic.List[object]
$receipt = $null
$gitHooksBefore = $null
$gitHooksChanged = $false

try {
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    for ($index = 0; $index -lt $plan.Count; $index++) {
        $item = $plan[$index]
        if (-not (Test-Path -LiteralPath $item.Source -PathType Leaf)) {
            throw ("Package asset missing: " + $item.Source)
        }
        Assert-NoReparsePath -Path $item.Source
        Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
        $stagePath = Join-Path $stageRoot (("{0:D4}.bin" -f $index))
        if ($item.Render) {
            $text = [IO.File]::ReadAllText($item.Source, [Text.Encoding]::UTF8)
            $renderedHome = $targetFull.Replace("\", "\\")
            $text = $text.Replace("%STEADYAGENT_HOME_JSON%", $renderedHome)
            $text = $text.Replace("%STEADYAGENT_HOME%", $targetFull)
            Write-Utf8NoBom -Path $stagePath -Text $text
        }
        else {
            [IO.File]::Copy($item.Source, $stagePath, $false)
        }
        Add-Member -InputObject $item -NotePropertyName StagePath -NotePropertyValue $stagePath
        Add-Member -InputObject $item -NotePropertyName DesiredHash -NotePropertyValue ((Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash)
        Add-Member -InputObject $item -NotePropertyName Action -NotePropertyValue "install"
    }
    foreach ($item in $removals) {
        Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
    }
    $operations = New-Object Collections.Generic.List[object]
    foreach ($item in $plan) { $operations.Add($item) | Out-Null }
    foreach ($item in $removals) { $operations.Add($item) | Out-Null }
    $operationDestinations = @{}
    foreach ($item in $operations) {
        $operationKey = $item.Destination.ToLowerInvariant()
        if ($operationDestinations.ContainsKey($operationKey)) {
            throw ("Duplicate install operation destination: " + $item.Destination)
        }
        $operationDestinations[$operationKey] = $true
    }
    $desiredGitHooksPath = Join-Path $targetFull "tools\git-hooks"
    $gitHooksBefore = Get-GitHooksPath

    if (-not $Apply) {
        $conflicts = @(Get-OperationConflicts -Operations $operations)
        if ($gitHooksBefore -and
            -not $gitHooksBefore.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
            $conflicts += ("Git core.hooksPath=" + $gitHooksBefore)
        }
        Write-Host "DRY-RUN SteadyAgent 2.0.0 migration"
        Write-Host ("Plan: {0} operations; {1} existing conflict(s); 0 writes." -f $operations.Count, $conflicts.Count)
        foreach ($item in $plan) { Write-Host ("WOULD INSTALL " + $item.Destination) }
        foreach ($item in $removals) {
            if (Test-Path -LiteralPath $item.Destination -PathType Leaf) {
                Write-Host ("WOULD REMOVE V1 " + $item.Destination)
            }
        }
        if ($conflicts.Count -gt 0) {
            Write-Host "Re-run with -Apply -ReplaceExistingWorkflow only after reviewing these replacements:"
            foreach ($conflict in $conflicts) { Write-Host ("CONFLICT " + $conflict) }
        }
        exit 0
    }

    $mutex = New-Object Threading.Mutex($false, "Local\SteadyAgentV2Migration")
    try { $lockTaken = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $lockTaken = $true }
    if (-not $lockTaken) { throw "Another SteadyAgent install or rollback transaction is active." }

    $gitHooksBefore = Get-GitHooksPath
    $conflicts = @(Get-OperationConflicts -Operations $operations)
    if ($gitHooksBefore -and
        -not $gitHooksBefore.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
        $conflicts += ("Git core.hooksPath=" + $gitHooksBefore)
    }
    if ($conflicts.Count -gt 0 -and -not $ReplaceExistingWorkflow) {
        Write-Host "[FAIL] Existing workflow differs. No files were written."
        foreach ($conflict in $conflicts) { Write-Host ("CONFLICT " + $conflict) }
        Write-Host "Review the dry-run, then use -ReplaceExistingWorkflow to authorize backup and replacement."
        exit 2
    }
    if (Test-Path -LiteralPath $backupFull) {
        throw ("BackupRoot already exists: " + $backupFull)
    }

    if ($InjectTargetMutationPath) {
        $mutationFull = [IO.Path]::GetFullPath($InjectTargetMutationPath)
        if (-not @($operations | Where-Object {
            $_.Destination.Equals($mutationFull, [StringComparison]::OrdinalIgnoreCase)
        }).Count) {
            throw "Injected mutation target is outside the operation set."
        }
        [IO.File]::WriteAllText($mutationFull, "injected-external-drift", (New-Object Text.UTF8Encoding($false)))
    }
    if ($InjectGitHooksMutationValue) {
        Set-GitHooksPath -Value $InjectGitHooksMutationValue
    }
    $preWriteConflicts = @(Get-OperationConflicts -Operations $operations)
    $preWriteGitHooks = Get-GitHooksPath
    $gitHooksChangedAfterPlan = (
        ($null -eq $gitHooksBefore -and $null -ne $preWriteGitHooks) -or
        ($null -ne $gitHooksBefore -and
         ($null -eq $preWriteGitHooks -or
          -not $gitHooksBefore.Equals($preWriteGitHooks, [StringComparison]::OrdinalIgnoreCase)))
    )
    if ($gitHooksChangedAfterPlan -and -not $ReplaceExistingWorkflow) {
        Write-Host "[FAIL] Git core.hooksPath changed after planning. No SteadyAgent files were written."
        exit 2
    }
    $gitHooksBefore = $preWriteGitHooks
    if ($preWriteConflicts.Count -gt 0 -and -not $ReplaceExistingWorkflow) {
        Write-Host "[FAIL] A target changed after planning. No SteadyAgent files were written."
        foreach ($conflict in $preWriteConflicts) { Write-Host ("CONFLICT " + $conflict) }
        exit 2
    }

    New-Item -ItemType Directory -Path $backupFull -Force | Out-Null
    Assert-NoReparsePath -Path $backupFull
    for ($index = 0; $index -lt $operations.Count; $index++) {
        $item = $operations[$index]
        $exists = Test-Path -LiteralPath $item.Destination -PathType Leaf
        $snapshotName = if ($exists) { "{0:D4}.original" -f $index } else { $null }
        $snapshotPath = if ($snapshotName) { Join-Path $backupFull $snapshotName } else { $null }
        $originalHash = $null
        if ($exists) {
            Assert-NoReparsePath -Path $item.Destination
            Assert-NoReparsePath -Path $snapshotPath -AllowMissingLeaf
            [IO.File]::Copy($item.Destination, $snapshotPath, $false)
            $originalHash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
        }
        $snapshots.Add([pscustomobject]@{
            Destination = $item.Destination
            Existed = $exists
            SnapshotName = $snapshotName
            SnapshotPath = $snapshotPath
            OriginalSHA256 = $originalHash
            Action = $item.Action
            InstalledSHA256 = $item.DesiredHash
        }) | Out-Null
    }

    $receipt = [ordered]@{
        schema_version = 2
        steadyagent_version = $version
        created_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = "applying"
        target_root = $targetFull
        codex_home = $codexFull
        managed_config = $managedFull
        git_config = $(if ($GitConfigPath) { [IO.Path]::GetFullPath($GitConfigPath) } else { "global" })
        git_hooks_path_before = $gitHooksBefore
        git_hooks_path_after = $desiredGitHooksPath
        created_directories = @()
        entries = @($snapshots | ForEach-Object {
            [ordered]@{
                action = $_.Action
                destination = $_.Destination
                existed = $_.Existed
                snapshot_name = $_.SnapshotName
                original_sha256 = $_.OriginalSHA256
                installed_sha256 = $_.InstalledSHA256
            }
        })
    }
    Write-Utf8NoBomAtomic -Path (Join-Path $backupFull "migration-receipt.json") -Text (($receipt | ConvertTo-Json -Depth 6) + "`n")

    foreach ($item in $operations) {
        $snapshot = $snapshots[$written]
        Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
        $currentExists = Test-Path -LiteralPath $item.Destination -PathType Leaf
        if ($currentExists -ne $snapshot.Existed -or
            ($currentExists -and
             (Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash -ne $snapshot.OriginalSHA256)) {
            throw ("Target changed immediately before write: " + $item.Destination)
        }
        if ($item.Action -eq "install") {
            $parent = Split-Path -Parent $item.Destination
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                $missing = New-Object Collections.Generic.List[string]
                $cursor = $parent
                while ($cursor -and -not (Test-Path -LiteralPath $cursor)) {
                    $missing.Add($cursor) | Out-Null
                    $next = Split-Path -Parent $cursor
                    if (-not $next -or $next -eq $cursor) { break }
                    $cursor = $next
                }
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                foreach ($directory in $missing) { $createdDirectories.Add($directory) | Out-Null }
            }
            Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
            Copy-Atomically -Source $item.StagePath -Destination $item.Destination
            $written++
            if ($InjectPostWriteFailureAt -gt 0 -and $written -eq $InjectPostWriteFailureAt) {
                throw "Injected post-write verification failure."
            }
            $actualHash = (Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash
            if ($actualHash -ne $item.DesiredHash) {
                throw ("Post-write verification failed: " + $item.Destination)
            }
        }
        elseif (Test-Path -LiteralPath $item.Destination -PathType Leaf) {
            Assert-NoReparsePath -Path $item.Destination
            Remove-Item -LiteralPath $item.Destination -Force
            $written++
        }
        else {
            $written++
        }
        if ($InjectFailureAfter -gt 0 -and $written -eq $InjectFailureAfter) {
            throw "Injected migration failure."
        }
    }
    $gitHooksImmediatelyBeforeSet = Get-GitHooksPath
    $gitHooksDriftedBeforeSet = (
        ($null -eq $gitHooksBefore -and $null -ne $gitHooksImmediatelyBeforeSet) -or
        ($null -ne $gitHooksBefore -and
         ($null -eq $gitHooksImmediatelyBeforeSet -or
          -not $gitHooksBefore.Equals($gitHooksImmediatelyBeforeSet, [StringComparison]::OrdinalIgnoreCase)))
    )
    if ($gitHooksDriftedBeforeSet) {
        throw "Git core.hooksPath changed immediately before activation."
    }
    if (-not $gitHooksBefore -or
        -not $gitHooksBefore.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
        Set-GitHooksPath -Value $desiredGitHooksPath
        $gitHooksChanged = $true
    }
    $verifiedInstalledGitHooks = Get-GitHooksPath
    if (-not $verifiedInstalledGitHooks -or
        -not $verifiedInstalledGitHooks.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Git core.hooksPath activation verification failed."
    }

    foreach ($item in $operations) {
        if ($item.Action -eq "install") {
            if (-not (Test-Path -LiteralPath $item.Destination -PathType Leaf) -or
                (Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash -ne $item.DesiredHash) {
                throw ("Final plan verification failed: " + $item.Destination)
            }
        }
        elseif (Test-Path -LiteralPath $item.Destination) {
            throw ("Final V1 removal verification failed: " + $item.Destination)
        }
    }
    $receipt.status = "applied"
    $receipt.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    $receipt.created_directories = @($createdDirectories | Sort-Object -Unique | Sort-Object { $_.Length } -Descending)
    Write-Utf8NoBomAtomic -Path (Join-Path $backupFull "migration-receipt.json") -Text (($receipt | ConvertTo-Json -Depth 6) + "`n")
    Write-Host ("[OK] SteadyAgent {0} installed and verified: {1} operations." -f $version, $operations.Count)
    Write-Host ("Backup and rollback receipt: " + (Join-Path $backupFull "migration-receipt.json"))
    Write-Host "Restart Codex Desktop, then run diagnose-install.ps1 -RequireHooksActive."
    exit 0
}
catch {
    $rollbackErrors = @()
    if ($gitHooksChanged) {
        try {
            $currentHooks = Get-GitHooksPath
            if (-not $currentHooks -or
                -not $currentHooks.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Git core.hooksPath changed after activation."
            }
            Set-GitHooksPath -Value $gitHooksBefore
        }
        catch { $rollbackErrors += "git core.hooksPath" }
    }
    if ($Apply -and $written -gt 0) {
        for ($index = 0; $index -lt $written; $index++) {
            $snapshot = $snapshots[$index]
            try {
                if ($snapshot.Action -eq "install") {
                    if (-not (Test-Path -LiteralPath $snapshot.Destination -PathType Leaf) -or
                        (Get-FileHash -LiteralPath $snapshot.Destination -Algorithm SHA256).Hash -ne $snapshot.InstalledSHA256) {
                        throw "Installed target changed before automatic rollback."
                    }
                }
                elseif (Test-Path -LiteralPath $snapshot.Destination) {
                    throw "Removed V1 target reappeared before automatic rollback."
                }
                if ($snapshot.Existed) {
                    Assert-NoReparsePath -Path $snapshot.Destination -AllowMissingLeaf
                    Copy-Atomically -Source $snapshot.SnapshotPath -Destination $snapshot.Destination
                }
                elseif (Test-Path -LiteralPath $snapshot.Destination) {
                    Assert-NoReparsePath -Path $snapshot.Destination
                    Remove-Item -LiteralPath $snapshot.Destination -Force
                }
            }
            catch { $rollbackErrors += $snapshot.Destination }
        }
        foreach ($directory in @($createdDirectories | Sort-Object -Unique | Sort-Object { $_.Length } -Descending)) {
            try {
                $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue)
                if ((Test-Path -LiteralPath $directory -PathType Container) -and
                    $children.Count -eq 0) {
                    Remove-Item -LiteralPath $directory -Force
                }
            }
            catch { }
        }
    }
    if ($receipt -and (Test-Path -LiteralPath $backupFull)) {
        $receipt.status = if ($rollbackErrors.Count -eq 0) { "rolled_back" } else { "rollback_incomplete" }
        $receipt.failure = $_.Exception.Message
        Write-Utf8NoBomAtomic -Path (Join-Path $backupFull "migration-receipt.json") -Text (($receipt | ConvertTo-Json -Depth 6) + "`n")
    }
    if ($rollbackErrors.Count -gt 0) {
        [Console]::Error.WriteLine("SteadyAgent migration failed and rollback was incomplete.")
        exit 3
    }
    [Console]::Error.WriteLine(("SteadyAgent migration blocked: " + $_.Exception.Message))
    exit 2
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lockTaken -and $mutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}

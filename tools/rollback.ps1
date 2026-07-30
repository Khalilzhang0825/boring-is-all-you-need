[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReceiptPath,
    [string]$GitConfigPath,
    [switch]$Apply,
    [string]$InjectTargetMutationPath,
    [string]$InjectSnapshotMutationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
trap {
    [Console]::Error.WriteLine(("Rollback blocked: " + $_.Exception.Message))
    exit 2
}

if (($InjectTargetMutationPath -or $InjectSnapshotMutationPath) -and $env:STEADYAGENT_TEST_MODE -ne "1") {
    throw "Test-only rollback injection parameters require STEADYAGENT_TEST_MODE=1."
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
    param([string]$Source, [string]$Destination, [string]$ExpectedSHA256)
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temp = Join-Path $parent (".steadyagent-v2-rollback-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::Copy($Source, $temp, $false)
        if ($ExpectedSHA256 -and
            (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ne $ExpectedSHA256) {
            throw ("Atomic copy source hash changed: " + $Source)
        }
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-GitHooksPath {
    param([AllowNull()][string]$ConfigPath)
    if ($ConfigPath) { Assert-NoReparsePath -Path $ConfigPath -AllowMissingLeaf }
    if ($ConfigPath) {
        $value = & git config --file $ConfigPath --get core.hooksPath
    }
    else {
        $value = & git config --global --get core.hooksPath
    }
    if ($LASTEXITCODE -eq 0) { return [string]$value }
    return $null
}

function Set-GitHooksPath {
    param([AllowNull()][string]$ConfigPath, [AllowNull()][string]$Value)
    if ($ConfigPath) { Assert-NoReparsePath -Path $ConfigPath -AllowMissingLeaf }
    if ($ConfigPath) {
        $parent = Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if ([string]::IsNullOrEmpty($Value)) {
            & git config --file $ConfigPath --unset core.hooksPath
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 5) { throw "Could not restore fixture Git hooks path." }
        }
        else {
            & git config --file $ConfigPath core.hooksPath $Value
            if ($LASTEXITCODE -ne 0) { throw "Could not restore fixture Git hooks path." }
        }
    }
    else {
        if ([string]::IsNullOrEmpty($Value)) {
            & git config --global --unset core.hooksPath
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 5) { throw "Could not restore global Git hooks path." }
        }
        else {
            & git config --global core.hooksPath $Value
            if ($LASTEXITCODE -ne 0) { throw "Could not restore global Git hooks path." }
        }
    }
}

$receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
Assert-NoReparsePath -Path $receiptFull
if (-not (Test-Path -LiteralPath $receiptFull -PathType Leaf)) {
    throw ("Receipt not found: " + $receiptFull)
}
$backupRoot = Split-Path -Parent $receiptFull
$receipt = [IO.File]::ReadAllText($receiptFull, [Text.Encoding]::UTF8) | ConvertFrom-Json
if ([int]$receipt.schema_version -ne 2 -or [string]$receipt.steadyagent_version -ne "2.0.0") {
    throw "Unsupported migration receipt."
}
if ([string]$receipt.status -ne "applied") {
    throw ("Receipt is not eligible for rollback: status=" + [string]$receipt.status)
}
$entries = @($receipt.entries)
if ($entries.Count -eq 0) { throw "Receipt contains no file entries." }

$receiptGitConfig = [string]$receipt.git_config
$effectiveGitConfig = $null
if ($receiptGitConfig -ne "global") {
    $effectiveGitConfig = [IO.Path]::GetFullPath($receiptGitConfig)
    Assert-NoReparsePath -Path $effectiveGitConfig -AllowMissingLeaf
}
if ($GitConfigPath) {
    $requestedGitConfig = [IO.Path]::GetFullPath($GitConfigPath)
    if (-not $effectiveGitConfig -or
        -not $requestedGitConfig.Equals($effectiveGitConfig, [StringComparison]::OrdinalIgnoreCase)) {
        throw "GitConfigPath does not match the receipt."
    }
    $effectiveGitConfig = $requestedGitConfig
}

$seen = @{}
$validated = New-Object Collections.Generic.List[object]
$receiptTargetRoot = [IO.Path]::GetFullPath([string]$receipt.target_root)
$receiptCodexHome = [IO.Path]::GetFullPath([string]$receipt.codex_home)
$receiptManagedConfig = [IO.Path]::GetFullPath([string]$receipt.managed_config)
foreach ($entry in $entries) {
    $action = if ($entry.PSObject.Properties.Name -contains "action") { [string]$entry.action } else { "install" }
    if ($action -notin @("install", "remove")) { throw ("Invalid receipt action: " + $action) }
    $destination = [IO.Path]::GetFullPath([string]$entry.destination)
    $inTargetRoot = $destination.StartsWith($receiptTargetRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    $inCodexHome = $destination.StartsWith($receiptCodexHome.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    $isManagedConfig = $destination.Equals($receiptManagedConfig, [StringComparison]::OrdinalIgnoreCase)
    if (-not ($inTargetRoot -or $inCodexHome -or $isManagedConfig)) {
        throw ("Receipt destination escaped declared roots: " + $destination)
    }
    $key = $destination.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { throw ("Duplicate receipt destination: " + $destination) }
    $seen[$key] = $true
    Assert-NoReparsePath -Path $destination
    $installedHash = [string]$entry.installed_sha256
    if ($action -eq "install") {
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw ("Installed file is missing; rollback made zero writes: " + $destination)
        }
        if ($installedHash -notmatch '^[0-9A-Fa-f]{64}$' -or
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $installedHash) {
            throw ("Installed file drifted; rollback made zero writes: " + $destination)
        }
    }
    elseif (Test-Path -LiteralPath $destination) {
        throw ("Removed V1 file reappeared; rollback made zero writes: " + $destination)
    }

    $snapshotPath = $null
    if ([bool]$entry.existed) {
        $snapshotName = [string]$entry.snapshot_name
        if ($snapshotName -notmatch '^[0-9]{4}[.]original$') {
            throw ("Invalid snapshot name for: " + $destination)
        }
        $snapshotPath = Join-Path $backupRoot $snapshotName
        Assert-NoReparsePath -Path $snapshotPath
        if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
            throw ("Snapshot is missing: " + $snapshotPath)
        }
        $originalHash = [string]$entry.original_sha256
        if ($originalHash -notmatch '^[0-9A-Fa-f]{64}$' -or
            (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash -ne $originalHash) {
            throw ("Snapshot verification failed: " + $snapshotPath)
        }
    }
    $validated.Add([pscustomobject]@{
        Action = $action
        Destination = $destination
        Existed = [bool]$entry.existed
        SnapshotPath = $snapshotPath
        OriginalSHA256 = [string]$entry.original_sha256
        InstalledSHA256 = $installedHash
    }) | Out-Null
}

$gitHooksAfter = [string]$receipt.git_hooks_path_after
$gitHooksBefore = if ($null -eq $receipt.git_hooks_path_before) { $null } else { [string]$receipt.git_hooks_path_before }
$currentGitHooks = Get-GitHooksPath -ConfigPath $effectiveGitConfig
if (-not $currentGitHooks -or
    -not $currentGitHooks.Equals($gitHooksAfter, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Git core.hooksPath drifted; rollback made zero writes."
}

$validatedCreatedDirectories = @()
if ($receipt.PSObject.Properties.Name -contains "created_directories") {
    $safeRoots = @(
        [IO.Path]::GetFullPath([string]$receipt.target_root),
        [IO.Path]::GetFullPath([string]$receipt.codex_home),
        [IO.Path]::GetFullPath((Split-Path -Parent ([string]$receipt.managed_config)))
    )
    foreach ($candidate in @($receipt.created_directories)) {
        $directoryFull = [IO.Path]::GetFullPath([string]$candidate)
        $isSafe = $false
        foreach ($safeRoot in $safeRoots) {
            if ($directoryFull.Equals($safeRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $directoryFull.StartsWith($safeRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $isSafe = $true
                break
            }
        }
        if (-not $isSafe) { throw ("Created directory escaped rollback roots: " + $directoryFull) }
        Assert-NoReparsePath -Path $directoryFull -AllowMissingLeaf
        $validatedCreatedDirectories += $directoryFull
    }
}
$validatedCreatedDirectories = @($validatedCreatedDirectories | Sort-Object -Unique | Sort-Object { $_.Length } -Descending)

if (-not $Apply) {
    Write-Host ("DRY-RUN SteadyAgent 2.0.0 rollback: {0} files; 0 writes." -f $validated.Count)
    foreach ($item in $validated) {
        Write-Host ($(if ($item.Existed) { "WOULD RESTORE " } else { "WOULD REMOVE " }) + $item.Destination)
    }
    exit 0
}

$mutex = New-Object Threading.Mutex($false, "Local\SteadyAgentV2Migration")
$lockTaken = $false
$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ("steadyagent-v2-rollback-stage-" + [guid]::NewGuid().ToString("N"))
$restoredCount = 0
$gitChanged = $false
$injectionApplied = $false
$snapshotInjectionApplied = $false
$targetInjectionFull = if ($InjectTargetMutationPath) { [IO.Path]::GetFullPath($InjectTargetMutationPath) } else { $null }
$snapshotInjectionFull = if ($InjectSnapshotMutationPath) { [IO.Path]::GetFullPath($InjectSnapshotMutationPath) } else { $null }
if ($targetInjectionFull -and
    -not @($validated | Where-Object { $_.Destination.Equals($targetInjectionFull, [StringComparison]::OrdinalIgnoreCase) }).Count) {
    throw "Injected target mutation path is outside the receipt."
}
if ($snapshotInjectionFull -and
    -not @($validated | Where-Object {
        $_.SnapshotPath -and $_.SnapshotPath.Equals($snapshotInjectionFull, [StringComparison]::OrdinalIgnoreCase)
    }).Count) {
    throw "Injected snapshot mutation path is outside the receipt."
}
try {
    try { $lockTaken = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $lockTaken = $true }
    if (-not $lockTaken) { throw "Another SteadyAgent install or rollback transaction is active." }

    $lockedGitHooks = Get-GitHooksPath -ConfigPath $effectiveGitConfig
    if (-not $lockedGitHooks -or
        -not $lockedGitHooks.Equals($gitHooksAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Git core.hooksPath changed while acquiring the rollback lock."
    }
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    for ($index = 0; $index -lt $validated.Count; $index++) {
        $item = $validated[$index]
        Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
        if ($item.Action -eq "install") {
            if (-not (Test-Path -LiteralPath $item.Destination -PathType Leaf) -or
                (Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash -ne $item.InstalledSHA256) {
                throw ("Installed file changed while acquiring the rollback lock: " + $item.Destination)
            }
            $stagePath = Join-Path $stageRoot (("{0:D4}.installed" -f $index))
            [IO.File]::Copy($item.Destination, $stagePath, $false)
            if ((Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash -ne $item.InstalledSHA256) {
                throw ("Installed file changed while staging rollback: " + $item.Destination)
            }
        }
        else {
            if (Test-Path -LiteralPath $item.Destination) {
                throw ("Removed V1 file reappeared while acquiring the rollback lock: " + $item.Destination)
            }
            $stagePath = $null
        }
        $originalStagePath = $null
        if ($item.Existed) {
            Assert-NoReparsePath -Path $item.SnapshotPath
            if (-not $snapshotInjectionApplied -and $snapshotInjectionFull -and
                $snapshotInjectionFull.Equals($item.SnapshotPath, [StringComparison]::OrdinalIgnoreCase)) {
                [IO.File]::WriteAllText($item.SnapshotPath, "injected-snapshot-drift", (New-Object Text.UTF8Encoding($false)))
                $snapshotInjectionApplied = $true
            }
            $originalStagePath = Join-Path $stageRoot (("{0:D4}.original" -f $index))
            [IO.File]::Copy($item.SnapshotPath, $originalStagePath, $false)
            if ((Get-FileHash -LiteralPath $originalStagePath -Algorithm SHA256).Hash -ne $item.OriginalSHA256) {
                throw ("Snapshot changed while staging rollback: " + $item.SnapshotPath)
            }
        }
        Add-Member -InputObject $validated[$index] -NotePropertyName InstalledStagePath -NotePropertyValue $stagePath
        Add-Member -InputObject $validated[$index] -NotePropertyName OriginalStagePath -NotePropertyValue $originalStagePath
    }

    foreach ($item in $validated) {
        if (-not $injectionApplied -and $targetInjectionFull -and
            $targetInjectionFull.Equals($item.Destination, [StringComparison]::OrdinalIgnoreCase)) {
            [IO.File]::WriteAllText($item.Destination, "injected-rollback-drift", (New-Object Text.UTF8Encoding($false)))
            $injectionApplied = $true
        }
        Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
        if ($item.Action -eq "install") {
            if (-not (Test-Path -LiteralPath $item.Destination -PathType Leaf) -or
                (Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash -ne $item.InstalledSHA256) {
                throw ("Installed file changed immediately before restoration: " + $item.Destination)
            }
        }
        elseif (Test-Path -LiteralPath $item.Destination) {
            throw ("Removed V1 file reappeared immediately before restoration: " + $item.Destination)
        }
        if ($item.Existed) {
            Copy-Atomically `
                -Source $item.OriginalStagePath `
                -Destination $item.Destination `
                -ExpectedSHA256 $item.OriginalSHA256
        }
        elseif (Test-Path -LiteralPath $item.Destination) {
            Remove-Item -LiteralPath $item.Destination -Force
        }
        $restoredCount++
    }

    $gitHooksImmediatelyBeforeRestore = Get-GitHooksPath -ConfigPath $effectiveGitConfig
    if (-not $gitHooksImmediatelyBeforeRestore -or
        -not $gitHooksImmediatelyBeforeRestore.Equals($gitHooksAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Git core.hooksPath changed immediately before restoration."
    }
    Set-GitHooksPath -ConfigPath $effectiveGitConfig -Value $gitHooksBefore
    $gitChanged = $true
    foreach ($item in $validated) {
        if ($item.Existed) {
            if (-not (Test-Path -LiteralPath $item.Destination -PathType Leaf) -or
                (Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash -ne $item.OriginalSHA256) {
                throw ("Restored file verification failed: " + $item.Destination)
            }
        }
        elseif (Test-Path -LiteralPath $item.Destination) {
            throw ("Created file was not removed: " + $item.Destination)
        }
    }
    $verifiedGitHooks = Get-GitHooksPath -ConfigPath $effectiveGitConfig
    if (($null -eq $gitHooksBefore -and $null -ne $verifiedGitHooks) -or
        ($null -ne $gitHooksBefore -and
         (-not $verifiedGitHooks -or -not $verifiedGitHooks.Equals($gitHooksBefore, [StringComparison]::OrdinalIgnoreCase)))) {
        throw "Git core.hooksPath restoration verification failed."
    }

    $receipt.status = "restored"
    Add-Member -InputObject $receipt -NotePropertyName restored_utc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o"))
    Write-Utf8NoBomAtomic -Path $receiptFull -Text (($receipt | ConvertTo-Json -Depth 6) + "`n")

    foreach ($directory in $validatedCreatedDirectories) {
        try {
            if ((Test-Path -LiteralPath $directory -PathType Container) -and
                @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
                Remove-Item -LiteralPath $directory -Force
            }
        }
        catch { }
    }
    Write-Host ("[OK] SteadyAgent 2.0.0 rollback restored {0} files and Git core.hooksPath." -f $validated.Count)
    exit 0
}
catch {
    $reapplyErrors = @()
    if ($gitChanged) {
        try {
            $currentHooks = Get-GitHooksPath -ConfigPath $effectiveGitConfig
            $hooksStillRestored = (
                ($null -eq $gitHooksBefore -and $null -eq $currentHooks) -or
                ($null -ne $gitHooksBefore -and $null -ne $currentHooks -and
                 $currentHooks.Equals($gitHooksBefore, [StringComparison]::OrdinalIgnoreCase))
            )
            if (-not $hooksStillRestored) { throw "Git core.hooksPath changed after restoration." }
            Set-GitHooksPath -ConfigPath $effectiveGitConfig -Value $gitHooksAfter
        }
        catch { $reapplyErrors += "git core.hooksPath" }
    }
    for ($index = 0; $index -lt $restoredCount; $index++) {
        $item = $validated[$index]
        try {
            if ($item.Existed) {
                if (-not (Test-Path -LiteralPath $item.Destination -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash -ne $item.OriginalSHA256) {
                    throw "Restored target changed before reapplying the installed state."
                }
            }
            elseif (Test-Path -LiteralPath $item.Destination) {
                throw "Restored target reappeared before reapplying the installed state."
            }
            if ($item.Action -eq "install") {
                Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
                Copy-Atomically `
                    -Source $item.InstalledStagePath `
                    -Destination $item.Destination `
                    -ExpectedSHA256 $item.InstalledSHA256
            }
            elseif (Test-Path -LiteralPath $item.Destination) {
                Assert-NoReparsePath -Path $item.Destination
                Remove-Item -LiteralPath $item.Destination -Force
            }
        }
        catch { $reapplyErrors += $item.Destination }
    }
    if ($reapplyErrors.Count -gt 0) {
        [Console]::Error.WriteLine("Rollback failed and reapplying the installed state was incomplete.")
        exit 3
    }
    [Console]::Error.WriteLine(("Rollback blocked: " + $_.Exception.Message))
    exit 2
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lockTaken) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

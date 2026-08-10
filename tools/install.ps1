#requires -Version 7.5
[CmdletBinding()]
param(
    [string]$TargetRoot = (Join-Path $HOME ".steadyagent"),
    [string]$CodexHome = (Join-Path $HOME ".codex"),
    [string]$ManagedConfigPath,
    [string]$BackupRoot,
    [string]$GitConfigPath,
    [switch]$Apply,
    [switch]$ReplaceExistingWorkflow,
    [switch]$TestAsElevated,
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
    [string]$InjectTargetMutationPath,
    [string]$InjectGitHooksMutationValue,
    [string]$InjectTrustedUpgradePostValidationMutationPath,
    [switch]$InjectTrustedUpgradePointerCasMutation,
    [switch]$InjectTrustedUpgradeCleanupFailure,
    [int]$InjectJunctionSwapAt = 0,
    [string]$InjectJunctionParkedRoot,
    [string]$InjectJunctionEscapeRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$expectedMigrationRuntimeSha256 = "1B560A50AF7DECF76789C29F8BEC567877760BBDC179282C3CF9DBC86E44A950"
$migrationRuntimePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "migration-runtime.ps1"))
if (-not [IO.File]::Exists($migrationRuntimePath)) {
    throw "Migration runtime is missing; no migration writes were made."
}
$migrationRuntimeCursor = $migrationRuntimePath
while ($migrationRuntimeCursor) {
    if ([IO.File]::Exists($migrationRuntimeCursor) -or [IO.Directory]::Exists($migrationRuntimeCursor)) {
        $migrationRuntimeAttributes = [IO.File]::GetAttributes($migrationRuntimeCursor)
        if (($migrationRuntimeAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Migration runtime path is a reparse point; no migration writes were made."
        }
    }
    $migrationRuntimeParent = [IO.Path]::GetDirectoryName($migrationRuntimeCursor)
    if ([string]::IsNullOrEmpty($migrationRuntimeParent) -or
        $migrationRuntimeParent -eq $migrationRuntimeCursor) {
        break
    }
    $migrationRuntimeCursor = $migrationRuntimeParent
}
$migrationRuntimeBytes = [IO.File]::ReadAllBytes($migrationRuntimePath)
$migrationRuntimeSha = [Security.Cryptography.SHA256]::Create()
try {
    $actualMigrationRuntimeSha256 = (
        [BitConverter]::ToString($migrationRuntimeSha.ComputeHash($migrationRuntimeBytes))
    ).Replace("-", "")
}
finally {
    $migrationRuntimeSha.Dispose()
}
if ($actualMigrationRuntimeSha256 -cne $expectedMigrationRuntimeSha256) {
    throw "Migration runtime integrity verification failed; no migration writes were made."
}
if (([IO.File]::GetAttributes($migrationRuntimePath) -band
    [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Migration runtime path is a reparse point; no migration writes were made."
}
try {
    $migrationRuntimeEncoding = New-Object Text.UTF8Encoding($false, $true)
    $migrationRuntimeText = $migrationRuntimeEncoding.GetString($migrationRuntimeBytes)
}
catch {
    throw "Migration runtime is not strict UTF-8; no migration writes were made."
}
$migrationRuntimeBlock = [scriptblock]::Create($migrationRuntimeText)
. $migrationRuntimeBlock
foreach ($migrationRuntimeCommand in @(
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
)) {
    if (-not (Get-Command $migrationRuntimeCommand -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "Migration runtime did not load its frozen primitive set; no migration writes were made."
    }
}
$version = "3.0.0"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$packageManifestPath = Join-Path $repoRoot "package-assets.sha256"
$expectedPackageManifestSha256 = "FB94A32F1EA920E91760913041F7F5E4E18B6F746AA368AD6DE76DF3068B4E79"
$expectedPackageAssetCount = 52
$programDataRoot = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData
)
if ([string]::IsNullOrWhiteSpace($programDataRoot)) { $programDataRoot = "C:\ProgramData" }
$defaultTargetRoot = Join-Path $HOME ".steadyagent"
$defaultCodexHome = Join-Path $HOME ".codex"
$defaultManagedConfigPath = Join-Path $programDataRoot "OpenAI\Codex\requirements.toml"
$defaultBackupParent = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($defaultTargetRoot))) ".steadyagent-backups"

if (-not $ManagedConfigPath) {
    $ManagedConfigPath = $defaultManagedConfigPath
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






function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}



function ConvertFrom-StrictUtf8Bytes {
    param([byte[]]$Bytes, [string]$Label)
    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        throw ($Label + " must not contain a UTF-8 BOM.")
    }
    try {
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        return $encoding.GetString($Bytes)
    }
    catch {
        throw ($Label + " is not strict UTF-8.")
    }
}

function Get-PackageSourceKey {
    param([string]$Root, [string]$Source)
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $sourceFull = [IO.Path]::GetFullPath($Source)
    if (-not $sourceFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("Package source escaped the package root: " + $Source)
    }
    return $sourceFull.Substring($rootPrefix.Length).Replace('\', '/')
}

function Read-TrustedPackageSnapshot {
    param(
        [string]$Root,
        [object[]]$Plan,
        [string]$ManifestPath,
        [string]$ExpectedManifestSHA256,
        [int]$ExpectedAssetCount
    )
    Assert-NoReparsePath -Path $ManifestPath
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Package asset manifest is missing."
    }
    $manifestBytes = [IO.File]::ReadAllBytes($ManifestPath)
    if ($ExpectedManifestSHA256 -notmatch '^[0-9A-F]{64}$' -or
        (Get-Sha256Bytes -Bytes $manifestBytes) -cne $ExpectedManifestSHA256) {
        throw "Package asset manifest does not match the installer trust anchor."
    }
    $manifestText = ConvertFrom-StrictUtf8Bytes `
        -Bytes $manifestBytes `
        -Label "Package asset manifest"
    if ($manifestText.Contains("`r") -or -not $manifestText.EndsWith("`n") -or
        $manifestText.EndsWith("`n`n")) {
        throw "Package asset manifest must use canonical LF line endings."
    }
    $lines = @($manifestText.Substring(0, $manifestText.Length - 1).Split("`n"))
    if ($lines.Count -ne $ExpectedAssetCount) {
        throw (
            "Package asset manifest count mismatch. expected={0} actual={1}" -f
            $ExpectedAssetCount,
            $lines.Count
        )
    }
    $manifestHashes = @{}
    $manifestCaseKeys = @{}
    $manifestPaths = New-Object Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -notmatch '^(?<hash>[0-9A-F]{64})  (?<path>[A-Za-z0-9._/-]+)$') {
            throw "Package asset manifest line is invalid."
        }
        $relative = [string]$Matches.path
        if ($relative.Contains("\") -or [IO.Path]::IsPathRooted($relative) -or
            $relative -match '(^|/)[.][.]?(/|$)') {
            throw "Package asset manifest path is invalid."
        }
        $caseKey = $relative.ToLowerInvariant()
        if ($manifestCaseKeys.ContainsKey($caseKey)) {
            throw ("Package asset manifest contains a duplicate path: " + $relative)
        }
        $manifestCaseKeys[$caseKey] = $relative
        $manifestHashes[$caseKey] = [string]$Matches.hash
        $manifestPaths.Add($relative) | Out-Null
    }
    $sortedManifestPaths = [string[]]@($manifestPaths)
    [Array]::Sort($sortedManifestPaths, [StringComparer]::Ordinal)
    if (($manifestPaths -join "`n") -cne ($sortedManifestPaths -join "`n")) {
        throw "Package asset manifest is not ordinally sorted by path."
    }
    $planKeys = @{}
    foreach ($item in $Plan) {
        $relative = Get-PackageSourceKey -Root $Root -Source ([string]$item.Source)
        $caseKey = $relative.ToLowerInvariant()
        if ($planKeys.ContainsKey($caseKey) -and
            [string]$planKeys[$caseKey] -cne $relative) {
            throw "Package plan contains a case-colliding source path."
        }
        $planKeys[$caseKey] = $relative
    }
    if ($planKeys.Count -ne $ExpectedAssetCount -or
        $planKeys.Count -ne $manifestHashes.Count) {
        throw "Package asset manifest does not close over the install source set."
    }
    foreach ($caseKey in $planKeys.Keys) {
        if (-not $manifestHashes.ContainsKey($caseKey)) {
            throw ("Package asset manifest is missing plan source: " + $planKeys[$caseKey])
        }
    }
    foreach ($caseKey in $manifestHashes.Keys) {
        if (-not $planKeys.ContainsKey($caseKey)) {
            throw ("Package asset manifest contains an unexplained source: " + $manifestCaseKeys[$caseKey])
        }
    }
    $snapshot = @{}
    foreach ($caseKey in $planKeys.Keys) {
        $relative = [string]$planKeys[$caseKey]
        $sourcePath = Join-Path $Root $relative.Replace('/', '\')
        Assert-NoReparsePath -Path $sourcePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw ("Package asset missing: " + $relative)
        }
        $bytes = [IO.File]::ReadAllBytes($sourcePath)
        $sourceHash = Get-Sha256Bytes -Bytes $bytes
        if ($sourceHash -cne [string]$manifestHashes[$caseKey]) {
            throw ("Package asset hash mismatch: " + $relative)
        }
        $snapshot[$caseKey] = [pscustomobject]@{
            RelativePath = $relative
            Bytes = $bytes
            SourceSHA256 = $sourceHash
        }
    }
    return $snapshot
}






function Write-ActiveReceiptPointer {
    param(
        [string]$TargetRoot,
        [string]$ReceiptPath,
        [string]$ExpectedCurrentPointerSHA256
    )
    $receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
    $pointer = [pscustomobject][ordered]@{
        schema_version = 1
        target_root = [IO.Path]::GetFullPath($TargetRoot)
        receipts = @([pscustomobject][ordered]@{
            path = $receiptFull
            sha256 = (Get-FileHash -LiteralPath $receiptFull -Algorithm SHA256).Hash
        })
        pointer_integrity_sha256 = $null
    }
    $pointer.pointer_integrity_sha256 = Get-ActiveReceiptPointerIntegritySha256 -Pointer $pointer
    $pointerPath = Get-ActiveReceiptPointerPath -TargetRoot $TargetRoot
    $pointerBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
        (($pointer | ConvertTo-Json -Depth 6) + "`n")
    )
    if ($ExpectedCurrentPointerSHA256) {
        Invoke-SteadyAgentBoundAtomicWrite `
            -Destination $pointerPath `
            -Bytes $pointerBytes `
            -ExpectedCurrentSHA256 $ExpectedCurrentPointerSHA256
    }
    else {
        Write-Utf8NoBomAtomic `
            -Path $pointerPath `
            -Text ([Text.Encoding]::UTF8.GetString($pointerBytes))
    }
}

function Resolve-ActiveReceipt {
    param([string]$TargetRoot)
    $pointerPath = Get-ActiveReceiptPointerPath -TargetRoot $TargetRoot
    $pointerParent = Split-Path -Parent $pointerPath
    $pointerLeaf = Split-Path -Leaf $pointerPath
    $candidates = @(
        Get-ChildItem -LiteralPath $pointerParent -Filter ($pointerLeaf + "*") -File -Force -ErrorAction SilentlyContinue
    )
    if ($candidates.Count -ne 1 -or
        -not $candidates[0].FullName.Equals($pointerPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The active receipt pointer is missing or ambiguous."
    }
    Assert-NoReparsePath -Path $pointerPath
    $pointerBytes = [IO.File]::ReadAllBytes($pointerPath)
    $pointerFileSHA256 = Get-Sha256Bytes -Bytes $pointerBytes
    $pointer = [Text.Encoding]::UTF8.GetString($pointerBytes) | ConvertFrom-Json -DateKind String
    $expectedProperties = @("schema_version", "target_root", "receipts", "pointer_integrity_sha256")
    $actualProperties = @($pointer.PSObject.Properties.Name)
    if (@($expectedProperties | Where-Object { $actualProperties -notcontains $_ }).Count -gt 0 -or
        @($actualProperties | Where-Object { $expectedProperties -notcontains $_ }).Count -gt 0 -or
        [int]$pointer.schema_version -ne 1 -or
        -not ([IO.Path]::GetFullPath([string]$pointer.target_root)).Equals(
            [IO.Path]::GetFullPath($TargetRoot),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        @($pointer.receipts).Count -ne 1 -or
        [string]$pointer.pointer_integrity_sha256 -notmatch '^[0-9A-F]{64}$' -or
        [string]$pointer.pointer_integrity_sha256 -cne
            (Get-ActiveReceiptPointerIntegritySha256 -Pointer $pointer)) {
        throw "The active receipt pointer failed its unique integrity contract."
    }
    $receiptPath = [IO.Path]::GetFullPath([string]$pointer.receipts[0].path)
    Assert-NoReparsePath -Path $receiptPath
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw "The active migration receipt referenced by the pointer is missing."
    }
    $receiptBytes = [IO.File]::ReadAllBytes($receiptPath)
    $receiptSHA256 = Get-Sha256Bytes -Bytes $receiptBytes
    $activeReceipt = [Text.Encoding]::UTF8.GetString($receiptBytes) | ConvertFrom-Json -DateKind String
    if ([string]$activeReceipt.status -notin @(
            "applying", "applied", "rollback_incomplete", "rolled_back", "restored"
        ) -or
        -not ([IO.Path]::GetFullPath([string]$activeReceipt.target_root)).Equals(
            [IO.Path]::GetFullPath($TargetRoot),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        [string]$activeReceipt.receipt_integrity_sha256 -cne
            (Get-ReceiptIntegritySha256 -Receipt $activeReceipt)) {
        throw "The active migration receipt is not a unique integrity-valid receipt for this target."
    }
    return [pscustomobject]@{
        Path = $receiptPath
        Status = [string]$activeReceipt.status
        Receipt = $activeReceipt
        ReceiptSHA256 = $receiptSHA256
        PointerWasStale = [string]$pointer.receipts[0].sha256 -cne $receiptSHA256
        PointerSHA256 = $pointerFileSHA256
    }
}

function Get-ActiveRollbackJournalState {
    param([object]$ActiveReceipt)
    $receiptPath = [IO.Path]::GetFullPath([string]$ActiveReceipt.Path)
    $journalPath = Join-Path (Split-Path -Parent $receiptPath) "rollback-journal.json"
    $journalParent = Split-Path -Parent $journalPath
    $journalLeaf = Split-Path -Leaf $journalPath
    Assert-NoReparsePath -Path $journalParent
    $candidates = @(
        Get-ChildItem -LiteralPath $journalParent `
            -Filter ($journalLeaf + "*") -File -Force -ErrorAction SilentlyContinue
    )
    if ($candidates.Count -eq 0) {
        if ([string]$ActiveReceipt.Status -in @("restored", "rolled_back")) {
            throw "A finalized active receipt is missing its rollback journal."
        }
        return $null
    }
    if ($candidates.Count -ne 1 -or
        -not $candidates[0].FullName.Equals($journalPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The active rollback journal is missing or ambiguous."
    }
    Assert-NoReparsePath -Path $journalPath
    $journal = [IO.File]::ReadAllText($journalPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -DateKind String
    $expectedProperties = @(
        "schema_version", "transaction_kind", "transaction_id", "state",
        "created_utc", "updated_utc", "failure_code", "failure_message",
        "receipt", "rollback_tool", "git", "entries", "created_directories",
        "snapshot_set_sha256", "journal_integrity_sha256"
    )
    $actualProperties = @($journal.PSObject.Properties.Name)
    if (@($expectedProperties | Where-Object { $actualProperties -notcontains $_ }).Count -gt 0 -or
        @($actualProperties | Where-Object { $expectedProperties -notcontains $_ }).Count -gt 0 -or
        [int]$journal.schema_version -ne 1 -or
        [string]$journal.transaction_kind -cne "steadyagent-v2-rollback" -or
        [string]$journal.transaction_id -notmatch '^[0-9a-f]{32}$' -or
        [string]$journal.state -notin @(
            "rolling_back", "compensating", "compensated", "finalizing",
            "completed", "rollback_incomplete"
        )) {
        throw "The active rollback journal header is invalid."
    }
    $savedIntegrity = $journal.journal_integrity_sha256
    $journal.journal_integrity_sha256 = $null
    try {
        $calculatedIntegrity = Get-Sha256Text -Text (
            $journal | ConvertTo-Json -Depth 10 -Compress
        )
    }
    finally {
        $journal.journal_integrity_sha256 = $savedIntegrity
    }
    if ([string]$savedIntegrity -notmatch '^[0-9A-F]{64}$' -or
        [string]$savedIntegrity -cne $calculatedIntegrity -or
        -not ([IO.Path]::GetFullPath([string]$journal.receipt.path)).Equals(
            $receiptPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "The active rollback journal failed its receipt-bound integrity contract."
    }
    if ([string]$journal.state -eq "completed" -and
        ([string]$ActiveReceipt.Status -notin @("restored", "rolled_back") -or
         [string]$journal.receipt.success_status -cne [string]$ActiveReceipt.Status)) {
        throw "The completed rollback journal and active receipt do not agree."
    }
    return [string]$journal.state
}

function Resolve-ActiveAppliedReceipt {
    param([string]$TargetRoot)
    $active = Resolve-ActiveReceipt -TargetRoot $TargetRoot
    if ([string]$active.Status -cne "applied") {
        throw "The active migration receipt is not an applied receipt for this target."
    }
    return [string]$active.Path
}

function Write-NewTaskStrictAuditBlock {
    param([string]$TargetRoot, [string]$ReceiptPath)
    $quotedTargetRoot = "'" + $TargetRoot.Replace("'", "''") + "'"
    $quotedReceiptPath = "'" + $ReceiptPath.Replace("'", "''") + "'"
    Write-Host ("Backup and rollback receipt: " + $ReceiptPath)
    Write-Host "Restart Codex Desktop, open a new Codex task, and run this block in that task's terminal:"
    Write-Host ('$SteadyAgentRoot = ' + $quotedTargetRoot)
    Write-Host ('$ReceiptPath = ' + $quotedReceiptPath)
    Write-Host 'if ([string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { throw "Run this audit from a newly started Codex task." }'
    Write-Host 'pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\skill-index.ps1" -ThreadId $env:CODEX_THREAD_ID'
    Write-Host 'pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$SteadyAgentRoot\tools\diagnose-install.ps1" -ReceiptPath $ReceiptPath -RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity'
}


function Get-OperationProjection {
    param(
        [object[]]$Operations,
        [string]$TargetRoot,
        [string]$CodexHome,
        [string]$ManagedConfig
    )
    $targetPrefix = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\') + '\'
    $codexPrefix = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\') + '\'
    $managedFull = [IO.Path]::GetFullPath($ManagedConfig)
    $projection = @()
    foreach ($operation in $Operations) {
        $destination = [IO.Path]::GetFullPath([string]$operation.Destination)
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
            throw ("Install operation escaped the frozen path roles: " + $destination)
        }
        $projection += (([string]$operation.Action).ToLowerInvariant() + "|" + $role + "|" + $relative)
    }
    return @($projection)
}

# Intentionally local: install validates the production mutex ACL shape before migration writes.
function Assert-SteadyAgentMigrationMutexSecurity {
    param(
        [Threading.Mutex]$Mutex,
        [Security.Principal.SecurityIdentifier]$CurrentUser,
        [switch]$Elevated
    )
    $administrators = New-Object Security.Principal.SecurityIdentifier(
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
        $null
    )
    $localSystem = New-Object Security.Principal.SecurityIdentifier(
        [Security.Principal.WellKnownSidType]::LocalSystemSid,
        $null
    )
    $security = [Security.AccessControl.MutexSecurity]::new(
        "Global\SteadyAgentV2Migration",
        [Security.AccessControl.AccessControlSections]::Access -bor
            [Security.AccessControl.AccessControlSections]::Owner
    )
    $owner = $security.GetOwner([Security.Principal.SecurityIdentifier])
    if (-not $owner.Equals($CurrentUser) -and
        -not $owner.Equals($administrators) -and
        -not $owner.Equals($localSystem)) {
        throw "The machine-wide migration mutex has an untrusted owner."
    }
    if (-not $security.AreAccessRulesProtected) {
        throw "The machine-wide migration mutex DACL is not protected."
    }
    $rights = @{}
    foreach ($rule in @($security.GetAccessRules(
        $true,
        $false,
        [Security.Principal.SecurityIdentifier]
    ))) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            throw "The machine-wide migration mutex contains a deny rule."
        }
        $sid = [Security.Principal.SecurityIdentifier]$rule.IdentityReference
        $key = $sid.Value
        if ($sid.Equals($administrators) -or $sid.Equals($localSystem) -or
            (-not $Elevated -and $sid.Equals($CurrentUser))) {
            $existing = if ($rights.ContainsKey($key)) { [int]$rights[$key] } else { 0 }
            $rights[$key] = $existing -bor [int]$rule.MutexRights
        }
        else {
            throw "The machine-wide migration mutex grants an untrusted principal access."
        }
    }
    $fullControl = [int][Security.AccessControl.MutexRights]::FullControl
    foreach ($principal in @($administrators, $localSystem)) {
        if (-not $rights.ContainsKey($principal.Value) -or
            (([int]$rights[$principal.Value] -band $fullControl) -ne $fullControl)) {
            throw "The machine-wide migration mutex does not grant the protected principals full control."
        }
    }
    if (-not $Elevated) {
        $sharedRights = [int](
            [Security.AccessControl.MutexRights]::Synchronize -bor
            [Security.AccessControl.MutexRights]::Modify
        )
        if (-not $rights.ContainsKey($CurrentUser.Value) -or
            (([int]$rights[$CurrentUser.Value] -band $sharedRights) -ne $sharedRights)) {
            throw "The machine-wide migration mutex does not grant the current user transaction rights."
        }
    }
}

# Intentionally local: install constructs the production mutex ACL for the active token shape.
function New-SteadyAgentMigrationMutex {
    param([AllowNull()][string]$TestRoot)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "The machine-wide migration mutex is unavailable on this platform; no target writes were made."
    }
    try {
        if (-not [string]::IsNullOrWhiteSpace($TestRoot)) {
            $canonicalTestRoot = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\', '/').ToLowerInvariant()
            $testMutexName = "Local\SteadyAgentV2MigrationTest_" +
                (Get-Sha256Text -Text $canonicalTestRoot).ToLowerInvariant()
            return New-Object Threading.Mutex($false, $testMutexName)
        }
        $security = New-Object Security.AccessControl.MutexSecurity
        $security.SetAccessRuleProtection($true, $false)
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($null -eq $currentUser) {
            throw "The current Windows identity has no user SID."
        }
        $administrators = New-Object Security.Principal.SecurityIdentifier(
            [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
            $null
        )
        $localSystem = New-Object Security.Principal.SecurityIdentifier(
            [Security.Principal.WellKnownSidType]::LocalSystemSid,
            $null
        )
        $elevated = Test-IsProcessElevated
        if (-not $elevated) {
            $sharedRights = [Security.AccessControl.MutexRights]::Synchronize -bor
                [Security.AccessControl.MutexRights]::Modify
            $security.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule(
                $currentUser,
                $sharedRights,
                [Security.AccessControl.AccessControlType]::Allow
            )))
        }
        foreach ($principal in @($administrators, $localSystem)) {
            $security.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule(
                $principal,
                [Security.AccessControl.MutexRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow
            )))
        }
        $createdNew = $false
        $mutex = [Threading.MutexAcl]::Create(
            $false,
            "Global\SteadyAgentV2Migration",
            [ref]$createdNew,
            $security
        )
        Assert-SteadyAgentMigrationMutexSecurity `
            -Mutex $mutex `
            -CurrentUser $currentUser `
            -Elevated:$elevated
        return $mutex
    }
    catch {
        throw "The machine-wide migration mutex is unavailable; no target writes were made."
    }
}


function Copy-FileDurable {
    param([string]$Source, [string]$Destination)
    $bytes = [IO.File]::ReadAllBytes($Source)
    Invoke-SteadyAgentBoundAtomicWrite -Destination $Destination -Bytes $bytes -RequireMissing
    if ((Get-Sha256Bytes -Bytes ([IO.File]::ReadAllBytes($Destination))) -cne
        (Get-Sha256Bytes -Bytes $bytes)) {
        throw ("Durable snapshot readback verification failed: " + $Destination)
    }
}

function Write-BytesAtomic {
    param([string]$Path, [byte[]]$Bytes)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $existingHash = if (Test-Path -LiteralPath $Path -PathType Leaf) {
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    else { $null }
    Invoke-SteadyAgentBoundAtomicWrite `
        -Destination $Path `
        -Bytes $Bytes `
        -ExpectedCurrentSHA256 $existingHash `
        -RequireMissing:(!$existingHash)
}

# Intentionally local: install requires an existing parent and exposes hard-kill publication callbacks.
function Copy-Atomically {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$ExpectedSHA256,
        [string]$ExpectedDestinationSHA256,
        [switch]$RequireDestinationMissing,
        [Action]$AfterParentPin,
        [Action]$AfterOldRename,
        [Action]$AfterPublish
    )
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw ("Destination parent missing: " + $parent)
    }
    $bytes = [IO.File]::ReadAllBytes($Source)
    if ($ExpectedSHA256 -and (Get-Sha256Bytes -Bytes $bytes) -cne $ExpectedSHA256) {
        throw ("Atomic copy source hash changed: " + $Source)
    }
    Invoke-SteadyAgentBoundAtomicWrite `
        -Destination $Destination `
        -Bytes $bytes `
        -ExpectedCurrentSHA256 $ExpectedDestinationSHA256 `
        -RequireMissing:$RequireDestinationMissing `
        -AfterParentPin $AfterParentPin `
        -AfterOldRename $AfterOldRename `
        -AfterPublish $AfterPublish
}

function Resolve-GitConfigPath {
    if ($GitConfigPath) { return [IO.Path]::GetFullPath($GitConfigPath) }
    if (-not [string]::IsNullOrWhiteSpace($env:GIT_CONFIG_GLOBAL)) {
        return [IO.Path]::GetFullPath($env:GIT_CONFIG_GLOBAL)
    }
    return [IO.Path]::GetFullPath((Join-Path $HOME ".gitconfig"))
}

# Intentionally local: install reads the already-bound package-scoped Git config path.
function Get-GitHooksPath {
    Assert-NoReparsePath -Path $gitConfigFull -AllowMissingLeaf
    $value = & git config --file $gitConfigFull --get core.hooksPath
    if ($LASTEXITCODE -eq 0) { return [string]$value }
    return $null
}

function Get-GitConfigBytesWithHooksPath {
    param([byte[]]$CurrentBytes, [AllowNull()][string]$Value)
    $scratch = Join-Path $stageRoot ("git-config-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [byte[]]$initialBytes = if ($null -eq $CurrentBytes) {
            New-Object byte[] 0
        }
        else { $CurrentBytes }
        [IO.File]::WriteAllBytes($scratch, $initialBytes)
        if ([string]::IsNullOrEmpty($Value)) {
            & git config --file $scratch --unset-all core.hooksPath
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 5) {
                throw "Could not render a Git config without core.hooksPath."
            }
        }
        else {
            & git config --file $scratch --replace-all core.hooksPath $Value
            if ($LASTEXITCODE -ne 0) { throw "Could not render the desired Git hooks path." }
        }
        return [IO.File]::ReadAllBytes($scratch)
    }
    finally {
        if (Test-Path -LiteralPath $scratch) {
            Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue
        }
    }
}

# Intentionally local: install binds the destination and requires its parent to pre-exist.
function Set-GitConfigBytesCas {
    param(
        [byte[]]$Bytes,
        [string]$ExpectedCurrentSHA256,
        [switch]$RequireMissing
    )
    $parent = Split-Path -Parent $gitConfigFull
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw ("Git config parent is missing: " + $parent)
    }
    Invoke-SteadyAgentBoundAtomicWrite `
        -Destination $gitConfigFull `
        -Bytes $Bytes `
        -ExpectedCurrentSHA256 $ExpectedCurrentSHA256 `
        -RequireMissing:$RequireMissing
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

function Test-OperationsMatchDesiredState {
    param([object[]]$Operations)
    foreach ($item in $Operations) {
        if ($item.Action -eq "remove") {
            if (Test-Path -LiteralPath $item.Destination) { return $false }
            continue
        }
        if (-not (Test-Path -LiteralPath $item.Destination -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash -cne
            $item.DesiredHash) {
            return $false
        }
    }
    return $true
}

function Test-TrustedV202UpgradeState {
    param(
        [object]$ActiveReceipt,
        [AllowNull()][string]$CurrentGitHooksPath,
        [hashtable]$AllowedInstalledSHA256ByDestination = @{}
    )
    try {
    $candidate = $ActiveReceipt.Receipt
    $expectedReceiptProperties = @(
        'schema_version', 'steadyagent_version', 'created_utc', 'completed_utc',
        'restored_utc', 'failure', 'status', 'target_root', 'codex_home',
        'managed_config', 'git_config', 'git_config_existed_before',
        'git_config_before_sha256', 'git_config_after_sha256',
        'git_config_before_snapshot_name', 'git_config_before_snapshot_sha256',
        'git_config_after_snapshot_name', 'git_config_after_snapshot_sha256',
        'git_hooks_path_before', 'git_hooks_path_after',
        'git_hooks_path_before_snapshot_name', 'git_hooks_path_before_snapshot_sha256',
        'install_operation_count', 'remove_operation_count',
        'install_projection_sha256', 'removal_projection_sha256',
        'created_directories', 'entries', 'receipt_integrity_sha256'
    )
    $actualReceiptProperties = @($candidate.PSObject.Properties.Name)
    if ($actualReceiptProperties.Count -ne $expectedReceiptProperties.Count -or
        @($expectedReceiptProperties | Where-Object {
            $actualReceiptProperties -cnotcontains $_
        }).Count -gt 0) {
        return $false
    }
    if ([int]$candidate.schema_version -ne 2 -or
        [string]$candidate.steadyagent_version -cne '2.0.2' -or
        [string]$candidate.status -cne 'applied' -or
        -not [string]$candidate.completed_utc -or
        $null -ne $candidate.restored_utc -or
        $null -ne $candidate.failure -or
        [int]$candidate.install_operation_count -ne 53 -or
        [int]$candidate.remove_operation_count -ne 27 -or
        [string]$candidate.install_projection_sha256 -cne
            'D8FAAE46FF7C2E80E71C3ECC539DE1B9CE9097A0F8EFC2D1E82B25865A857356' -or
        [string]$candidate.removal_projection_sha256 -cne
            'F69BFE5A67AAE53337DE0C1E54D52CDDD1C841EF8528180B1F9F758F94A74582') {
        return $false
    }
    if (-not ([IO.Path]::GetFullPath([string]$candidate.target_root)).Equals(
            $targetFull,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not ([IO.Path]::GetFullPath([string]$candidate.codex_home)).Equals(
            $codexFull,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not ([IO.Path]::GetFullPath([string]$candidate.managed_config)).Equals(
            $managedFull,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not ([IO.Path]::GetFullPath([string]$candidate.git_config)).Equals(
            $gitConfigFull,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        return $false
    }
    $entries = @($candidate.entries)
    if ($entries.Count -ne 80) { return $false }
    $expectedEntryProperties = @(
        'action', 'destination', 'existed', 'snapshot_name',
        'original_sha256', 'installed_sha256'
    )
    $seenDestinations = @{}
    $installEntries = New-Object Collections.Generic.List[object]
    $removeEntries = New-Object Collections.Generic.List[object]
    $allowedProfileEntryCount = 0
    $allowedProfileMatchCount = 0
    foreach ($entry in $entries) {
        $actualEntryProperties = @($entry.PSObject.Properties.Name)
        if ($actualEntryProperties.Count -ne $expectedEntryProperties.Count -or
            @($expectedEntryProperties | Where-Object {
                $actualEntryProperties -cnotcontains $_
            }).Count -gt 0) {
            return $false
        }
        $destination = [IO.Path]::GetFullPath([string]$entry.destination)
        $destinationKey = $destination.ToUpperInvariant()
        if ($seenDestinations.ContainsKey($destinationKey)) { return $false }
        $seenDestinations[$destinationKey] = $true
        $inManagedSurface = (
            $destination.Equals($managedFull, [StringComparison]::OrdinalIgnoreCase) -or
            (Test-PathWithinRoot -Path $destination -Root $targetFull) -or
            (Test-PathWithinRoot -Path $destination -Root $codexFull)
        )
        if (-not $inManagedSurface) { return $false }
        if ([string]$entry.action -ceq 'install') {
            $installEntries.Add($entry) | Out-Null
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or
                [string]$entry.installed_sha256 -notmatch '^[0-9A-F]{64}$') {
                return $false
            }
            $actualInstalledSHA256 = (
                Get-FileHash -LiteralPath $destination -Algorithm SHA256
            ).Hash
            $allowedInstalledSHA256 = if (
                $AllowedInstalledSHA256ByDestination.ContainsKey($destinationKey)
            ) {
                [string]$AllowedInstalledSHA256ByDestination[$destinationKey]
            }
            else { $null }
            if ($null -ne $allowedInstalledSHA256) {
                $allowedProfileEntryCount++
                if ($allowedInstalledSHA256 -notmatch '^[0-9A-F]{64}$' -or
                    $allowedInstalledSHA256 -ceq [string]$entry.installed_sha256) {
                    return $false
                }
            }
            if ($actualInstalledSHA256 -cne [string]$entry.installed_sha256 -and
                ($allowedInstalledSHA256 -notmatch '^[0-9A-F]{64}$' -or
                 $actualInstalledSHA256 -cne $allowedInstalledSHA256)) {
                return $false
            }
            if ($null -ne $allowedInstalledSHA256 -and
                $actualInstalledSHA256 -ceq $allowedInstalledSHA256) {
                $allowedProfileMatchCount++
            }
        }
        elseif ([string]$entry.action -ceq 'remove') {
            $removeEntries.Add($entry) | Out-Null
            if (Test-Path -LiteralPath $destination) { return $false }
        }
        else { return $false }
    }
    if ($installEntries.Count -ne 53 -or $removeEntries.Count -ne 27) {
        return $false
    }
    if ($allowedProfileEntryCount -ne $AllowedInstalledSHA256ByDestination.Count -or
        ($allowedProfileMatchCount -ne 0 -and
         $allowedProfileMatchCount -ne $AllowedInstalledSHA256ByDestination.Count)) {
        return $false
    }
    $calculatedInstallProjection = Get-SortedProjectionSha256 -Projection @(
        Get-OperationProjection `
            -Operations $installEntries.ToArray() `
            -TargetRoot $targetFull `
            -CodexHome $codexFull `
            -ManagedConfig $managedFull
    )
    $calculatedRemovalProjection = Get-SortedProjectionSha256 -Projection @(
        Get-OperationProjection `
            -Operations $removeEntries.ToArray() `
            -TargetRoot $targetFull `
            -CodexHome $codexFull `
            -ManagedConfig $managedFull
    )
    if ($calculatedInstallProjection -cne
            'D8FAAE46FF7C2E80E71C3ECC539DE1B9CE9097A0F8EFC2D1E82B25865A857356' -or
        $calculatedRemovalProjection -cne
            'F69BFE5A67AAE53337DE0C1E54D52CDDD1C841EF8528180B1F9F758F94A74582') {
        return $false
    }
    if (-not (Test-Path -LiteralPath $gitConfigFull -PathType Leaf) -or
        [string]$candidate.git_config_after_sha256 -notmatch '^[0-9A-F]{64}$' -or
        (Get-FileHash -LiteralPath $gitConfigFull -Algorithm SHA256).Hash -cne
            [string]$candidate.git_config_after_sha256 -or
        $null -eq $CurrentGitHooksPath -or
        -not $CurrentGitHooksPath.Equals(
            [string]$candidate.git_hooks_path_after,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        return $false
    }
    return $true
    }
    catch { return $false }
}

$targetFull = [IO.Path]::GetFullPath($TargetRoot)
$codexFull = [IO.Path]::GetFullPath($CodexHome)
$managedFull = [IO.Path]::GetFullPath($ManagedConfigPath)
$defaultTargetFull = [IO.Path]::GetFullPath($defaultTargetRoot)
$defaultCodexFull = [IO.Path]::GetFullPath($defaultCodexHome)
$defaultManagedFull = [IO.Path]::GetFullPath($defaultManagedConfigPath)
$defaultBackupParentFull = [IO.Path]::GetFullPath($defaultBackupParent)
$backupFull = [IO.Path]::GetFullPath($BackupRoot)
$gitConfigFull = Resolve-GitConfigPath
$isTestMode = $env:STEADYAGENT_TEST_MODE -eq "1"
if ($isTestMode) {
    if ([string]::IsNullOrWhiteSpace($env:STEADYAGENT_TEST_ROOT)) {
        throw "STEADYAGENT_TEST_MODE requires STEADYAGENT_TEST_ROOT."
    }
    $testRootFull = [IO.Path]::GetFullPath($env:STEADYAGENT_TEST_ROOT)
    $systemTempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not (Test-PathWithinRoot -Path $testRootFull -Root $systemTempFull) -or
        -not (Test-Path -LiteralPath $testRootFull -PathType Container) -or
        (Split-Path -Leaf $testRootFull) -notmatch '^steadyagent-v2-migration-[0-9a-f]{32}$') {
        throw "STEADYAGENT_TEST_ROOT must be an existing fixture root under the system temp directory."
    }
    Assert-NoReparsePath -Path $testRootFull
    foreach ($testScopedPath in @(
        $repoRoot,
        $targetFull,
        $codexFull,
        $managedFull,
        $backupFull,
        $gitConfigFull,
        $InjectTargetMutationPath,
        $InjectTrustedUpgradePostValidationMutationPath,
        $InjectJunctionParkedRoot,
        $InjectJunctionEscapeRoot
    )) {
        if (-not $testScopedPath) { continue }
        if (-not (Test-PathWithinRoot -Path $testScopedPath -Root $testRootFull)) {
            throw ("Test-mode path escaped STEADYAGENT_TEST_ROOT: " + $testScopedPath)
        }
    }
    if (-not $gitConfigFull) {
        throw "Test mode requires an isolated GitConfigPath under STEADYAGENT_TEST_ROOT."
    }
}
if ($TestAsElevated -and -not $isTestMode) {
    throw "TestAsElevated is available only in the isolated migration test."
}
if (-not $isTestMode) {
    if (-not $targetFull.Equals($defaultTargetFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("Production installs require TargetRoot: " + $defaultTargetFull)
    }
    if (-not $codexFull.Equals($defaultCodexFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("Production installs require CodexHome: " + $defaultCodexFull)
    }
    if (-not $managedFull.Equals($defaultManagedFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw (
            "Production installs require the managed Codex configuration at: " +
            $defaultManagedFull
        )
    }
    $defaultBackupPrefix = $defaultBackupParentFull.TrimEnd('\') + '\'
    if ($backupFull.Equals($defaultBackupParentFull, [StringComparison]::OrdinalIgnoreCase) -or
        -not $backupFull.StartsWith($defaultBackupPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("Production installs require BackupRoot under: " + $defaultBackupParentFull)
    }
    if ($PSBoundParameters.ContainsKey("GitConfigPath")) {
        throw "Production installs do not allow GitConfigPath; the real global Git configuration is required."
    }
    $productionHomeFull = [IO.Path]::GetFullPath($HOME)
    if (-not $gitConfigFull.StartsWith(
        $productionHomeFull.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Production global Git configuration must stay inside the current user profile."
    }
}
foreach ($path in @(
    $repoRoot,
    $targetFull,
    $codexFull,
    $managedFull,
    $backupFull,
    $gitConfigFull
)) {
    if (-not $path) { continue }
    Assert-NoReparsePath -Path $path -AllowMissingLeaf
}

if (($InjectFailureAfter -gt 0 -or $InjectPostWriteFailureAt -gt 0 -or $InjectSnapshotMutationAt -gt 0 -or
     $InjectSnapshotCopyFailureAt -gt 0 -or
     $InjectHardKillAfterOperation -gt 0 -or $InjectHardKillAfterGitActivation -or
     $InjectAtomicHardKillPhase -or $InjectAtomicHardKillAt -gt 0 -or
     $InjectDirectoryHardKillPhase -or $InjectDirectoryHardKillAt -gt 0 -or
     $InjectHardKillAfterAppliedReceipt -or
     $InjectGitConfigCasMutationValue -or
     $InjectRemovalSubstitution -or $InjectMutexFailure -or $InjectAutomaticRollbackFailure -or
     $InjectTargetMutationPath -or $InjectGitHooksMutationValue -or
     $InjectTrustedUpgradePostValidationMutationPath -or
     $InjectTrustedUpgradePointerCasMutation -or $InjectTrustedUpgradeCleanupFailure -or
     $InjectJunctionSwapAt -gt 0 -or $InjectJunctionParkedRoot -or
     $InjectJunctionEscapeRoot) -and
    -not $isTestMode) {
    throw "Failure and mutation injection are available only in the isolated migration test."
}
if ($InjectHardKillAfterOperation -lt 0 -or $InjectHardKillAfterOperation -gt 80) {
    throw "InjectHardKillAfterOperation must be between 1 and 80."
}
if (($InjectAtomicHardKillAt -gt 0) -ne [bool]$InjectAtomicHardKillPhase -or
    $InjectAtomicHardKillAt -lt 0 -or $InjectAtomicHardKillAt -gt 80) {
    throw "Atomic hard-kill injection requires a phase and an operation index between 1 and 80."
}
if (($InjectDirectoryHardKillAt -gt 0) -ne [bool]$InjectDirectoryHardKillPhase -or
    $InjectDirectoryHardKillAt -lt 0 -or $InjectDirectoryHardKillAt -gt 80) {
    throw "Directory hard-kill injection requires a phase and a directory index between 1 and 80."
}
if ($InjectSnapshotCopyFailureAt -lt 0 -or $InjectSnapshotCopyFailureAt -gt 80) {
    throw "InjectSnapshotCopyFailureAt must be between 1 and 80."
}
if ($InjectJunctionSwapAt -lt 0 -or $InjectJunctionSwapAt -gt 80) {
    throw "InjectJunctionSwapAt must be between 1 and 80."
}
if (($InjectJunctionSwapAt -gt 0) -ne
    [bool]($InjectJunctionParkedRoot -and $InjectJunctionEscapeRoot)) {
    throw "Junction swap injection requires an operation index, parked root, and escape root."
}
if ($InjectHardKillAfterOperation -gt 0 -or $InjectHardKillAfterGitActivation -or
    $InjectHardKillAfterAppliedReceipt -or
    $InjectAtomicHardKillAt -gt 0 -or $InjectDirectoryHardKillAt -gt 0) {
    $tempFixtureRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $hardKillPaths = @($targetFull, $codexFull, $managedFull, $backupFull, $gitConfigFull)
    if (-not $gitConfigFull -or
        @($hardKillPaths | Where-Object {
            -not $_ -or -not (Test-PathWithinRoot -Path $_ -Root $tempFixtureRoot)
        }).Count -gt 0) {
        throw "Hard-kill injection requires every writable role and GitConfigPath under the system temp directory."
    }
}
$pathRoles = [ordered]@{
    PackageRoot = $repoRoot
    TargetRoot = $targetFull
    CodexHome = $codexFull
    ManagedConfigPath = $managedFull
    BackupRoot = $backupFull
}
if ($gitConfigFull) { $pathRoles.GitConfigPath = $gitConfigFull }
$roleNames = @($pathRoles.Keys)
for ($leftIndex = 0; $leftIndex -lt $roleNames.Count; $leftIndex++) {
    for ($rightIndex = $leftIndex + 1; $rightIndex -lt $roleNames.Count; $rightIndex++) {
        $leftRole = [string]$roleNames[$leftIndex]
        $rightRole = [string]$roleNames[$rightIndex]
        if (Test-PathTreeOverlap -First ([string]$pathRoles[$leftRole]) -Second ([string]$pathRoles[$rightRole])) {
            throw ("Install path roles must be disjoint: {0} overlaps {1}." -f $leftRole, $rightRole)
        }
    }
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
    "migration-runtime.ps1",
    "protected-path-policy.ps1",
    "rollback.ps1",
    "skill-catalog-resolver.ps1",
    "skill-index.ps1",
    "skill-search.ps1",
    "test-agent-hooks.ps1",
    "test-git-checkpoint.ps1",
    "test-pre-commit.ps1",
    "test-protected-path-policy.ps1",
    "test-skill-catalog.ps1"
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
$packageSnapshot = Read-TrustedPackageSnapshot `
    -Root $repoRoot `
    -Plan $plan.ToArray() `
    -ManifestPath $packageManifestPath `
    -ExpectedManifestSHA256 $expectedPackageManifestSha256 `
    -ExpectedAssetCount $expectedPackageAssetCount
$boundPolicyPath = Join-Path $repoRoot "tools\protected-path-policy.ps1"
$boundPolicyKey = (Get-PackageSourceKey -Root $repoRoot -Source $boundPolicyPath).ToLowerInvariant()
$boundPolicyText = ConvertFrom-StrictUtf8Bytes `
    -Bytes ([byte[]]$packageSnapshot[$boundPolicyKey].Bytes) `
    -Label "Bound path policy"
$boundPolicyBlock = [scriptblock]::Create($boundPolicyText)
. $boundPolicyBlock
if (-not ("SteadyAgent.BoundPath" -as [type]) -or
    -not (Get-Command Invoke-SteadyAgentBoundAtomicWrite -ErrorAction SilentlyContinue) -or
    -not (Get-Command Repair-SteadyAgentBoundMutation -ErrorAction SilentlyContinue)) {
    throw "The trusted bound path policy did not load its reviewed mutation primitives."
}
$legacyManifestPath = Join-Path $repoRoot "manifests\v1-codex-owned-files.txt"
$legacyManifestKey = (Get-PackageSourceKey -Root $repoRoot -Source $legacyManifestPath).ToLowerInvariant()
$legacyManifestText = ConvertFrom-StrictUtf8Bytes `
    -Bytes ([byte[]]$packageSnapshot[$legacyManifestKey].Bytes) `
    -Label "V1-owned file manifest"
$legacyRemovalRelativePaths = @(
    $legacyManifestText.Split([string[]]@("`r`n", "`n"), [StringSplitOptions]::None) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)
if ($InjectRemovalSubstitution) {
    $legacyRemovalRelativePaths[0] = "requirements.managed-hooks.substituted.toml"
}
$expectedLegacyRemovalProjectionSha256 = "16F51949FF3DF81A7E33E471E25432034A72AF2136EB3D138FEB6F710E61B58A"
$legacyRemovalProjectionSha256 = Get-Sha256Text -Text ($legacyRemovalRelativePaths -join "`n")
if ($legacyRemovalProjectionSha256 -cne $expectedLegacyRemovalProjectionSha256) {
    throw (
        "V1 removal manifest projection mismatch. expected={0} actual={1}" -f
        $expectedLegacyRemovalProjectionSha256,
        $legacyRemovalProjectionSha256
    )
}
foreach ($relative in $legacyRemovalRelativePaths) {
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
$createdDirectories = New-Object Collections.Generic.List[object]
$directoryPublicationCount = 0
$snapshots = New-Object Collections.Generic.List[object]
$receipt = $null
$gitHooksBefore = $null
$gitHooksChanged = $false
$gitConfigExistedBefore = $false
$gitConfigBytesBefore = $null
$gitConfigBeforeSHA256 = $null
$gitConfigBytesAfter = $null
$gitConfigAfterSHA256 = $null
$gitConfigCasConflict = $false
$snapshotCopies = 0
$trustedV202Upgrade = $false
$trustedUpgradePointerBytes = $null
$trustedUpgradePointerSHA256 = $null
$trustedUpgradeEntriesByDestination = @{}
$trustedUpgradePointerTakenOver = $false

try {
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    for ($index = 0; $index -lt $plan.Count; $index++) {
        $item = $plan[$index]
        Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
        $stagePath = Join-Path $stageRoot (("{0:D4}.bin" -f $index))
        $sourceKey = (Get-PackageSourceKey -Root $repoRoot -Source ([string]$item.Source)).ToLowerInvariant()
        $sourceBytes = [byte[]]$packageSnapshot[$sourceKey].Bytes
        if ($item.Render) {
            $text = ConvertFrom-StrictUtf8Bytes `
                -Bytes $sourceBytes `
                -Label ([string]$packageSnapshot[$sourceKey].RelativePath)
            $renderedHome = $targetFull.Replace("\", "\\")
            $text = $text.Replace("%STEADYAGENT_HOME_JSON%", $renderedHome)
            $text = $text.Replace("%STEADYAGENT_HOME%", $targetFull)
            $finalBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
        }
        else {
            $finalBytes = $sourceBytes
        }
        $desiredHash = Get-Sha256Bytes -Bytes $finalBytes
        [IO.File]::WriteAllBytes($stagePath, $finalBytes)
        if ((Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash -cne $desiredHash) {
            throw ("Package staging verification failed: " + [string]$packageSnapshot[$sourceKey].RelativePath)
        }
        Add-Member -InputObject $item -NotePropertyName StagePath -NotePropertyValue $stagePath
        Add-Member -InputObject $item -NotePropertyName DesiredHash -NotePropertyValue $desiredHash
        Add-Member -InputObject $item -NotePropertyName Action -NotePropertyValue "install"
    }
    foreach ($item in $removals) {
        Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
    }
    $operations = New-Object Collections.Generic.List[object]
    foreach ($item in $plan) { $operations.Add($item) | Out-Null }
    foreach ($item in $removals) { $operations.Add($item) | Out-Null }
    $trustedUpgradeAllowedPreimages = @{}
    $noCavemanAgentsDestination = [IO.Path]::GetFullPath(
        (Join-Path $codexFull 'AGENTS.md')
    )
    $noCavemanAgentsOperation = @($plan | Where-Object {
        $_.Destination.Equals(
            $noCavemanAgentsDestination,
            [StringComparison]::OrdinalIgnoreCase
        )
    })
    if ($noCavemanAgentsOperation.Count -ne 1) {
        throw 'The no-Caveman AGENTS migration preimage could not be bound to one plan item.'
    }
    $trustedUpgradeAllowedPreimages[
        $noCavemanAgentsDestination.ToUpperInvariant()
    ] = [string]$noCavemanAgentsOperation[0].DesiredHash
    $noCavemanContextDestination = [IO.Path]::GetFullPath(
        (Join-Path $targetFull 'tools\hooks\agent-hook-context.ps1')
    )
    $trustedUpgradeAllowedPreimages[
        $noCavemanContextDestination.ToUpperInvariant()
    ] = '20BF528341B1A5BF6A098BD8BB55975475BD663C109C6038AC6515FD6DC69091'
    $operationDestinations = @{}
    foreach ($item in $operations) {
        $operationKey = $item.Destination.ToLowerInvariant()
        if ($operationDestinations.ContainsKey($operationKey)) {
            throw ("Duplicate install operation destination: " + $item.Destination)
        }
        $operationDestinations[$operationKey] = $true
    }
    $installOperations = @($operations | Where-Object { $_.Action -eq "install" })
    $removeOperations = @($operations | Where-Object { $_.Action -eq "remove" })
    $installProjectionSha256 = Get-SortedProjectionSha256 -Projection @(
        Get-OperationProjection `
            -Operations $installOperations `
            -TargetRoot $targetFull `
            -CodexHome $codexFull `
            -ManagedConfig $managedFull
    )
    $removalProjectionSha256 = Get-SortedProjectionSha256 -Projection @(
        Get-OperationProjection `
            -Operations $removeOperations `
            -TargetRoot $targetFull `
            -CodexHome $codexFull `
            -ManagedConfig $managedFull
    )
    if ($installOperations.Count -ne 53 -or
        $installProjectionSha256 -cne "D8FAAE46FF7C2E80E71C3ECC539DE1B9CE9097A0F8EFC2D1E82B25865A857356") {
        throw (
            "V2 install operation contract mismatch. count={0} projection={1}" -f
            $installOperations.Count,
            $installProjectionSha256
        )
    }
    if ($removeOperations.Count -ne 27 -or
        $removalProjectionSha256 -cne "F69BFE5A67AAE53337DE0C1E54D52CDDD1C841EF8528180B1F9F758F94A74582") {
        throw (
            "V1 removal operation contract mismatch. count={0} projection={1}" -f
            $removeOperations.Count,
            $removalProjectionSha256
        )
    }
    $desiredGitHooksPath = Join-Path $targetFull "tools\git-hooks"
    $gitConfigExistedBefore = Test-Path -LiteralPath $gitConfigFull -PathType Leaf
    if ($gitConfigExistedBefore) {
        $gitConfigBytesBefore = [IO.File]::ReadAllBytes($gitConfigFull)
        $gitConfigBeforeSHA256 = Get-Sha256Bytes -Bytes $gitConfigBytesBefore
    }
    $gitHooksBefore = Get-GitHooksPath
    if ($gitHooksBefore -and
        $gitHooksBefore.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
        $gitConfigBytesAfter = $gitConfigBytesBefore
        $gitConfigAfterSHA256 = $gitConfigBeforeSHA256
    }
    else {
        $gitConfigBytesAfter = Get-GitConfigBytesWithHooksPath `
            -CurrentBytes $gitConfigBytesBefore `
            -Value $desiredGitHooksPath
        $gitConfigAfterSHA256 = Get-Sha256Bytes -Bytes $gitConfigBytesAfter
    }

    if (-not $Apply) {
        $conflicts = @(Get-OperationConflicts -Operations $operations)
        if ($gitHooksBefore -and
            -not $gitHooksBefore.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
            $conflicts += ("Git core.hooksPath=" + $gitHooksBefore)
        }
        Write-Host "DRY-RUN Boring Is All You Need v3.0.0 migration"
        Write-Host (
            (
                "Plan: {0} operations; {1} existing conflict(s); " +
                "0 target/config/backup/receipt/state writes. " +
                "Temporary staging was used for rendering and is removed on normal exit."
            ) -f $operations.Count, $conflicts.Count
        )
        $gitHooksBeforeDisplay = if ([string]::IsNullOrWhiteSpace($gitHooksBefore)) {
            "<unset>"
        }
        else { $gitHooksBefore }
        Write-Host (
            "WOULD SET Git core.hooksPath: {0} -> {1}" -f
            $gitHooksBeforeDisplay,
            $desiredGitHooksPath
        )
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

    if ($InjectMutexFailure) {
        throw "The machine-wide migration mutex is unavailable; no target writes were made."
    }
    $mutex = New-SteadyAgentMigrationMutex -TestRoot $(if ($isTestMode) { $testRootFull } else { $null })
    try { $lockTaken = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $lockTaken = $true }
    if (-not $lockTaken) { throw "Another Boring Is All You Need install or rollback transaction is active." }

    $activeReceipt = $null
    $activePointerPath = Get-ActiveReceiptPointerPath -TargetRoot $targetFull
    Repair-SteadyAgentBoundMutation -Path $activePointerPath | Out-Null
    $activePointerParent = Split-Path -Parent $activePointerPath
    $activePointerLeaf = Split-Path -Leaf $activePointerPath
    $activePointerCandidates = @(
        Get-ChildItem -LiteralPath $activePointerParent `
            -Filter ($activePointerLeaf + "*") -File -Force -ErrorAction SilentlyContinue
    )
    if ($activePointerCandidates.Count -gt 0) {
        $activeReceipt = Resolve-ActiveReceipt -TargetRoot $targetFull
        $activeRollbackJournalState = Get-ActiveRollbackJournalState -ActiveReceipt $activeReceipt
        if ($activeRollbackJournalState -and $activeRollbackJournalState -cne "completed") {
            [Console]::Error.WriteLine(
                "Boring Is All You Need install refused: the active rollback journal is not completed."
            )
            Write-Host ("Recovery receipt: " + [string]$activeReceipt.Path)
            Write-Host (
                "Run the verified rollback tool with this receipt before another install attempt."
            )
            Write-Host (
                "Do not blindly retry install or rollback; preserve and inspect the recovery evidence."
            )
            exit 3
        }
        if ([bool]$activeReceipt.PointerWasStale) {
            Write-ActiveReceiptPointer `
                -TargetRoot $targetFull `
                -ReceiptPath ([string]$activeReceipt.Path) `
                -ExpectedCurrentPointerSHA256 ([string]$activeReceipt.PointerSHA256)
            Write-Host "[RECOVERED] Rebound a stale active receipt pointer to the integrity-valid receipt."
        }
        if ([string]$activeReceipt.Status -in @("applying", "rollback_incomplete")) {
            [Console]::Error.WriteLine(
                "Boring Is All You Need install refused: an active applying receipt requires recovery."
            )
            Write-Host ("Recovery receipt: " + [string]$activeReceipt.Path)
            Write-Host (
                "Run the verified rollback tool with this receipt before another install attempt."
            )
            Write-Host (
                "Do not blindly retry install or rollback; preserve and inspect the recovery evidence."
            )
            exit 3
        }
    }

    $gitHooksBefore = Get-GitHooksPath
    $alreadyDesired = (
        (Test-OperationsMatchDesiredState -Operations $operations) -and
        $null -ne $gitHooksBefore -and
        $gitHooksBefore.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)
    )
    if ($alreadyDesired) {
        $activeReceiptPath = if ($activeReceipt -and
            [string]$activeReceipt.Status -ceq "applied") {
            [string]$activeReceipt.Path
        }
        else {
            Resolve-ActiveAppliedReceipt -TargetRoot $targetFull
        }
        Write-Host "[OK] Boring Is All You Need v3.0.0 is already installed; no target/config/backup/receipt/state writes."
        Write-NewTaskStrictAuditBlock -TargetRoot $targetFull -ReceiptPath $activeReceiptPath
        exit 0
    }
    if ($activeReceipt -and [string]$activeReceipt.Status -ceq "applied") {
        $trustedV202Upgrade = Test-TrustedV202UpgradeState `
            -ActiveReceipt $activeReceipt `
            -CurrentGitHooksPath $gitHooksBefore `
            -AllowedInstalledSHA256ByDestination $trustedUpgradeAllowedPreimages
        if (-not $trustedV202Upgrade) {
            [Console]::Error.WriteLine(
                "Boring Is All You Need install refused: the active applied receipt no longer matches installed state."
            )
            [Console]::Error.WriteLine("Recovery receipt: " + [string]$activeReceipt.Path)
            exit 3
        }
        if (-not $ReplaceExistingWorkflow) {
            Write-Host "[FAIL] A verified v2.0.2 installation is active. No files were written."
            Write-Host "Review the dry-run, then use -ReplaceExistingWorkflow to authorize the v3.0.0 upgrade."
            exit 2
        }
        $trustedUpgradePointerBytes = [IO.File]::ReadAllBytes($activePointerPath)
        $trustedUpgradePointerSHA256 = Get-Sha256Bytes -Bytes $trustedUpgradePointerBytes
        foreach ($trustedEntry in @($activeReceipt.Receipt.entries)) {
            $trustedDestination = [IO.Path]::GetFullPath([string]$trustedEntry.destination)
            $trustedDestinationKey = $trustedDestination.ToUpperInvariant()
            $trustedInstalledSHA256 = [string]$trustedEntry.installed_sha256
            if ([string]$trustedEntry.action -ceq 'install' -and
                $trustedUpgradeAllowedPreimages.ContainsKey($trustedDestinationKey)) {
                $actualTrustedSHA256 = (
                    Get-FileHash -LiteralPath $trustedDestination -Algorithm SHA256
                ).Hash
                if ($actualTrustedSHA256 -ceq
                    [string]$trustedUpgradeAllowedPreimages[$trustedDestinationKey]) {
                    $trustedInstalledSHA256 = $actualTrustedSHA256
                }
            }
            $trustedUpgradeEntriesByDestination[$trustedDestinationKey] =
                [pscustomobject][ordered]@{
                    action = [string]$trustedEntry.action
                    destination = [string]$trustedEntry.destination
                    existed = [bool]$trustedEntry.existed
                    snapshot_name = $trustedEntry.snapshot_name
                    original_sha256 = $trustedEntry.original_sha256
                    installed_sha256 = $trustedInstalledSHA256
                }
        }
        Write-Host "[OK] Verified the complete v2.0.2 receipt, supported no-Caveman preimages, and Git Hook state for trusted upgrade."
    }
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
        $gitMutationParent = Split-Path -Parent $gitConfigFull
        if (-not (Test-Path -LiteralPath $gitMutationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $gitMutationParent -Force | Out-Null
        }
        & git config --file $gitConfigFull --replace-all core.hooksPath $InjectGitHooksMutationValue
        if ($LASTEXITCODE -ne 0) { throw "Could not inject Git hooksPath mutation." }
    }
    $preWriteConflicts = @(Get-OperationConflicts -Operations $operations)
    $preWriteGitHooks = Get-GitHooksPath
    if ($trustedV202Upgrade) {
        $trustedUpgradeAuthorityStillMatches = (
            (Test-Path -LiteralPath $activePointerPath -PathType Leaf) -and
            (Get-FileHash -LiteralPath $activePointerPath -Algorithm SHA256).Hash -ceq
                $trustedUpgradePointerSHA256 -and
            (Test-Path -LiteralPath ([string]$activeReceipt.Path) -PathType Leaf) -and
            (Get-FileHash -LiteralPath ([string]$activeReceipt.Path) -Algorithm SHA256).Hash -ceq
                [string]$activeReceipt.ReceiptSHA256 -and
            (Test-TrustedV202UpgradeState `
                -ActiveReceipt $activeReceipt `
                -CurrentGitHooksPath $preWriteGitHooks `
                -AllowedInstalledSHA256ByDestination $trustedUpgradeAllowedPreimages)
        )
        if (-not $trustedUpgradeAuthorityStillMatches) {
            throw "The verified v2.0.2 upgrade source changed before snapshot; no migration writes were made."
        }
    }
    if ($InjectTrustedUpgradePostValidationMutationPath) {
        if (-not $trustedV202Upgrade) {
            throw "Post-validation mutation injection requires a trusted v2.0.2 upgrade."
        }
        $postValidationMutationFull = [IO.Path]::GetFullPath(
            $InjectTrustedUpgradePostValidationMutationPath
        )
        if (-not $trustedUpgradeEntriesByDestination.ContainsKey(
                $postValidationMutationFull.ToUpperInvariant()
            )) {
            throw "Post-validation mutation target is outside the trusted v2.0.2 receipt."
        }
        [IO.File]::WriteAllText(
            $postValidationMutationFull,
            "injected-post-validation-drift",
            (New-Object Text.UTF8Encoding($false))
        )
    }
    $gitHooksChangedAfterPlan = (
        ($null -eq $gitHooksBefore -and $null -ne $preWriteGitHooks) -or
        ($null -ne $gitHooksBefore -and
         ($null -eq $preWriteGitHooks -or
          -not $gitHooksBefore.Equals($preWriteGitHooks, [StringComparison]::OrdinalIgnoreCase)))
    )
    if ($gitHooksChangedAfterPlan -and -not $ReplaceExistingWorkflow) {
        Write-Host "[FAIL] Git core.hooksPath changed after planning. No Boring Is All You Need files were written."
        exit 2
    }
    $gitHooksBefore = $preWriteGitHooks
    $gitConfigExistedBefore = Test-Path -LiteralPath $gitConfigFull -PathType Leaf
    $gitConfigBytesBefore = if ($gitConfigExistedBefore) {
        [IO.File]::ReadAllBytes($gitConfigFull)
    }
    else { $null }
    $gitConfigBeforeSHA256 = if ($gitConfigExistedBefore) {
        Get-Sha256Bytes -Bytes $gitConfigBytesBefore
    }
    else { $null }
    if ($trustedV202Upgrade -and
        (-not $gitConfigExistedBefore -or
         $gitConfigBeforeSHA256 -cne [string]$activeReceipt.Receipt.git_config_after_sha256)) {
        throw "The verified v2.0.2 Git config changed before durable snapshot."
    }
    if ($gitHooksBefore -and
        $gitHooksBefore.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
        $gitConfigBytesAfter = $gitConfigBytesBefore
        $gitConfigAfterSHA256 = $gitConfigBeforeSHA256
    }
    else {
        $gitConfigBytesAfter = Get-GitConfigBytesWithHooksPath `
            -CurrentBytes $gitConfigBytesBefore `
            -Value $desiredGitHooksPath
        $gitConfigAfterSHA256 = Get-Sha256Bytes -Bytes $gitConfigBytesAfter
    }
    if ($preWriteConflicts.Count -gt 0 -and -not $ReplaceExistingWorkflow) {
        Write-Host "[FAIL] A target changed after planning. No Boring Is All You Need files were written."
        foreach ($conflict in $preWriteConflicts) { Write-Host ("CONFLICT " + $conflict) }
        exit 2
    }

    New-Item -ItemType Directory -Path $backupFull -Force | Out-Null
    Assert-NoReparsePath -Path $backupFull
    $gitHooksBeforeSnapshotName = "git-hooks-path.original.json"
    $gitHooksBeforeSnapshotPath = Join-Path $backupFull $gitHooksBeforeSnapshotName
    $gitHooksBeforeSnapshot = [pscustomobject][ordered]@{
        schema_version = 1
        core_hooks_path = $gitHooksBefore
    }
    Write-Utf8NoBomAtomic `
        -Path $gitHooksBeforeSnapshotPath `
        -Text (($gitHooksBeforeSnapshot | ConvertTo-Json -Compress) + "`n")
    $gitHooksBeforeSnapshotSha256 = (
        Get-FileHash -LiteralPath $gitHooksBeforeSnapshotPath -Algorithm SHA256
    ).Hash
    $gitConfigBeforeSnapshotName = if ($gitConfigExistedBefore) { "git-config.original" } else { $null }
    $gitConfigBeforeSnapshotSha256 = $null
    if ($gitConfigExistedBefore) {
        $gitConfigBeforeSnapshotPath = Join-Path $backupFull $gitConfigBeforeSnapshotName
        Copy-FileDurable -Source $gitConfigFull -Destination $gitConfigBeforeSnapshotPath
        $gitConfigBeforeSnapshotSha256 = (
            Get-FileHash -LiteralPath $gitConfigBeforeSnapshotPath -Algorithm SHA256
        ).Hash
        if ($gitConfigBeforeSnapshotSha256 -cne $gitConfigBeforeSHA256) {
            throw "Git config durable snapshot does not match the planned preimage."
        }
    }
    $gitConfigAfterSnapshotName = "git-config.installed"
    $gitConfigAfterSnapshotPath = Join-Path $backupFull $gitConfigAfterSnapshotName
    Invoke-SteadyAgentBoundAtomicWrite `
        -Destination $gitConfigAfterSnapshotPath `
        -Bytes $gitConfigBytesAfter `
        -RequireMissing
    $gitConfigAfterSnapshotSha256 = (
        Get-FileHash -LiteralPath $gitConfigAfterSnapshotPath -Algorithm SHA256
    ).Hash
    if ($gitConfigAfterSnapshotSha256 -cne $gitConfigAfterSHA256) {
        throw "Git config durable postimage snapshot does not match the planned bytes."
    }
    for ($index = 0; $index -lt $operations.Count; $index++) {
        $item = $operations[$index]
        $exists = Test-Path -LiteralPath $item.Destination -PathType Leaf
        $snapshotName = if ($exists) { "{0:D4}.original" -f $index } else { $null }
        $snapshotPath = if ($snapshotName) { Join-Path $backupFull $snapshotName } else { $null }
        $originalHash = $null
        if ($exists) {
            Assert-NoReparsePath -Path $item.Destination
            Assert-NoReparsePath -Path $snapshotPath -AllowMissingLeaf
            Copy-FileDurable -Source $item.Destination -Destination $snapshotPath
            $originalHash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
            $snapshotCopies++
            if ($InjectSnapshotCopyFailureAt -gt 0 -and
                $snapshotCopies -eq $InjectSnapshotCopyFailureAt) {
                throw "Injected pre-receipt snapshot copy failure."
            }
        }
        if ($trustedV202Upgrade) {
            $trustedSnapshotEntry = $trustedUpgradeEntriesByDestination[
                ([IO.Path]::GetFullPath([string]$item.Destination)).ToUpperInvariant()
            ]
            if ($null -eq $trustedSnapshotEntry -or
                [string]$trustedSnapshotEntry.action -cne [string]$item.Action -or
                ($item.Action -eq "install" -and
                 (-not $exists -or
                  $originalHash -cne [string]$trustedSnapshotEntry.installed_sha256)) -or
                ($item.Action -eq "remove" -and $exists)) {
                throw ("The verified v2.0.2 target changed before durable snapshot: " + $item.Destination)
            }
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
    if ($trustedV202Upgrade) {
        $trustedUpgradePublicationStillMatches = (
            (Get-FileHash -LiteralPath $activePointerPath -Algorithm SHA256).Hash -ceq
                $trustedUpgradePointerSHA256 -and
            (Get-FileHash -LiteralPath ([string]$activeReceipt.Path) -Algorithm SHA256).Hash -ceq
                [string]$activeReceipt.ReceiptSHA256 -and
            (Test-TrustedV202UpgradeState `
                -ActiveReceipt $activeReceipt `
                -CurrentGitHooksPath (Get-GitHooksPath) `
                -AllowedInstalledSHA256ByDestination $trustedUpgradeAllowedPreimages)
        )
        if (-not $trustedUpgradePublicationStillMatches) {
            throw "The verified v2.0.2 upgrade source changed before authority publication."
        }
    }

    $receipt = [pscustomobject][ordered]@{
        schema_version = 2
        steadyagent_version = $version
        created_utc = (Get-Date).ToUniversalTime().ToString("o")
        completed_utc = $null
        restored_utc = $null
        failure = $null
        status = "applying"
        target_root = $targetFull
        codex_home = $codexFull
        managed_config = $managedFull
        git_config = $gitConfigFull
        git_config_existed_before = $gitConfigExistedBefore
        git_config_before_sha256 = $gitConfigBeforeSHA256
        git_config_after_sha256 = $gitConfigAfterSHA256
        git_config_before_snapshot_name = $gitConfigBeforeSnapshotName
        git_config_before_snapshot_sha256 = $gitConfigBeforeSnapshotSha256
        git_config_after_snapshot_name = $gitConfigAfterSnapshotName
        git_config_after_snapshot_sha256 = $gitConfigAfterSnapshotSha256
        git_hooks_path_before = $gitHooksBefore
        git_hooks_path_after = $desiredGitHooksPath
        git_hooks_path_before_snapshot_name = $gitHooksBeforeSnapshotName
        git_hooks_path_before_snapshot_sha256 = $gitHooksBeforeSnapshotSha256
        install_operation_count = 53
        remove_operation_count = 27
        install_projection_sha256 = $installProjectionSha256
        removal_projection_sha256 = $removalProjectionSha256
        created_directories = @()
        entries = @($snapshots | ForEach-Object {
            [pscustomobject][ordered]@{
                action = $_.Action
                destination = $_.Destination
                existed = $_.Existed
                snapshot_name = $_.SnapshotName
                original_sha256 = $_.OriginalSHA256
                installed_sha256 = $_.InstalledSHA256
            }
        })
        receipt_integrity_sha256 = $null
    }
    $receiptPath = Join-Path $backupFull "migration-receipt.json"
    Write-MigrationReceipt -Receipt $receipt -Path $receiptPath
    if ($InjectTrustedUpgradePointerCasMutation) {
        if (-not $trustedV202Upgrade) {
            throw "Pointer CAS mutation injection requires a trusted v2.0.2 upgrade."
        }
        [IO.File]::WriteAllText(
            $activePointerPath,
            "injected-concurrent-pointer",
            (New-Object Text.UTF8Encoding($false))
        )
    }
    Write-ActiveReceiptPointer `
        -TargetRoot $targetFull `
        -ReceiptPath $receiptPath `
        -ExpectedCurrentPointerSHA256 $(
            if ($trustedV202Upgrade) { $trustedUpgradePointerSHA256 } else { $null }
        )
    if ($trustedV202Upgrade) { $trustedUpgradePointerTakenOver = $true }
    Write-Host ("Recovery receipt: " + $receiptPath)
    if ($InjectSnapshotMutationAt -gt 0) {
        if ($InjectSnapshotMutationAt -gt $snapshots.Count) {
            throw "Injected snapshot mutation index is outside the operation set."
        }
        $snapshotToMutate = $snapshots[$InjectSnapshotMutationAt - 1]
        if (-not $snapshotToMutate.Existed -or -not $snapshotToMutate.SnapshotPath) {
            throw "Injected snapshot mutation requires an existing target."
        }
        [IO.File]::WriteAllText($snapshotToMutate.SnapshotPath, "injected-snapshot-drift", (New-Object Text.UTF8Encoding($false)))
    }

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
                foreach ($directory in @($missing | Sort-Object { $_.Length })) {
                    $directoryPublicationCount++
                    $directoryStagePath = Join-Path $backupFull (
                        ".steadyagent-v2-directory-" + [guid]::NewGuid().ToString("N")
                    )
                    $stagedDirectoryState = New-SteadyAgentOwnedDirectory -Path $directoryStagePath
                    if ($InjectDirectoryHardKillAt -eq $directoryPublicationCount -and
                        $InjectDirectoryHardKillPhase -eq "after-stage-create") {
                        Invoke-TestHardKill -Point ("directory-stage-" + $directoryPublicationCount)
                    }
                    $directoryState = [pscustomobject][ordered]@{
                        path = [IO.Path]::GetFullPath($directory)
                        volume_serial = [string]$stagedDirectoryState.volume_serial
                        file_id = [string]$stagedDirectoryState.file_id
                    }
                    $createdDirectories.Add($directoryState) | Out-Null
                    $receipt.created_directories = @(
                        $createdDirectories | Sort-Object { ([string]$_.path).Length } -Descending
                    )
                    Write-MigrationReceipt -Receipt $receipt -Path $receiptPath
                    if ($InjectDirectoryHardKillAt -eq $directoryPublicationCount -and
                        $InjectDirectoryHardKillPhase -eq "after-receipt-before-pointer") {
                        Invoke-TestHardKill -Point ("directory-receipt-before-pointer-" + $directoryPublicationCount)
                    }
                    Write-ActiveReceiptPointer -TargetRoot $targetFull -ReceiptPath $receiptPath
                    if ($InjectDirectoryHardKillAt -eq $directoryPublicationCount -and
                        $InjectDirectoryHardKillPhase -eq "after-receipt") {
                        Invoke-TestHardKill -Point ("directory-receipt-" + $directoryPublicationCount)
                    }
                    Publish-SteadyAgentOwnedDirectory `
                        -StagingPath $directoryStagePath `
                        -DirectoryState $directoryState | Out-Null
                    if ($InjectDirectoryHardKillAt -eq $directoryPublicationCount -and
                        $InjectDirectoryHardKillPhase -eq "after-publish") {
                        Invoke-TestHardKill -Point ("directory-publish-" + $directoryPublicationCount)
                    }
                }
            }
            Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
            foreach ($createdDirectoryState in $createdDirectories) {
                Assert-SteadyAgentOwnedDirectoryIdentity `
                    -DirectoryState $createdDirectoryState | Out-Null
            }
            $afterParentPin = $null
            $afterOldRename = $null
            $afterPublish = $null
            $junctionSwapState = $null
            if ($InjectJunctionSwapAt -gt 0 -and ($written + 1) -eq $InjectJunctionSwapAt) {
                $junctionSwapState = @{ Blocked = $false }
                $junctionParent = Split-Path -Parent $item.Destination
                $afterParentPin = [Action]{
                    try {
                        if (Test-Path -LiteralPath $InjectJunctionParkedRoot) {
                            throw "Injected junction parked root already exists."
                        }
                        if (-not (Test-Path -LiteralPath $InjectJunctionEscapeRoot -PathType Container)) {
                            New-Item -ItemType Directory -Path $InjectJunctionEscapeRoot -Force | Out-Null
                        }
                        [IO.Directory]::Move($junctionParent, $InjectJunctionParkedRoot)
                        New-Item -ItemType Junction -Path $junctionParent -Target $InjectJunctionEscapeRoot | Out-Null
                        Write-Host "TEST junction swap succeeded after parent pin"
                    }
                    catch {
                        $junctionSwapState.Blocked = $true
                        Write-Host "TEST junction swap blocked after parent pin"
                    }
                }
            }
            if ($InjectAtomicHardKillAt -gt 0 -and
                ($written + 1) -eq $InjectAtomicHardKillAt) {
                if ($InjectAtomicHardKillPhase -eq "after-old-rename") {
                    $afterOldRename = [Action]{ Invoke-TestHardKill -Point "atomic-after-old-rename" }
                }
                elseif ($InjectAtomicHardKillPhase -eq "after-publish") {
                    $afterPublish = [Action]{ Invoke-TestHardKill -Point "atomic-after-publish" }
                }
                elseif ($InjectAtomicHardKillPhase -eq "after-delete-rename") {
                    throw "Delete-rename hard-kill injection requires a remove operation."
                }
            }
            Copy-Atomically `
                -Source $item.StagePath `
                -Destination $item.Destination `
                -ExpectedSHA256 $item.DesiredHash `
                -ExpectedDestinationSHA256 $snapshot.OriginalSHA256 `
                -RequireDestinationMissing:(-not $snapshot.Existed) `
                -AfterParentPin $afterParentPin `
                -AfterOldRename $afterOldRename `
                -AfterPublish $afterPublish
            if ($junctionSwapState -and -not [bool]$junctionSwapState.Blocked) {
                throw "The bound publish did not block the injected junction swap."
            }
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
            $afterDeleteRename = $null
            if ($InjectAtomicHardKillAt -gt 0 -and
                ($written + 1) -eq $InjectAtomicHardKillAt) {
                if ($InjectAtomicHardKillPhase -ne "after-delete-rename") {
                    throw "Write atomic hard-kill injection requires an install operation."
                }
                $afterDeleteRename = [Action]{ Invoke-TestHardKill -Point "atomic-after-delete-rename" }
            }
            Remove-SteadyAgentBoundFile `
                -Path $item.Destination `
                -ExpectedCurrentSHA256 $snapshot.OriginalSHA256 `
                -AfterDeleteRename $afterDeleteRename | Out-Null
            $written++
        }
        else {
            $written++
        }
        if ($InjectHardKillAfterOperation -gt 0 -and
            $written -eq $InjectHardKillAfterOperation) {
            Invoke-TestHardKill -Point ("operation-" + $written)
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
        if ($InjectGitConfigCasMutationValue) {
            $gitMutationParent = Split-Path -Parent $gitConfigFull
            if (-not (Test-Path -LiteralPath $gitMutationParent -PathType Container)) {
                New-Item -ItemType Directory -Path $gitMutationParent -Force | Out-Null
            }
            & git config --file $gitConfigFull --replace-all core.hooksPath $InjectGitConfigCasMutationValue
            if ($LASTEXITCODE -ne 0) { throw "Could not inject the final Git config CAS race." }
        }
        try {
            Set-GitConfigBytesCas `
                -Bytes $gitConfigBytesAfter `
                -ExpectedCurrentSHA256 $gitConfigBeforeSHA256 `
                -RequireMissing:(-not $gitConfigExistedBefore)
        }
        catch {
            $gitConfigCasConflict = $true
            throw ("Git config changed before bound activation. " + $_.Exception.Message)
        }
        $gitHooksChanged = $true
    }
    $verifiedInstalledGitHooks = Get-GitHooksPath
    if ((Get-FileHash -LiteralPath $gitConfigFull -Algorithm SHA256).Hash -cne $gitConfigAfterSHA256 -or
        -not $verifiedInstalledGitHooks -or
        -not $verifiedInstalledGitHooks.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Git core.hooksPath activation verification failed."
    }
    if ($InjectHardKillAfterGitActivation) {
        Invoke-TestHardKill -Point "after-git-activation"
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
    foreach ($snapshot in $snapshots) {
        if (-not $snapshot.Existed) { continue }
        Assert-NoReparsePath -Path $snapshot.SnapshotPath
        if (-not (Test-Path -LiteralPath $snapshot.SnapshotPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $snapshot.SnapshotPath -Algorithm SHA256).Hash -ne $snapshot.OriginalSHA256) {
            throw ("Final snapshot verification failed: " + $snapshot.SnapshotPath)
        }
    }
    $receipt.status = "applied"
    $receipt.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    $receipt.created_directories = @(
        $createdDirectories | Sort-Object { ([string]$_.path).Length } -Descending
    )
    Write-MigrationReceipt -Receipt $receipt -Path $receiptPath
    if ($InjectHardKillAfterAppliedReceipt) {
        Invoke-TestHardKill -Point "after-applied-receipt-before-pointer"
    }
    Write-ActiveReceiptPointer -TargetRoot $targetFull -ReceiptPath $receiptPath
    Write-Host ("[OK] Boring Is All You Need {0} installed and verified: {1} operations." -f $version, $operations.Count)
    Write-NewTaskStrictAuditBlock -TargetRoot $targetFull -ReceiptPath $receiptPath
    exit 0
}
catch {
    $rollbackErrors = @()
    if ($gitConfigCasConflict) { $rollbackErrors += "git config CAS conflict" }
    if ($gitHooksChanged) {
        try {
            $currentHooks = Get-GitHooksPath
            $currentConfigHash = if (Test-Path -LiteralPath $gitConfigFull -PathType Leaf) {
                (Get-FileHash -LiteralPath $gitConfigFull -Algorithm SHA256).Hash
            }
            else { $null }
            if ($currentConfigHash -cne $gitConfigAfterSHA256 -or
                -not $currentHooks -or
                -not $currentHooks.Equals($desiredGitHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Git core.hooksPath changed after activation."
            }
            if ($gitConfigExistedBefore) {
                Set-GitConfigBytesCas `
                    -Bytes $gitConfigBytesBefore `
                    -ExpectedCurrentSHA256 $gitConfigAfterSHA256
            }
            else {
                Remove-SteadyAgentBoundFile `
                    -Path $gitConfigFull `
                    -ExpectedCurrentSHA256 $gitConfigAfterSHA256 | Out-Null
            }
        }
        catch { $rollbackErrors += "git core.hooksPath" }
    }
    if ($Apply -and ($written -gt 0 -or $createdDirectories.Count -gt 0)) {
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
                    Assert-NoReparsePath -Path $snapshot.SnapshotPath
                    Copy-Atomically `
                        -Source $snapshot.SnapshotPath `
                        -Destination $snapshot.Destination `
                        -ExpectedSHA256 $snapshot.OriginalSHA256 `
                        -ExpectedDestinationSHA256 $(
                            if ($snapshot.Action -eq "install") {
                                $snapshot.InstalledSHA256
                            }
                            else { $null }
                        ) `
                        -RequireDestinationMissing:($snapshot.Action -eq "remove")
                    if ((Get-FileHash -LiteralPath $snapshot.Destination -Algorithm SHA256).Hash -ne $snapshot.OriginalSHA256) {
                        throw "Automatic rollback restored an unexpected file."
                    }
                }
                elseif (Test-Path -LiteralPath $snapshot.Destination) {
                    Assert-NoReparsePath -Path $snapshot.Destination
                    Remove-SteadyAgentBoundFile `
                        -Path $snapshot.Destination `
                        -ExpectedCurrentSHA256 $snapshot.InstalledSHA256 | Out-Null
                    if (Test-Path -LiteralPath $snapshot.Destination) {
                        throw "Automatic rollback did not remove a created file."
                    }
                }
            }
            catch { $rollbackErrors += $snapshot.Destination }
        }
        foreach ($directoryState in @(
            $createdDirectories |
                Sort-Object path -Unique |
                Sort-Object { ([string]$_.path).Length } -Descending
        )) {
            try {
                if (Test-Path -LiteralPath ([string]$directoryState.path) -PathType Container) {
                    Remove-SteadyAgentOwnedEmptyDirectory -DirectoryState $directoryState | Out-Null
                }
            }
            catch { $rollbackErrors += [string]$directoryState.path }
        }
        if ($InjectAutomaticRollbackFailure) {
            $rollbackErrors += "injected automatic rollback evidence fixture"
        }
    }
    if ($Apply -and $null -eq $receipt -and $written -eq 0 -and
        $rollbackErrors.Count -eq 0 -and (Test-Path -LiteralPath $backupFull -PathType Container)) {
        try {
            Assert-NoReparsePath -Path $backupFull
            Remove-Item -LiteralPath $backupFull -Recurse -Force
        }
        catch { $rollbackErrors += "pre-receipt backup cleanup" }
    }
    if ($receipt -and $trustedV202Upgrade -and -not $trustedUpgradePointerTakenOver -and
        $written -eq 0 -and -not $gitHooksChanged) {
        try {
            if ($InjectTrustedUpgradeCleanupFailure) {
                throw "Injected trusted upgrade orphan backup cleanup failure."
            }
            if (Test-Path -LiteralPath $backupFull -PathType Container) {
                Assert-NoReparsePath -Path $backupFull
                Remove-Item -LiteralPath $backupFull -Recurse -Force
            }
        }
        catch { $rollbackErrors += "pre-takeover trusted upgrade cleanup" }
        finally { $receipt = $null }
    }
    if ($receipt -and (Test-Path -LiteralPath $backupFull)) {
        $receipt.status = if ($rollbackErrors.Count -eq 0) { "rolled_back" } else { "rollback_incomplete" }
        $receipt.failure = $_.Exception.Message
        $failedReceiptPath = Join-Path $backupFull "migration-receipt.json"
        Write-MigrationReceipt -Receipt $receipt -Path $failedReceiptPath
        Write-ActiveReceiptPointer -TargetRoot $targetFull -ReceiptPath $failedReceiptPath
        if ($rollbackErrors.Count -eq 0 -and $null -ne $trustedUpgradePointerBytes -and
            -not (Test-TrustedV202UpgradeState `
                -ActiveReceipt $activeReceipt `
                -CurrentGitHooksPath (Get-GitHooksPath) `
                -AllowedInstalledSHA256ByDestination $trustedUpgradeAllowedPreimages)) {
            $rollbackErrors += "trusted v2.0.2 exact preimage"
            $receipt.status = "rollback_incomplete"
            Write-MigrationReceipt -Receipt $receipt -Path $failedReceiptPath
            Write-ActiveReceiptPointer -TargetRoot $targetFull -ReceiptPath $failedReceiptPath
        }
        elseif ($rollbackErrors.Count -eq 0 -and $null -ne $trustedUpgradePointerBytes) {
            try {
                $failedPointerSHA256 = (
                    Get-FileHash -LiteralPath $activePointerPath -Algorithm SHA256
                ).Hash
                Invoke-SteadyAgentBoundAtomicWrite `
                    -Destination $activePointerPath `
                    -Bytes $trustedUpgradePointerBytes `
                    -ExpectedCurrentSHA256 $failedPointerSHA256
                if ((Get-FileHash -LiteralPath $activePointerPath -Algorithm SHA256).Hash -cne
                    $trustedUpgradePointerSHA256) {
                    throw "The trusted v2.0.2 active pointer was not restored exactly."
                }
                Write-Host "[RECOVERED] Restored the trusted v2.0.2 active receipt pointer."
            }
            catch {
                $rollbackErrors += "trusted v2.0.2 active receipt pointer"
                $receipt.status = "rollback_incomplete"
                Write-MigrationReceipt -Receipt $receipt -Path $failedReceiptPath
                Write-ActiveReceiptPointer -TargetRoot $targetFull -ReceiptPath $failedReceiptPath
            }
        }
    }
    if ($rollbackErrors.Count -gt 0) {
        [Console]::Error.WriteLine("Boring Is All You Need migration failed and rollback was incomplete.")
        $failedReceiptPath = Join-Path $backupFull "migration-receipt.json"
        [Console]::Error.WriteLine("Preserve this recovery receipt: " + $failedReceiptPath)
        [Console]::Error.WriteLine("Recovery journal/state: " + $failedReceiptPath)
        [Console]::Error.WriteLine("Preserve the backup root and all recovery evidence: " + $backupFull)
        [Console]::Error.WriteLine("Do not blindly retry install or rollback; inspect the receipt and recovery state first.")
        exit 3
    }
    [Console]::Error.WriteLine(("Boring Is All You Need migration blocked: " + $_.Exception.Message))
    exit 2
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lockTaken -and $mutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}

#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReceiptPath,
    [string]$GitConfigPath,
    [switch]$Apply,
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
    [string]$InjectAuthorityBarrierReadyPath,
    [string]$InjectAuthorityBarrierContinuePath,
    [switch]$TestAsElevated
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
trap {
    [Console]::Error.WriteLine(("Rollback blocked: " + $_.Exception.Message))
    exit 2
}

if (($InjectTargetMutationPath -or $InjectSnapshotMutationPath -or $InjectMutexFailure -or
     $InjectFailureAfterRestore -gt 0 -or $InjectReapplyFailure -or
     $InjectHardKillAfterRollbackOperation -gt 0 -or $InjectHardKillAfterGitRestore -or
     $InjectGitConfigCasMutationValue -or
     $InjectHardKillAfterCompensationOperation -gt 0 -or
     $InjectHardKillBeforeJournalFinalizing -or $InjectHardKillAfterJournalFinalizing -or
     $InjectHardKillAfterReceiptFinalize -or $InjectHardKillAfterJournalCompleted -or
     $InjectCompletedJournalWriteFailure -or
     $InjectJunctionSwapAt -gt 0 -or $InjectJunctionParkedRoot -or
     $InjectJunctionEscapeRoot -or
     $InjectAuthorityBarrierReadyPath -or $InjectAuthorityBarrierContinuePath -or
     $TestAsElevated) -and
    $env:STEADYAGENT_TEST_MODE -ne "1") {
    throw "Test-only rollback injection parameters require STEADYAGENT_TEST_MODE=1."
}




$testMode = $env:STEADYAGENT_TEST_MODE -eq "1"








function Resolve-ReceiptOwnedActivePointer {
    param([string]$TargetRoot, [string]$ReceiptPath, [string]$ReceiptSHA256)
    $pointerPath = Get-ActiveReceiptPointerPath -TargetRoot $TargetRoot
    $pointerParent = Split-Path -Parent $pointerPath
    $pointerLeaf = Split-Path -Leaf $pointerPath
    $candidates = @(
        Get-ChildItem -LiteralPath $pointerParent -Filter ($pointerLeaf + "*") -File -Force -ErrorAction SilentlyContinue
    )
    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -ne 1 -or
        -not $candidates[0].FullName.Equals($pointerPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The active receipt pointer is ambiguous."
    }
    Assert-NoReparsePath -Path $pointerPath
    $pointerBytes = [IO.File]::ReadAllBytes($pointerPath)
    $pointerSHA256 = Get-Sha256Bytes -Bytes $pointerBytes
    $pointer = [Text.Encoding]::UTF8.GetString($pointerBytes) | ConvertFrom-Json -DateKind String
    if ([int]$pointer.schema_version -ne 1 -or
        @($pointer.receipts).Count -ne 1 -or
        [string]$pointer.pointer_integrity_sha256 -notmatch '^[0-9A-F]{64}$' -or
        [string]$pointer.pointer_integrity_sha256 -cne
            (Get-ActiveReceiptPointerIntegritySha256 -Pointer $pointer)) {
        throw "The active receipt pointer failed its integrity contract."
    }
    if (-not ([IO.Path]::GetFullPath([string]$pointer.target_root)).Equals(
        [IO.Path]::GetFullPath($TargetRoot),
        [StringComparison]::OrdinalIgnoreCase
    )) { throw "The active receipt pointer targets another installation." }
    if (([IO.Path]::GetFullPath([string]$pointer.receipts[0].path)).Equals(
            [IO.Path]::GetFullPath($ReceiptPath),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        return [pscustomobject]@{
            Path = $pointerPath
            SHA256 = $pointerSHA256
            WasStale = [string]$pointer.receipts[0].sha256 -cne $ReceiptSHA256
        }
    }
    throw "The active receipt pointer belongs to another migration transaction; rollback made zero writes."
}

function Get-RollbackAuthorityFingerprint {
    param(
        [string]$ReceiptPath,
        [string]$RollbackJournalPath,
        [string]$TargetRoot
    )
    $authorityPaths = @(
        [pscustomobject]@{ Role = "receipt"; Path = [IO.Path]::GetFullPath($ReceiptPath) },
        [pscustomobject]@{ Role = "journal"; Path = [IO.Path]::GetFullPath($RollbackJournalPath) },
        [pscustomobject]@{
            Role = "pointer"
            Path = [IO.Path]::GetFullPath((Get-ActiveReceiptPointerPath -TargetRoot $TargetRoot))
        }
    )
    $projection = New-Object Collections.Generic.List[string]
    foreach ($authority in $authorityPaths) {
        $parent = Split-Path -Parent ([string]$authority.Path)
        $leaf = Split-Path -Leaf ([string]$authority.Path)
        Assert-NoReparsePath -Path $parent
        $candidates = @(
            Get-ChildItem -LiteralPath $parent -Filter ($leaf + "*") -File -Force |
                Sort-Object Name
        )
        $projection.Add(([string]$authority.Role + ".count=" + $candidates.Count)) | Out-Null
        foreach ($candidate in $candidates) {
            Assert-NoReparsePath -Path $candidate.FullName
            $bytes = [IO.File]::ReadAllBytes($candidate.FullName)
            $projection.Add((
                [string]$authority.Role + "|" + $candidate.Name + "|" +
                $bytes.Length + "|" + (Get-Sha256Bytes -Bytes $bytes)
            )) | Out-Null
        }
    }
    return Get-Sha256Text -Text ($projection.ToArray() -join "`n")
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

function Write-RollbackJournal {
    param([object]$Journal, [string]$Path)
    $Journal.updated_utc = (Get-Date).ToUniversalTime().ToString("o")
    $Journal.journal_integrity_sha256 = Get-RollbackJournalIntegritySha256 -Journal $Journal
    Write-Utf8NoBomAtomic -Path $Path -Text (($Journal | ConvertTo-Json -Depth 10) + "`n")
}

function Read-RollbackJournal {
    param([string]$Path)
    Assert-NoReparsePath -Path $Path
    $journal = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -DateKind String
    $expectedProperties = @(
        "schema_version",
        "transaction_kind",
        "transaction_id",
        "state",
        "created_utc",
        "updated_utc",
        "failure_code",
        "failure_message",
        "receipt",
        "rollback_tool",
        "git",
        "entries",
        "created_directories",
        "snapshot_set_sha256",
        "journal_integrity_sha256"
    )
    $actualProperties = @($journal.PSObject.Properties.Name)
    if (@($expectedProperties | Where-Object { $actualProperties -notcontains $_ }).Count -gt 0 -or
        @($actualProperties | Where-Object { $expectedProperties -notcontains $_ }).Count -gt 0) {
        throw "Rollback journal schema properties do not match the frozen contract."
    }
    if ([int]$journal.schema_version -ne 1 -or
        [string]$journal.transaction_kind -cne "steadyagent-v2-rollback" -or
        [string]$journal.transaction_id -notmatch '^[0-9a-f]{32}$' -or
        [string]$journal.state -notin @(
            "rolling_back",
            "compensating",
            "compensated",
            "finalizing",
            "completed",
            "rollback_incomplete"
        )) {
        throw "Rollback journal header is invalid."
    }
    $integrity = [string]$journal.journal_integrity_sha256
    if ($integrity -notmatch '^[0-9A-F]{64}$' -or
        $integrity -cne (Get-RollbackJournalIntegritySha256 -Journal $journal)) {
        throw "Rollback journal integrity verification failed."
    }
    return $journal
}

function Get-RollbackSnapshotSetSha256 {
    param([object[]]$Entries, [string]$ReceiptSnapshotSHA256)
    $projection = New-Object Collections.Generic.List[string]
    $projection.Add("receipt=" + $ReceiptSnapshotSHA256) | Out-Null
    foreach ($entry in @($Entries | Sort-Object { [int]$_.entry_index })) {
        $projection.Add((
            "{0}|{1}|{2}|{3}|{4}" -f
            [int]$entry.entry_index,
            [string]$entry.entering_classification,
            [bool]$entry.entering_exists,
            [string]$entry.entering_snapshot_name,
            [string]$entry.entering_sha256
        )) | Out-Null
    }
    return Get-Sha256Text -Text ($projection -join "`n")
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
            throw ("Receipt destination escaped the frozen path roles: " + $destination)
        }
        $projection += (([string]$entry.action).ToLowerInvariant() + "|" + $role + "|" + $relative)
    }
    return @($projection)
}



# Intentionally local: rollback validates the transaction-rights ACL shape before recovery writes.
function Assert-SteadyAgentMigrationMutexSecurity {
    param(
        [Threading.Mutex]$Mutex,
        [Security.Principal.SecurityIdentifier]$CurrentUser
    )
    $administrators = New-Object Security.Principal.SecurityIdentifier(
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
        $null
    )
    $localSystem = New-Object Security.Principal.SecurityIdentifier(
        [Security.Principal.WellKnownSidType]::LocalSystemSid,
        $null
    )
    $security = $Mutex.GetAccessControl()
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
            $sid.Equals($CurrentUser)) {
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
    $sharedRights = [int](
        [Security.AccessControl.MutexRights]::Synchronize -bor
        [Security.AccessControl.MutexRights]::Modify
    )
    if (-not $rights.ContainsKey($CurrentUser.Value) -or
        (([int]$rights[$CurrentUser.Value] -band $sharedRights) -ne $sharedRights)) {
        throw "The machine-wide migration mutex does not grant the current user transaction rights."
    }
}

# Intentionally local: rollback grants the active caller transaction rights.
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
        $sharedRights = [Security.AccessControl.MutexRights]::Synchronize -bor
            [Security.AccessControl.MutexRights]::Modify
        $security.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule(
            $currentUser,
            $sharedRights,
            [Security.AccessControl.AccessControlType]::Allow
        )))
        foreach ($principal in @($administrators, $localSystem)) {
            $security.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule(
                $principal,
                [Security.AccessControl.MutexRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow
            )))
        }
        $createdNew = $false
        $mutex = New-Object Threading.Mutex(
            $false,
            "Global\SteadyAgentV2Migration",
            [ref]$createdNew,
            $security
        )
        Assert-SteadyAgentMigrationMutexSecurity `
            -Mutex $mutex `
            -CurrentUser $currentUser
        return $mutex
    }
    catch {
        throw "The machine-wide migration mutex is unavailable; no target writes were made."
    }
}


# Intentionally local: rollback may recreate a validated parent and has no install hard-kill callbacks.
function Copy-Atomically {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$ExpectedSHA256,
        [string]$ExpectedDestinationSHA256,
        [switch]$RequireDestinationMissing,
        [Action]$AfterParentPin
    )
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
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
        -AfterParentPin $AfterParentPin
}

function Get-ReceiptEntryState {
    param([object]$Item)
    $existsAsLeaf = Test-Path -LiteralPath $Item.Destination -PathType Leaf
    $existsAtAll = Test-Path -LiteralPath $Item.Destination
    $currentHash = if ($existsAsLeaf) {
        (Get-FileHash -LiteralPath $Item.Destination -Algorithm SHA256).Hash
    }
    else { $null }
    if ($Item.Action -eq "install") {
        $matchesPost = $existsAsLeaf -and $currentHash -eq $Item.InstalledSHA256
        $matchesOriginal = (
            ($Item.Existed -and $existsAsLeaf -and $currentHash -eq $Item.OriginalSHA256) -or
            (-not $Item.Existed -and -not $existsAtAll)
        )
        if ($matchesPost -and $matchesOriginal) { return "equivalent" }
        if ($matchesPost) { return "post" }
        if ($matchesOriginal) { return "original" }
        return "unknown"
    }
    if ($Item.Existed) {
        if (-not $existsAtAll) { return "post" }
        if ($existsAsLeaf -and $currentHash -eq $Item.OriginalSHA256) { return "original" }
        return "unknown"
    }
    if (-not $existsAtAll) { return "equivalent" }
    return "unknown"
}

# Intentionally local: rollback reads the receipt-bound Git config path supplied by the caller.
function Get-GitHooksPath {
    param([string]$ConfigPath)
    Assert-NoReparsePath -Path $ConfigPath -AllowMissingLeaf
    $value = & git config --file $ConfigPath --get core.hooksPath
    if ($LASTEXITCODE -eq 0) { return [string]$value }
    return $null
}

# Intentionally local: rollback writes the receipt-bound Git config path supplied by the caller.
function Set-GitConfigBytesCas {
    param(
        [string]$ConfigPath,
        [byte[]]$Bytes,
        [string]$ExpectedCurrentSHA256,
        [switch]$RequireMissing
    )
    Invoke-SteadyAgentBoundAtomicWrite `
        -Destination $ConfigPath `
        -Bytes $Bytes `
        -ExpectedCurrentSHA256 $ExpectedCurrentSHA256 `
        -RequireMissing:$RequireMissing
}

function Remove-GitConfigCas {
    param([string]$ConfigPath, [string]$ExpectedCurrentSHA256)
    Remove-SteadyAgentBoundFile `
        -Path $ConfigPath `
        -ExpectedCurrentSHA256 $ExpectedCurrentSHA256 | Out-Null
}

function Get-CurrentFileSHA256 {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $null
}

$receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
if ($testMode) {
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
        $PSScriptRoot,
        $receiptFull,
        $GitConfigPath,
        $InjectTargetMutationPath,
        $InjectSnapshotMutationPath,
        $InjectJunctionParkedRoot,
        $InjectJunctionEscapeRoot,
        $InjectAuthorityBarrierReadyPath,
        $InjectAuthorityBarrierContinuePath
    )) {
        if (-not $testScopedPath) { continue }
        if (-not (Test-PathWithinRoot -Path $testScopedPath -Root $testRootFull)) {
            throw ("Test-mode path escaped STEADYAGENT_TEST_ROOT: " + $testScopedPath)
        }
    }
    if ([string]::IsNullOrWhiteSpace($GitConfigPath)) {
        throw "Test mode requires an isolated GitConfigPath under STEADYAGENT_TEST_ROOT."
    }
}
if ($InjectJunctionSwapAt -lt 0 -or $InjectJunctionSwapAt -gt 80) {
    throw "InjectJunctionSwapAt must be between 1 and 80."
}
if (($InjectJunctionSwapAt -gt 0) -ne
    [bool]($InjectJunctionParkedRoot -and $InjectJunctionEscapeRoot)) {
    throw "Rollback junction swap injection requires an operation index, parked root, and escape root."
}
if ([bool]$InjectAuthorityBarrierReadyPath -ne [bool]$InjectAuthorityBarrierContinuePath) {
    throw "Rollback authority barrier injection requires both ready and continue paths."
}
Assert-NoReparsePath -Path $receiptFull
if (-not (Test-Path -LiteralPath $receiptFull -PathType Leaf)) {
    throw ("Receipt not found: " + $receiptFull)
}
$backupRoot = Split-Path -Parent $receiptFull
$rollbackJournalPath = Join-Path $backupRoot "rollback-journal.json"
$hasRollbackJournal = Test-Path -LiteralPath $rollbackJournalPath -PathType Leaf
$rollbackJournal = if ($hasRollbackJournal) {
    Read-RollbackJournal -Path $rollbackJournalPath
}
else { $null }
$receiptBytes = [IO.File]::ReadAllBytes($receiptFull)
$receiptBytesSha256 = Get-Sha256Bytes -Bytes $receiptBytes
$receipt = ([Text.Encoding]::UTF8.GetString($receiptBytes)) | ConvertFrom-Json -DateKind String
$expectedReceiptProperties = @(
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
    "removal_projection_sha256",
    "created_directories",
    "entries",
    "receipt_integrity_sha256"
)
$actualReceiptProperties = @($receipt.PSObject.Properties.Name)
$missingReceiptProperties = @($expectedReceiptProperties | Where-Object {
    $actualReceiptProperties -notcontains $_
})
$extraReceiptProperties = @($actualReceiptProperties | Where-Object {
    $expectedReceiptProperties -notcontains $_
})
if ($missingReceiptProperties.Count -gt 0 -or $extraReceiptProperties.Count -gt 0) {
    throw "Receipt schema properties do not match the frozen V2 contract."
}
if ([int]$receipt.schema_version -ne 2 -or [string]$receipt.steadyagent_version -ne "3.0.0") {
    throw "Unsupported migration receipt."
}
$receiptStatus = [string]$receipt.status
$isRollbackIncompleteReceipt = (
    $hasRollbackJournal -and
    $receiptStatus -eq "rollback_incomplete" -and
    [string]$rollbackJournal.state -eq "rollback_incomplete"
)
if ($receiptStatus -notin @("applied", "applying") -and
    -not ($hasRollbackJournal -and $receiptStatus -in @("restored", "rolled_back")) -and
    -not $isRollbackIncompleteReceipt) {
    throw ("Receipt is not eligible for rollback: status=" + [string]$receipt.status)
}
$sourceReceiptStatus = if ($hasRollbackJournal) {
    [string]$rollbackJournal.receipt.source_status
}
else { $receiptStatus }
if ($sourceReceiptStatus -notin @("applied", "applying")) {
    throw "Rollback journal source receipt status is invalid."
}
$isApplyingReceipt = $sourceReceiptStatus -eq "applying"
$receiptAlreadyFinalized = $receiptStatus -in @("restored", "rolled_back")
$receiptFinalizedDurably = $receiptAlreadyFinalized
$completionOnlyPhase = $false
$entries = @($receipt.entries)
if ($entries.Count -ne 80) {
    throw ("Receipt operation contract mismatch; expected 80 entries, found " + $entries.Count + ".")
}
if ([int]$receipt.install_operation_count -ne 53 -or
    [int]$receipt.remove_operation_count -ne 27 -or
    [string]$receipt.install_projection_sha256 -cne "D8FAAE46FF7C2E80E71C3ECC539DE1B9CE9097A0F8EFC2D1E82B25865A857356" -or
    [string]$receipt.removal_projection_sha256 -cne "F69BFE5A67AAE53337DE0C1E54D52CDDD1C841EF8528180B1F9F758F94A74582") {
    throw "Receipt operation metadata does not match the frozen V2 install contract."
}
$receiptIntegrity = [string]$receipt.receipt_integrity_sha256
$calculatedReceiptIntegrity = Get-ReceiptIntegritySha256 -Receipt $receipt
if ($receiptIntegrity -notmatch '^[0-9A-F]{64}$' -or $receiptIntegrity -cne $calculatedReceiptIntegrity) {
    throw "Receipt integrity verification failed; rollback made zero writes."
}
if ((-not $receiptAlreadyFinalized -and $null -ne $receipt.restored_utc) -or
    -not [string]$receipt.created_utc) {
    throw ($receiptStatus + " receipt lifecycle fields are invalid.")
}
if ($isRollbackIncompleteReceipt) {
    if (-not [string]$receipt.failure) {
        throw "Rollback-incomplete receipt is missing its manual-recovery failure evidence."
    }
}
elseif ($null -ne $receipt.failure) {
    throw ($receiptStatus + " receipt lifecycle fields are invalid.")
}
if ($isApplyingReceipt -and $null -ne $receipt.completed_utc) {
    throw "Applying receipt lifecycle fields are invalid."
}
if (-not $isApplyingReceipt -and -not [string]$receipt.completed_utc) {
    throw "Applied receipt lifecycle fields are invalid."
}
$receiptGitConfig = [string]$receipt.git_config
$effectiveGitConfig = [IO.Path]::GetFullPath($receiptGitConfig)
Assert-NoReparsePath -Path $effectiveGitConfig -AllowMissingLeaf
if (-not $testMode -and -not [string]::IsNullOrWhiteSpace($GitConfigPath)) {
    throw "Production rollback uses the physical Git config path frozen in the receipt."
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
$seenSnapshots = @{}
$validated = New-Object Collections.Generic.List[object]
$receiptTargetRoot = [IO.Path]::GetFullPath([string]$receipt.target_root)
$receiptCodexHome = [IO.Path]::GetFullPath([string]$receipt.codex_home)
$receiptManagedConfig = [IO.Path]::GetFullPath([string]$receipt.managed_config)
$installedTargetRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$rollbackRunsFromInstalledTarget = $receiptTargetRoot.Equals(
    $installedTargetRoot,
    [StringComparison]::OrdinalIgnoreCase
)
if (-not $testMode) {
    $programDataRoot = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonApplicationData
    )
    if ([string]::IsNullOrWhiteSpace($programDataRoot)) {
        $programDataRoot = "C:\ProgramData"
    }
    $defaultTargetRoot = [IO.Path]::GetFullPath((Join-Path $HOME ".steadyagent"))
    $defaultCodexHome = [IO.Path]::GetFullPath((Join-Path $HOME ".codex"))
    $defaultManagedConfig = [IO.Path]::GetFullPath(
        (Join-Path $programDataRoot "OpenAI\Codex\requirements.toml")
    )
    $defaultBackupParent = [IO.Path]::GetFullPath(
        (Join-Path (Split-Path -Parent $defaultTargetRoot) ".steadyagent-backups")
    )
    $productionHome = [IO.Path]::GetFullPath($HOME)
    if (-not $receiptTargetRoot.Equals($defaultTargetRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $receiptCodexHome.Equals($defaultCodexHome, [StringComparison]::OrdinalIgnoreCase) -or
        -not $receiptManagedConfig.Equals($defaultManagedConfig, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Production receipt paths do not match the default Boring Is All You Need compatibility path roles."
    }
    if (-not ($effectiveGitConfig.Equals(
            (Join-Path $productionHome ".gitconfig"),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $effectiveGitConfig.StartsWith(
            $productionHome.TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase
        ))) {
        throw "Production receipt Git config path must remain inside the current user profile."
    }
    if (-not [IO.Path]::GetFullPath((Split-Path -Parent $backupRoot)).Equals(
        $defaultBackupParent,
        [StringComparison]::OrdinalIgnoreCase
    ) -or
        -not (Split-Path -Leaf $receiptFull).Equals(
            "migration-receipt.json",
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Production receipt must be the canonical receipt in a default backup directory."
    }
}
$rolePaths = @($receiptTargetRoot, $receiptCodexHome, $receiptManagedConfig, [IO.Path]::GetFullPath($backupRoot))
if ($effectiveGitConfig) { $rolePaths += $effectiveGitConfig }
if ($testMode) {
    foreach ($testScopedRole in $rolePaths) {
        if (-not (Test-PathWithinRoot -Path $testScopedRole -Root $testRootFull)) {
            throw ("Receipt path escaped STEADYAGENT_TEST_ROOT: " + $testScopedRole)
        }
    }
}
for ($leftIndex = 0; $leftIndex -lt $rolePaths.Count; $leftIndex++) {
    for ($rightIndex = $leftIndex + 1; $rightIndex -lt $rolePaths.Count; $rightIndex++) {
        if (Test-PathTreeOverlap -First $rolePaths[$leftIndex] -Second $rolePaths[$rightIndex]) {
            throw "Receipt path roles are not disjoint."
        }
    }
}
$gitHooksBefore = if ($null -eq $receipt.git_hooks_path_before) {
    $null
}
else {
    [string]$receipt.git_hooks_path_before
}
$gitHooksBeforeSnapshotName = [string]$receipt.git_hooks_path_before_snapshot_name
if ($gitHooksBeforeSnapshotName -cne "git-hooks-path.original.json") {
    throw "Receipt Git before snapshot name is invalid."
}
$gitHooksBeforeSnapshotPath = Join-Path $backupRoot $gitHooksBeforeSnapshotName
Assert-NoReparsePath -Path $gitHooksBeforeSnapshotPath
$gitHooksBeforeSnapshotSha256 = [string]$receipt.git_hooks_path_before_snapshot_sha256
if ($gitHooksBeforeSnapshotSha256 -notmatch '^[0-9A-F]{64}$' -or
    -not (Test-Path -LiteralPath $gitHooksBeforeSnapshotPath -PathType Leaf) -or
    (Get-FileHash -LiteralPath $gitHooksBeforeSnapshotPath -Algorithm SHA256).Hash -cne
        $gitHooksBeforeSnapshotSha256) {
    throw "Receipt Git before snapshot verification failed."
}
$gitHooksBeforeSnapshot = (
    [IO.File]::ReadAllText($gitHooksBeforeSnapshotPath, [Text.Encoding]::UTF8) |
        ConvertFrom-Json -DateKind String
)
$gitSnapshotProperties = @($gitHooksBeforeSnapshot.PSObject.Properties.Name)
if ($gitSnapshotProperties.Count -ne 2 -or
    $gitSnapshotProperties -notcontains "schema_version" -or
    $gitSnapshotProperties -notcontains "core_hooks_path" -or
    [int]$gitHooksBeforeSnapshot.schema_version -ne 1) {
    throw "Receipt Git before snapshot schema is invalid."
}
$snapshottedGitHooksBefore = if ($null -eq $gitHooksBeforeSnapshot.core_hooks_path) {
    $null
}
else {
    [string]$gitHooksBeforeSnapshot.core_hooks_path
}
$gitBeforeMatchesSnapshot = (
    ($null -eq $gitHooksBefore -and $null -eq $snapshottedGitHooksBefore) -or
    ($null -ne $gitHooksBefore -and $null -ne $snapshottedGitHooksBefore -and
        $gitHooksBefore.Equals($snapshottedGitHooksBefore, [StringComparison]::Ordinal))
)
if (-not $gitBeforeMatchesSnapshot) {
    throw "Receipt Git before value does not match its install snapshot."
}
if ($receipt.git_config_existed_before -isnot [bool]) {
    throw "Receipt Git config existence flag is not Boolean."
}
$gitConfigExistedBefore = [bool]$receipt.git_config_existed_before
$gitConfigBeforeSHA256 = if ($null -eq $receipt.git_config_before_sha256) {
    $null
}
else { [string]$receipt.git_config_before_sha256 }
$gitConfigAfterSHA256 = [string]$receipt.git_config_after_sha256
$gitConfigBeforeSnapshotName = if ($null -eq $receipt.git_config_before_snapshot_name) {
    $null
}
else { [string]$receipt.git_config_before_snapshot_name }
$gitConfigBeforeSnapshotSHA256 = if ($null -eq $receipt.git_config_before_snapshot_sha256) {
    $null
}
else { [string]$receipt.git_config_before_snapshot_sha256 }
$gitConfigBytesBefore = $null
if ($gitConfigAfterSHA256 -notmatch '^[0-9A-F]{64}$') {
    throw "Receipt Git config postimage hash is invalid."
}
if ($gitConfigExistedBefore) {
    if ($gitConfigBeforeSHA256 -notmatch '^[0-9A-F]{64}$' -or
        $gitConfigBeforeSnapshotName -cne "git-config.original" -or
        $gitConfigBeforeSnapshotSHA256 -cne $gitConfigBeforeSHA256) {
        throw "Receipt Git config preimage metadata is invalid."
    }
    $gitConfigBeforeSnapshotPath = Join-Path $backupRoot $gitConfigBeforeSnapshotName
    Assert-NoReparsePath -Path $gitConfigBeforeSnapshotPath
    if (-not (Test-Path -LiteralPath $gitConfigBeforeSnapshotPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $gitConfigBeforeSnapshotPath -Algorithm SHA256).Hash -cne
            $gitConfigBeforeSHA256) {
        throw "Receipt Git config preimage snapshot verification failed."
    }
    $gitConfigBytesBefore = [IO.File]::ReadAllBytes($gitConfigBeforeSnapshotPath)
}
elseif ($null -ne $gitConfigBeforeSHA256 -or
    $null -ne $gitConfigBeforeSnapshotName -or
    $null -ne $gitConfigBeforeSnapshotSHA256) {
    throw "Receipt claims a missing Git config but carries preimage metadata."
}
$gitConfigAfterSnapshotName = [string]$receipt.git_config_after_snapshot_name
$gitConfigAfterSnapshotSHA256 = [string]$receipt.git_config_after_snapshot_sha256
if ($gitConfigAfterSnapshotName -cne "git-config.installed" -or
    $gitConfigAfterSnapshotSHA256 -cne $gitConfigAfterSHA256) {
    throw "Receipt Git config postimage snapshot metadata is invalid."
}
$gitConfigAfterSnapshotPath = Join-Path $backupRoot $gitConfigAfterSnapshotName
Assert-NoReparsePath -Path $gitConfigAfterSnapshotPath
if (-not (Test-Path -LiteralPath $gitConfigAfterSnapshotPath -PathType Leaf) -or
    (Get-FileHash -LiteralPath $gitConfigAfterSnapshotPath -Algorithm SHA256).Hash -cne
        $gitConfigAfterSHA256) {
    throw "Receipt Git config postimage snapshot verification failed."
}
$gitConfigBytesAfter = [IO.File]::ReadAllBytes($gitConfigAfterSnapshotPath)
$installEntries = @($entries | Where-Object { [string]$_.action -eq "install" })
$removeEntries = @($entries | Where-Object { [string]$_.action -eq "remove" })
$installProjectionSha256 = Get-SortedProjectionSha256 -Projection @(
    Get-ReceiptOperationProjection `
        -Entries $installEntries `
        -TargetRoot $receiptTargetRoot `
        -CodexHome $receiptCodexHome `
        -ManagedConfig $receiptManagedConfig
)
$removalProjectionSha256 = Get-SortedProjectionSha256 -Projection @(
    Get-ReceiptOperationProjection `
        -Entries $removeEntries `
        -TargetRoot $receiptTargetRoot `
        -CodexHome $receiptCodexHome `
        -ManagedConfig $receiptManagedConfig
)
if ($installEntries.Count -ne 53 -or
    $installProjectionSha256 -cne "D8FAAE46FF7C2E80E71C3ECC539DE1B9CE9097A0F8EFC2D1E82B25865A857356") {
    throw (
        "Receipt install operation contract mismatch; count={0} projection={1}." -f
        $installEntries.Count,
        $installProjectionSha256
    )
}
if ($removeEntries.Count -ne 27 -or
    $removalProjectionSha256 -cne "F69BFE5A67AAE53337DE0C1E54D52CDDD1C841EF8528180B1F9F758F94A74582") {
    throw (
        "Receipt removal operation contract mismatch; count={0} projection={1}." -f
        $removeEntries.Count,
        $removalProjectionSha256
    )
}
$expectedRollbackDestination = [IO.Path]::GetFullPath(
    (Join-Path $receiptTargetRoot "tools\rollback.ps1")
)
$rollbackEntries = @($installEntries | Where-Object {
    [IO.Path]::GetFullPath([string]$_.destination).Equals(
        $expectedRollbackDestination,
        [StringComparison]::OrdinalIgnoreCase
    )
})
$runningRollbackHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
if ($rollbackEntries.Count -ne 1 -or
    [string]$rollbackEntries[0].installed_sha256 -cne $runningRollbackHash) {
    throw "Rollback tool identity does not match the receipt install contract."
}
$boundPolicyDestination = Join-Path $receiptTargetRoot "tools\protected-path-policy.ps1"
$boundPolicyEntries = @($installEntries | Where-Object {
    [IO.Path]::GetFullPath([string]$_.destination).Equals(
        $boundPolicyDestination,
        [StringComparison]::OrdinalIgnoreCase
    )
})
if ($boundPolicyEntries.Count -ne 1) {
    throw "Bound path policy identity is missing from the receipt install contract."
}
$boundPolicySource = Join-Path $PSScriptRoot "protected-path-policy.ps1"
if (-not (Test-Path -LiteralPath $boundPolicySource -PathType Leaf)) {
    throw "The rollback runtime is missing its bound path policy."
}
$boundPolicyBytes = [IO.File]::ReadAllBytes($boundPolicySource)
if ((Get-Sha256Bytes -Bytes $boundPolicyBytes) -cne
    [string]$boundPolicyEntries[0].installed_sha256) {
    throw "The rollback runtime bound path policy does not match the receipt."
}
$strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
$boundPolicyText = $strictUtf8.GetString($boundPolicyBytes)
$boundPolicyBlock = [scriptblock]::Create($boundPolicyText)
. $boundPolicyBlock
if (-not ("SteadyAgent.BoundPath" -as [type]) -or
    -not (Get-Command Invoke-SteadyAgentBoundAtomicWrite -ErrorAction SilentlyContinue) -or
    -not (Get-Command Repair-SteadyAgentBoundMutation -ErrorAction SilentlyContinue) -or
    -not (Get-Command Test-SteadyAgentBoundMutationPending -ErrorAction SilentlyContinue)) {
    throw "The reviewed bound path policy did not load its mutation primitives."
}
if ($hasRollbackJournal -and
    ([string]$rollbackJournal.rollback_tool.running_sha256 -cne $runningRollbackHash -or
     [string]$rollbackJournal.rollback_tool.installed_sha256 -cne $runningRollbackHash)) {
    throw "Running rollback tool identity does not match the active rollback journal."
}

for ($entryIndex = 0; $entryIndex -lt $entries.Count; $entryIndex++) {
    $entry = $entries[$entryIndex]
    $expectedEntryProperties = @(
        "action",
        "destination",
        "existed",
        "snapshot_name",
        "original_sha256",
        "installed_sha256"
    )
    $actualEntryProperties = @($entry.PSObject.Properties.Name)
    if (@($expectedEntryProperties | Where-Object { $actualEntryProperties -notcontains $_ }).Count -gt 0 -or
        @($actualEntryProperties | Where-Object { $expectedEntryProperties -notcontains $_ }).Count -gt 0) {
        throw ("Receipt entry schema mismatch at index " + $entryIndex + ".")
    }
    $action = [string]$entry.action
    if ($action -notin @("install", "remove")) { throw ("Invalid receipt action: " + $action) }
    if ($entry.existed -isnot [bool]) {
        throw ("Receipt existed flag is not Boolean at index " + $entryIndex + ".")
    }
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
    if ($action -eq "install" -and $installedHash -notmatch '^[0-9A-Fa-f]{64}$') {
        throw ("Installed hash is invalid for: " + $destination)
    }

    $snapshotPath = $null
    if ([bool]$entry.existed) {
        $snapshotName = [string]$entry.snapshot_name
        $expectedSnapshotName = "{0:D4}.original" -f $entryIndex
        if ($snapshotName -cne $expectedSnapshotName) {
            throw ("Invalid snapshot name for: " + $destination)
        }
        $snapshotKey = $snapshotName.ToLowerInvariant()
        if ($seenSnapshots.ContainsKey($snapshotKey)) {
            throw ("Duplicate snapshot reference: " + $snapshotName)
        }
        $seenSnapshots[$snapshotKey] = $true
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
    elseif ([string]$entry.snapshot_name -or [string]$entry.original_sha256) {
        throw ("Nonexistent original has snapshot metadata: " + $destination)
    }
    if ($action -eq "remove" -and $installedHash) {
        throw ("Removal entry has an installed hash: " + $destination)
    }
    $validatedItem = [pscustomobject]@{
        Action = $action
        Destination = $destination
        Existed = [bool]$entry.existed
        SnapshotPath = $snapshotPath
        OriginalSHA256 = [string]$entry.original_sha256
        InstalledSHA256 = $installedHash
    }
    Add-Member -InputObject $validatedItem -NotePropertyName EntryIndex -NotePropertyValue $entryIndex
    $validated.Add($validatedItem) | Out-Null
}

$gitHooksAfter = [string]$receipt.git_hooks_path_after
$expectedGitHooksAfter = Join-Path $receiptTargetRoot "tools\git-hooks"
if (-not $gitHooksAfter.Equals($expectedGitHooksAfter, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Receipt Git after value does not match the frozen install contract."
}

$validatedCreatedDirectories = @()
if ($receipt.PSObject.Properties.Name -contains "created_directories") {
    $safeRoots = @(
        [IO.Path]::GetFullPath([string]$receipt.target_root),
        [IO.Path]::GetFullPath([string]$receipt.codex_home),
        [IO.Path]::GetFullPath((Split-Path -Parent ([string]$receipt.managed_config)))
    )
    foreach ($candidate in @($receipt.created_directories)) {
        foreach ($name in @("path", "volume_serial", "file_id")) {
            if ($candidate.PSObject.Properties.Name -notcontains $name -or
                [string]::IsNullOrWhiteSpace([string]$candidate.$name)) {
                throw ("Created directory ownership record is missing " + $name + ".")
            }
        }
        $directoryFull = [IO.Path]::GetFullPath([string]$candidate.path)
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
        if (Test-Path -LiteralPath $directoryFull -PathType Container) {
            $currentDirectoryState = Get-SteadyAgentDirectoryIdentity -Path $directoryFull
            if ([string]$currentDirectoryState.volume_serial -cne [string]$candidate.volume_serial -or
                [string]$currentDirectoryState.file_id -cne [string]$candidate.file_id) {
                throw ("Created directory ownership identity changed: " + $directoryFull)
            }
        }
        $validatedCreatedDirectories += [pscustomobject][ordered]@{
            path = $directoryFull
            volume_serial = [string]$candidate.volume_serial
            file_id = [string]$candidate.file_id
        }
    }
}
$validatedCreatedDirectories = @(
    $validatedCreatedDirectories |
        Sort-Object path -Unique |
        Sort-Object { ([string]$_.path).Length } -Descending
)

function Get-ValidatedRuntimeClassification {
    param(
        [switch]$RepairPending,
        [switch]$AllowPending
    )

    $pendingPaths = New-Object Collections.Generic.List[string]
    foreach ($validatedItem in $validated) {
        $hasPendingMutation = Test-SteadyAgentBoundMutationPending `
            -Path $validatedItem.Destination
        if ($hasPendingMutation -and -not $RepairPending) {
            if (-not $AllowPending) {
                throw ("Pending bound recovery requires the migration mutex: " + $validatedItem.Destination)
            }
            $pendingPaths.Add($validatedItem.Destination) | Out-Null
            Add-Member -InputObject $validatedItem -NotePropertyName EntryState `
                -NotePropertyValue "pending" -Force
            continue
        }
        if ($RepairPending) {
            Repair-SteadyAgentBoundMutation -Path $validatedItem.Destination | Out-Null
        }
        $entryState = Get-ReceiptEntryState -Item $validatedItem
        if (-not $isApplyingReceipt -and -not $hasRollbackJournal) {
            if ($entryState -notin @("post", "equivalent")) {
                if ($validatedItem.Action -eq "install" -and
                    -not (Test-Path -LiteralPath $validatedItem.Destination -PathType Leaf)) {
                    throw ("Installed file is missing; rollback made zero writes: " + $validatedItem.Destination)
                }
                if ($validatedItem.Action -eq "install") {
                    throw ("Installed file drifted; rollback made zero writes: " + $validatedItem.Destination)
                }
                throw ("Removed V1 file reappeared; rollback made zero writes: " + $validatedItem.Destination)
            }
        }
        elseif (-not $isRollbackIncompleteReceipt -and $entryState -eq "unknown") {
            throw (
                "Applying receipt target is not in a known original or post-install state; " +
                "rollback made zero writes: " + $validatedItem.Destination
            )
        }
        Add-Member -InputObject $validatedItem -NotePropertyName EntryState `
            -NotePropertyValue $entryState -Force
    }

    $gitHasPendingMutation = Test-SteadyAgentBoundMutationPending -Path $effectiveGitConfig
    if ($gitHasPendingMutation -and -not $RepairPending) {
        if (-not $AllowPending) {
            throw ("Pending bound recovery requires the migration mutex: " + $effectiveGitConfig)
        }
        $pendingPaths.Add($effectiveGitConfig) | Out-Null
        $gitEntryState = "pending"
    }
    else {
        if ($RepairPending) {
            Repair-SteadyAgentBoundMutation -Path $effectiveGitConfig | Out-Null
        }
        $currentGitHooks = Get-GitHooksPath -ConfigPath $effectiveGitConfig
        $currentGitConfigSHA256 = Get-CurrentFileSHA256 -Path $effectiveGitConfig
        $gitConfigMatchesBefore = if ($gitConfigExistedBefore) {
            $currentGitConfigSHA256 -ceq $gitConfigBeforeSHA256
        }
        else { $null -eq $currentGitConfigSHA256 }
        $gitMatchesBefore = (
            $gitConfigMatchesBefore -and
            (
                ($null -eq $gitHooksBefore -and $null -eq $currentGitHooks) -or
                ($null -ne $gitHooksBefore -and $null -ne $currentGitHooks -and
                 $currentGitHooks.Equals($gitHooksBefore, [StringComparison]::OrdinalIgnoreCase))
            )
        )
        $gitMatchesAfter = (
            $currentGitConfigSHA256 -ceq $gitConfigAfterSHA256 -and
            $null -ne $currentGitHooks -and
            $currentGitHooks.Equals($gitHooksAfter, [StringComparison]::OrdinalIgnoreCase)
        )
        if (-not $isApplyingReceipt -and -not $hasRollbackJournal -and -not $gitMatchesAfter) {
            throw "Git core.hooksPath drifted; rollback made zero writes."
        }
        if (-not $isRollbackIncompleteReceipt -and
            ($isApplyingReceipt -or $hasRollbackJournal) -and
            -not ($gitMatchesBefore -or $gitMatchesAfter)) {
            throw "Git core.hooksPath is not in the receipt before or after state; rollback made zero writes."
        }
        $gitEntryState = if ($gitMatchesAfter) { "after" } else { "before" }
    }

    return [pscustomobject]@{
        GitEntryState = $gitEntryState
        PendingPaths = @($pendingPaths.ToArray())
    }
}

$ownedActivePointer = Resolve-ReceiptOwnedActivePointer `
    -TargetRoot ([string]$receipt.target_root) `
    -ReceiptPath $receiptFull `
    -ReceiptSHA256 $receiptBytesSha256
$activePointerReleasedDurably = $null -eq $ownedActivePointer
$preLockAuthorityFingerprint = Get-RollbackAuthorityFingerprint `
    -ReceiptPath $receiptFull `
    -RollbackJournalPath $rollbackJournalPath `
    -TargetRoot ([string]$receipt.target_root)

if (-not $Apply) {
    if ($hasRollbackJournal -and [string]$rollbackJournal.state -eq "completed") {
        Write-Host "[OK] Boring Is All You Need rollback transaction was already completed; 0 writes."
        exit 0
    }
    $dryRunClassification = Get-ValidatedRuntimeClassification -AllowPending
    if ($receiptStatus -eq "applied" -and
        -not $hasRollbackJournal -and
        @($dryRunClassification.PendingPaths).Count -eq 0) {
        Write-Host "STABLE INSTALLED PROJECTION VERIFIED receipt=applied entries=80 pending=0"
    }
    Write-Host ("DRY-RUN Boring Is All You Need v3.0.0 rollback: {0} files; 0 writes." -f $validated.Count)
    foreach ($pendingPath in @($dryRunClassification.PendingPaths)) {
        Write-Host ("PENDING BOUND RECOVERY " + $pendingPath)
    }
    foreach ($item in $validated) {
        Write-Host ($(if ($item.Existed) { "WOULD RESTORE " } else { "WOULD REMOVE " }) + $item.Destination)
    }
    exit 0
}

if ($InjectMutexFailure) {
    throw "The machine-wide migration mutex is unavailable; no target writes were made."
}
$mutex = New-SteadyAgentMigrationMutex -TestRoot $(if ($testMode) { $testRootFull } else { $null })
$lockTaken = $false
$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ("steadyagent-v2-rollback-stage-" + [guid]::NewGuid().ToString("N"))
$restoredItems = New-Object Collections.Generic.List[object]
$gitChanged = $false
$rollbackOperationCount = 0
$compensationOperationCount = 0
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
    if ($InjectAuthorityBarrierReadyPath) {
        [IO.File]::WriteAllText(
            $InjectAuthorityBarrierReadyPath,
            "authority-validated`n",
            (New-Object Text.UTF8Encoding($false))
        )
        $barrierDeadline = [DateTime]::UtcNow.AddSeconds(45)
        while (-not (Test-Path -LiteralPath $InjectAuthorityBarrierContinuePath -PathType Leaf)) {
            if ([DateTime]::UtcNow -ge $barrierDeadline) {
                throw "Rollback authority barrier timed out before mutex acquisition."
            }
            Start-Sleep -Milliseconds 20
        }
    }
    try { $lockTaken = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $lockTaken = $true }
    if (-not $lockTaken) { throw "Another Boring Is All You Need install or rollback transaction is active." }

    $postLockAuthorityFingerprint = Get-RollbackAuthorityFingerprint `
        -ReceiptPath $receiptFull `
        -RollbackJournalPath $rollbackJournalPath `
        -TargetRoot ([string]$receipt.target_root)
    if ($postLockAuthorityFingerprint -cne $preLockAuthorityFingerprint) {
        throw "Rollback authority changed before mutex acquisition; zero target writes were made."
    }

    $runtimeClassification = Get-ValidatedRuntimeClassification -RepairPending
    $gitEntryState = [string]$runtimeClassification.GitEntryState

    if ($hasRollbackJournal) {
        $sourceReceiptSnapshotPath = Join-Path $backupRoot (
            [string]$rollbackJournal.receipt.source_snapshot_name
        )
        Assert-NoReparsePath -Path $sourceReceiptSnapshotPath
        if (-not (Test-Path -LiteralPath $sourceReceiptSnapshotPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $sourceReceiptSnapshotPath -Algorithm SHA256).Hash -cne
                [string]$rollbackJournal.receipt.source_bytes_sha256) {
            throw "Rollback source receipt snapshot verification failed."
        }
        if (-not $receiptAlreadyFinalized -and -not $isRollbackIncompleteReceipt -and
            $receiptBytesSha256 -cne [string]$rollbackJournal.receipt.source_bytes_sha256) {
            throw "Migration receipt changed during rollback."
        }
        $expectedSuccessStatus = if (
            [string]$rollbackJournal.receipt.source_status -eq "applying"
        ) { "rolled_back" } else { "restored" }
        if ($receiptAlreadyFinalized -and
            ($receiptStatus -cne $expectedSuccessStatus -or
             [string]$rollbackJournal.state -notin @("finalizing", "completed"))) {
            throw "Finalized migration receipt does not match the rollback journal."
        }
        if (-not [IO.Path]::GetFullPath(
                [string]$rollbackJournal.rollback_tool.expected_destination
            ).Equals($expectedRollbackDestination, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Rollback journal tool destination does not match the receipt."
        }
        $journalEntries = @($rollbackJournal.entries)
        if ($journalEntries.Count -ne $validated.Count) {
            throw "Rollback journal entry count does not match the receipt."
        }
        for ($index = 0; $index -lt $validated.Count; $index++) {
            $item = $validated[$index]
            $journalEntry = $journalEntries[$index]
            if ([int]$journalEntry.entry_index -ne $index -or
                -not [IO.Path]::GetFullPath([string]$journalEntry.destination).Equals(
                    $item.Destination,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                [string]$journalEntry.entering_classification -notin @(
                    "original", "post", "equivalent"
                )) {
                throw ("Rollback journal entry contract mismatch at index " + $index + ".")
            }
            $entryStateStagePath = $null
            if ([bool]$journalEntry.entering_exists) {
                $entryStateStagePath = Join-Path $backupRoot (
                    [string]$journalEntry.entering_snapshot_name
                )
                Assert-NoReparsePath -Path $entryStateStagePath
                if (-not (Test-Path -LiteralPath $entryStateStagePath -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $entryStateStagePath -Algorithm SHA256).Hash -cne
                        [string]$journalEntry.entering_sha256) {
                    throw ("Rollback entering snapshot verification failed at index " + $index + ".")
                }
            }
            elseif ([string]$journalEntry.entering_snapshot_name -or
                [string]$journalEntry.entering_sha256) {
                throw ("Absent rollback entering state has snapshot metadata at index " + $index + ".")
            }
            $item.EntryState = [string]$journalEntry.entering_classification
            Add-Member -InputObject $item -NotePropertyName EntryStateStagePath `
                -NotePropertyValue $entryStateStagePath -Force
            Add-Member -InputObject $item -NotePropertyName EntryStateSHA256 `
                -NotePropertyValue ([string]$journalEntry.entering_sha256) -Force
            Add-Member -InputObject $item -NotePropertyName EntryStateExisted `
                -NotePropertyValue ([bool]$journalEntry.entering_exists) -Force
            if ($item.Existed) {
                # Original receipt snapshots remain the source of truth.
                $originalStagePath = $item.SnapshotPath
            }
            else { $originalStagePath = $null }
            Add-Member -InputObject $item -NotePropertyName OriginalStagePath `
                -NotePropertyValue $originalStagePath -Force
        }
        $calculatedSnapshotSetSha256 = Get-RollbackSnapshotSetSha256 `
            -Entries $journalEntries `
            -ReceiptSnapshotSHA256 ([string]$rollbackJournal.receipt.source_bytes_sha256)
        if ([string]$rollbackJournal.snapshot_set_sha256 -notmatch '^[0-9A-F]{64}$' -or
            [string]$rollbackJournal.snapshot_set_sha256 -cne $calculatedSnapshotSetSha256) {
            throw "Rollback journal snapshot-set verification failed."
        }
        $gitEntryState = [string]$rollbackJournal.git.entering_classification
        if ($gitEntryState -notin @("before", "after")) {
            throw "Rollback journal Git entering classification is invalid."
        }
        if ([string]$rollbackJournal.state -eq "rollback_incomplete") {
            if (-not $isRollbackIncompleteReceipt) {
                throw "Rollback-incomplete journal and receipt status do not agree."
            }
            [Console]::Error.WriteLine(
                "Rollback journal is rollback_incomplete and requires manual recovery."
            )
            exit 3
        }
        if ([string]$rollbackJournal.state -eq "completed") {
            if (-not $activePointerReleasedDurably -and
                (Test-Path -LiteralPath $ownedActivePointer.Path -PathType Leaf)) {
                Remove-SteadyAgentBoundFile `
                    -Path $ownedActivePointer.Path `
                    -ExpectedCurrentSHA256 $ownedActivePointer.SHA256 | Out-Null
                $activePointerReleasedDurably = $true
            }
            Write-Host "[OK] Boring Is All You Need rollback transaction was already completed."
            exit 0
        }
        if ([string]$rollbackJournal.state -eq "compensated") {
            $rollbackJournal.state = "rolling_back"
            $rollbackJournal.failure_code = $null
            $rollbackJournal.failure_message = $null
            Write-RollbackJournal -Journal $rollbackJournal -Path $rollbackJournalPath
        }
        elseif ([string]$rollbackJournal.state -eq "compensating") {
            for ($index = $validated.Count - 1; $index -ge 0; $index--) {
                $item = $validated[$index]
                Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
                $currentState = Get-ReceiptEntryState -Item $item
                $matchesEntering = (
                    $currentState -eq $item.EntryState -or
                    ($currentState -in @("original", "equivalent") -and
                     $item.EntryState -in @("original", "equivalent"))
                )
                if ($matchesEntering) { continue }
                if ($currentState -notin @("original", "equivalent")) {
                    throw (
                        "Rollback compensation encountered a third target state: " +
                        $item.Destination
                    )
                }
                if ($item.EntryStateExisted) {
                    Copy-Atomically `
                        -Source $item.EntryStateStagePath `
                        -Destination $item.Destination `
                        -ExpectedSHA256 $item.EntryStateSHA256 `
                        -ExpectedDestinationSHA256 $(
                            if ($item.Existed) { $item.OriginalSHA256 } else { $null }
                        ) `
                        -RequireDestinationMissing:(-not $item.Existed)
                }
                elseif (Test-Path -LiteralPath $item.Destination) {
                    if (-not $item.Existed) {
                        throw "Rollback compensation found an unexpected target while restoring a missing entering state."
                    }
                    Remove-SteadyAgentBoundFile `
                        -Path $item.Destination `
                        -ExpectedCurrentSHA256 $item.OriginalSHA256 | Out-Null
                }
                $verifiedState = Get-ReceiptEntryState -Item $item
                $verifiedMatchesEntering = (
                    $verifiedState -eq $item.EntryState -or
                    ($verifiedState -in @("original", "equivalent") -and
                     $item.EntryState -in @("original", "equivalent"))
                )
                if (-not $verifiedMatchesEntering) {
                    throw (
                        "Rollback compensation could not restore its entering state: " +
                        $item.Destination
                    )
                }
            }
            $compensationGitHooks = Get-GitHooksPath -ConfigPath $effectiveGitConfig
            $compensationGitHash = Get-CurrentFileSHA256 -Path $effectiveGitConfig
            $compensationGitIsBefore = (
                $(if ($gitConfigExistedBefore) {
                    $compensationGitHash -ceq $gitConfigBeforeSHA256
                } else { $null -eq $compensationGitHash }) -and
                (
                    ($null -eq $gitHooksBefore -and $null -eq $compensationGitHooks) -or
                    ($null -ne $gitHooksBefore -and $null -ne $compensationGitHooks -and
                     $compensationGitHooks.Equals(
                        $gitHooksBefore,
                        [StringComparison]::OrdinalIgnoreCase
                     ))
                )
            )
            $compensationGitIsAfter = (
                $compensationGitHash -ceq $gitConfigAfterSHA256 -and
                $null -ne $compensationGitHooks -and
                $compensationGitHooks.Equals(
                    $gitHooksAfter,
                    [StringComparison]::OrdinalIgnoreCase
                )
            )
            if ($gitEntryState -eq "after" -and $compensationGitIsBefore) {
                Set-GitConfigBytesCas `
                    -ConfigPath $effectiveGitConfig `
                    -Bytes $gitConfigBytesAfter `
                    -ExpectedCurrentSHA256 $gitConfigBeforeSHA256 `
                    -RequireMissing:(-not $gitConfigExistedBefore)
            }
            elseif ($gitEntryState -eq "before" -and $compensationGitIsAfter) {
                if ($gitConfigExistedBefore) {
                    Set-GitConfigBytesCas `
                        -ConfigPath $effectiveGitConfig `
                        -Bytes $gitConfigBytesBefore `
                        -ExpectedCurrentSHA256 $gitConfigAfterSHA256
                }
                else {
                    Remove-GitConfigCas `
                        -ConfigPath $effectiveGitConfig `
                        -ExpectedCurrentSHA256 $gitConfigAfterSHA256
                }
            }
            elseif (($gitEntryState -eq "after" -and -not $compensationGitIsAfter) -or
                ($gitEntryState -eq "before" -and -not $compensationGitIsBefore)) {
                throw "Rollback compensation encountered a third Git hooksPath state."
            }
            foreach ($directoryState in @($rollbackJournal.created_directories)) {
                $directory = [IO.Path]::GetFullPath([string]$directoryState.path)
                Assert-NoReparsePath -Path $directory -AllowMissingLeaf
                if ([bool]$directoryState.entering_exists) {
                    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                        throw ("Rollback compensation cannot reconstruct an owned directory identity: " + $directory)
                    }
                    $currentDirectoryState = Get-SteadyAgentDirectoryIdentity -Path $directory
                    if ([string]$currentDirectoryState.volume_serial -cne [string]$directoryState.volume_serial -or
                        [string]$currentDirectoryState.file_id -cne [string]$directoryState.file_id) {
                        throw ("Rollback compensation found a replaced owned directory: " + $directory)
                    }
                }
                elseif (Test-Path -LiteralPath $directory -PathType Container) {
                    throw ("Rollback compensation found an unexpected entering-absent directory: " + $directory)
                }
            }
            $rollbackJournal.state = "compensated"
            $rollbackJournal.failure_code = $null
            $rollbackJournal.failure_message = $null
            Write-RollbackJournal -Journal $rollbackJournal -Path $rollbackJournalPath
            [Console]::Error.WriteLine(
                "Rollback compensation completed after a hard interruption; rerun -Apply to retry rollback."
            )
            exit 2
        }
    }
    else {
        if ($snapshotInjectionFull) {
            [IO.File]::WriteAllText(
                $snapshotInjectionFull,
                "injected-snapshot-drift",
                (New-Object Text.UTF8Encoding($false))
            )
            $snapshotInjectionApplied = $true
        }
        $transactionId = [guid]::NewGuid().ToString("N")
        $stateRelativeRoot = Join-Path "rollback-state" $transactionId
        $stateRoot = Join-Path $backupRoot $stateRelativeRoot
        Assert-NoReparsePath -Path $stateRoot -AllowMissingLeaf
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        $sourceReceiptSnapshotName = Join-Path $stateRelativeRoot "source-receipt.json"
        $sourceReceiptSnapshotPath = Join-Path $backupRoot $sourceReceiptSnapshotName
        Copy-Atomically `
            -Source $receiptFull `
            -Destination $sourceReceiptSnapshotPath `
            -ExpectedSHA256 $receiptBytesSha256 `
            -RequireDestinationMissing
        $journalEntries = New-Object Collections.Generic.List[object]
        for ($index = 0; $index -lt $validated.Count; $index++) {
            $item = $validated[$index]
            $entryStateExisted = Test-Path -LiteralPath $item.Destination -PathType Leaf
            $entryStateHash = if ($entryStateExisted) {
                (Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash
            }
            else { $null }
            $entryStateSnapshotName = if ($entryStateExisted) {
                Join-Path $stateRelativeRoot (("{0:D4}.entering" -f $index))
            }
            else { $null }
            $entryStateStagePath = if ($entryStateSnapshotName) {
                Join-Path $backupRoot $entryStateSnapshotName
            }
            else { $null }
            if ($entryStateExisted) {
                Copy-Atomically `
                    -Source $item.Destination `
                    -Destination $entryStateStagePath `
                    -ExpectedSHA256 $entryStateHash `
                    -RequireDestinationMissing
                if ((Get-FileHash -LiteralPath $item.Destination -Algorithm SHA256).Hash -cne
                    $entryStateHash) {
                    throw ("Target changed while snapshotting its rollback entering state: " +
                        $item.Destination)
                }
            }
            Add-Member -InputObject $item -NotePropertyName EntryStateStagePath `
                -NotePropertyValue $entryStateStagePath -Force
            Add-Member -InputObject $item -NotePropertyName EntryStateSHA256 `
                -NotePropertyValue $entryStateHash -Force
            Add-Member -InputObject $item -NotePropertyName EntryStateExisted `
                -NotePropertyValue $entryStateExisted -Force
            Add-Member -InputObject $item -NotePropertyName OriginalStagePath `
                -NotePropertyValue $item.SnapshotPath -Force
            $journalEntries.Add([pscustomobject][ordered]@{
                entry_index = $index
                destination = $item.Destination
                entering_classification = $item.EntryState
                entering_exists = $entryStateExisted
                entering_snapshot_name = $entryStateSnapshotName
                entering_sha256 = $entryStateHash
            }) | Out-Null
        }
        $rollbackEntryIndex = -1
        for ($index = 0; $index -lt $entries.Count; $index++) {
            if ([IO.Path]::GetFullPath([string]$entries[$index].destination).Equals(
                $expectedRollbackDestination,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                $rollbackEntryIndex = $index
                break
            }
        }
        if ($rollbackEntryIndex -lt 0) {
            throw "Rollback tool entry index is unavailable."
        }
        $journalCreatedDirectories = @($validatedCreatedDirectories | ForEach-Object {
            [pscustomobject][ordered]@{
                path = $_.path
                volume_serial = $_.volume_serial
                file_id = $_.file_id
                entering_exists = (Test-Path -LiteralPath $_.path -PathType Container)
            }
        })
        $rollbackJournal = [pscustomobject][ordered]@{
            schema_version = 1
            transaction_kind = "steadyagent-v2-rollback"
            transaction_id = $transactionId
            state = "rolling_back"
            created_utc = (Get-Date).ToUniversalTime().ToString("o")
            updated_utc = $null
            failure_code = $null
            failure_message = $null
            receipt = [pscustomobject][ordered]@{
                path = $receiptFull
                source_snapshot_name = $sourceReceiptSnapshotName
                source_bytes_sha256 = $receiptBytesSha256
                source_integrity_sha256 = $receiptIntegrity
                source_status = $receiptStatus
                source_completed_utc = $receipt.completed_utc
                success_status = $(if ($isApplyingReceipt) { "rolled_back" } else { "restored" })
            }
            rollback_tool = [pscustomobject][ordered]@{
                receipt_entry_index = $rollbackEntryIndex
                expected_destination = $expectedRollbackDestination
                installed_sha256 = $runningRollbackHash
                running_sha256 = $runningRollbackHash
            }
            git = [pscustomobject][ordered]@{
                before = $gitHooksBefore
                after = $gitHooksAfter
                entering_classification = $gitEntryState
            }
            entries = $journalEntries.ToArray()
            created_directories = $journalCreatedDirectories
            snapshot_set_sha256 = $null
            journal_integrity_sha256 = $null
        }
        $rollbackJournal.snapshot_set_sha256 = Get-RollbackSnapshotSetSha256 `
            -Entries $journalEntries.ToArray() `
            -ReceiptSnapshotSHA256 $receiptBytesSha256
        Write-RollbackJournal -Journal $rollbackJournal -Path $rollbackJournalPath
        $hasRollbackJournal = $true
    }

    $lockedGitHooks = Get-GitHooksPath -ConfigPath $effectiveGitConfig
    $lockedGitHash = Get-CurrentFileSHA256 -Path $effectiveGitConfig
    $lockedGitMatchesEntry = if ($gitEntryState -eq "after") {
        $lockedGitHash -ceq $gitConfigAfterSHA256 -and
        $null -ne $lockedGitHooks -and
        $lockedGitHooks.Equals($gitHooksAfter, [StringComparison]::OrdinalIgnoreCase)
    }
    else {
        $(if ($gitConfigExistedBefore) {
            $lockedGitHash -ceq $gitConfigBeforeSHA256
        } else { $null -eq $lockedGitHash }) -and
        (
            ($null -eq $gitHooksBefore -and $null -eq $lockedGitHooks) -or
            ($null -ne $gitHooksBefore -and $null -ne $lockedGitHooks -and
             $lockedGitHooks.Equals($gitHooksBefore, [StringComparison]::OrdinalIgnoreCase))
        )
    }
    $lockedGitMatchesOriginal = (
        $(if ($gitConfigExistedBefore) {
            $lockedGitHash -ceq $gitConfigBeforeSHA256
        } else { $null -eq $lockedGitHash }) -and
        (
            ($null -eq $gitHooksBefore -and $null -eq $lockedGitHooks) -or
            ($null -ne $gitHooksBefore -and $null -ne $lockedGitHooks -and
             $lockedGitHooks.Equals($gitHooksBefore, [StringComparison]::OrdinalIgnoreCase))
        )
    )
    if (-not ($lockedGitMatchesEntry -or
        ($hasRollbackJournal -and $lockedGitMatchesOriginal))) {
        throw "Git core.hooksPath changed while acquiring the rollback lock."
    }
    foreach ($item in $validated) {
        Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
        $lockedState = Get-ReceiptEntryState -Item $item
        if ($lockedState -notin @($item.EntryState, "original", "equivalent")) {
            throw ("Target state changed while acquiring the rollback lock: " + $item.Destination)
        }
    }

    foreach ($item in $validated) {
        if (-not $injectionApplied -and $targetInjectionFull -and
            $targetInjectionFull.Equals($item.Destination, [StringComparison]::OrdinalIgnoreCase)) {
            [IO.File]::WriteAllText($item.Destination, "injected-rollback-drift", (New-Object Text.UTF8Encoding($false)))
            $injectionApplied = $true
        }
        Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
        $immediateState = Get-ReceiptEntryState -Item $item
        if ($immediateState -in @("original", "equivalent")) {
            continue
        }
        if ($immediateState -ne $item.EntryState) {
            throw ("Target changed immediately before restoration: " + $item.Destination)
        }
        if ($item.EntryState -in @("original", "equivalent")) { continue }
        $afterParentPin = $null
        $junctionSwapState = $null
        if ($InjectJunctionSwapAt -gt 0 -and
            ($rollbackOperationCount + 1) -eq $InjectJunctionSwapAt) {
            $junctionSwapState = @{ Blocked = $false }
            $junctionParent = Split-Path -Parent $item.Destination
            $afterParentPin = [Action]{
                try {
                    if (Test-Path -LiteralPath $InjectJunctionParkedRoot) {
                        throw "Injected rollback junction parked root already exists."
                    }
                    if (-not (Test-Path -LiteralPath $InjectJunctionEscapeRoot -PathType Container)) {
                        New-Item -ItemType Directory -Path $InjectJunctionEscapeRoot -Force | Out-Null
                    }
                    [IO.Directory]::Move($junctionParent, $InjectJunctionParkedRoot)
                    New-Item -ItemType Junction -Path $junctionParent -Target $InjectJunctionEscapeRoot | Out-Null
                    Write-Host "TEST rollback junction swap succeeded after parent pin"
                }
                catch {
                    $junctionSwapState.Blocked = $true
                    Write-Host "TEST rollback junction swap blocked after parent pin"
                }
            }
        }
        if ($item.Existed) {
            Copy-Atomically `
                -Source $item.OriginalStagePath `
                -Destination $item.Destination `
                -ExpectedSHA256 $item.OriginalSHA256 `
                -ExpectedDestinationSHA256 $(
                    if ($item.Action -eq "install") { $item.InstalledSHA256 }
                    else { $null }
                ) `
                -RequireDestinationMissing:($item.Action -eq "remove") `
                -AfterParentPin $afterParentPin
        }
        elseif (Test-Path -LiteralPath $item.Destination) {
            Remove-SteadyAgentBoundFile `
                -Path $item.Destination `
                -ExpectedCurrentSHA256 $item.InstalledSHA256 `
                -AfterParentPin $afterParentPin | Out-Null
        }
        if ($junctionSwapState -and -not [bool]$junctionSwapState.Blocked) {
            throw "The bound rollback mutation did not block the injected junction swap."
        }
        $restoredItems.Add($item) | Out-Null
        $rollbackOperationCount++
        if ($InjectHardKillAfterRollbackOperation -gt 0 -and
            $rollbackOperationCount -eq $InjectHardKillAfterRollbackOperation) {
            Invoke-TestHardKill -Point ("rollback-operation-" + $rollbackOperationCount)
        }
        if ($InjectFailureAfterRestore -gt 0 -and
            $restoredItems.Count -eq $InjectFailureAfterRestore) {
            throw "Injected rollback recovery failure."
        }
    }

    $gitHooksImmediatelyBeforeRestore = Get-GitHooksPath -ConfigPath $effectiveGitConfig
    $gitHashImmediatelyBeforeRestore = Get-CurrentFileSHA256 -Path $effectiveGitConfig
    $gitStillMatchesEntry = if ($gitEntryState -eq "after") {
        $gitHashImmediatelyBeforeRestore -ceq $gitConfigAfterSHA256 -and
        $null -ne $gitHooksImmediatelyBeforeRestore -and
        $gitHooksImmediatelyBeforeRestore.Equals($gitHooksAfter, [StringComparison]::OrdinalIgnoreCase)
    }
    else {
        $(if ($gitConfigExistedBefore) {
            $gitHashImmediatelyBeforeRestore -ceq $gitConfigBeforeSHA256
        } else { $null -eq $gitHashImmediatelyBeforeRestore }) -and
        (
            ($null -eq $gitHooksBefore -and $null -eq $gitHooksImmediatelyBeforeRestore) -or
            ($null -ne $gitHooksBefore -and $null -ne $gitHooksImmediatelyBeforeRestore -and
             $gitHooksImmediatelyBeforeRestore.Equals($gitHooksBefore, [StringComparison]::OrdinalIgnoreCase))
        )
    }
    $gitAlreadyRestored = (
        $(if ($gitConfigExistedBefore) {
            $gitHashImmediatelyBeforeRestore -ceq $gitConfigBeforeSHA256
        } else { $null -eq $gitHashImmediatelyBeforeRestore }) -and
        (
            ($null -eq $gitHooksBefore -and $null -eq $gitHooksImmediatelyBeforeRestore) -or
            ($null -ne $gitHooksBefore -and $null -ne $gitHooksImmediatelyBeforeRestore -and
             $gitHooksImmediatelyBeforeRestore.Equals(
                $gitHooksBefore,
                [StringComparison]::OrdinalIgnoreCase
             ))
        )
    )
    if (-not ($gitStillMatchesEntry -or $gitAlreadyRestored)) {
        throw "Git core.hooksPath changed immediately before restoration."
    }
    if ($gitEntryState -eq "after" -and -not $gitAlreadyRestored) {
        if ($InjectGitConfigCasMutationValue) {
            & git config --file $effectiveGitConfig --replace-all core.hooksPath $InjectGitConfigCasMutationValue
            if ($LASTEXITCODE -ne 0) { throw "Could not inject the rollback Git config CAS race." }
        }
        if ($gitConfigExistedBefore) {
            try {
                Set-GitConfigBytesCas `
                    -ConfigPath $effectiveGitConfig `
                    -Bytes $gitConfigBytesBefore `
                    -ExpectedCurrentSHA256 $gitConfigAfterSHA256
            }
            catch {
                throw ("Git config changed before bound restoration. " + $_.Exception.Message)
            }
        }
        else {
            try {
                Remove-GitConfigCas `
                    -ConfigPath $effectiveGitConfig `
                    -ExpectedCurrentSHA256 $gitConfigAfterSHA256
            }
            catch {
                throw ("Git config changed before bound restoration. " + $_.Exception.Message)
            }
        }
        $gitChanged = $true
        if ($InjectHardKillAfterGitRestore) {
            Invoke-TestHardKill -Point "after-git-restore"
        }
    }
    foreach ($item in $validated) {
        $restoredState = Get-ReceiptEntryState -Item $item
        if ($restoredState -eq "equivalent") { $restoredState = "original" }
        if ($restoredState -ne "original") {
            throw ("Restored preimage verification failed: " + $item.Destination)
        }
    }
    $verifiedGitHooks = Get-GitHooksPath -ConfigPath $effectiveGitConfig
    $verifiedGitHash = Get-CurrentFileSHA256 -Path $effectiveGitConfig
    $verifiedGitBytes = if ($gitConfigExistedBefore) {
        $verifiedGitHash -ceq $gitConfigBeforeSHA256
    } else { $null -eq $verifiedGitHash }
    if (-not $verifiedGitBytes -or
        ($null -eq $gitHooksBefore -and $null -ne $verifiedGitHooks) -or
        ($null -ne $gitHooksBefore -and
         (-not $verifiedGitHooks -or -not $verifiedGitHooks.Equals($gitHooksBefore, [StringComparison]::OrdinalIgnoreCase)))) {
        throw "Git core.hooksPath restoration verification failed."
    }

    foreach ($directoryState in $validatedCreatedDirectories) {
        $directory = [string]$directoryState.path
        if (Test-Path -LiteralPath $directory -PathType Container) {
            Remove-SteadyAgentOwnedEmptyDirectory -DirectoryState $directoryState | Out-Null
            if (Test-Path -LiteralPath $directory) {
                throw ("Created rollback directory was not removed: " + $directory)
            }
        }
    }
    if ($InjectHardKillBeforeJournalFinalizing) {
        Invoke-TestHardKill -Point "before-journal-finalizing"
    }
    $rollbackJournal.state = "finalizing"
    Write-RollbackJournal -Journal $rollbackJournal -Path $rollbackJournalPath
    if ($InjectHardKillAfterJournalFinalizing) {
        Invoke-TestHardKill -Point "after-journal-finalizing"
    }
    if (-not $receiptAlreadyFinalized) {
        $receipt.status = if ($isApplyingReceipt) { "rolled_back" } else { "restored" }
        $receipt.restored_utc = (Get-Date).ToUniversalTime().ToString("o")
        $receipt.receipt_integrity_sha256 = Get-ReceiptIntegritySha256 -Receipt $receipt
        $expectedFinalizedReceiptBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
            (($receipt | ConvertTo-Json -Depth 7) + "`n")
        )
        $expectedFinalizedReceiptSha256 = Get-Sha256Bytes -Bytes $expectedFinalizedReceiptBytes
        try {
            Write-MigrationReceipt -Receipt $receipt -Path $receiptFull
            $receiptFinalizedDurably = $true
        }
        catch {
            if (Test-Path -LiteralPath $receiptFull -PathType Leaf) {
                try {
                    $persistedReceiptBytes = [IO.File]::ReadAllBytes($receiptFull)
                    if ((Get-Sha256Bytes -Bytes $persistedReceiptBytes) -ceq
                        $expectedFinalizedReceiptSha256) {
                        $receiptFinalizedDurably = $true
                        $completionOnlyPhase = $true
                    }
                }
                catch { }
            }
            throw
        }
    }
    if ($InjectHardKillAfterReceiptFinalize) {
        Invoke-TestHardKill -Point "after-receipt-finalize"
    }
    $completionOnlyPhase = $true
    $rollbackJournal.state = "completed"
    if ($InjectCompletedJournalWriteFailure) {
        throw "Injected completed journal write failure."
    }
    Write-RollbackJournal -Journal $rollbackJournal -Path $rollbackJournalPath
    if ($InjectHardKillAfterJournalCompleted) {
        Invoke-TestHardKill -Point "after-journal-completed"
    }
    if (-not $activePointerReleasedDurably -and
        (Test-Path -LiteralPath $ownedActivePointer.Path -PathType Leaf)) {
        Remove-SteadyAgentBoundFile `
            -Path $ownedActivePointer.Path `
            -ExpectedCurrentSHA256 $ownedActivePointer.SHA256 | Out-Null
        $activePointerReleasedDurably = $true
    }
    Write-Host ("[OK] Boring Is All You Need v3.0.0 rollback restored {0} files and Git core.hooksPath." -f $validated.Count)
    exit 0
}
catch {
    $rollbackFailure = $_.Exception.Message
    if ($receiptFinalizedDurably) {
        try {
            $persistedFinalizationJournal = Read-RollbackJournal -Path $rollbackJournalPath
        }
        catch {
            [Console]::Error.WriteLine(
                "Rollback receipt is finalized, but the durable journal cannot be verified; " +
                "targets were not compensated. Manual recovery is required."
            )
            exit 3
        }
        if ([string]$persistedFinalizationJournal.state -eq "completed") {
            if ($activePointerReleasedDurably) {
                Write-Host "[OK] Boring Is All You Need rollback transaction was already completed."
                exit 0
            }
            [Console]::Error.WriteLine(
                "Rollback journal is completed, but active pointer release is pending. Rerun -Apply."
            )
            exit 2
        }
        if ([string]$persistedFinalizationJournal.state -eq "finalizing" -and
            $completionOnlyPhase) {
            [Console]::Error.WriteLine(
                "Rollback receipt is finalized and targets are restored; journal completion is pending. " +
                "Rerun -Apply to retry completion."
            )
            exit 2
        }
        [Console]::Error.WriteLine(
            "Rollback receipt is finalized, but completion failed before the journal-only phase: " +
            $rollbackFailure + ". Targets were not compensated."
        )
        exit 3
    }
    $reapplyErrors = @()
    if ($rollbackJournal) {
        try {
            $rollbackJournal.state = "compensating"
            $rollbackJournal.failure_code = "ROLLBACK_CAUGHT_EXCEPTION"
            $rollbackJournal.failure_message = $rollbackFailure
            Write-RollbackJournal -Journal $rollbackJournal -Path $rollbackJournalPath
        }
        catch {
            [Console]::Error.WriteLine(
                "Rollback failed before durable compensation state could be published."
            )
            exit 3
        }
    }
    if ($gitChanged) {
        try {
            $currentHooks = Get-GitHooksPath -ConfigPath $effectiveGitConfig
            $currentGitHash = Get-CurrentFileSHA256 -Path $effectiveGitConfig
            $hooksStillRestored = (
                $(if ($gitConfigExistedBefore) {
                    $currentGitHash -ceq $gitConfigBeforeSHA256
                } else { $null -eq $currentGitHash }) -and
                (
                    ($null -eq $gitHooksBefore -and $null -eq $currentHooks) -or
                    ($null -ne $gitHooksBefore -and $null -ne $currentHooks -and
                     $currentHooks.Equals($gitHooksBefore, [StringComparison]::OrdinalIgnoreCase))
                )
            )
            if (-not $hooksStillRestored) { throw "Git core.hooksPath changed after restoration." }
            Set-GitConfigBytesCas `
                -ConfigPath $effectiveGitConfig `
                -Bytes $gitConfigBytesAfter `
                -ExpectedCurrentSHA256 $gitConfigBeforeSHA256 `
                -RequireMissing:(-not $gitConfigExistedBefore)
        }
        catch { $reapplyErrors += "git core.hooksPath" }
    }
    if ($InjectReapplyFailure -and $restoredItems.Count -gt 0) {
        try {
            [IO.File]::WriteAllText(
                $restoredItems[0].Destination,
                "injected-reapply-drift",
                (New-Object Text.UTF8Encoding($false))
            )
        }
        catch {
            $reapplyErrors += "injected reapply drift"
        }
    }
    for ($index = $restoredItems.Count - 1; $index -ge 0; $index--) {
        $item = $restoredItems[$index]
        try {
            $currentState = Get-ReceiptEntryState -Item $item
            if ($currentState -eq "equivalent") { $currentState = "original" }
            if ($currentState -ne "original") {
                throw "Restored target changed before reapplying its entering state."
            }
            if ($item.EntryStateExisted) {
                Assert-NoReparsePath -Path $item.Destination -AllowMissingLeaf
                Copy-Atomically `
                    -Source $item.EntryStateStagePath `
                    -Destination $item.Destination `
                    -ExpectedSHA256 $item.EntryStateSHA256 `
                    -ExpectedDestinationSHA256 $(
                        if ($item.Existed) { $item.OriginalSHA256 } else { $null }
                    ) `
                    -RequireDestinationMissing:(-not $item.Existed)
            }
            elseif (Test-Path -LiteralPath $item.Destination) {
                if (-not $item.Existed) {
                    throw "Rollback compensation found an unexpected target while restoring a missing entering state."
                }
                Remove-SteadyAgentBoundFile `
                    -Path $item.Destination `
                    -ExpectedCurrentSHA256 $item.OriginalSHA256 | Out-Null
            }
            $compensationOperationCount++
            if ($InjectHardKillAfterCompensationOperation -gt 0 -and
                $compensationOperationCount -eq $InjectHardKillAfterCompensationOperation) {
                Invoke-TestHardKill -Point (
                    "rollback-compensation-operation-" + $compensationOperationCount
                )
            }
        }
        catch { $reapplyErrors += $item.Destination }
    }
    if ($rollbackJournal) {
        foreach ($directoryState in @($rollbackJournal.created_directories)) {
            if ([bool]$directoryState.entering_exists -and
                -not (Test-Path -LiteralPath ([string]$directoryState.path) -PathType Container)) {
                $reapplyErrors += [string]$directoryState.path
            }
            elseif ([bool]$directoryState.entering_exists) {
                try {
                    $currentDirectoryState = Get-SteadyAgentDirectoryIdentity -Path ([string]$directoryState.path)
                    if ([string]$currentDirectoryState.volume_serial -cne [string]$directoryState.volume_serial -or
                        [string]$currentDirectoryState.file_id -cne [string]$directoryState.file_id) {
                        $reapplyErrors += [string]$directoryState.path
                    }
                }
                catch { $reapplyErrors += [string]$directoryState.path }
            }
        }
    }
    if ($reapplyErrors.Count -gt 0) {
        try {
            $rollbackJournal.state = "rollback_incomplete"
            $rollbackJournal.failure_code = "ROLLBACK_COMPENSATION_INCOMPLETE"
            $rollbackJournal.failure_message = ($reapplyErrors -join "; ")
            Write-RollbackJournal -Journal $rollbackJournal -Path $rollbackJournalPath
            $receipt.status = "rollback_incomplete"
            $receipt.failure = (
                "Rollback failed and exact entering-state compensation was incomplete: " +
                ($reapplyErrors -join "; ")
            )
            Write-MigrationReceipt -Receipt $receipt -Path $receiptFull
        }
        catch {
            $reapplyErrors += "rollback receipt"
        }
        [Console]::Error.WriteLine("Rollback failed and reapplying the entering state was incomplete.")
        exit 3
    }
    if ($rollbackJournal) {
        $rollbackJournal.state = "compensated"
        Write-RollbackJournal -Journal $rollbackJournal -Path $rollbackJournalPath
    }
    [Console]::Error.WriteLine(("Rollback blocked: " + $rollbackFailure))
    exit 2
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lockTaken) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

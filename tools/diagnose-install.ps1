[CmdletBinding()]
param(
    [string]$TargetRoot = (Join-Path $HOME ".steadyagent"),
    [string]$CodexHome = (Join-Path $HOME ".codex"),
    [string]$ManagedConfigPath,
    [string]$GitConfigPath,
    [string]$ReceiptPath,
    [switch]$RequireInstalledBytes,
    [switch]$RequireHooksActive,
    [switch]$RequireRuntimeCatalog,
    [switch]$RequireGitIdentity,
    [switch]$SkipSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($SkipSmoke -and $env:STEADYAGENT_TEST_MODE -ne "1") {
    throw "SkipSmoke is available only to isolated Boring Is All You Need tests."
}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

if (-not $ManagedConfigPath) {
    $programDataRoot = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
    $ManagedConfigPath = Join-Path $programDataRoot "OpenAI\Codex\requirements.toml"
}

$script:Passed = 0
$script:Warned = 0
$script:Failed = 0

function Add-Result {
    param(
        [ValidateSet("PASS", "WARN", "FAIL")][string]$Status,
        [string]$Name,
        [string]$Detail = ""
    )
    if ($Status -eq "PASS") { $script:Passed++ }
    elseif ($Status -eq "WARN") { $script:Warned++ }
    else { $script:Failed++ }
    Write-Host ("{0} {1}{2}" -f $Status, $Name, $(if ($Detail) { " - " + $Detail } else { "" }))
}

function Test-File {
    param([string]$Name, [string]$Path)
    Add-Result $(if (Test-Path -LiteralPath $Path -PathType Leaf) { "PASS" } else { "FAIL" }) $Name $Path
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

function Get-Sha256Bytes {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Initialize-TrustedDirectoryPinType {
    if ("SteadyAgent.DiagnosePinnedDirectory" -as [type]) { return }
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SteadyAgent
{
    public sealed class DiagnosePinnedDirectory : IDisposable
    {
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle handle,
            out BY_HANDLE_FILE_INFORMATION information);

        private SafeFileHandle handle;

        private DiagnosePinnedDirectory(SafeFileHandle value)
        {
            handle = value;
        }

        public static DiagnosePinnedDirectory Open(string path)
        {
            SafeFileHandle value = CreateFileW(
                path,
                0,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero);
            if (value.IsInvalid)
            {
                int code = Marshal.GetLastWin32Error();
                value.Dispose();
                throw new Win32Exception(code, "Could not pin trusted directory: " + path);
            }
            BY_HANDLE_FILE_INFORMATION information;
            if (!GetFileInformationByHandle(value, out information))
            {
                int code = Marshal.GetLastWin32Error();
                value.Dispose();
                throw new Win32Exception(code, "Could not inspect pinned directory: " + path);
            }
            FileAttributes attributes = (FileAttributes)information.FileAttributes;
            if ((attributes & FileAttributes.Directory) == 0 ||
                (attributes & FileAttributes.ReparsePoint) != 0)
            {
                value.Dispose();
                throw new IOException("Trusted directory pin rejected a non-directory or reparse point: " + path);
            }
            return new DiagnosePinnedDirectory(value);
        }

        public void Dispose()
        {
            if (handle != null)
            {
                handle.Dispose();
                handle = null;
            }
        }
    }
}
'@
}

function Assert-TrustedReadPath {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($cursor)) {
        throw ("Trusted read file is missing: " + $cursor)
    }
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            $attributes = [IO.File]::GetAttributes($cursor)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ("Trusted read path contains a reparse point: " + $cursor)
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Open-TrustedReadLease {
    param([string]$Path, [int64]$MaximumBytes = 4194304)
    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-TrustedReadPath -Path $fullPath
    $stream = $null
    $directoryPins = New-Object Collections.Generic.List[object]
    try {
        Initialize-TrustedDirectoryPinType
        $directoryPaths = New-Object Collections.Generic.List[string]
        $directoryCursor = [IO.Path]::GetDirectoryName($fullPath)
        while (-not [string]::IsNullOrEmpty($directoryCursor)) {
            $directoryPaths.Add($directoryCursor) | Out-Null
            $parent = [IO.Path]::GetDirectoryName($directoryCursor)
            if ([string]::IsNullOrEmpty($parent) -or $parent -eq $directoryCursor) { break }
            $directoryCursor = $parent
        }
        for ($index = $directoryPaths.Count - 1; $index -ge 0; $index--) {
            $directoryPins.Add(
                [SteadyAgent.DiagnosePinnedDirectory]::Open($directoryPaths[$index])
            ) | Out-Null
        }
        $stream = [IO.File]::Open(
            $fullPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        Assert-TrustedReadPath -Path $fullPath
        if ($stream.Length -lt 1 -or $stream.Length -gt $MaximumBytes) {
            throw ("Trusted read file length is outside the frozen bound: " + $fullPath)
        }
        $memory = New-Object IO.MemoryStream
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        }
        finally {
            $memory.Dispose()
        }
        return [pscustomobject]@{
            Path = $fullPath
            Stream = $stream
            DirectoryPins = $directoryPins.ToArray()
            Bytes = [byte[]]$bytes
            SHA256 = Get-Sha256Bytes -Bytes ([byte[]]$bytes)
        }
    }
    catch {
        if ($stream) { $stream.Dispose() }
        for ($index = $directoryPins.Count - 1; $index -ge 0; $index--) {
            $directoryPins[$index].Dispose()
        }
        throw
    }
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
        "schema_version", "steadyagent_version", "created_utc", "completed_utc",
        "restored_utc", "failure", "status", "target_root", "codex_home",
        "managed_config", "git_config", "git_config_existed_before",
        "git_config_before_sha256", "git_config_after_sha256",
        "git_config_before_snapshot_name", "git_config_before_snapshot_sha256",
        "git_config_after_snapshot_name", "git_config_after_snapshot_sha256",
        "git_hooks_path_before", "git_hooks_path_after",
        "git_hooks_path_before_snapshot_name", "git_hooks_path_before_snapshot_sha256",
        "install_operation_count", "remove_operation_count", "install_projection_sha256",
        "removal_projection_sha256"
    )) {
        $value = if ($Receipt.PSObject.Properties.Name -contains $name) {
            $Receipt.$name
        }
        else { $null }
        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes((ConvertTo-ReceiptIntegrityValue -Value $value))
        )
        $lines.Add($name + "=" + $encoded) | Out-Null
    }
    $directories = if ($Receipt.PSObject.Properties.Name -contains "created_directories") {
        @($Receipt.created_directories)
    }
    else { @() }
    $lines.Add("created_directories.count=" + $directories.Count) | Out-Null
    for ($index = 0; $index -lt $directories.Count; $index++) {
        foreach ($name in @("path", "volume_serial", "file_id")) {
            $encoded = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes(
                    (ConvertTo-ReceiptIntegrityValue -Value $directories[$index].$name)
                )
            )
            $lines.Add(("created_directories[{0}].{1}={2}" -f $index, $name, $encoded)) |
                Out-Null
        }
    }
    $entries = if ($Receipt.PSObject.Properties.Name -contains "entries") {
        @($Receipt.entries)
    }
    else { @() }
    $lines.Add("entries.count=" + $entries.Count) | Out-Null
    for ($entryIndex = 0; $entryIndex -lt $entries.Count; $entryIndex++) {
        foreach ($name in @(
            "action", "destination", "existed", "snapshot_name", "original_sha256",
            "installed_sha256"
        )) {
            $entry = $entries[$entryIndex]
            $value = if ($entry.PSObject.Properties.Name -contains $name) {
                $entry.$name
            }
            else { $null }
            $encoded = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes((ConvertTo-ReceiptIntegrityValue -Value $value))
            )
            $lines.Add(("entries[{0}].{1}={2}" -f $entryIndex, $name, $encoded)) | Out-Null
        }
    }
    return Get-Sha256Text -Text ($lines -join "`n")
}

function Invoke-GitIdentityVars {
    param([AllowNull()][string]$ConfigPath)
    $results = @{}
    $isolatedNames = @(
        "GIT_AUTHOR_NAME",
        "GIT_AUTHOR_EMAIL",
        "GIT_COMMITTER_NAME",
        "GIT_COMMITTER_EMAIL",
        "EMAIL",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_INDEX_FILE",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_NOSYSTEM",
        "GIT_CONFIG_COUNT"
    )
    $savedEnvironment = @{}
    try {
        foreach ($name in $isolatedNames) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
        if ($ConfigPath) {
            [Environment]::SetEnvironmentVariable(
                "GIT_CONFIG_GLOBAL",
                [IO.Path]::GetFullPath($ConfigPath),
                "Process"
            )
        }
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_NOSYSTEM", "1", "Process")
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_COUNT", "0", "Process")
        foreach ($variable in @("GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT")) {
            try {
                $stdout = & git var $variable 2>$null
                $code = $LASTEXITCODE
                $results[$variable] = (
                    $code -eq 0 -and
                    -not [string]::IsNullOrWhiteSpace((@($stdout) -join "`n"))
                )
            }
            catch {
                $results[$variable] = $false
            }
        }
    }
    finally {
        foreach ($name in $isolatedNames) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $savedEnvironment[$name],
                "Process"
            )
        }
    }
    return [pscustomobject]@{
        AuthorUsable = [bool]$results["GIT_AUTHOR_IDENT"]
        CommitterUsable = [bool]$results["GIT_COMMITTER_IDENT"]
    }
}

function Invoke-ReceiptBoundByteVerification {
    param(
        [string]$RollbackPath,
        [string]$MigrationReceiptPath,
        [string]$ExpectedTargetRoot,
        [AllowNull()][string]$ConfigPath
    )
    $process = $null
    $leases = New-Object Collections.Generic.List[object]
    try {
        $receiptLease = Open-TrustedReadLease -Path $MigrationReceiptPath -MaximumBytes 1048576
        $leases.Add($receiptLease) | Out-Null
        if ($receiptLease.Bytes.Length -ge 3 -and
            $receiptLease.Bytes[0] -eq 0xEF -and
            $receiptLease.Bytes[1] -eq 0xBB -and
            $receiptLease.Bytes[2] -eq 0xBF) {
            throw "Migration receipt must not contain a UTF-8 BOM."
        }
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $receipt = $strictUtf8.GetString($receiptLease.Bytes) | ConvertFrom-Json
        $receiptIntegrity = [string]$receipt.receipt_integrity_sha256
        if ($receiptIntegrity -notmatch '^[0-9A-F]{64}$' -or
            $receiptIntegrity -cne (Get-ReceiptIntegritySha256 -Receipt $receipt)) {
            throw "Migration receipt integrity verification failed before rollback execution."
        }
        $targetFull = [IO.Path]::GetFullPath($ExpectedTargetRoot)
        if ([int]$receipt.schema_version -ne 2 -or
            [string]$receipt.steadyagent_version -ne "2.0.1" -or
            [string]$receipt.status -ne "applied" -or
            -not [string]$receipt.completed_utc -or
            $null -ne $receipt.failure -or
            -not [IO.Path]::GetFullPath([string]$receipt.target_root).Equals(
                $targetFull,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Migration receipt is not the applied receipt for the diagnosed target."
        }
        $entries = @($receipt.entries)
        if ($entries.Count -ne 80 -or
            [int]$receipt.install_operation_count -ne 53 -or
            [int]$receipt.remove_operation_count -ne 27 -or
            [string]$receipt.install_projection_sha256 -cne
                "D8FAAE46FF7C2E80E71C3ECC539DE1B9CE9097A0F8EFC2D1E82B25865A857356" -or
            [string]$receipt.removal_projection_sha256 -cne
                "F69BFE5A67AAE53337DE0C1E54D52CDDD1C841EF8528180B1F9F758F94A74582") {
            throw "Migration receipt operation contract is not the frozen V2 contract."
        }

        $expectedFiles = @(
            [pscustomobject]@{
                Label = "rollback"
                Path = [IO.Path]::GetFullPath((Join-Path $targetFull "tools\rollback.ps1"))
            },
            [pscustomobject]@{
                Label = "migration runtime"
                Path = [IO.Path]::GetFullPath((Join-Path $targetFull "tools\migration-runtime.ps1"))
            },
            [pscustomobject]@{
                Label = "bound path policy"
                Path = [IO.Path]::GetFullPath((Join-Path $targetFull "tools\protected-path-policy.ps1"))
            }
        )
        if (-not [IO.Path]::GetFullPath($RollbackPath).Equals(
            [string]$expectedFiles[0].Path,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Rollback path is not the diagnosed target's frozen rollback destination."
        }
        foreach ($expectedFile in $expectedFiles) {
            $matchingEntries = @($entries | Where-Object {
                [string]$_.action -eq "install" -and
                [IO.Path]::GetFullPath([string]$_.destination).Equals(
                    [string]$expectedFile.Path,
                    [StringComparison]::OrdinalIgnoreCase
                )
            })
            if ($matchingEntries.Count -ne 1 -or
                [string]$matchingEntries[0].installed_sha256 -notmatch '^[0-9A-F]{64}$') {
                throw ("Migration receipt has no unique " + $expectedFile.Label + " identity.")
            }
            $lease = Open-TrustedReadLease -Path ([string]$expectedFile.Path)
            $leases.Add($lease) | Out-Null
            if ($lease.SHA256 -cne [string]$matchingEntries[0].installed_sha256) {
                throw ("Installed " + $expectedFile.Label + " bytes do not match the receipt.")
            }
        }

        if ($env:STEADYAGENT_TEST_DIAGNOSE_PARENT_SWAP -eq "1") {
            if ($env:STEADYAGENT_TEST_MODE -ne "1" -or
                [string]::IsNullOrWhiteSpace($env:STEADYAGENT_TEST_ROOT) -or
                [string]::IsNullOrWhiteSpace($env:STEADYAGENT_TEST_DIAGNOSE_PARENT_PARKED)) {
                throw "Diagnose parent-swap injection requires the isolated migration fixture."
            }
            $testRootFull = [IO.Path]::GetFullPath($env:STEADYAGENT_TEST_ROOT).TrimEnd('\') + '\'
            $parentToSwap = [IO.Path]::GetDirectoryName([string]$expectedFiles[0].Path)
            $parkedParent = [IO.Path]::GetFullPath(
                $env:STEADYAGENT_TEST_DIAGNOSE_PARENT_PARKED
            )
            if (-not $parentToSwap.StartsWith(
                    $testRootFull,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                -not $parkedParent.StartsWith(
                    $testRootFull,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                [IO.Directory]::Exists($parkedParent) -or [IO.File]::Exists($parkedParent)) {
                throw "Diagnose parent-swap injection escaped or reused its isolated fixture path."
            }
            $parentSwapBlocked = $false
            try {
                [IO.Directory]::Move($parentToSwap, $parkedParent)
            }
            catch [IO.IOException] {
                $parentSwapBlocked = $true
            }
            catch [UnauthorizedAccessException] {
                $parentSwapBlocked = $true
            }
            if (-not $parentSwapBlocked) {
                [IO.Directory]::Move($parkedParent, $parentToSwap)
                throw "Pinned authority failed to block the diagnose parent-directory swap."
            }
            Write-Host "TEST diagnose parent rename/junction exchange blocked by pinned authority"
        }

        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = Join-Path $PSHOME "powershell.exe"
        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", ([string]$expectedFiles[0].Path),
            "-ReceiptPath", $receiptLease.Path
        )
        if ($ConfigPath) {
            $arguments += @("-GitConfigPath", $ConfigPath)
        }
        $startInfo.Arguments = @($arguments | ForEach-Object {
            '"' + ([string]$_).Replace('"', '\"') + '"'
        }) -join " "
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Receipt-bound byte verification subprocess did not start."
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $passed = (
            $process.ExitCode -eq 0 -and
            $stdout -match '(?m)^STABLE INSTALLED PROJECTION VERIFIED receipt=applied entries=80 pending=0\r?$' -and
            $stdout -match 'DRY-RUN Boring Is All You Need v2[.]0[.]1 rollback: 80 files; 0 writes[.]' -and
            $stdout -notmatch '(?m)^PENDING BOUND RECOVERY '
        )
        return [pscustomobject]@{
            Passed = $passed
            ReceiptCompletedUtc = $(if ($passed) {
                [string]$receipt.completed_utc
            } else {
                $null
            })
            Detail = $(if ($passed) {
                "53 receipt-bound installed hashes plus 27 removal/snapshot operations verified"
            } else {
                ("rollback evidence rejected the installed state: " +
                    (@($stderr.Trim(), $stdout.Trim()) | Where-Object { $_ } | Select-Object -First 1))
            })
        }
    }
    catch {
        return [pscustomobject]@{
            Passed = $false
            ReceiptCompletedUtc = $null
            Detail = $_.Exception.Message
        }
    }
    finally {
        if ($process) { $process.Dispose() }
        for ($index = $leases.Count - 1; $index -ge 0; $index--) {
            $leases[$index].Stream.Dispose()
            $pins = @($leases[$index].DirectoryPins)
            for ($pinIndex = $pins.Count - 1; $pinIndex -ge 0; $pinIndex--) {
                $pins[$pinIndex].Dispose()
            }
        }
    }
}

function Test-ManagedConfig {
    param(
        [string]$Path,
        [string]$ExpectedPath,
        [ValidateSet("WARN", "FAIL")][string]$MissingSeverity
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Result $MissingSeverity "Codex managed config exists" $Path
        return
    }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    Add-Result "PASS" "Codex managed config exists"
    if (-not (Test-Path -LiteralPath $ExpectedPath -PathType Leaf)) {
        Add-Result "FAIL" "rendered expected managed config exists" $ExpectedPath
    }
    else {
        $expectedText = [IO.File]::ReadAllText($ExpectedPath, [Text.Encoding]::UTF8)
        Add-Result $(if ($text -eq $expectedText) { "PASS" } else { "FAIL" }) "active managed config exactly matches the rendered V2 matrix"
    }
    $blocks = ([regex]::Matches($text, '(?m)^\[\[hooks[.][A-Za-z]+[.]hooks\]\]$')).Count
    Add-Result $(if ($blocks -eq 3) { "PASS" } else { "FAIL" }) "exact three managed hook blocks" ("blocks=" + $blocks)
    $preToolUseBlocks = ([regex]::Matches($text, '(?m)^\[\[hooks[.]PreToolUse\]\]$')).Count
    Add-Result $(if (
        $preToolUseBlocks -eq 1 -and
        $text -match 'agent-hook-command-guard[.]ps1\\" -GuardMode Unified' -and
        $text -notmatch 'agent-hook-file-guard[.]ps1'
    ) { "PASS" } else { "FAIL" }) "single unified PreToolUse guard" ("blocks=" + $preToolUseBlocks)
    foreach ($required in @(
        "agent-hook-context[.]ps1",
        "agent-hook-command-guard[.]ps1",
        "agent-hook-precompact[.]ps1"
    )) {
        Add-Result $(if ($text -match $required) { "PASS" } else { "FAIL" }) ("managed config includes " + $required)
    }
    Add-Result $(if ($text -notmatch "UserPromptSubmit|PermissionRequest|PostToolUse") { "PASS" } else { "FAIL" }) "high-frequency lifecycle hooks are absent"
    Add-Result $(if ($text -notmatch "%STEADYAGENT_HOME%") { "PASS" } else { "FAIL" }) "managed paths are rendered"
}

$targetFull = [IO.Path]::GetFullPath($TargetRoot)
$codexFull = [IO.Path]::GetFullPath($CodexHome)
$managedFull = [IO.Path]::GetFullPath($ManagedConfigPath)

Write-Host "Boring Is All You Need v2.0.1 Codex diagnosis"
Write-Host ("TargetRoot: " + $targetFull)
Write-Host ("CodexHome: " + $codexFull)
Write-Host ("ManagedConfigPath: " + $managedFull)

$receiptProvided = -not [string]::IsNullOrWhiteSpace($ReceiptPath)
$validatedReceiptCompletedUtc = $null
if (-not $receiptProvided) {
    Add-Result $(if ($RequireInstalledBytes) { "FAIL" } else { "WARN" }) `
        "receipt-bound exact installed bytes" `
        "pass -ReceiptPath from the successful migration receipt"
}
else {
    $rollbackEvidencePath = Join-Path $targetFull "tools\rollback.ps1"
    if (-not (Test-Path -LiteralPath $rollbackEvidencePath -PathType Leaf)) {
        Add-Result "FAIL" "receipt-bound exact installed bytes" `
            ("missing " + $rollbackEvidencePath)
    }
    else {
        $byteEvidence = Invoke-ReceiptBoundByteVerification `
            -RollbackPath $rollbackEvidencePath `
            -MigrationReceiptPath ([IO.Path]::GetFullPath($ReceiptPath)) `
            -ExpectedTargetRoot $targetFull `
            -ConfigPath $GitConfigPath
        if ($byteEvidence.Passed) {
            $validatedReceiptCompletedUtc = [string]$byteEvidence.ReceiptCompletedUtc
        }
        Add-Result $(if ($byteEvidence.Passed) { "PASS" } else { "FAIL" }) `
            "receipt-bound exact installed bytes" `
            $byteEvidence.Detail
    }
}

if ($env:STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_SOURCE) {
    if ($env:STEADYAGENT_TEST_MODE -ne "1" -or
        [string]::IsNullOrWhiteSpace($env:STEADYAGENT_TEST_ROOT) -or
        [string]::IsNullOrWhiteSpace($env:STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_PARKED) -or
        -not $receiptProvided) {
        throw "Diagnose receipt-swap injection requires the isolated migration fixture."
    }
    $testRootPrefix = [IO.Path]::GetFullPath($env:STEADYAGENT_TEST_ROOT).TrimEnd('\') + '\'
    $verifiedReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
    $replacementReceiptPath = [IO.Path]::GetFullPath(
        $env:STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_SOURCE
    )
    $parkedReceiptPath = [IO.Path]::GetFullPath(
        $env:STEADYAGENT_TEST_DIAGNOSE_RECEIPT_SWAP_PARKED
    )
    foreach ($testSwapPath in @(
        $verifiedReceiptPath,
        $replacementReceiptPath,
        $parkedReceiptPath
    )) {
        if (-not $testSwapPath.StartsWith(
                $testRootPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Diagnose receipt-swap injection escaped its isolated fixture root."
        }
    }
    Assert-TrustedReadPath -Path $verifiedReceiptPath
    Assert-TrustedReadPath -Path $replacementReceiptPath
    if ([IO.File]::Exists($parkedReceiptPath) -or [IO.Directory]::Exists($parkedReceiptPath)) {
        throw "Diagnose receipt-swap parked path already exists."
    }
    [IO.File]::Move($verifiedReceiptPath, $parkedReceiptPath)
    [IO.File]::Move($replacementReceiptPath, $verifiedReceiptPath)
    Write-Host "TEST diagnose receipt swapped after verified rollback child"
}

$frozenInstalledPowerShellAssets = [string[]]@(
    "tools/diagnose-install.ps1",
    "tools/git-checkpoint.ps1",
    "tools/git-hooks/pre-commit-check.ps1",
    "tools/git-preflight.ps1",
    "tools/hooks/agent-hook-command-guard.ps1",
    "tools/hooks/agent-hook-context.ps1",
    "tools/hooks/agent-hook-file-guard.ps1",
    "tools/hooks/agent-hook-precompact.ps1",
    "tools/hooks/agent-hook-utils.ps1",
    "tools/hooks/pre-commit.ps1",
    "tools/migration-runtime.ps1",
    "tools/protected-path-policy.ps1",
    "tools/rollback.ps1",
    "tools/skill-catalog-resolver.ps1",
    "tools/skill-index.ps1",
    "tools/skill-search.ps1",
    "tools/test-agent-hooks.ps1",
    "tools/test-git-checkpoint.ps1",
    "tools/test-pre-commit.ps1",
    "tools/test-protected-path-policy.ps1",
    "tools/test-skill-catalog.ps1"
)
$inventoryProjection = [string[]]@($frozenInstalledPowerShellAssets)
[Array]::Sort($inventoryProjection, [StringComparer]::OrdinalIgnoreCase)
$inventoryHash = Get-Sha256Text -Text ($inventoryProjection -join "`n")
$inventoryFrozen = (
    $inventoryProjection.Count -eq 21 -and
    $inventoryHash -ceq "07293B0C5EC16359C3A83677FE0AF89E32D3A76AB96CFAA51B891D908EF6914B"
)
Add-Result $(if ($inventoryFrozen) { "PASS" } else { "FAIL" }) `
    "installed PowerShell asset set is frozen" `
    ("count=" + $inventoryProjection.Count)
foreach ($relative in $inventoryProjection) {
    $assetPath = Join-Path $targetFull $relative
    $exists = Test-Path -LiteralPath $assetPath -PathType Leaf
    Add-Result $(if ($exists) { "PASS" } else { "FAIL" }) ("installed PowerShell asset: " + $relative)
    if (-not $exists) { continue }
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $assetPath,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    Add-Result $(if ($parseErrors.Count -eq 0) { "PASS" } else { "FAIL" }) `
        ("PowerShell syntax: " + $relative) `
        ("errors=" + $parseErrors.Count)
}

Test-File "Codex AGENTS installed" (Join-Path $codexFull "AGENTS.md")
Test-File "Codex user hooks installed" (Join-Path $codexFull "hooks.json")
Test-File "workflow rule installed" (Join-Path $targetFull "rules\workflow-routing.md")
Test-File "review rule installed" (Join-Path $targetFull "rules\review-gates.md")
Test-File "safety rule installed" (Join-Path $targetFull "rules\safety-boundaries.md")
Test-File "lessons index source installed" (Join-Path $targetFull "rules\lessons.md")
Test-File "Harness guide installed" (Join-Path $targetFull "rules\HARNESS-GUIDE.md")
Test-File "Harness review contract installed" (Join-Path $targetFull "rules\harness-review.md")
Test-File "workflow skill installed" (Join-Path $codexFull "skills\steadyagent-workflow\SKILL.md")
foreach ($hook in @(
    "agent-hook-utils.ps1",
    "agent-hook-context.ps1",
    "agent-hook-command-guard.ps1",
    "agent-hook-file-guard.ps1",
    "agent-hook-precompact.ps1"
)) {
    Test-File ("hook installed: " + $hook) (Join-Path $targetFull ("tools\hooks\" + $hook))
}

$contextHookPath = Join-Path $targetFull "tools\hooks\agent-hook-context.ps1"
$agentsPath = Join-Path $codexFull "AGENTS.md"
if ((Test-Path -LiteralPath $contextHookPath -PathType Leaf) -and
    (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
    $contextText = [IO.File]::ReadAllText($contextHookPath, [Text.Encoding]::UTF8)
    $agentsText = [IO.File]::ReadAllText($agentsPath, [Text.Encoding]::UTF8)
    Add-Result $(if (
        $contextText -match "Caveman startup status report" -and
        $contextText -match "first assistant response" -and
        $contextText -match "mode = `"lite`"" -and
        $agentsText -match "Caveman.*lite"
    ) { "PASS" } else { "FAIL" }) "Caveman lite startup contract is installed"
    Add-Result $(if (
        $contextText -match "Known pitfalls to avoid" -and
        $contextText -match "HARNESS-REVIEW DUE" -and
        $contextText -match "[.]harness-last-review"
    ) { "PASS" } else { "FAIL" }) "lessons and periodic Harness review injection are installed"
}

$reviewRulePath = Join-Path $targetFull "rules\review-gates.md"
$skillRulePath = Join-Path $targetFull "rules\skill-routing.md"
$maintenancePath = Join-Path $targetFull "rules\harness-review.md"
if ((Test-Path -LiteralPath $reviewRulePath -PathType Leaf) -and
    (Test-Path -LiteralPath $skillRulePath -PathType Leaf) -and
    (Test-Path -LiteralPath $maintenancePath -PathType Leaf)) {
    $reviewText = [IO.File]::ReadAllText($reviewRulePath, [Text.Encoding]::UTF8)
    $skillText = [IO.File]::ReadAllText($skillRulePath, [Text.Encoding]::UTF8)
    $maintenanceText = [IO.File]::ReadAllText($maintenancePath, [Text.Encoding]::UTF8)
    Add-Result $(if (
        $reviewText -match "File count alone is not a trigger" -and
        $reviewText -match "material risk" -and
        $skillText -match "Ordinary tasks do not search" -and
        $skillText -match "require explicit user invocation" -and
        $maintenanceText -match "three to six months" -and
        $maintenanceText -match "180 days" -and
        $maintenanceText -match "[.]harness-last-review"
    ) { "PASS" } else { "FAIL" }) "review, skill, and periodic maintenance contracts are consistent"
}
Test-File "protected path policy installed" (Join-Path $targetFull "tools\protected-path-policy.ps1")
Test-File "rollback tool installed" (Join-Path $targetFull "tools\rollback.ps1")
foreach ($catalogTool in @(
    "skill-catalog-resolver.ps1",
    "skill-index.ps1",
    "skill-search.ps1",
    "test-skill-catalog.ps1",
    "test-protected-path-policy.ps1"
)) {
    Test-File ("catalog/equivalence tool installed: " + $catalogTool) (Join-Path $targetFull ("tools\" + $catalogTool))
}
Test-File "pre-commit entrypoint installed" (Join-Path $targetFull "tools\git-hooks\pre-commit")
Test-File "pre-commit guard installed" (Join-Path $targetFull "tools\git-hooks\pre-commit-check.ps1")
$preCommitEntrypoint = Join-Path $targetFull "tools\git-hooks\pre-commit"
if (Test-Path -LiteralPath $preCommitEntrypoint -PathType Leaf) {
    $preCommitBytes = [IO.File]::ReadAllBytes($preCommitEntrypoint)
    $preCommitText = [Text.Encoding]::UTF8.GetString($preCommitBytes)
    $preCommitFormatValid = (
        $preCommitBytes.Length -ge 2 -and
        -not ($preCommitBytes.Length -ge 3 -and
            $preCommitBytes[0] -eq 0xEF -and
            $preCommitBytes[1] -eq 0xBB -and
            $preCommitBytes[2] -eq 0xBF) -and
        $preCommitText.StartsWith("#!/bin/sh`n", [StringComparison]::Ordinal) -and
        $preCommitText -notmatch "`r"
    )
    Add-Result $(if ($preCommitFormatValid) { "PASS" } else { "FAIL" }) `
        "pre-commit entrypoint is LF without BOM"
}
$legacyManifest = Join-Path $targetFull "manifests\v1-codex-owned-files.txt"
Test-File "V1-owned file manifest installed" $legacyManifest
$equivalenceManifest = Join-Path $targetFull "manifests\local-postimage-equivalence.json"
Test-File "23-item local equivalence manifest installed" $equivalenceManifest
if (Test-Path -LiteralPath $equivalenceManifest -PathType Leaf) {
    try {
        $equivalence = Get-Content -LiteralPath $equivalenceManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-Result $(if (@($equivalence.entries).Count -eq 23) { "PASS" } else { "FAIL" }) `
            "local equivalence manifest maps all 23 entries" ("count=" + @($equivalence.entries).Count)
        Add-Result $(if ([string]$equivalence.localPostimageManifestSha256 -eq "A76846A184673C176F2FE2FE22B14835D216CA79824CB2F0ABF583B0F91D89FF") { "PASS" } else { "FAIL" }) `
            "local equivalence manifest identity is frozen"
        $installedAssetRecords = @($equivalence.entries) + @($equivalence.supportInstalls)
        $installedAssetProjection = New-Object Collections.Generic.List[string]
        $installedAssetPaths = New-Object Collections.Generic.List[object]
        $seenInstalledDestinations = @{}
        foreach ($asset in $installedAssetRecords) {
            $declaredDestination = [string]$asset.installedDestination
            $role = ""
            $relative = ""
            $assetPath = ""
            if ($declaredDestination -ceq "@managedConfig") {
                $role = "managed"
                $relative = "requirements.toml"
                $assetPath = $managedFull
            }
            elseif ($declaredDestination.StartsWith("@codex/", [StringComparison]::Ordinal)) {
                $role = "codex"
                $relative = $declaredDestination.Substring(7)
                $assetPath = Join-Path $codexFull $relative
            }
            else {
                if (-not $declaredDestination -or
                    [IO.Path]::IsPathRooted($declaredDestination) -or
                    $declaredDestination -match '(^|[\\/])[.][.]([\\/]|$)') {
                    throw ("Unsafe installed destination in equivalence manifest: " + $declaredDestination)
                }
                $role = "target"
                $relative = $declaredDestination
                $assetPath = Join-Path $targetFull $relative
            }
            $relative = $relative.Replace('\', '/')
            $destinationKey = ($role + "|" + $relative).ToLowerInvariant()
            if ($seenInstalledDestinations.ContainsKey($destinationKey)) {
                throw ("Duplicate installed destination in equivalence manifest: " + $declaredDestination)
            }
            $seenInstalledDestinations[$destinationKey] = $true
            $installedAssetProjection.Add("install|" + $role + "|" + $relative) | Out-Null
            $installedAssetPaths.Add([pscustomobject]@{
                Declared = $declaredDestination
                Path = [IO.Path]::GetFullPath($assetPath)
            }) | Out-Null
        }
        $sortedInstalledAssetProjection = [string[]]@($installedAssetProjection.ToArray())
        [Array]::Sort($sortedInstalledAssetProjection, [StringComparer]::OrdinalIgnoreCase)
        $installedAssetProjectionSha256 = Get-Sha256Text -Text (
            $sortedInstalledAssetProjection -join "`n"
        )
        $installedAssetContractFrozen = (
            @($equivalence.entries).Count -eq 23 -and
            @($equivalence.supportInstalls).Count -eq 30 -and
            $installedAssetPaths.Count -eq 53 -and
            $installedAssetProjectionSha256 -ceq
                "D8FAAE46FF7C2E80E71C3ECC539DE1B9CE9097A0F8EFC2D1E82B25865A857356"
        )
        Add-Result $(if ($installedAssetContractFrozen) { "PASS" } else { "FAIL" }) `
            "complete installed asset set is frozen" `
            ("count=" + $installedAssetPaths.Count)
        foreach ($installedAsset in @($installedAssetPaths.ToArray())) {
            Test-File ("installed asset: " + [string]$installedAsset.Declared) `
                ([string]$installedAsset.Path)
        }
    }
    catch {
        Add-Result "FAIL" "local equivalence manifest parses" $_.Exception.Message
    }
}
$expectedManagedConfig = Join-Path $targetFull "manifests\codex-requirements.expected.toml"
Test-File "rendered expected managed config installed" $expectedManagedConfig
if (Test-Path -LiteralPath $legacyManifest -PathType Leaf) {
    foreach ($relative in @([IO.File]::ReadAllLines($legacyManifest, [Text.Encoding]::UTF8))) {
        if (-not $relative.Trim()) { continue }
        $removedPath = Join-Path $codexFull $relative.Trim()
        Add-Result $(if (-not (Test-Path -LiteralPath $removedPath)) { "PASS" } else { "FAIL" }) ("V1-owned Codex file absent: " + $relative.Trim())
    }
}

$hooksJsonPath = Join-Path $codexFull "hooks.json"
if (Test-Path -LiteralPath $hooksJsonPath -PathType Leaf) {
    try {
        $hooksData = [IO.File]::ReadAllText($hooksJsonPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $hookPropertyCount = if ($hooksData.PSObject.Properties.Name -contains "hooks") {
            @($hooksData.hooks.PSObject.Properties).Count
        }
        else { -1 }
        Add-Result $(if ($hookPropertyCount -eq 0) { "PASS" } else { "FAIL" }) "Codex user hooks are empty"
    }
    catch { Add-Result "FAIL" "Codex user hooks parse as JSON" $_.Exception.Message }
}

$activeSeverity = if ($RequireHooksActive) { "FAIL" } else { "WARN" }
Test-ManagedConfig -Path $managedFull -ExpectedPath $expectedManagedConfig -MissingSeverity $activeSeverity

$expectedHooksPath = Join-Path $targetFull "tools\git-hooks"
if ($GitConfigPath) {
    $activeHooksPath = & git config --file $GitConfigPath --get core.hooksPath
}
else {
    $activeHooksPath = & git config --global --get core.hooksPath
}
$gitHooksActive = $LASTEXITCODE -eq 0 -and
    [string]$activeHooksPath -and
    ([string]$activeHooksPath).Equals($expectedHooksPath, [StringComparison]::OrdinalIgnoreCase)
Add-Result $(if ($gitHooksActive) { "PASS" } else { $activeSeverity }) "Git pre-commit path is active" ([string]$activeHooksPath)

if ($RequireRuntimeCatalog) {
    try {
        if ([string]::IsNullOrWhiteSpace($validatedReceiptCompletedUtc)) {
            throw "A successful migration receipt is required before checking installed rollout-file evidence."
        }
        . (Join-Path $targetFull "tools\skill-catalog-resolver.ps1")
        $catalogThread = [string]$env:CODEX_THREAD_ID
        $catalogRoot = Join-Path $targetFull "runtime-skill-catalogs"
        $expectedCatalog = Resolve-RolloutFileCatalogSnapshot `
            -HostSurface "Auto" `
            -ThreadId $catalogThread `
            -CatalogRoot $catalogRoot
        Assert-CatalogSessionStartedAfterReceipt `
            -SessionStartedUtc ([string]$expectedCatalog.SessionStartedUtc) `
            -ReceiptCompletedUtc $validatedReceiptCompletedUtc
        $rolloutFileConsistent = Test-RolloutFileCatalogSnapshot -Expected $expectedCatalog
        Add-Result $(if ($rolloutFileConsistent) { "PASS" } else { "FAIL" }) `
            "current task rollout-file-confirmed catalog is internally consistent" `
            $expectedCatalog.SnapshotId
    }
    catch {
        Add-Result "FAIL" "current task rollout-file-confirmed catalog is internally consistent" $_.Exception.Message
    }
    Add-Result "WARN" "manual Codex Live acceptance is still required" `
        "Restart Codex Desktop, open a real new task, and observe SessionStart plus one controlled Hook behavior; rollout/config files cannot prove Live activation."
}

$identitySeverity = if ($RequireGitIdentity) { "FAIL" } else { "WARN" }
if ($GitConfigPath) {
    $gitName = & git config --file $GitConfigPath --get user.name
    $gitEmail = & git config --file $GitConfigPath --get user.email
}
else {
    $gitName = & git config --global --get user.name
    $gitEmail = & git config --global --get user.email
}
$gitName = if ($null -eq $gitName) { "" } else { ([string]$gitName).Trim() }
$gitEmail = if ($null -eq $gitEmail) { "" } else { ([string]$gitEmail).Trim() }
$gitNameValid = (
    -not [string]::IsNullOrWhiteSpace($gitName) -and
    $gitName -notmatch '[<>\x00-\x1F\x7F]'
)
$gitEmailValid = (
    -not [string]::IsNullOrWhiteSpace($gitEmail) -and
    $gitEmail -match '^[^<>\s@]+@[^<>\s@]+$'
)
Add-Result $(if ($gitNameValid) { "PASS" } else { $identitySeverity }) "Git user.name is configured"
Add-Result $(if ($gitEmailValid) { "PASS" } else { $identitySeverity }) "Git user.email is configured"
$gitIdentityVars = Invoke-GitIdentityVars -ConfigPath $GitConfigPath
Add-Result $(if ($gitNameValid -and $gitEmailValid -and $gitIdentityVars.AuthorUsable) {
    "PASS"
} else {
    $identitySeverity
}) "Git author identity is usable"
Add-Result $(if ($gitNameValid -and $gitEmailValid -and $gitIdentityVars.CommitterUsable) {
    "PASS"
} else {
    $identitySeverity
}) "Git committer identity is usable"

if ($SkipSmoke) {
    Add-Result "WARN" "installed hook smoke" "skipped"
}
else {
    $smoke = Join-Path $targetFull "tools\test-agent-hooks.ps1"
    if (-not (Test-Path -LiteralPath $smoke -PathType Leaf)) {
        Add-Result "FAIL" "installed hook smoke" ("missing " + $smoke)
    }
    else {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $smoke
        $code = $LASTEXITCODE
        Add-Result $(if ($code -eq 0 -and ($output | Out-String) -match "fail=0") { "PASS" } else { "FAIL" }) "installed hook smoke" ($output | Out-String).Trim()
    }
}

Write-Host ("RESULT pass={0} warn={1} fail={2}" -f $script:Passed, $script:Warned, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

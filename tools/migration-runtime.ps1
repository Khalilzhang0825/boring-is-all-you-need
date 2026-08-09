#requires -Version 7.5
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

function ConvertTo-ReceiptIntegrityValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "<null>" }
    if ($Value -is [bool]) { return $(if ([bool]$Value) { "true" } else { "false" }) }
    return [string]$Value
}

function Get-ActiveReceiptPointerIntegritySha256 {
    param([object]$Pointer)
    $receipts = @($Pointer.receipts)
    $lines = @(
        "schema_version=" + [string]$Pointer.schema_version,
        "target_root=" + [string]$Pointer.target_root,
        "receipts.count=" + $receipts.Count
    )
    for ($index = 0; $index -lt $receipts.Count; $index++) {
        $lines += "receipts[$index].path=" + [string]$receipts[$index].path
        $lines += "receipts[$index].sha256=" + [string]$receipts[$index].sha256
    }
    return Get-Sha256Text -Text ($lines -join "`n")
}

function Get-ActiveReceiptPointerPath {
    param([string]$TargetRoot)
    $targetFull = [IO.Path]::GetFullPath($TargetRoot)
    $token = (Get-Sha256Text -Text $targetFull.ToUpperInvariant()).Substring(0, 20).ToLowerInvariant()
    return Join-Path (Split-Path -Parent $targetFull) (".steadyagent-active-receipt-" + $token + ".json")
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
        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes((ConvertTo-ReceiptIntegrityValue -Value $value))
        )
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

function Get-SortedProjectionSha256 {
    param([string[]]$Projection)
    $sorted = [string[]]@($Projection)
    [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
    return Get-Sha256Text -Text ($sorted -join "`n")
}

function Invoke-TestHardKill {
    param([string]$Point)
    if ($env:STEADYAGENT_TEST_MODE -ne "1") {
        throw "Hard-kill injection is available only in the isolated migration test."
    }
    [Console]::Out.Flush()
    [Console]::Error.Flush()
    [Diagnostics.Process]::GetCurrentProcess().Kill()
    [Environment]::FailFast("SteadyAgent test hard kill at " + $Point)
}

function Test-IsProcessElevated {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PathTreeOverlap {
    param([string]$First, [string]$Second)
    if ($First.Equals($Second, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $firstPrefix = $First.TrimEnd('\') + '\'
    $secondPrefix = $Second.TrimEnd('\') + '\'
    return (
        $First.StartsWith($secondPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $Second.StartsWith($firstPrefix, [StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-PathWithinRoot {
    param([string]$Path, [string]$Root)
    $pathFull = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)
}

function Write-MigrationReceipt {
    param([object]$Receipt, [string]$Path)
    $Receipt.receipt_integrity_sha256 = Get-ReceiptIntegritySha256 -Receipt $Receipt
    Write-Utf8NoBomAtomic -Path $Path -Text (($Receipt | ConvertTo-Json -Depth 7) + "`n")
}

function Write-Utf8NoBomAtomic {
    param([string]$Path, [string]$Text)
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    $existingHash = if (Test-Path -LiteralPath $Path -PathType Leaf) {
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    else { $null }
    Invoke-SteadyAgentBoundAtomicWrite `
        -Destination $Path `
        -Bytes $bytes `
        -ExpectedCurrentSHA256 $existingHash `
        -RequireMissing:(!$existingHash)
    if ((Get-Sha256Bytes -Bytes ([IO.File]::ReadAllBytes($Path))) -cne
        (Get-Sha256Bytes -Bytes $bytes)) {
        throw ("Durable receipt readback verification failed: " + $Path)
    }
}

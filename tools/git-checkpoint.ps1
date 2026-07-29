[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [string[]]$Files,

    [switch]$All,

    [switch]$DryRun,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    . (Join-Path $PSScriptRoot 'protected-path-policy.ps1')
}
catch {
    [Console]::Error.WriteLine("Cannot load protected path policy; checkpoint is blocked.")
    exit 2
}

function Stop-WithMessage {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
    exit 2
}

function Invoke-GitQuiet {
    param([string[]]$GitArgs)

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & git @GitArgs 2>$null
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    [PSCustomObject]@{
        Output = $output
        Code = $code
    }
}

function Get-TextHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace("-", "")
    } finally { $sha.Dispose() }
}

function Get-FileHashHex {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Set-IndexPathsFromCommit {
    param([string]$Commit, [string[]]$Paths)
    foreach ($path in $Paths) {
        $entry = @(& git ls-tree $Commit -- $path)
        if ($LASTEXITCODE -ne 0) { return $false }
        if ($entry.Count -eq 0) {
            & git update-index --force-remove -- $path
        } elseif ($entry.Count -eq 1 -and $entry[0] -match '^([0-9]{6})\s+[a-z]+\s+([0-9a-f]+)\t') {
            & git update-index --add --cacheinfo $Matches[1] $Matches[2] $path
        } else {
            return $false
        }
        if ($LASTEXITCODE -ne 0) { return $false }
    }
    return $true
}

$problemTag = ([string][char]0x3010) + ([string][char]0x95EE) + ([string][char]0x9898) + ([string][char]0x63CF) + ([string][char]0x8FF0) + ([string][char]0x3011)
$reproTag = ([string][char]0x3010) + ([string][char]0x590D) + ([string][char]0x73B0) + ([string][char]0x8DEF) + ([string][char]0x5F84) + ([string][char]0x3011)
$fixTag = ([string][char]0x3010) + ([string][char]0x4FEE) + ([string][char]0x590D) + ([string][char]0x601D) + ([string][char]0x8DEF) + ([string][char]0x3011)
$requiredTags = @($problemTag, $reproTag, $fixTag)

$hasRequiredTag = $false
foreach ($tag in $requiredTags) {
    if ($Message.Contains($tag)) {
        $hasRequiredTag = $true
        break
    }
}

if (-not $hasRequiredTag) {
    $Message = $problemTag + " " + $Message
}

if ($RemainingFiles -and $RemainingFiles.Count -gt 0) {
    if (-not $Files) {
        $Files = @()
    }
    $Files += $RemainingFiles
}

if ($All -and $Files -and $Files.Count -gt 0) {
    Stop-WithMessage "Use either -All or -Files, not both."
}

$rootResult = Invoke-GitQuiet @("rev-parse", "--show-toplevel")
$root = $rootResult.Output
if ($rootResult.Code -ne 0 -or -not $root) {
    Stop-WithMessage "Current directory is not inside a Git repository."
}
if ($env:GIT_INDEX_FILE) {
    Stop-WithMessage "Refusing to run with a caller-supplied GIT_INDEX_FILE."
}
$injectIndexPublicationFailure = $false
if ($env:STEADYAGENT_TEST_INDEX_PUBLICATION_FAILURE) {
    if ($env:STEADYAGENT_TEST_MODE -ne "1") {
        Stop-WithMessage "Test-only index publication failure requires STEADYAGENT_TEST_MODE=1."
    }
    $injectIndexPublicationFailure = $true
}

$checkpointMutex = $null
$checkpointLockTaken = $false
$tempIndex = $null
$publishIndex = $null
$messageFile = $null
$realIndexPath = $null
$realIndexHash = $null
$indexLockPath = $null
$indexBackupPath = $null
$indexLockStream = $null
$preserveIndexLock = $false
Push-Location $root
try {
    $lockHash = Get-TextHash -Text ([IO.Path]::GetFullPath($root).ToLowerInvariant())
    $checkpointMutex = New-Object Threading.Mutex($false, ("Local\CodexCheckpoint_" + $lockHash))
    try { $checkpointLockTaken = $checkpointMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $checkpointLockTaken = $true }
    if (-not $checkpointLockTaken) {
        Stop-WithMessage "Another checkpoint transaction already holds the repository lock."
    }

    $status = (& git status --porcelain)
    if (-not $status) {
        Write-Host "[OK] No changes to commit."
        exit 0
    }

    $preExistingStaged = @(& git -c core.quotepath=false diff --cached --name-only --ita-visible-in-index)
    $unmerged = @(& git diff --name-only --diff-filter=U)
    if ($preExistingStaged.Count -gt 0 -or $unmerged.Count -gt 0) {
        Write-Host "[BLOCKED] Existing staged changes belong to the caller and will not be committed or unstaged:"
        $preExistingStaged | ForEach-Object { Write-Host "  $_" }
        $unmerged | ForEach-Object { Write-Host ("  unresolved: " + $_) }
        Stop-WithMessage "Resolve or clear the existing index explicitly before creating a checkpoint."
    }

    if (-not $DryRun) {
        $oldHead = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $oldHead) { Stop-WithMessage "Cannot resolve the current HEAD." }
        $realIndexPath = (& git rev-parse --path-format=absolute --git-path index).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $realIndexPath) { Stop-WithMessage "Cannot resolve the repository index path." }
        if (-not (Test-Path -LiteralPath $realIndexPath -PathType Leaf)) {
            Stop-WithMessage "Cannot bind checkpoint publication because the real index does not exist."
        }
        $realIndexHash = Get-FileHashHex -Path $realIndexPath
        $tempIndex = Join-Path ([IO.Path]::GetTempPath()) ("agent-checkpoint-index-" + [guid]::NewGuid().ToString("N"))
        $env:GIT_INDEX_FILE = $tempIndex
        & git read-tree $oldHead
        if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Cannot initialize the isolated checkpoint index." }
    }

    if ($All) {
        Write-Host "[INFO] Staging all changes because -All was provided."
        if (-not $DryRun) {
            & git add -A
            if ($LASTEXITCODE -ne 0) { Stop-WithMessage "git add failed in the isolated checkpoint index." }
        }
    }
    elseif ($Files -and $Files.Count -gt 0) {
        $validatedFiles = New-Object System.Collections.Generic.List[string]
        foreach ($path in $Files) {
            if (-not $path -or $path -eq "." -or [IO.Path]::IsPathRooted($path) -or $path.IndexOfAny(@([char]'*', [char]'?', [char]'[')) -ge 0) {
                Stop-WithMessage ("Refusing non-literal or non-relative scope in -Files: " + $path)
            }
            $fullPath = [IO.Path]::GetFullPath((Join-Path $root $path))
            $rootBoundary = [IO.Path]::GetFullPath($root).TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
            if (-not $fullPath.StartsWith($rootBoundary, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-WithMessage ("Refusing repository-external path in -Files: " + $path)
            }
            if (Test-Path -LiteralPath $path -PathType Container) {
                Stop-WithMessage ("Refusing directory scope in -Files: " + $path)
            }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $trackedResult = Invoke-GitQuiet @("ls-files", "--error-unmatch", "--", $path)
                if ($trackedResult.Code -ne 0) {
                    Stop-WithMessage ("Explicit file does not exist and is not a tracked deletion: " + $path)
                }
            }
            $relativePath = $fullPath.Substring($rootBoundary.Length) -replace "\\", "/"
            if (-not $validatedFiles.Contains($relativePath)) { $validatedFiles.Add($relativePath) }
        }
        $Files = @($validatedFiles)
        Write-Host "[INFO] Staging explicit files:"
        $Files | ForEach-Object { Write-Host "  $_" }
        if (-not $DryRun) {
            & git add -- @Files
            if ($LASTEXITCODE -ne 0) {
                Stop-WithMessage "git add failed; checkpoint was not created."
            }
        }
    }
    else {
        Write-Host "[INFO] Changed files:"
        & git status --short
        Stop-WithMessage "Refusing to commit without explicit -Files or user-approved -All."
    }

    if ($DryRun) {
        $staged = @()
        if ($All) {
            $statusLines = @(& git -c core.quotepath=false status --porcelain)
            foreach ($line in $statusLines) {
                if ($line.Length -ge 4) { $staged += $line.Substring(3) }
            }
        } else {
            foreach ($path in $Files) {
                if (@(& git -c core.quotepath=false status --porcelain -- $path).Count -gt 0) { $staged += $path }
            }
        }
        $staged = @($staged | Sort-Object -Unique)
    } else {
        $staged = @(& git -c core.quotepath=false diff --cached --name-only)
    }
    if (-not $staged) {
        Write-Host "[OK] No staged changes."
        exit 0
    }

    $blocked = @()
    foreach ($path in $staged) {
        $protectedReason = Get-ProtectedPathReason -Path $path
        if ($protectedReason) {
            $blocked += "$path ($protectedReason)"
            continue
        }

        $full = Join-Path $root $path
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $item = Get-Item -LiteralPath $full
            if ($item.Length -gt 25MB) {
                $blocked += ("{0} ({1:N1} MB)" -f $path, ($item.Length / 1MB))
            }
        }
    }

    if ($blocked.Count -gt 0) {
        Write-Host "[BLOCKED] Refusing to commit risky files:"
        $blocked | ForEach-Object { Write-Host "  $_" }
        exit 2
    }

    Write-Host "[INFO] Staged files:"
    $staged | ForEach-Object { Write-Host "  $_" }

    $stagedArr = @($staged)
    $highRisk = @($stagedArr | Where-Object { $_ -match "(?i)(auth|login|payment|migrat|secret|crypto|password|\.env|permission|deploy|release)" })
    if ($highRisk.Count -gt 0) {
        Write-Host ""
        Write-Host "[REVIEW?] High-risk path detected -- confirm review-gates.md was satisfied before committing."
        Write-Host ""
    }

    if ($DryRun) {
        Write-Host "[DRY-RUN] Commit skipped."
        exit 0
    }

    $expectedPaths = @($stagedArr | Sort-Object -Unique)
    & git hook run --ignore-missing pre-commit
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $postHookPaths = @(& git -c core.quotepath=false diff --cached --name-only | Sort-Object -Unique)
    $scopeDrift = @(Compare-Object -ReferenceObject $expectedPaths -DifferenceObject $postHookPaths)
    if ($scopeDrift.Count -gt 0) {
        [Console]::Error.WriteLine("Pre-commit changed the checkpoint path scope; refusing to create a commit.")
        exit 2
    }

    $tree = (& git write-tree).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $tree) { Stop-WithMessage "Cannot write the isolated checkpoint tree." }
    $messageFile = Join-Path ([IO.Path]::GetTempPath()) ("agent-checkpoint-message-" + [guid]::NewGuid().ToString("N") + ".txt")
    [IO.File]::WriteAllText($messageFile, $Message, (New-Object Text.UTF8Encoding($false)))
    $newCommit = (& git commit-tree $tree -p $oldHead -F $messageFile).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $newCommit) { Stop-WithMessage "Cannot create the checkpoint commit object." }

    $publishIndex = Join-Path ([IO.Path]::GetTempPath()) ("agent-checkpoint-publish-index-" + [guid]::NewGuid().ToString("N"))
    [IO.File]::Copy($realIndexPath, $publishIndex, $false)
    $env:GIT_INDEX_FILE = $publishIndex
    if (-not (Set-IndexPathsFromCommit -Commit $newCommit -Paths $expectedPaths)) {
        Stop-WithMessage "Cannot construct the complete checkpoint index for publication."
    }

    $env:GIT_INDEX_FILE = $realIndexPath
    if ($env:STEADYAGENT_TEST_INDEX_MUTATION_PATH) {
        if ($env:STEADYAGENT_TEST_MODE -ne "1") {
            Stop-WithMessage "Test-only index mutation requires STEADYAGENT_TEST_MODE=1."
        }
        & git add -- $env:STEADYAGENT_TEST_INDEX_MUTATION_PATH
        if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Test-only index mutation failed." }
    }

    $indexLockPath = $realIndexPath + ".lock"
    $indexBackupPath = $realIndexPath + ".steadyagent-" + [guid]::NewGuid().ToString("N") + ".backup"
    try {
        $indexLockStream = [IO.File]::Open(
            $indexLockPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
    }
    catch {
        Stop-WithMessage "The Git index is busy; checkpoint publication was not attempted."
    }

    $currentIndexHash = Get-FileHashHex -Path $realIndexPath
    $currentHead = (& git rev-parse HEAD).Trim()
    $foreignStaged = @(& git -c core.quotepath=false diff --cached --name-only --ita-visible-in-index)
    $foreignUnmerged = @(& git diff --name-only --diff-filter=U)
    if ($currentIndexHash -ne $realIndexHash -or $currentHead -ne $oldHead -or
        $foreignStaged.Count -gt 0 -or $foreignUnmerged.Count -gt 0) {
        [Console]::Error.WriteLine("Repository HEAD or real index changed during the checkpoint transaction; commit was not attached.")
        exit 2
    }

    $publishBytes = [IO.File]::ReadAllBytes($publishIndex)
    $indexLockStream.Write($publishBytes, 0, $publishBytes.Length)
    $indexLockStream.Flush($true)
    $indexLockStream.Dispose()
    $indexLockStream = $null

    & git update-ref -m "agent checkpoint" HEAD $newCommit $oldHead
    if ($LASTEXITCODE -ne 0) { Stop-WithMessage "HEAD changed before checkpoint publication; commit was not attached." }
    try {
        if ($injectIndexPublicationFailure) {
            throw "Injected index publication failure."
        }
        [IO.File]::Replace($indexLockPath, $realIndexPath, $indexBackupPath)
    }
    catch {
        & git update-ref -m "rollback failed checkpoint index publication" HEAD $oldHead $newCommit
        $headRollbackCode = $LASTEXITCODE
        if ($headRollbackCode -ne 0) {
            $preserveIndexLock = $true
            [Console]::Error.WriteLine("Checkpoint index publication failed and HEAD rollback CAS also failed; index.lock was preserved for recovery.")
            exit 4
        }
        [Console]::Error.WriteLine("Checkpoint commit publication was rolled back because the complete index could not be published.")
        exit 3
    }
    if (Test-Path -LiteralPath $indexBackupPath) {
        Remove-Item -LiteralPath $indexBackupPath -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $indexBackupPath)) {
        $indexBackupPath = $null
    }
    else {
        [Console]::Error.WriteLine("Checkpoint succeeded, but the recoverable old-index backup could not be removed.")
    }

    Write-Host "[OK] Checkpoint commit created."

    Write-Host ""
    Write-Host "[REFLECT?] Record only recurring, generalizable pitfalls in the project's maintained lessons file."
}
finally {
    if ($env:GIT_INDEX_FILE) { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
    if ($null -ne $indexLockStream) { $indexLockStream.Dispose() }
    if ($indexLockPath -and -not $preserveIndexLock -and (Test-Path -LiteralPath $indexLockPath)) {
        Remove-Item -LiteralPath $indexLockPath -Force -ErrorAction SilentlyContinue
    }
    if ($indexBackupPath -and -not $preserveIndexLock -and (Test-Path -LiteralPath $indexBackupPath)) {
        Remove-Item -LiteralPath $indexBackupPath -Force -ErrorAction SilentlyContinue
    }
    if ($tempIndex -and (Test-Path -LiteralPath $tempIndex)) { Remove-Item -LiteralPath $tempIndex -Force -ErrorAction SilentlyContinue }
    if ($publishIndex -and (Test-Path -LiteralPath $publishIndex)) { Remove-Item -LiteralPath $publishIndex -Force -ErrorAction SilentlyContinue }
    if ($messageFile -and (Test-Path -LiteralPath $messageFile)) { Remove-Item -LiteralPath $messageFile -Force -ErrorAction SilentlyContinue }
    if ($checkpointLockTaken -and $null -ne $checkpointMutex) { $checkpointMutex.ReleaseMutex() }
    if ($null -ne $checkpointMutex) { $checkpointMutex.Dispose() }
    Pop-Location
}

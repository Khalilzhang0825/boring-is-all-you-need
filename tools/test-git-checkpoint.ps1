#requires -Version 7.5
[CmdletBinding()]
param(
    [switch]$FocusedSafetyRegression
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:pass = 0
$script:fail = 0
$script:results = @{}
$checkpoint = Join-Path $PSScriptRoot 'git-checkpoint.ps1'
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase ('steadyagent-git-checkpoint-' + [guid]::NewGuid().ToString('N'))
$resolvedRoot = [System.IO.Path]::GetFullPath($tempRoot)

if (-not $resolvedRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Temporary root escaped the system temp directory.'
}

function Assert-Equal {
    param([string]$Name, [object]$Actual, [object]$Expected)
    $condition = [string]$Actual -eq [string]$Expected
    $script:results[$Name] = $condition
    if ($condition) {
        Write-Host ('PASS  ' + $Name)
        $script:pass++
    } else {
        Write-Host ('FAIL  ' + $Name + '  expected=' + [string]$Expected + ' actual=' + [string]$Actual)
        $script:fail++
    }
}

function Write-SemanticCheck {
    param([string]$Id, [string[]]$Cases)
    $missing = @($Cases | Where-Object {
        -not $script:results.ContainsKey($_) -or -not [bool]$script:results[$_]
    })
    if ($missing.Count -eq 0) {
        Write-Host ("SEMANTIC PASS " + $Id)
    } else {
        Write-Host ("FAIL  semantic evidence " + $Id + " missing=" + ($missing -join ","))
        $script:fail++
    }
}

function Invoke-Git {
    param([string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw ('git failed: ' + ($GitArgs -join ' '))
    }
}

function Get-RepositoryIndexHash {
    $indexPath = (& git rev-parse --path-format=absolute --git-path index).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $indexPath) {
        throw 'Cannot resolve the repository index path.'
    }
    return (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
}

function Get-WorkingTreeOidForExplicitPath {
    param([string]$Repository, [string]$Path)

    $temporaryIndex = Join-Path $Repository ('.checkpoint-tree-' + [guid]::NewGuid().ToString('N') + '.index')
    $savedIndexFile = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $temporaryIndex
        Invoke-Git @('read-tree', 'HEAD')
        Invoke-Git @('add', '--', $Path)
        $treeOid = (& git write-tree).Trim()
        if ($LASTEXITCODE -ne 0 -or $treeOid -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
            throw 'Cannot create the explicit working-tree fixture tree.'
        }
        return $treeOid
    }
    finally {
        if ($null -eq $savedIndexFile) { Remove-Item Env:\\GIT_INDEX_FILE -ErrorAction SilentlyContinue }
        else { $env:GIT_INDEX_FILE = $savedIndexFile }
        if (Test-Path -LiteralPath $temporaryIndex) {
            Remove-Item -LiteralPath $temporaryIndex -Force
        }
    }
}

function Get-CheckpointArtifactState {
    $gitDirectory = (& git rev-parse --path-format=absolute --git-dir).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $gitDirectory) {
        throw 'Cannot resolve the worktree Git directory.'
    }
    $commonDirectory = (& git rev-parse --path-format=absolute --git-common-dir).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $commonDirectory) {
        throw 'Cannot resolve the common Git directory.'
    }
    $quarantineRoot = Join-Path $commonDirectory 'steadyagent-quarantine'
    [pscustomobject]@{
        Journal = Test-Path -LiteralPath (Join-Path $gitDirectory 'steadyagent-checkpoint-journal.json')
        Backup = Test-Path -LiteralPath (Join-Path $gitDirectory 'steadyagent-checkpoint-index.backup')
        IndexLock = Test-Path -LiteralPath (Join-Path $gitDirectory 'index.lock')
        QuarantineArtifacts = @(
            Get-ChildItem -LiteralPath $quarantineRoot -Force -ErrorAction SilentlyContinue
        ).Count
    }
}

function Get-GitObjectInventory {
    $objectsPath = (& git rev-parse --path-format=absolute --git-path objects).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $objectsPath) {
        throw 'Cannot resolve the repository object directory.'
    }
    $objectsBoundary = $objectsPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return @(
        Get-ChildItem -LiteralPath $objectsPath -Recurse -File |
            Sort-Object FullName |
            ForEach-Object {
                $relativePath = $_.FullName.Substring($objectsBoundary.Length) -replace '\\', '/'
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                $relativePath + ':' + $_.Length + ':' + $hash
            }
    )
}

function Test-GitBlobExists {
    param([string]$ObjectId)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git cat-file -e ($ObjectId + '^{blob}') 2>$null
        return $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Get-UnreachableGitObjects {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git fsck --unreachable --no-reflogs --no-progress 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw 'git fsck failed while checking unreachable objects.'
        }
        return $output
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function New-TestRepo {
    param([string]$Name)
    $path = Join-Path $resolvedRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Push-Location $path
    try {
        Invoke-Git @('init', '-q')
        Invoke-Git @('config', 'user.name', 'Checkpoint Test')
        Invoke-Git @('config', 'user.email', 'checkpoint@example.invalid')
        Invoke-Git @('config', 'core.hooksPath', (Join-Path $path '.empty-hooks'))
        New-Item -ItemType Directory -Path (Join-Path $path '.empty-hooks') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $path 'user.txt'), "base-user`n", [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText((Join-Path $path 'task.txt'), "base-task`n", [System.Text.Encoding]::UTF8)
        Invoke-Git @('add', '--', 'user.txt', 'task.txt')
        Invoke-Git @('commit', '-q', '-m', 'baseline')
    } finally {
        Pop-Location
    }
    return $path
}

function Start-CheckpointChild {
    param(
        [string]$Repository,
        [string]$Message,
        [string]$File,
        [switch]$DryRun,
        [Collections.IDictionary]$EnvironmentOverrides
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $checkpoint + '" -Message "' + $Message + '" -Files "' + $File + '"'
    if ($DryRun) { $psi.Arguments += ' -DryRun' }
    $psi.WorkingDirectory = $Repository
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $scrubbedNames = @(
        'STEADYAGENT_TEST_MODE',
        'STEADYAGENT_TEST_ROOT',
        'STEADYAGENT_TEST_INDEX_PUBLICATION_FAILURE',
        'STEADYAGENT_TEST_INDEX_MUTATION_PATH',
        'STEADYAGENT_TEST_INDEX_ABA_PATH',
        'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_ACQUIRE',
        'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_WRITE',
        'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_BACKUP',
        'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_PUBLICATION',
        'STEADYAGENT_TEST_REF_MUTATION_BEFORE_CAS',
        'STEADYAGENT_TEST_REWRITE_INDEX_LOCK_AFTER_CLAIM',
        'STEADYAGENT_TEST_CREATE_EXTERNAL_LOCK_DURING_CLEANUP',
        'STEADYAGENT_TEST_CREATE_EXTERNAL_LOCK_AFTER_RECOVERY_REPLACE',
        'STEADYAGENT_TEST_SWITCH_HEAD_AFTER_REF_VERIFY',
        'STEADYAGENT_TEST_SWAP_GIT_DIRECTORY_AFTER_PIN',
        'STEADYAGENT_TEST_GIT_DIRECTORY_PARKED_PATH',
        'STEADYAGENT_TEST_GIT_DIRECTORY_ESCAPE_PATH',
        'STEADYAGENT_TEST_OBJECT_FANOUT_JUNCTION',
        'STEADYAGENT_TEST_OBJECT_FANOUT_ESCAPE_PATH'
    )
    $originalEnvironment = @{}
    foreach ($name in $scrubbedNames) {
        $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    if ($null -ne $EnvironmentOverrides) {
        foreach ($name in $EnvironmentOverrides.Keys) {
            $environmentName = [string]$name
            if (-not $originalEnvironment.ContainsKey($environmentName)) {
                $originalEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable(
                    $environmentName,
                    'Process'
                )
            }
            [Environment]::SetEnvironmentVariable(
                $environmentName,
                [string]$EnvironmentOverrides.Item($name),
                'Process'
            )
        }
    }
    try {
        return [System.Diagnostics.Process]::Start($psi)
    }
    finally {
        foreach ($name in $originalEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable(
                [string]$name,
                $originalEnvironment[$name],
                'Process'
            )
        }
    }
}

function Complete-CheckpointChild {
    param([Diagnostics.Process]$Process)
    $stdout = $Process.StandardOutput.ReadToEnd()
    $stderr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $Process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Invoke-CheckpointChild {
    param(
        [string]$Repository,
        [string]$Message,
        [string]$File,
        [switch]$DryRun,
        [Collections.IDictionary]$EnvironmentOverrides
    )
    $process = Start-CheckpointChild `
        -Repository $Repository `
        -Message $Message `
        -File $File `
        -DryRun:$DryRun `
        -EnvironmentOverrides $EnvironmentOverrides
    return Complete-CheckpointChild -Process $process
}

function Invoke-CheckpointAllChild {
    param(
        [string]$Repository,
        [string]$Message,
        [string]$File,
        [switch]$DryRun
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $checkpoint + '" -Message "' + $Message + '" -All'
    if ($File) { $psi.Arguments += ' -Files "' + $File + '"' }
    if ($DryRun) { $psi.Arguments += ' -DryRun' }
    $psi.WorkingDirectory = $Repository
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return Complete-CheckpointChild -Process ([System.Diagnostics.Process]::Start($psi))
}

function Invoke-CheckpointNoScopeChild {
    param(
        [string]$Repository,
        [string]$Message
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $checkpoint + '" -Message "' + $Message + '"'
    $psi.WorkingDirectory = $Repository
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return Complete-CheckpointChild -Process ([System.Diagnostics.Process]::Start($psi))
}

function Invoke-FinalSymbolicHeadCasRegression {
    $repository = New-TestRepo 'final-symbolic-head-cas'
    Push-Location $repository
    try {
        $initialRef = (& git symbolic-ref HEAD).Trim()
        $oldHead = (& git rev-parse HEAD).Trim()
        Invoke-Git @('branch', 'same-oid-final')
        [IO.File]::WriteAllText(
            (Join-Path $repository 'task.txt'),
            "task-change`n",
            [Text.Encoding]::UTF8
        )
        $result = Invoke-CheckpointChild `
            -Repository $repository `
            -Message 'final symbolic HEAD CAS fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_SWITCH_HEAD_AFTER_REF_VERIFY = 'refs/heads/same-oid-final'
            }
        if ($result.ExitCode -ne 0) {
            Write-Host ('DETAIL final head CAS stdout=' + $result.Stdout)
            Write-Host ('DETAIL final head CAS stderr=' + $result.Stderr)
        }
        $artifacts = Get-CheckpointArtifactState
        Assert-Equal 'final head CAS: exact post-bind switch seam is reached' (
            $result.Stdout -match 'TEST symbolic HEAD switch blocked after identity bind'
        ) $true
        Assert-Equal 'final head CAS: checkpoint succeeds after blocking the switch' $result.ExitCode 0
        Assert-Equal 'final head CAS: captured symbolic HEAD is preserved' (
            (& git symbolic-ref HEAD).Trim()
        ) $initialRef
        Assert-Equal 'final head CAS: original branch ref advances' (
            ((& git rev-parse $initialRef).Trim()) -ne $oldHead
        ) $true
        Assert-Equal 'final head CAS: switched branch ref is unchanged' (
            (& git rev-parse refs/heads/same-oid-final).Trim()
        ) $oldHead
        Assert-Equal 'final head CAS: published index is clean' (
            @(& git diff --cached --name-only) -join ','
        ) ''
        Assert-Equal 'final head CAS: journal is finalized safely' $artifacts.Journal $false
    }
    finally {
        Pop-Location
    }
}

function Invoke-GitDirectoryPinRegression {
    $repository = New-TestRepo 'git-directory-parent-pin'
    Push-Location $repository
    try {
        [IO.File]::WriteAllText(
            (Join-Path $repository 'task.txt'),
            "task-change`n",
            [Text.Encoding]::UTF8
        )
        $gitDirectory = (& git rev-parse --path-format=absolute --git-dir).Trim()
        $parkedPath = Join-Path $resolvedRoot 'git-directory-parent-pin-parked'
        $escapePath = Join-Path $resolvedRoot 'git-directory-parent-pin-escape'
        New-Item -ItemType Directory -Path $escapePath | Out-Null
        $sentinelPath = Join-Path $escapePath 'sentinel.txt'
        [IO.File]::WriteAllText($sentinelPath, "sentinel`n", [Text.Encoding]::UTF8)
        $sentinelHash = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
        $result = Invoke-CheckpointChild `
            -Repository $repository `
            -Message 'Git directory parent pin fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_SWAP_GIT_DIRECTORY_AFTER_PIN = '1'
                STEADYAGENT_TEST_GIT_DIRECTORY_PARKED_PATH = $parkedPath
                STEADYAGENT_TEST_GIT_DIRECTORY_ESCAPE_PATH = $escapePath
            }
        if ($result.ExitCode -ne 0) {
            Write-Host ('DETAIL Git parent pin stdout=' + $result.Stdout)
            Write-Host ('DETAIL Git parent pin stderr=' + $result.Stderr)
        }
        Assert-Equal 'Git parent pin: exact post-pin swap seam is reached' (
            $result.Stdout -match 'TEST Git directory swap blocked after path pin'
        ) $true
        Assert-Equal 'Git parent pin: checkpoint succeeds after blocked swap' $result.ExitCode 0
        Assert-Equal 'Git parent pin: Git directory remains a normal directory' (
            (Test-Path -LiteralPath $gitDirectory -PathType Container) -and
            (((Get-Item -LiteralPath $gitDirectory -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint) -eq 0)
        ) $true
        Assert-Equal 'Git parent pin: no parked Git directory is created' (
            Test-Path -LiteralPath $parkedPath
        ) $false
        Assert-Equal 'Git parent pin: escape tree remains byte-identical' (
            (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
        ) $sentinelHash
    }
    finally {
        Pop-Location
    }
}

function Invoke-ObjectFanoutJunctionRegression {
    $repository = New-TestRepo 'object-fanout-junction'
    Push-Location $repository
    try {
        $objectsDirectory = (& git rev-parse --path-format=absolute --git-path objects).Trim()
        $targetBlob = $null
        $fanout = $null
        for ($attempt = 0; $attempt -lt 4096; $attempt++) {
            [IO.File]::WriteAllText(
                (Join-Path $repository 'task.txt'),
                ("object-fanout-junction-" + $attempt + "`n"),
                [Text.Encoding]::UTF8
            )
            $candidate = (& git hash-object -- task.txt).Trim()
            if ($LASTEXITCODE -ne 0 -or $candidate -notmatch '^[0-9a-f]{40}$') {
                throw 'Could not compute the fanout fixture blob id.'
            }
            $candidateFanout = $candidate.Substring(0, 2)
            if (-not (Test-Path -LiteralPath (Join-Path $objectsDirectory $candidateFanout))) {
                $targetBlob = $candidate
                $fanout = $candidateFanout
                break
            }
        }
        if (-not $targetBlob) { throw 'Could not find an unused object fanout for the fixture.' }
        $escapePath = Join-Path $resolvedRoot 'object-fanout-junction-escape'
        New-Item -ItemType Directory -Path $escapePath | Out-Null
        $sentinelPath = Join-Path $escapePath 'sentinel.txt'
        [IO.File]::WriteAllText($sentinelPath, "sentinel`n", [Text.Encoding]::UTF8)
        $sentinelHash = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
        $beforeHead = (& git rev-parse HEAD).Trim()
        $beforeIndexHash = Get-RepositoryIndexHash
        $result = Invoke-CheckpointChild `
            -Repository $repository `
            -Message 'object fanout junction fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_OBJECT_FANOUT_JUNCTION = $fanout
                STEADYAGENT_TEST_OBJECT_FANOUT_ESCAPE_PATH = $escapePath
            }
        Assert-Equal 'object fanout junction: exact pre-publication seam is reached' (
            $result.Stdout -match 'TEST object fanout junction injected before publication'
        ) $true
        Assert-Equal 'object fanout junction: checkpoint fails closed' $result.ExitCode 2
        Assert-Equal 'object fanout junction: reports bound fanout refusal' (
            $result.Stderr -match '(?i)(fanout|normal directory|reparse)'
        ) $true
        Assert-Equal 'object fanout junction: HEAD remains unchanged' (
            (& git rev-parse HEAD).Trim()
        ) $beforeHead
        Assert-Equal 'object fanout junction: real index remains unchanged' (
            Get-RepositoryIndexHash
        ) $beforeIndexHash
        Assert-Equal 'object fanout junction: escape sentinel remains byte-identical' (
            (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
        ) $sentinelHash
        Assert-Equal 'object fanout junction: no object is published into escape tree' (
            @(Get-ChildItem -LiteralPath $escapePath -Recurse -File -Force).Count
        ) 1
    }
    finally {
        Pop-Location
    }
}

function Invoke-SameContentExternalLockIdentityRegression {
    $repository = New-TestRepo 'same-content-external-index-lock'
    Push-Location $repository
    try {
        [IO.File]::WriteAllText(
            (Join-Path $repository 'task.txt'),
            "task-change`n",
            [Text.Encoding]::UTF8
        )
        $beforeHead = (& git rev-parse HEAD).Trim()
        $crash = Invoke-CheckpointChild `
            -Repository $repository `
            -Message 'same-content external index lock crash fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_ACQUIRE = '1'
            }
        $indexLockPath = ((& git rev-parse --path-format=absolute --git-path index).Trim()) + '.lock'
        $parkedOwnedLock = $indexLockPath + '.original-owner'
        Move-Item -LiteralPath $indexLockPath -Destination $parkedOwnedLock
        Copy-Item -LiteralPath $parkedOwnedLock -Destination $indexLockPath
        $ownedHash = (Get-FileHash -LiteralPath $parkedOwnedLock -Algorithm SHA256).Hash
        $replacementHash = (Get-FileHash -LiteralPath $indexLockPath -Algorithm SHA256).Hash

        $recovery = Invoke-CheckpointChild `
            -Repository $repository `
            -Message 'same-content external index lock recovery fixture' `
            -File 'task.txt'
        $artifacts = Get-CheckpointArtifactState
        Assert-Equal 'same-content external lock: fixture reaches the exact hard-exit seam' $crash.ExitCode 83
        Assert-Equal 'same-content external lock: replacement has identical bytes' $replacementHash $ownedHash
        Assert-Equal 'same-content external lock: different identity fails closed' $recovery.ExitCode 2
        Assert-Equal 'same-content external lock: identity mismatch is reported' (
            $recovery.Stderr -match 'different file identity'
        ) $true
        Assert-Equal 'same-content external lock: replacement remains present' (
            (Test-Path -LiteralPath $indexLockPath -PathType Leaf) -and
            ((Get-FileHash -LiteralPath $indexLockPath -Algorithm SHA256).Hash -eq $replacementHash)
        ) $true
        Assert-Equal 'same-content external lock: original owned file remains parked' (
            (Test-Path -LiteralPath $parkedOwnedLock -PathType Leaf) -and
            ((Get-FileHash -LiteralPath $parkedOwnedLock -Algorithm SHA256).Hash -eq $ownedHash)
        ) $true
        Assert-Equal 'same-content external lock: recovery journal remains pending' $artifacts.Journal $true
        Assert-Equal 'same-content external lock: HEAD remains unchanged' ((& git rev-parse HEAD).Trim()) $beforeHead

        Remove-Item -LiteralPath $indexLockPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $parkedOwnedLock -Force -ErrorAction SilentlyContinue
        $retry = Invoke-CheckpointChild `
            -Repository $repository `
            -Message 'same-content external index lock retry fixture' `
            -File 'task.txt'
        Assert-Equal 'same-content external lock: retry after external unlock succeeds' $retry.ExitCode 0
    }
    finally {
        Pop-Location
    }
}

function Invoke-QuarantineAncestorJunctionRecoveryRegression {
    # Keep the full quarantined-object path below the legacy Windows MAX_PATH
    # boundary used by GitHub-hosted runners. The runner temp prefix is longer
    # than a typical local profile path, while the fixture semantics do not
    # depend on this directory name.
    $repository = New-TestRepo 'quarantine-junction'
    Push-Location $repository
    try {
        [IO.File]::WriteAllText(
            (Join-Path $repository 'task.txt'),
            "task-change`n",
            [Text.Encoding]::UTF8
        )
        $beforeHead = (& git rev-parse HEAD).Trim()
        $beforeIndexHash = Get-RepositoryIndexHash
        $beforeObjectInventory = @(Get-GitObjectInventory)
        $crash = Invoke-CheckpointChild `
            -Repository $repository `
            -Message 'quarantine ancestor junction crash fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_ACQUIRE = '1'
            }

        $commonDirectory = (& git rev-parse --path-format=absolute --git-common-dir).Trim()
        $quarantineRoot = Join-Path $commonDirectory 'steadyagent-quarantine'
        $transaction = @(
            Get-ChildItem -LiteralPath $quarantineRoot -Directory -Force
        )
        if ($transaction.Count -ne 1 -or
            -not $transaction[0].Name.StartsWith('transaction-', [StringComparison]::Ordinal)) {
            throw 'Hard-kill fixture did not leave exactly one quarantine transaction.'
        }
        $transactionLeaf = $transaction[0].Name
        $parkedRoot = Join-Path $resolvedRoot 'quarantine-ancestor-junction-parked'
        $escapeRoot = Join-Path $resolvedRoot 'quarantine-ancestor-junction-escape'
        $escapeTransaction = Join-Path $escapeRoot $transactionLeaf
        New-Item -ItemType Directory -Path $escapeTransaction -Force | Out-Null
        $sentinelPath = Join-Path $escapeTransaction 'sentinel.txt'
        [IO.File]::WriteAllText($sentinelPath, "outside-sentinel`n", [Text.Encoding]::UTF8)
        $sentinelHash = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
        Move-Item -LiteralPath $quarantineRoot -Destination $parkedRoot
        New-Item -ItemType Junction -Path $quarantineRoot -Target $escapeRoot | Out-Null

        $recovery = Invoke-CheckpointChild `
            -Repository $repository `
            -Message 'quarantine ancestor junction recovery fixture' `
            -File 'task.txt'
        $afterIndexHash = Get-RepositoryIndexHash
        $afterObjectInventory = @(Get-GitObjectInventory)

        Assert-Equal 'quarantine ancestor junction: fixture reaches the exact hard-exit seam' `
            $crash.ExitCode 83
        Assert-Equal 'quarantine ancestor junction: recovery fails closed' $recovery.ExitCode 2
        Assert-Equal 'quarantine ancestor junction: ancestor reparse is reported' (
            $recovery.Stderr -match '(?i)(quarantine|reparse|normal directory)'
        ) $true
        Assert-Equal 'quarantine ancestor junction: external sentinel remains byte-identical' (
            (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -and
            ((Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash -eq $sentinelHash)
        ) $true
        Assert-Equal 'quarantine ancestor junction: HEAD remains unchanged' (
            (& git rev-parse HEAD).Trim()
        ) $beforeHead
        Assert-Equal 'quarantine ancestor junction: real index remains byte-identical' `
            $afterIndexHash $beforeIndexHash
        Assert-Equal 'quarantine ancestor junction: real object inventory remains byte-identical' (
            $afterObjectInventory -join "`n"
        ) ($beforeObjectInventory -join "`n")
        Assert-Equal 'quarantine ancestor junction: original transaction remains parked' (
            Test-Path -LiteralPath (Join-Path $parkedRoot $transactionLeaf) -PathType Container
        ) $true
    }
    finally {
        Pop-Location
    }
}

New-Item -ItemType Directory -Path $resolvedRoot -Force | Out-Null
if ($FocusedSafetyRegression) {
    try {
        Invoke-FinalSymbolicHeadCasRegression
        Invoke-GitDirectoryPinRegression
        Invoke-ObjectFanoutJunctionRegression
        Invoke-SameContentExternalLockIdentityRegression
        Invoke-QuarantineAncestorJunctionRecoveryRegression
    }
    finally {
        if (Test-Path -LiteralPath $resolvedRoot) {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
        }
    }
    Write-Host ("=== Focused checkpoint safety regression: {0} passed, {1} failed ===" -f $script:pass, $script:fail)
    if ($script:fail -gt 0) { exit 1 }
    exit 0
}
try {
    Invoke-FinalSymbolicHeadCasRegression
    Invoke-GitDirectoryPinRegression
    Invoke-ObjectFanoutJunctionRegression
    Invoke-SameContentExternalLockIdentityRegression
    Invoke-QuarantineAncestorJunctionRecoveryRegression

    $isolatedRepo = New-TestRepo 'pre-staged'
    Push-Location $isolatedRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $isolatedRepo 'user.txt'), "user-change`n", [System.Text.Encoding]::UTF8)
        Invoke-Git @('add', '--', 'user.txt')
        [System.IO.File]::WriteAllText((Join-Path $isolatedRepo 'task.txt'), "task-change`n", [System.Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointChild -Repository $isolatedRepo -Message 'checkpoint isolation fixture' -File 'task.txt'
        $exitCode = $checkpointResult.ExitCode
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $taskWorking = @(& git diff --name-only -- 'task.txt')

        Assert-Equal 'pre-staged: checkpoint refuses' $exitCode 2
        Assert-Equal 'pre-staged: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'pre-staged: user index preserved' ($staged -join ',') 'user.txt'
        Assert-Equal 'pre-staged: task remains unstaged' ($taskWorking -join ',') 'task.txt'
    } finally {
        Pop-Location
    }

    $hardlinkRepo = New-TestRepo 'protected-hardlink'
    Push-Location $hardlinkRepo
    try {
        [IO.File]::WriteAllText(
            (Join-Path $hardlinkRepo '.env'),
            "SYNTHETIC_SECRET_MARKER`n",
            (New-Object Text.UTF8Encoding($false))
        )
        New-Item `
            -ItemType HardLink `
            -Path (Join-Path $hardlinkRepo 'safe-hardlink.txt') `
            -Target (Join-Path $hardlinkRepo '.env') | Out-Null
        $beforeHead = (& git rev-parse HEAD).Trim()
        $beforeIndexHash = Get-RepositoryIndexHash
        $checkpointResult = Invoke-CheckpointChild `
            -Repository $hardlinkRepo `
            -Message 'protected hardlink fixture' `
            -File 'safe-hardlink.txt'
        Assert-Equal 'protected hardlink: checkpoint fails closed' $checkpointResult.ExitCode 2
        Assert-Equal 'protected hardlink: HEAD remains unchanged' ((& git rev-parse HEAD).Trim()) $beforeHead
        Assert-Equal 'protected hardlink: real index bytes remain unchanged' (Get-RepositoryIndexHash) $beforeIndexHash
        Assert-Equal 'protected hardlink: alias remains untracked' (
            @(& git ls-files --others --exclude-standard -- 'safe-hardlink.txt').Count
        ) 1
    }
    finally {
        Pop-Location
    }

    $normalRepo = New-TestRepo 'normal'
    Push-Location $normalRepo
    try {
        Invoke-Git @('update-index', '--skip-worktree', 'user.txt')
        [System.IO.File]::WriteAllText((Join-Path $normalRepo 'task.txt'), "task-change`n", [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText((Join-Path $normalRepo 'other.txt'), "untracked`n", [System.Text.Encoding]::UTF8)
        $checkpointResult = Invoke-CheckpointChild -Repository $normalRepo -Message 'normal explicit checkpoint' -File 'task.txt'
        $exitCode = $checkpointResult.ExitCode
        $committed = @(& git diff-tree --no-commit-id --name-only -r HEAD)
        $untracked = @(& git ls-files --others --exclude-standard)

        if ($exitCode -ne 0) {
            Write-Host ('DETAIL normal stdout=' + $checkpointResult.Stdout)
            Write-Host ('DETAIL normal stderr=' + $checkpointResult.Stderr)
        }
        Assert-Equal 'normal: checkpoint succeeds' $exitCode 0
        Assert-Equal 'normal: commits explicit task only' ($committed -join ',') 'task.txt'
        Assert-Equal 'normal: unrelated file remains untracked' ($untracked -join ',') 'other.txt'
        Assert-Equal 'normal: unrelated index flags preserved' ((& git ls-files -v -- 'user.txt').StartsWith('S')) $true
        $directoryResult = Invoke-CheckpointChild -Repository $normalRepo -Message 'directory rejection fixture' -File '.'
        Assert-Equal 'scope: directory rejected' $directoryResult.ExitCode 2
        $outsideResult = Invoke-CheckpointChild -Repository $normalRepo -Message 'outside rejection fixture' -File '..\outside.txt'
        Assert-Equal 'scope: outside path rejected' $outsideResult.ExitCode 2
    } finally {
        Pop-Location
    }

    $noScopeRepo = New-TestRepo 'no-scope'
    Push-Location $noScopeRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $noScopeRepo 'task.txt'), "task-change`n", [System.Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointNoScopeChild -Repository $noScopeRepo -Message 'missing scope fixture'
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)

        Assert-Equal 'no scope: checkpoint fails closed' $checkpointResult.ExitCode 2
        Assert-Equal 'no scope: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'no scope: real index remains clean' ($staged -join ',') ''
        Assert-Equal 'no scope: working change is preserved' ($working -join ',') 'task.txt'
    } finally {
        Pop-Location
    }

    $allRepo = New-TestRepo 'all-explicit'
    Push-Location $allRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $allRepo 'task.txt'), "task-change`n", [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText((Join-Path $allRepo 'user.txt'), "user-change`n", [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText((Join-Path $allRepo 'other.txt'), "other-change`n", [System.Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointAllChild -Repository $allRepo -Message 'explicit all checkpoint fixture'
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)
        $untracked = @(& git ls-files --others --exclude-standard)
        $committed = @(& git diff-tree --no-commit-id --name-only -r HEAD | Sort-Object)

        Assert-Equal 'all switch: checkpoint succeeds when explicitly requested' $checkpointResult.ExitCode 0
        Assert-Equal 'all switch: HEAD advances' ($afterHead -ne $beforeHead) $true
        Assert-Equal 'all switch: commits every changed path' ($committed -join ',') 'other.txt,task.txt,user.txt'
        Assert-Equal 'all switch: real index is clean after publication' ($staged -join ',') ''
        Assert-Equal 'all switch: no working changes remain' ($working -join ',') ''
        Assert-Equal 'all switch: no untracked changes remain' ($untracked -join ',') ''
    } finally {
        Pop-Location
    }

    $allBlockedRepo = New-TestRepo 'all-blocked-risk'
    Push-Location $allBlockedRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $allBlockedRepo 'task.txt'), "task-change`n", [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText((Join-Path $allBlockedRepo '.env'), "TOKEN=fixture`n", [System.Text.Encoding]::UTF8)
        $blockedBlob = (& git hash-object --path=.env -- '.env').Trim()
        $blobAbsentBefore = -not (Test-GitBlobExists -ObjectId $blockedBlob)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $beforeIndexHash = Get-RepositoryIndexHash
        $beforeObjectInventory = @(Get-GitObjectInventory)
        $beforeFsck = @(Get-UnreachableGitObjects)
        $checkpointResult = Invoke-CheckpointAllChild -Repository $allBlockedRepo -Message 'all protected path fixture'
        $afterHead = (& git rev-parse HEAD).Trim()
        $afterIndexHash = Get-RepositoryIndexHash
        $afterObjectInventory = @(Get-GitObjectInventory)
        $afterFsck = @(Get-UnreachableGitObjects)
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)
        $untracked = @(& git ls-files --others --exclude-standard)

        Assert-Equal 'all protected path: returns exit 2' $checkpointResult.ExitCode 2
        Assert-Equal 'all protected path: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'all protected path: real index remains clean' ($staged -join ',') ''
        Assert-Equal 'all protected path: real index bytes unchanged' $afterIndexHash $beforeIndexHash
        Assert-Equal 'all protected path: tracked change is preserved' ($working -join ',') 'task.txt'
        Assert-Equal 'all protected path: risky file remains untracked' ($untracked -join ',') '.env'
        Assert-Equal 'all protected path: target blob absent before checkpoint' $blobAbsentBefore $true
        Assert-Equal 'all protected path: target blob absent after checkpoint' (Test-GitBlobExists -ObjectId $blockedBlob) $false
        Assert-Equal 'all protected path: object inventory unchanged' ($afterObjectInventory -join "`n") ($beforeObjectInventory -join "`n")
        Assert-Equal 'all protected path: fsck had no target before checkpoint' (($beforeFsck -join "`n").Contains($blockedBlob)) $false
        Assert-Equal 'all protected path: fsck has no target dangling blob' (($afterFsck -join "`n").Contains($blockedBlob)) $false
    } finally {
        Pop-Location
    }

    $allLargeRepo = New-TestRepo 'all-large-file'
    Push-Location $allLargeRepo
    try {
        $largePath = Join-Path $allLargeRepo 'large.bin'
        $largeStream = [System.IO.File]::Open($largePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $largeStream.SetLength(26MB)
        } finally {
            $largeStream.Dispose()
        }
        $largeBlob = (& git hash-object --path=large.bin -- 'large.bin').Trim()
        $blobAbsentBefore = -not (Test-GitBlobExists -ObjectId $largeBlob)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $beforeIndexHash = Get-RepositoryIndexHash
        $beforeObjectInventory = @(Get-GitObjectInventory)
        $beforeFsck = @(Get-UnreachableGitObjects)
        $checkpointResult = Invoke-CheckpointAllChild -Repository $allLargeRepo -Message 'all large file fixture'
        $afterHead = (& git rev-parse HEAD).Trim()
        $afterIndexHash = Get-RepositoryIndexHash
        $afterObjectInventory = @(Get-GitObjectInventory)
        $afterFsck = @(Get-UnreachableGitObjects)
        $staged = @(& git diff --cached --name-only)
        $untracked = @(& git ls-files --others --exclude-standard)

        Assert-Equal 'all large file: returns exit 2' $checkpointResult.ExitCode 2
        Assert-Equal 'all large file: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'all large file: real index remains clean' ($staged -join ',') ''
        Assert-Equal 'all large file: real index bytes unchanged' $afterIndexHash $beforeIndexHash
        Assert-Equal 'all large file: file remains untracked' ($untracked -join ',') 'large.bin'
        Assert-Equal 'all large file: target blob absent before checkpoint' $blobAbsentBefore $true
        Assert-Equal 'all large file: target blob absent after checkpoint' (Test-GitBlobExists -ObjectId $largeBlob) $false
        Assert-Equal 'all large file: object inventory unchanged' ($afterObjectInventory -join "`n") ($beforeObjectInventory -join "`n")
        Assert-Equal 'all large file: fsck had no target before checkpoint' (($beforeFsck -join "`n").Contains($largeBlob)) $false
        Assert-Equal 'all large file: fsck has no target dangling blob' (($afterFsck -join "`n").Contains($largeBlob)) $false
    } finally {
        Pop-Location
    }

    $preAddGrowthRepo = New-TestRepo 'pre-add-growth'
    Push-Location $preAddGrowthRepo
    try {
        $growthPath = Join-Path $preAddGrowthRepo 'large.bin'
        [IO.File]::WriteAllText($growthPath, "tiny", (New-Object Text.UTF8Encoding($false)))
        $shimDirectory = Join-Path $resolvedRoot 'pre-add-growth-git-shim'
        $shimMarker = Join-Path $shimDirectory 'mutated.marker'
        New-Item -ItemType Directory -Path $shimDirectory -Force | Out-Null
        $shimText = @'
$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $env:STEADYAGENT_MUTATION_MARKER)) {
    [IO.File]::WriteAllText(
        $env:STEADYAGENT_MUTATION_MARKER,
        "mutated",
        (New-Object Text.UTF8Encoding($false))
    )
    $stream = [IO.File]::Open(
        $env:STEADYAGENT_MUTATION_PATH,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $stream.SetLength(26MB)
    }
    finally {
        $stream.Dispose()
    }
}
'@
        [IO.File]::WriteAllText(
            (Join-Path $shimDirectory 'git-shim.ps1'),
            $shimText,
            (New-Object Text.UTF8Encoding($false))
        )
        [IO.File]::WriteAllText(
            (Join-Path $shimDirectory 'git.cmd'),
            (
                "@echo off`r`n" +
                "if /I `"%~1`"==`"add`" pwsh.exe -NoProfile " +
                "-ExecutionPolicy Bypass -File `"%~dp0git-shim.ps1`"`r`n" +
                "if errorlevel 1 exit /b %ERRORLEVEL%`r`n" +
                "`"%STEADYAGENT_REAL_GIT%`" %*`r`n" +
                "exit /b %ERRORLEVEL%`r`n"
            ),
            [Text.Encoding]::ASCII
        )
        $realGit = (Get-Command git.exe -CommandType Application -ErrorAction Stop |
            Select-Object -First 1).Source
        $beforeHead = (& git rev-parse HEAD).Trim()
        $beforeIndexHash = Get-RepositoryIndexHash
        $beforeObjectInventory = @(Get-GitObjectInventory)
        $beforeFsck = @(Get-UnreachableGitObjects)
        $checkpointResult = Invoke-CheckpointChild `
            -Repository $preAddGrowthRepo `
            -Message 'pre-add growth fixture' `
            -File 'large.bin' `
            -EnvironmentOverrides @{
                PATH = $shimDirectory + [IO.Path]::PathSeparator +
                    [Environment]::GetEnvironmentVariable('PATH', 'Process')
                STEADYAGENT_REAL_GIT = $realGit
                STEADYAGENT_MUTATION_PATH = $growthPath
                STEADYAGENT_MUTATION_MARKER = $shimMarker
            }
        $afterHead = (& git rev-parse HEAD).Trim()
        $afterIndexHash = Get-RepositoryIndexHash
        $afterObjectInventory = @(Get-GitObjectInventory)
        $afterFsck = @(Get-UnreachableGitObjects)
        $largeBlob = (& git hash-object --no-filters -- 'large.bin').Trim()
        $largeObjectRelative = $largeBlob.Substring(0, 2) + '/' + $largeBlob.Substring(2)
        $staged = @(& git diff --cached --name-only)
        $untracked = @(& git ls-files --others --exclude-standard)
        $commonDirectory = (& git rev-parse --path-format=absolute --git-common-dir).Trim()
        $quarantineRoot = Join-Path $commonDirectory 'steadyagent-quarantine'
        $quarantineArtifacts = @(
            Get-ChildItem -LiteralPath $quarantineRoot -Force -ErrorAction SilentlyContinue
        )
        if (-not (Test-Path -LiteralPath $shimMarker -PathType Leaf)) {
            Write-Host (
                'PRE-ADD FIXTURE STDOUT: ' +
                $checkpointResult.Stdout.Replace("`r", "").Replace("`n", " | ")
            )
            Write-Host (
                'PRE-ADD FIXTURE STDERR: ' +
                $checkpointResult.Stderr.Replace("`r", "").Replace("`n", " | ")
            )
        }

        Assert-Equal 'pre-add growth: shim reaches the exact add seam' (
            Test-Path -LiteralPath $shimMarker -PathType Leaf
        ) $true
        Assert-Equal 'pre-add growth: returns exit 2' $checkpointResult.ExitCode 2
        Assert-Equal 'pre-add growth: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'pre-add growth: real index remains clean' ($staged -join ',') ''
        Assert-Equal 'pre-add growth: real index bytes unchanged' $afterIndexHash $beforeIndexHash
        Assert-Equal 'pre-add growth: file remains untracked' ($untracked -join ',') 'large.bin'
        Assert-Equal 'pre-add growth: target blob absent before checkpoint' (
            ($beforeObjectInventory -join "`n").Contains($largeObjectRelative)
        ) $false
        Assert-Equal 'pre-add growth: target blob absent after checkpoint' (
            Test-GitBlobExists -ObjectId $largeBlob
        ) $false
        Assert-Equal 'pre-add growth: object inventory unchanged' (
            $afterObjectInventory -join "`n"
        ) ($beforeObjectInventory -join "`n")
        Assert-Equal 'pre-add growth: fsck had no target before checkpoint' (
            ($beforeFsck -join "`n").Contains($largeBlob)
        ) $false
        Assert-Equal 'pre-add growth: fsck has no target dangling blob' (
            ($afterFsck -join "`n").Contains($largeBlob)
        ) $false
        Assert-Equal 'pre-add growth: quarantine leaves no artifacts' $quarantineArtifacts.Count 0
    } finally {
        Pop-Location
    }

    $allDryRunRepo = New-TestRepo 'all-dry-run'
    Push-Location $allDryRunRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $allDryRunRepo 'task.txt'), "task-change`n", [System.Text.Encoding]::UTF8)
        Remove-Item -LiteralPath (Join-Path $allDryRunRepo 'user.txt') -Force
        [System.IO.File]::WriteAllText((Join-Path $allDryRunRepo 'other.txt'), "other-change`n", [System.Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $beforeStatus = @(& git -c core.quotepath=false status --porcelain)
        $checkpointResult = Invoke-CheckpointAllChild -Repository $allDryRunRepo -Message 'all dry-run fixture' -DryRun
        $afterHead = (& git rev-parse HEAD).Trim()
        $afterStatus = @(& git -c core.quotepath=false status --porcelain)
        $staged = @(& git diff --cached --name-only)

        Assert-Equal 'all dry-run: succeeds' $checkpointResult.ExitCode 0
        Assert-Equal 'all dry-run: reports modified path' $checkpointResult.Stdout.Contains('task.txt') $true
        Assert-Equal 'all dry-run: reports deleted path' $checkpointResult.Stdout.Contains('user.txt') $true
        Assert-Equal 'all dry-run: reports untracked path' $checkpointResult.Stdout.Contains('other.txt') $true
        Assert-Equal 'all dry-run: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'all dry-run: real index remains clean' ($staged -join ',') ''
        Assert-Equal 'all dry-run: working state is preserved' ($afterStatus -join "`n") ($beforeStatus -join "`n")
    } finally {
        Pop-Location
    }

    $allAndFilesRepo = New-TestRepo 'all-and-files'
    Push-Location $allAndFilesRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $allAndFilesRepo 'task.txt'), "task-change`n", [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText((Join-Path $allAndFilesRepo 'user.txt'), "user-change`n", [System.Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointAllChild -Repository $allAndFilesRepo -Message 'mutually exclusive scope fixture' -File 'task.txt'
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only | Sort-Object)

        Assert-Equal 'all and files: mutually exclusive scopes are rejected' $checkpointResult.ExitCode 2
        Assert-Equal 'all and files: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'all and files: real index remains clean' ($staged -join ',') ''
        Assert-Equal 'all and files: working changes are preserved' ($working -join ',') 'task.txt,user.txt'
    } finally {
        Pop-Location
    }

    $failingRepo = New-TestRepo 'commit-failure'
    Push-Location $failingRepo
    try {
        $hookPath = Join-Path $failingRepo '.empty-hooks/pre-commit'
        [System.IO.File]::WriteAllText($hookPath, "#!/bin/sh`nexit 1`n", (New-Object System.Text.UTF8Encoding $false))
        [System.IO.File]::WriteAllText((Join-Path $failingRepo 'task.txt'), "task-change`n", [System.Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointChild -Repository $failingRepo -Message 'commit failure fixture' -File 'task.txt'
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only -- 'task.txt')

        Assert-Equal 'commit failure: returns nonzero' ($checkpointResult.ExitCode -ne 0) $true
        Assert-Equal 'commit failure: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'commit failure: index restored' ($staged -join ',') ''
        Assert-Equal 'commit failure: working change preserved' ($working -join ',') 'task.txt'
    } finally {
        Pop-Location
    }

    $dryRunRepo = New-TestRepo 'dry-run'
    Push-Location $dryRunRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $dryRunRepo 'task.txt'), "task-change`n", [System.Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointChild -Repository $dryRunRepo -Message 'dry run fixture' -File 'task.txt' -DryRun
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only -- 'task.txt')

        Assert-Equal 'dry-run: succeeds' $checkpointResult.ExitCode 0
        Assert-Equal 'dry-run: reports explicit file' ($checkpointResult.Stdout.Contains('task.txt')) $true
        Assert-Equal 'dry-run: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'dry-run: index unchanged' ($staged -join ',') ''
        Assert-Equal 'dry-run: working change preserved' ($working -join ',') 'task.txt'
    } finally {
        Pop-Location
    }

    $blockedRepo = New-TestRepo 'blocked-risk'
    Push-Location $blockedRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $blockedRepo '.env'), "TOKEN=fixture`n", [System.Text.Encoding]::UTF8)
        $blockedBlob = (& git hash-object --path=.env -- '.env').Trim()
        $blobAbsentBefore = -not (Test-GitBlobExists -ObjectId $blockedBlob)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $beforeIndexHash = Get-RepositoryIndexHash
        $beforeObjectInventory = @(Get-GitObjectInventory)
        $beforeFsck = @(Get-UnreachableGitObjects)
        $checkpointResult = Invoke-CheckpointChild -Repository $blockedRepo -Message 'blocked risk fixture' -File '.env'
        $afterHead = (& git rev-parse HEAD).Trim()
        $afterIndexHash = Get-RepositoryIndexHash
        $afterObjectInventory = @(Get-GitObjectInventory)
        $afterFsck = @(Get-UnreachableGitObjects)
        $staged = @(& git diff --cached --name-only)
        $untracked = @(& git ls-files --others --exclude-standard)

        Assert-Equal 'blocked risk: returns exit 2' $checkpointResult.ExitCode 2
        Assert-Equal 'blocked risk: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'blocked risk: index restored' ($staged -join ',') ''
        Assert-Equal 'blocked risk: real index bytes unchanged' $afterIndexHash $beforeIndexHash
        Assert-Equal 'blocked risk: file remains untracked' ($untracked -join ',') '.env'
        Assert-Equal 'blocked risk: target blob absent before checkpoint' $blobAbsentBefore $true
        Assert-Equal 'blocked risk: target blob absent after checkpoint' (Test-GitBlobExists -ObjectId $blockedBlob) $false
        Assert-Equal 'blocked risk: object inventory unchanged' ($afterObjectInventory -join "`n") ($beforeObjectInventory -join "`n")
        Assert-Equal 'blocked risk: fsck had no target before checkpoint' (($beforeFsck -join "`n").Contains($blockedBlob)) $false
        Assert-Equal 'blocked risk: fsck has no target dangling blob' (($afterFsck -join "`n").Contains($blockedBlob)) $false
    } finally {
        Pop-Location
    }

    $blockedDryRunRepo = New-TestRepo 'blocked-risk-dry-run'
    Push-Location $blockedDryRunRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $blockedDryRunRepo '.env'), "TOKEN=dry-run-fixture`n", [System.Text.Encoding]::UTF8)
        $blockedBlob = (& git hash-object --path=.env -- '.env').Trim()
        $beforeHead = (& git rev-parse HEAD).Trim()
        $beforeIndexHash = Get-RepositoryIndexHash
        $beforeObjectInventory = @(Get-GitObjectInventory)
        $explicitResult = Invoke-CheckpointChild -Repository $blockedDryRunRepo -Message 'blocked explicit dry-run fixture' -File '.env' -DryRun
        $afterExplicitHead = (& git rev-parse HEAD).Trim()
        $afterExplicitIndexHash = Get-RepositoryIndexHash
        $afterExplicitObjectInventory = @(Get-GitObjectInventory)
        $allResult = Invoke-CheckpointAllChild -Repository $blockedDryRunRepo -Message 'blocked all dry-run fixture' -DryRun
        $afterAllHead = (& git rev-parse HEAD).Trim()
        $afterAllIndexHash = Get-RepositoryIndexHash
        $afterAllObjectInventory = @(Get-GitObjectInventory)
        $afterFsck = @(Get-UnreachableGitObjects)

        Assert-Equal 'protected dry-run: explicit returns exit 2' $explicitResult.ExitCode 2
        Assert-Equal 'protected dry-run: all returns exit 2' $allResult.ExitCode 2
        Assert-Equal 'protected dry-run: explicit HEAD unchanged' $afterExplicitHead $beforeHead
        Assert-Equal 'protected dry-run: all HEAD unchanged' $afterAllHead $beforeHead
        Assert-Equal 'protected dry-run: explicit index bytes unchanged' $afterExplicitIndexHash $beforeIndexHash
        Assert-Equal 'protected dry-run: all index bytes unchanged' $afterAllIndexHash $beforeIndexHash
        Assert-Equal 'protected dry-run: explicit object inventory unchanged' ($afterExplicitObjectInventory -join "`n") ($beforeObjectInventory -join "`n")
        Assert-Equal 'protected dry-run: all object inventory unchanged' ($afterAllObjectInventory -join "`n") ($beforeObjectInventory -join "`n")
        Assert-Equal 'protected dry-run: target blob remains absent' (Test-GitBlobExists -ObjectId $blockedBlob) $false
        Assert-Equal 'protected dry-run: fsck has no target dangling blob' (($afterFsck -join "`n").Contains($blockedBlob)) $false
    } finally {
        Pop-Location
    }

    $publicKeyRepo = New-TestRepo 'public-key'
    Push-Location $publicKeyRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $publicKeyRepo 'id_ed25519.pub'), "fixture public key`n", [System.Text.Encoding]::UTF8)
        $checkpointResult = Invoke-CheckpointChild -Repository $publicKeyRepo -Message 'public key fixture' -File 'id_ed25519.pub'
        $committed = @(& git show --pretty= --name-only HEAD)

        if ($checkpointResult.ExitCode -ne 0) {
            Write-Host ('DETAIL public-key stdout=' + $checkpointResult.Stdout)
            Write-Host ('DETAIL public-key stderr=' + $checkpointResult.Stderr)
        }
        Assert-Equal 'public key: checkpoint succeeds' $checkpointResult.ExitCode 0
        Assert-Equal 'public key: explicit file committed' ($committed -join ',') 'id_ed25519.pub'
    } finally {
        Pop-Location
    }

    $deletionRepo = New-TestRepo 'tracked-deletion'
    Push-Location $deletionRepo
    try {
        Remove-Item -LiteralPath (Join-Path $deletionRepo 'task.txt') -Force
        $checkpointResult = Invoke-CheckpointChild -Repository $deletionRepo -Message 'tracked deletion fixture' -File 'task.txt'
        $committed = @(& git diff-tree --no-commit-id --name-only -r HEAD)
        if ($checkpointResult.ExitCode -ne 0) {
            Write-Host ('DETAIL deletion stdout=' + $checkpointResult.Stdout)
            Write-Host ('DETAIL deletion stderr=' + $checkpointResult.Stderr)
        }
        Assert-Equal 'deletion: checkpoint succeeds' $checkpointResult.ExitCode 0
        Assert-Equal 'deletion: explicit file committed' ($committed -join ',') 'task.txt'
    } finally {
        Pop-Location
    }

    $renameRepo = New-TestRepo 'tracked-rename'
    Push-Location $renameRepo
    try {
        Move-Item -LiteralPath (Join-Path $renameRepo 'task.txt') -Destination (Join-Path $renameRepo 'renamed-task.txt')
        $checkpointResult = Invoke-CheckpointAllChild -Repository $renameRepo -Message 'tracked rename fixture'
        $renameChange = (& git diff-tree --no-commit-id --name-status -r -M HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git status --porcelain)
        Assert-Equal 'rename: all checkpoint succeeds' $checkpointResult.ExitCode 0
        Assert-Equal 'rename: old and new paths form one tracked rename' ($renameChange -match '^R100\s+task[.]txt\s+renamed-task[.]txt$') $true
        Assert-Equal 'rename: real index remains clean after publication' ($staged -join ',') ''
        Assert-Equal 'rename: working tree is clean' ($working -join ',') ''
    } finally {
        Pop-Location
    }

    $literalRepo = New-TestRepo 'literal-name'
    Push-Location $literalRepo
    try {
        [IO.File]::WriteAllText((Join-Path $literalRepo 'semi;name.txt'), "literal`n", [Text.Encoding]::UTF8)
        $checkpointResult = Invoke-CheckpointChild -Repository $literalRepo -Message 'literal filename fixture' -File 'semi;name.txt'
        $committed = @(& git diff-tree --no-commit-id --name-only -r HEAD)
        Assert-Equal 'literal: semicolon filename succeeds' $checkpointResult.ExitCode 0
        Assert-Equal 'literal: semicolon filename remains one path' ($committed -join ',') 'semi;name.txt'

        New-Item -ItemType Directory -Path (Join-Path $literalRepo 'nested') | Out-Null
        [IO.File]::WriteAllText((Join-Path $literalRepo 'nested/path.txt'), "normalized`n", [Text.Encoding]::UTF8)
        $normalizedResult = Invoke-CheckpointChild -Repository $literalRepo -Message 'normalized path fixture' -File 'nested\path.txt'
        $normalizedCommitted = @(& git diff-tree --no-commit-id --name-only -r HEAD)
        Assert-Equal 'scope: Windows separator path succeeds' $normalizedResult.ExitCode 0
        Assert-Equal 'scope: Windows separator normalizes to Git path' ($normalizedCommitted -join ',') 'nested/path.txt'
    } finally {
        Pop-Location
    }

    $itaRepo = New-TestRepo 'intent-to-add'
    Push-Location $itaRepo
    try {
        [IO.File]::WriteAllText((Join-Path $itaRepo 'intent.txt'), "intent`n", [Text.Encoding]::UTF8)
        Invoke-Git @('add', '-N', '--', 'intent.txt')
        [IO.File]::WriteAllText((Join-Path $itaRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointChild -Repository $itaRepo -Message 'intent-to-add fixture' -File 'task.txt'
        $afterHead = (& git rev-parse HEAD).Trim()
        $intentStillPresent = (@(& git diff --name-only --ita-visible-in-index -- 'intent.txt') -contains 'intent.txt')
        Assert-Equal 'intent-to-add: checkpoint refuses' $checkpointResult.ExitCode 2
        Assert-Equal 'intent-to-add: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'intent-to-add: index intent preserved' $intentStillPresent $true
        Assert-Equal 'intent-to-add: task remains unstaged' ((@(& git diff --name-only -- 'task.txt') -join ',') -eq 'task.txt') $true
    } finally {
        Pop-Location
    }

    $hookStageRepo = New-TestRepo 'hook-stage'
    Push-Location $hookStageRepo
    try {
        [IO.File]::WriteAllText((Join-Path $hookStageRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $hookStageRepo 'user.txt'), "user-change`n", [Text.Encoding]::UTF8)
        $hookPath = Join-Path $hookStageRepo '.empty-hooks/pre-commit'
        [IO.File]::WriteAllText($hookPath, "#!/bin/sh`ngit add -- user.txt`nexit 0`n", (New-Object Text.UTF8Encoding($false)))
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointChild -Repository $hookStageRepo -Message 'hook scope injection fixture' -File 'task.txt'
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)
        Assert-Equal 'hook-stage: checkpoint refuses foreign path' $checkpointResult.ExitCode 2
        Assert-Equal 'hook-stage: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'hook-stage: real index remains clean' ($staged -join ',') ''
        Assert-Equal 'hook-stage: both working changes remain' (($working | Sort-Object) -join ',') 'task.txt,user.txt'
    } finally {
        Pop-Location
    }

    $missingRootRepo = New-TestRepo 'injection-missing-root'
    Push-Location $missingRootRepo
    try {
        [IO.File]::WriteAllText((Join-Path $missingRootRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $indexPath = (& git rev-parse --path-format=absolute --git-path index).Trim()
        $beforeIndexHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
        $checkpointResult = Invoke-CheckpointChild `
            -Repository $missingRootRepo `
            -Message 'missing test root fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_INDEX_PUBLICATION_FAILURE = '1'
            }
        $afterHead = (& git rev-parse HEAD).Trim()
        $afterIndexHash = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
        $artifacts = Get-CheckpointArtifactState
        Assert-Equal 'test-root gate: injection without root is rejected' $checkpointResult.ExitCode 2
        Assert-Equal 'test-root gate: rejection occurs before HEAD writes' $afterHead $beforeHead
        Assert-Equal 'test-root gate: rejection occurs before index writes' $afterIndexHash $beforeIndexHash
        Assert-Equal 'test-root gate: no journal is created' $artifacts.Journal $false
        Assert-Equal 'test-root gate: no index backup is created' $artifacts.Backup $false
        Assert-Equal 'test-root gate: no index lock is created' $artifacts.IndexLock $false
        Assert-Equal 'test-root gate: no quarantine is created' $artifacts.QuarantineArtifacts 0
    } finally {
        Pop-Location
    }

    $indexRaceRepo = New-TestRepo 'index-race'
    Push-Location $indexRaceRepo
    try {
        [IO.File]::WriteAllText((Join-Path $indexRaceRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $indexRaceRepo 'user.txt'), "user-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointChild -Repository $indexRaceRepo -Message 'index publication race fixture' -File 'task.txt' -EnvironmentOverrides @{
            STEADYAGENT_TEST_MODE = '1'
            STEADYAGENT_TEST_ROOT = $resolvedRoot
            STEADYAGENT_TEST_INDEX_MUTATION_PATH = 'user.txt'
        }
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)
        Assert-Equal 'index-race: checkpoint fails closed' ($checkpointResult.ExitCode -ne 0) $true
        Assert-Equal 'index-race: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'index-race: concurrent user stage preserved' ($staged -join ',') 'user.txt'
        Assert-Equal 'index-race: checkpoint file remains working' (($working -contains 'task.txt')) $true
    } finally {
        Pop-Location
    }

    $indexAbaRepo = New-TestRepo 'index-aba'
    Push-Location $indexAbaRepo
    try {
        [IO.File]::WriteAllText((Join-Path $indexAbaRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $indexAbaRepo 'user.txt'), "user-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointChild `
            -Repository $indexAbaRepo `
            -Message 'real index ABA fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_INDEX_ABA_PATH = 'user.txt'
            }
        $afterHead = (& git rev-parse HEAD).Trim()
        $committed = @(& git diff-tree --no-commit-id --name-only -r HEAD)
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)
        Assert-Equal 'index ABA: exact stage-copy-unstage seam is reached' (
            $checkpointResult.Stdout -match 'TEST real-index ABA stage-copy-unstage seam reached|TEST real-index ABA stage blocked'
        ) $true
        Assert-Equal 'index ABA: checkpoint succeeds without reviving external staged state' $checkpointResult.ExitCode 0
        Assert-Equal 'index ABA: HEAD advances' ($afterHead -ne $beforeHead) $true
        Assert-Equal 'index ABA: explicit task is committed' ($committed -join ',') 'task.txt'
        Assert-Equal 'index ABA: final index does not revive the external staged path' ($staged -join ',') ''
        Assert-Equal 'index ABA: external working change remains' ($working -contains 'user.txt') $true
    } finally {
        Pop-Location
    }

    $publishFailureRepo = New-TestRepo 'publish-failure'
    Push-Location $publishFailureRepo
    try {
        [IO.File]::WriteAllText((Join-Path $publishFailureRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointChild -Repository $publishFailureRepo -Message 'index publication failure fixture' -File 'task.txt' -EnvironmentOverrides @{
            STEADYAGENT_TEST_MODE = '1'
            STEADYAGENT_TEST_ROOT = $resolvedRoot
            STEADYAGENT_TEST_INDEX_PUBLICATION_FAILURE = '1'
        }
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)
        Assert-Equal 'publish-failure: returns compensation code' $checkpointResult.ExitCode 3
        Assert-Equal 'publish-failure: HEAD CAS rolls back' $afterHead $beforeHead
        Assert-Equal 'publish-failure: real index remains unchanged' ($staged -join ',') ''
        Assert-Equal 'publish-failure: working change remains' (($working -contains 'task.txt')) $true
    } finally {
        Pop-Location
    }

    $prePublicationCrashCases = @(
        [pscustomobject]@{
            Name = 'index-lock-acquire'
            Environment = 'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_ACQUIRE'
            ExitCode = 83
            BackupExpected = $false
        },
        [pscustomobject]@{
            Name = 'index-lock-write'
            Environment = 'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_WRITE'
            ExitCode = 84
            BackupExpected = $false
        },
        [pscustomobject]@{
            Name = 'index-backup'
            Environment = 'STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_BACKUP'
            ExitCode = 85
            BackupExpected = $true
        }
    )
    foreach ($crashCase in $prePublicationCrashCases) {
        $crashRepo = New-TestRepo ('journal-' + $crashCase.Name)
        Push-Location $crashRepo
        try {
            [IO.File]::WriteAllText(
                (Join-Path $crashRepo 'task.txt'),
                "task-change`n",
                [Text.Encoding]::UTF8
            )
            $beforeHead = (& git rev-parse HEAD).Trim()
            $beforeIndexHash = (
                Get-FileHash -LiteralPath (Join-Path $crashRepo '.git/index') -Algorithm SHA256
            ).Hash
            $crashEnvironment = @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
            }
            $crashEnvironment[[string]$crashCase.Environment] = '1'
            $crashResult = Invoke-CheckpointChild `
                -Repository $crashRepo `
                -Message ('pre-publication crash ' + $crashCase.Name) `
                -File 'task.txt' `
                -EnvironmentOverrides $crashEnvironment
            $afterCrashArtifacts = Get-CheckpointArtifactState
            $afterCrashHead = (& git rev-parse HEAD).Trim()
            $afterCrashIndexHash = (
                Get-FileHash -LiteralPath (Join-Path $crashRepo '.git/index') -Algorithm SHA256
            ).Hash
            $recoveryResult = Invoke-CheckpointChild `
                -Repository $crashRepo `
                -Message ('pre-publication recovery ' + $crashCase.Name) `
                -File 'task.txt'
            $afterRecoveryArtifacts = Get-CheckpointArtifactState
            $committed = @(& git diff-tree --no-commit-id --name-only -r HEAD)
            Assert-Equal ($crashCase.Name + ': reaches the exact hard-exit seam') `
                $crashResult.ExitCode ([int]$crashCase.ExitCode)
            Assert-Equal ($crashCase.Name + ': crash leaves HEAD unchanged') `
                $afterCrashHead $beforeHead
            Assert-Equal ($crashCase.Name + ': crash leaves real index bytes unchanged') `
                $afterCrashIndexHash $beforeIndexHash
            Assert-Equal ($crashCase.Name + ': crash leaves durable journal') `
                $afterCrashArtifacts.Journal $true
            Assert-Equal ($crashCase.Name + ': crash leaves the expected backup state') `
                $afterCrashArtifacts.Backup ([bool]$crashCase.BackupExpected)
            Assert-Equal ($crashCase.Name + ': crash leaves journal-owned index lock') `
                $afterCrashArtifacts.IndexLock $true
            Assert-Equal ($crashCase.Name + ': retry recovers and commits') `
                $recoveryResult.ExitCode 0
            Assert-Equal ($crashCase.Name + ': retry commits the explicit file') `
                ($committed -join ',') 'task.txt'
            Assert-Equal ($crashCase.Name + ': retry removes journal') `
                $afterRecoveryArtifacts.Journal $false
            Assert-Equal ($crashCase.Name + ': retry removes backup') `
                $afterRecoveryArtifacts.Backup $false
            Assert-Equal ($crashCase.Name + ': retry removes index lock') `
                $afterRecoveryArtifacts.IndexLock $false
            Assert-Equal ($crashCase.Name + ': retry removes quarantine') `
                $afterRecoveryArtifacts.QuarantineArtifacts 0
        }
        finally {
            Pop-Location
        }
    }

    $dryRunRecoveryRepo = New-TestRepo 'journal-dry-run-zero-write'
    Push-Location $dryRunRecoveryRepo
    try {
        [IO.File]::WriteAllText(
            (Join-Path $dryRunRecoveryRepo 'task.txt'),
            "task-change`n",
            [Text.Encoding]::UTF8
        )
        $crashResult = Invoke-CheckpointChild `
            -Repository $dryRunRecoveryRepo `
            -Message 'dry-run pending recovery crash fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_BACKUP = '1'
            }
        $gitDirectory = (& git rev-parse --path-format=absolute --git-dir).Trim()
        $indexPath = (& git rev-parse --path-format=absolute --git-path index).Trim()
        $journalPath = Join-Path $gitDirectory 'steadyagent-checkpoint-journal.json'
        $backupPath = Join-Path $gitDirectory 'steadyagent-checkpoint-index.backup'
        $indexLockPath = $indexPath + '.lock'
        $beforeDryRun = [pscustomobject]@{
            Head = (& git rev-parse HEAD).Trim()
            Index = (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
            Journal = (Get-FileHash -LiteralPath $journalPath -Algorithm SHA256).Hash
            Backup = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
            IndexLock = (Get-FileHash -LiteralPath $indexLockPath -Algorithm SHA256).Hash
            Objects = @(Get-GitObjectInventory) -join "`n"
            Status = @(& git status --porcelain=v1) -join "`n"
        }
        $dryRunResult = Invoke-CheckpointChild `
            -Repository $dryRunRecoveryRepo `
            -Message 'dry-run must not recover pending transaction' `
            -File 'task.txt' `
            -DryRun
        $afterDryRunArtifacts = Get-CheckpointArtifactState
        Assert-Equal 'pending recovery dry-run: reaches the exact hard-exit seam' $crashResult.ExitCode 85
        Assert-Equal 'pending recovery dry-run: fails closed without recovery' $dryRunResult.ExitCode 2
        Assert-Equal 'pending recovery dry-run: reports explicit recovery requirement' (
            $dryRunResult.Stderr -match 'pending checkpoint transaction requires a non-dry-run recovery'
        ) $true
        Assert-Equal 'pending recovery dry-run: preserves HEAD' ((& git rev-parse HEAD).Trim()) $beforeDryRun.Head
        Assert-Equal 'pending recovery dry-run: preserves real index bytes' (
            (Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash
        ) $beforeDryRun.Index
        Assert-Equal 'pending recovery dry-run: preserves journal bytes' (
            (Get-FileHash -LiteralPath $journalPath -Algorithm SHA256).Hash
        ) $beforeDryRun.Journal
        Assert-Equal 'pending recovery dry-run: preserves backup bytes' (
            (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
        ) $beforeDryRun.Backup
        Assert-Equal 'pending recovery dry-run: preserves index lock bytes' (
            (Get-FileHash -LiteralPath $indexLockPath -Algorithm SHA256).Hash
        ) $beforeDryRun.IndexLock
        Assert-Equal 'pending recovery dry-run: preserves object inventory' (
            @(Get-GitObjectInventory) -join "`n"
        ) $beforeDryRun.Objects
        Assert-Equal 'pending recovery dry-run: preserves worktree and index status' (
            @(& git status --porcelain=v1) -join "`n"
        ) $beforeDryRun.Status
        Assert-Equal 'pending recovery dry-run: leaves journal pending' $afterDryRunArtifacts.Journal $true
        Assert-Equal 'pending recovery dry-run: leaves backup pending' $afterDryRunArtifacts.Backup $true
        Assert-Equal 'pending recovery dry-run: leaves index lock pending' $afterDryRunArtifacts.IndexLock $true
        $recoveryResult = Invoke-CheckpointChild `
            -Repository $dryRunRecoveryRepo `
            -Message 'explicit pending recovery retry' `
            -File 'task.txt'
        Assert-Equal 'pending recovery dry-run: later non-dry-run recovery succeeds' $recoveryResult.ExitCode 0
    }
    finally {
        Pop-Location
    }

    $externalEmptyLockRepo = New-TestRepo 'journal-external-empty-lock'
    Push-Location $externalEmptyLockRepo
    try {
        [IO.File]::WriteAllText(
            (Join-Path $externalEmptyLockRepo 'task.txt'),
            "task-change`n",
            [Text.Encoding]::UTF8
        )
        $beforeHead = (& git rev-parse HEAD).Trim()
        $crashResult = Invoke-CheckpointChild `
            -Repository $externalEmptyLockRepo `
            -Message 'external empty lock fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_ACQUIRE = '1'
            }
        $indexLockPath = ((& git rev-parse --path-format=absolute --git-path index).Trim()) + '.lock'
        $ownedLockLength = (Get-Item -LiteralPath $indexLockPath).Length
        Remove-Item -LiteralPath $indexLockPath -Force
        [IO.File]::WriteAllBytes($indexLockPath, [byte[]]@())
        $blockedResult = Invoke-CheckpointChild `
            -Repository $externalEmptyLockRepo `
            -Message 'external empty lock blocked retry' `
            -File 'task.txt'
        $blockedArtifacts = Get-CheckpointArtifactState
        Assert-Equal 'external empty lock: reaches the exact hard-exit seam' $crashResult.ExitCode 83
        Assert-Equal 'external empty lock: owned lock was fully populated atomically' ($ownedLockLength -gt 0) $true
        Assert-Equal 'external empty lock: replacement fails closed' $blockedResult.ExitCode 2
        Assert-Equal 'external empty lock: replacement is reported as unowned' (
            $blockedResult.Stderr -match 'not owned by the checkpoint journal'
        ) $true
        Assert-Equal 'external empty lock: replacement remains present' (
            (Test-Path -LiteralPath $indexLockPath -PathType Leaf) -and
            (Get-Item -LiteralPath $indexLockPath).Length -eq 0
        ) $true
        Assert-Equal 'external empty lock: journal remains pending' $blockedArtifacts.Journal $true
        Assert-Equal 'external empty lock: HEAD remains unchanged' ((& git rev-parse HEAD).Trim()) $beforeHead
        if (Test-Path -LiteralPath $indexLockPath) {
            Remove-Item -LiteralPath $indexLockPath -Force
        }
        $recoveryResult = Invoke-CheckpointChild `
            -Repository $externalEmptyLockRepo `
            -Message 'external empty lock clean retry' `
            -File 'task.txt'
        Assert-Equal 'external empty lock: retry after external unlock recovers' $recoveryResult.ExitCode 0
        Assert-Equal 'external empty lock: explicit file is committed after recovery' (
            @(& git diff-tree --no-commit-id --name-only -r HEAD) -join ','
        ) 'task.txt'
    }
    finally {
        Pop-Location
    }

    $hardExitRepo = New-TestRepo 'journal-hard-exit'
    Push-Location $hardExitRepo
    try {
        [IO.File]::WriteAllText((Join-Path $hardExitRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $firstResult = Invoke-CheckpointChild `
            -Repository $hardExitRepo `
            -Message 'hard exit journal fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_PUBLICATION = '1'
            }
        $afterCrashHead = (& git rev-parse HEAD).Trim()
        $afterCrashStaged = @(& git diff --cached --name-only)
        $afterCrashArtifacts = Get-CheckpointArtifactState
        $recoveryResult = Invoke-CheckpointChild -Repository $hardExitRepo -Message 'hard exit recovery fixture' -File 'task.txt'
        $afterRecoveryHead = (& git rev-parse HEAD).Trim()
        $committed = @(& git diff-tree --no-commit-id --name-only -r HEAD)
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)
        $afterRecoveryArtifacts = Get-CheckpointArtifactState
        Assert-Equal 'journal recovery: hard exit occurs after index publication' $firstResult.ExitCode 86
        Assert-Equal 'journal recovery: hard exit leaves HEAD unchanged' $afterCrashHead $beforeHead
        Assert-Equal 'journal recovery: published index is observable before recovery' ($afterCrashStaged -join ',') 'task.txt'
        Assert-Equal 'journal recovery: hard exit leaves recovery journal' $afterCrashArtifacts.Journal $true
        Assert-Equal 'journal recovery: next invocation succeeds' $recoveryResult.ExitCode 0
        Assert-Equal 'journal recovery: next invocation advances HEAD' ($afterRecoveryHead -ne $beforeHead) $true
        Assert-Equal 'journal recovery: explicit modification is committed' ($committed -join ',') 'task.txt'
        Assert-Equal 'journal recovery: real index is clean' ($staged -join ',') ''
        Assert-Equal 'journal recovery: working tree is clean' ($working -join ',') ''
        Assert-Equal 'journal recovery: journal removed' $afterRecoveryArtifacts.Journal $false
        Assert-Equal 'journal recovery: backup removed' $afterRecoveryArtifacts.Backup $false
        Assert-Equal 'journal recovery: index lock removed' $afterRecoveryArtifacts.IndexLock $false
        Assert-Equal 'journal recovery: quarantine removed' $afterRecoveryArtifacts.QuarantineArtifacts 0
    } finally {
        Pop-Location
    }

    $lockBindingRepo = New-TestRepo 'index-lock-handle-binding'
    Push-Location $lockBindingRepo
    try {
        [IO.File]::WriteAllText(
            (Join-Path $lockBindingRepo 'task.txt'),
            "task-change`n",
            [Text.Encoding]::UTF8
        )
        $bindingResult = Invoke-CheckpointChild `
            -Repository $lockBindingRepo `
            -Message 'index lock handle binding fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_REWRITE_INDEX_LOCK_AFTER_CLAIM = '1'
            }
        Assert-Equal 'index-lock-binding: checkpoint succeeds' $bindingResult.ExitCode 0
        Assert-Equal 'index-lock-binding: competing rewrite is blocked by the bound handle' (
            $bindingResult.Stdout -match 'TEST index.lock competing rewrite blocked'
        ) $true
        Assert-Equal 'index-lock-binding: explicit file is committed' (
            @(& git diff-tree --no-commit-id --name-only -r HEAD) -join ','
        ) 'task.txt'
        Assert-Equal 'index-lock-binding: no index lock remains' (
            Get-CheckpointArtifactState
        ).IndexLock $false
    }
    finally {
        Pop-Location
    }

    $cleanupClaimRepo = New-TestRepo 'cleanup-lock-claim'
    Push-Location $cleanupClaimRepo
    try {
        [IO.File]::WriteAllText(
            (Join-Path $cleanupClaimRepo 'task.txt'),
            "task-change`n",
            [Text.Encoding]::UTF8
        )
        $cleanupCrash = Invoke-CheckpointChild `
            -Repository $cleanupClaimRepo `
            -Message 'cleanup lock claim crash fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_LOCK_ACQUIRE = '1'
            }
        $cleanupRace = Invoke-CheckpointChild `
            -Repository $cleanupClaimRepo `
            -Message 'cleanup lock claim race fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_CREATE_EXTERNAL_LOCK_DURING_CLEANUP = '1'
            }
        $cleanupIndexLock = ((& git rev-parse --path-format=absolute --git-path index).Trim()) + '.lock'
        $cleanupRaceArtifacts = Get-CheckpointArtifactState
        Assert-Equal 'cleanup-lock-claim: fixture reaches the exact hard-exit seam' $cleanupCrash.ExitCode 83
        Assert-Equal 'cleanup-lock-claim: recovery fails closed on the new external lock' $cleanupRace.ExitCode 2
        Assert-Equal 'cleanup-lock-claim: verified owned lock is atomically claimed before external replacement' (
            $cleanupRace.Stdout -match 'TEST external index.lock created after cleanup claim'
        ) $true
        Assert-Equal 'cleanup-lock-claim: new external lock remains present' (
            (Test-Path -LiteralPath $cleanupIndexLock -PathType Leaf) -and
            (Get-Item -LiteralPath $cleanupIndexLock).Length -eq 0
        ) $true
        Assert-Equal 'cleanup-lock-claim: recovery journal remains pending' $cleanupRaceArtifacts.Journal $true
        if (Test-Path -LiteralPath $cleanupIndexLock) {
            Remove-Item -LiteralPath $cleanupIndexLock -Force
        }
        $cleanupRetry = Invoke-CheckpointChild `
            -Repository $cleanupClaimRepo `
            -Message 'cleanup lock claim retry fixture' `
            -File 'task.txt'
        Assert-Equal 'cleanup-lock-claim: retry after external unlock succeeds' $cleanupRetry.ExitCode 0
    }
    finally {
        Pop-Location
    }

    $restoreReplaceRepo = New-TestRepo 'restore-replace-lock'
    Push-Location $restoreReplaceRepo
    try {
        [IO.File]::WriteAllText(
            (Join-Path $restoreReplaceRepo 'task.txt'),
            "task-change`n",
            [Text.Encoding]::UTF8
        )
        $restoreOldIndexHash = Get-RepositoryIndexHash
        $restoreCrash = Invoke-CheckpointChild `
            -Repository $restoreReplaceRepo `
            -Message 'restore replace crash fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_PUBLICATION = '1'
            }
        $restoreRace = Invoke-CheckpointChild `
            -Repository $restoreReplaceRepo `
            -Message 'restore replace race fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_CREATE_EXTERNAL_LOCK_AFTER_RECOVERY_REPLACE = '1'
            }
        $restoreIndexLock = ((& git rev-parse --path-format=absolute --git-path index).Trim()) + '.lock'
        $restoreRaceArtifacts = Get-CheckpointArtifactState
        Assert-Equal 'restore-replace-lock: fixture reaches the exact hard-exit seam' $restoreCrash.ExitCode 86
        Assert-Equal 'restore-replace-lock: recovery fails closed on the new external lock' $restoreRace.ExitCode 2
        Assert-Equal 'restore-replace-lock: replacement seam creates a new external lock' (
            $restoreRace.Stdout -match 'TEST external index.lock created after recovery replace'
        ) $true
        Assert-Equal 'restore-replace-lock: new external lock remains present' (
            (Test-Path -LiteralPath $restoreIndexLock -PathType Leaf) -and
            (Get-Item -LiteralPath $restoreIndexLock).Length -eq 0
        ) $true
        Assert-Equal 'restore-replace-lock: old index bytes are restored' (
            Get-RepositoryIndexHash
        ) $restoreOldIndexHash
        Assert-Equal 'restore-replace-lock: recovery journal remains pending' $restoreRaceArtifacts.Journal $true
        if (Test-Path -LiteralPath $restoreIndexLock) {
            Remove-Item -LiteralPath $restoreIndexLock -Force
        }
        $restoreRetry = Invoke-CheckpointChild `
            -Repository $restoreReplaceRepo `
            -Message 'restore replace retry fixture' `
            -File 'task.txt'
        Assert-Equal 'restore-replace-lock: retry after external unlock succeeds' $restoreRetry.ExitCode 0
    }
    finally {
        Pop-Location
    }

    $thirdPartyRepo = New-TestRepo 'journal-third-party'
    Push-Location $thirdPartyRepo
    try {
        [IO.File]::WriteAllText((Join-Path $thirdPartyRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $thirdPartyRepo 'user.txt'), "user-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $crashResult = Invoke-CheckpointChild `
            -Repository $thirdPartyRepo `
            -Message 'third party recovery fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_HARD_EXIT_AFTER_INDEX_PUBLICATION = '1'
            }
        Invoke-Git @('add', '--', 'user.txt')
        $recoveryResult = Invoke-CheckpointChild -Repository $thirdPartyRepo -Message 'third party recovery retry' -File 'task.txt'
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only | Sort-Object)
        $artifacts = Get-CheckpointArtifactState
        Assert-Equal 'journal third-party: fixture reaches hard exit' $crashResult.ExitCode 86
        Assert-Equal 'journal third-party: recovery fails closed' $recoveryResult.ExitCode 2
        Assert-Equal 'journal third-party: HEAD remains unchanged' $afterHead $beforeHead
        Assert-Equal 'journal third-party: third-party index state is preserved' ($staged -join ',') 'task.txt,user.txt'
        Assert-Equal 'journal third-party: pending journal is preserved' $artifacts.Journal $true
        Assert-Equal 'journal third-party: old-index backup is preserved' $artifacts.Backup $true
        Assert-Equal 'journal third-party: no index lock is left' $artifacts.IndexLock $false
    } finally {
        Pop-Location
    }

    $headIdentityRepo = New-TestRepo 'head-identity'
    Push-Location $headIdentityRepo
    try {
        $initialBranch = (& git symbolic-ref --short HEAD).Trim()
        $initialRef = (& git symbolic-ref HEAD).Trim()
        $beforeHead = (& git rev-parse HEAD).Trim()
        Invoke-Git @('branch', 'same-oid')
        [IO.File]::WriteAllText((Join-Path $headIdentityRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $hookPath = Join-Path $headIdentityRepo '.empty-hooks/pre-commit'
        [IO.File]::WriteAllText(
            $hookPath,
            "#!/bin/sh`ngit symbolic-ref HEAD refs/heads/same-oid`nexit 0`n",
            (New-Object Text.UTF8Encoding($false))
        )
        $checkpointResult = Invoke-CheckpointChild -Repository $headIdentityRepo -Message 'symbolic head identity fixture' -File 'task.txt'
        $afterRef = (& git symbolic-ref HEAD).Trim()
        $initialRefOid = (& git rev-parse $initialRef).Trim()
        $sameOid = (& git rev-parse refs/heads/same-oid).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)
        $artifacts = Get-CheckpointArtifactState
        Assert-Equal 'head identity: same-OID branch switch fails closed' $checkpointResult.ExitCode 2
        Assert-Equal 'head identity: switched symbolic HEAD is preserved' $afterRef 'refs/heads/same-oid'
        Assert-Equal 'head identity: original branch ref is unchanged' $initialRefOid $beforeHead
        Assert-Equal 'head identity: switched branch ref is unchanged' $sameOid $beforeHead
        Assert-Equal 'head identity: old index is restored' ($staged -join ',') ''
        Assert-Equal 'head identity: explicit modification is preserved' ($working -join ',') 'task.txt'
        Assert-Equal 'head identity: journal removed' $artifacts.Journal $false
        Assert-Equal 'head identity: backup removed' $artifacts.Backup $false
        Assert-Equal 'head identity: index lock removed' $artifacts.IndexLock $false
        Assert-Equal 'head identity: quarantine removed' $artifacts.QuarantineArtifacts 0
        Assert-Equal 'head identity: fixture began on another branch' ($initialBranch -ne 'same-oid') $true
    } finally {
        Pop-Location
    }

    $detachedRepo = New-TestRepo 'detached-head'
    Push-Location $detachedRepo
    try {
        Invoke-Git @('checkout', '--detach', '-q', 'HEAD')
        [IO.File]::WriteAllText((Join-Path $detachedRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointChild -Repository $detachedRepo -Message 'detached HEAD fixture' -File 'task.txt'
        $afterHead = (& git rev-parse HEAD).Trim()
        $symbolicHead = @(& git symbolic-ref -q HEAD)
        $symbolicCode = $LASTEXITCODE
        $committed = @(& git diff-tree --no-commit-id --name-only -r HEAD)
        $staged = @(& git diff --cached --name-only)
        $artifacts = Get-CheckpointArtifactState
        Assert-Equal 'detached HEAD: checkpoint succeeds' $checkpointResult.ExitCode 0
        Assert-Equal 'detached HEAD: HEAD advances' ($afterHead -ne $beforeHead) $true
        Assert-Equal 'detached HEAD: identity remains detached' $symbolicCode 1
        Assert-Equal 'detached HEAD: no symbolic ref appears' ($symbolicHead -join ',') ''
        Assert-Equal 'detached HEAD: explicit modification is committed' ($committed -join ',') 'task.txt'
        Assert-Equal 'detached HEAD: real index is clean' ($staged -join ',') ''
        Assert-Equal 'detached HEAD: journal removed' $artifacts.Journal $false
        Assert-Equal 'detached HEAD: backup removed' $artifacts.Backup $false
        Assert-Equal 'detached HEAD: index lock removed' $artifacts.IndexLock $false
    } finally {
        Pop-Location
    }

    $refRaceRepo = New-TestRepo 'ref-race'
    Push-Location $refRaceRepo
    try {
        [IO.File]::WriteAllText((Join-Path $refRaceRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $headRef = (& git symbolic-ref HEAD).Trim()
        $tree = (& git rev-parse ($beforeHead + '^{tree}')).Trim()
        $beforeIndexHash = Get-RepositoryIndexHash
        $externalCommit = (& git commit-tree $tree -p $beforeHead -m 'external ref mutation').Trim()
        if ($LASTEXITCODE -ne 0 -or -not $externalCommit) {
            throw 'Cannot create the external ref mutation commit.'
        }
        $checkpointResult = Invoke-CheckpointChild `
            -Repository $refRaceRepo `
            -Message 'ref mutation before CAS fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_REF_MUTATION_BEFORE_CAS = $externalCommit
            }
        $afterRefOid = (& git rev-parse $headRef).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)
        $artifacts = Get-CheckpointArtifactState
        Assert-Equal 'ref-race: checkpoint fails closed' $checkpointResult.ExitCode 2
        Assert-Equal 'ref-race: external ref mutation is preserved' $afterRefOid $externalCommit
        Assert-Equal 'ref-race: old index is restored' ($staged -join ',') ''
        Assert-Equal 'ref-race: old index bytes are restored' (Get-RepositoryIndexHash) $beforeIndexHash
        Assert-Equal 'ref-race: index tree matches the old tree' ((& git write-tree).Trim()) $tree
        Assert-Equal 'ref-race: explicit modification is preserved' ($working -join ',') 'task.txt'
        Assert-Equal 'ref-race: journal removed' $artifacts.Journal $false
        Assert-Equal 'ref-race: backup removed' $artifacts.Backup $false
        Assert-Equal 'ref-race: index lock removed' $artifacts.IndexLock $false
        Assert-Equal 'ref-race: quarantine removed' $artifacts.QuarantineArtifacts 0
    } finally {
        Pop-Location
    }

    $refRaceNewTreeRepo = New-TestRepo 'ref-race-new-tree'
    Push-Location $refRaceNewTreeRepo
    try {
        [IO.File]::WriteAllText((Join-Path $refRaceNewTreeRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $headRef = (& git symbolic-ref HEAD).Trim()
        $newTree = Get-WorkingTreeOidForExplicitPath -Repository $refRaceNewTreeRepo -Path 'task.txt'
        $externalNewTreeCommit = (& git commit-tree $newTree -p $beforeHead -m 'external new-tree ref mutation').Trim()
        if ($LASTEXITCODE -ne 0 -or -not $externalNewTreeCommit) {
            throw 'Cannot create the external new-tree ref mutation commit.'
        }
        $checkpointResult = Invoke-CheckpointChild `
            -Repository $refRaceNewTreeRepo `
            -Message 'new-tree ref mutation before CAS fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_REF_MUTATION_BEFORE_CAS = $externalNewTreeCommit
            }
        $afterRefOid = (& git rev-parse $headRef).Trim()
        $staged = @(& git diff --cached --name-only)
        $working = @(& git diff --name-only)
        $artifacts = Get-CheckpointArtifactState
        Assert-Equal 'ref-race new tree: checkpoint fails closed' $checkpointResult.ExitCode 2
        Assert-Equal 'ref-race new tree: external ref mutation is preserved' $afterRefOid $externalNewTreeCommit
        Assert-Equal 'ref-race new tree: publish index is preserved' ($staged -join ',') ''
        Assert-Equal 'ref-race new tree: working tree is clean' ($working -join ',') ''
        Assert-Equal 'ref-race new tree: index tree matches the external tree' ((& git write-tree).Trim()) $newTree
        Assert-Equal 'ref-race new tree: journal removed' $artifacts.Journal $false
        Assert-Equal 'ref-race new tree: backup removed' $artifacts.Backup $false
        Assert-Equal 'ref-race new tree: index lock removed' $artifacts.IndexLock $false
        Assert-Equal 'ref-race new tree: quarantine removed' $artifacts.QuarantineArtifacts 0
    } finally {
        Pop-Location
    }

    $detachedRefRaceNewTreeRepo = New-TestRepo 'detached-ref-race-new-tree'
    Push-Location $detachedRefRaceNewTreeRepo
    try {
        Invoke-Git @('checkout', '--detach', '-q', 'HEAD')
        [IO.File]::WriteAllText((Join-Path $detachedRefRaceNewTreeRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $newTree = Get-WorkingTreeOidForExplicitPath -Repository $detachedRefRaceNewTreeRepo -Path 'task.txt'
        $externalNewTreeCommit = (& git commit-tree $newTree -p $beforeHead -m 'detached external new-tree ref mutation').Trim()
        if ($LASTEXITCODE -ne 0 -or -not $externalNewTreeCommit) {
            throw 'Cannot create the detached external new-tree ref mutation commit.'
        }
        $checkpointResult = Invoke-CheckpointChild `
            -Repository $detachedRefRaceNewTreeRepo `
            -Message 'detached new-tree ref mutation before CAS fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_REF_MUTATION_BEFORE_CAS = $externalNewTreeCommit
            }
        $afterHead = (& git rev-parse HEAD).Trim()
        $symbolicHead = @(& git symbolic-ref -q HEAD)
        $symbolicExitCode = $LASTEXITCODE
        $artifacts = Get-CheckpointArtifactState
        Assert-Equal 'detached ref-race new tree: checkpoint fails closed' $checkpointResult.ExitCode 2
        Assert-Equal 'detached ref-race new tree: external HEAD mutation is preserved' $afterHead $externalNewTreeCommit
        Assert-Equal 'detached ref-race new tree: identity remains detached' $symbolicExitCode 1
        Assert-Equal 'detached ref-race new tree: no symbolic ref appears' $symbolicHead.Count 0
        Assert-Equal 'detached ref-race new tree: index tree matches the external tree' ((& git write-tree).Trim()) $newTree
        Assert-Equal 'detached ref-race new tree: journal removed' $artifacts.Journal $false
        Assert-Equal 'detached ref-race new tree: backup removed' $artifacts.Backup $false
        Assert-Equal 'detached ref-race new tree: quarantine removed' $artifacts.QuarantineArtifacts 0
    } finally {
        Pop-Location
    }

    $refRaceThirdTreeRepo = New-TestRepo 'ref-race-third-tree'
    Push-Location $refRaceThirdTreeRepo
    try {
        [IO.File]::WriteAllText((Join-Path $refRaceThirdTreeRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $headRef = (& git symbolic-ref HEAD).Trim()
        [IO.File]::WriteAllText((Join-Path $refRaceThirdTreeRepo 'user.txt'), "external-user-change`n", [Text.Encoding]::UTF8)
        $thirdTree = Get-WorkingTreeOidForExplicitPath -Repository $refRaceThirdTreeRepo -Path 'user.txt'
        [IO.File]::WriteAllText((Join-Path $refRaceThirdTreeRepo 'user.txt'), "base-user`n", [Text.Encoding]::UTF8)
        $externalThirdTreeCommit = (& git commit-tree $thirdTree -p $beforeHead -m 'external third-tree ref mutation').Trim()
        if ($LASTEXITCODE -ne 0 -or -not $externalThirdTreeCommit) {
            throw 'Cannot create the external third-tree ref mutation commit.'
        }
        $checkpointResult = Invoke-CheckpointChild `
            -Repository $refRaceThirdTreeRepo `
            -Message 'third-tree ref mutation before CAS fixture' `
            -File 'task.txt' `
            -EnvironmentOverrides @{
                STEADYAGENT_TEST_MODE = '1'
                STEADYAGENT_TEST_ROOT = $resolvedRoot
                STEADYAGENT_TEST_REF_MUTATION_BEFORE_CAS = $externalThirdTreeCommit
            }
        $afterRefOid = (& git rev-parse $headRef).Trim()
        $artifacts = Get-CheckpointArtifactState
        $journalPath = (& git rev-parse --path-format=absolute --git-path steadyagent-checkpoint-journal.json).Trim()
        $backupPath = (& git rev-parse --path-format=absolute --git-path steadyagent-checkpoint-index.backup).Trim()
        $journal = [IO.File]::ReadAllText($journalPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -DateKind String
        $publishedIndexHash = Get-RepositoryIndexHash
        $backupIndexHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
        $journalHashBeforeRetry = (Get-FileHash -LiteralPath $journalPath -Algorithm SHA256).Hash
        Assert-Equal 'ref-race third tree: checkpoint fails closed' $checkpointResult.ExitCode 2
        Assert-Equal 'ref-race third tree: external ref mutation is preserved' $afterRefOid $externalThirdTreeCommit
        Assert-Equal 'ref-race third tree: journal remains for manual recovery' $artifacts.Journal $true
        Assert-Equal 'ref-race third tree: backup remains for manual recovery' $artifacts.Backup $true
        Assert-Equal 'ref-race third tree: index lock is not removed by path' $artifacts.IndexLock $false
        Assert-Equal 'ref-race third tree: quarantine remains journal-bound' ($artifacts.QuarantineArtifacts -gt 0) $true
        Assert-Equal 'ref-race third tree: journal binds the old-index backup' ([string]$journal.old_index_hash) $backupIndexHash
        Assert-Equal 'ref-race third tree: journal binds the published index' ([string]$journal.publish_index_hash) $publishedIndexHash
        Assert-Equal 'ref-race third tree: published index differs from old index' ($publishedIndexHash -cne $backupIndexHash) $true
        $retryResult = Invoke-CheckpointChild `
            -Repository $refRaceThirdTreeRepo `
            -Message 'third-tree recovery retry fixture' `
            -File 'task.txt'
        Assert-Equal 'ref-race third tree: retry remains fail closed' $retryResult.ExitCode 2
        Assert-Equal 'ref-race third tree: retry preserves the external ref' ((& git rev-parse $headRef).Trim()) $externalThirdTreeCommit
        Assert-Equal 'ref-race third tree: retry preserves the published index' (Get-RepositoryIndexHash) $publishedIndexHash
        Assert-Equal 'ref-race third tree: retry preserves the journal bytes' ((Get-FileHash -LiteralPath $journalPath -Algorithm SHA256).Hash) $journalHashBeforeRetry
    } finally {
        Pop-Location
    }

    $concurrentRepo = New-TestRepo 'concurrent'
    Push-Location $concurrentRepo
    try {
        [IO.File]::WriteAllText((Join-Path $concurrentRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $hookPath = Join-Path $concurrentRepo '.empty-hooks/pre-commit'
        [IO.File]::WriteAllText($hookPath, "#!/bin/sh`nsleep 2`nexit 0`n", (New-Object Text.UTF8Encoding($false)))
        $firstProcess = Start-CheckpointChild -Repository $concurrentRepo -Message 'first concurrent fixture' -File 'task.txt'
        Start-Sleep -Milliseconds 400
        $secondProcess = Start-CheckpointChild -Repository $concurrentRepo -Message 'second concurrent fixture' -File 'task.txt'
        $secondResult = Complete-CheckpointChild -Process $secondProcess
        $firstResult = Complete-CheckpointChild -Process $firstProcess
        $committed = @(& git diff-tree --no-commit-id --name-only -r HEAD)
        Assert-Equal 'concurrent: first checkpoint succeeds' $firstResult.ExitCode 0
        Assert-Equal 'concurrent: second checkpoint fails closed on lock' $secondResult.ExitCode 2
        Assert-Equal 'concurrent: commit contains explicit task only' ($committed -join ',') 'task.txt'
    } finally {
        Pop-Location
    }
} finally {
    if (Test-Path -LiteralPath $resolvedRoot) {
        $finalRoot = [System.IO.Path]::GetFullPath($resolvedRoot)
        if ($finalRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $finalRoot) -cmatch '^steadyagent-git-checkpoint-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $finalRoot -Recurse -Force
        }
    }
}

Write-Host ''
Write-SemanticCheck -Id 'checkpoint.isolated-index-cas-compensation' -Cases @(
    'final head CAS: exact post-bind switch seam is reached',
    'final head CAS: checkpoint succeeds after blocking the switch',
    'final head CAS: captured symbolic HEAD is preserved',
    'final head CAS: original branch ref advances',
    'final head CAS: switched branch ref is unchanged',
    'final head CAS: published index is clean',
    'final head CAS: journal is finalized safely',
    'Git parent pin: exact post-pin swap seam is reached',
    'Git parent pin: checkpoint succeeds after blocked swap',
    'Git parent pin: Git directory remains a normal directory',
    'Git parent pin: no parked Git directory is created',
    'Git parent pin: escape tree remains byte-identical',
    'same-content external lock: fixture reaches the exact hard-exit seam',
    'same-content external lock: replacement has identical bytes',
    'same-content external lock: different identity fails closed',
    'same-content external lock: identity mismatch is reported',
    'same-content external lock: replacement remains present',
    'same-content external lock: original owned file remains parked',
    'same-content external lock: recovery journal remains pending',
    'same-content external lock: HEAD remains unchanged',
    'same-content external lock: retry after external unlock succeeds',
    'protected hardlink: checkpoint fails closed',
    'protected hardlink: HEAD remains unchanged',
    'protected hardlink: real index bytes remain unchanged',
    'protected hardlink: alias remains untracked',
    'normal: checkpoint succeeds',
    'normal: commits explicit task only',
    'no scope: checkpoint fails closed',
    'all switch: checkpoint succeeds when explicitly requested',
    'all switch: commits every changed path',
    'all switch: real index is clean after publication',
    'all protected path: returns exit 2',
    'all protected path: real index remains clean',
    'all protected path: target blob absent after checkpoint',
    'all protected path: fsck has no target dangling blob',
    'all large file: returns exit 2',
    'all large file: target blob absent after checkpoint',
    'all large file: fsck has no target dangling blob',
    'all dry-run: reports modified path',
    'all dry-run: reports deleted path',
    'all dry-run: reports untracked path',
    'all dry-run: real index remains clean',
    'all and files: mutually exclusive scopes are rejected',
    'rename: all checkpoint succeeds',
    'rename: old and new paths form one tracked rename',
    'scope: Windows separator path succeeds',
    'scope: Windows separator normalizes to Git path',
    'index-race: checkpoint fails closed',
    'index-race: concurrent user stage preserved',
    'publish-failure: HEAD CAS rolls back',
    'publish-failure: real index remains unchanged',
    'index-lock-acquire: reaches the exact hard-exit seam',
    'index-lock-acquire: crash leaves durable journal',
    'index-lock-acquire: retry recovers and commits',
    'index-lock-acquire: retry removes index lock',
    'index-lock-write: reaches the exact hard-exit seam',
    'index-lock-write: crash leaves durable journal',
    'index-lock-write: retry recovers and commits',
    'index-lock-write: retry removes index lock',
    'index-backup: reaches the exact hard-exit seam',
    'index-backup: crash leaves durable journal',
    'index-backup: retry recovers and commits',
    'index-backup: retry removes index lock',
    'external empty lock: owned lock was fully populated atomically',
    'external empty lock: replacement fails closed',
    'external empty lock: replacement remains present',
    'external empty lock: retry after external unlock recovers',
    'journal recovery: hard exit occurs after index publication',
    'journal recovery: hard exit leaves recovery journal',
    'journal recovery: next invocation succeeds',
    'journal recovery: explicit modification is committed',
    'journal recovery: journal removed',
    'journal recovery: index lock removed',
    'index-lock-binding: checkpoint succeeds',
    'index-lock-binding: competing rewrite is blocked by the bound handle',
    'index-lock-binding: explicit file is committed',
    'index-lock-binding: no index lock remains',
    'cleanup-lock-claim: fixture reaches the exact hard-exit seam',
    'cleanup-lock-claim: recovery fails closed on the new external lock',
    'cleanup-lock-claim: verified owned lock is atomically claimed before external replacement',
    'cleanup-lock-claim: new external lock remains present',
    'cleanup-lock-claim: recovery journal remains pending',
    'cleanup-lock-claim: retry after external unlock succeeds',
    'restore-replace-lock: fixture reaches the exact hard-exit seam',
    'restore-replace-lock: recovery fails closed on the new external lock',
    'restore-replace-lock: replacement seam creates a new external lock',
    'restore-replace-lock: new external lock remains present',
    'restore-replace-lock: old index bytes are restored',
    'restore-replace-lock: recovery journal remains pending',
    'restore-replace-lock: retry after external unlock succeeds',
    'journal third-party: fixture reaches hard exit',
    'journal third-party: recovery fails closed',
    'journal third-party: third-party index state is preserved',
    'journal third-party: pending journal is preserved',
    'journal third-party: no index lock is left',
    'head identity: same-OID branch switch fails closed',
    'head identity: switched symbolic HEAD is preserved',
    'head identity: original branch ref is unchanged',
    'head identity: old index is restored',
    'head identity: explicit modification is preserved',
    'head identity: journal removed',
    'detached HEAD: checkpoint succeeds',
    'detached HEAD: HEAD advances',
    'detached HEAD: identity remains detached',
    'detached HEAD: explicit modification is committed',
    'detached HEAD: journal removed',
    'ref-race: checkpoint fails closed',
    'ref-race: external ref mutation is preserved',
    'ref-race: old index is restored',
    'ref-race: old index bytes are restored',
    'ref-race: index tree matches the old tree',
    'ref-race: explicit modification is preserved',
    'ref-race: journal removed',
    'ref-race new tree: checkpoint fails closed',
    'ref-race new tree: external ref mutation is preserved',
    'ref-race new tree: publish index is preserved',
    'ref-race new tree: working tree is clean',
    'ref-race new tree: index tree matches the external tree',
    'ref-race new tree: journal removed',
    'ref-race new tree: backup removed',
    'ref-race new tree: index lock removed',
    'ref-race new tree: quarantine removed',
    'detached ref-race new tree: checkpoint fails closed',
    'detached ref-race new tree: external HEAD mutation is preserved',
    'detached ref-race new tree: identity remains detached',
    'detached ref-race new tree: no symbolic ref appears',
    'detached ref-race new tree: index tree matches the external tree',
    'detached ref-race new tree: journal removed',
    'detached ref-race new tree: backup removed',
    'detached ref-race new tree: quarantine removed',
    'ref-race third tree: checkpoint fails closed',
    'ref-race third tree: external ref mutation is preserved',
    'ref-race third tree: journal remains for manual recovery',
    'ref-race third tree: backup remains for manual recovery',
    'ref-race third tree: index lock is not removed by path',
    'ref-race third tree: quarantine remains journal-bound',
    'ref-race third tree: journal binds the old-index backup',
    'ref-race third tree: journal binds the published index',
    'ref-race third tree: published index differs from old index',
    'ref-race third tree: retry remains fail closed',
    'ref-race third tree: retry preserves the external ref',
    'ref-race third tree: retry preserves the published index',
    'ref-race third tree: retry preserves the journal bytes',
    'concurrent: second checkpoint fails closed on lock'
)
Write-SemanticCheck -Id 'checkpoint.quarantined-object-publication' -Cases @(
    'object fanout junction: exact pre-publication seam is reached',
    'object fanout junction: checkpoint fails closed',
    'object fanout junction: reports bound fanout refusal',
    'object fanout junction: HEAD remains unchanged',
    'object fanout junction: real index remains unchanged',
    'object fanout junction: escape sentinel remains byte-identical',
    'object fanout junction: no object is published into escape tree',
    'quarantine ancestor junction: fixture reaches the exact hard-exit seam',
    'quarantine ancestor junction: recovery fails closed',
    'quarantine ancestor junction: ancestor reparse is reported',
    'quarantine ancestor junction: external sentinel remains byte-identical',
    'quarantine ancestor junction: HEAD remains unchanged',
    'quarantine ancestor junction: real index remains byte-identical',
    'quarantine ancestor junction: real object inventory remains byte-identical',
    'quarantine ancestor junction: original transaction remains parked',
    'blocked risk: returns exit 2',
    'blocked risk: HEAD unchanged',
    'blocked risk: real index bytes unchanged',
    'blocked risk: target blob absent before checkpoint',
    'blocked risk: target blob absent after checkpoint',
    'blocked risk: object inventory unchanged',
    'blocked risk: fsck has no target dangling blob',
    'all protected path: returns exit 2',
    'all protected path: HEAD unchanged',
    'all protected path: real index bytes unchanged',
    'all protected path: target blob absent before checkpoint',
    'all protected path: target blob absent after checkpoint',
    'all protected path: object inventory unchanged',
    'all protected path: fsck has no target dangling blob',
    'protected dry-run: explicit object inventory unchanged',
    'protected dry-run: all object inventory unchanged',
    'protected dry-run: target blob remains absent',
    'protected dry-run: fsck has no target dangling blob',
    'pre-add growth: shim reaches the exact add seam',
    'pre-add growth: returns exit 2',
    'pre-add growth: HEAD unchanged',
    'pre-add growth: real index bytes unchanged',
    'pre-add growth: target blob absent before checkpoint',
    'pre-add growth: target blob absent after checkpoint',
    'pre-add growth: object inventory unchanged',
    'pre-add growth: fsck has no target dangling blob',
    'pre-add growth: quarantine leaves no artifacts',
    'index ABA: exact stage-copy-unstage seam is reached',
    'index ABA: checkpoint succeeds without reviving external staged state',
    'index ABA: final index does not revive the external staged path'
)
if ($script:fail -eq 0 -and $script:results.Count -ge 52) {
    Write-Host 'SEMANTIC PASS checkpoint.adversarial-suite-executed'
} else {
    Write-Host ('FAIL  semantic evidence checkpoint.adversarial-suite-executed cases=' + $script:results.Count)
    $script:fail++
}
Write-Host ('=== Git checkpoint test: ' + $script:pass + ' passed, ' + $script:fail + ' failed ===')
if ($script:fail -gt 0) { exit 1 }
exit 0

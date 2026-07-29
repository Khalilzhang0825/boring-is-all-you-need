[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:pass = 0
$script:fail = 0
$checkpoint = Join-Path $PSScriptRoot 'git-checkpoint.ps1'
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase ('git-checkpoint-test-' + [guid]::NewGuid().ToString('N'))
$resolvedRoot = [System.IO.Path]::GetFullPath($tempRoot)

if (-not $resolvedRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Temporary root escaped the system temp directory.'
}

function Assert-Equal {
    param([string]$Name, [object]$Actual, [object]$Expected)
    if ([string]$Actual -eq [string]$Expected) {
        Write-Host ('PASS  ' + $Name)
        $script:pass++
    } else {
        Write-Host ('FAIL  ' + $Name + '  expected=' + [string]$Expected + ' actual=' + [string]$Actual)
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
        [switch]$DryRun
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $checkpoint + '" -Message "' + $Message + '" -Files "' + $File + '"'
    if ($DryRun) { $psi.Arguments += ' -DryRun' }
    $psi.WorkingDirectory = $Repository
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    return [System.Diagnostics.Process]::Start($psi)
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
        [switch]$DryRun
    )
    $process = Start-CheckpointChild -Repository $Repository -Message $Message -File $File -DryRun:$DryRun
    return Complete-CheckpointChild -Process $process
}

New-Item -ItemType Directory -Path $resolvedRoot -Force | Out-Null
try {
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
        $beforeHead = (& git rev-parse HEAD).Trim()
        $checkpointResult = Invoke-CheckpointChild -Repository $blockedRepo -Message 'blocked risk fixture' -File '.env'
        $afterHead = (& git rev-parse HEAD).Trim()
        $staged = @(& git diff --cached --name-only)
        $untracked = @(& git ls-files --others --exclude-standard)

        Assert-Equal 'blocked risk: returns exit 2' $checkpointResult.ExitCode 2
        Assert-Equal 'blocked risk: HEAD unchanged' $afterHead $beforeHead
        Assert-Equal 'blocked risk: index restored' ($staged -join ',') ''
        Assert-Equal 'blocked risk: file remains untracked' ($untracked -join ',') '.env'
    } finally {
        Pop-Location
    }

    $publicKeyRepo = New-TestRepo 'public-key'
    Push-Location $publicKeyRepo
    try {
        [System.IO.File]::WriteAllText((Join-Path $publicKeyRepo 'id_ed25519.pub'), "fixture public key`n", [System.Text.Encoding]::UTF8)
        $checkpointResult = Invoke-CheckpointChild -Repository $publicKeyRepo -Message 'public key fixture' -File 'id_ed25519.pub'
        $committed = @(& git show --pretty= --name-only HEAD)

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
        Assert-Equal 'deletion: checkpoint succeeds' $checkpointResult.ExitCode 0
        Assert-Equal 'deletion: explicit file committed' ($committed -join ',') 'task.txt'
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

    $indexRaceRepo = New-TestRepo 'index-race'
    Push-Location $indexRaceRepo
    try {
        [IO.File]::WriteAllText((Join-Path $indexRaceRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $indexRaceRepo 'user.txt'), "user-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $env:STEADYAGENT_TEST_MODE = '1'
        $env:STEADYAGENT_TEST_INDEX_MUTATION_PATH = 'user.txt'
        try {
            $checkpointResult = Invoke-CheckpointChild -Repository $indexRaceRepo -Message 'index publication race fixture' -File 'task.txt'
        } finally {
            Remove-Item Env:STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
            Remove-Item Env:STEADYAGENT_TEST_INDEX_MUTATION_PATH -ErrorAction SilentlyContinue
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

    $publishFailureRepo = New-TestRepo 'publish-failure'
    Push-Location $publishFailureRepo
    try {
        [IO.File]::WriteAllText((Join-Path $publishFailureRepo 'task.txt'), "task-change`n", [Text.Encoding]::UTF8)
        $beforeHead = (& git rev-parse HEAD).Trim()
        $env:STEADYAGENT_TEST_MODE = '1'
        $env:STEADYAGENT_TEST_INDEX_PUBLICATION_FAILURE = '1'
        try {
            $checkpointResult = Invoke-CheckpointChild -Repository $publishFailureRepo -Message 'index publication failure fixture' -File 'task.txt'
        } finally {
            Remove-Item Env:STEADYAGENT_TEST_MODE -ErrorAction SilentlyContinue
            Remove-Item Env:STEADYAGENT_TEST_INDEX_PUBLICATION_FAILURE -ErrorAction SilentlyContinue
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
            (Split-Path -Leaf $finalRoot).StartsWith('git-checkpoint-test-')) {
            Remove-Item -LiteralPath $finalRoot -Recurse -Force
        }
    }
}

Write-Host ''
Write-Host ('=== Git checkpoint test: ' + $script:pass + ' passed, ' + $script:fail + ' failed ===')
if ($script:fail -gt 0) { exit 1 }
exit 0

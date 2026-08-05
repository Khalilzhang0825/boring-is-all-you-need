[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Passed = 0
$script:Failed = 0
$helper = Join-Path $PSScriptRoot "release-whitespace.ps1"
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $tempBase ("steadyagent-release-whitespace-" + [guid]::NewGuid().ToString("N"))
$fixtureFull = [IO.Path]::GetFullPath($fixtureRoot)

function Assert-Equal {
    param([string]$Name, [object]$Actual, [object]$Expected)
    if ([string]$Actual -eq [string]$Expected) {
        $script:Passed++
        Write-Host ("PASS " + $Name)
    }
    else {
        $script:Failed++
        Write-Host ("FAIL " + $Name + " expected=" + [string]$Expected + " actual=" + [string]$Actual)
    }
}

function Invoke-Git {
    param([string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw ("git failed: " + ($GitArgs -join " "))
    }
}

function Write-FixtureText {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-ObjectInventory {
    param([string]$ObjectRoot)
    $rootFull = [IO.Path]::GetFullPath($ObjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $items = foreach ($file in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File)) {
        $relative = $file.FullName.Substring($rootFull.Length).TrimStart(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        )
        $relative + ":" + (Get-FileSha256 -Path $file.FullName)
    }
    return (@($items | Sort-Object) -join "`n")
}

function Get-TempArtifactInventory {
    $items = @(
        Get-ChildItem -LiteralPath $tempBase -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name.StartsWith("steadyagent-whitespace-index-") -or
                $_.Name.StartsWith("steadyagent-git-stderr-")
            } |
            ForEach-Object { $_.FullName }
    )
    return (@($items | Sort-Object) -join "`n")
}

function Get-ProcessEnvironmentState {
    param([string]$Name)
    return [pscustomobject]@{
        Present = Test-Path ("Env:" + $Name)
        Value = [Environment]::GetEnvironmentVariable($Name, "Process")
    }
}

function Restore-ProcessEnvironmentState {
    param([string]$Name, [object]$State)
    if ($State.Present) {
        [Environment]::SetEnvironmentVariable($Name, [string]$State.Value, "Process")
    }
    else {
        [Environment]::SetEnvironmentVariable($Name, $null, "Process")
    }
}

function Assert-EnvironmentState {
    param([string]$Name, [object]$Expected)
    $actual = Get-ProcessEnvironmentState -Name $Name
    Assert-Equal ($Name + " presence is preserved") $actual.Present $Expected.Present
    Assert-Equal ($Name + " value is preserved") $actual.Value $Expected.Value
}

if (-not $fixtureFull.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Split-Path -Leaf $fixtureFull).StartsWith("steadyagent-release-whitespace-")) {
    throw "Fixture root escaped the system temp directory."
}

. $helper

$helperText = [IO.File]::ReadAllText($helper, [Text.Encoding]::UTF8)
Assert-Equal "helper does not mutate process Git isolation variables" (
    $helperText -notmatch '\$env:GIT_(?:INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES)\s*='
) $true
Assert-Equal "helper does not persist raw Git stderr to a temp file" (
    $helperText -notmatch "steadyagent-git-stderr-"
) $true
Assert-Equal "helper does not build WIP blobs with git add" (
    $helperText -notmatch '(?i)"add"\s*,\s*"-A"'
) $true

$environmentNames = @(
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_TRACE",
    "GIT_TRACE2_EVENT",
    "GIT_REDIRECT_STDERR",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_KEY_0",
    "GIT_CONFIG_VALUE_0",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_ATTR_NOSYSTEM",
    "GIT_EXTERNAL_DIFF",
    "GIT_DIFF_OPTS",
    "GIT_TERMINAL_PROMPT"
)
$isolationEnvironmentNames = @(
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR"
)
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = Get-ProcessEnvironmentState -Name $name
    [Environment]::SetEnvironmentVariable($name, $null, "Process")
}

New-Item -ItemType Directory -Path $fixtureFull -Force | Out-Null
try {
    Push-Location $fixtureFull
    try {
        Invoke-Git @("init", "-q")
        Invoke-Git @("config", "user.name", "Release Whitespace Test")
        Invoke-Git @("config", "user.email", "release-whitespace@example.invalid")
        Invoke-Git @("config", "core.autocrlf", "false")
        New-Item -ItemType Directory -Path (Join-Path $fixtureFull ".empty-hooks") -Force | Out-Null
        Invoke-Git @("config", "core.hooksPath", (Join-Path $fixtureFull ".empty-hooks"))
        Write-FixtureText -Path (Join-Path $fixtureFull "tracked.txt") -Text "baseline`n"
        Write-FixtureText -Path (Join-Path $fixtureFull "delete-me.txt") -Text "keep or delete`n"
        Invoke-Git @("add", "--", "tracked.txt", "delete-me.txt")
        Invoke-Git @("commit", "-q", "-m", "baseline")
        Invoke-Git @("branch", "-M", "main")
        $baseline = (& git rev-parse HEAD).Trim()

        Invoke-Git @("switch", "-q", "-c", "candidate")
        Write-FixtureText -Path (Join-Path $fixtureFull "tracked.txt") -Text "candidate`n"
        Invoke-Git @("add", "--", "tracked.txt")
        Invoke-Git @("commit", "-q", "-m", "candidate")
        $candidateHead = (& git rev-parse HEAD).Trim()

        $tracePath = Join-Path $fixtureFull "git-trace.log"
        $trace2Path = Join-Path $fixtureFull "git-trace2.json"
        $redirectPath = Join-Path $fixtureFull "git-redirect.log"
        $traceInjection = @{
            GIT_TRACE = $tracePath
            GIT_TRACE2_EVENT = $trace2Path
            GIT_REDIRECT_STDERR = $redirectPath
        }
        foreach ($name in $traceInjection.Keys) {
            [Environment]::SetEnvironmentVariable($name, [string]$traceInjection[$name], "Process")
        }
        $traceProbe = Invoke-ReleaseWhitespaceGit -GitArgs @("rev-parse", "HEAD")
        Assert-Equal "Git trace injection cannot alter a successful child command" $traceProbe.Code 0
        Assert-Equal "Git trace injection creates no external diagnostics" (
            -not (Test-Path -LiteralPath $tracePath) -and
            -not (Test-Path -LiteralPath $trace2Path) -and
            -not (Test-Path -LiteralPath $redirectPath)
        ) $true
        foreach ($name in $traceInjection.Keys) {
            Assert-Equal ($name + " parent value survives child sanitization") (
                [Environment]::GetEnvironmentVariable($name, "Process")
            ) ([string]$traceInjection[$name])
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }

        $configInjection = @{
            GIT_CONFIG_COUNT = "1"
            GIT_CONFIG_KEY_0 = "steadyagent.injected"
            GIT_CONFIG_VALUE_0 = "catalog-injection-marker"
            GIT_EXTERNAL_DIFF = "steadyagent-missing-external-diff"
            GIT_DIFF_OPTS = "--stat"
            GIT_TERMINAL_PROMPT = "1"
        }
        foreach ($name in $configInjection.Keys) {
            [Environment]::SetEnvironmentVariable($name, [string]$configInjection[$name], "Process")
        }
        $configProbe = Invoke-ReleaseWhitespaceGit -GitArgs @("config", "--get", "steadyagent.injected")
        Assert-Equal "Git config environment injection is absent from the child" (
            $configProbe.Code -ne 0 -and
            ([string]$configProbe.RawOutput -notmatch "catalog-injection-marker")
        ) $true
        foreach ($name in $configInjection.Keys) {
            Assert-Equal ($name + " parent value survives child sanitization") (
                [Environment]::GetEnvironmentVariable($name, "Process")
            ) ([string]$configInjection[$name])
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
        $sanitizedEnvironment = New-ReleaseWhitespaceGitEnvironment
        Assert-Equal "child Git environment disables terminal prompts" (
            [string]$sanitizedEnvironment["GIT_TERMINAL_PROMPT"]
        ) "0"
        Assert-Equal "child Git environment disables global config" (
            [string]$sanitizedEnvironment["GIT_CONFIG_GLOBAL"]
        ) "NUL"
        Assert-Equal "child Git environment disables system config" (
            [string]$sanitizedEnvironment["GIT_CONFIG_NOSYSTEM"]
        ) "1"
        Assert-Equal "child Git environment disables system attributes" (
            [string]$sanitizedEnvironment["GIT_ATTR_NOSYSTEM"]
        ) "1"

        Invoke-Git @("branch", "base-advanced", $baseline)
        Invoke-Git @("switch", "-q", "base-advanced")
        Write-FixtureText -Path (Join-Path $fixtureFull "base-only.txt") -Text "advanced base`n"
        Invoke-Git @("add", "--", "base-only.txt")
        Invoke-Git @("commit", "-q", "-m", "advance base")
        Invoke-Git @("switch", "-q", "candidate")

        $cleanResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "base-advanced"
        Assert-Equal "clean candidate passes" $cleanResult.Code 0
        Assert-Equal "advanced base resolves to candidate merge-base" $cleanResult.MergeBase $baseline

        $originalHome = Get-ProcessEnvironmentState -Name "HOME"
        $fakeHome = Join-Path $fixtureFull "fake-global-config-home"
        $fakeAttributes = Join-Path $fakeHome "global-attributes"
        $fakeExcludes = Join-Path $fakeHome "global-excludes"
        New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
        Write-FixtureText -Path $fakeAttributes -Text "tracked.txt binary`n"
        Write-FixtureText -Path $fakeExcludes -Text "globally-hidden-bad.txt`n"
        $attributesConfigPath = $fakeAttributes.Replace("\", "/")
        $excludesConfigPath = $fakeExcludes.Replace("\", "/")
        Write-FixtureText -Path (Join-Path $fakeHome ".gitconfig") -Text (
            "[core]`n" +
            ("    attributesFile = `"{0}`"`n" -f $attributesConfigPath) +
            ("    excludesFile = `"{0}`"`n" -f $excludesConfigPath) +
            "[steadyagent]`n" +
            "    globalMarker = fake-home-marker`n"
        )
        [Environment]::SetEnvironmentVariable("HOME", $fakeHome, "Process")
        [Environment]::SetEnvironmentVariable(
            "GIT_CONFIG_GLOBAL",
            (Join-Path $fakeHome ".gitconfig"),
            "Process"
        )
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_NOSYSTEM", "0", "Process")
        [Environment]::SetEnvironmentVariable("GIT_ATTR_NOSYSTEM", "0", "Process")
        try {
            $globalMarkerResult = Invoke-ReleaseWhitespaceGit `
                -GitArgs @("config", "--get", "steadyagent.globalMarker") `
                -WorkingDirectory $fixtureFull
            Assert-Equal "global Git config marker is absent from the child" (
                $globalMarkerResult.Code -ne 0 -and
                ([string]$globalMarkerResult.RawOutput -notmatch "fake-home-marker")
            ) $true
            Assert-Equal "HOME parent value survives child isolation" (
                [Environment]::GetEnvironmentVariable("HOME", "Process")
            ) $fakeHome
            Assert-Equal "GIT_CONFIG_GLOBAL parent value survives child isolation" (
                [Environment]::GetEnvironmentVariable("GIT_CONFIG_GLOBAL", "Process")
            ) (Join-Path $fakeHome ".gitconfig")
            Assert-Equal "GIT_CONFIG_NOSYSTEM parent value survives child isolation" (
                [Environment]::GetEnvironmentVariable("GIT_CONFIG_NOSYSTEM", "Process")
            ) "0"
            Assert-Equal "GIT_ATTR_NOSYSTEM parent value survives child isolation" (
                [Environment]::GetEnvironmentVariable("GIT_ATTR_NOSYSTEM", "Process")
            ) "0"

            Write-FixtureText -Path (Join-Path $fixtureFull "tracked.txt") -Text "hidden tracked bad   `n"
            $globalAttributesResult = Test-ReleaseWhitespace `
                -Repository $fixtureFull `
                -BaseRef "base-advanced" `
                -AllowDirty
            Assert-Equal "global attributes cannot hide tracked trailing whitespace" (
                $globalAttributesResult.Code -eq 1
            ) $true

            $globallyHiddenPath = Join-Path $fixtureFull "globally-hidden-bad.txt"
            Write-FixtureText -Path $globallyHiddenPath -Text "hidden untracked bad   `n"
            Write-FixtureText -Path (Join-Path $fixtureFull "tracked.txt") -Text "candidate`n"
            $globalExcludesResult = Test-ReleaseWhitespace `
                -Repository $fixtureFull `
                -BaseRef "base-advanced" `
                -AllowDirty
            Assert-Equal "global excludes cannot hide untracked trailing whitespace" (
                $globalExcludesResult.Code -eq 1
            ) $true
            Assert-Equal "global excludes bypass report names the untracked file" (
                $globalExcludesResult.Output -match "globally-hidden-bad[.]txt"
            ) $true
            Remove-Item -LiteralPath $globallyHiddenPath -Force
        }
        finally {
            Restore-ProcessEnvironmentState -Name "HOME" -State $originalHome
            foreach ($name in @(
                "GIT_CONFIG_GLOBAL",
                "GIT_CONFIG_NOSYSTEM",
                "GIT_ATTR_NOSYSTEM"
            )) {
                Restore-ProcessEnvironmentState -Name $name -State $originalEnvironment[$name]
            }
            Write-FixtureText -Path (Join-Path $fixtureFull "tracked.txt") -Text "candidate`n"
        }

        $fsmonitorFixtureId = [guid]::NewGuid().ToString("N")
        $fsmonitorMarker = Join-Path $tempBase (
            "steadyagent-fsmonitor-marker-" + $fsmonitorFixtureId + ".txt"
        )
        $fsmonitorHook = Join-Path $tempBase (
            "steadyagent-fsmonitor-hook-" + $fsmonitorFixtureId + ".cmd"
        )
        $fsmonitorHookText = @(
            "@echo off",
            ("> `"{0}`" echo invoked" -f $fsmonitorMarker),
            "echo builtin:fake",
            "exit /b 0"
        ) -join "`r`n"
        Write-FixtureText -Path $fsmonitorHook -Text ($fsmonitorHookText + "`r`n")
        Invoke-Git @("config", "core.fsmonitor", $fsmonitorHook.Replace("\", "/"))
        try {
            $fsmonitorResult = Invoke-ReleaseWhitespaceGit `
                -GitArgs @("status", "--porcelain=v1") `
                -WorkingDirectory $fixtureFull
            Assert-Equal "repo-local fsmonitor cannot alter a successful Git child" (
                $fsmonitorResult.Code
            ) 0
            Assert-Equal "repo-local fsmonitor creates no external side effect" (
                -not (Test-Path -LiteralPath $fsmonitorMarker)
            ) $true
        }
        finally {
            Invoke-Git @("config", "--unset", "core.fsmonitor")
            if (Test-Path -LiteralPath $fsmonitorMarker) {
                Remove-Item -LiteralPath $fsmonitorMarker -Force
            }
            Remove-Item -LiteralPath $fsmonitorHook -Force
        }

        $stdoutProbe = Invoke-ReleaseWhitespaceGit -GitArgs @("rev-parse", "HEAD")
        Assert-Equal "Git stdout is captured separately" ([string]$stdoutProbe.Output[0]).Trim() $candidateHead
        Assert-Equal "successful Git command has no stderr diagnostic" (
            [string]::IsNullOrWhiteSpace([string]$stdoutProbe.Error)
        ) $true
        $stderrProbe = Invoke-ReleaseWhitespaceGit `
            -GitArgs @("rev-parse", "--verify", "refs/heads/missing-probe")
        Assert-Equal "Git failure preserves a nonzero exit code" ($stderrProbe.Code -ne 0) $true
        Assert-Equal "Git stderr is captured separately" (
            -not [string]::IsNullOrWhiteSpace([string]$stderrProbe.Error)
        ) $true
        Assert-Equal "Git failure does not mislabel stderr as stdout" (
            [string]::IsNullOrEmpty([string]$stderrProbe.RawOutput)
        ) $true

        $stderrSecret = "SENSITIVE_STDERR_MARKER_4f29"
        $largeFailure = Invoke-ReleaseWhitespaceGit `
            -GitArgs @(("--unknown=" + $stderrSecret + ("x" * 6000)))
        Assert-Equal "large Git stderr fails closed" ($largeFailure.Code -ne 0) $true
        Assert-Equal "Git stderr capture is bounded at entry" (
            ([string]$largeFailure.Error).Length -le 300
        ) $true
        Assert-Equal "Git stderr diagnostics redact argument contents" (
            [string]$largeFailure.Error -notmatch [regex]::Escape($stderrSecret)
        ) $true
        $pathDiagnostic = Get-ReleaseWhitespaceDiagnostic `
            -Text 'fatal: C:\private\secret.txt and \\server\share\private.txt' `
            -Repository $fixtureFull
        Assert-Equal "diagnostics redact drive and UNC paths" (
            $pathDiagnostic -notmatch 'private|server|share'
        ) $true
        $credentialDiagnostic = Get-ReleaseWhitespaceDiagnostic `
            -Text 'https://user:pass@example.invalid/repo.git token=TOPSECRET123' `
            -Repository $fixtureFull
        Assert-Equal "diagnostics redact URI credentials and secret assignments" (
            $credentialDiagnostic -notmatch 'user:pass|TOPSECRET123'
        ) $true

        $limitFixtureRoot = Join-Path $fixtureFull "untracked-limit-fixture"
        New-Item -ItemType Directory -Path $limitFixtureRoot -Force | Out-Null
        foreach ($number in 1..3) {
            Write-FixtureText `
                -Path (Join-Path $limitFixtureRoot ("clean-{0}.txt" -f $number)) `
                -Text ("clean-{0}`n" -f $number)
        }
        $limitResult = $null
        $limitError = ""
        $limitStopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $limitResult = Test-ReleaseWhitespace `
                -Repository $fixtureFull `
                -BaseRef "base-advanced" `
                -AllowDirty `
                -UntrackedFileLimit 2
        }
        catch {
            $limitError = $_.Exception.Message
        }
        finally {
            $limitStopwatch.Stop()
        }
        Assert-Equal "untracked file count above the configured ceiling fails closed" (
            $null -ne $limitResult -and [int]$limitResult.Code -eq 2
        ) $true
        Assert-Equal "untracked file ceiling failure is explicit" (
            $null -ne $limitResult -and
            [string]$limitResult.Output -match "safe limit of 2"
        ) $true
        Assert-Equal "untracked file ceiling fails immediately" (
            $limitStopwatch.Elapsed.TotalSeconds -lt 5 -and
            [string]::IsNullOrEmpty($limitError)
        ) $true
        Remove-Item -LiteralPath $limitFixtureRoot -Recurse -Force

        $deadlinePath = Join-Path $fixtureFull "untracked-deadline.txt"
        Write-FixtureText -Path $deadlinePath -Text "deadline fixture`n"
        $deadlineResult = $null
        $deadlineError = ""
        $deadlineStopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $deadlineResult = Test-ReleaseWhitespace `
                -Repository $fixtureFull `
                -BaseRef "base-advanced" `
                -AllowDirty `
                -UntrackedDeadlineMilliseconds 1
        }
        catch {
            $deadlineError = $_.Exception.Message
        }
        finally {
            $deadlineStopwatch.Stop()
        }
        Assert-Equal "expired untracked inspection deadline fails closed" (
            $null -ne $deadlineResult -and [int]$deadlineResult.Code -eq 2
        ) $true
        Assert-Equal "untracked deadline failure is explicit" (
            $null -ne $deadlineResult -and
            [string]$deadlineResult.Output -match "total time limit of 1 ms"
        ) $true
        Assert-Equal "untracked deadline bounds wall-clock time" (
            $deadlineStopwatch.Elapsed.TotalSeconds -lt 5 -and
            [string]::IsNullOrEmpty($deadlineError)
        ) $true
        Remove-Item -LiteralPath $deadlinePath -Force

        $badPath = Join-Path $fixtureFull "untracked-bad.txt"
        $privateLineMarker = "PRIVATE_LINE_MARKER_82af"
        Write-FixtureText -Path $badPath -Text (
            "bad-private-content:7: " + $privateLineMarker + "   `n"
        )
        $dirtyResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "base-advanced" -AllowDirty
        Assert-Equal "untracked trailing whitespace makes WIP red" ($dirtyResult.Code -ne 0) $true
        Assert-Equal "untracked failure names the file" ($dirtyResult.Output -match "untracked-bad[.]txt") $true
        Assert-Equal "untracked failure omits offending file content" (
            $dirtyResult.Output -notmatch "bad-private-content" -and
            $dirtyResult.Output -notmatch [regex]::Escape($privateLineMarker)
        ) $true
        Assert-Equal "WIP check preserves HEAD" ((& git rev-parse HEAD).Trim()) $candidateHead
        Assert-Equal "WIP check preserves the untracked file" (Test-Path -LiteralPath $badPath) $true
        Remove-Item -LiteralPath $badPath -Force

        $stagedBadPath = Join-Path $fixtureFull "staged-bad.txt"
        Write-FixtureText -Path $stagedBadPath -Text "staged bad   `n"
        Invoke-Git @("add", "--", "staged-bad.txt")
        $stagedBadResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "base-advanced" -AllowDirty
        Assert-Equal "staged trailing whitespace makes WIP red" ($stagedBadResult.Code -ne 0) $true
        Write-FixtureText -Path $stagedBadPath -Text "final worktree is clean`n"
        $stagedOverwrittenResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "base-advanced" -AllowDirty
        Assert-Equal "clean final worktree overrides stale staged whitespace" $stagedOverwrittenResult.Code 0
        Invoke-Git @("restore", "--staged", "--", "staged-bad.txt")
        Remove-Item -LiteralPath $stagedBadPath -Force

        Write-FixtureText -Path (Join-Path $fixtureFull "tracked.txt") -Text "unstaged bad   `n"
        $unstagedBadResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "base-advanced" -AllowDirty
        Assert-Equal "unstaged trailing whitespace makes WIP red" ($unstagedBadResult.Code -ne 0) $true
        Write-FixtureText -Path (Join-Path $fixtureFull "tracked.txt") -Text "candidate`n"

        $deletePath = Join-Path $fixtureFull "delete-me.txt"
        Remove-Item -LiteralPath $deletePath -Force
        $unstagedDeleteResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "base-advanced" -AllowDirty
        Assert-Equal "unstaged deletion passes WIP whitespace check" $unstagedDeleteResult.Code 0
        Write-FixtureText -Path $deletePath -Text "keep or delete`n"

        Remove-Item -LiteralPath $deletePath -Force
        Invoke-Git @("add", "--", "delete-me.txt")
        $stagedDeleteResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "base-advanced" -AllowDirty
        Assert-Equal "staged deletion passes WIP whitespace check" $stagedDeleteResult.Code 0
        Write-FixtureText -Path $deletePath -Text "keep or delete`n"
        Invoke-Git @("add", "--", "delete-me.txt")

        $cleanPath = Join-Path $fixtureFull "untracked clean space.txt"
        Write-FixtureText -Path $cleanPath -Text (
            "unique-" + [guid]::NewGuid().ToString("N") + "`n"
        )
        $indexPath = (& git rev-parse --path-format=absolute --git-path index).Trim()
        $objectsPath = (& git rev-parse --path-format=absolute --git-path objects).Trim()
        $gitDirectory = (& git rev-parse --path-format=absolute --git-dir).Trim()
        $beforeStatus = @(& git status --porcelain=v1 -uall) -join "`n"
        $beforeIndexHash = Get-FileSha256 -Path $indexPath
        $beforeObjects = Get-ObjectInventory -ObjectRoot $objectsPath
        $beforeTempArtifacts = Get-TempArtifactInventory

        $expectedEnvironment = @{
            GIT_INDEX_FILE = $indexPath
            GIT_OBJECT_DIRECTORY = $objectsPath
            GIT_ALTERNATE_OBJECT_DIRECTORIES = $objectsPath
            GIT_DIR = $gitDirectory
            GIT_WORK_TREE = $fixtureFull
            GIT_COMMON_DIR = $gitDirectory
        }
        foreach ($name in $isolationEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, [string]$expectedEnvironment[$name], "Process")
        }

        $cleanDirtyResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "base-advanced" -AllowDirty
        Assert-Equal "clean untracked file with spaces passes WIP check" $cleanDirtyResult.Code 0
        Assert-Equal "dirty mode uses the same merge-base" $cleanDirtyResult.MergeBase $baseline
        foreach ($name in $isolationEnvironmentNames) {
            Assert-EnvironmentState -Name $name -Expected (
                [pscustomobject]@{ Present = $true; Value = [string]$expectedEnvironment[$name] }
            )
        }

        foreach ($name in $isolationEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
        Assert-Equal "WIP check preserves exact index bytes" (Get-FileSha256 -Path $indexPath) $beforeIndexHash
        Assert-Equal "WIP check preserves repository object inventory" (Get-ObjectInventory -ObjectRoot $objectsPath) $beforeObjects
        Assert-Equal "WIP check preserves worktree and index status" (@(& git status --porcelain=v1 -uall) -join "`n") $beforeStatus
        Assert-Equal "WIP check creates no sensitive temp artifacts" (Get-TempArtifactInventory) $beforeTempArtifacts

        $concurrentScript = @'
param($HelperPath, $RepositoryPath, $Barrier)
. $HelperPath
if (-not $Barrier.SignalAndWait(15000)) { throw "Concurrent test barrier timed out." }
$result = Test-ReleaseWhitespace -Repository $RepositoryPath -BaseRef "base-advanced" -AllowDirty
[pscustomobject]@{ Code = $result.Code; MergeBase = $result.MergeBase }
'@
        $barrier = New-Object Threading.Barrier -ArgumentList 2
        $firstRunspace = [PowerShell]::Create()
        $secondRunspace = [PowerShell]::Create()
        try {
            [void]$firstRunspace.AddScript($concurrentScript).AddArgument($helper).AddArgument($fixtureFull).AddArgument($barrier)
            [void]$secondRunspace.AddScript($concurrentScript).AddArgument($helper).AddArgument($fixtureFull).AddArgument($barrier)
            $firstAsync = $firstRunspace.BeginInvoke()
            $secondAsync = $secondRunspace.BeginInvoke()
            $firstOutput = @($firstRunspace.EndInvoke($firstAsync))
            $secondOutput = @($secondRunspace.EndInvoke($secondAsync))
            Assert-Equal "first same-process concurrent WIP check passes" $firstOutput[-1].Code 0
            Assert-Equal "second same-process concurrent WIP check passes" $secondOutput[-1].Code 0
            Assert-Equal "same-process concurrent WIP checks emit no runspace errors" (
                $firstRunspace.Streams.Error.Count + $secondRunspace.Streams.Error.Count
            ) 0
        }
        finally {
            $barrier.Dispose()
            $firstRunspace.Dispose()
            $secondRunspace.Dispose()
        }
        Assert-Equal "concurrent WIP checks preserve exact index bytes" (Get-FileSha256 -Path $indexPath) $beforeIndexHash
        Assert-Equal "concurrent WIP checks preserve repository objects" (Get-ObjectInventory -ObjectRoot $objectsPath) $beforeObjects
        Assert-Equal "concurrent WIP checks preserve HEAD" ((& git rev-parse HEAD).Trim()) $candidateHead
        Assert-Equal "concurrent WIP checks create no temp artifacts" (Get-TempArtifactInventory) $beforeTempArtifacts
        Remove-Item -LiteralPath $cleanPath -Force

        $missingBaseResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "refs/heads/private-missing-base"
        Assert-Equal "invalid base fails closed" $missingBaseResult.Code 2
        Assert-Equal "invalid base includes bounded Git diagnostics" (
            $missingBaseResult.Output -match "git:" -and $missingBaseResult.Output.Length -le 400
        ) $true
        Assert-Equal "Git diagnostics do not expose the fixture path" (
            -not $missingBaseResult.Output.Contains($fixtureFull)
        ) $true

        Write-FixtureText -Path (Join-Path $fixtureFull "committed-bad.txt") -Text "bad   `n"
        Invoke-Git @("add", "--", "committed-bad.txt")
        Invoke-Git @("commit", "-q", "-m", "committed whitespace")
        $committedResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "base-advanced"
        Assert-Equal "committed trailing whitespace makes clean candidate red" ($committedResult.Code -ne 0) $true
        Write-FixtureText -Path (Join-Path $fixtureFull "clean-followup.txt") -Text "clean followup`n"
        Invoke-Git @("add", "--", "clean-followup.txt")
        Invoke-Git @("commit", "-q", "-m", "clean followup")
        $tipOnlyResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef "HEAD^"
        $frozenBaseResult = Test-ReleaseWhitespace -Repository $fixtureFull -BaseRef $baseline
        Assert-Equal "tip-only whitespace gate misses an earlier bad commit" $tipOnlyResult.Code 0
        Assert-Equal "frozen baseline catches whitespace from an earlier commit" ($frozenBaseResult.Code -ne 0) $true
    }
    finally {
        Pop-Location
    }
}
finally {
    foreach ($name in $environmentNames) {
        Restore-ProcessEnvironmentState -Name $name -State $originalEnvironment[$name]
    }
    if (Test-Path -LiteralPath $fixtureFull) {
        Remove-Item -LiteralPath $fixtureFull -Recurse -Force
    }
}

Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

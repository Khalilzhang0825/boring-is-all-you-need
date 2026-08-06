[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:Passed = 0
$script:Failed = 0
$script:FixtureReviewedCommit = "1111111111111111111111111111111111111111"
$script:ExactReleaseBody = (
    "# Reviewed release notes`n`n- exact body`n`n" +
    "## Verified provenance`n`n" +
    "Reviewed commit: $script:FixtureReviewedCommit`n" +
    "Source ref: refs/tags/v2.0.1`n"
)

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        $script:Passed++
        Write-Host ("PASS " + $Name)
    }
    else {
        $script:Failed++
        Write-Host ("FAIL " + $Name + $(if ($Detail) { " - " + $Detail } else { "" }))
    }
}

function Get-DraftStepScript {
    $lines = [IO.File]::ReadAllLines(
        (Join-Path $root ".github\workflows\release.yml"),
        [Text.Encoding]::UTF8
    )
    $stepIndex = -1
    $runIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s+- name: Create or recover the exact draft GitHub release\s*$') {
            $stepIndex = $index
            continue
        }
        if ($stepIndex -ge 0 -and $lines[$index] -match '^\s+run:\s+\|\s*$') {
            $runIndex = $index
            break
        }
    }
    if ($stepIndex -lt 0 -or $runIndex -lt 0) {
        throw "Could not locate the draft release workflow step."
    }
    $scriptLines = New-Object Collections.Generic.List[string]
    for ($index = $runIndex + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^          (.*)$') {
            $scriptLines.Add([string]$Matches[1]) | Out-Null
            continue
        }
        if ([string]::IsNullOrWhiteSpace($lines[$index])) {
            $scriptLines.Add("") | Out-Null
            continue
        }
        break
    }
    if ($scriptLines.Count -eq 0) { throw "The draft release workflow step is empty." }
    return (($scriptLines.ToArray() -join "`n") + "`n")
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function New-ReleaseFixture {
    param(
        [string]$Name,
        [string]$ExistingBody,
        [bool]$IsPrerelease = $false,
        [bool]$IsDraft = $true,
        [string]$RemoteSidecarSuffix = "",
        [string]$RemoteArchiveSuffix = "",
        [string]$RemoteProvenanceSuffix = "",
        [bool]$NoExistingRelease = $false,
        [bool]$RefDriftAfterCreate = $false,
        [bool]$ReplaceAfterCreate = $false,
        [bool]$PublishAfterUpload = $false,
        [bool]$MutateBodyAfterUpload = $false,
        [bool]$AddAssetAfterUpload = $false,
        [bool]$ReleaseViewFailure = $false,
        [bool]$FinalReadbackFailure = $false,
        [bool]$TagObservationFailure = $false,
        [bool]$IdObservationFailureAfterDelete = $false,
        [bool]$ReplaceAfterDelete = $false,
        [string]$ReleaseName = "Boring Is All You Need v2.0.1",
        [string[]]$AssetNames = @(
            "boring-is-all-you-need-v2.0.1.provenance.json",
            "boring-is-all-you-need-v2.0.1.zip",
            "boring-is-all-you-need-v2.0.1.zip.sha256"
        )
    )

    $fixture = Join-Path ([IO.Path]::GetTempPath()) (
        "steadyagent-release-workflow-" + [guid]::NewGuid().ToString("N")
    )
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $dist = New-Item -ItemType Directory -Path (Join-Path $fixture "dist")
    $remote = New-Item -ItemType Directory -Path (Join-Path $fixture "remote")
    $mockBin = New-Item -ItemType Directory -Path (Join-Path $fixture "mock-bin")

    $archiveName = "boring-is-all-you-need-v2.0.1.zip"
    $archivePath = Join-Path $dist.FullName $archiveName
    [IO.File]::WriteAllBytes($archivePath, [Text.Encoding]::UTF8.GetBytes("reviewed archive bytes"))
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sidecarPath = $archivePath + ".sha256"
    Write-Utf8NoBom -Path $sidecarPath -Text ($archiveHash + "  " + $archiveName + "`n")
    $releaseBodyText = $script:ExactReleaseBody
    $releaseBodyPath = Join-Path $dist.FullName "RELEASE_BODY.md"
    Write-Utf8NoBom -Path $releaseBodyPath -Text $releaseBodyText
    $releaseBodyHash = (Get-FileHash -LiteralPath $releaseBodyPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $provenancePath = Join-Path $dist.FullName "boring-is-all-you-need-v2.0.1.provenance.json"
    $provenance = [ordered]@{
        schemaVersion = 1
        releaseTag = "v2.0.1"
        reviewedCommit = $script:FixtureReviewedCommit
        archiveName = $archiveName
        archiveSha256 = $archiveHash
        releaseBodySha256 = $releaseBodyHash
        sourceRepository = "fixture/boring-is-all-you-need"
        sourceRef = "refs/tags/v2.0.1"
        signerWorkflow = "fixture/boring-is-all-you-need/.github/workflows/release.yml"
    } | ConvertTo-Json -Depth 4
    Write-Utf8NoBom -Path $provenancePath -Text ($provenance + "`n")

    $remoteArchive = Join-Path $remote.FullName $archiveName
    $remoteSidecar = $remoteArchive + ".sha256"
    $remoteProvenance = Join-Path $remote.FullName "boring-is-all-you-need-v2.0.1.provenance.json"
    [IO.File]::Copy($archivePath, $remoteArchive)
    [IO.File]::Copy($sidecarPath, $remoteSidecar)
    [IO.File]::Copy($provenancePath, $remoteProvenance)
    if ($RemoteArchiveSuffix) {
        [IO.File]::AppendAllText($remoteArchive, $RemoteArchiveSuffix, [Text.Encoding]::UTF8)
    }
    if ($RemoteSidecarSuffix) {
        [IO.File]::AppendAllText($remoteSidecar, $RemoteSidecarSuffix, [Text.Encoding]::UTF8)
    }
    if ($RemoteProvenanceSuffix) {
        [IO.File]::AppendAllText($remoteProvenance, $RemoteProvenanceSuffix, [Text.Encoding]::UTF8)
    }
    $statePath = Join-Path $fixture "state.json"
    $logPath = Join-Path $fixture "gh.log"
    $releaseState = [ordered]@{
        tagName = "v2.0.1"
        name = $ReleaseName
        body = $ExistingBody
        isDraft = $IsDraft
        isPrerelease = $IsPrerelease
        databaseId = 4101
        assets = @($AssetNames | ForEach-Object { [ordered]@{ name = [string]$_ } })
    }
    $state = [ordered]@{
        expectedReleaseSha = $script:FixtureReviewedCommit
        expectedBody = $releaseBodyText
        release = $(if ($NoExistingRelease) { $null } else { $releaseState })
        created = $false
        createdReleaseId = 5101
        replacementReleaseId = 5999
        refDriftAfterCreate = $RefDriftAfterCreate
        replaceAfterCreate = $ReplaceAfterCreate
        replacementApplied = $false
        publishAfterUpload = $PublishAfterUpload
        mutateBodyAfterUpload = $MutateBodyAfterUpload
        addAssetAfterUpload = $AddAssetAfterUpload
        releaseViewFailure = $ReleaseViewFailure
        finalReadbackFailure = $FinalReadbackFailure
        finalReadbackFailureConsumed = $false
        tagObservationFailure = $TagObservationFailure
        idObservationFailureAfterDelete = $IdObservationFailureAfterDelete
        replaceAfterDelete = $ReplaceAfterDelete
        remoteArchive = $remoteArchive
        remoteSidecar = $remoteSidecar
        remoteProvenance = $remoteProvenance
    }
    Write-Utf8NoBom -Path $statePath -Text (($state | ConvertTo-Json -Depth 8) + "`n")

    $mockScript = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$state = Get-Content -Raw -LiteralPath $env:MOCK_GH_STATE | ConvertFrom-Json
Add-Content -LiteralPath $env:MOCK_GH_LOG -Value (($args | ForEach-Object { [string]$_ }) -join "|")
function Save-State {
    [IO.File]::WriteAllText(
        $env:MOCK_GH_STATE,
        (($state | ConvertTo-Json -Depth 10) + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )
}
function Set-CreatedRelease {
    $state.release = [pscustomobject]@{
        tagName = "v2.0.1"
        name = "Boring Is All You Need v2.0.1"
        body = [string]$state.expectedBody
        isDraft = $true
        isPrerelease = $false
        databaseId = [int]$state.createdReleaseId
        assets = @()
    }
    $state.created = $true
    Save-State
}
if ($args.Count -ge 2 -and $args[0] -eq "release" -and $args[1] -eq "view") {
    if ([bool]$state.releaseViewFailure) { exit 17 }
    if ([bool]$state.finalReadbackFailure -and [bool]$state.created -and
        $null -ne $state.release -and @($state.release.assets).Count -eq 3 -and
        -not [bool]$state.finalReadbackFailureConsumed) {
        $state.finalReadbackFailureConsumed = $true
        Save-State
        exit 17
    }
    if ([bool]$state.replaceAfterDelete -and [bool]$state.created -and
        $null -eq $state.release -and -not [bool]$state.replacementApplied) {
        $state.release = [pscustomobject]@{
            tagName = "v2.0.1"
            name = "Boring Is All You Need v2.0.1"
            body = [string]$state.expectedBody
            isDraft = $true
            isPrerelease = $false
            databaseId = [int]$state.replacementReleaseId
            assets = @()
        }
        $state.replacementApplied = $true
        Save-State
    }
    if ($null -eq $state.release) { exit 1 }
    if ([bool]$state.created -and [bool]$state.replaceAfterCreate -and
        -not [bool]$state.replacementApplied) {
        $state.release.databaseId = [int]$state.replacementReleaseId
        $state.replacementApplied = $true
        Save-State
    }
    $state.release | ConvertTo-Json -Depth 8 -Compress
    exit 0
}
if ($args.Count -ge 2 -and $args[0] -eq "release" -and $args[1] -eq "download") {
    $dirIndex = [Array]::IndexOf([object[]]$args, "--dir")
    if ($dirIndex -lt 0) { exit 2 }
    $destination = [string]$args[$dirIndex + 1]
    Copy-Item -LiteralPath ([string]$state.remoteArchive) -Destination $destination
    Copy-Item -LiteralPath ([string]$state.remoteSidecar) -Destination $destination
    Copy-Item -LiteralPath ([string]$state.remoteProvenance) -Destination $destination
    exit 0
}
if ($args.Count -ge 2 -and $args[0] -eq "release" -and $args[1] -eq "create") {
    Set-CreatedRelease
    "https://example.invalid/fixture/releases/5101"
    exit 0
}
if ($args.Count -ge 2 -and $args[0] -eq "release" -and $args[1] -eq "upload") {
    $state.release.assets = @(
        [pscustomobject]@{ name = "boring-is-all-you-need-v2.0.1.provenance.json" },
        [pscustomobject]@{ name = "boring-is-all-you-need-v2.0.1.zip" },
        [pscustomobject]@{ name = "boring-is-all-you-need-v2.0.1.zip.sha256" }
    )
    if ([bool]$state.publishAfterUpload) {
        $state.release.isDraft = $false
    }
    if ([bool]$state.mutateBodyAfterUpload) {
        $state.release.body = "concurrent body drift`n"
    }
    if ([bool]$state.addAssetAfterUpload) {
        $state.release.assets += [pscustomobject]@{ name = "unexpected.bin" }
    }
    Save-State
    exit 0
}
if ($args.Count -ge 2 -and $args[0] -eq "release" -and $args[1] -eq "delete") {
    $state.release = $null
    Save-State
    exit 0
}
if ($args.Count -ge 2 -and $args[0] -eq "api") {
    $endpoint = [string]@($args | Where-Object { [string]$_ -like "repos/*" })[0]
    if ($endpoint -match '/releases/tags/') {
        if ([bool]$state.tagObservationFailure) { exit 18 }
        if ($null -eq $state.release) {
            "HTTP/2.0 404 Not Found"
            exit 1
        }
        "HTTP/2.0 200 OK"
        exit 0
    }
    if ($endpoint -match '/releases/(?<id>[0-9]+)$' -and $args -contains "DELETE") {
        if ($null -eq $state.release -or [int]$state.release.databaseId -ne [int]$Matches.id) { exit 1 }
        $state.release = $null
        Save-State
        exit 0
    }
    if ($endpoint -match '/releases/(?<id>[0-9]+)$') {
        if ([bool]$state.idObservationFailureAfterDelete -and
            [bool]$state.created -and $null -eq $state.release) {
            exit 19
        }
        if ($null -eq $state.release -or
            [int]$state.release.databaseId -ne [int]$Matches.id) {
            "HTTP/2.0 404 Not Found"
            exit 1
        }
        "HTTP/2.0 200 OK"
        exit 0
    }
    if ($endpoint -match '/releases$' -and $args -contains "POST") {
        Set-CreatedRelease
        [pscustomobject]@{ id = [int]$state.createdReleaseId } | ConvertTo-Json -Compress
        exit 0
    }
    if ($endpoint -match '/git/ref/tags/') {
        $sha = if ([bool]$state.created -and [bool]$state.refDriftAfterCreate) {
            "2222222222222222222222222222222222222222"
        } else { [string]$state.expectedReleaseSha }
        [pscustomobject]@{ object = [pscustomobject]@{ type = "commit"; sha = $sha } } |
            ConvertTo-Json -Compress
        exit 0
    }
    if ($endpoint -match '/git/ref/heads/main$') {
        [pscustomobject]@{ object = [pscustomobject]@{ type = "commit"; sha = [string]$state.expectedReleaseSha } } |
            ConvertTo-Json -Compress
        exit 0
    }
}
exit 90
'@
    $mockScriptPath = Join-Path $fixture "mock-gh.ps1"
    Write-Utf8NoBom -Path $mockScriptPath -Text $mockScript
    $shimText = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%MOCK_GH_SCRIPT%`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    Write-Utf8NoBom -Path (Join-Path $mockBin.FullName "gh.cmd") -Text $shimText
    $runnerPath = Join-Path $fixture "draft-step.ps1"
    Write-Utf8NoBom -Path $runnerPath -Text (Get-DraftStepScript)

    return [pscustomobject]@{
        Root = $fixture
        Dist = $dist.FullName
        MockBin = $mockBin.FullName
        MockScript = $mockScriptPath
        State = $statePath
        Log = $logPath
        Runner = $runnerPath
        ArchiveHash = $archiveHash
        Notes = $releaseBodyText
    }
}

function Invoke-DraftStepFixture {
    param([object]$Fixture)
    $environmentNames = @(
        "MOCK_GH_SCRIPT", "MOCK_GH_STATE", "MOCK_GH_LOG", "RELEASE_TAG",
        "EXPECTED_RELEASE_SHA", "EXPECTED_RELEASE_SHA256", "GH_TOKEN", "GH_REPO", "RUNNER_TEMP"
    )
    $saved = @{}
    foreach ($name in $environmentNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    $oldPath = $env:PATH
    Push-Location $Fixture.Root
    try {
        $env:PATH = $Fixture.MockBin + ";" + $oldPath
        $env:MOCK_GH_SCRIPT = $Fixture.MockScript
        $env:MOCK_GH_STATE = $Fixture.State
        $env:MOCK_GH_LOG = $Fixture.Log
        $env:RELEASE_TAG = "v2.0.1"
        $env:EXPECTED_RELEASE_SHA = "1111111111111111111111111111111111111111"
        $env:EXPECTED_RELEASE_SHA256 = $Fixture.ArchiveHash
        $env:GH_TOKEN = "fixture"
        $env:GH_REPO = "fixture/boring-is-all-you-need"
        $env:RUNNER_TEMP = $Fixture.Root
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Fixture.Runner 2>$null
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = (@($output) -join "`n")
            Log = $(if (Test-Path -LiteralPath $Fixture.Log) {
                @([IO.File]::ReadAllLines($Fixture.Log, [Text.Encoding]::UTF8))
            } else { @() })
        }
    }
    finally {
        Pop-Location
        $env:PATH = $oldPath
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
        }
    }
}

$fixtures = New-Object Collections.Generic.List[string]
$releaseWorkflowText = [IO.File]::ReadAllText(
    (Join-Path $root ".github\workflows\release.yml"),
    [Text.Encoding]::UTF8
)
$validateWorkflowText = [IO.File]::ReadAllText(
    (Join-Path $root ".github\workflows\validate.yml"),
    [Text.Encoding]::UTF8
)
$archiveValidatorText = [IO.File]::ReadAllText(
    (Join-Path $root "tools\validate-release-archive.ps1"),
    [Text.Encoding]::UTF8
)
Assert-True "release workflow pins reviewed Node24-native action commits" (
    $releaseWorkflowText -match 'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd' -and
    $releaseWorkflowText -match 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' -and
    ([regex]::Matches(
        $releaseWorkflowText,
        'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'
    )).Count -eq 2
)
Assert-True "GitHub workflows force the reviewed Node24 runtime contract" (
    $releaseWorkflowText -match '(?m)^\s*FORCE_JAVASCRIPT_ACTIONS_TO_NODE24:\s*["'']?true["'']?\s*$' -and
    $validateWorkflowText -match 'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd' -and
    $validateWorkflowText -match '(?m)^\s*FORCE_JAVASCRIPT_ACTIONS_TO_NODE24:\s*["'']?true["'']?\s*$'
)
Assert-True "release workflow binds the new repository, title, archive, and prefix" (
    $releaseWorkflowText -match 'Khalilzhang0825/boring-is-all-you-need' -and
    $releaseWorkflowText -match 'Boring Is All You Need v2[.]0[.]1' -and
    $releaseWorkflowText -match 'boring-is-all-you-need-v2[.]0[.]1[.]zip' -and
    $releaseWorkflowText -match '--prefix=boring-is-all-you-need-\$env:RELEASE_TAG/' -and
    $releaseWorkflowText -notmatch 'Khalilzhang0825/steadyagent|steadyagent-v2[.]0[.]1|SteadyAgent v2[.]0[.]1'
)
$publicVerificationText = @(
    "README.md",
    "README.zh-CN.md",
    "docs/getting-started.md",
    "docs/getting-started.zh-CN.md",
    "docs/github-publication-runbook.md",
    "docs/github-publication-runbook.zh-CN.md"
) | ForEach-Object {
    [IO.File]::ReadAllText((Join-Path $root $_), [Text.Encoding]::UTF8)
}
Assert-True "release workflow publishes reviewed-commit provenance and a bound release body" (
    $releaseWorkflowText -match 'boring-is-all-you-need-v2[.]0[.]1[.]provenance[.]json' -and
    $releaseWorkflowText -match 'reviewedCommit' -and
    $releaseWorkflowText -match 'RELEASE_BODY[.]md' -and
    $releaseWorkflowText -match 'releaseBodySha256' -and
    $releaseWorkflowText -match 'EXPECTED_RELEASE_SHA'
)
Assert-True "public verification derives ReviewedSha from the provenance asset without placeholders" (
    @($publicVerificationText | Where-Object {
        $_ -match '\$ReviewedSha\s*=\s*\[string\]\$Provenance[.]reviewedCommit' -and
        $_ -notmatch '<recorded reviewed commit>|<记录的已审查 commit>'
    }).Count -eq $publicVerificationText.Count
)
Assert-True "copyable release verification fails closed after every gh native command" (
    @($publicVerificationText | Where-Object {
        $_ -match '(?m)^gh attestation verify --help \| Out-Null\r?\nif \(\$LASTEXITCODE -ne 0\) \{ throw ' -and
        $_ -match '(?m)^gh release download v2[.]0[.]1[^\r\n]*\r?\nif \(\$LASTEXITCODE -ne 0\) \{ throw ' -and
        $_ -match '(?ms)^gh attestation verify [.]\\boring-is-all-you-need-v2[.]0[.]1[.]zip .*?^  --source-digest \$ReviewedSha\r?\nif \(\$LASTEXITCODE -ne 0\) \{ throw '
    }).Count -eq $publicVerificationText.Count
)
Assert-True "copyable release verification cannot extract before attestation success" (
    @($publicVerificationText | Where-Object {
        $_ -match '(?ms)--source-digest \$ReviewedSha\r?\nif \(\$LASTEXITCODE -ne 0\) \{ throw [^\r\n]+\}\r?\nExpand-Archive'
    }).Count -eq $publicVerificationText.Count
)
Assert-True "public receipt examples use installer output instead of angle placeholders" (
    @($publicVerificationText | Where-Object {
        $_ -notmatch '<[^>\r\n]*(receipt|backup|收据|备份)[^>\r\n]*>'
    }).Count -eq $publicVerificationText.Count
)
$publicationRunbooks = @($publicVerificationText[4], $publicVerificationText[5])
$harnessReviewText = [IO.File]::ReadAllText(
    (Join-Path $root "rules\harness-review.md"),
    [Text.Encoding]::UTF8
)
Assert-True "operational release and Harness docs contain no actionable angle placeholders" (
    @($publicationRunbooks | Where-Object {
        $_ -notmatch '<(?:branch|commit|successful-receipt)>'
    }).Count -eq $publicationRunbooks.Count -and
    $harnessReviewText -notmatch '<(?:branch|commit|successful-receipt)>' -and
    $harnessReviewText -match 'Read-Host "Successful migration receipt path"'
)
Assert-True "tag publication checks local and remote identity and every native exit" (
    @($publicationRunbooks | Where-Object {
        $_ -match 'git rev-parse origin/main' -and
        $_ -match 'git rev-parse "refs/tags/\$Tag\^\{commit\}"' -and
        $_ -match 'git ls-remote --exit-code --tags origin' -and
        $_ -match '(?m)^\s*git tag \$Tag \$ReviewedSha\r?\n\s*if \(\$LASTEXITCODE -ne 0\) \{ throw ' -and
        $_ -match '(?m)^\s*git push origin "refs/tags/\$Tag:refs/tags/\$Tag"\r?\n\s*if \(\$LASTEXITCODE -ne 0\) \{ throw '
    }).Count -eq $publicationRunbooks.Count
)
Assert-True "partial-draft recovery is exact and deletes only the captured release ID" (
    @($publicationRunbooks | Where-Object {
        $_ -match '\$CapturedReleaseId' -and
        $_ -match 'gh run download \$RunId' -and
        $_ -match 'Get-FileHash' -and
        $_ -match '--method DELETE "repos/\$Repository/releases/\$CapturedReleaseId"' -and
        $_ -match 'Get-ReleaseById -ReleaseId \$CapturedReleaseId' -and
        $_ -notmatch 'gh release delete'
    }).Count -eq $publicationRunbooks.Count
)
Assert-True "final publication revalidates and publishes the captured exact draft by ID" (
    @($publicationRunbooks | Where-Object {
        $_ -match 'Assert-ExactReleaseDraft' -and
        $_ -match '--method PATCH "repos/\$Repository/releases/\$CapturedReleaseId" -F draft=false' -and
        $_ -match 'Get-ReleaseById -ReleaseId \$CapturedReleaseId' -and
        $_ -match '(?s)Assert-TagPublicationGuards -Repository \$Repository -Tag \$Tag.*?draft=false.*?Assert-TagPublicationGuards -Repository \$Repository -Tag \$Tag' -and
        $_ -match '\$PostPublishTagSha' -and
        $_ -match '\$PostPublishMainSha' -and
        $_ -match '-not \[bool\]\$state[.]immutable' -and
        $_ -match 'boring-is-all-you-need-v2[.]0[.]1[.]provenance[.]json\|boring-is-all-you-need-v2[.]0[.]1[.]zip\|boring-is-all-you-need-v2[.]0[.]1[.]zip[.]sha256' -and
        $_ -notmatch 'gh release edit'
    }).Count -eq $publicationRunbooks.Count
)
Assert-True "publication requires immutable releases and an exact no-bypass tag guard" (
    @($publicationRunbooks | Where-Object {
        $_ -match 'repos/\$Repository/immutable-releases' -and
        $_ -match 'repos/\$Repository/rulesets[?]targets=tag&per_page=100' -and
        $_ -match '\$BypassProperty\s*=\s*\$Ruleset[.]PSObject[.]Properties\[''bypass_actors''\]' -and
        $_ -match '\$null -ne \$BypassProperty[.]Value' -and
        $_ -match '\$Excludes[.]Count -eq 0' -and
        $_ -match '\$RuleTypes -ccontains "update"' -and
        $_ -match '\$RuleTypes -ccontains "deletion"'
    }).Count -eq $publicationRunbooks.Count
)
Assert-True "archive Markdown link validation excludes fenced PowerShell casts" (
    $archiveValidatorText -match 'function Remove-MarkdownFencedCode' -and
    $archiveValidatorText -match 'Remove-MarkdownFencedCode -Text' -and
    $archiveValidatorText -match 'archive Markdown link scan excludes fenced PowerShell casts'
)
$ordinaryUserDocs = @(
    "README.md",
    "README.zh-CN.md",
    "docs/getting-started.md",
    "docs/getting-started.zh-CN.md"
) | ForEach-Object {
    [IO.File]::ReadAllText((Join-Path $root $_), [Text.Encoding]::UTF8)
}
Assert-True "ordinary-user archive verification selects the quick integrity-only surface" (
    @($ordinaryUserDocs | Where-Object {
        $_ -match 'validate-release-archive[.]ps1\s+-IntegrityOnly' -and
        $_ -match '(?i)(maintainer|CI|维护者)' -and
        $_ -match '(?i)(full|完整).*(gate|suite|门|套件)'
    }).Count -eq $ordinaryUserDocs.Count
)
Assert-True "ordinary-user docs document elevated Codex compatibility before install commands" (
    @($ordinaryUserDocs | Where-Object {
        $warningIndex = $_.IndexOf('[windows] sandbox = "elevated"', [StringComparison]::Ordinal)
        $installIndex = $_.IndexOf(
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1',
            [StringComparison]::Ordinal
        )
        $warningIndex -ge 0 -and $installIndex -ge 0 -and $warningIndex -lt $installIndex
    }).Count -eq $ordinaryUserDocs.Count
)
$releaseNotesText = [IO.File]::ReadAllText(
    (Join-Path $root "RELEASE_NOTES.md"),
    [Text.Encoding]::UTF8
)
Assert-True "release notes lead with elevated PowerShell compatibility" (
    $releaseNotesText.IndexOf('[windows] sandbox = "elevated"', [StringComparison]::Ordinal) -gt 0 -and
    $releaseNotesText.IndexOf('[windows] sandbox = "elevated"', [StringComparison]::Ordinal) -lt
        $releaseNotesText.IndexOf('- replaces', [StringComparison]::Ordinal)
)
$installerText = [IO.File]::ReadAllText(
    (Join-Path $root "tools\install.ps1"),
    [Text.Encoding]::UTF8
)
$rollbackText = [IO.File]::ReadAllText(
    (Join-Path $root "tools\rollback.ps1"),
    [Text.Encoding]::UTF8
)
Assert-True "installer and rollback contain no elevated-token refusal" (
    $installerText -notmatch 'non-elevated PowerShell session' -and
    $rollbackText -notmatch 'non-elevated PowerShell process' -and
    $installerText -notmatch 'STEADYAGENT_ALLOW_ELEVATED_FIXTURE' -and
    $rollbackText -notmatch 'STEADYAGENT_ALLOW_ELEVATED_FIXTURE'
)
Assert-True "archive validator exposes a bounded integrity-only mode without weakening the default" (
    $archiveValidatorText -match '(?m)^\s*\[switch\]\$IntegrityOnly\s*$' -and
    $archiveValidatorText -match 'MODE integrity-only' -and
    $archiveValidatorText -match '(?s)if \(-not \$IntegrityOnly\) \{.*?validate-phase3[.]ps1.*?validate-runtime-slice[.]ps1.*?test-equivalence-contract[.]ps1.*?test-release-whitespace[.]ps1.*?\}'
)
$harnessGuideText = [IO.File]::ReadAllText(
    (Join-Path $root "rules\HARNESS-GUIDE.md"),
    [Text.Encoding]::UTF8
)
Assert-True "HARNESS cold strict diagnosis binds the task before catalog and diagnosis" (
    $harnessGuideText -match '(?s)## Validation and evidence boundaries.*?```powershell.*?\$env:CODEX_THREAD_ID.*?throw .*?skill-index[.]ps1" -ThreadId \$env:CODEX_THREAD_ID.*?diagnose-install[.]ps1" -ReceiptPath'
)
$readmeText = [IO.File]::ReadAllText((Join-Path $root "README.md"), [Text.Encoding]::UTF8)
$readmeZhText = [IO.File]::ReadAllText((Join-Path $root "README.zh-CN.md"), [Text.Encoding]::UTF8)
Assert-True "README runtime catalog wording remains rollout-file-confirmed and non-Live" (
    $readmeText -notmatch 'catalog advertised by the active Codex runtime' -and
    $readmeZhText -notmatch 'Codex runtime .*skill catalog' -and
    $readmeText -match 'rollout-file-confirmed' -and
    $readmeZhText -match 'rollout-file-confirmed' -and
    $readmeText -match 'does not prove current-host or Live activation' -and
    $readmeZhText -match 'Live'
)
try {
    $archiveFixture = Join-Path $env:TEMP ("steadyagent-integrity-only-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $archiveFixture -Force | Out-Null
    $fixtures.Add($archiveFixture) | Out-Null
    foreach ($relative in @([IO.File]::ReadAllLines(
        (Join-Path $root "release-files.txt"),
        [Text.Encoding]::UTF8
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $source = Join-Path $root $relative
        $destination = Join-Path $archiveFixture $relative
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    $gateLedger = Join-Path $env:TEMP ("steadyagent-integrity-ledger-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $fixtures.Add($gateLedger) | Out-Null
    $oldGateLedger = $env:STEADYAGENT_TEST_ARCHIVE_GATE_LEDGER
    $env:STEADYAGENT_TEST_ARCHIVE_GATE_LEDGER = $gateLedger
    try {
        foreach ($relative in @(
            "tools\validate-phase3.ps1",
            "tools\validate-runtime-slice.ps1",
            "tools\test-equivalence-contract.ps1",
            "tools\test-release-whitespace.ps1"
        )) {
            $stubName = [IO.Path]::GetFileName($relative)
            $stub = @"
[IO.File]::AppendAllText(`$env:STEADYAGENT_TEST_ARCHIVE_GATE_LEDGER, '$stubName' + [Environment]::NewLine)
Write-Host 'RESULT pass=1 fail=0'
exit 0
"@
            [IO.File]::WriteAllText(
                (Join-Path $archiveFixture $relative),
                $stub,
                (New-Object Text.UTF8Encoding($true))
            )
        }

        $quickOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $archiveFixture "tools\validate-release-archive.ps1") -IntegrityOnly
        $quickLedger = @()
        if (Test-Path -LiteralPath $gateLedger -PathType Leaf) {
            $quickLedger = @([IO.File]::ReadAllLines($gateLedger, [Text.Encoding]::UTF8))
        }
        Assert-True "integrity-only archive validation never invokes heavyweight child suites" (
            (@($quickOutput) -join "`n") -match 'MODE integrity-only' -and
            $quickLedger.Count -eq 0
        ) ((@($quickOutput) -join "; ") + "; ledger=" + ($quickLedger -join ","))

        if (Test-Path -LiteralPath $gateLedger -PathType Leaf) {
            [IO.File]::WriteAllText($gateLedger, "", [Text.Encoding]::UTF8)
        }
        $fullOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $archiveFixture "tools\validate-release-archive.ps1")
        $fullLedger = @()
        if (Test-Path -LiteralPath $gateLedger -PathType Leaf) {
            $fullLedger = @([IO.File]::ReadAllLines($gateLedger, [Text.Encoding]::UTF8) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        Assert-True "default archive validation retains all heavyweight child suites" (
            $fullLedger.Count -eq 4 -and
            @($fullLedger | Sort-Object -Unique).Count -eq 4
        ) ((@($fullOutput) -join "; ") + "; ledger=" + ($fullLedger -join ","))
    }
    finally {
        $env:STEADYAGENT_TEST_ARCHIVE_GATE_LEDGER = $oldGateLedger
    }

    $observationFailure = New-ReleaseFixture `
        -Name "release-observation-failure" `
        -ExistingBody $script:ExactReleaseBody `
        -NoExistingRelease $true `
        -ReleaseViewFailure $true `
        -TagObservationFailure $true
    $fixtures.Add($observationFailure.Root) | Out-Null
    $observationFailureResult = Invoke-DraftStepFixture -Fixture $observationFailure
    $observationFailureLog = $observationFailureResult.Log -join "`n"
    Assert-True "release observation failure is not treated as absence" (
        $observationFailureResult.ExitCode -ne 0 -and
        $observationFailureLog -notmatch
            'api[|].*POST[|].*repos/fixture/boring-is-all-you-need/releases(?:[|]|$)'
    ) ($observationFailureResult.Output + "; " + $observationFailureLog)

    $bodyDrift = New-ReleaseFixture -Name "body-drift" -ExistingBody "tampered release body`n"
    $fixtures.Add($bodyDrift.Root) | Out-Null
    $bodyDriftResult = Invoke-DraftStepFixture -Fixture $bodyDrift
    Assert-True "existing draft with body drift is rejected" ($bodyDriftResult.ExitCode -ne 0) $bodyDriftResult.Output
    Assert-True "body drift never creates or deletes a release" (
        @($bodyDriftResult.Log | Where-Object {
            $_ -match '^release\|(create|delete|upload)\|' -or
            $_ -match '^api\|.*(POST|DELETE).*?/releases'
        }).Count -eq 0
    ) ($bodyDriftResult.Log -join "; ")

    $prerelease = New-ReleaseFixture `
        -Name "prerelease" `
        -ExistingBody $script:ExactReleaseBody `
        -IsPrerelease $true
    $fixtures.Add($prerelease.Root) | Out-Null
    $prereleaseResult = Invoke-DraftStepFixture -Fixture $prerelease
    Assert-True "existing prerelease draft is rejected" ($prereleaseResult.ExitCode -ne 0) $prereleaseResult.Output

    $titleCaseDrift = New-ReleaseFixture `
        -Name "title-case-drift" `
        -ExistingBody $script:ExactReleaseBody `
        -ReleaseName "boring is all you need v2.0.1"
    $fixtures.Add($titleCaseDrift.Root) | Out-Null
    $titleCaseDriftResult = Invoke-DraftStepFixture -Fixture $titleCaseDrift
    Assert-True "existing draft with title case drift is rejected" (
        $titleCaseDriftResult.ExitCode -ne 0
    ) $titleCaseDriftResult.Output

    $sidecarDrift = New-ReleaseFixture `
        -Name "sidecar-drift" `
        -ExistingBody $script:ExactReleaseBody `
        -RemoteSidecarSuffix "tampered trailing bytes`n"
    $fixtures.Add($sidecarDrift.Root) | Out-Null
    $sidecarDriftResult = Invoke-DraftStepFixture -Fixture $sidecarDrift
    Assert-True "existing draft with non-exact sidecar bytes is rejected" (
        $sidecarDriftResult.ExitCode -ne 0
    ) $sidecarDriftResult.Output

    $provenanceDrift = New-ReleaseFixture `
        -Name "provenance-drift" `
        -ExistingBody $script:ExactReleaseBody `
        -RemoteProvenanceSuffix "tampered trailing bytes`n"
    $fixtures.Add($provenanceDrift.Root) | Out-Null
    $provenanceDriftResult = Invoke-DraftStepFixture -Fixture $provenanceDrift
    Assert-True "existing draft with non-exact provenance bytes is rejected" (
        $provenanceDriftResult.ExitCode -ne 0
    ) $provenanceDriftResult.Output

    $exact = New-ReleaseFixture -Name "exact" -ExistingBody $script:ExactReleaseBody
    $fixtures.Add($exact.Root) | Out-Null
    $exactResult = Invoke-DraftStepFixture -Fixture $exact
    Assert-True "byte-exact existing draft completes retry" (
        $exactResult.ExitCode -eq 0 -and
        $exactResult.Output -match "retry is complete" -and
        @( $exactResult.Log | Where-Object {
            $_ -match '^release\|(create|delete|upload)\|' -or
            $_ -match '^api\|.*(POST|DELETE).*?/releases'
        }).Count -eq 0
    ) $exactResult.Output

    $archiveDrift = New-ReleaseFixture `
        -Name "archive-drift" `
        -ExistingBody $script:ExactReleaseBody `
        -RemoteArchiveSuffix "tampered archive bytes"
    $fixtures.Add($archiveDrift.Root) | Out-Null
    $archiveDriftResult = Invoke-DraftStepFixture -Fixture $archiveDrift
    Assert-True "existing draft with non-exact archive bytes is rejected" (
        $archiveDriftResult.ExitCode -ne 0
    ) $archiveDriftResult.Output

    $partial = New-ReleaseFixture `
        -Name "partial" `
        -ExistingBody $script:ExactReleaseBody `
        -AssetNames @("boring-is-all-you-need-v2.0.1.zip")
    $fixtures.Add($partial.Root) | Out-Null
    $partialResult = Invoke-DraftStepFixture -Fixture $partial
    Assert-True "partial existing draft is rejected for manual recovery" (
        $partialResult.ExitCode -ne 0
    ) $partialResult.Output

    $published = New-ReleaseFixture `
        -Name "published" `
        -ExistingBody $script:ExactReleaseBody `
        -IsDraft $false
    $fixtures.Add($published.Root) | Out-Null
    $publishedResult = Invoke-DraftStepFixture -Fixture $published
    Assert-True "published existing release is rejected" ($publishedResult.ExitCode -ne 0) $publishedResult.Output

    $postUploadPublish = New-ReleaseFixture `
        -Name "post-upload-publish" `
        -ExistingBody $script:ExactReleaseBody `
        -NoExistingRelease $true `
        -PublishAfterUpload $true
    $fixtures.Add($postUploadPublish.Root) | Out-Null
    $postUploadPublishResult = Invoke-DraftStepFixture -Fixture $postUploadPublish
    Assert-True "post-upload publication race is rejected" (
        $postUploadPublishResult.ExitCode -ne 0
    ) $postUploadPublishResult.Output

    $postUploadBody = New-ReleaseFixture `
        -Name "post-upload-body" `
        -ExistingBody $script:ExactReleaseBody `
        -NoExistingRelease $true `
        -MutateBodyAfterUpload $true
    $fixtures.Add($postUploadBody.Root) | Out-Null
    $postUploadBodyResult = Invoke-DraftStepFixture -Fixture $postUploadBody
    Assert-True "post-upload body race is rejected" (
        $postUploadBodyResult.ExitCode -ne 0
    ) $postUploadBodyResult.Output

    $postUploadAsset = New-ReleaseFixture `
        -Name "post-upload-asset" `
        -ExistingBody $script:ExactReleaseBody `
        -NoExistingRelease $true `
        -AddAssetAfterUpload $true
    $fixtures.Add($postUploadAsset.Root) | Out-Null
    $postUploadAssetResult = Invoke-DraftStepFixture -Fixture $postUploadAsset
    Assert-True "post-upload asset race is rejected" (
        $postUploadAssetResult.ExitCode -ne 0
    ) $postUploadAssetResult.Output

    $stableCreate = New-ReleaseFixture `
        -Name "stable-create" `
        -ExistingBody $script:ExactReleaseBody `
        -NoExistingRelease $true
    $fixtures.Add($stableCreate.Root) | Out-Null
    $stableCreateResult = Invoke-DraftStepFixture -Fixture $stableCreate
    $stableCreateState = Get-Content -Raw -LiteralPath $stableCreate.State | ConvertFrom-Json
    Assert-True "empty draft receives exact assets before successful final readback" (
        $stableCreateResult.ExitCode -eq 0 -and
        [bool]$stableCreateState.release.isDraft -and
        @($stableCreateState.release.assets).Count -eq 3
    ) $stableCreateResult.Output

    $finalReadbackFailure = New-ReleaseFixture `
        -Name "transient-final-readback-failure" `
        -ExistingBody $script:ExactReleaseBody `
        -NoExistingRelease $true `
        -FinalReadbackFailure $true
    $fixtures.Add($finalReadbackFailure.Root) | Out-Null
    $finalReadbackFailureResult = Invoke-DraftStepFixture -Fixture $finalReadbackFailure
    $finalReadbackFailureLog = $finalReadbackFailureResult.Log -join "`n"
    $finalReadbackFailureState = Get-Content -Raw -LiteralPath $finalReadbackFailure.State |
        ConvertFrom-Json
    Assert-True "unknown final draft readback preserves the captured exact draft" (
        $finalReadbackFailureResult.ExitCode -ne 0 -and
        $null -ne $finalReadbackFailureState.release -and
        [int]$finalReadbackFailureState.release.databaseId -eq 5101 -and
        $finalReadbackFailureLog -notmatch '(?m)^api\|.*DELETE.*?/releases/[0-9]+'
    ) ($finalReadbackFailureResult.Output + "; " + $finalReadbackFailureLog)

    $refRace = New-ReleaseFixture `
        -Name "post-create-ref-race" `
        -ExistingBody $script:ExactReleaseBody `
        -NoExistingRelease $true `
        -RefDriftAfterCreate $true
    $fixtures.Add($refRace.Root) | Out-Null
    $refRaceResult = Invoke-DraftStepFixture -Fixture $refRace
    $refRaceLog = $refRaceResult.Log -join "`n"
    Assert-True "post-create ref race fails after removing only the captured release ID" (
        $refRaceResult.ExitCode -ne 0 -and
        $refRaceLog -match 'api\|.*DELETE.*repos/fixture/boring-is-all-you-need/releases/5101' -and
        $refRaceLog -notmatch '(?m)^release\|delete\|'
    ) ($refRaceResult.Output + "; " + $refRaceLog)

    $idObservationFailure = New-ReleaseFixture `
        -Name "post-delete-id-observation-failure" `
        -ExistingBody $script:ExactReleaseBody `
        -NoExistingRelease $true `
        -RefDriftAfterCreate $true `
        -IdObservationFailureAfterDelete $true
    $fixtures.Add($idObservationFailure.Root) | Out-Null
    $idObservationFailureResult = Invoke-DraftStepFixture -Fixture $idObservationFailure
    $idObservationFailureLog = $idObservationFailureResult.Log -join "`n"
    Assert-True "post-delete captured ID observation failure stays fail closed" (
        $idObservationFailureResult.ExitCode -ne 0 -and
        $idObservationFailureLog -match
            'api[|].*repos/fixture/boring-is-all-you-need/releases/5101(?:[|]|$)'
    ) ($idObservationFailureResult.Output + "; " + $idObservationFailureLog)

    $postDeleteReplacement = New-ReleaseFixture `
        -Name "post-delete-replacement" `
        -ExistingBody $script:ExactReleaseBody `
        -NoExistingRelease $true `
        -RefDriftAfterCreate $true `
        -ReplaceAfterDelete $true
    $fixtures.Add($postDeleteReplacement.Root) | Out-Null
    $postDeleteReplacementResult = Invoke-DraftStepFixture -Fixture $postDeleteReplacement
    $postDeleteReplacementLog = $postDeleteReplacementResult.Log -join "`n"
    $postDeleteReplacementState = Get-Content -Raw -LiteralPath $postDeleteReplacement.State |
        ConvertFrom-Json
    $postDeleteReplacementId = if ($null -eq $postDeleteReplacementState.release) {
        -1
    }
    else { [int]$postDeleteReplacementState.release.databaseId }
    $postDeleteDeleteCount = @($postDeleteReplacementResult.Log | Where-Object {
        $_ -match 'api[|].*DELETE[|].*repos/fixture/boring-is-all-you-need/releases/[0-9]+'
    }).Count
    $postDeleteIdReadObserved = @($postDeleteReplacementResult.Log | Where-Object {
        $_ -match 'api[|].*repos/fixture/boring-is-all-you-need/releases/5101(?:[|]|$)'
    }).Count -ge 1
    Assert-True "post-delete replacement is preserved after captured ID absence" (
        $postDeleteReplacementResult.ExitCode -ne 0 -and
        $postDeleteReplacementId -eq 5999 -and
        $postDeleteDeleteCount -eq 1 -and
        $postDeleteIdReadObserved
    ) (
        "exit={0}; replacementId={1}; deleteCount={2}; idRead={3}; {4}" -f
            $postDeleteReplacementResult.ExitCode, $postDeleteReplacementId,
            $postDeleteDeleteCount, $postDeleteIdReadObserved, $postDeleteReplacementLog
    )

    $replacement = New-ReleaseFixture `
        -Name "concurrent-replacement" `
        -ExistingBody $script:ExactReleaseBody `
        -NoExistingRelease $true `
        -RefDriftAfterCreate $true `
        -ReplaceAfterCreate $true
    $fixtures.Add($replacement.Root) | Out-Null
    $replacementResult = Invoke-DraftStepFixture -Fixture $replacement
    $replacementLog = $replacementResult.Log -join "`n"
    $replacementState = Get-Content -Raw -LiteralPath $replacement.State | ConvertFrom-Json
    Assert-True "post-upload replacement release ID is preserved and never deleted" (
        $replacementResult.ExitCode -ne 0 -and
        [int]$replacementState.release.databaseId -eq 5999 -and
        $replacementLog -notmatch '(?m)^api\|.*DELETE.*?/releases/[0-9]+' -and
        $replacementLog -notmatch '(?m)^release\|delete\|'
    ) ($replacementResult.Output + "; " + $replacementLog)
}
finally {
    foreach ($fixture in $fixtures) {
        if (Test-Path -LiteralPath $fixture) {
            Remove-Item -LiteralPath $fixture -Recurse -Force
        }
    }
}

Write-Host ("RESULT pass={0} fail={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

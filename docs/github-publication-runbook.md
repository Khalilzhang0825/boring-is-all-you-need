# GitHub Publication Runbook

Use this runbook after local release-readiness passes and before any public push, tag, or release.

Prerequisites: authenticated `git` and current `gh`, `origin` set to
`Khalilzhang0825/boring-is-all-you-need`, permission to push the reviewed branch and create
the protected `v3.0.0` tag, and repository Actions allowed to write contents,
OIDC tokens, and attestations.

## Required Local Evidence

Run from a clean working tree:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

This aggregate gate owns the single installed Hook-suite invocation and includes the phase, runtime, migration, equivalence, checkpoint, pre-commit, and skill-catalog child gates. Do not rerun child gates as separate release requirements.

Record the command output, GitHub Actions run URL, release URL, tag, target commit, and repository metadata update notes.

The release artifact must be built by `.github/workflows/release.yml` from the exact `v3.0.0` tag. Do not upload a locally assembled replacement archive.

## Maintainer Approval

Only run public GitHub writes after explicit maintainer approval.

Required approval items:

- target repository
- target branch
- tag name
- target commit
- release type

## Push And PR

Only run after explicit maintainer approval:

```powershell
$Branch = ([string](git branch --show-current)).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Branch)) {
  throw "Could not resolve the current branch."
}
git check-ref-format --branch $Branch
if ($LASTEXITCODE -ne 0) { throw "The current branch name is not publishable." }
git push -u origin ("refs/heads/{0}:refs/heads/{0}" -f $Branch)
if ($LASTEXITCODE -ne 0) { throw "Branch push failed." }
```

For normal changes, open a PR and let GitHub Actions run before merge.

V3 preserves the public V1 and V2 history. History rewrite, orphan commits, force-push, release replacement, and tag replacement are outside this release procedure.
The workflow freezes `v1.0.0` at
`f80c05c4b79e069ee3a35db3c09a8f870bca0b59`, requires it to be an ancestor of the release candidate,
and requires the single repository root
`7641ff9ff8c372036766541d565b81e44e1f8704`.

## Repository Metadata

Recommended GitHub description:

```text
Boring Is All You Need: a Codex Desktop workflow replacement with transactional migration, audit-only managed hooks, risk-based review, scoped checkpoint commits, and release evidence.
```

Recommended topics:

```text
ai-agents, coding-agents, codex, codex-desktop, agents-md, developer-tools, powershell, workflow-automation, prompt-engineering
```

## Release

Do not create or replace a tag or GitHub release until explicit maintainer approval confirms the tag name, release type, and target commit.

Release template:

```text
Tag: v3.0.0
Title: Boring Is All You Need v3.0.0
Target commit: the exact `$ReviewedSha` resolved and verified below
```

After the reviewed commit is merged to and is the current tip of `main`, create
and push the exact tag:

```powershell
$Tag = "v3.0.0"
$ReviewedSha = git rev-parse origin/main
if ($LASTEXITCODE -ne 0 -or $ReviewedSha.Trim() -notmatch '^[0-9a-f]{40}$') { throw "Could not resolve origin/main." }
$ReviewedSha = ([string]$ReviewedSha).Trim()
$HeadSha = git rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $HeadSha.Trim() -ne $ReviewedSha) { throw "HEAD is not origin/main." }

function Get-RemoteTagCommit {
  $lines = @(git ls-remote --exit-code --tags origin "refs/tags/$Tag" "refs/tags/$Tag^{}")
  $code = $LASTEXITCODE
  if ($code -eq 2) { return $null }
  if ($code -ne 0) { throw "Could not inspect the remote release tag." }
  $peeled = @($lines | Where-Object { $_ -match '\^\{\}$' })
  $selected = if ($peeled.Count -eq 1) { $peeled[0] } elseif ($lines.Count -eq 1) { $lines[0] } else { throw "Remote release tag resolution is ambiguous." }
  $sha = ($selected -split '\s+')[0]
  $sha = [string]$sha
  if ($sha -notmatch '^[0-9a-f]{40}$') { throw "Remote release tag did not resolve to a commit." }
  return $sha
}

$LocalTagCommit = git rev-parse --verify --quiet "refs/tags/$Tag^{commit}"
$LocalTagCommit = [string]$LocalTagCommit
$LocalTagExit = $LASTEXITCODE
if ($LocalTagExit -eq 1) {
  git tag $Tag $ReviewedSha
  if ($LASTEXITCODE -ne 0) { throw "Could not create the reviewed local release tag." }
} elseif ($LocalTagExit -ne 0) {
  throw "Could not inspect the local release tag."
}
$LocalTagCommit = git rev-parse "refs/tags/$Tag^{commit}"
$LocalTagCommit = [string]$LocalTagCommit
if ($LASTEXITCODE -ne 0 -or $LocalTagCommit.Trim() -ne $ReviewedSha) { throw "The local release tag is not the reviewed commit." }

$RemoteTagCommit = Get-RemoteTagCommit
if ($null -ne $RemoteTagCommit -and $RemoteTagCommit -ne $ReviewedSha) { throw "The remote release tag already targets a different commit." }
if ($null -eq $RemoteTagCommit) {
  git push origin "refs/tags/$Tag:refs/tags/$Tag"
  if ($LASTEXITCODE -ne 0) { throw "Could not push the reviewed release tag." }
  $RemoteTagCommit = Get-RemoteTagCommit
  if ($RemoteTagCommit -ne $ReviewedSha) { throw "The pushed release tag did not read back as the reviewed commit." }
} else {
  Write-Host "The remote release tag already targets the reviewed commit; no tag write was made."
}
```

The tag triggers three pinned, Node-24-native, least-privilege jobs serialized by an exact-release concurrency group. The read-only build job reruns the clean tag-checkout gate from the frozen V1 whitespace baseline, creates `boring-is-all-you-need-v3.0.0.zip`, validates the exact extracted archive without `.git`, and transfers its SHA-256-bound bundle. The attestation job has only read, OIDC, and attestation permissions and attests that reviewed archive. The contents-write job creates only a **draft** GitHub release whose generated body displays the reviewed commit. It re-resolves the live lightweight or annotated tag and `main` immediately before and after creation. On retry it accepts only a non-prerelease draft with the exact title/body and three byte-exact assets: archive, checksum, and machine-readable provenance. Every other existing release is preserved for manual review. After upload it reads the live release back and requires the captured release ID, exact draft state, body, assets, digests, tag, and `main`. If refs drift after creation, automatic cleanup is allowed only when the live draft still has the release ID captured from that run and remains exact.

Before publishing that draft:

```powershell
gh attestation verify --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "GitHub CLI does not provide attestation verification." }
gh release download v3.0.0 -R Khalilzhang0825/boring-is-all-you-need -p "boring-is-all-you-need-v3.0.0.*"
if ($LASTEXITCODE -ne 0) { throw "Could not download the exact v3.0.0 release assets." }
$Provenance = Get-Content -Raw .\boring-is-all-you-need-v3.0.0.provenance.json | ConvertFrom-Json
$ReviewedSha = [string]$Provenance.reviewedCommit
$Expected = (Get-Content -Raw .\boring-is-all-you-need-v3.0.0.zip.sha256).Split(" ")[0].Trim()
$Actual = (Get-FileHash .\boring-is-all-you-need-v3.0.0.zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ([int]$Provenance.schemaVersion -ne 1 -or
    [string]$Provenance.releaseTag -cne "v3.0.0" -or
    $ReviewedSha -notmatch '^[0-9a-f]{40}$' -or
    [string]$Provenance.archiveName -cne "boring-is-all-you-need-v3.0.0.zip" -or
    [string]$Provenance.archiveSha256 -cne $Actual -or
    $Expected -cne $Actual -or
    [string]$Provenance.sourceRepository -cne "Khalilzhang0825/boring-is-all-you-need" -or
    [string]$Provenance.sourceRef -cne "refs/tags/v3.0.0" -or
    [string]$Provenance.signerWorkflow -cne "Khalilzhang0825/boring-is-all-you-need/.github/workflows/release.yml") {
  throw "Release provenance or digest mismatch."
}
gh attestation verify .\boring-is-all-you-need-v3.0.0.zip `
  -R Khalilzhang0825/boring-is-all-you-need `
  --signer-workflow Khalilzhang0825/boring-is-all-you-need/.github/workflows/release.yml `
  --source-ref refs/tags/v3.0.0 `
  --source-digest $ReviewedSha
if ($LASTEXITCODE -ne 0) { throw "Release attestation verification failed; do not extract or run this archive." }
Expand-Archive .\boring-is-all-you-need-v3.0.0.zip .\release-check
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\release-check\boring-is-all-you-need-v3.0.0\tools\validate-release-archive.ps1
```

Install or update the current [GitHub CLI](https://cli.github.com/) if `gh attestation verify --help` fails. Online attestation verification requires network access to GitHub; do not substitute the sidecar alone as provenance.

If a failed workflow left a partial draft, do not rerun blindly. Only after
explicit maintainer approval, use the failed run's retained bundle to prove the
draft is the exact, unchanged partial output of that run. The recovery below
captures its numeric ID, checks every present asset against the workflow bundle,
re-reads the same ID immediately before deletion, deletes only that ID, and
confirms that ID is absent while preserving any concurrent replacement:

```powershell
$Repository = "Khalilzhang0825/boring-is-all-you-need"
$Tag = "v3.0.0"
$RunIdText = Read-Host "Paste the failed release workflow run ID"
$RunId = 0L
if (-not [long]::TryParse($RunIdText, [ref]$RunId) -or $RunId -le 0) { throw "The workflow run ID is invalid." }
$ExpectedRoot = Join-Path $env:TEMP ("steadyagent-release-recovery-" + [guid]::NewGuid().ToString("N"))
$RemoteRoot = Join-Path $ExpectedRoot "remote"
New-Item -ItemType Directory -Path $RemoteRoot -Force | Out-Null
gh run download $RunId -R $Repository -n boring-is-all-you-need-v3.0.0-release-bundle -D $ExpectedRoot
if ($LASTEXITCODE -ne 0) { throw "Could not download the failed run's reviewed bundle." }

function Get-ReleaseById {
  param([long]$ReleaseId)
  $json = gh api "repos/$Repository/releases/$ReleaseId"
  if ($LASTEXITCODE -ne 0) { throw "Could not read release ID $ReleaseId." }
  return ($json | ConvertFrom-Json)
}
function Get-ReleaseProjection {
  param([object]$State)
  $assets = @($State.assets | Sort-Object name | ForEach-Object {
    [ordered]@{ id = [long]$_.id; name = [string]$_.name; size = [long]$_.size; digest = [string]$_.digest; updated_at = [string]$_.updated_at }
  })
  return ([ordered]@{
    id = [long]$State.id; draft = [bool]$State.draft; prerelease = [bool]$State.prerelease
    tag_name = [string]$State.tag_name; name = [string]$State.name; body = [string]$State.body; assets = $assets
  } | ConvertTo-Json -Depth 5 -Compress)
}

$tagJson = gh api "repos/$Repository/releases/tags/$Tag"
if ($LASTEXITCODE -ne 0) { throw "Could not read the partial draft by tag." }
$CapturedDraft = $tagJson | ConvertFrom-Json
$CapturedReleaseId = [long]$CapturedDraft.id
$ExpectedBody = [IO.File]::ReadAllText((Join-Path $ExpectedRoot "RELEASE_BODY.md"), [Text.Encoding]::UTF8)
$ExpectedAssetNames = @(
  "boring-is-all-you-need-v3.0.0.provenance.json",
  "boring-is-all-you-need-v3.0.0.zip",
  "boring-is-all-you-need-v3.0.0.zip.sha256"
)
$CapturedAssetNames = @($CapturedDraft.assets | ForEach-Object { [string]$_.name } | Sort-Object)
if ($CapturedReleaseId -le 0 -or -not [bool]$CapturedDraft.draft -or [bool]$CapturedDraft.prerelease -or
    [string]$CapturedDraft.tag_name -cne $Tag -or [string]$CapturedDraft.name -cne "Boring Is All You Need v3.0.0" -or
    [string]$CapturedDraft.body -cne $ExpectedBody -or $CapturedAssetNames.Count -ge 3 -or
    @($CapturedAssetNames | Where-Object { $ExpectedAssetNames -notcontains $_ }).Count -ne 0 -or
    @($CapturedAssetNames | Sort-Object -Unique).Count -ne $CapturedAssetNames.Count) {
  throw "The live release is not the exact partial draft created by the failed run."
}
foreach ($assetName in $CapturedAssetNames) {
  gh release download $Tag -R $Repository -D $RemoteRoot -p $assetName
  if ($LASTEXITCODE -ne 0) { throw "Could not download partial draft asset $assetName." }
  $expectedPath = Join-Path $ExpectedRoot $assetName
  $remotePath = Join-Path $RemoteRoot $assetName
  if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf) -or
      (Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash -cne
      (Get-FileHash -LiteralPath $remotePath -Algorithm SHA256).Hash) {
    throw "Partial draft asset $assetName is not byte-exact."
  }
}
$CapturedProjection = Get-ReleaseProjection -State $CapturedDraft
$BeforeDelete = Get-ReleaseById -ReleaseId $CapturedReleaseId
if ((Get-ReleaseProjection -State $BeforeDelete) -cne $CapturedProjection) { throw "The captured draft changed before deletion; preserve it." }
gh api --method DELETE "repos/$Repository/releases/$CapturedReleaseId"
if ($LASTEXITCODE -ne 0) { throw "Could not delete the captured partial draft ID." }
$allJson = gh api --paginate --slurp "repos/$Repository/releases?per_page=100"
if ($LASTEXITCODE -ne 0) { throw "Could not confirm deletion of the captured release ID." }
$allReleases = @($allJson | ConvertFrom-Json | ForEach-Object { $_ | ForEach-Object { $_ } })
if (@($allReleases | Where-Object { [long]$_.id -eq $CapturedReleaseId }).Count -ne 0) { throw "The captured release ID still exists." }
$replacement = @($allReleases | Where-Object { [string]$_.tag_name -ceq $Tag -and [long]$_.id -ne $CapturedReleaseId })
if ($replacement.Count -gt 0) { Write-Host "A replacement release exists and was preserved for manual review." }
gh run rerun $RunId --failed -R $Repository
if ($LASTEXITCODE -ne 0) { throw "Could not rerun the failed workflow jobs." }
```

The draft release body should include:

- what changed
- included public assets
- validation results
- known limits
- the workflow-generated reviewed commit

Publish only after the workflow is green, attestation verification succeeds, the digest matches, and the no-Git archive validator reports `fail=0`. Separately confirm a fresh clone of the tag passes the Git-aware clean release gate. Immediately before making the draft public, resolve the live tag and `main` again and require both to equal the recorded reviewed commit. Attestation establishes provenance; it is not a guarantee that the code is vulnerability-free.

```powershell
$Repository = "Khalilzhang0825/boring-is-all-you-need"
$Tag = "v3.0.0"
$Provenance = Get-Content -Raw .\boring-is-all-you-need-v3.0.0.provenance.json | ConvertFrom-Json
$ReviewedSha = [string]$Provenance.reviewedCommit
$ExpectedAssetNames = @(
  "boring-is-all-you-need-v3.0.0.provenance.json",
  "boring-is-all-you-need-v3.0.0.zip",
  "boring-is-all-you-need-v3.0.0.zip.sha256"
)
$ReleaseNotes = [IO.File]::ReadAllText((Resolve-Path .\RELEASE_NOTES.md), [Text.Encoding]::UTF8).TrimEnd([char[]]"`r`n")
$ExpectedBody = $ReleaseNotes + "`n`n## Verified provenance`n`nReviewed commit: $ReviewedSha`nSource ref: refs/tags/v3.0.0`n"
$ExpectedBodyHash = [BitConverter]::ToString(
  [Security.Cryptography.SHA256]::Create().ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($ExpectedBody))
).Replace("-", "").ToLowerInvariant()
if ([string]$Provenance.releaseBodySha256 -cne $ExpectedBodyHash) { throw "The local release body does not match provenance." }

function Get-ReleaseById {
  param([long]$ReleaseId)
  $json = gh api "repos/$Repository/releases/$ReleaseId"
  if ($LASTEXITCODE -ne 0) { throw "Could not read release ID $ReleaseId." }
  return ($json | ConvertFrom-Json)
}
function Get-ReleaseProjection {
  param([object]$State)
  $assets = @($State.assets | Sort-Object name | ForEach-Object {
    [ordered]@{ id = [long]$_.id; name = [string]$_.name; size = [long]$_.size; digest = [string]$_.digest; updated_at = [string]$_.updated_at }
  })
  return ([ordered]@{
    id = [long]$State.id; draft = [bool]$State.draft; prerelease = [bool]$State.prerelease
    tag_name = [string]$State.tag_name; name = [string]$State.name; body = [string]$State.body; assets = $assets
  } | ConvertTo-Json -Depth 5 -Compress)
}
function Assert-ExactReleaseDraft {
  param([object]$State, [long]$ReleaseId)
  $assetNames = @($State.assets | ForEach-Object { [string]$_.name } | Sort-Object)
  if ([long]$State.id -ne $ReleaseId -or -not [bool]$State.draft -or [bool]$State.prerelease -or
      [string]$State.tag_name -cne $Tag -or [string]$State.name -cne "Boring Is All You Need v3.0.0" -or
      [string]$State.body -cne $ExpectedBody -or ($assetNames -join "|") -cne
      "boring-is-all-you-need-v3.0.0.provenance.json|boring-is-all-you-need-v3.0.0.zip|boring-is-all-you-need-v3.0.0.zip.sha256") {
    throw "The captured release is not the exact reviewed draft."
  }
}

$tagJson = gh api "repos/$Repository/releases/tags/$Tag"
if ($LASTEXITCODE -ne 0) { throw "Could not read the reviewed draft by tag." }
$CapturedDraft = $tagJson | ConvertFrom-Json
$CapturedReleaseId = [long]$CapturedDraft.id
Assert-ExactReleaseDraft -State $CapturedDraft -ReleaseId $CapturedReleaseId
$CapturedProjection = Get-ReleaseProjection -State $CapturedDraft
$CapturedAssetProjection = @($CapturedDraft.assets | Sort-Object name | ForEach-Object {
  [ordered]@{ id = [long]$_.id; name = [string]$_.name; size = [long]$_.size; digest = [string]$_.digest; updated_at = [string]$_.updated_at }
}) | ConvertTo-Json -Depth 4 -Compress
$RemoteRoot = Join-Path $env:TEMP ("steadyagent-publish-check-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $RemoteRoot -Force | Out-Null
foreach ($assetName in $ExpectedAssetNames) {
  gh release download $Tag -R $Repository -D $RemoteRoot -p $assetName
  if ($LASTEXITCODE -ne 0) { throw "Could not download draft asset $assetName." }
  if ((Get-FileHash -LiteralPath (Join-Path $RemoteRoot $assetName) -Algorithm SHA256).Hash -cne
      (Get-FileHash -LiteralPath (Resolve-Path (".\" + $assetName)) -Algorithm SHA256).Hash) {
    throw "Draft asset $assetName changed after verification."
  }
}
function Assert-TagPublicationGuards {
  param([string]$Repository, [string]$Tag)
  $ImmutableJson = gh api -H "X-GitHub-Api-Version: 2026-03-10" "repos/$Repository/immutable-releases"
  if ($LASTEXITCODE -ne 0) { throw "Immutable releases are not enabled or could not be verified." }
  $ImmutableState = $ImmutableJson | ConvertFrom-Json
  if (-not [bool]$ImmutableState.enabled) { throw "Immutable releases must be enabled before publication." }
  $RulesetSummariesJson = gh api -H "X-GitHub-Api-Version: 2026-03-10" `
    "repos/$Repository/rulesets?targets=tag&per_page=100"
  if ($LASTEXITCODE -ne 0) { throw "Could not enumerate tag rulesets." }
  $ExactTagRef = "refs/tags/$Tag"
  $ExactGuardFound = $false
  foreach ($summary in @($RulesetSummariesJson | ConvertFrom-Json)) {
    $RulesetJson = gh api -H "X-GitHub-Api-Version: 2026-03-10" `
      "repos/$Repository/rulesets/$([long]$summary.id)"
    if ($LASTEXITCODE -ne 0) { throw "Could not read a tag ruleset." }
    $Ruleset = $RulesetJson | ConvertFrom-Json
    $Includes = @($Ruleset.conditions.ref_name.include | ForEach-Object { [string]$_ })
    $Excludes = @($Ruleset.conditions.ref_name.exclude | ForEach-Object { [string]$_ })
    $RuleTypes = @($Ruleset.rules | ForEach-Object { [string]$_.type })
    $BypassProperty = $Ruleset.PSObject.Properties['bypass_actors']
    $HasExplicitNoBypass = (
      $null -ne $BypassProperty -and
      $null -ne $BypassProperty.Value -and
      @($BypassProperty.Value).Count -eq 0
    )
    if ([string]$Ruleset.target -ceq "tag" -and
        [string]$Ruleset.enforcement -ceq "active" -and
        $HasExplicitNoBypass -and
        $Includes -ccontains $ExactTagRef -and
        $Excludes.Count -eq 0 -and
        $RuleTypes -ccontains "update" -and
        $RuleTypes -ccontains "deletion") {
      $ExactGuardFound = $true
    }
  }
  if (-not $ExactGuardFound) {
    throw "An active no-bypass tag ruleset must block update and deletion of the exact release tag."
  }
}
Assert-TagPublicationGuards -Repository $Repository -Tag $Tag
$BeforePublish = Get-ReleaseById -ReleaseId $CapturedReleaseId
Assert-ExactReleaseDraft -State $BeforePublish -ReleaseId $CapturedReleaseId
if ((Get-ReleaseProjection -State $BeforePublish) -cne $CapturedProjection) { throw "The captured draft changed before publication." }
$LiveTagSha = gh api "repos/$Repository/commits/$Tag" --jq .sha
$LiveTagSha = [string]$LiveTagSha
if ($LASTEXITCODE -ne 0) { throw "Could not resolve the live release tag." }
$LiveMainSha = gh api "repos/$Repository/commits/main" --jq .sha
$LiveMainSha = [string]$LiveMainSha
if ($LASTEXITCODE -ne 0) { throw "Could not resolve live main." }
if ($LiveTagSha.Trim() -ne $ReviewedSha -or $LiveMainSha.Trim() -ne $ReviewedSha) {
  throw "Live v3.0.0 or main moved away from the reviewed commit."
}
$publishedJson = gh api --method PATCH "repos/$Repository/releases/$CapturedReleaseId" -F draft=false
if ($LASTEXITCODE -ne 0) { throw "Could not publish the captured release ID." }
$Published = $publishedJson | ConvertFrom-Json
Assert-TagPublicationGuards -Repository $Repository -Tag $Tag
$PostPublishTagSha = [string](gh api "repos/$Repository/commits/$Tag" --jq .sha)
if ($LASTEXITCODE -ne 0) { throw "Could not resolve the post-publication release tag." }
$PostPublishMainSha = [string](gh api "repos/$Repository/commits/main" --jq .sha)
if ($LASTEXITCODE -ne 0) { throw "Could not resolve post-publication main." }
if ($PostPublishTagSha.Trim() -ne $ReviewedSha -or $PostPublishMainSha.Trim() -ne $ReviewedSha) {
  throw "A ref moved during publication; preserve the immutable release evidence and start incident review."
}
$Readback = Get-ReleaseById -ReleaseId $CapturedReleaseId
foreach ($state in @($Published, $Readback)) {
  $assetNames = @($state.assets | ForEach-Object { [string]$_.name } | Sort-Object)
  $assetProjection = @($state.assets | Sort-Object name | ForEach-Object {
    [ordered]@{ id = [long]$_.id; name = [string]$_.name; size = [long]$_.size; digest = [string]$_.digest; updated_at = [string]$_.updated_at }
  }) | ConvertTo-Json -Depth 4 -Compress
  if ([long]$state.id -ne $CapturedReleaseId -or [bool]$state.draft -or [bool]$state.prerelease -or
      -not [bool]$state.immutable -or
      [string]$state.tag_name -cne $Tag -or [string]$state.name -cne "Boring Is All You Need v3.0.0" -or
      [string]$state.body -cne $ExpectedBody -or ($assetNames -join "|") -cne
      "boring-is-all-you-need-v3.0.0.provenance.json|boring-is-all-you-need-v3.0.0.zip|boring-is-all-you-need-v3.0.0.zip.sha256" -or
      $assetProjection -cne $CapturedAssetProjection) {
    throw "Published release readback is not exact."
  }
}
```

Publication is blocked unless GitHub Live proves both repository immutable releases and an exact, active, no-bypass tag ruleset that rejects updates and deletion of `refs/tags/v3.0.0`. The same guards, tag SHA, main SHA, immutable flag, captured release ID, body, and assets are read back immediately after publication. Do not weaken or bypass these guards; if the post-publication readback fails, preserve the immutable release and open incident review instead of deleting or reusing the tag.

## Post-Publish Checks

- Confirm README renders on GitHub.
- Confirm GitHub Actions is green.
- Confirm the release workflow used pinned action commits and its attestation verifies against `Khalilzhang0825/boring-is-all-you-need`.
- Confirm the downloaded archive matches its SHA-256 sidecar and a fresh extraction passes `validate-release-archive.ps1`.
- Confirm a fresh clone of the tag passes the Git-aware `validate-release-readiness.ps1`.
- Confirm release page links to the correct tag and target commit.
- Confirm repository description and topics are updated.
- Confirm no private paths, local-only claims, or maintainer-only state appear in public pages.
- Save the PR URL, GitHub Actions run URL, release URL, tag, commit hash, repository metadata update notes, and validation outputs as the release audit trail.

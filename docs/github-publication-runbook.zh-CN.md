# GitHub Publication Runbook

本文件用于本地 release-readiness 通过后、公开 push / tag / release / history rewrite 前的最终执行。

## 必备本地证据

在干净 working tree 根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-phase3.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-runtime-slice.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-agent-hooks.ps1
```

记录命令输出、GitHub Actions run URL、release URL、tag、目标 commit 和 repository metadata update notes。

## Maintainer Approval

只有得到 maintainer 明确批准后，才执行公开 GitHub 写操作；approval boundary: explicit maintainer approval。

批准项必须包括：

- 目标仓库
- 目标分支
- tag name
- target commit
- release type
- 是否 rewrite history

## Push And PR

只有得到 maintainer 明确批准后才运行：

```powershell
git push -u origin <branch>
```

普通改动应先开 PR，等待 GitHub Actions 通过后再 merge。

如果是 clean-history release rewrite，使用 orphan commit 或等价的 Git data API 工作流；只有本地验证和 independent review 都通过后，才 force-update default branch。

## Clean-History Rewrite

只有 maintainer 明确批准 rewrite history 时，才使用这条路径。

必需顺序：

1. 为旧 default branch 创建本地 backup ref。
2. 从已审查的 release tree 创建干净 orphan/root commit。
3. 删除会暴露旧 checkpoint history 的 stale remote branches，尤其是临时 `codex/*` release branches。
4. 替换 tag 前，先删除或替换现有 GitHub release。
5. 删除并重建 release tag，让它指向干净 commit。
6. force-update default branch 到干净 commit。
7. 基于干净 tag 重建 GitHub release。
8. 从空目录做 fresh clone verification。

Fresh clone verification 必须检查：

```powershell
git branch -r
git tag -l
git log --all --oneline
git log --all --grep "<private checkpoint label>"
```

还要在 fresh clone 里运行公开残留扫描和 release gate：

```powershell
$patterns = @("zsh" + "-agent-rules", "validate-phase[0-2]", "v1" + "-migration-plan", "release" + "-plan")
foreach ($pattern in $patterns) { rg -n $pattern . }
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

只有 default branch、`v2.0.0` tag、GitHub release、remote branch list 和 fresh clone history 都只指向干净公开产物时，rewrite 才算完成。

## Repository Metadata

推荐 GitHub description：

```text
SteadyAgent 2: a Codex Desktop workflow replacement with transactional migration, fail-closed safety hooks, risk-based review, checkpoint commits, and release evidence.
```

推荐 topics：

```text
ai-agents, coding-agents, codex, codex-desktop, agents-md, developer-tools, powershell, workflow-automation, prompt-engineering
```

## Release

只有 maintainer 明确批准 tag/release、版本号、发布类型和目标 commit 后，才可以创建或替换 tag / GitHub release。

Release template：

```text
Tag: v2.0.0
Title: SteadyAgent v2.0.0
Target commit: <commit>
```

Release body 应包含：

- 本次变更
- 已包含的公开资产
- validation results
- known limits

## 发布后检查

- 确认 README 在 GitHub 正常渲染。
- 确认 GitHub Actions 通过。
- 确认 release 页面指向正确 tag 和 target commit。
- 确认 repository description 和 topics 已更新。
- 确认公开页面没有 private paths、local-only claims 或 maintainer-only state。
- 保存 PR URL、GitHub Actions run URL、release URL、tag、commit hash、repository metadata update notes 和验证输出，形成发布审计链。

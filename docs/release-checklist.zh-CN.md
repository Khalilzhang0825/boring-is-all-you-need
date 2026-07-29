# Release Checklist

发布 SteadyAgent V2 tag 或 GitHub release 前，用这份清单做最后验收。

## 必跑门禁

在干净 checkout 根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-phase3.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-runtime-slice.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

`validate-release-readiness.ps1` 会覆盖 fresh-checkout 风格快照、V2 事务迁移、Codex 渲染配置、安装后诊断、Hook/checkpoint/pre-commit 测试、本地 Markdown 链接和公开发布资产。

本地 WIP、checkpoint commit 之前，可以加 `-AllowDirty` 验证当前未提交 release surface。最终发布证据必须在干净 checkout 中运行，不加 `-AllowDirty`。

## 人工复查

- 确认 `README.md` 和 `README.zh-CN.md` 描述的是同一套 V2 能力。
- 确认 `LICENSE`、`CONTRIBUTING.md`、`SECURITY.md` 和 `RELEASE_NOTES.md` 都存在。
- 确认 `.github/` issue/PR 模板和 validation workflow 已存在。
- 确认公开 skill 路径是 `skills/steadyagent-workflow/`。
- 远端 push、PR、tag 或 GitHub release 前，先按 [docs/github-publication-runbook.zh-CN.md](github-publication-runbook.zh-CN.md) 执行。
- 发布前启用 GitHub Private Vulnerability Reporting，并确认仓库的 **Report a vulnerability** 入口可打开。
- 确认 `git diff --check` 没有 whitespace errors。
- 确认 checkpoint commit 后 `git status --short` 干净。
- maintainer 明确批准前，不 push、不 tag、不 publish。

## 需要保留的发布证据

- 验证命令输出。
- 独立 review 分数和 findings。
- Checkpoint commit hash。
- 发布后的 PR URL、GitHub Actions URL、release URL 和 repository metadata 更新记录。
- 已知边界：Windows-first 脚本、Codex managed hooks 必须在重启后做 Live 验证，自动化验证不会写入用户真实全局 Codex 配置。

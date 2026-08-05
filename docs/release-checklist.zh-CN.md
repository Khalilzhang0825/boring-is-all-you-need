# Release Checklist

发布 Boring Is All You Need v2 tag 或 GitHub release 前，用这份清单做最后验收。

## 必跑门禁

在干净 checkout 根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

这是唯一的聚合门。`validate-release-readiness.ps1` 已包含 phase 验证、runtime slice、fresh-checkout 风格快照、V2 事务迁移、Codex 渲染配置、安装后诊断、Hook/checkpoint/pre-commit/skill-catalog 测试、带故意红灯证明的 23 项本机等价合同、mock-`gh` release 状态机套件，以及从 merge-base 到最终工作树的 whitespace 检查；其中 tracked 文件直接检查，untracked 文件由有界 no-index 子进程检查，全程不暂存也不创建 Git 对象；同时覆盖本地 Markdown 链接和公开发布资产。不要再把其子门作为独立发布必跑项重复执行。

本地 WIP、checkpoint commit 之前，可以加 `-AllowDirty` 验证当前未提交 release surface。最终发布证据必须在干净 checkout 中运行，不加 `-AllowDirty`。

## 人工复查

- 确认 `README.md` 和 `README.zh-CN.md` 描述的是同一套 V2 能力。
- 确认 `LICENSE`、`CONTRIBUTING.md`、`SECURITY.md` 和 `RELEASE_NOTES.md` 都存在。
- 确认 `.github/` issue/PR 模板和 validation workflow 已存在。
- 确认公开 skill 路径是 `skills/steadyagent-workflow/`。
- 确认 `manifests/local-postimage-equivalence.json` 保持 23/23，且等价门无 missing、drift 或未解释目标。Payload 06 必须继续使用 `scoped-equivalent`，并把冻结的 73 条源断言精确分成 65 条保留的 Codex-active 断言和 8 条明确排除的 Claude 或已移除事件断言。
- 确认 `package-assets.sha256` 恰好包含 52 条规范源资产，所有源哈希一致，且 `install.ps1` 中唯一嵌入摘要与 manifest 匹配。
- 确认 `.github/workflows/release.yml` 只接受当前 `origin/main` 上的精确 `v2.0.0` tag，全部 action 固定到已审查的 Node-24-native commit、强制 Node 24、串行化精确 release 且不取消 active run，把只读验证、attestation 与 draft 创建拆为三个最小权限 job，重新运行干净 tag-checkout 门，并在创建前后重新解析 live tag/main。重跑只接受标题、显示 reviewed commit 的正文与三个 asset 都字节精确一致、且不是 prerelease 的 draft。上传后读回还必须匹配捕获的 release ID；创建后 ref 竞态只能删除该 ID，并发替换必须保留。
- 确认 workflow 冻结已审计的 `v1.0.0` commit 与唯一仓库 root、证明 V1 ancestry，并为每个发布命令提供显式 `GH_REPO`/`-R` 上下文。
- 确认每段可复制 GitHub CLI 流程在 capability probe、asset 下载和 attestation 验证后都检查 `$LASTEXITCODE`；从下载的机器可读 provenance asset 得到 `$ReviewedSha`，严格绑定 repository、tag ref、signer workflow、archive 名称与摘要，再通过 `--source-digest $ReviewedSha` 验证 archive、核对 SHA-256 sidecar，并且所有 native-command guard 通过前不得解压。
- 确认本地与远端 `v2.0.0` tag 均只能处于不存在或精确指向已审查 `origin/main` commit 两种状态，每条 native Git 命令都检查退出码，远端已存在 exact tag 时不执行写入。
- 确认 `release-files.txt` 与 tag 仓库和解压 archive 完全一致，没有额外公开文件或 Git metadata。Partial-draft recovery 必须使用失败 run 保留的 bundle、捕获数字 release ID、删除前立即复核 exact draft/body 与每个已有 asset digest，只删除该 ID、确认旧 ID 已消失，并在重跑失败 job 前保留任何并发 replacement。
- 确认最终发布会捕获已审查 draft 的数字 ID，立即复核 exact body、三个字节精确 asset 及其 metadata/digest 与 live tag/main，只按该 ID 执行 PATCH，并按同一已发布 ID 回读精确 body 与 asset snapshot。
- 确认 production Apply 与 rollback 会在迁移写入前拒绝提权 token，不请求 UAC，且不存在受保护 recovery 的 production 入口。
- 确认 Apply 会在首次目标或 Git 写入前 durable 写入并回读 snapshots 与 `applying` 收据；operation 1、中段及 Git 激活后的真实强杀 fixture 必须恢复 managed 文件字节内容/存在性与记录的 Git 值/config 字节。ACL、owner、属性、时间戳和 alternate data streams 不属于 snapshot 合同。
- 确认迁移测试专用根与 injection 必须同时具备 `STEADYAGENT_TEST_MODE=1` 和系统临时目录下现有、basename 严格为 `steadyagent-v2-migration-<32 位小写十六进制>` 的隔离 `STEADYAGENT_TEST_ROOT`，且发行包、工具、收据、目标、配置及 Git 路径均受其约束；checkpoint injection 另行要求 `steadyagent-git-checkpoint-<32 位小写十六进制>`，并在恢复前包含全部 Git 角色。
- 确认 rollback 会在首次受控写入前发布 durable journal，能恢复 operation 1、中段和 Git 后的强杀，并把退出码 3 或 `rollback_incomplete` 作为保留证据、人工对账边界。
- 确认全部示例都使用普通非提权命令，并明确把管理员锁定的 managed 配置标为 unsupported。不得把收据哈希当成身份认证。
- 确认重启后从具有 `CODEX_THREAD_ID` 的新 Codex 任务执行诊断：先运行 `skill-index.ps1 -ThreadId $env:CODEX_THREAD_ID`，再把成功迁移收据与 `-RequireInstalledBytes -RequireHooksActive -RequireRuntimeCatalog -RequireGitIdentity` 一起使用。仓库测试不能替代该 Live canary。
- 远端 push、PR、tag 或 GitHub release 前，先按 [docs/github-publication-runbook.zh-CN.md](github-publication-runbook.zh-CN.md) 执行。
- 发布前启用 GitHub Private Vulnerability Reporting，并确认仓库的 **Report a vulnerability** 入口可打开。
- 发布 captured draft 前，必须保留 GitHub Live 证据：immutable releases 已启用，且存在精确匹配 `refs/tags/v2.0.0`、active、无 bypass actor、阻止 update/deletion 的 tag ruleset；同时保留发布前后 guard 与 ref 回读。
- 确认完整 V2 变更范围运行 `git diff --check f80c05c4b79e069ee3a35db3c09a8f870bca0b59...HEAD` 没有 whitespace errors。
- 确认 checkpoint commit 后 `git status --short` 干净。
- maintainer 明确批准前，不 push、不 tag、不 publish。
- 不得用本地构建压缩包替换 tagged、attested 的工作流产物。
- V2 保留 V1 历史；orphan commit、force-push、tag replacement 与 release replacement 均不属于本次发布。

## 需要保留的发布证据

- 验证命令输出。
- 独立 review 分数和 findings。
- Checkpoint commit hash。
- 发布后的 PR URL、GitHub Actions URL、release URL 和 repository metadata 更新记录。
- 已知边界：Windows-first 脚本、Codex managed hooks 必须在重启后做 Live 验证、自动化验证不会写入用户真实全局 Codex 配置、同用户 guardrail 是协作式防误操作而非对抗性 sandbox，且管理员锁定的 managed 配置不受支持。

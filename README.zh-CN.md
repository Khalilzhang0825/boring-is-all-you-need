# SteadyAgent 2

**用证据交付，而不是凭感觉相信 AI agent。**

SteadyAgent `v2.0.0` 是面向 Windows 的 Codex Desktop 工作流替换包。用户在审阅 dry-run 后，只需一次明确授权，就能把现有 Codex 环境迁移成维护者正在使用的同款轻量工作流：范围控制、确定性安全门、状态恢复、真实验证、只因实质风险触发的独立审查，以及显式文件 checkpoint。

[English README](README.md)

## 2.0.0 的核心变化

- 唯一支持宿主为 Codex Desktop。
- 常驻 runtime 精简为 4 个 managed hook block：一个 `SessionStart`、两个 `PreToolUse`、一个 `PreCompact`。
- 不安装 `UserPromptSubmit`、`PermissionRequest` 或 `PostToolUse`。
- 文件数量本身不再触发独立审查。
- Command/File Guard 递归检查嵌套 parallel；匹配到的 payload 无法理解时 fail closed。
- Guard 日志只记录固定原因、规范化工具名和输入 SHA-256。
- Git checkpoint 使用隔离 index、显式文件、范围复核和单写者锁。
- 全新安装及 V1→V2 迁移均采用事务：预览、冲突检查、备份、原子应用、验证、收据和失败回滚。
- 版本化 V1 资产清单会在明确授权替换时移除旧 Codex 发行面，并可通过同一收据完整恢复。

## 为什么只发布 Codex

维护者的 Anthropic 账户被封，因此从 V2 起停止发布 Anthropic/Claude 兼容层。这是维护者个人经历及据此作出的产品决定。

> 一个连封门都比解释快的公司，就别指望开源维护者继续替它擦门牌了。

V1 历史版本仍保留在 Git 历史中；V2 不再发布 Claude 模板、settings、hooks、测试或安装路径。

## 安全的一键迁移

安装器默认只做 dry-run：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1
```

它会列出所有目标、现有冲突、managed Hook 替换和 Git Hook 变化，但不会写入文件。

确认计划后，全新安装：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply
```

替换 SteadyAgent V1 或已有自定义 Codex 工作流：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -Apply -ReplaceExistingWorkflow
```

若 Codex managed 配置位于 `%ProgramData%`，请在管理员 PowerShell 中执行替换命令。

安装器会：

1. 按当前机器渲染可移植包；
2. 写入前验证全部源与目标；
3. 未明确授权替换时阻断未知差异；
4. 保存每个现有目标及原 Git Hook 路径；
5. 备份并移除旧 Codex 位置中已知的 V1-owned 文件；
6. 在当前会话唯一的 SteadyAgent 迁移互斥锁下原子应用；
7. 逐项并全量验证最终结果；
8. 任一步失败时恢复全部已变更目标；
9. 生成机器可读的 `migration-receipt.json`。

安装器不会修改模型或推理强度。

若要撤销已完成的迁移，先预览，再应用该次安装生成的收据：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath "<备份目录>\migration-receipt.json"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\rollback.ps1" -ReceiptPath "<备份目录>\migration-receipt.json" -Apply
```

回滚器会在任何写入前验证收据、全部已安装文件、原始快照及 active Git Hook 路径；只要安装后发生漂移，就以零写入停止。只使用你自己的 SteadyAgent 安装生成的收据。

## 安装后

重启 Codex Desktop，然后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.steadyagent\tools\diagnose-install.ps1" -RequireHooksActive
```

预期结果：

```text
RESULT pass=<n> warn=0 fail=0
```

诊断会检查安装资产、空用户 hooks、精确 4-block managed 矩阵、所有已知 V1-owned Codex 文件均已移除、渲染路径、active Git Hook 路径以及安装后的 Hook smoke。

## 日常闭环

```text
understand -> plan -> red check -> smallest change -> green check -> review when risk requires it -> checkpoint
```

SteadyAgent 要求 Codex：

- 修改前检查仓库；
- 修复前先诊断；
- 保护用户已有和无关改动；
- 运行最小相关验证；
- 只有明确审查请求或实质风险才调用 fresh reviewer；
- checkpoint 只包含显式文件；
- 未授权时不 push、发布、部署、迁移、安装或执行破坏性操作；
- 压缩前固化状态，恢复后重新读取。

## 主要命令

| 命令 | 作用 |
| --- | --- |
| `tools/install.ps1` | Dry-run 或事务式迁移 Codex 工作流。 |
| `tools/rollback.ps1` | Dry-run 或按收据事务式恢复已完成迁移。 |
| `tools/diagnose-install.ps1` | 验证安装资产和 active managed hooks。 |
| `tools/test-v2-migration.ps1` | 验证全新安装、替换、冲突和回滚。 |
| `tools/test-agent-hooks.ps1` | 验证 SessionStart、Guard、日志和 PreCompact。 |
| `tools/test-git-checkpoint.ps1` | 验证显式文件 checkpoint 事务。 |
| `tools/test-pre-commit.ps1` | 验证 staged 密钥和大文件防线。 |
| `tools/validate-release-readiness.ps1` | 运行完整 V2 发布门。 |

## Runtime 架构

| 层级 | 职责 |
| --- | --- |
| `templates/codex/AGENTS.md` | Codex 常驻短合同。 |
| `rules/` | 渐进式 workflow、verification、review、skill、context 和 safety 规则。 |
| `tools/hooks/` | Fail-closed Guard、状态注入和 PreCompact 提醒。 |
| `tools/git-checkpoint.ps1` | 限定范围、可恢复的本地提交。 |
| `tools/git-hooks/` | 全局 pre-commit 防线。 |
| `skills/steadyagent-workflow/` | 用户显式调用的通用工作流 skill。 |
| `tools/install.ps1` | 可移植渲染与事务迁移引擎。 |
| `tools/rollback.ps1` | 收据绑定、漂移感知的事务恢复工具。 |

Hooks 用于减少常见误操作，不是完整安全沙箱；人工授权和项目级验证仍然必要。

## 发布验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

发布门覆盖 PowerShell 5.1 语法、公开路径和密钥、Codex-only 资产、文档链接、迁移 fixture、Hook、checkpoint/pre-commit、全新安装、安装后诊断以及发布元数据。

## 兼容性

- Windows 10/11
- Windows PowerShell 5.1
- Codex Desktop managed hooks
- Git for Windows

Linux、macOS、其他 coding agent 和 Anthropic 产品不属于 V2 支持合同。

## License

MIT。见 [LICENSE](LICENSE)。

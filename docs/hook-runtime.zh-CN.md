# Boring Is All You Need Hook Runtime

Codex runtime 精确包含 3 个 managed Hook block：

| 事件 | 行为 |
| --- | --- |
| `SessionStart` | 只注入动态 Caveman 状态、lessons 标题、真正到期的 90 天 Harness review 提醒，并在 resume/compact 后恢复 `PROJECT_STATE.md` 或 `.agent/state.md`。fresh install 缺少 review marker 时，以已安装 context Hook 的 mtime 作为首次 90 天基线。 |
| `PreToolUse` | 在一个 PowerShell 进程内递归检查匹配的 shell 与文件编辑叶子。标准 managed 命令使用 `-EnforcementMode Audit`，尽力记录已识别风险，但永远不返回 deny。 |
| `PreCompact` | 提醒 Agent 固化当前状态。 |

V2 没有每轮 prompt、权限请求或工具后审计 Hook。

标准 managed Audit 模式下，匹配事件中的 malformed 输入、不完整相关 leaf 和未知嵌套 parallel schema 均不会返回 deny；维护者可显式选择 `-EnforcementMode Enforce`，此时同类输入 fail closed。明确命名的无关工具不作决定。Hook 套件会记录普通 shell、文件编辑和 mixed parallel 的精确 managed 调用次数，并报告宽松的 Windows PowerShell 5.1 冷启动预算，用来捕获重复启动或明显退化，而不是设置容易抖动的紧墙钟阈值。

Guard 日志只含时间、固定原因、规范化工具名和输入 SHA-256，不记录原始命令、路径、patch 或文件内容。

运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-agent-hooks.ps1
```

脚本测试只能证明包内行为，不能证明宿主已注册。重启 Codex 后，安装后诊断只建立配置与 rollout-file 证据；还必须在真实新任务中观察 SessionStart 和一个受控 Hook 行为，才能完成 Live 验收。

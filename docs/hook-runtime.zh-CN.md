# SteadyAgent 2 Hook Runtime

Codex runtime 精确包含 4 个 managed Hook block：

| 事件 | 行为 |
| --- | --- |
| `SessionStart` | 注入短 Codex 合同，并在 resume/compact 后恢复 `PROJECT_STATE.md` 或 `.agent/state.md`。 |
| `PreToolUse` | 递归检查匹配的 shell 调用并拒绝危险命令。 |
| `PreToolUse` | 递归检查匹配的文件编辑并拒绝受保护路径。 |
| `PreCompact` | 提醒 Agent 固化当前状态。 |

V2 没有每轮 prompt、权限请求或工具后审计 Hook。

匹配事件中的 malformed 输入、不完整相关 leaf 和未知嵌套 parallel schema 均 fail closed；明确命名的无关工具不作决定。

Guard 日志只含时间、固定原因、规范化工具名和输入 SHA-256，不记录原始命令、路径、patch 或文件内容。

运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\test-agent-hooks.ps1
```

脚本测试只能证明 runtime 行为，不能证明宿主已注册。Live 验收仍需重启 Codex 并运行安装后诊断。

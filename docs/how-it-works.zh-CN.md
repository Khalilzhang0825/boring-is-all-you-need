# SteadyAgent 2 如何工作

SteadyAgent 在 Codex Desktop 外围组合六层能力：

1. 短 `AGENTS.md` 合同；
2. 按需加载的渐进规则；
3. 用户显式调用的 workflow skill；
4. 确定性 PowerShell 工具；
5. 四个 managed lifecycle Hook；
6. 发布与迁移验证。

工作闭环：

```text
understand -> plan -> red check -> smallest change -> green check -> risk-based review -> checkpoint
```

判断留在人与 Agent 的协作中；危险命令、受保护文件、staged 密钥、checkpoint 范围、迁移冲突、回滚和 active Hook 矩阵等确定性边界由脚本承担。

安装器在 staging 中渲染路径，验证完整计划，识别冲突，保存原文件，在当前会话唯一的 SteadyAgent 迁移锁下原子写入，验证最终状态，并在失败时恢复。迁移收据是恢复权威。

Runtime 不运行每轮 prompt 或工具后 Hook。SessionStart 只注入短合同和必要状态；独立审查依据实质风险，而不是文件数量。

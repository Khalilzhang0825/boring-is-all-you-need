# Boring Is All You Need 如何工作

Boring Is All You Need 在 Codex Desktop 外围组合六层能力：

1. 短 `AGENTS.md` 合同；
2. 按需加载的渐进规则；
3. 用户显式调用的 workflow skill；
4. 确定性 PowerShell 工具；
5. 三个 managed lifecycle Hook，其中 `PreToolUse` 统一为一个进程；
6. 发布与迁移验证。

工作闭环：

```text
understand -> plan -> red check -> smallest change -> green check -> risk-based review -> checkpoint
```

判断与授权留在人和 Agent 的协作中。标准 managed `PreToolUse` Hook 只审计识别到的命令与文件风险，不作拒绝；staged 密钥、checkpoint 显式范围、迁移冲突、回滚和 active Hook 矩阵等确定性写入边界仍由脚本强制执行。

已加载的 installer 会先验证规范化的 52 项源资产 manifest 摘要，对每项匹配源只读取一次，并且只把这些可信字节渲染进 staging。它随后验证完整计划、识别冲突、durable 保存原文件，并在首次目标或 Git 写入前 durable 写入、回读 `applying` 收据；之后在全机器唯一的 Boring Is All You Need 迁移锁下原子写入，验证最终状态，再将收据推进到 `applied`。当全部 managed 字节、removal 与 active Hook 值都已一致时，重复 Apply 会以零目标/config/backup/receipt/state 写入退出。普通失败会立即恢复；强制中止后，rollback 会把每个目标和 Git 状态分类为精确原态或安装后态，在写入前 durable 记录自身进入态，恢复合法混合状态，并在 rollback 强杀后续跑或补偿。精确目标态覆盖 managed 文件字节内容/存在性及记录的 Git 值/config 字节，不覆盖 ACL、owner、属性、时间戳或 alternate data streams。任何第三种状态都会在写入前拒绝，`rollback_incomplete` 则是保留证据并转人工对账的边界。installer 自身的信任根仍是发布渠道或用户单独核验的 installer 摘要。迁移收据只绑定恢复计划和字节完整性证据，其哈希不是身份认证。Apply 与 rollback 使用启动它们的普通或管理员 token，不主动请求 UAC、修改 ACL 或接管 owner；同用户 guardrail 仍是协作式防误操作机制，而非对抗性 sandbox。

Runtime 不运行每轮 prompt 或工具后 Hook。SessionStart 只在需要时注入动态 Caveman 状态、lessons 标题、到期复查提醒和任务状态；静态合同只保留在 `AGENTS.md`。独立审查依据实质风险，而不是文件数量。

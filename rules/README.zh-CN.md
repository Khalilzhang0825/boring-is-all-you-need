# SteadyAgent 规则库

这些文件是渐进加载的公开规则。常驻模板保持短，只在任务需要时加载对应规则。

## 规则索引

- `workflow-routing.md`：选择工作模式、暴露冲突、控制范围。
- `verification.md`：选择能证明真实行为的验证，而不是只验证自信语气。
- `review-gates.md`：判断什么时候必须独立审查和评分。
- `context-management.md`：处理中断、压缩和长任务状态恢复。
- `safety-boundaries.md`：处理危险操作、secrets、安装、push、发布和宿主差异。

## 使用方式

1. 从 `templates/codex/AGENTS.md` 开始。
2. 模板需要和 `rules/` 目录一起复制；如果只复制单文件，必须同步调整规则路径。
3. 任务需要时只加载一个相关规则文件。
4. 项目私有细节放在项目自己的仓库，不放进公开模板。
5. 只有能对应重复失败模式的规则才值得加入。

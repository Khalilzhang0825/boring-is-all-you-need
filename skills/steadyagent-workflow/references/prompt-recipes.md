# Prompt Recipes

Use this reference when a task needs a reusable Chinese prompt template.

## HTML Exploration

```text
请为这个问题生成一个单文件 HTML 工件。把 4-6 个可行方案并排展示，每个方案包含：适用条件、代价、风险、推荐指数、关键流程图。最后给一个对比矩阵和推荐路径。HTML 必须便于阅读、比较和后续验证。
```

## Subagent Research

```text
请使用 read-only 子代理研究这个模块，不要修改文件。目标是找出入口文件、核心数据流、测试方式、已知风险。返回 10 条以内的综合结论，并列出建议主会话接下来读取的 3 个文件。
```

## Independent Review

```text
请派一个不继承当前讨论假设的子代理审查这次修改。重点检查边界条件、权限、并发、缓存、数据迁移、测试缺口和是否过度实现。按 P0-P3 排序，只报告可操作问题。
```

## AGENTS.md Iteration

```text
请阅读当前 AGENTS.md，指出哪些规则值得常驻加载，哪些应该移到 skill、docs 或 references。每条新增或保留规则必须对应真实失败模式，最后给出精简后的版本和取舍说明。
```

## Skill Creation

```text
请使用 skill-creator 规范设计一个新 skill。先明确触发场景、用户示例、skill 名称、SKILL.md 主体边界、references 拆分方式和验证标准。不要先创建文件，先给结构方案。
```

## GitHub Release Check

```text
请在发布前检查这个仓库：文件结构、README 可读性、skill frontmatter、references 链接、未替换模板词、Git 状态、验证记录和发布风险。只报告阻塞项和建议修复项。
```

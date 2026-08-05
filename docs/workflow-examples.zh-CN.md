# 工作流示例

这些示例说明安装 SteadyAgent 后应该怎么向 agent 下任务。你不需要点名每个内部文件，只需要说明目标，并要求 agent 使用 SteadyAgent 的过程。

## 通用起手提示词

如果不确定宿主是否自动加载了指令，可以先发这一段：

```text
Use the SteadyAgent workflow for this repository. Inspect first, keep the change scoped, run the smallest relevant validation, and end with changed files, verification, remaining risks, and Git status.
```

预期行为：

- agent 先读相关文件，再修改。
- 复杂或高风险任务先给短计划。
- 不混入无关重构。
- 运行最小相关验证。
- 用证据报告结果，而不是只说已经完成。

## 示例 1：修 bug

提示词：

```text
The login test is failing. Use SteadyAgent to investigate, find the smallest fix, run the relevant test, and checkpoint only after the diff is reviewed.
```

预期 agent 流程：

1. 查看失败测试和相关代码。
2. 复现失败，或找到可观察证据。
3. 修改前说明怀疑原因。
4. 只 patch 相关文件。
5. 运行目标测试或最接近的可用检查。
6. 报告改动文件、验证结果、风险和 Git 状态。

好的结束报告类似：

```text
Changed: src/auth/session.ts and tests/auth/session.test.ts.
Verified: npm test -- tests/auth/session.test.ts passed.
Risk: only the remembered-session path was covered; full auth regression suite was not run.
Git: clean after checkpoint.
```

## 示例 2：做 feature

提示词：

```text
Add a dark-mode toggle to the settings page. Use SteadyAgent: inspect existing UI patterns, give me a short plan, implement the smallest complete version, run the relevant checks, and report residual risk.
```

预期 agent 流程：

1. 查看已有 settings components、style conventions 和 tests。
2. 用短计划定义行为。
3. 复用已有 UI 模式，不另起一套设计系统。
4. 如果代码库已有匹配测试模式，补聚焦测试。
5. 根据项目运行 lint、type check、unit test 或浏览器验证。
6. maintainer 明确要求、任务属于高风险，或 agent 识别并说明了具体实质风险时，checkpoint 前触发独立 review；文件数量本身不是触发条件。

## 示例 3：先 review 再修改

提示词：

```text
Review this branch before we change anything. Use SteadyAgent review style: findings first, order by severity, cite file and line, then list test gaps and residual risk.
```

预期 agent 流程：

1. 读取 diff 和相关上下文代码。
2. 先列具体 findings，而不是先写总结。
3. 区分 bug 和风格偏好。
4. 给出文件和行号。
5. 说明缺失测试或未验证行为。
6. 除非你明确要求修复，否则不修改文件。

## 示例 4：长任务恢复

提示词：

```text
Continue the migration from the last checkpoint. Use SteadyAgent: first read the project state file, verify Git status, summarize current progress, then continue with the next smallest step.
```

预期 agent 流程：

1. 如果存在，先读 `PROJECT_STATE.md` 或 `.agent/state.md`。
2. 运行 Git preflight。
3. 对齐状态文件和当前工作树。
4. 从文档里的下一步继续，而不是凭记忆重来。
5. 上下文交接或压缩前更新状态文件。

这类提示词适合多小时任务、发布准备、迁移，以及可能被打断的工作。

## 示例 5：发布检查

提示词：

```text
Check whether this repository is ready for a public release. Use SteadyAgent: run the release-readiness gate, inspect any failure, and do not push or tag unless I explicitly approve.
```

预期 agent 流程：

1. 运行 release gate：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1
```

2. 如果工作树有明确的进行中改动，使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\validate-release-readiness.ps1 -AllowDirty
```

3. 把失败解释成具体问题，例如缺文件、链接断裂、发布文案过时、hook 冒烟测试失败或命名残留。
4. 没有明确批准，不 publish、不 retag、不 rewrite remote history。

## 一个好的 SteadyAgent 回复应该包含什么

任务结束时，回复应该包含：

- 改动文件
- 验证命令和结果
- 未解决风险或跳过的检查
- Git 状态
- 是否还有未完成项

较大的任务还应该包含 review 结果和下一步。

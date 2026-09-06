---
name: "kikoflu-project"
description: "在 KikoFlu 中按任务选择 Flutter、移动、构建、测试、依赖或文档子智能体，使用多个只读顾问和至多一个写入者完成工作。"
metadata:
  short-description: "KikoFlu 项目子智能体的按需单写者路由。"
---

# KikoFlu 项目子智能体路由

适用于 Flutter/Dart、Android/iOS、移动端行为、构建、测试、依赖和项目文档任务。可用角色包括：
`build-engineer`、`code-reviewer`、`dependency-manager`、`documentation-engineer`、`flutter-expert`、`mobile-app-developer`、`test-automator`、`tooling-engineer`。

## 路由规则

1. 先写一句 `task_brief`，明确目标、范围、是否需要修改文件，以及是否已有更具体的领域或项目 skill 覆盖该任务。
2. 读取候选角色的配置，按职责和 `sandbox_mode` 选择最小集合；角色目录不是启动清单。
3. 只启动能回答当前问题的只读角色。每个只读角色必须有独立问题和明确产出；没有问题的角色跳过。
4. 需要修改代码或文件时，只指定一个 `writer`。选择最贴近目标文件和主执行路径的角色；其他角色只提供分析，不修改文件。
5. 若任务需要多个阶段的写入，按顺序执行：前一位 writer 完成并验证后，才把其结果交给下一位 writer。禁止并行写入者。
6. 只读角色使用共享或只读上下文（平台支持时），不要为每个只读角色单独创建写入 worktree；writer 才需要隔离的写入上下文。
7. 若更具体的领域或项目 skill 已处理目标职责，跳过全局目录中的重复角色；全局 skill 只补充它没有覆盖的跨领域问题。
8. 只读结论汇总给 writer 后再实施。若没有 writer，直接输出评审或方案，不创建修改分支。
9. 对同一任务不要同时启动 `core-development` 的重复角色；项目 skill 优先负责 KikoFlu 内部路径，全局 skill 仅补充项目侧没有覆盖的架构或协议问题。

## 主角色选择

- Flutter widget、状态、路由、渲染或插件：`flutter-expert`
- 跨屏幕移动产品流程、生命周期或发布风险：`mobile-app-developer`
- 编译、打包、CI 或工具链：`build-engineer` 或 `tooling-engineer`，二选一
- 依赖升级和兼容性：`dependency-manager`
- 自动化测试和回归覆盖：`test-automator`
- 开发/运维文档：`documentation-engineer`
- 已复现的代码风险审查：`code-reviewer`，无 writer 时直接输出评审

## 完成标准

- 已列出实际启动的角色、问题和文件范围。
- `writer` 为零或恰好一个；后续写入者必须排在 `writer_sequence` 中并等待前一阶段完成。
- 只读结论已交给 writer，或明确记录在最终决策中。
- 已记录跳过的角色及理由，避免全量启动和职责重复。
- 验证覆盖变更路径；无法运行的设备或环境检查明确标为人工后续动作。

## 输出契约（必须返回）
- `task_brief`
- `dispatch`：`read_only`、`writer`、`writer_sequence`、`skipped`
- `agents`：数组，字段 `name/focus/result/risks/next_step`
- `implementation_plan`：按顺序的执行步骤（含文件/模块建议）
- `verification`：与任务相关的构建、测试、关键交互或人工检查清单
- `dependency_risks`：新增依赖、版本锁定、升级影响
- `conflicts`：有冲突写 `issue/impact/resolution`，无冲突写 `[]`
- `handoff`：给下一位实施者的 `what / why / next`

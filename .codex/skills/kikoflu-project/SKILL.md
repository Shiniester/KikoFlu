---
name: "kikoflu-project"
description: "在 KikoFlu 中按任务选择 Flutter、移动、构建、测试、依赖或文档子智能体，使用只读顾问和按条件并行的写入者完成工作。"
metadata:
  short-description: "KikoFlu 项目子智能体的按需路由与有条件并行写入。"
---

# KikoFlu 项目子智能体路由

适用于 Flutter/Dart、Android/iOS、移动端行为、构建、测试、依赖和项目文档任务。

- 项目专属角色（`.codex/agents/`）：`flutter-expert`、`mobile-app-developer`。
- 复用全局角色（`~/.codex/agents/`，由 `core-development` 维护通用职责）：`build-engineer`、`code-reviewer`、`dependency-manager`、`documentation-engineer`、`test-automator`、`tooling-engineer`。

本 skill 为全局角色提供 KikoFlu 的任务范围、项目约束与验证要求。项目需要不同模型或职责时才增加同名项目覆盖；全局角色不可用时由主智能体处理。

## 路由规则

1. 先写一句 `task_brief`，明确目标、范围、是否需要修改文件，以及是否已有更具体的领域或项目 skill 覆盖该任务。
2. 按上述来源读取候选角色配置；存在同名项目覆盖时先核对其职责与设置。按职责和 `sandbox_mode` 选择最小集合；角色目录不是启动清单。
3. 只启动能回答当前问题的只读角色。每个只读角色必须有独立问题和明确产出；没有问题的角色跳过。
4. 需要修改代码或文件时，按目标文件和执行路径选择 writer，明确每位 writer 的文件归属。默认串行写入，满足下方“并行写入”规则时可在同一阶段启动多个 writer；只读角色保持只读。
5. 存在前后依赖的任务按阶段交接：前一阶段完成并验证后，再启动依赖其结果的下一阶段。独立任务可在同一阶段并行；主智能体负责集成与最终验收。
6. 只读角色使用共享或只读上下文（平台支持时）；writer 可在文件归属明确的共享工作区工作，需要隔离时才创建写入 worktree。
7. 更具体的领域 skill 提供实施要求；构建、评审、测试、依赖、工具和文档职责复用全局角色，避免为同一任务重复派发。
8. 影响实现的只读结论先交给相关 writer。若没有 writer，直接输出评审或方案，不创建修改分支。
9. 主智能体统一协调项目角色和全局角色。本 skill 负责 KikoFlu 内部任务的分工与验收，`core-development` 提供通用角色选择和并行条件，也可补充架构或协议专家；同一职责只派发一次。

## 并行写入

准备并行写入时，读取全局 `core-development` skill 的“并行写入”部分，遵循其全部条件与协调流程：文件归属独立、契约已确定、可分别验收、执行互不干扰、并行有收益且允许。找不到该 skill 时使用串行写入。

KikoFlu 中另外明确以下归属和执行方式：

- `pubspec.yaml`、`pubspec.lock`、共享路由与本地化配置，以及生成文件，由指定负责人统一修改或生成。Flutter 与移动端角色按文件边界分工；同一文件的不同区域仍归一位 writer。
- 代码实现与测试可以在接口和预期行为确定后分属不同 writer；测试任务若依赖尚未确定的实现决定，先完成这些决定再派发。
- Flutter/Dart 代码生成、构建和设备测试若共享输出目录、缓存或设备，则隔离资源或串行执行。主智能体统一安排跨范围集成及共享工作区的 Git 操作。

派发时列出文件或目录边界，说明其他智能体正在协作，要求保留并适配他人改动。writer 需要扩展到他人范围或发现接口依赖未定时，暂停相关写入并交由主智能体重新分工。

## 主角色选择

- Flutter widget、状态、路由、渲染或插件：`flutter-expert`
- 跨屏幕移动产品流程、生命周期或发布风险：`mobile-app-developer`
- 编译、打包、构建图或 CI 故障：全局 `build-engineer`
- 开发脚本、内部工具或自动化胶水：全局 `tooling-engineer`；与构建任务按文件归属分工
- 依赖升级和兼容性：全局 `dependency-manager`
- 自动化测试和回归覆盖：全局 `test-automator`
- 开发/运维文档：全局 `documentation-engineer`
- 正确性、可维护性与变更风险审查：全局只读 `code-reviewer`，评审结果交由目标文件的 writer 处理

## 完成标准

- 已列出实际启动的角色、问题和文件范围。
- 已明确写入阶段和每位 writer 的文件归属；同阶段并行满足全部条件，后续阶段等待其依赖的结果完成并验证。
- 只读结论已交给 writer，或明确记录在最终决策中。
- 已记录跳过的角色及理由，避免全量启动和职责重复。
- 每位 writer 返回实际改动文件、验证结果与集成注意事项；主智能体完成组合后的验证，解决文件归属或接口冲突后接受整体交付。
- 验证覆盖变更路径；无法运行的设备或环境检查明确标为人工后续动作。

## 输出契约（必须返回）

- `task_brief`
- `dispatch`：`read_only`、`write_stages`、`skipped`；`write_stages` 按执行顺序列出阶段，每阶段的 `writers` 列出角色及负责文件，同阶段可并行，无写入时为 `[]`
- `agents`：数组，字段 `name/focus/result/risks/next_step`
- `implementation_plan`：执行步骤、阶段依赖和并行理由（含文件/模块建议）
- `verification`：与任务相关的构建、测试、关键交互或人工检查清单
- `dependency_risks`：新增依赖、版本锁定、升级影响
- `conflicts`：有冲突写 `issue/impact/resolution`，无冲突写 `[]`
- `handoff`：给下一位实施者的 `what / why / next`

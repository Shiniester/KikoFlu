# PR #4 检查修复验证

2026-10-05，Windows，Flutter 3.44.7 / Dart 3.12.2。
对应 [Build test 运行](https://github.com/Shiniester/KikoFlu/actions/runs/37296067270)。

## Linux 后台测试初始化

Linux 的两份后台提取测试在断言通过后，`flutter_tester` 收尾时发生原生
类型检查崩溃。两份测试现在在入口初始化 `TestWidgetsFlutterBinding`。

[Ubuntu 验证](https://github.com/Shiniester/KikoFlu/actions/runs/37334793165/job/111846719580)：
两份测试连续运行 20 次，每次 6 项通过；完整测试 1342 项通过、7 项跳过，
静态分析通过。Windows 的同一组 6 项测试通过。

- `task_brief`：修复 PR #4 的 Linux 测试进程收尾崩溃。
- `dispatch.read_only`：`entrypoint_crash_map` 定位调用与资源生命周期；
  `isolate_test_shutdown_advice` 核对 isolate 退出语义；
  `native_vm_crash_expert` 解析原生故障指令。
- `dispatch.write_stages`：主智能体串行修改两份测试的绑定初始化并清理诊断。
- `dispatch.skipped`：无需业务实现、依赖或设备构建改动，不增加对应 writer。
- `implementation_plan`：以 Linux 失败日志定位测试环境，连续复现检查通过后
  清理诊断，再验证正常工作流。
- `verification`：以上 Ubuntu、Windows 测试与静态分析。
- `dependency_risks`：无新增依赖，继续使用 Flutter 3.44.7。
- `conflicts`：[]。
- `handoff`：两份测试显式初始化绑定；正常 CI 保留完整测试及原有失败判定。

`agents`：

| name | focus | result | risks | next_step |
| --- | --- | --- | --- | --- |
| entrypoint_crash_map | 后台扫描与提取调用 | 定位两份失败测试的公共提取路径 | Windows 不能代替 Linux 崩溃检查 | 已验收 |
| isolate_test_shutdown_advice | 退出和测试环境语义 | 核对退出通知与 native 清理顺序 | 原生故障需 Ubuntu 验证 | 已验收 |
| native_vm_crash_expert | 原生堆栈与指令 | 定位 VM 类型检查读取无效对象信息 | 未确定 VM 内部损坏的具体来源 | 初始化修复已通过 Ubuntu 连续验证 |

## 修复结果

- Android APK 已在原 CI 中完成构建，兼容性检查使用的证书预期与签名产物不一致。
  测试工作流现与两个发布工作流使用同一证书预期，遵循
  [签名证书更新](https://github.com/Shiniester/KikoFlu/commit/c2a3adc4fdeb93a57d418383c1192f3da26eae93)。
  保留实际 APK 签名验证，并增加三个工作流的证书预期一致性检查。
- 播放器、歌词、播放列表和作品卡片测试在读取设置前初始化模拟存储。
  卡片比例、浏览页控制器释放和封面连续显示断言对应当前实现；滚动位置恢复
  与失效分页回调继续受回归覆盖。漫画收藏错误提示使用统一提示组件。
- 四张整页播放器基准对应当前界面。完整页与转场截图共用既有 Linux 0.003
  栅格差异容差；Windows 保持严格匹配。转场基准和截图采样时序保持原值。

## 自动验证

- `flutter test --no-pub --exclude-tags external --reporter expanded`：1342 项通过，
  7 项跳过，零失败。
- 模拟存储相关四个测试文件：19 项通过。
- 浏览动效与播放器代码约束：11 项通过。
- 播放器整页及转场截图：7 项通过，Windows 严格匹配。
- `python scripts/test_android_signing.py`：通过。
- `flutter analyze --no-pub --fatal-infos lib test integration_test test_driver third_party tool`：
  全部源码、测试和工具目录无问题。
- `git diff --check`：通过。

## 限制

本机未运行 Ubuntu 环境和 GitHub 的签名构建；签名产物及 Linux 截图结果需由
更新后的 GitHub CI 确认。本机默认全目录分析会包含 ignored `build/` 内的旧诊断
脚本，这些脚本不属于 GitHub checkout。

## 任务交接

- `task_brief`：修复 PR #4 的 Analyze and Test 与 Android Build 失败。
- `dispatch.read_only`：`shared_tab_render_review / code-reviewer` 检查签名依据、
  回归断言及稳定截图状态。
- `dispatch.write_stages`：第一阶段按独立文件分配签名工作流与检查脚本、四个
  存储 fixture；主智能体负责浏览测试和漫画提示。第二阶段由 Flutter writer
  负责播放器代码约束、两个截图测试、共享 comparator 及四张基准。Flutter
  验证串行使用 SDK；第三阶段由主智能体执行组合验证与记录。
- `dispatch.skipped`：无依赖升级、接口或设备动效变更，不增加相应角色。
- `implementation_plan`：从失败日志确定签名与测试原因，分别修复并验证，再
  对组合结果执行完整 CI 测试与静态分析。文件归属独立；截图更新依赖稳定帧
  与界面历史核对。
- `verification`：以上自动验证，及更新后的 GitHub CI。
- `dependency_risks`：无新增依赖，使用 CI 锁定的 Flutter 3.44.7。
- `conflicts`：[]。
- `handoff`：修复保留真实签名检查与行为回归；下一步由 GitHub CI 验证 Ubuntu
  截图和签名 APK。

`agents`：

| name | focus | result | risks | next_step |
| --- | --- | --- | --- | --- |
| android_ci_signing / build-engineer | 签名工作流与一致性脚本 | 对齐已采用的证书并保留签名验证 | GitHub 签名构建需重跑 | Android Build |
| ci_storage_fixtures / test-automator | 四个模拟存储测试文件 | 初始化 fixture 并校准现有卡片比例 | 无新增运行时行为 | 已验收 |
| cold_tab_strategy / flutter-expert | 播放器约束与截图测试、基准 | 严格 Windows 回归通过，共用原 Linux 容差 | Linux 栅格结果需 CI 确认 | Analyze and Test |
| shared_tab_render_review / code-reviewer | 签名依据、断言与稳定截图 | 未发现需要修改的问题 | 设备构建未执行 | 已验收 |

## PR #4 合并冲突与发布审查验证（2026-10-06）

- `task_brief`：同步 `main`，解决合并阻塞并处理五条发布与 CI 审查意见。
- `implementation_plan`：核对 `gh` 与本地分支，合并 `main` 的 `c4b8407`，保留双方行为，修复发布元数据并执行相关回归。
- `dispatch.read_only`：`isolate_test_shutdown_advice` 独立检查发布 SHA、Beta 编号和排队目标。
- `dispatch.write_stages`：`cold_tab_strategy` 处理七个 Flutter 冲突文件；主智能体处理发布脚本、工作流、文档及 Git 集成。文件归属独立，SDK 验证串行执行。
- `dispatch.skipped`：无依赖升级、设备动效调整或额外诊断工作流。
- `conflicts`：`issue` 为十处文件冲突；`impact` 为 PR 无法合并；`resolution` 为保留已发布 Beta 历史去重、独立 Dart ZIP 检查、统一提示和截图比较器，并组合控制器释放、位置恢复、过期加载与减弱动态效果回归。
- `verification`：189 项相关 Flutter 测试、3 项独立 ZIP 检查通过；全部源码、测试和工具目录静态分析无问题；发布规划、版本编号、签名一致性、6 项上传恢复检查、工作流 YAML 与 Bash 语法检查通过。旧目标回归能够在原 planner 中复现重新发布，并在修复后跳过。
- `dependency_risks`：无新增依赖；本机验证使用 Flutter 3.44.7，GitHub Linux 测试及签名 APK 构建仍由 CI 执行。
- `handoff`：`what` 为冲突解决和发布修复；`why` 为避免重复发布、错用 SHA 和 Beta 升级编号回退；`next` 为提交到 PR 分支，由 GitHub 重新计算合并状态和运行 CI。

审查意见结果：

1. 保留 `queue: max`；当前 [GitHub 官方语法](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency)支持该配置及 100 个等待运行。
2. 合并 `main` 的已发布 Beta 历史排除逻辑，并跳过已包含在较新 Beta 中的旧排队目标。
3. Android-only 工作流接受并解析 `commit_sha`，构建和发布标签共用解析后的 SHA。
4. 20 次诊断循环已在 `e965c00` 移除；正常 CI 保持单次测试套件执行。
5. 手动与自动 Beta 按版本共用构建编号，并核验实际 APK 的 universal 编号和 arm64 偏移。

| name | focus | result | risks | next_step |
| --- | --- | --- | --- | --- |
| cold_tab_strategy | Flutter 合并冲突 | 七处冲突按双方有效行为解决，组合回归通过 | Linux 截图需 CI 验证 | 已验收 |
| isolate_test_shutdown_advice | 发布兼容性只读审查 | 发现旧排队目标重新发布边界，真实 Git 回归覆盖并修复 | 签名 APK 构建需 CI 验证 | 已验收 |

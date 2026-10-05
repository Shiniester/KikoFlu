# PR #4 检查修复验证

2026-10-05，Windows，Flutter 3.44.7 / Dart 3.12.2。
对应 [Build test 运行](https://github.com/Shiniester/KikoFlu/actions/runs/37296067270)。

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

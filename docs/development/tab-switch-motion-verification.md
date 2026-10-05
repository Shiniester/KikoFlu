# 首次标签切换验证

2026-10-05，Flutter 3.44.7 / Dart 3.12.2。

音声页和漫画页点击上方标签时，`TabPageWarmup` 在首帧临时扩大
`PageView` 的布局缓存范围，让目标页先完成首次创建和布局。帧结束后恢复
零缓存，已创建的目标页由现有 `LazyTabPage` 保留。切换继续使用
300ms / `Curves.ease`，未访问的中间标签保持未加载。

## 自动验证

```powershell
flutter test --no-pub test/audio_screen_test.dart
flutter test --no-pub test/comic_widgets_test.dart --name "comic tab|comic reduced motion|first comic History|distant comic tab"
flutter analyze --no-pub lib/src/widgets/tab_page_motion.dart lib/src/screens/audio_screen.dart lib/src/comics/ui/comic_screen.dart test/audio_screen_test.dart test/comic_widgets_test.dart
```

- 音声页 40 项测试通过；漫画标签相关 5 项测试通过。
- 两个首次历史标签回归记录首次数据源创建或读取时的页位置，均为 0；
  动画继续移动时，缓存范围已恢复为 0，隐式滚动已关闭。
- 现有回归覆盖缓动和时长、快速改选、滑动打断、减少动态效果、可选标签
  调整、已访问页面及滚动位置保留、远距离点击不加载中间标签。
- 五个修改的 Dart 文件静态分析无问题。
- Flutter 顾问独立检查请求失效、滑动取消、标签重排和卸载回调，未发现问题。

## 限制

当前未连接 Android 设备，尚未测量正式版或 Profile 帧耗时。首帧扩大布局
范围会让其中已访问的页面参与一次布局；真实流畅度需在同设备、同场景的
隔离 Profile 构建中比较。测试证明初始化时序和交互行为，不代表真机性能
已经验收。设备测试流程见 [Android 真机回归](android-device-testing.md)。

## 任务交接

- `task_brief`：优化 Android 首次上方标签切换，保留动画、页面状态和数据行为。
- `dispatch.read_only`：`code-mapper` 定位入口和首次加载路径；
  `flutter-expert` 检查 Flutter 缓存机制及实施方案。
- `dispatch.write_stages`：主智能体串行负责共享组件、音声和漫画调用处、
  两个回归测试及本文；文件归属无重叠。
- `dispatch.skipped`：无依赖、构建配置或数据接口变更，不增加相关 writer。
- `implementation_plan`：先锁定首次创建时序，再修改共享机制，最后运行相关
  交互回归与静态分析；阶段串行，不存在并行写入。
- `verification`：以上 45 项测试及五个文件静态分析。
- `dependency_risks`：无新增依赖；使用项目锁定的 Flutter 3.44.7 缓存接口。
- `conflicts`：[]。
- `handoff`：代码与自动回归已就绪；下一步为隔离 Android Profile 帧耗时比较。

`agents`：

| name | focus | result | risks | next_step |
| --- | --- | --- | --- | --- |
| tab_flow_map / code-mapper | 入口、首次加载与测试路径 | 确认零缓存导致目标页延后创建 | 真机帧耗时未测量 | 路径已交给主智能体 |
| cold_tab_strategy / flutter-expert | 缓存方案与独立验收 | 首帧临时缓存可保留现有交互；取消和生命周期检查无发现 | 已访问中间页的一次布局成本 | 隔离 Profile 验证 |

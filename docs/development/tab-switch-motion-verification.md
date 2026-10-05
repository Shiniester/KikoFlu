# 首次标签切换验证

2026-10-05，Flutter 3.44.7 / Dart 3.12.2。

音声页和漫画页点击上方标签时，`TabPageWarmup` 在首帧临时扩大
`PageView` 的布局缓存范围，让目标页框架和数据源提前初始化。帧结束后恢复
零缓存，已创建的目标页由现有 `LazyTabPage` 保留。切换继续使用
300ms / `Curves.ease`，未访问的中间标签保持未加载。

共享的 `DeferredTabContent` 用于音声集合组件和漫画 `ComicGrid`。首次进入
时显示静态加载占位，所属标签停稳且成为当前页后再创建卡片、布局列表和
发起封面请求。数据查询继续提前进行。被取消的首次目标页保持等待；已展示
的内容保持挂载，再次进入保留原页面状态和滚动位置。

## 自动验证

```powershell
flutter test --no-pub test/audio_screen_test.dart test/tab_collection_motion_test.dart
flutter test --no-pub test/comic_widgets_test.dart --name "comic tab|comic reduced motion|first comic History|distant comic tab"
flutter test --no-pub test/virtualized_sliver_collection_test.dart
flutter analyze --no-pub lib/src/widgets/tab_page_motion.dart lib/src/widgets/virtualized_sliver_collection.dart lib/src/comics/ui/comic_widgets.dart test/audio_screen_test.dart test/comic_widgets_test.dart test/tab_collection_motion_test.dart
```

- 音声页 42 项、共享集合动效 3 项、漫画标签 5 项、集合行为 16 项测试通过，
  共 66 项。
- 两个首次历史标签回归记录首次数据源创建或读取时的页位置，均为 0；
  动画继续移动时，缓存范围已恢复为 0，隐式滚动已关闭。
- 现有回归覆盖缓动和时长、快速改选、滑动打断、减少动态效果、可选标签
  调整、已访问页面及滚动位置保留、远距离点击不加载中间标签。
- 列表、网格和瀑布流首次切换的 100ms 采样点均未构建卡片或发起预取，
  停稳后正常展示和预取；再次切换保留同一内容元素。
- 音声快速改选后，被取消的目标页不构建内容，减少动态效果下重新进入可
  正常展示。漫画历史在首帧读取数据，动画期间不创建封面。
- 集合独立使用时的分页、加载更多、预取、虚拟化和条目保留回归通过。
- 六个修改的 Dart 文件静态分析无问题。
- 独立评审检查当前页判断、请求取消、标签重排、监听解绑和集合检查时序，
  未发现需要修改的问题。

## 限制

当前未连接 Android 设备，尚未测量正式版或 Profile 帧耗时。首次封面加载
在切换停稳后启动；已访问页面仍可能在临时布局缓存中参与一次布局。真实
流畅度需在同设备、同场景的隔离 Profile 构建中比较。测试证明初始化、卡片
构建时序和交互行为，不代表真机性能已经验收。设备测试流程见
[Android 真机回归](android-device-testing.md)。

## 任务交接

- `task_brief`：统一优化音声与漫画上方标签首次内容展示，保留动画、页面状态
  和提前进行的数据查询。
- `dispatch.read_only`：`flutter-expert` 检查共享内容边界及实现风险；
  `code-reviewer` 独立验收生命周期和取消行为。
- `dispatch.write_stages`：主智能体串行负责共享动效和集合组件、漫画集合、
  三个相关测试文件及本文；文件归属无重叠。
- `dispatch.skipped`：无依赖、构建配置或数据接口变更，不增加相关 writer。
- `implementation_plan`：先锁定首次卡片构建时序，再修改共享机制，最后运行相关
  交互回归与静态分析；阶段串行，不存在并行写入。
- `verification`：以上 66 项测试及六个文件静态分析。
- `dependency_risks`：无新增依赖；使用项目锁定的 Flutter 3.44.7 缓存接口。
- `conflicts`：[]。
- `handoff`：代码与自动回归已就绪；下一步为隔离 Android Profile 帧耗时比较。

`agents`：

| name | focus | result | risks | next_step |
| --- | --- | --- | --- | --- |
| cold_tab_strategy / flutter-expert | 共享内容边界与取消风险 | 确认音声与漫画集合共用展示等待机制；取消目标页需保持等待 | 首次封面加载延后 | 隔离 Profile 验证 |
| shared_tab_render_review / code-reviewer | 生命周期、当前页判断与集合检查 | 未发现需要修改的缺陷 | 真机帧耗时未测量 | 代码行为已验收 |

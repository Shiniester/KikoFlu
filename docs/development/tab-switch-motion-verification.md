# 标签与底部导航首次切换验证

2026-10-05，Flutter 3.44.7 / Dart 3.12.2。

音声页和漫画页的上方标签、底部 Dock 的音声／漫画／设置导航共同使用
`TabPageWarmup`，在首帧临时扩大
`PageView` 的布局缓存范围，让目标页框架和数据源提前初始化。帧结束后恢复
零缓存，已创建的目标页由现有 `LazyTabPage` 保留。切换继续使用
300ms / `Curves.ease`，未访问的中间标签保持未加载。

共享的 `DeferredTabContent` 用于音声集合组件、漫画 `ComicGrid` 和设置页
正文。首次进入时显示静态加载占位，所有所属分页均停稳且目标页成为当前页
后再创建卡片、布局列表和发起封面请求。嵌套标签通过所属页链同时等待内部
标签与外层应用导航。页面框架、设置缓存查询及漫画数据查询继续提前初始化。
被取消的首次目标页保持等待；已展示
的内容保持挂载，再次进入保留原页面状态和滚动位置。

## 自动验证

```powershell
flutter test --no-pub test/audio_screen_test.dart test/tab_collection_motion_test.dart test/virtualized_sliver_collection_test.dart
flutter test --no-pub test/comic_widgets_test.dart --name "comic tab|comic reduced motion|first comic History|distant comic tab|first main comic switch|main navigation cancels a pending comic page turn"
flutter analyze --no-pub lib/src/screens/main_screen.dart lib/src/screens/settings_screen.dart lib/src/widgets/tab_page_motion.dart test/audio_screen_test.dart test/comic_widgets_test.dart
```

- 音声页与应用导航 42 项、共享集合动效 3 项、漫画标签与应用导航 7 项、
  集合行为 16 项测试通过，共 68 项。
- 两个首次历史标签回归记录首次数据源创建或读取时的页位置，均为 0；
  动画继续移动时，缓存范围已恢复为 0，隐式滚动已关闭。
- 现有回归覆盖缓动和时长、快速改选、滑动打断、减少动态效果、可选标签
  调整、已访问页面及滚动位置保留、远距离点击不加载中间标签。
- 列表、网格和瀑布流首次切换的 100ms 采样点均未构建卡片或发起预取，
  停稳后正常展示和预取；再次切换保留同一内容元素。
- 音声快速改选后，被取消的目标页不构建内容，减少动态效果下重新进入可
  正常展示。漫画历史在首帧读取数据，动画期间不创建封面。
- 底部首次切换到漫画时，外层页位置为 0 即已查询漫画数据；100ms 时内部
  主页仍无封面组件或图片请求。取消后保持等待，重新进入停稳后正常展示；
  再次切换保留漫画页状态，动画期间直接显示已展示的内容。
- 设置页在横竖屏首次切换的 100ms 时保留页面框架，正文卡片等待停稳；
  减少动态效果时直接展示，再次进入保留页面状态与卡片。
- 远距离切换至设置不会初始化中间漫画页；被取消的设置正文保持未构建。
- 集合独立使用时的分页、加载更多、预取、虚拟化和条目保留回归通过。
- 本次五个修改的 Dart 文件静态分析无问题。
- 独立评审检查嵌套当前页判断、请求取消、监听解绑、Hero 和漫画活跃状态，
  未发现需要修改的问题。

## 限制

当前未连接 Android 设备，尚未测量正式版或 Profile 帧耗时。首次封面加载
在切换停稳后启动；已访问页面仍可能在临时布局缓存中参与一次布局。真实
流畅度需在同设备、同场景的隔离 Profile 构建中比较。测试证明初始化、卡片
构建时序和交互行为，不代表真机性能已经验收。设备测试流程见
[Android 真机回归](android-device-testing.md)。

## 任务交接

- `task_brief`：底部 Dock 首次切换复用上方标签的统一机制，保留动画、页面
  状态和提前进行的数据查询。
- `dispatch.read_only`：`flutter-expert` 检查整屏延后与嵌套内容等待的取舍；
  `code-reviewer` 独立验收嵌套监听、取消、Hero 和漫画活跃状态。
- `dispatch.write_stages`：主智能体串行负责 `MainScreen`、`SettingsScreen`、
  共享动效、音声与漫画两个测试文件及本文；文件归属无重叠。
- `dispatch.skipped`：无依赖、构建配置或数据接口变更，不增加相关 writer。
- `implementation_plan`：先锁定底部首次切换的正文构建时序，再复用共享机制并
  连接嵌套所属页，最后运行相关交互回归与静态分析；阶段串行。
- `verification`：以上 68 项测试及五个文件静态分析。
- `dependency_risks`：无新增依赖；使用项目锁定的 Flutter 3.44.7 缓存接口。
- `conflicts`：[]。
- `handoff`：代码与自动回归已就绪；下一步为隔离 Android Profile 帧耗时比较。

`agents`：

| name | focus | result | risks | next_step |
| --- | --- | --- | --- | --- |
| cold_tab_strategy / flutter-expert | 嵌套等待与数据查询时序 | 保留屏幕提前初始化，串联所属页并仅延后设置正文布局 | 首次封面加载延后 | 隔离 Profile 验证 |
| shared_tab_render_review / code-reviewer | 嵌套监听、取消、Hero 与活跃状态 | 未发现需要修改的缺陷 | 真机帧耗时未测量 | 代码行为已验收 |

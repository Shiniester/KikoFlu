# Android 视频导航性能调整

视频详情页在路由稳定后才初始化，确认离页时提前暂停播放。
下载页在一次构建中复用同一份任务列表。
侧栏切换还存在抽屉动画与页面工作重叠的路径。
以下结论来自代码核查，尚不能认定为实际卡顿根因。

## 已确认范围

- 平台为 Android，通过代码和自动回归验证。
- 场景为视频详情页进出，以及视频侧栏入口切换。
- 侧栏入口包括目录、视频源收藏、视频观看历史和视频下载。
- 保留当前外观、动画效果和操作行为。
- 本轮实施详情初始化、退场处理和下载列表读取调整。

术语沿用 [CONTEXT.md](../../CONTEXT.md)。
播放规则沿用 [ADR 0005](../adr/0005-native-video-and-source-account.md)。

## 1. 详情初始化等待路由稳定

[VideoDetailsScreen](../../lib/src/videos/ui/video_details_screen.dart)
调整前通过首帧回调启动初始化。
初始化恢复本机资料，或请求在线详情。
结果原来只检查页面是否仍挂载，以及请求代次是否匹配。

[详情内容](../../lib/src/videos/ui/video_details_screen.dart)
在结果到达后挂载 `VideoPlaybackPanel`。
[播放面板](../../lib/src/videos/ui/video_playback_panel.dart)
随即创建播放会话并打开媒体，初始状态为暂停。
调整前，本机或在线结果返回较快时，这些工作会与入场动画重叠。
首帧回调并不表示转场已经结束。

视频详情页复用
[WorkDetailRouteReadiness](../../lib/src/widgets/work_detail_route_readiness.dart)。
该组件检查当前路由、主次动画和返回手势。
`waitForIdle()` 还会等待最后一个移动帧绘制完成。
视频详情在该时机启动初始化。
异步步骤结束后再次等待路由就绪，并检查请求代次。
覆盖路由或返回手势期间，详情结果会等待页面再次稳定。
路由已退出时，不再发布结果或挂载播放器。
账号变化和访问验证后的重试也遵守同一约束。

代价是详情加载与播放器初始化开始得更晚。
页面转场和现有加载占位可以保持原样。
用户已确认这项取舍。
音声详情已有同类约定，见
[ADR 0001](../adr/0001-work-detail-bottom-dock-handoff.md)。

## 2. 确认离页时提前暂停播放器

[播放面板的路由监听](../../lib/src/videos/ui/video_playback_panel.dart)
原来只订阅 `secondaryAnimation`。
该监听处理页面被其他路由覆盖的情况。
详情路由自身开始返回时，主动画会反向运行。
原来没有为这条路径注册对应的暂停处理。

[最终清理](../../lib/src/videos/ui/video_playback_panel.dart)
会暂停、保存进度，并在等待加载操作后释放会话。
该清理从组件销毁时才开始。
调整前，已经开始的播放或加载可能持续到退场动画结束。
退场期间返回的详情结果也可能挂载新的播放面板。

播放面板现在观察详情路由的 `popped` 信号。
确认离页后立即开始暂停和进度保存。
该信号不会因取消返回手势而触发。
全屏路由的进出也不会触发详情路由的离页处理。
迟到详情结果由路由就绪判断拦截。
播放器最终释放仍留在组件清理阶段。
提前释放画面资源可能让退场画面变黑。
返回手势取消、全屏切换和续播进度保留现有语义。

## 3. 侧栏关闭与后续动作会同时开始

[LibraryDrawerTile](../../lib/src/widgets/library_page_scaffold.dart)
先调用 `Navigator.pop()`，随后立即执行入口回调。

- 在线目录、视频源收藏和视频观看历史调用
  [_loadUrl](../../lib/src/videos/ui/video_screen.dart)。
  该方法立即更新加载状态，然后请求页面。
  等待期间保留旧列表，结果到达后替换内容。
- [视频下载入口](../../lib/src/videos/ui/video_screen.dart)
  通过 `pushBottomDockRoute` 打开独立的下载页。
  [路由帮助函数](../../lib/src/widgets/app_bottom_dock_transition.dart)
  可能等待一帧，但不等待抽屉关闭动画结束。

因此，抽屉尚在收起时，页面重建或下载页入场可能已经开始。
这是与反馈场景对应的代码路径，实际耗时仍不确定。

若延后入口动作，需要先确定可靠的抽屉动画结束信号。
仓库锁定 Flutter 3.44.7。
该 SDK 的 `DrawerControllerState.close()` 在启动关闭动画后，
立即调用 `drawerCallback(false)`。
源码位置为 SDK 的 `packages/flutter/lib/src/material/drawer.dart:630`。
`onDrawerChanged(false)` 不能单独作为动画完成信号。
固定延时也无法反映手势和动画的实际状态。
本次尚未核验到可直接复用的完成机制。
这项候选需要先补足设计，再修改共享侧栏组件。

快速连续选择目录时，还存在过期请求继续执行的路径。
`_request` 只阻止旧结果覆盖新页面。
客户端的会话取消令牌不随每次目录选择更新。
这属于后续候选，不能把网络等待本身认定为界面卡顿。

## 4. 下载页复用单次读取的任务列表

[下载服务的 tasks getter](../../lib/src/videos/video_downloads.dart)
每次返回新建的不可修改列表。
下载页监听整个下载服务。
进度通知会触发页面重建。

调整前，已经就绪且列表非空时，一次构建会读取 `tasks` 3 次：

1. [检查列表是否为空](../../lib/src/videos/ui/video_downloads_screen.dart)。
2. [读取任务总数](../../lib/src/videos/ui/video_downloads_screen.dart)。
3. [截取当前分页](../../lib/src/videos/ui/video_downloads_screen.dart)。

下载页现在只读取一次，并将列表传入分页构建。
同一次非空列表构建的完整列表复制从 3 次减少到 1 次。
这项调整不增加跨帧缓存，也不改变通知规则。
下载页本身已有分页和虚拟列表，不能据此认为所有任务卡片都会同时渲染。
这项改动的范围小，但没有证据表明收益高于详情页时机调整。

## 回归覆盖

1. 调整详情初始化时机。
   用共享详情路由推入页面，断言进场期间没有详情请求和会话创建。
   转场及最终绘制完成后，断言初始化只启动一次。
2. 补齐退场处理。
   断言路由退出完成前已暂停播放。
   退场时完成延迟详情请求，断言不会新建播放器。
   同时检查返回手势取消、全屏、续播和音声独立播放。
   挂起清晰度切换后返回，加载完成也不能恢复播放。
   退场完成前保留画面，完成后释放播放会话。
3. 合并下载页单次构建中的任务读取。
   核对分页、删除后的页码和进度更新保持原有结果。

侧栏调度属于后续范围。
先补充动画中间帧测试，再确定调度方式。
测试需要覆盖原页替换、下载路由和底部播放条。
快速切换的乱序结果不能覆盖当前选择。

详情时机测试复用
[现有播放页替身](../../test/videos/video_playback_test.dart)
的请求与会话计数。
路由等待语义可参考
[现有时机测试](../../test/work_detail_route_readiness_test.dart)。
侧栏原页替换已有
[视频页测试](../../test/videos/video_screen_test.dart)。

## 本次验证与限制

2026-10-26 完成以下检查：

| 检查 | 结果 |
| --- | --- |
| 视频模块、路由就绪与底部播放条组合回归 | 227 项通过，1 项跳过 |
| 挂起清晰度加载后离页的补充回归 | 1 项通过 |
| 全项目静态检查 | 通过，无诊断 |
| 独立代码复核 | 未发现必修缺陷；建议补充的清晰度竞态回归已通过 |

```powershell
flutter test --no-pub test/videos test/work_detail_route_readiness_test.dart test/app_bottom_dock_transition_test.dart --reporter expanded
flutter test --no-pub test/videos/video_playback_test.dart --plain-name "detail pop during pending quality load" --reporter expanded
flutter analyze --no-pub --fatal-infos
```

跳过项为真实元数据接口测试。
该项要求启用 `KIKOFLU_LIVE_MISSAV_METADATA`。
本轮新增 4 项路由时序回归，验证代码执行顺序。
返回手势取消通过 Navigator 手势状态模拟。
自动回归不代表已经测得设备帧耗时收益。

本次采用 Tier 2 代码核验。
引用代码路径的覆盖检查没有记录解析缺口。
文件新鲜度标记为 `metadata_changed`，结论已用直接读源补足。
本次没有设备帧耗时、CPU 或内存测量结果。

## 实施交接

- `task_brief`：将视频详情初始化移出转场，提前处理离页，并减少下载列表复制。
- `dispatch.read_only`：`video_playback_map` 核对详情与播放器生命周期；`video_sidebar_map` 核对在线目录和下载入口。
- `dispatch.write_stages`：`video_route_fix` 负责详情页、播放面板和播放页回归；主智能体负责下载页和本文。文件归属独立，允许并行写入；Flutter 命令串行执行。
- `dispatch.skipped`：原生、构建和依赖写入者；本轮不涉及这些模块。
- `agents`：两名只读顾问提供调用顺序与源码证据；`video_route_fix` 负责详情时机改动；`video_route_review` 独立核对异步和手势边界。
- `implementation_plan`：先验证旧时机，再修改详情与下载页，最后组合回归并独立评审。
- `verification`：组合回归 227 项及补充回归 1 项通过；静态检查通过；独立复核未发现必修缺陷。
- `dependency_risks`：无新增依赖或数据格式变更。
- `conflicts`：`[]`。
- `handoff.what`：本轮范围为详情进出与下载列表读取；`why`：减少转场期间的初始化与重复工作；`next`：侧栏抽屉调度仍需核验可靠的动画结束机制。

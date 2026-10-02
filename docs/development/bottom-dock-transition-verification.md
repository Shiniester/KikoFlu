# Bottom Dock SlideTransition 验证

2026-10-02，Flutter 3.44.7，Windows 主机。承载与运动决策见
[ADR 0001](../adr/0001-work-detail-bottom-dock-handoff.md)。

## 自动回归

六个核心套件共 67 项通过：

```powershell
flutter test --no-pub test/app_bottom_dock_transition_test.dart `
  test/app_bottom_dock_test.dart test/page_transitions_test.dart `
  test/mini_player_route_gesture_test.dart test/player_artwork_hero_test.dart `
  test/work_detail_route_readiness_test.dart --timeout 45s
```

覆盖普通进退、路由缓动采样、安全区 0／34、DPR 1／3、Mini Player 高度变化、
无播放状态、Mini-only 嵌套导航、减少动画、快速重入、过渡中旋转横屏、
iOS 返回手势和 Android predictive back 的完成／取消，以及手势进度仍为 1
时的快照切换。落定后点击或上划打开完整播放器并返回的封面 Hero 通过回归。
位置、间距、页面水平移动、首末帧和组件 State 保留由 widget 测试验证。

音频搜索、漫画详情、漫画搜索及漫画分类的四个导航入口回归通过：

```powershell
flutter test --no-pub test/audio_screen_test.dart test/comic_widgets_test.dart `
  --name '(hands off|hand off)' --timeout 45s
```

五个修改的生产 Dart 文件及四个修改的测试文件 analyzer 无问题；
`git diff --check` 通过。独立范围评审完成。

## 设备动效

本次没有执行真机视觉或帧耗时检查，自动回归结果不代表真机流畅度验收。

| 环境 | 本次结果 |
| --- | --- |
| Android 真机 Huawei ABR AL60，Android 12／API 31 | 已识别设备；未安装或运行本次构建，动效未检查 |
| Android 13+ predictive back | 没有对应设备；完成／取消及进度 1 时序仅通过 widget 测试 |
| iOS 返回手势 | 没有对应设备；完成／取消仅通过 widget 测试 |

后续真机检查应使用[独立 Android Debug 包](android-device-testing.md)，观察
首次进入和返回、取消手势、安全区、字幕高度变化、快速重入、旋转横屏及
完整播放器往返是否存在双影或闪空，并记录设备与构建信息。

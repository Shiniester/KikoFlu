# 漫画阅读器动效验证

阅读控制层使用与 Bottom Dock 相同的 300 ms、`Curves.ease` 位移动画。
顶部工具栏向上退出，底部阅读进度控件与 Mini Player 一起向下退出，移动
距离为各自控制层高度。漫画画布尺寸保持稳定；隐藏的控制层不参与点击、
焦点或无障碍访问。减少动态效果时直接切换位置。

## 缩放参考

缩放边界与 [PicaComic 阅读视图](https://github.com/ccbkv/PicaComic/blob/master/lib/pages/reader/image_view.dart)
一致：连续阅读模式的整个列表共同缩放，双页模式的两张图片共同缩放，
单页模式以当前页为阅读视图。

[双击处理](https://github.com/ccbkv/PicaComic/blob/master/lib/pages/reader/touch_control.dart#L323-L343)
在连续与双页模式中切换初始比例和 1.75 倍比例，并根据双击位置调整平移。
单页模式参考 PhotoView 的完整显示、覆盖视口、原始尺寸循环。
缩放过渡参考其
[弹簧动画](https://github.com/wgh136/photo_view/blob/a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c/lib/src/core/photo_view_core.dart#L252-L315)。

## 关键交互

- 显示和隐藏上下控制层时，检查中间帧、最终位置与漫画页面尺寸。
- 双页模式分别双击左右图片，检查两张图片一起缩放。
- 连续模式双击后继续上下滚动与横向平移，检查后续图片与当前缩放比例
  一致，页码和保存的阅读进度对应实际可见图片。
- 单页模式重复双击，检查缩放状态循环与图片居中。
- 缩放过渡期间再次双击或开始双指操作，检查动画接续和手势接管。
- 手动双指缩放后再次双击，检查恢复初始比例；小尺寸图片在原始尺寸下
  继续双指缩放时不应突然跳回初始大小。
- 关闭双击缩放后，检查双击不再改变比例，双指缩放仍可使用。
- 开启减少动态效果，检查控制层和双击缩放直接落定。
- 打开完整播放器并返回，检查阅读页码和 Mini Player 状态保留。

## 自动化验证

2026-10-04，Windows，Flutter 3.44.7 / Dart 3.12.2。以下定向回归共
25 项通过：单页缩放 3 项、连续缩放 1 项、双页缩放 1 项、阅读器现有
交互与控制层 20 项。覆盖原始尺寸下双指缩放、拖拽惯性边界、缩放动画中
切章、可见页码与阅读进度、减少动态效果，以及完整播放器返回。

```sh
flutter test --no-pub test/comic_widgets_test.dart --plain-name "single-page"
flutter test --no-pub test/comic_widgets_test.dart --plain-name "continuous zoom covers the strip and preserves list gestures"
flutter test --no-pub test/comic_widgets_test.dart --plain-name "spread zoom follows its focal point and interrupts smoothly"
flutter test --no-pub test/comic_widgets_test.dart --plain-name "reader"
flutter analyze --no-pub lib/src/comics/ui/comic_reader_screen.dart test/comic_widgets_test.dart
```

修改的 Dart 文件已格式化，静态分析无问题。未新增依赖。

## 设备检查

2026-10-04 的 Windows 主机未连接 Android 设备。真机动效与帧耗时需要在
[独立 Android Debug 包](android-device-testing.md)中检查。

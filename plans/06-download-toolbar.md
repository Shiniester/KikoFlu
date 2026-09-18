# 下载工具条形变

范围：`lib/src/screens/local_downloads_screen.dart`。

只有普通、搜索、多选三种模式键。始终挂载一个内容子树，外层 AnimatedSize 在 200ms 内改变胶囊宽度；新模式由页面持有的控制器驱动 0.97→1 缩放和透明度进入，曲线 easeOutCubic。输入和选择数量不改变模式键。

页面持有搜索 FocusNode；关闭搜索或进入多选立即 unfocus。打开搜索或从多选返回搜索时，下一帧仅在页面仍挂载且仍处于搜索模式时请求焦点。退出搜索立即卸载输入框。启动时或运行中开启减少动态效果，控制器立即归并到终点，宽度动画重新初始化；内容通过稳定 GlobalKey 保持挂载，保留输入和焦点。关闭该设置不重播当前模式的进入动画。

自动覆盖：`test/browse_motion_test.dart` 检查快速切换只有一个输入框、输入后节点不变、关闭立即释放焦点、重开恢复焦点。

`test/toolbar_motion_regression_test.dart` 验证中途关闭位置／缩放／宽度动画、输入框身份和焦点保持，以及多选返回搜索。执行 `flutter test --no-pub --dart-define=KIKOFLU_PERFORMANCE=true test/toolbar_motion_regression_test.dart`，以启用已有的内存下载数据夹具；无该参数时仅跳过需要夹具的焦点测试。

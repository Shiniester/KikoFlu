# 画廊触点缩放

范围：`lib/src/widgets/image_gallery_screen.dart`。

双击在当前矩阵与 1／2 倍目标间做 250ms easeOutCubic 插值。用 InteractiveViewer 实际约束及双击局部坐标计算场景点，再求目标平移并限制在可视边界。中途双击按最近目标反转，从当前矩阵接续。

指针按下、交互开始、换页和退出停止自动缩放。缩放状态随矩阵更新，阻止与整页滑动争抢。单击翻页使用确认后的 onTapUp，双击识别前不翻页。系统禁用动画时直接赋目标；动画中途开启则完成目标并停止控制器。

自动覆盖：`test/browse_motion_test.dart` 检查中间比例、触点场景坐标稳定、按下打断与中途减少动态效果。真机 profile 场景：`galleryDoubleTap`。

# 连续曲目视觉过渡

范围：`player_track_layers.dart`、`player_cover_widget.dart`、`audio_player_screen.dart` 的私有标题切换组件。

`PlayerTrackLayers<T>` 仅负责曲目视觉层：最多三个控制器／渲染层，加一个最新待呈现目标。每次改目标先采样实际 offset、scale、opacity；从该值接续。退出期限在打断后至多 125ms，后续请求不能延长。满载时替换待呈现目标并保留当前进入层；有空位后接入最新目标。请求命中现有层时复用且不改变绘制顺序。

正常标题 260ms、封面 300ms，封面缩放端点 1.20；保留 easeOutCubic 几何和线性封面透明度。每帧由 Slide／Scale／FadeTransition 驱动，文字和图片放在静态 RepaintBoundary 子树。只有最新已提交内容有交互／语义资格。

封面继续等待图片准备并过滤过期回调。同作品更新只替换信息，不重置当前混合。新图片准备时清理过期待显示目标，保持可见层。关闭动画或运行中开启减少动态效果时立即归并最新内容，撤销图片监听；销毁释放全部控制器。

自动覆盖：`test/player_track_layers_test.dart`（45／180ms 打断、30ms 连续提交、图层上限、复用与绘制顺序、截止时间、清理）、`test/player_artwork_hero_test.dart`、既有主过渡帧和标题布局测试。

# KikoFlu 动画改进

基于 `3e6f5cd` 和 Flutter 3.44.7。采用柔和减速、轻微形变和淡入淡出，无新增依赖。播放器进出、封面 Hero 和底部 Dock 的主编排保持原有测试预期。

按执行依赖顺序：

- [首页模式滚动隔离](01-home-mode-scroll.md)
- [分页与减少动态效果](02-pagination-reduced-motion.md)
- [连续曲目视觉过渡](03-track-presentation.md)
- [播放条横滑请求解耦](04-mini-player-swipes.md)
- [画廊触点缩放](05-gallery-zoom.md)
- [下载工具条形变](06-download-toolbar.md)
- [搜索条件区域展开](07-search-conditions.md)
- [验证与真机对比](08-validation.md)

交付状态和实测结果见 [验证报告](animation-validation.md)。

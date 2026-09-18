# 分页与减少动态效果

范围：`virtualized_sliver_collection.dart`，首页、我的、歌单列表／详情、本地下载、浮动工具条、搜索、画廊与文本预览。

分页锁仅包围真实请求。按钮发起请求后安排回顶，越界分页等待请求完成再安排回顶；回顶 Future 不延长请求锁。每次分页递增操作序号并停止当前程序滚动；用户 ScrollStart 带 dragDetails 时取消尚未启动的回顶。下一帧启动前校验挂载状态和序号。活动滚动由用户拖动接管。

选中范围内分页采用 `UiMotion.travel`（250ms）与 `UiMotion.curve`（easeOutCubic）。`VirtualizedCollectionController.scrollToTop` 新增 `animate = true`；false 或零时长直接跳转。本地下载传入系统设置。

统一用 `MediaQuery.disableAnimationsOf(context)`：分页、搜索条件定位、画廊程序翻页、文本定位直接跳转；浮动位置不插值，隐藏内容同步禁用点击；新增几何动画直接到目标。保留颜色／透明度反馈。

验收：真实请求去重、动画中再次分页、用户打断、退出页面、禁用动画和零时长跳转。自动覆盖：`test/virtualized_sliver_collection_test.dart`、`test/floating_feed_toolbar_test.dart`。

# 动画验证报告

八项动画改进已落地；播放器进出、Hero、Dock 的原有编排和主过渡图片预期保留。新增测试验证中断时不重置端点、最多三层和一个最新目标、退出期限、真实服务横滑请求、滚动实例隔离、分页解锁、焦点和手势接管。

## 自动验证

- 减少动态效果新增 8 项回归覆盖 Hero 进出与交接结果、队列开关、标签即时定位及中途切换；播放器、Hero、Dock、播放条手势、浏览和标签相关 58 项回归通过，队列定向 2 项通过。修改的源文件与测试静态分析无问题。日志：`build/reduced_motion_fix_{tests,regression,analysis}.log`。
- `flutter analyze --no-pub`：无问题。工具条修改涉及的两个源文件和回归测试亦通过定向静态分析。
- 工具条中途减少动态效果与多选返回搜索的 3 项回归通过（启用已有 `KIKOFLU_PERFORMANCE` 内存夹具）；相关浏览、工具条、分页 24 项回归通过。
- 曲目图层、封面、播放条、请求服务、性能结构保护、主过渡图片、工具条及分页相关回归：76 项通过。
- 最终浏览、图片乱序完成、分页、播放器路由／编排和 Dock 回归：30 项通过。画廊追加快速双击反转检查通过。
- 播放器布局、请求服务、播放条与 Dock transition 扩展回归：92 项通过，1 项既有失败（下文）。
- Android profile APK 构建成功。未升级 Gradle、Kotlin 或依赖。

测试文件包括 `player_track_layers_test.dart`、`player_artwork_interruptions_test.dart`、`browse_motion_test.dart`、`virtualized_sliver_collection_test.dart`、`audio_player_latest_request_test.dart`，以及原有播放器路由、Hero、Dock 和 `player_transition_frames_test.dart`。日志保存在 `build/animation_*.log`。

## Android 真机 profile

设备：Huawei ABR-AL60，Android 12 / API 31；实测刷新率 60.000Hz，帧预算 16.667ms。基准 `3e6f5cd` 与修改后使用 Flutter 3.44.7 profile、同一设备和同一测试场景，各运行五次。独立测试包名，不覆盖日常安装。

各 P95 列是五轮场景 P95 的中位数；超预算率将五轮的超预算帧／总帧数合并计算。帧超预算口径沿用项目记录器（UI 或 raster 超过当前显示帧预算）。单位 ms，表内为“修改前 → 修改后”。

| 场景 | UI P95 | raster P95 | 超预算帧比例 |
| --- | ---: | ---: | ---: |
| 首次展开 | 13.051 → 12.003 | 8.359 → 6.608 | 3.409% → 2.841% |
| 反复展开／收起 | 8.682 → 7.926 | 9.581 → 8.955 | 3.298% → 3.457% |
| 拖动回退 | 5.908 → 6.057 | 9.433 → 9.290 | 3.708% → 3.364% |
| 拖动交接 | 10.619 → 10.674 | 10.309 → 9.965 | 6.250% → 6.217% |
| 播放器页面切换 | 2.105 → 2.239 | 12.441 → 13.153 | 2.514% → 3.207% |
| 歌词跟随 | 9.545 → 9.929 | 10.265 → 10.423 | 4.133% → 3.852% |
| 歌词滚动 | 5.848 → 6.739 | 11.164 → 10.171 | 0.463% → 0.308% |
| 连续曲目展示（45ms） | 18.132 → 19.688 | 7.717 → 7.684 | 14.025% → 18.143% |
| 画廊双击缩放 | 5.250 → 5.736 | 4.534 → 4.573 | 0.064% → 0.064% |

连续曲目展示在每 45ms 提交的压力下，UI P95 从 18.132ms 上升至 19.688ms，超预算率增加 4.118 个百分点。保留最多三层以接续中断具有额外渲染成本；该结果不支持性能改善结论。画廊加入 250ms 缩放后仍在帧预算内。既有主过渡各场景存在小幅双向波动，不能归因为本次改动的性能收益。

[完整聚合数据](animation-profile-summary.json)。原始逐轮数据和温度／显示状态保存在 `build/animation_performance/reports/animation_detail_{baseline,candidate}_*.json`。复现入口为 `integration_test/player_profile_test.dart`，汇总脚本为 `tool/performance/summarize_player_profile.py`。额外扩展的连续曲目与画廊场景已保存在这两个入口中。

## 验证边界与已知问题

- `main lyric preview scrolls without opening queue or dismissing` 的滚动复位断言在原始 `3e6f5cd` 单独运行亦失败。基准与当前均为预期 0、实际 76；原始日志：`build/animation_baseline_lyric_test.log`。未更改其测试预期或歌词逻辑。
- 真机 profile 覆盖播放器和画廊；首页、分页、下载工具条、搜索条件目前以 widget 测试验收，未收集其独立真机帧数据。
- 正常时长交互已由真机自动化执行；45／180ms 中断和零时间 transform／opacity 连续性由自动化检查。人工握持设备的跟手感与慢速视觉检查尚未完成，不宣称已通过人工观感验收。
- 所有 profile 场景使用本地图片与模拟曲目提交；此次帧测试不测量真实音频加载耗时。

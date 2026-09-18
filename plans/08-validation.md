# 验证与真机对比

基准：提交 `3e6f5cd`，Flutter 3.44.7，Android 为主要验收平台。

自动验证覆盖：图层连续性／容量／截止时间、真实服务请求、首页实例隔离和偏移恢复、分页请求与滚动解耦、画廊触点与手势接管、下载输入焦点、条件区高度接续。执行相关 widget 测试、静态分析，以及播放器路由／Hero／Dock 回归；保留 `player_transition_frames_test.dart` 的原有图片预期。

真机使用单独包名 `com.meteor.kikoeruflutter.animationprofile`，保留用户日常安装的数据。基准和候选采用同一设备、同一 profile 场景和 60Hz 刷新率；各运行五次。场景包含既有播放器进出、拖动、页面切换和歌词，以及连续曲目展示和画廊双击。统计 UI／raster P95、帧预算和超预算帧比例；结果见 `animation-validation.md`。

复现入口：`integration_test/player_profile_test.dart`，运行器 `tool/performance/run_player_profile.py`。隔离包测试在忽略的 build 副本内改 applicationId 与测试文件路径；Activity 保持原 namespace。Huawei 设备 push 的 fchown 兼容问题用 shell cat 写入测试控制文件处理，不涉及日常应用。

已知基准问题：`main lyric preview scrolls without opening queue or dismissing` 在原始提交单独运行也于滚动复位断言失败，记录原始输出 `build/animation_baseline_lyric_test.log`。它不属于本次动画修改。

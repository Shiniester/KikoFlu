# 音频切换与跳转修复

修复恢复跳转阻塞后续请求、同曲目重载丢失新目标和进度预览回跳。
验证使用本机契约测试和界面测试，不依赖 Android 设备。

## 恢复跳转

保存位置超过实际时长时，恢复会话需要将位置修正到末尾前 1 ms。
这次原生跳转需要响应请求取消，并遵守现有恢复等待上限。
后续换曲或停止不能继续等待已被替代的跳转回调。

回归覆盖以下场景：

- 修正跳转挂起时，新的曲目请求能够完成。
- 修正跳转挂起时，停止能够完成。
- 原生回调不返回时，恢复会话有界结束。

依据：[播放服务](../../lib/src/services/audio_player_service.dart)、
[请求协调回归](../../test/audio_player_latest_request_test.dart)。

## 同曲目重载期间的连续跳转

远程跳转命中完整缓存，或跳转失败后恢复时，当前曲目需要重新加载。
这段时间只保留最后一个跳转目标，待音源准备完成后应用。
前进和后退从最新待处理目标累计。
加载期间时长未知时也接收请求，准备完成后限制目标范围。
停止或切换到其他曲目时，旧目标失效。
不同曲目加载期间仍保留进度保护。

服务返回跳转是否实际生效。
控制器和系统媒体入口只在跳转生效后保存实际位置，避免将越界目标写入播放历史。

回归覆盖缓存换源、控制器入口、失败恢复和待处理目标失效。
例如先加载 30 秒目标，再请求 60 秒目标，最终位置必须为 60 秒。

依据：[播放服务](../../lib/src/services/audio_player_service.dart)、
[音频控制器](../../lib/src/providers/audio_provider.dart)、
[完整缓存跳转回归](../../test/audio_player_cached_seek_test.dart)、
[跳转恢复回归](../../test/audio_player_seek_recovery_test.dart)。

## 进度预览

开始新拖动或提交新跳转时，取消旧预览的清理任务。
页面销毁时也取消清理任务。
正常松手后仍在 100 ms 后恢复播放器进度显示。

窄屏和宽屏回归均执行连续拖动。
第二次拖动越过第一次清理时间后，预览必须保持第二次的位置。
第二次松手后，再检查正常清理。

依据：[播放器界面](../../lib/src/screens/audio_player_screen.dart)、
[界面回归](../../test/audio_player_screen_layout_test.dart)。

## 保留的边界

- Android 启播缓冲门槛保持 750 ms。
- 本地下一首预加载沿用 [ADR 0003](../adr/0003-independent-audio-cache.md) 的边界。
- 下载曲目的音频触感分析保持现有播放顺序。

## 验证

新增 10 项回归，关联测试共 261 项通过：播放器界面 105 项，服务与状态管理 156 项。
修改涉及的 7 个 Dart 文件通过静态分析。

```powershell
flutter test --no-pub test/audio_player_screen_layout_test.dart
flutter test --no-pub test/audio_player_latest_request_test.dart test/audio_player_cached_seek_test.dart test/audio_player_seek_recovery_test.dart test/audio_player_native_preload_test.dart test/playback_session_restore_failure_test.dart test/playback_session_store_test.dart test/playback_history_service_test.dart test/player_rebuild_boundaries_test.dart test/player_lyric_interaction_test.dart
```

本机检查验证请求顺序、取消和最终位置。
实际出声耗时和触发频率未测量。

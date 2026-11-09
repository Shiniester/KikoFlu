# 原生音频适配器契约

测试在当前进程注册本地 `just_audio_media_kit`，直接使用真实 `just_audio` 和 libmpv。
测试不启动生产应用，也不改变生产后端注册。

## 运行

在 Windows 用参考库运行同一组契约：

```text
flutter test --no-pub tool/audio_backend_contract/reference_test.dart --dart-define=KIKOFLU_PERFORMANCE=true --dart-define=KIKOFLU_AUDIO_LIBMPV=C:/path/to/libmpv-2.dll
```

这个入口使用 Flutter tester 和真实 FFI 库，不构建 Windows 应用插件。
`integration_test plugin was not detected` 表示这个入口不收集设备插件报告。
断言和原生库调用仍实际执行；这不等于打包的 Windows 或 Android 应用通过。

在独立测试包中使用当前打包库：

```text
flutter test -d <device-id> integration_test/audio_backend_native_contract_test.dart --dart-define=KIKOFLU_PERFORMANCE=true
```

Android 包名必须与正式应用不同，不能覆盖正式安装。
`gate_status` 保持 `incomplete`；系统控制、后台和持续播放仍需分别验收。

## FLAC 夹具

夹具为自有 24 秒、16 kHz 单声道信号，包含 type 3、长度为 0 的 SEEKTABLE。
测试检查实际 FLAC 元数据，再验证 25%、80%、10% seek 后的原生位置事件继续推进至少 500 ms。
这个文件检查格式兼容性，不替代大文件的性能验证。
压缩后的测试常量仅用于减少代码体积，播放前解压为完整 FLAC 文件。

重建夹具：

```text
python tool/audio_backend_contract/generate_fixture.py --ffmpeg C:/path/to/ffmpeg.exe
```

正常运行不需要 FFmpeg 可执行文件。

## 认证 HTTP 和切片

本机服务器要求固定的测试 Authorization，并记录原站收到的嵌套路径、查询参数和 Range。
普通来源和 `ClippingAudioSource` 使用同一份自有 WAV。
8 KiB 内存缓冲用于迫使 seek 发起实际字节范围请求，测试结束后恢复原值。
切片保留 4 秒起点和 20 秒终点，并要求 16 秒相对时长、末端 completed 状态及下一次加载恢复 ready。

## 服务与生命周期契约

测试向现有 `AudioPlayerService.forTesting` 注入真实 AudioPlayer，启用其 Android 原生预加载窗口。
偏好存储独立于账号，音频来源、原生适配器和 HTTP 请求均实际执行。
测试进程开启既有 `JustAudioMediaKit.prefetchPlaylist`，在结束后恢复。
预加载要求 B 的 HTTP 请求在 A 仍播放时到站，再检查自然 A→B→C 各发布一次。
手动下一首复用已经预取的 16 秒 WAV B，检查 B 的时长、缓冲和位置，且不能重复打开 B 的 HTTP。
快速切歌在真实 B 请求挂起时请求 C，要求最终仅发布 A、C，C 实际推进且资源销毁完成。
B 返回 404 的用例要求 A 在预取失败后仍推进，服务明确发布 B 加载失败，然后 C 正常加载。
服务失败诊断需要既有 `KIKOFLU_PERFORMANCE=true`，不是播放结果的替代来源。
预期 404 用例只接受指定 B 的 HTTP 错误，以及参考库为该失败启动提取器时的明确缺失进程日志。
其他用例要求原生 error/fatal 日志和公开错误流为空。

缓存归一读取真实 `demuxer-cache-state`，仅在 `eof` 与 `eof-cached` 都为 true 时补齐最后一个音频包的时长。
固定 mpv 源码中 `eof-cached` 对所有缓存段取 OR，不能单独证明当前位置已连续缓存到文件尾。
跨加载测试先取得 A 的真实 EOF 结果，再延迟返回；B 已加载且只收到前 262144 字节时，A 的旧结果不能填满 B 的尾段。
另一个用例在销毁后实际调用 NativePlayer.getProperty，要求已退休查询的异常不成为新源错误或未处理异常。
这些测试只延迟真实查询完成时间，不伪造查询值。
同一时序入口还覆盖 128 KiB 多段缓存的 seek 23→5 秒，要求旧 EOF 不能填满新的缓存段。
自然文件边界通过既有 NativePlayer unload hook 暂停原生卸载，要求等待新 index 时旧查询不发布 A 的状态。
HTTP 停尾触发原生 buffering 后恢复响应，要求挂起的旧查询不能覆盖最新 ready。

## 章节预加载

服务预加载复用 `_clipAudioSourceForTrack`，晋升后保留章节范围。
回归用例使用 24 秒来源，范围为第 4～20 秒。
用例等待 B 完成预取，再调用 `service.skipToNext()`。
晋升后时长为 16 秒，位置继续推进。
晋升不能再次打开 B 的 HTTP 请求，也不能发起第二次服务加载。

原生缓冲长度为 0 时，就绪判断也接受已到达切片起点的实际位置。
等待原生缓冲结束后，服务才能发布就绪状态。

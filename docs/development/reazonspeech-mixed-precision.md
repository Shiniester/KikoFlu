# ReazonSpeech 混合精度替换

## 模型与缓存

日语音频字幕生成使用 ReazonSpeech-k2-v2 的 `int8-fp32` 组合。
组合与 [ReazonSpeech 官方加载代码](https://github.com/reazon-research/ReazonSpeech/blob/master/pkg/k2-asr/src/huggingface.py)一致：

| 文件 | 精度 |
| --- | --- |
| `encoder-epoch-99-avg-1.int8.onnx` | int8 |
| `decoder-epoch-99-avg-1.onnx` | fp32 |
| `joiner-epoch-99-avg-1.int8.onnx` | int8 |

模型保存到应用支持目录的
`local_audio_subtitles/ja_reazonspeech_int8_fp32`。
首次生成时下载全部模型文件、tokens 和 Silero VAD。
下载文件共 169,824,553 字节，约 170 MB。
后续生成复用此目录内已完成的文件。
下载失败或取消时，沿用现有临时文件清理与重试流程。

旧目录 `local_audio_subtitles/ja_reazonspeech` 不参与新模型的就绪判定。
本次不迁移或自动删除旧模型文件，也不回退到旧模型。
新目录尚未下载完整时，离线生成会失败。

## 代码与测试

模型下载库使用新目录和 fp32 decoder URL，转写器加载对应的 decoder 文件。
现有字幕继续保留，已有字幕的跳过规则继续生效。

模型下载、转写和字幕生成服务共 17 项测试通过。
测试覆盖旧缓存隔离、完整下载清单、复用、失败重试与取消。
3 个修改的 Dart 文件静态检查通过。

```powershell
flutter test --no-pub test/local_subtitle_model_store_test.dart test/local_audio_transcriber_test.dart test/audio_subtitle_generation_service_test.dart
flutter analyze --no-pub lib/src/services/local_subtitle_model_store.dart lib/src/services/local_audio_transcriber.dart test/local_subtitle_model_store_test.dart
```

## 对比方法

2026 年 10 月 21 日，在 Windows x64 上对比全 int8 与混合精度模型。
运行环境为 Windows 11 build 26200、i7-12700H、Flutter 3.44.7、Dart 3.12.2。
识别使用 2 个线程，其余解码与语音分段参数沿用现有转写器。

样本使用模型发布者提供的 [13.433 秒日语 WAV](https://huggingface.co/csukuangfj/reazonspeech-k2-v2/resolve/main/test_wavs/1.wav)。
MP3、FLAC 均由该 WAV 转换，使用 FFmpeg 7.1、16 kHz、单声道。
MP3 使用 `libmp3lame -q:a 2`，FLAC 使用 `-compression_level 5`。
WAV、MP3、FLAC 分别为 429,934、88,028、236,185 字节。

每个模型与格式组合均在独立测试进程中运行 1 次。
全 int8 对照的 decoder 在临时目录使用新加载路径的文件名，内容仍为原 int8 文件。
两种模型使用同一生产转写器，避免引入解码、线程或语音分段差异。
计时包含模型加载、解码、识别、SRT 生成和现有字幕解析器读取。
计时不包含模型与音频下载，也不包含 Flutter 测试宿主启动。
峰值工作集读取 Windows `GetProcessMemoryInfo` 的 `PeakWorkingSetSize`。

## 对比结果

6 组原生识别均通过日文文本、字幕条数、时间顺序和音频时长上界检查。
无效音频路径也按预期返回 `StateError`。

| 模型 | 格式 | 处理耗时（秒） | 进程峰值工作集（MiB） | 字幕条数 | 末条结束时间（秒） |
| --- | --- | ---: | ---: | ---: | ---: |
| 全 int8 | WAV | 3.457 | 558.18 | 2 | 12.844 |
| 混合精度 | WAV | 3.628 | 574.00 | 2 | 12.844 |
| 全 int8 | MP3 | 3.485 | 559.04 | 1 | 12.764 |
| 混合精度 | MP3 | 3.645 | 572.81 | 1 | 12.764 |
| 全 int8 | FLAC | 3.595 | 557.64 | 2 | 12.844 |
| 混合精度 | FLAC | 3.514 | 573.36 | 2 | 12.844 |

本次混合精度的峰值工作集比全 int8 高 13.77–15.82 MiB。
WAV、MP3 的处理耗时增加，FLAC 的处理耗时减少。

识别文本如下，单元格中的换行区分字幕条目。

| 模型 | 格式 | 识别文本 |
| --- | --- | --- |
| 全 int8 | WAV、FLAC | `町`<br>`気崩れや屋根からの落雪にも十分注意するよう呼びかけています` |
| 全 int8 | MP3 | `気象庁は雪や路面の凍結による交通への影響暴風雪や高波に警戒するとともに雪崩や屋根からの落雪にも十分注意するよう呼びかけていま` |
| 混合精度 | WAV、FLAC | `町`<br>`気象庁は雪や路面の凍結による交通への影響暴風雪や高波に警戒するとともに雪崩や屋根からの落雪にも十分注意するよう呼びかけています` |
| 混合精度 | MP3 | `気象庁は雪や路面の凍結による交通への影響暴風雪や高波に警戒するとともに雪崩や屋根からの落雪にも十分注意するよう呼びかけています` |

原始 JSON 与 SRT 保存在本次本地工作区的
`.dart_tool/reazonspeech_benchmark/results`。

## 结果范围

进程峰值工作集包含 Flutter 测试宿主和模型，不能视为模型独占内存。
各组合只测量 1 次，耗时不能代表其他音频与设备。
本次没有人工参考转写，公开样本的文本差异不能证明真实音声的准确率提高。
耳语、气声和长音频仍需用对应样本实测。
Android、iOS、macOS、Linux 尚未执行混合精度模型的构建与运行验证。

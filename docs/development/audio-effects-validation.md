# 播放音效验证

## 统一版本（2026-11-11）

Android、iOS、macOS、Windows 和 Linux 的原生库使用相同的源码版本：

| 组件 | 版本 | 源码提交 |
| --- | --- | --- |
| mpv | 0.42.0 | `b0841e8c4d156b8403dc1876c4cbd9011eb583f3` |
| FFmpeg | 9.0.2 | `946fcce07b6dcd0331c8cc609192aeff5e1924f8` |
| libplacebo | 7.387.0 | `275f7dea27924cdd34ab2e6c20e448b6bc4fab65` |

验收使用应用打包的原生库，检查实际 PCM 输出、播放中参数更新和视频播放。
旁路和零强度输出要求与输入逐样本相同，其他音效沿用已有数值误差范围。
iOS 模拟器检查同源库的输出；设备版本检查构建、架构和最低系统版本。
本轮不执行真机测试或耳机试听。

固定 PCM 测试信号使用 WAV 格式，并显式指定 WAV 解复用器。
这组信号的格式自动识别未纳入验收；视频测试仍使用自动识别。
macOS 集成测试使用软件纹理，以适配没有加速 OpenGL 上下文的构建机。
应用默认的加速纹理路径在无法创建 OpenGL 像素格式时会崩溃，目前没有自动回退。
Android 预加载切到下一首后，启用“仅播放切片”可能先播放片段外音频。
播放器随后才定位到切片。

### Windows 附加宿主测试

测试用的 `arealtime` 滤镜会延迟 mpv 的位置通知。
此前一次超时时，原生位置为 9.72 秒，media_kit 位置仍为 0。
复现时，直接订阅 mpv 也收不到推进通知。移除滤镜后，位置通知恢复。
宿主测试读取原生 `time-pos`，并在 HLS 输入为 44.1 kHz 时更新播放音效。

HLS 测试曾在 PCM 输出关闭前读到 381,952 帧。
确认输出关闭后，同一文件补齐到 382,405 帧，原有字节完全一致。
宿主测试在 PCM 输出关闭后读取文件，检查冷热采集的完整帧数并逐样本比较尾段。

使用交付的 `libmpv-2.dll`，播放音效宿主测试复跑 4 轮，每轮 6 项全部通过。
其中两轮合跑均通过 11 项测试。
另一轮合跑有 5 项服务宿主测试未完成。
Windows 日志记录 `flutter_tester.exe` 访问冲突 `0xc0000005`，故障模块未知。
服务宿主测试单跑 4 轮，每轮 5 项全部通过。

将 `KIKOFLU_AUDIO_LIBMPV` 指向交付的 DLL 后，单跑播放音效宿主测试。

```powershell
flutter --suppress-analytics --no-version-check test --no-pub --reporter expanded test/audio_effects_native_host_test.dart
```

### 已完成的验证

[跨平台流水线](https://github.com/Shiniester/KikoFlu/actions/runs/42979288828/attempts/2)通过，源码提交为 `dcbaaf17`。

[Linux 验证](https://github.com/Shiniester/KikoFlu/actions/runs/42979288828)通过 x64 和 ARM64 发布包构建、PCM 检查及各 7 项播放器集成测试。
视频测试在两个架构上均观察到 1280×720 的纹理。

[Windows 原生库产物](https://github.com/Shiniester/KikoFlu/actions/runs/42979288828/artifacts/13838446526)在本机通过 90 项 PCM 检查，包含 HTTP/HLS 和跳转边界。
跳转后的 48,017 帧与同一测试时钟下的冷启动基准逐样本相等。
同一产物通过 HLS 输入采样率切换与实时参数恢复检查。
输入依次切换为 44.1、96、44.1 和 96 kHz，冷启动与实时更新均输出 382,405 帧。
[Windows 应用验证](https://github.com/Shiniester/KikoFlu/actions/runs/42979288828/job/130397770649)通过发布包构建、7 项音效和视频测试及 14 项播放后端测试。

[Apple 原生库构建](https://github.com/Shiniester/KikoFlu/actions/runs/42979288828/job/130385632260)通过 iOS 和 macOS 的架构及最低系统版本检查。
[iOS 模拟器验证](https://github.com/Shiniester/KikoFlu/actions/runs/42979288828/job/130409302955)通过 7 项音效和视频测试，未签名设备应用也构建通过。
[macOS 应用验证](https://github.com/Shiniester/KikoFlu/actions/runs/42979288828/job/130394970194)通过 7 项音效和视频测试，并完成发布包构建；视频测试使用软件纹理。

[Android 原生库构建](https://github.com/Shiniester/KikoFlu/actions/runs/42979288828/job/130385665562)通过四个 ABI 的检查。
[Android 应用验证](https://github.com/Shiniester/KikoFlu/actions/runs/42979288828/job/130409303798)通过 APK 打包、7 项音效和视频测试及 14 项播放后端测试。

## 历史记录（2026-11-08 至 2026-11-09）

以下记录对应当时的构建与验收范围，不代表统一版本的验证结果。

按 2026-11-09 的确认，不再执行真机验证。
本轮优先保证 Android，其他平台的检查不阻塞交付。
统一音声后端、基础音效和两种双耳扩宽均已合入。
Android 的 4 个 ABI 原生构建已通过。
全量测试通过 3,458 项，跳过 22 项。
静态分析未报告问题。
通用 APK 与 ARM64 APK 已构建通过。
Android 旧版自建库的 90 项实际 PCM 检查单独保留。
最新原生参数恢复检查在主机运行，未在设备复测。

验证日期为 2026-11-08 至 2026-11-09。
本报告对应 [规格 #35](https://github.com/Shiniester/KikoFlu/issues/35)
及任务 #36～#39。
未完成的设备检查和耳机试听保留为未验证状态。

### Windows 原锁定库

原型通过 libmpv 客户端接口处理固定信号，并采集 PCM 文件。
运行库来自项目锁定的 `media_kit_libs_windows_video` 1.0.11。
该包指定的原生归档为 `mpv-dev-x86_64-20230924-git-652a1dd.7z`。

实际加载版本：

| 项目 | 结果 |
| --- | --- |
| 架构 | x86_64 |
| mpv | `mpv v0.36.0-403-g652a1dd907` |
| FFmpeg | `n6.0` |

实际运行结果保存在 [Windows 原始证据](audio-effects-windows-probe.json)。
旁路的 9,600 帧与固定输入完全一致。
输出包含 38,400 字节的双声道 `s16le` 采样。
当前滤镜探测得到以下结果：

| 检查 | 实际结果 |
| --- | --- |
| 均衡器 | 日志报告缺少 `aresample`，仅输出 8,576 帧 |
| `anull` | `No such filter: 'anull'` |
| `aeval` | `No such filter: 'aeval'` |
| `aiir` | `No such filter: 'aiir'` |
| `allpass` | `No such filter: 'allpass'` |

后四项探测均未取得 PCM 输出。
`anull` 等滤镜本身不存在，格式转换不是唯一缺口。

这些结果说明当前处理链不能在锁定库上运行。
均衡器、声道映射和两种扩宽均未通过实际输出验收。
Eara 场景基准、HTTP/HLS 音效输出和参数实时更新尚未验证。
更新后的适配器已在此原锁定库通过 11 项原生契约和 4 项加载单测。
[原库契约记录](audio-backend-windows-current.json)来自 Flutter tester 和真实 FFI。
平台应用插件、后台播放、系统控制和耳机试听仍待验证。

### Android 原锁定库

首次验证时尚未准备 Android SDK 和连接设备。
原锁定库未执行设备上的 PCM 检查。

项目锁定 `media_kit_libs_android_video` 1.3.8。
该包使用 libmpv 构建 `v1.1.7` 的 `default` 原生归档。
[固定版本的构建脚本](https://github.com/media-kit/libmpv-android-video-build/blob/v1.1.7/buildscripts/flavors/default.sh#L48)
设置 `--disable-filters`。
脚本仅重新启用 `overlay` 和 `equalizer`。
`aresample`、`aeval`、`aiir` 和 `allpass` 未在脚本中启用。
这是构建配置证据，不能替代 Android 实际加载和输出结果。

### 自建原生库

原生构建脚本位于 `scripts/native_audio/`。
构建保留原有滤镜禁用策略，仅补充明确需要的滤镜。
源码、工具链及依赖来源随产物写入 `source-provenance.txt`。
Windows 的 62 个构建 Git 输入已固定，完整构建仍待验证。

Android 全 ABI 产物来自[构建 42559176909](https://github.com/Shiniester/KikoFlu/actions/runs/42559176909)。
源码版本为 `b088c936`，包含 ARM64、ARMv7、x86 和 x86_64。
实际源码和工具链版本见[Android 构建来源](audio-effects-android-native-build.txt)。
4 个库的 ELF 加载段 `p_align` 均为 16,384 字节。
该轮包含重初始化、命令精度和效果参数恢复补丁。
这些补丁未执行设备复测。

#### Android 参数恢复

[参数恢复记录](audio-effects-android-control-cache.json)通过全部断言。
主机库使用 Android 固定的 mpv 源码和相同的两项补丁。
主机环境与依赖见[来源记录](audio-effects-android-control-build.txt)。
主机库使用系统 FFmpeg，不代表 Android 二进制的设备运行结果。

HLS 输入依次切换 44.1、96、44.1、96 kHz。
输出固定为 48 kHz。
旁路与受控输出均保留 382,405 帧。
检查先连续切换声道模式，再发送一条无效命令。
后续采样率切换不再发送控制命令。
切换后的左右声道均等于旁路右声道，最大误差为 `0`。
无效命令没有覆盖最后一次成功的参数。

原生缓存只记录已成功执行的有限数值参数。
滤镜图重新配置后，原生缓存先恢复参数，再接收音频。
Dart 不依赖格式通知补发参数。

#### 应用处理链

[应用处理链记录](audio-effects-production-pcm.json)保留 158 项通过结果。
基础音效通过 53 项，双耳扩宽通过 105 项。
检查使用应用实际生成的滤镜图和主机参考库。
参考库运行 `systemLibrary` 表达式版本。
检查不代表 Android 自建库的设备验证。

检查覆盖以下行为：

- 44.1、48、96 kHz，以及短输入和非整块末尾。
- 均衡器、声道模式、场景强度和实时调节。
- 立体声扩宽的中声道保留与差异声道变化。
- 单声道输入、相同左右声道输入和瞬态保护。
- 两种扩宽经过中性状态切换，以及最大强度切回关闭。
- 关闭时的恒等输出、静音、末尾帧数和高峰值保护。

171 项聚焦 Flutter 回归已通过。
全量测试和静态分析也已在上述 Android 优先流水线通过。
设置保存、恢复、重置、最新参数和视频实例隔离均有回归覆盖。

未打精度补丁的参考库仍有一项失败。
电话场景在 48 kHz 的最大误差为 `2.787137e-6`，超过 `1e-6`。
Android 自建 FFmpeg 已改用 17 位有效数字。
该误差不能用参考库的通过结果代替验证。
Windows 参考库的服务采集仍出现过 `47,616/48,017` 帧缺口。
实时跳转采集也偶尔出现尾部样本错位。
这两项尚未标记为稳定通过。

最终评审的 3 项问题均已修复。
修复后，93 项受影响的回归和 3 项原生章节契约通过。
结果见[双轴评审](audio-effects-review.md)。

#### Android APK

通用 APK 和 ARM64 APK 均通过最终流水线。
通用包包含 ARMv7、ARM64 和 x86_64。
原生提供包另有 x86 库，共 4 个 ABI。
Flutter 3.44.7 的 Android 应用构建不再提供 x86 目标。

通用包的 18 个、ARM64 包的 9 个 64 位原生库均通过 ELF 检查。
两个包也通过 `zipalign -P 16 -c 4` 检查。
包内 mpv 库与本轮 JAR 去除调试符号后的产物逐字节一致。
3 个 ABI 的应用产物均已包含最终评审修复。

#### Android 实际输出

自建 ARM64 库已在 OPD2405 的 Android 16 设备上运行。
设备为 API 36，页大小为 4,096 字节。
ELF 加载段的 `p_align` 为 16,384 字节。
实际加载版本为 mpv `v0.36.0-549-g78d43740f5-dirty`、FFmpeg `n6.0`。
构建来源见[Android 来源记录](audio-effects-android-build.txt)。
版本输入位于 `scripts/native_audio/android.lock`。

[Android 原始证据](audio-effects-android-probe.json)记录 90 项通过结果。
检查复用 `tool/audio_effects/validate.py` 的固定信号和独立判据。
设备上的 C API 工具采集实际 float32 PCM。
检查覆盖均衡器、声道模式、两种扩宽，以及三种场景的固定和动态强度。
采样率覆盖 44.1、48、96 kHz。
旁路和中性检查保持逐样本恒等要求。
动态场景保留全部 105,617 帧，误差低于 `1e-6`。
96 kHz 组合链完整输出 384,000 帧，未出现非有限值。
HTTP 输入完整输出 48,000 帧。
标准 AAC/MPEG-TS HLS 输入完整输出 49,152 帧。
网络输入的场景输出与其解码基线符合相同的递推判据。

FFmpeg 6 的处理链使用以下兼容约束：

- 显式指定滤镜输出的声道布局。
- 在音效前使用 mpv 的原生双声道转换。
- 只对指定的控制滤镜实例更新参数。
- 填充内部反馈计算块，保留干声的原始长度。

组合检查还发现常量 `volume` 的 ARM64 NEON 路径会崩溃。
等价的 `aeval` 常量乘法可避开该路径。
96 kHz 组合图处理 4 秒信号时，默认线程配置耗时 8.38 秒。
固定每个 lavfi 图使用 1 个线程后，耗时为 1.52 秒。

三个动态场景常驻时，96 kHz 最重组合曾耗时 4.10 秒。
该输入长度为 4.00 秒，共 384,017 帧。
零强度短路计算后，三种场景分别耗时 3.60、3.04、3.28 秒。
每个输出均完整且有限，测量包含初始化、销毁和日志收尾。
这些是[单次离线性能记录](audio-effects-android-performance.json)。
结果不代表持续播放或其他设备的性能验收。

均衡器全频段 `+15 dB` 叠加单声道扩宽时，峰值达到 28.22。
`alimiter` 在进入场景前控制该输出，样本峰值不超过 `0.97 + 1e-7`。
低幅信号及首尾脉冲保持逐样本恒等。
延迟补偿在 44.1、48、96 kHz 下保留全部采样。
短于 5 ms 的文件也完整输出。
场景内部的有意限幅仍按 Eara 行为验收。
这些结果不代表真峰值或耳机听感验收通过。
热播放边界检查先确认已有 PCM 写入，再触发暂停或跳转。
跳转前实际输出 80,896 帧，跳转后与同库冷起点逐样本相同。
停播重载和销毁重建均保留非空热前缀。
后续的 9,617 帧静音完整输出，没有上一段串音。
场景切换完整输出 163,217 帧，7 条命令均成功。
中性桥保持恒等，连续递推误差低于 `1e-6`。

[Flutter 集成记录](audio-effects-android-flutter.json)来自独立测试包。
该轮 12 个测试组全部通过，包含新增的热边界和场景切换。
热跳转前输出 79,872 帧，跳转后完整输出 48,017 帧。
测试包与生产包分开，运行后已由 Flutter 驱动卸载。
现有服务与设置的 171 个单元和界面基线也已通过。
这些基线不替代迁移后的队列、预加载和系统控制验证。

#### 自适应采样率原型

[自适应图记录](../../tool/audio_effects/fixtures/adaptive-fs-android.json)来自新增 `aselect` 的 Android 自建库。
57 项信号检查全部通过，包含 44.1、48、96 kHz 和非整块末尾。
原型按实际采样率计算全通延迟和 RC 系数。
原型仍未通过实时性能验收。
最重组合的输入为 384,017 帧、4.00018 秒，CPU 耗时为 6.92056 秒。

同一 HLS 中切换采样率的 7 项检查均未通过。
旁路也在输出首段 23,552 帧后超时，没有收到文件结束事件。
Windows 旧库对照也复现了 PCM 输出阻塞。
构建已回移 [mpv 官方重初始化修复](https://github.com/mpv-player/mpv/commit/a7f6460e7eb5995704c8940092c411feb6038932)。
最新 Android arm64 构建已包含修复，未执行设备复测。
Windows 自建库尚未完成该输入的复测。
本轮构建见 [原生构建记录](https://github.com/Shiniester/KikoFlu/actions/runs/42529641501)。
原型说明与复现入口见[自适应采样率原型](../../tool/audio_effects/ADAPTIVE_FS.md)。

#### 适配器契约原型

[参考库记录](audio-backend-reference.json)包含 11 项真实原生契约和 4 项加载单测。
位置快照修复后的 15 项均已通过。
入口为 `tool/audio_backend_contract/reference_test.dart`。
该入口使用 Windows 参考库和真实 FFI，没有构建平台应用插件。
打包的 Windows 应用尚未执行适配器契约。

[Android 适配器记录](audio-backend-android.json)来自自建 ARM64 库和独立测试包。
11 项原生契约通过 9 项，失败 2 项，没有跳过项。
预加载用例中，A 位于 20 秒且已缓冲到 24 秒，但窗口仍只有一个来源。
失败恢复用例也未在 A 播放期间预取 B，随后等待播放推进超时。
两项失败对应的位置读取问题已修复，设备复测未执行。
设备报告在 `latest_wins` 字段处截断。
完整断言结果保存在运行日志中。

服务已改为在一次预加载判断中复用播放位置。
每次读取前进 1 微秒的回归用例在旧代码失败，修复后通过。
全部 19 项预加载单测均通过，Android 设备套件不再重跑。
修复版独立测试包已构建，未在设备运行。

检查覆盖空 SEEKTABLE 的 FLAC、认证请求头、Range 和 16 秒切片。
真实服务验证了预加载、自然切换、手动切换、取消及失败恢复。
缓存查询不能跨加载、跳转或销毁回写状态。
旧缓冲事件也不能覆盖最新的就绪状态。

#### 后端迁移回归

后端迁移已合入 `364e47db`，使用同一音声实例配置输出和增益。
Windows 参考库的 14 项真实契约检查已通过。
检查新增了章节预加载晋升和 Android 音频属性接入回归。
章节来源为 24 秒，范围为第 4～20 秒。
晋升后时长为 16 秒，位置继续推进，且不再次加载来源。
预加载、Android 后端保护和待处理加载的 26 项检查已通过。
`flutter analyze --fatal-infos` 未报告问题。

Android 调试包已通过本机 Gradle 构建。
产物包含 Flutter 支持的 ARMv7、ARM64 和 x86_64 三个 ABI。
原生提供包另包含 x86 库，共 4 个 ABI。
调试包已通过 `zipalign -P 16 -c -v 4` 检查。
调试包未安装到设备。
两阶段音效的本机发布构建已通过。
该本机包使用较早的原生库，不作为最终原生补丁的打包证据。

#### Windows 自建库

Windows 构建采用固定的 llvm-mingw 工具链和上游构建配方。
ExternalProject 模块和模板已固定到内层补丁对应的版本。
LZO 下载地址已改为同一版本的官方来源，保留原归档校验。
地址检查也已通过固定配方的完整检查。
Opus、光盘依赖和 zimg 的源码已固定到兼容的输入。
构建也已接入重初始化和命令参数精度补丁。
graphengine 已迁到官方 GitHub，并固定到 zimg 的子模块提交。
Windows 的 62 个构建 Git 输入已固定到提交。
最近一次[Windows 构建](https://github.com/Shiniester/KikoFlu/actions/runs/42547713301)失败于 libass 的 `checkasm` 工具。
尚无 Windows 自建库的实际输出通过结果。

### 其余平台

iOS、macOS 和 Linux 的实际运行尚未验证。
iOS 和 macOS 的锁定库使用 `libmpv-darwin-build` v0.6.0。
其 `video-default` 配方只启用 `overlay` 和 `equalizer`。
[固定 FFmpeg 配方](https://github.com/media-kit/libmpv-darwin-build/blob/4286f5557bdccc0747030e3c376ce5cd160a96a0/scripts/ffmpeg/meson.build)缺少音效链滤镜。
Apple 自建配方已补齐滤镜，最低应用版本保持不变。
最近一次 [Apple 构建](https://github.com/Shiniester/KikoFlu/actions/runs/42546217679)失败于 libpng 的旧头文件。
SDK 路径和头文件修复已合入，修复后尚未重新编译。

### 未验证项

本轮按确认后的 Android 范围交付。
未执行的检查包括设备上的后台与系统控制、实时性能和耳机试听。
自适应原型的 CPU 耗时超过输入时长，最终处理链未作设备性能复测。
Windows 和 Apple 自建库尚未编译通过。
Linux 应用打包和运行尚未验证。
这些缺口不计作通过结果。

### 复现

#### Android 实际 PCM

以下为已有设备证据的复现方法，本次不再执行。

准备 Android NDK、ADB 和已授权的 ARM64 设备。
把 `ANDROID_NDK_HOME` 指向本机 NDK 目录。
先下载对应版本的公共 C API 头文件，再编译设备工具：

```powershell
New-Item -ItemType Directory -Force build/audio-effects-android
gh api 'repos/mpv-player/mpv/contents/libmpv/client.h?ref=78d43740f52db817d98bcf24fb30a76ab6fa13ff' -H 'Accept: application/vnd.github.raw+json' > build/audio-effects-android/client.h
& "$env:ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android24-clang.cmd" -std=gnu11 -Wall -Wextra -Werror -I build/audio-effects-android scripts/android_audio_effects_runner.c -ldl -o build/audio-effects-android/runner
```

把已构建的 `libmpv.so` 下载到本机，再指定设备运行：

```powershell
python scripts/validate_android_audio_effects.py --serial <设备序列号> --runner build/audio-effects-android/runner --libmpv <libmpv.so路径> --output build/audio-effects-android/result.json
```

ADB 不在 `PATH` 时，使用 `--adb <adb路径>`。
工具只在设备的 `/data/local/tmp/kikoflu-audio-gate` 目录写入测试文件。
HTTP/HLS 的本机测试服务器通过临时 `adb reverse` 映射访问。
原生检查不替代 Flutter 播放器和系统控制验收。

#### Windows 原锁定库

使用项目锁定构建中的 `libmpv-2.dll` 运行原型：

```powershell
python scripts/probe_audio_effects.py --libmpv "<libmpv-2.dll 的路径>" --output build/audio-effects-windows-probe.json
```

原型返回 `1` 表示至少一项处理检查失败。
返回 `2` 表示输入参数、库加载或证据写入失败。
返回 `0` 仅表示原型已覆盖的检查通过。
`gate_status` 保持 `incomplete`，完整验收还包括报告中列出的未验证项。

运行不加载原生库的回归检查：

```powershell
python scripts/test_audio_effects_probe.py
```

该检查已接入现有 CI。

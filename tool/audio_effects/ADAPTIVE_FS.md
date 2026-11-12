# 按实际采样率计算的 lavfi 原型

独立原型在原生图内读取 Fs，计算 Schroeder 延迟和 Eara RC 系数。
原型沿用现有算法，没有替换基线图或生产后端。
当前证据来自 Windows 参考库，`gate_status` 保持 `incomplete`。

## 复现

```text
python tool/audio_effects/adaptive_fs.py --libmpv <libmpv-2.dll> --output build/adaptive-fs/result.json
python tool/audio_effects/adaptive_fs_stream.py --libmpv <libmpv-2.dll> --ffmpeg <ffmpeg.exe> --output build/adaptive-fs/hls/result.json
```

第一个命令验证 57 项真实 PCM 检查。
第二个命令生成自有 AAC HLS，并检查同一文件中的 Fs 变化。
第二个命令当前退出码为 1：不重发参数时，原生格式重建会恢复初始强度。
这个红用例保留在报告中，不能当成通过。

两个命令复用既有 C API 绑定和子进程超时。
PCM、夹具和完整日志写入 `--output` 所在目录。
精简参考结果见 [adaptive-fs-reference.json](fixtures/adaptive-fs-reference.json)。
FFmpeg 只用于生成 HLS 夹具，不参与被测 PCM 处理。

## 原生图

全通级使用递推 `w[n]=x[n]-g*w[n-D]`、`y[n]=g*w[n]+w[n-D]`。
这对应 `H(z)=(g+z^-D)/(1+g*z^-D)`。
三阶延迟仍为 0.7、1.1、1.7 ms，D 使用原有 round 定义。

seed 从实际输入分支生成：

```text
atrim=duration=<有界短片段>,asetnsamples=n=1:p=0,
aselect='lt(n,max(1,floor(sample_rate*ms/1000+.5)))',
aeval=0:c=same,asetnsamples=n=4096:p=0,asetpts=N/SR/TB
```

`aselect` 的 `sample_rate` 是实际输入 Fs。
4096 样本聚合使种子恢复为 D 样本块，反馈不会永久逐样本调度。
负系数通过 `aeval` 相乘；`amix` 只执行无归一的加法。
未填充的原声分支限制最终长度，工作支路单独填充完整块。

Eara 延迟仍按 `floor(Fs*ms/1000)` 计算。
每条长 seed 在 `atrim` 前先用 `asetpts=N/SR/TB` 归零。
这个步骤保留 HLS 格式重建后的全部延迟样本。
三个场景的截止频率、级数、宽度、反馈和混合表达式沿用既有规格。

RC 高通系数为 `s/(s+2*PI*cutoff)`。
RC 低通系数为 `2*PI*cutoff/(s+2*PI*cutoff)`。
表达式在 `n==0` 时缓存系数并清空历史寄存器。
后续样本只计算一阶递推，截止频率和系数限值与原 oracle 相同。

原型只新增 `aselect` 需求；本次没有修改 native allowlist。
其他滤镜均来自现有链，包括 `aeval`、`concat`、`amix` 和 `join`。
[FFmpeg n6.0 文档](https://github.com/FFmpeg/FFmpeg/blob/n6.0/doc/filters.texi)定义了 `aselect` 的输入采样率变量。
滤镜存在与数学可表达，不等于旧版本或打包库验收通过。

## 已取得的证据

参考版本为 mpv `v0.42.0-5-g55d3feb45`、FFmpeg `N-128607-g1ddef7d76`。

- 44.1、48、96 kHz 共 57 项检查通过。
- 全通、完整单声道保护和三场景对照独立递推，误差均小于 `1e-6`。
- 零强度要求逐样本恒等，实际误差为 0。
- 非整块 EOF 保留额外的 17 帧。
- 饱和浴室分别触发 21416、23290、47332 次反馈写入削波。
- 切片与同库已验收图使用同一 `start=.05` 比较，误差为 0。
- 切片保留原生解码预滚语义，没有假定滤镜从目标样本开始计算。
- 同一 handle、同一图依次处理 44100→96000→48000 Hz。
- 原生诊断声道报告三个 Fs，18861 帧完整，历史重置后对上各自 oracle。

HLS 只触发一次 FILE_LOADED，实际输出在第 23552 帧切换至 96 kHz。
总计 72704 帧完整，所有捕获均没有原生错误日志。
全通、完整单声道保护、电话和浴室均对上分段独立递推。
最大误差分别约为 `2.75e-8`、`2.94e-8`、`3.83e-8`、`2.12e-8`。

96 kHz 的一次离线组合测量使用 384017 帧输入。
链为全 EQ +15 dB、单声道最大、limiter 和三个常驻动态场景。
只有电话强度为 1，其他场景为 0。
输出完整且有限，CPU 为 1.96875 秒，墙钟为 2.14949 秒。
这组数据不代表持续播放或 Android 性能验收。

## 参数恢复候选与剩余边界

格式重建会恢复图中写死的初始 target。
HLS 中先把浴室强度从 0 改到 1，96 kHz 段会重新变成 0。
该用例的命令回复为 0，音频递推本身仍正确。

最小接线候选是在原生 audio-reconfig 通知后重发当前强度。
原型读取同一播放器的 `audio-params`，只向命名实例发送 `af-command`。
实例名在旧 FFmpeg 上仍须采用既有的全名→短名兼容规则。
原型不会重建 AF，也不依赖文件 hook 判断实际 Fs。

事件重发的 enqueue 和 reply 均为 0，PCM 没有丢帧。
当前强度最终恢复为 1，输出仍对上独立时变量 oracle。
两次捕获观察到新 Fs 段先处理 1152 或 19456 帧的零强度，再按 20 ms 爬升。
这些捕获使用 `arealtime` 节流。
样本数反映本机测试的处理队列和命令调度，不能推导设备听感延迟上下限。
audio-reconfig 不提供已解码样本位置，也不是阻塞解码的 hook。
接线仍须在实际平台验证连续输出、最终配置恢复和历史清空。

固定 FFmpeg n6.0、Android 新库和打包 Windows 尚未回放本原型。
原基线和其通过状态保持独立；本原型没有推进生产迁移。


## Android 回放入口

Android 回放复用同一 `run` 接口和 oracle。
设备交接后，使用本次源码重新编译的 C runner 和含 `aselect` 的库：

```text
python scripts/validate_android_audio_effects.py --suite adaptive --adb <adb.exe> --serial <device> --runner <new-runner> --libmpv <new-libmpv.so> --output build/adaptive-android/result.json
python scripts/validate_android_audio_effects.py --suite adaptive-hls --adb <adb.exe> --serial <device> --runner <new-runner> --libmpv <new-libmpv.so> --ffmpeg <host-ffmpeg.exe> --output build/adaptive-android/hls/result.json
```

省略 `--suite` 仍运行原 90 项基线。
`--timeout` 仍用于基线；自适应套件沿用各用例原有的时限。

本机 WAV、后续 loadfile/reinit 文件会推送到独立设备目录。
本机 HLS 只推送自有清单与明确引用的 `0.aac`、`1.aac`。
HTTP 地址保持原样，本机 HTTP 继续使用端口反向转发。

`reconfig_actions=((Fs, command),)` 使用既有 action 文件传递事件触发条件。
`on-audio-reconfig` 前缀只是测试元数据，发送原生命令前会剥离。
Python 和 C 捕获都记录实际 Fs、PCM 字节数以及命令尝试和回复。
格式事件重发复用既有命名实例的全名→短名重试。

runner 仍接收原有 14 个进程参数。
新事件元数据需要对应版本的 runner，不能混用旧二进制。
报告记录传入 runner 的完整主机路径。

纯主机检查不使用 ADB 或原生库：

```text
python tool/audio_effects/test_android_capture.py
```

这些检查验证文件映射、事件元数据和回复解析，不是 Android PCM 通过证据。


## Android 固定 n6.0 的检查点

[Android 捕获结果](fixtures/adaptive-fs-android.json)记录 OPD2405、Android 16/API 36、arm64-v8a 的实测。
原生版本为 mpv `v0.36.0-549-g78d43740f5-dirty`、FFmpeg `n6.0`。
此处仍未安装或启动 APK。

新库的原 90 项基线全部通过。
自适应套件在末块修复后完成 57/57 检查。
57 次捕获均在同步关闭 AO 后读取完整 PCM，并对上既定 oracle。
同一 handle 的 44100→96000→48000 Hz 文件切换通过。

n6.0 的末块处理需要保留以下接线：

- 级联 AP 内部不再用冗余 join 限长，原 mid/dry 在外层限制真实长度。
- control 工作支路填充完整块，原 mid/dry 不填充。
- 场景反馈与反射延迟的 concat 输出统一为 128 样本块。
- 静态场景的最终合成使用同权重 join+aeval，由原 dry 驱动。

这些接线保留全通和 Eara 递推。
这些接线避免 n6.0 在尚有尾部数据时处理 EOF，未增加输出帧。
短帧先记为失败，不能把不完整强度数组交给时变量 oracle。
报告逐例保留 END_FILE、超时、AO 关闭和 pull 结果。

最重 96 kHz 组合仍不满足实时性能。
384017 帧输入约为 4.00018 秒，单次离线 CPU 为 6.920557 秒，墙钟为 6.978337 秒。
数学检查通过不能代替这项性能要求。

同文件 HLS 捕获为 0/7，全部在首段 23552 帧后超时。
报告只观察到 44100 Hz，没有 END_FILE，也没有原生错误日志。
两条隔离捕获仍失败：完全去掉 lavfi，以及只保留 anull 且去掉节流。
因此这轮不能评估第二个 Fs 的算法或参数恢复。
隔离结果指向旧核心的 PCM AO 格式重配捕获路径，不能据此判断生产音频输出失败。

官方 [a7f6460 重配修复](https://github.com/mpv-player/mpv/commit/a7f6460e7eb5995704c8940092c411feb6038932)删除旧 AO playing 状态导致的提前返回。
补丁已在固定旧源码副本上通过应用检查。
补丁后的构建与 HLS 实测仍待完成，本检查点没有修改 native 版本或补丁。

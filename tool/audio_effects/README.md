# 原生 PCM 音效验证

验证工具直接加载指定的 libmpv，并检查实际 PCM 输出。
工具复用 `scripts/probe_audio_effects.py` 的 C API 绑定。
每个图在独立子进程中运行；超时或滤镜自动停用均判为失败。
进入 lavfi 前，mpv 的 `format=channels=stereo` 按原始采样格式转换声道。
这使中性图复用与原生旁路相同的混音，避免 FFmpeg 6 的整数混音差异。

## Windows CLI

在仓库根目录运行：

```text
python tool/audio_effects/validate.py --libmpv C:/path/to/libmpv-2.dll --output build/audio-effects/result.json
```

Python 只使用标准库。输出 JSON 记录运行库版本、原生错误和每项数值。
90 项全部通过时退出码为 0，否则为 1。
PCM 和输入 WAV 位于输出目录下的临时目录，结束后删除。

## 检查范围

- 浴室 100%：精确 RC 系数、多抽头、反馈写入削波及末端混合。
- 浴室反馈块：128、1024、4096 样本，与独立参考递推比较。
- 浴室、闷声和电话音：强度 0%、50%、100% 的固定场景递推。
- 三场景动态强度：同一播放实例连续更新，按实际强度逐样本比较。
- 单声道扩宽：44.1、48、96 kHz 的中性、起音、包络和分块。
- 真实单声道 WAV：中性输出与同一库的原生旁路逐样本比较。
- 原始差异分量保留及线性左右合并。
- 正常、交换和两种克隆声道模式。
- 立体声宽度 0、0.5、1、2，以及相同左右输入。
- 10 个 EQ 频段的 −15、+15 dB 与全 0 dB。
- 实际 `af-command` 更新及每样本参数限速。
- 本机 HTTP WAV 和标准 AAC/MPEG-TS HLS 的实际解码与场景输出。
- 暂停恢复、单声道与场景 seek、stop/reload 和销毁重建后的历史重置。
- 三场景经中性桥切换及返回原强度，逐样本检查全部控制量。
- alimiter 的 3 个采样率、低幅恒等、短文件、脉冲时间和关联声道峰值。
- 96 kHz、4 秒的全 EQ +15 dB → 单声道扩宽最大 → 浴室 100% 组合。

组合使用独立的 mpv lavfi 节点，不拼接为一张大型反馈图。
每个节点固定 `o=[threads=1]`，避免滤镜线程调度拖慢小音频块。
场景中的常量增益使用等价 `aeval` 乘法。
这绕过已在 Android FFmpeg 6 组合路径复现的双精度 volume 崩溃。
运行时的具名 volume 控制声道仍保留。
组合热信号检查只验帧数、有限值、输出限制和崩溃，不代表余量或听感通过。

电平控制单独使用 `alimiter=limit=0.97:attack=5:release=50:level=false:latency=true`。
低幅检查要求首尾和脉冲位置逐样本恒等。
热信号的采样峰值上限为 0.97，加 `1e-7` 浮点量化预算。
电平控制位于 EQ、单声道扩宽之后、场景之前。
场景自己的有意削波仍按当前场景参数保留。
该判据不等于过采样真峰值或听感验收。
JSON 的进程 CPU 和 wall 时间包含播放器设置、销毁与日志排空。

场景数值来自 [ADR 0011](../../docs/adr/0011-asmr-audio-preset-tuning.md) 的 KikoFlu ASMR 调音。
[Eara 场景参数](https://github.com/eValDoll/EaraAsmrPlayer/blob/3918b196390011b0fccbab59e3489f72e96c92e9/app/src/main/java/com/asmr/player/data/settings/SceneEffectPresets.kt)保留为历史和结构参考。
均衡器的 `fixtures/eq-octave-reference.json` 记录 ADR 0011 之前的 Eara 曲线；当前曲线以 `adaptive_eq.py` 为准。
参考递推用于检验输出，不替代原生 DSP。
全通、瞬态和包络的参数仍是原型起点。

HTTP/HLS 使用本机临时服务器，不访问外部媒体。
HLS 为自有合成信号，包含 3 个 TS 分片。
AAC 的 49152 个解码帧包含编码器预热和填充。
音效输出与同一库的解码旁路比较，不要求与编码前 WAV 恒等。
正常验证不需要 FFmpeg 可执行文件。
重建 HLS 夹具时使用 `generate_hls.py --ffmpeg <路径>`。
生成器版本与来源记录在 `fixtures/hls/fixture.json`。

播放边界使用同一库的新建上下文作参考。
边界动作在 PCM 文件首次含有字节后开始计时，JSON 记录锚点字节数。
3 秒热信号跳转至第 2 秒，跳转前必须捕获大于 0 且小于 96000 帧的正确前缀。
暂停命令必须在 EOF 前得到确认。
暂停恢复要求完整输出逐样本相同。
seek 与相同原生起点的输出比较，保留解码器预读行为。
stop/reload 和销毁重建必须先输出正确的热信号前缀，再输出完整的 9617 帧静音。
静音不能残留前一段反射。
这些检查不覆盖应用队列、预加载、后台和系统控制。

场景切换原型常驻 3 个独立动态节点。
零强度节点跳过当前样本的参数树，仍更新滤波和反射历史。
旧场景回到 0 后，下一个节点再平滑升到目标强度。
第 3～5 个诊断声道记录三场景的实际强度，前两个声道仍是音频。
独立递推检查完整级联，中性桥要求逐样本恒等。
诊断封装只填充声音工作支路，未填充的历史支路限制最终长度，避免 FFmpeg 6 丢弃末块。
模式信号在最后命令后保留 1.3 秒音频，并保留非整块文件尾，以检查控制更新和完整输出。
该检查不代表应用已经保存各模式设置，也不代表常驻节点的设备 CPU 已验收。

## 数值判据

原生输出为 float32。受控幅度下，递推误差预算为 `1e-6`。
中性检查要求逐样本恒等；线性合成和分块预算为 `1e-7`。
真实单声道的每耳增益由同一库的旁路输出测量。
测试不强制把单声道按 1.0 增益复制到两耳。
EQ 用 0.5 秒预热、1 秒整数周期测量窗口。
中心增益误差预算为 0.03 dB。
相邻八度的增益绝对值必须低于中心至少 1 dB。
该判据同时检查增益与频率选择性。
起音检查要求该固定信号的处理支路峰值减少 90%。
原声停止 30 ms 后，处理输出低于 `1e-5`，即 −100 dBFS。
后两项仅为原型回归判据，不代表已经通过耳机听感验收。
参数控制按 20 ms 全幅限速，每样本上限为 `1/(Fs*.02)`。
命令先匹配完整滤镜实例名。
仅在返回 −12 时，重试 `@` 后的明确实例名。
这兼容 FFmpeg 6 的实例命名，不向全部 volume 滤镜广播。
JSON 记录每次尝试的目标和结果。
动态场景由同一图的第 3 个诊断声道带出原生强度。
前 2 个声道仍是实际音效输出。
参考递推据此检查当前宽度、反馈、各混合比例和电话软削波。
诊断强度与音频属于同一采样时刻，不从命令发送时间推算。
额外检查固定 100% 结果的淡入模型与原生输出存在至少 `1e-3` 差异。

## Android 和 Windows 集成测试

测试仅创建独立的 media-kit Player，不改变音声后端。
测试在设备临时目录生成 WAV，并通过原生 PCM AO 捕获输出。
固定图编入测试代码，不需要账号或生产 assets。

使用当前打包的原生库：

```text
flutter test -d <device-id> integration_test/audio_effects_native_test.dart
```

在 Windows 指定参考库：

```text
flutter test -d windows integration_test/audio_effects_native_test.dart --dart-define=KIKOFLU_AUDIO_LIBMPV=C:/path/to/libmpv-2.dll
```

Android 测试必须使用独立 applicationId，不能覆盖已安装的正式应用。
设备打包配置由项目原生构建流程提供，不通过修改 pub-cache 接入。
测试包含 EQ、声道模式、立体声扩宽和浴室饱和递推。
单声道保护覆盖 3 个采样率。
设备入口也包含三场景动态强度。
单声道扩宽的已有差异分量检查目前仍在 Python CLI。

修改 Python 原型图后，重建测试图：

```text
python tool/audio_effects/generate_dart.py
dart format integration_test/audio_effects_native_graphs.dart
```

## 验证边界

`gate_status` 始终为 `incomplete`。
通过本工具不代表统一后端迁移已经获准。
项目自建库和 Android 必须分别运行相同信号检查。
尚缺应用模式设置持久化、队列、预加载、后台和系统控制检查。
CPU、组合音效的输出余量和耳机听感也需单独验收。
测试专用 `arealtime` 只为离线 PCM 捕获期间发送命令，不进入生产图。

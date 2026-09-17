# Android 播放器性能验证

此场景使用真实 Mini Player、`AudioPlayerPageRoute`、横向页面和字幕组件。
音频使用 Android 的 just_audio / Media3 实现；本地文件清单独立于服务器账号。
工具和生产应用沿用仓库锁定的 Flutter、just_audio、Media3 版本。

## 准备

构建前确认 USB 设备、可用空间和原始素材。测试包名为
`com.meteor.kikoeruflutter`；同包名已有安装时，测试会修改其播放队列和缓存，
应使用专用测试安装。测试不会修改素材原文件。

```powershell
fvm flutter build apk --profile --no-pub `
  --target integration_test/player_profile_test.dart `
  --dart-define=KIKOFLU_PERFORMANCE=true --target-platform android-arm64
adb -s <device> install -r build/app/outputs/flutter-apk/app-profile.apk
```

设备素材目录：
`/sdcard/Android/data/com.meteor.kikoeruflutter/files/player_performance/fixtures`。
将 `manifest.json` 与素材放在这个目录。清单中的相对路径基于清单目录解析，
绝对路径可直接指向已获授权的设备音频。公共报告使用匿名 `id/title`，
真实文件路径清单保存在被忽略的 `build/` 下。

清单前四项依次放大 WAV、大 FLAC、完整缓存 WAV、完整缓存 FLAC，
后面放三首不同的小文件；正确性场景按这个固定顺序运行。
`hash` 是现有缓存条目的标识，不对文件增加校验或内容哈希。

```json
{
  "fixtureVersion": 1,
  "tracks": [
    {"id":"large-wav","title":"WAV","path":"大音频_测试.wav","mode":"downloaded","sizeClass":"large"},
    {"id":"user-flac","title":"FLAC","path":"日本語の音声.flac","mode":"downloaded","sizeClass":"large"},
    {"id":"cache-wav","title":"WAV cache","path":"大音频_测试.wav","mode":"cache","hash":"profile-wav","sizeClass":"large"},
    {"id":"user-cache-flac","title":"FLAC cache","path":"日本語の音声.flac","mode":"cache","hash":"profile-flac","sizeClass":"large"},
    {"id":"small-a","title":"A","path":"small_a.wav","mode":"downloaded","sizeClass":"small"},
    {"id":"small-b","title":"B","path":"small_b.wav","mode":"downloaded","sizeClass":"small"},
    {"id":"small-c","title":"C","path":"small_c.wav","mode":"downloaded","sizeClass":"small"}
  ]
}
```

素材至少覆盖 512MiB WAV、数百 MiB FLAC、中文/日文文件名和同名字幕。
清单的缓存项会在计时前创建完整缓存；要预留两份大文件的缓存空间。
复用同一批素材，基线与候选都运行同一份测量代码。

## 运行

以下脚本只需要 Python 标准库与 PATH 中的 adb。每轮重新启动进程，
要求开始时 thermal status 不高于 2。记录设备状态，保持音频触感反馈关闭；
场景内不改变显示模式、亮度或系统动画倍率。

```powershell
python tool/performance/run_player_profile.py baseline --device <device> --no-audio
python tool/performance/run_player_profile.py candidate --device <device> --no-audio
python tool/performance/run_player_profile.py baseline_audio --device <device> --no-ui
python tool/performance/run_player_profile.py candidate_audio --device <device> --no-ui
python tool/performance/run_player_profile.py candidate_stop --device <device> --no-ui --stop
python tool/performance/run_player_profile.py candidate_checks --device <device> `
  --rounds 1 --no-ui --races --audio-repeats 4 --soak 120 --soak-index 1
python tool/performance/summarize_player_profile.py baseline candidate baseline_audio candidate_audio candidate_stop `
  --output build/player_performance/summary.json
```

四轮音频循环与取消用例合计超过 50 次实际源切换；当前曲目重复选择不计换源。
`--races` 在大文件加载中连续请求
A/B/C，校验最终曲目、发布事件、错误和完整缓存是否保留。连续播放期间另做实听，
记录有无断音、旧曲目短暂恢复以及声道或音量变化。

## 计时口径

- 每个 UI 场景从 Android 当前 Display 查询刷新率，以 `1000 / Hz` 计算预算。
  某些自适应刷新率设备的 Flutter Display 仍保留启动时数值，因此不能仅使用该值。
- 分别记录 UI、raster 和 `max(UI, raster)` 的 P95；卡顿帧使用后者超过预算判断。
  `totalSpan` 单独保留，不当作线程工作耗时。延后送达的 FrameTiming 按帧时间归属场景。
- 汇总表的 UI 数字是五个单轮 P95 的中位数，同时保留最差单轮 P95 和合并卡顿比例。
  原始 `frameSamples` 可用于重新统计；冷进程首次展开与重复展开分别报告。
- 音频阶段包含请求、源准备、`setFilePath`、READY 和进度流首次推进。
  `setFilePath` 是原生换源聚合时间，未进一步拆解解码器内部阶段。
- `switchSamples` 测量稳定播放 700ms 后离开旧文件，到目标曲目发布、READY、
  playing 且进度流推进的时间。显式停止方案把 `stop()` 也算在这个总时间里。
  just_audio 的位置包含时间外推，不等价于扬声器首个音频采样；25ms 检查周期也会引入量化误差。
- 每种离开场景五轮共 10 个样本，当前 P95 算法为 `ceil((n-1)*0.95)`，
  在 n=10 时等于最大值。取消请求标记 incomplete，不混入正常加载统计。

## 验收与回归

保留原黄金图。新增 `player_transition_frames_test.dart` 的七张图取自
v4.4.16，覆盖展开、部分切页、拖拽反向和交接。检查 Hero、字幕、手势、
响应式布局与连续请求测试；旧基线本来失败的测试需单列并比较前后实际输出。

动画 UI/raster P95 达到设备预算或改善至少 25%；已达预算的场景回退不超过 5%，
卡顿比例不增加。大文件切换中位数/P95 改善至少 25%。显式停止策略只有大文件
两项均改善 25%、小文件回退不超过 5% 才采用。测量未达门槛时直接记录结果。

本次实测与限制见 [播放器性能报告](player-performance-results.md)。

# Android 播放器性能验证

此场景使用真实 Mini Player、`AudioPlayerPageRoute`、横向页面和字幕组件。
音频使用 Android 的 just_audio / Media3 实现；本地文件清单独立于服务器账号。
工具和生产应用沿用仓库锁定的 Flutter、just_audio、Media3 版本。
Android 的 Media3 固定为 1.8.0，包含空 FLAC seek table 的上游修复。

## 准备

需要保留手机上的正式版、仅验证播放器打开交互时，使用
[独立 Debug 真机回归流程](android-device-testing.md)。该流程的 Debug 帧耗时
不用于本页的 Profile 性能验收。Profile 包名默认是正式包名；建议使用独立的
测试包名，避免替换设备上的正式安装。

构建前确认 USB 设备、可用空间和原始素材。默认包名为
`com.meteor.kikoeruflutter`。报告目录中的包名可通过 Dart define 覆盖；运行脚本的
`--package` 必须传入同一个 application id。入口 Activity 使用完整类名
`com.meteor.kikoeruflutter.MainActivity`。

```powershell
fvm flutter build apk --profile --no-pub `
  --target integration_test/player_profile_test.dart `
  --dart-define=KIKOFLU_PERFORMANCE=true --target-platform android-arm64
adb -s <device> install -r build/app/outputs/flutter-apk/app-profile.apk
```

独立包在临时 Gradle init script 中设置 Profile 后缀和测试签名，不修改正式
构建配置。Dart define 只设置报告目录，不能单独改变 Android 包名：

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$profileInit = Join-Path (Get-Location) 'build/player-profile-isolation.gradle'
@'
gradle.beforeProject { project ->
    project.pluginManager.withPlugin('com.android.application') {
        project.extensions.getByName('androidComponents').finalizeDsl { android ->
            android.buildTypes.named('profile') {
                applicationIdSuffix = '.profile'
                signingConfig = android.signingConfigs.getByName('debug')
            }
        }
    }
}
'@ | Set-Content -LiteralPath $profileInit -Encoding utf8
$profileDefines = @(
  'KIKOFLU_PERFORMANCE=true',
  'KIKOFLU_PROFILE_PACKAGE=com.meteor.kikoeruflutter.profile'
) | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }
Push-Location android
try {
  .\gradlew.bat --init-script $profileInit `
    -Ptarget=../integration_test/player_profile_test.dart `
    -Ptarget-platform=android-arm64 "-Pdart-defines=$($profileDefines -join ',')" `
    -Ptrack-widget-creation=false -Ptree-shake-icons=false assembleProfile
} finally { Pop-Location }
adb -s <device> install -r build/app/outputs/flutter-apk/app-profile.apk
python tool/performance/run_player_profile.py baseline `
  --device <device> --package com.meteor.kikoeruflutter.profile --no-audio
```

设备素材目录为
`/sdcard/Android/data/<profile-package>/files/player_performance/fixtures`。
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
FLAC 必须包含一个长度为 0 的 SEEKTABLE 元数据块（type 3），以覆盖
[Media3 #2327](https://github.com/androidx/media/issues/2327)；保留原始元数据，
不能只用重新编码或移除该块的文件代替。真机解析与播放不能由 Fake 契约测试替代。
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
python tool/performance/run_player_profile.py candidate_seeks --device <device> `
  --rounds 1 --no-ui --seeks
python tool/performance/run_player_profile.py candidate_handoff --device <device> `
  --rounds 1 --no-audio --continuous-handoff
python tool/performance/summarize_player_profile.py baseline candidate baseline_audio candidate_audio candidate_stop `
  --output build/player_performance/summary.json
```

独立包的运行命令均传入 `--package com.meteor.kikoeruflutter.profile`，与构建时的
`KIKOFLU_PROFILE_PACKAGE` 一致。内部分页使用固定 40 项可滚动假队列，
`--no-audio` 无需外部素材。快速切歌使用无在线作品 ID 的本地轨道，避免作品详情
缓存或网络加载与随后分页场景重叠。`queuePageSwitch` 测量队列按钮进入及 Escape 返回；
`queueEdgeHandoff` 从队列列表顶端下拉，等待原生分页完成吸附后再打开队列。
基线与候选使用同一份测量代码，各采集五轮。

`--continuous-handoff` 仅用于候选：从队列中段开始，在同一次手势中越过列表
边缘、反向拖回原分页，再验证剩余位移交回同一列表。单独采集其
`queueContinuousHandoff` 场景及检查，不混入共同场景的五轮对比。
汇总器默认要求第 1–5 轮完整报告，按 `--start`、`--rounds` 指定其他轮次；
缺失报告、场景或交接检查会失败，避免诊断轮次混入正式结果。

四轮音频循环与取消用例合计超过 50 次实际源切换；当前曲目重复选择不计换源。
`--races` 在大文件加载中连续请求
A/B/C，校验最终曲目、发布事件、错误和完整缓存是否保留。连续播放期间另做实听，
记录有无断音、旧曲目短暂恢复以及声道或音量变化。

`--seeks` 挂载真实播放状态、Mini Player 和播放器路由，对每个大文件（含完整缓存）
在正常播放后拖动实际进度条，依次跳到 25%、80%、10%。记录从手势开始到目标
位置后至少推进 500ms 的时间（`positionAdvancingMs`）、状态变化、诊断错误和
随后一秒的位置推进。该耗时包含手势与推进等待，不与直接调用 seek 的返回时间
混用。位置由 just_audio 外推，状态与进度通过仍需原生音频输出检查及实听确认。
跳转失败会令脚本退出；该场景与切歌、连续播放分别验收。

## 计时口径

只检查封面、音频详情、字幕之间的横向切换时，使用分阶段模式：

```powershell
python tool/performance/run_player_profile.py baseline_horizontal `
  --device <device> --package <baseline-package> --no-audio --horizontal-only
python tool/performance/run_player_profile.py candidate_horizontal `
  --device <device> --package <candidate-package> --no-audio --horizontal-only
python tool/performance/summarize_player_profile.py baseline_horizontal candidate_horizontal `
  --horizontal-only --output build/player_performance/horizontal_summary.json
```

两组均构建同一 `integration_test/player_profile_test.dart`。四个循环依次执行
封面→字幕→封面→音频详情→封面；每次拖动分为 12 个 25px 位移，每步
`pump(16ms)`，松手后 `pump(400ms)`。每次拖动及松手使用独立计时窗口，
汇总器合并窗口内的原始帧后计算该轮 P95，再取五轮中位数；缺少任一窗口
会失败。`pageSwitch` 为两个阶段合计，`pageDrag`、`pageRelease` 为阶段统计。
该模式不包含其他 UI 场景；省略参数仍执行原始完整场景。

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

## 内部分页交互契约

窄屏横向页为音频详情、封面、字幕，默认封面；纵向页为播放器主体、队列。
宽屏左栏为音频详情、封面，右栏横向为控制、字幕，纵向为控制／字幕区域、
队列。左右栏独立，队列期间的左栏操作及滚动位置保留。

点击统一使用 `PageController.animateToPage`，时长 300ms、曲线
`Curves.easeOutCubic`；减少动态效果时直接定位。拖动和松手使用默认
`PageView` 物理及原始松手速度。播放器路由关闭及切歌视觉继续使用原有行为。

详情、完整字幕、宽屏控制和队列列表保持 Clamping 滚动。播放器专用控制器
包装内层真实 `Drag`，通过公开的 `ScrollPosition.drag` 交接给纵向分页：列表
先消费，到边缘仅转发剩余位移；反向先回到原页，再把剩余位移交回原列表。
当前所有者收到原始结束事件，另一方取消；指针取消、活动替换、尺寸变化和
销毁均清理两条拖动。自动滚动和惯性到边缘不触发分页。

标题、封面和操作栏由单一纵向识别器区分上滑分页与下拉关闭。进度条优先
处理横向拖动，队列长按排序保留；宽屏左栏不参与右栏纵向交接。普通队列
下拉只返回原分页，同一手势不会继续关闭路由；直接队列入口保留关闭播放器
行为。

尺寸变化时，点击过渡保留最新目标，手势保留占比最大的页面，恰好各半时
保留该次拖动的原页；清理拖动后立即定位，并恢复列表偏移。页面按需挂载、
保持状态，不可见页停用 ticker。队列挂载后的切换仅更新相关区域。

## 验收与回归

保留原黄金图。新增 `player_transition_frames_test.dart` 的七张图取自
v4.4.16，覆盖展开、部分切页、拖拽反向和交接。检查 Hero、字幕、手势、
响应式布局与连续请求测试；旧基线本来失败的测试需单列并比较前后实际输出。

动画 UI/raster P95 达到设备预算或改善至少 25%；已达预算的场景回退不超过 5%，
卡顿比例不增加。大文件切换中位数/P95 改善至少 25%。显式停止策略只有大文件
两项均改善 25%、小文件回退不超过 5% 才采用。测量未达门槛时直接记录结果。

Android 本地文件 seek 监听原生错误事件；错误或等待超过 8 秒时，由现有请求
协调器停止旧原生实例，并以 `initialPosition` 重载当前音源一次。同位置或已到
文件末尾且状态匹配的跳转允许没有 READY 回调。恢复不重新发布曲目，不删除
完整缓存；正常完成的 seek 不换源。暂停、停止和新曲目选择始终保留最终意图。
错误订阅在 seek 返回后继续有效；晚到的错误会暂停失效音源并保留位置，再次
播放时从该位置重新准备原音源。换曲、停止和清空会清除旧 seek 的错误归属。

恢复的原生停止、重新准备和取消清理各有 8 秒等待上限。准备超时会实际调用
`stop()`，等待原始停止和加载 Future 都结束后才允许新音源开始；清理超时
返回失败并释放加载状态，但保留原始屏障，后续请求也只能有界等待，不能穿过
尚未完成的原生清理。失败保留完整缓存和重试位置，不循环重试。
Profile seek 场景的外层上限为 35 秒，覆盖 seek 及恢复各阶段的等待预算。

本机契约回归：

```powershell
flutter test --no-pub test/audio_player_seek_recovery_test.dart `
  test/audio_player_latest_request_test.dart test/android_audio_backend_guard_test.dart `
  test/playback_session_restore_failure_test.dart test/playback_history_service_test.dart `
  test/playback_session_store_test.dart
```

本次实测与限制见 [播放器性能报告](player-performance-results.md)。

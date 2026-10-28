# Android 浏览器媒体转发确认等待实验

Android 真机完成了 9 次受控传输和 9 次播放。
附加确认等待增加了完整传输耗时。
3 组首帧中位数没有呈现递增趋势。
4.04 秒素材均未发生播放中再缓冲。
当前结果不能确定源站首帧慢和缓冲的原因。

## 在线播放路由

成功连接视频源验证会话后，在线播放经过浏览器转发。
[验证会话](../../lib/src/videos/missav_verification.dart)把媒体地址绑定到 `MissavMediaServer.register`。
[源客户端](../../lib/src/videos/missav_client.dart)随后将播放地址改写为 `127.0.0.1`。

[视频客户端配置](../../lib/src/videos/video_providers.dart)会恢复已保存的浏览器会话。
在线请求发现已有 Cookie、但尚未绑定浏览器时，会先恢复会话。
未绑定媒体转发时，详情保留远端播放地址。
验证会话与视频源账号登录是两件事。

已有客户端回归验证了地址切换：

- 绑定验证浏览器后，两个视频流均使用 `127.0.0.1`。
- 调用 `restoreNativeTransport()` 后，两个视频流恢复为远端地址。

这些路由条件针对当前工作区代码。
真机 Beta 的连接观察与该路径一致，证据见下文。

## 受控传输结果

测量日期为 2026-10-27。
环境为 Android 16、API 36、x86_64 模拟器。
测试使用独立 Debug 包与主机 GPU 模式。

媒体数据来自工作区已有的 `build/video-player-fixture.mp4`。
素材共 1,293,015 字节，时长约 4.04 秒。
浏览器中的测试 `fetch` 返回固定素材，排除了媒体源站的网络波动。
传送仍经过生产浏览器转发和本机 HTTP 转发。

每次完整读取均收到 20 块数据和 20 个确认。
单块上限为 65,536 字节。
实验只给确认脚本增加延迟，未给请求或取消脚本增加延迟。
一次传输热身不计入结果。
三轮按 `0/10/30`、`10/30/0`、`30/0/10` 毫秒轮换顺序。

| 每块附加等待（毫秒） | 样本数 | 传输中位数（毫秒） | 范围（毫秒） | 中位吞吐（MiB/s） |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 3 | 241.0 | 230.2–264.3 | 5.12 |
| 10 | 3 | 444.3 | 422.3–479.6 | 2.78 |
| 30 | 3 | 810.7 | 805.7–828.2 | 1.52 |

`30` 毫秒组比基线多 `569.672` 毫秒。
20 块数据之间有 19 次确认等待。
`19 × 30 = 570` 毫秒，与本次观察的增量相近。
这支持确认等待会逐次累加到传输耗时的判断。

原始传输耗时如下，单位为毫秒：

| 轮次 | 0 毫秒 | 10 毫秒 | 30 毫秒 |
| ---: | ---: | ---: | ---: |
| 1 | 264.276 | 479.636 | 810.655 |
| 2 | 230.170 | 444.344 | 805.733 |
| 3 | 240.983 | 422.329 | 828.232 |

`transferMs` 在完整 HTTP 响应体收齐时结束。
测试随后等待尾块确认，再核对字节和确认数。
`ackWaitTotalMs` 累加各块从收块到确认脚本返回的区间。
这些区间可以重叠，不能当作关键路径耗时或纯往返时间。

## 模拟器首帧和再缓冲结果

视频阶段未通过。
不附加确认延迟的热身用例，在 45 秒内未观察到非黑视频像素。
模拟器活动帧截图也为黑色。

该次播放状态报告如下：

- 末次进度为 3,782 毫秒，总时长为 4,037 毫秒。
- `completed=true`，`playing=false`，没有播放器错误状态。
- 默认视频输出创建 EGL context 时，日志出现 `EGL_BAD_ATTRIBUTE`。

Android 视频控制器的 `waitUntilFirstFrameRendered` 只确认输出表面设置。
实验将这个信号单列为 `surfaceReadyMs`。
可见画面另用黑底上的非黑像素采样判断。
采样间隔为 25 毫秒，读图也会增加观测延迟。

再缓冲使用原生 `paused-for-cache` 事件。
统计区间从可见画面和播放请求均出现后开始，到播放结束为止。
该属性表示因等待缓存而暂停，见 [mpv 属性说明](https://mpv.io/manual/stable/#property-list)。
实验没有用复合 `buffering` 状态代替缓存暂停。

输出记录保留 `transferStatus=complete` 和 `videoStatus=failed`。
所有未完成的播放指标均为 `null`。
测试重新抛出视频失败，驱动退出码为 `1`。
失败导出不会把测试标为通过。

## 真机受控结果

真机视频阶段通过，9 次播放均出现可见画面并播放结束。
设备为 ABR-AL60，系统为 Android 12，架构为 arm64。
WebView 提供程序为 Huawei WebView 114.0.5.302。
测量日期为 2026-10-27。
Debug 实验包沿用生产默认视频输出。

素材、分组顺序和热身规则与模拟器实验相同。
9 次完整 GET 均收到 1,293,015 字节、20 块和 20 次确认。
`transferStatus` 和 `videoStatus` 均为 `complete`，驱动退出码为 `0`。

| 每块附加等待（毫秒） | 样本数 | 完整传输中位数（毫秒） | 可见首帧中位数（毫秒） | 首帧范围（毫秒） | 再缓冲总次数 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 3 | 515.688 | 702.409 | 619.492–752.479 | 0 |
| 10 | 3 | 723.178 | 733.639 | 684.581–766.664 | 0 |
| 30 | 3 | 1,249.559 | 637.977 | 583.433–713.916 | 0 |

附加等待增加时，完整传输中位数增加。
首帧中位数没有呈现相同趋势，不能据此宣称首帧收益。
4.04 秒本地素材没有覆盖长视频和源站网络波动。
本轮没有复现用户报告的频繁再缓冲。

`firstVisibleFrameMs` 从 `loadStream` 前计时。
浏览器准备、详情解析和详情转场发生在计时区间外。
该指标不能代表点击卡片或播放按钮后的完整等待。

`playbackBytes` 累加播放期间收到的全部桥接块。
该值不是播放器消费的去重字节，不能据此计算有效吞吐率。
本轮播放接收量为素材的 1.25–2.00 倍。
7 次播放的确认数比收块数少 1。
这些现象与重复 Range 读取和请求取消相符。
本轮没有逐请求记录，不能确定每次差额的原因。
确认数在调用确认脚本前增加，不表示已经收到 JavaScript 确认。

## 真机源站连接观察

Beta 版打开在线视频后，产生了应用自身的本机连接。
观察对象为 `com.meteor.kikoeruflutter.beta`，版本为 `5.0.1-beta.29`。
源站样本编号为 `SDDE-771`。

播放前，应用 UID `11420` 已监听 `127.0.0.1:41381`。
打开视频后，同一 UID 的两个端点连接到该端口。
连续 6 次采样观察到接收队列变化，单个队列约含 2 MiB 数据。
这些连接没有使用手机网络代理的 `7890` 端口。

该证据支持播放器读取本机转发服务。
结合源码，可推断该路径与浏览器媒体转发一致。
Beta 未开放 Dart VM 和 WebView 调试接口。
已有进程日志没有提供媒体地址。
本轮未直接读取 Beta 播放 URL、JavaScript 块大小和确认耗时。

### 工作区源站用例

手动验证改用 `lib/main.dart` 的普通 Debug 应用。
真机已显示音声、漫画、视频和设置页签。
MissAV 账号页显示原有登录状态。
实际播放和源站首帧、再缓冲仍需继续验证。

点击“检查访问”后的测试容器结果已从原进程读取：

```text
LiveTestWidgetsFlutterBinding.pump
'inTest': is not true
```

断言注明发生在用例完成后，记录保存在 `manual-result.log`。
该记录不能确认源站验证、媒体获取或解码是否通过。
普通应用入口不运行 `testWidgets`，没有该用例的结束页和 5 分钟时限。
应用自身的网络请求仍有超时限制。

此前的源站尝试在会话连接后，两次记录了以下状态：

```text
sourceReady=true
browserSessionConnected=true
MissAV browser navigation failed (receiveTimeout).
```

异常由 `client.details(video)` 的浏览器详情导航抛出。
该等待的上限为 30 秒，包含共享队列、导航、HTML 读取和浏览器复位。
这两次未取得播放地址，也未执行媒体获取和解码检查。
该失败发生在媒体传输之前，不能归因于逐块确认等待。
仅凭这个错误，不能确定源站响应、页面验证或复位中的哪个步骤超时。

自动源站用例按首页视频时长选择样本，未固定为 Beta 观察样本。
自动用例的客户端凭据使用内存存储，不读取或覆盖安全存储中的值。
普通应用使用安装包中原有的数据和登录会话。

## 结论与限制

本实验验证了附加确认等待对传送时间的影响。
本实验没有测量移除确认等待后的提速幅度。
受控首帧已在真机测得，未发现随附加等待增加而变慢的趋势。
实际源站的首帧、再缓冲和手机卡顿根因仍未验证。

本轮固定数据块最多为 64 KiB。
真实浏览器的 `reader.read()` 可能返回更小的数据块。
每次返回的数据都会等待确认，实际确认频率需要另测。
当前数据不足以选择多块同时在途的窗口大小。

下一步需要记录源站真实块大小、块间等待、可见画面和缓存暂停。
源站用例需先定位浏览器详情导航超时。
冷启动测量还需覆盖卡片和播放按钮两个入口。
替代视频输出的结果不能代表生产默认输出。

## 复现

以下命令在仓库根目录的 PowerShell 执行。
需要 Flutter 3.44.7 和 Android 工具链。
环境准备见 [Windows Android 开发](windows-android.md)。
素材保存在本机 `build/`，不随仓库提交。
更换素材或设备后，需要重新采集基线。

1. 构建实验包。

   ```powershell
   $deviceId = '<设备编号>'
   $env:NO_PROXY = '127.0.0.1,localhost,::1'
   $env:CI = 'true'
   flutter --suppress-analytics build apk --debug --no-pub `
     --target=integration_test/video_relay_profile_test.dart `
     --target-platform=android-arm64 `
     --dart-define=KIKOFLU_TEST_VIDEO=/data/user/0/com.meteor.kikoeruflutter.debug/files/video-relay-fixture.mp4
   ```

   设备编号来自 `adb devices -l`。
   使用 x64 模拟器时，将目标架构改为 `android-x64`。

2. 核验并安装本次 APK。

   `ANDROID_HOME` 需要指向 Android SDK 目录。

   ```powershell
   $apk = 'build/app/outputs/flutter-apk/app-debug.apk'
   $aapt = Join-Path $env:ANDROID_HOME 'build-tools/36.0.0/aapt.exe'
   $badging = & $aapt dump badging $apk
   if ($LASTEXITCODE -ne 0 -or
       -not ($badging -match "^package: name='com\.meteor\.kikoeruflutter\.debug'") -or
       -not ($badging -match '^application-debuggable')) {
     throw 'APK 不是独立 Debug 包'
   }
   adb -s $deviceId install -r -t $apk
   ```

   手机弹出安装确认或身份验证时，在手机上完成确认。

3. 将素材按二进制复制到 Debug 应用私有目录。

   ```powershell
   adb -s $deviceId push build/video-player-fixture.mp4 /data/local/tmp/kikoflu-relay-fixture.mp4
   if ($LASTEXITCODE -ne 0) { throw '素材上传失败' }
   adb -s $deviceId shell run-as com.meteor.kikoeruflutter.debug mkdir -p files
   adb -s $deviceId shell run-as com.meteor.kikoeruflutter.debug cp `
     /data/local/tmp/kikoflu-relay-fixture.mp4 files/video-relay-fixture.mp4
   if ($LASTEXITCODE -ne 0) { throw '素材复制失败' }
   $size = adb -s $deviceId shell run-as com.meteor.kikoeruflutter.debug `
     wc -c files/video-relay-fixture.mp4
   if ([long]($size -split '\s+')[0] -ne
       (Get-Item build/video-player-fixture.mp4).Length) {
     throw '素材字节数不匹配'
   }
   ```

4. 运行实验并保存原始报告。

   ```powershell
   New-Item -ItemType Directory -Force build/diagnostics/video-relay-experiment | Out-Null
   $env:KIKOFLU_PERF_RUN_OUTPUT = Join-Path (Get-Location) `
     'build/diagnostics/video-relay-experiment/run.json'
   flutter --suppress-analytics drive --debug --no-pub -d $deviceId `
     --driver=test_driver/video_relay_profile_driver.dart `
     --target=integration_test/video_relay_profile_test.dart `
     --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk
   ```

   驱动会保留失败数据。
   同时检查命令退出码、`transferStatus` 和 `videoStatus`。
   JSON 文件存在不表示整项实验通过。

### 手动验证源站

手动验证使用普通应用，不启动集成测试驱动。

```powershell
flutter --suppress-analytics build apk --debug --no-pub `
  --target=lib/main.dart `
  --target-platform=android-arm64
```

按前文核验并安装 Debug APK，然后从手机启动 KikoFlu Debug。
打开视频页，选择实际出现卡顿的视频并播放。
需要源站验证时，在网页完成验证后点“检查访问”。

### 自动源站用例

仓库另有 Android 源站用例，可检查本机媒体地址、响应和解码。
该用例会先探测媒体地址，不能用于测量冷启动首帧。
客户端凭据使用内存存储，保留 Debug 应用安全存储中的值。
用例已开启真实触摸，页面需要人机验证时可在手机上操作。

```powershell
flutter --suppress-analytics build apk --debug --no-pub `
  --target=integration_test/missav_android_media_relay_live_test.dart `
  --target-platform=android-arm64 `
  --dart-define=KIKOFLU_LIVE_MISSAV=true
flutter --suppress-analytics drive --debug --no-pub -d $deviceId `
  --driver=test_driver/video_player_driver.dart `
  --target=integration_test/missav_android_media_relay_live_test.dart `
  --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk
```

自动用例的总时限为 3 分钟。
自动用例不适合长时间手动验收。

## 验证记录

- 浏览器媒体转发和本机转发的 19 项回归通过。
- 验证会话与直连地址切换的 1 项客户端回归通过。
- 实验文件和导出器的静态分析通过。
- Android x64 Debug 构建通过，包名和调试标记核验通过。
- 模拟器的 9 次受控完整传输均通过字节、块数和确认数检查。
- 模拟器视频热身失败，未取得播放指标。
- Android arm64 Debug 构建通过，包名、调试标记和架构核验通过。
- 真机的 9 次完整传输和 9 次播放通过。
- 真机数据和测量结论已由只读评审者核查。
- 源站尝试在会话连接后，连续 2 次因详情导航 `receiveTimeout` 失败。
- 自动源站用例的真实触摸和安全存储隔离改动通过静态分析。
- 操作者确认真实触摸已恢复。
- 手动测试容器出现 `inTest` 生命周期断言，该次结果未通过。
- 普通 `lib/main.dart` 的 arm64 Debug 构建和安装通过。
- 真机正常应用页面已打开，原有源站登录状态已保留。

原始 JSON 与汇总保存在本机 `build/diagnostics/video-relay-experiment/`。
模拟器原始记录为 `run-20261027-075930941.json`。
真机原始记录为 `build/diagnostics/video-relay-phone/run-android12-1.json`。
详情导航失败记录为同目录的 `live-android12-4.log` 和 `live-android12-5.log`。
本实验未修改生产播放逻辑，无项目依赖变更。

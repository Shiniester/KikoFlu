# Android 视频性能排查

本轮减少了隐藏源站页面和视频封面原图解码的资源开销。
Android 的实际帧耗时仍需真机测量。
启动、后台刷新和音声路径的改动见[共享路径性能改动与候选](shared-performance-opportunities.md)。

## 范围

用户反馈 Android 在没有打开视频时、退出视频后均有页面卡顿。
本轮保留视频功能，检查视频服务初始化、浏览器会话和封面解码。
播放、下载和资料归属沿用 [ADR 0005](../adr/0005-native-video-and-source-account.md)。

## 已确认的开销

### 隐藏浏览器保留完整源站页面

恢复视频源会话后，应用会保留主请求浏览器和媒体转发浏览器。
两个浏览器均曾加载完整源站页面。
离开视频页不会关闭这两个浏览器。
主请求浏览器在提取页面内容后也曾保留原页面。

`Offstage` 只隐藏视图，不表示子树已停止工作。
[Flutter 文档](https://api.flutter.dev/flutter/widgets/Offstage-class.html)说明隐藏子树仍可保持活动。
因此，保留完整网页可能继续占用 CPU 和页面资源。

Android 现在用同源空白 HTML 承载媒体转发。
主请求浏览器提取文档后，也会卸载源站页面。
已连接会话中的文档请求失败或取消时，先停止导航，再卸载页面。
初次手动验证失败时，仍保留可见的验证页面。

空白页通过有效 HTTPS `baseUrl` 保持 JavaScript 来源。
[Android WebView 文档](https://developer.android.com/reference/android/webkit/WebView#loadDataWithBaseURL(java.lang.String,java.lang.String,java.lang.String,java.lang.String,java.lang.String))说明 `baseUrl` 参与同源判断。
Android 的原生可见地址可以是 `about:blank`，请求前会单独核验 JavaScript 来源。
原有请求地址和消息来源校验继续生效。

页面卸载完成前，请求队列不会放行下一次文档操作。
清理操作在平台调用前后核验会话代次，防止旧会话停止或覆盖新页面。

### 缩略图按原图尺寸解码

视频封面曾直接使用 `Image.network`，未限制解码尺寸。
80×60 逻辑像素的列表封面仍可解码完整大图。
浏览过的视频页会保留状态，原图解码会增加图片缓存的内存负担。

封面现在按布局宽度和设备像素比设置解码宽度。
列表、网格和下载条目复用同一个 `VideoCover`。
布局比例、图片裁剪和卡片内容保持原有行为。

同一张 1600×1200 PNG 的回归用例使用 80×60 逻辑像素、3 倍设备像素比：

| 项目 | 原实现 | 当前实现 |
| --- | ---: | ---: |
| 解码尺寸 | 1600×1200 | 240×180 |
| RGBA 像素占用 | 7,680,000 字节 | 172,800 字节 |

该用例的像素占用减少 97.75%。
数字按实际解码宽高乘以每像素 4 字节计算，不代表进程总内存。

### 未进入视频时的检查

主导航在首次选中前不会构建视频页。
新增断言检查启动、音声与设置切换后的视频服务状态。
视频客户端、资料库和下载服务均未创建。
这些检查在竖屏和横屏布局下通过。

视频播放器只在打开视频详情页时创建。
退出播放页会取消保存进度的定时器并释放播放器。
应用启动仍会初始化 MediaKit 的原生库和 JNI 状态。
现有证据没有确认这段启动工作造成持续卡顿。

## 验证

2026-10-25 的组合检查：251 项通过，1 项真实元数据接口检查未启用。
覆盖视频浏览、播放、下载、会话，以及音声与主导航。
回归包含封面真实解码尺寸、页面卸载顺序和旧会话清理。

```powershell
flutter test --no-pub test/videos test/tab_collection_motion_test.dart test/audio_screen_test.dart
```

`flutter analyze --no-pub --fatal-infos` 通过，未发现问题。

新增 Android 集成断言覆盖空白页的来源、文档卸载、Cookie 和本地存储保留。
媒体转发夹具也改为使用生产环境的空白页与来源核验函数。

## 真机验证限制

本轮没有连接 Android 真机。
尚未测量页面帧耗时、CPU 和进程总内存。
新增 Android 集成断言、真实源站会话和播放兼容性尚未在设备执行。
自动测试通过不能据此证明全部卡顿已经消失。

连接 Android 设备后，可运行已有集成入口：

```powershell
flutter test --no-pub -d <device-id> integration_test/android_verification_document_test.dart
flutter test --no-pub -d <device-id> integration_test/android_media_relay_fixture_test.dart
```

卡顿对比须使用相同设备、数据和 Profile 构建。
分别记录冷启动后未进入视频、浏览后返回音声、播放后返回音声的帧耗时。
已有 Profile 测量方式见[播放器性能验证](player-performance.md)。

## 实施交接

- `task_brief`：减少 Android 视频浏览引入的后台页面与图片解码开销。
- `dispatch.read_only`：`video_background_map` 核对会话与原生初始化；`video_ui_map` 核对界面刷新；`browser_lifecycle_review` 独立检查会话清理。
- `dispatch.write_stages`：`video_ui_map` 负责封面组件和解码测试；主执行者负责浏览器、主导航断言、集成入口和本文。文件归属独立，Flutter 命令串行执行。
- `dispatch.skipped`：没有另派构建、依赖和文档写入者，现有分工已覆盖本轮文件。
- `agents`：后台定位确认隐藏页面保留；界面定位未发现整页逐帧重建的证据；独立评审提出的旧会话清理问题已修复并补充回归。
- `implementation_plan`：先验证多余工作，再修改对应资源生命周期，最后组合验证。
- `dependency_risks`：无新增依赖，无持久化格式变更。
- `conflicts`：无。
- `handoff.what`：代码、组合回归和设备验证入口已更新。
- `handoff.why`：保留登录与媒体能力，同时卸载无需常驻的网页文档。
- `handoff.next`：在目标 Android 设备比较同场景帧耗时，并执行会话与媒体转发集成检查。

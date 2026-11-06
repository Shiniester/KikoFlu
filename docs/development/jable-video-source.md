# Jable 视频源

Jable（jable.tv）作为独立视频源接入现有视频页。
可匿名浏览、搜索、播放和下载视频。登录 Jable 后可使用视频收藏。

## 页面与操作

- 视频页沿用音声页和漫画页的抽屉选源方式。
- 选择视频源后，视频页显示该源的目录。
- 视频集合布局、视频详情页和视频播放器沿用现有界面。
- 在侧栏选择**新作上市**、**最近更新**、**中文字幕**或**热门**。
- 在搜索页按分类、标签或演员筛选。可同时输入关键词。
- 目录和搜索结果按源站页码翻页。页面提供排序时，可切换排序或榜单时间范围。
- 在详情页选择演员、分类或标签，可打开对应目录。

视频卡片使用 Jable 列表页提供的信息，不显示标签。
卡片不会为补充资料逐个读取视频详情。
演员、标签和发布时间在视频详情页显示。
卡片不会从视频详情补充字幕和无码标记。

## Jable 账号与视频收藏

1. 在视频侧栏选择 **Jable 账号**，再选择**登录**。
2. 在应用内的 Jable 页面完成验证和登录。
3. 选择**完成**。应用通过 Jable 的收藏页确认登录。
4. 在视频详情页选择**视频收藏**可收藏视频。再次选择可取消收藏。

在侧栏选择**视频收藏**可查看或搜索当前账号的收藏。
账号页保留登录状态和退出入口。
Jable 的**稍后观看**是单独的清单，应用尚未接入。
收藏保存在 Jable。退出登录或登录过期后，应用清空当前显示的收藏。
本机的视频下载和续播进度仍可用。
登录页和收藏协议见 [Jable 登录页](https://jable.tv/login/)和[收藏请求示例](https://github.com/OrangeSAM/jable-collect)。

## 视频源验证

Jable 沿用 MissAV 的浏览器验证交互。
遇到视频源验证后，页面提供验证入口。
验证成功后，自动重试原请求。
取消验证后，页面保留验证入口。

Jable 与 MissAV 分别保存浏览器会话。
目录、搜索和详情通过已验证的源站浏览器读取。
重新打开应用后，首次请求恢复 Jable 浏览器会话。
切换视频源后，旧请求的响应不得替换当前源的内容。

播放和下载使用源站详情提供的 HLS 地址及请求头。

## 资料归属

不同视频源的同番号作品分别保存视频续播进度和视频下载。
现有 MissAV 视频续播进度和视频下载继续可用。
切换视频源不删除视频下载。
标识与旧资料兼容规则见 [ADR 0008](../adr/0008-video-source-storage-identity.md)。

## 流程原型

流程原型保存在 `chore/jable-source-prototype` 分支。
提交为 `5249c81e3bfd07ee93672ef64989a8470e5af9f4`。
文件为 `lib/src/videos/ui/jable_source.prototype.html`。
原型使用内存中的示例数据，双击 HTML 文件即可打开。

原型回答的问题：新增 Jable 后，选源、搜索、播放和验证流程是否连贯？

- 正常流程：选择 Jable、搜索、打开详情、播放和下载。
- 验证流程：取消验证后重试，验证成功后恢复原请求。
- 切源流程：忽略旧请求的响应，保留各源独立的下载。

3 个引导场景通过内存状态检查。

## 自动检查

| 检查范围 | 结果 |
| --- | --- |
| `flutter test --no-pub test/videos` | 504 项通过。1 项 MissAV 源站测试默认跳过 |
| `flutter analyze --no-pub --fatal-infos` | 全项目通过 |
| `flutter build apk --debug --no-pub` | 已生成 Android 调试包 |

账号测试使用模拟的 Jable 响应，覆盖登录判断、收藏与取消收藏、翻页搜索、登录过期和退出登录。
本次未使用真实 Jable 账号或 Android 设备验证登录与收藏。

## Android 实测入口

`integration_test/jable_live_test.dart` 默认跳过源站实测。
连接 Android 设备后，使用以下命令启用实测：

```powershell
flutter drive --no-pub -d emulator-5554 --driver=test_driver/jable_live_driver.dart --target=integration_test/jable_live_test.dart --dart-define=KIKOFLU_LIVE_JABLE=true --keep-app-running
```

需要交互验证时，在设备中的 Jable 页面完成验证。
实测检查目录、搜索、在线播放、跳转、会话恢复、完整下载、暂停继续和离线播放。
完整下载的等待上限为 4 小时。
下载失败后，实测调用下载页已有的重试操作，最多重试 20 次。
全部检查通过后，实测删除临时样本。
实测失败时保留临时目录，并在日志中记录目录名。

- 使用本机 HTTP 代理的 Android 模拟器，可附加 `--dart-define=KIKOFLU_LIVE_JABLE_PROXY=10.0.2.2:7890`。
- 指定样本时，附加 `--dart-define=KIKOFLU_LIVE_JABLE_PAGE=<Jable 视频页面地址>`。
- 复用中断实测的缓存时，附加 `--dart-define=KIKOFLU_LIVE_JABLE_RESUME_DIRECTORY=<临时目录名>`，并指定原样本页面。目录必须已存在于应用临时目录，名称以 `kikoflu-jable-live-` 开头。
- 只验证下载时，附加 `--dart-define=KIKOFLU_LIVE_JABLE_DOWNLOAD_ONLY=true`。此模式跳过在线播放与在线播放跳转。其他检查仍会运行：
  - 浏览器验证、目录、搜索、详情和媒体探测。
  - 会话恢复、完整下载、暂停继续、失败重试和离线播放。

  实测报告会标记 `downloadOnly`。

## 实际访问

目录、搜索和详情解析参照 [CatVodSpider 的 Jable 解析代码](https://github.com/bizhangjie/CatVodSpider/blob/0c9346d49d951557942f4dac476a2959d20832da/app/src/main/java/com/github/catvod/spider/Jable.java)。
Jable 提供新作上市、最近更新、分类、演员和热门榜单。榜单可按时间范围切换。[新作上市](https://jable.tv/new-release/) · [演员目录](https://jable.tv/models/) · [热门榜单](https://jable.tv/hot/)

2026 年 11 月 3 日，本机直接请求 Jable 首页返回 HTTP 403。
响应包含 Cloudflare 浏览器验证标记。

Android API 36 x86_64 模拟器通过应用 HTTP 代理访问 Jable。
实测使用应用创建的播放器和下载器。
HTTP 代理下的 HLS 播放需要在播放器默认协议列表中加入 `httpproxy`。
协议设置参照 [FFmpeg 协议文档](https://ffmpeg.org/ffmpeg-protocols.html)。

| 实测范围 | 结果 |
| --- | --- |
| 浏览器验证 | 通过 |
| 目录 | 读取 25 条视频 |
| 搜索 | 找到指定样本 |
| 在线播放与跳转 | 通过；1280×720，时长 1 小时 59 分 43 秒 |
| 已保存会话恢复 | 新客户端恢复后读取目录通过 |
| 暂停与继续下载 | 通过 |
| 失败后重试续传 | 通过；TLS 握手中断后恢复续传 |
| 完整下载 | 按要求暂停；约 35%，保留约 423 MiB 分片 |
| 离线播放与跳转 | 未验证 |

### Android 手机

2026 年 11 月 4 日，ABR-AL60 通过手机系统 HTTP 代理实测。
设备运行 Android 12（API 31），架构为 `arm64-v8a`。
实测使用独立包名，保留手机原有的正式版、Beta 版和 Debug 版。
下载样本为 `mikr-130`。

| 实测范围 | 结果 |
| --- | --- |
| 浏览器验证 | 通过 |
| 目录与搜索 | 最终报告读取 25 条视频，找到指定样本 |
| 已保存会话恢复 | 通过 |
| 暂停、继续与失败后续传 | 通过；复用已下载分片 |
| 完整下载 | 通过；HLS 缓存总量为 1,321,393,248 字节，约 1.23 GiB |
| 离线播放与跳转 | 通过；1280×720，时长 1 小时 59 分 43 秒 |
| 在线播放 | 未通过；当前系统 HTTP 代理下发生 TLS 握手失败 |

下载期间出现 1 次接收中断和 5 次 TLS 握手中断。
续传启动时另有 2 次源站验证要求，重试后继续下载。
离线检查等待播放进度前进和视频尺寸有效，再检查中段跳转。
实测未单独验证画面输出和硬件解码。

最终报告保存在本机的 `build/jable-phone/completed-response.json`。
实测样本和独立测试应用已删除。
手机 USB 供电亮屏设置已恢复，原有 Debug 版更新时间未改变。

仓库未启用 GitHub Issues。
原型分支和检查结果保存在本文档中。

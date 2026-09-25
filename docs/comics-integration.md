# 漫画整合与匿名访问

## 使用与边界

主导航为「音声 → 漫画 → 设置」，适配底栏和横屏侧栏。漫画的二级标签为
「主页、收藏、历史记录、已下载」。主页按来源展示推荐和分类；搜索支持单源、
全部启用来源分组、全部启用来源合并，以及当前资料库内搜索。

收藏主操作优先写入已登录且支持收藏的源站，否则写入本机；「收藏到本机」始终
明确写入本机。源站写入失败保留错误和重试。长按收藏或历史条目可确认移除。
已下载只展示完整章节所属作品，下载任务入口独立，支持暂停、继续、重试和删除。

阅读器提供六种模式、缩放、章节和页码切换、预加载及后台进度保存。页码以实际
图片为单位；双页布局不把进度改成双页序号。点按中心显示控制层，有音声会话时
显示原有 Mini Player，可打开完整播放器再返回。漫画详情与阅读器使用独立路由。

新安装直接进入主界面，不提交演示账号登录。音声的已保存真实账号仍可恢复；
退出立即撤销请求会话，再按顺序清理持久化凭证并切换匿名缓存作用域。漫画账号
按来源隔离，退出不删除本地收藏、阅读历史或已下载内容。

设置外层保留主题、语言、隐私、代理、日志和关于。音声设置保留原偏好键；漫画
设置使用 `comic_` 前缀，包含来源与账号、默认收藏视图、列表、阅读模式、手势、
预加载、常亮、下载目录和图片缓存。全局代理作用于两类网络请求。

## 代码边界

| 模块 | 职责 |
| --- | --- |
| `lib/src/comics/comic_models.dart` | 来源限定的作品、章节、图片、实际页码进度 |
| `comic_source.dart`、`sources/` | 六个内置 Dart 适配器及实际支持的账号、收藏、评论能力 |
| `comic_http.dart` | 按来源保存 Cookie/token、代理、日志、退出后的迟到响应隔离 |
| `comic_library.dart` | 独立 SQLite 收藏、历史和任务持久化 |
| `comic_downloads.dart`、`comic_images.dart` | 章节/图片状态、断点继续、离线文件、图片缓存、JM 重组 |
| `ui/` | 漫画四标签、搜索、详情、设置、下载任务与阅读器 |
| `lib/src/widgets/library_tab_strip.dart` | 音声与漫画共用的标签及滚动显隐规则 |

漫画不使用音声 Work、毫秒进度或音声下载任务模型。图片缓存与音声缓存分开。
移植协议、Hitomi 搜索和 JM 图片算法的 MIT 许可见 `third_party/picacomic/`。
架构决策见 [ADR 0002](adr/0002-comic-domain-and-anonymous-entry.md)。

## 验证

2026-09-25，在 Windows、Flutter 3.44.7 / Dart 3.12.2 上检查。

静态分析：无问题。自动回归：109 项通过，1 项原有跳过。覆盖协议解析、来源 Cookie 隔离、JM 图片
重组、游客无登录请求、迟到登录响应、SQLite 进度、下载暂停和失败续传、缺失文件、
聚合失败隔离、源站收藏失败不落本地、六种阅读模式、完整播放器返回后页码保持，
以及现有音声标签、代理、缓存作用域、播放恢复、Dock 和手势动画。

主要命令：

```powershell
flutter analyze --no-pub
flutter test --no-pub test/comics_protocol_test.dart test/anonymous_auth_test.dart test/comic_library_test.dart test/comic_downloads_test.dart test/comic_widgets_test.dart test/audio_screen_test.dart test/toolbar_motion_regression_test.dart test/settings_subpage_test.dart test/floating_feed_toolbar_test.dart test/conditional_get_cache_test.dart test/cache_service_scope_test.dart test/playback_session_restore_failure_test.dart test/app_bottom_dock_test.dart test/app_bottom_dock_transition_test.dart test/preferences_proxy_settings_test.dart test/login_proxy_section_test.dart
flutter build apk --debug --no-pub
flutter build windows --debug --no-pub
```

`comic_library_test.dart` 在 Windows 上允许使用 `KIKOFLU_TEST_SQLITE` 指定可用的
SQLite DLL。真人源检查默认跳过，只有显式设置 `KIKOFLU_LIVE_COMICS=1` 才联网：

```powershell
$env:KIKOFLU_LIVE_COMICS='1'
flutter test --no-pub test/comic_live_smoke_test.dart
```

联网观察不等同于完整源站验收：

| 服务 | 实际结果 |
| --- | --- |
| 默认音声服务器 | 无 Cookie/token 的作品接口返回 200 和作品 JSON；未验收匿名真实播放 |
| Hitomi | 匿名推荐、详情、章节及首张 WebP 图片请求和解码通过 |
| Picacg、EH、HT、NH | 当前网络连接超时，功能未完成真实联网验收 |
| JM | 当前连接 TLS 握手终止，功能未完成真实联网验收 |
| 六源账号和源站收藏写入 | 未提供真实账号，未验收 |

## 限制与后续验收

- Windows 调试产物与 Android 调试 APK 可构建。Windows 本机 CMake 的符号链接
  解压限制影响已有 `smtc_windows` 插件；本机通过在插件实际缓存目录解压上游 DLL，
  再执行生成工程的 `INSTALL` 目标构建。项目没有修改该插件代码或升级工具链。
- iOS、macOS、Linux 未在对应系统构建；未连接移动设备，所有平台的真人交互、
  后台音频连续性、系统返回手势及离线重启流程仍需设备验收。Widget 测试不替代这些检查。
- EH/NH 使用外部网站登录后导入会话 Cookie/token，没有内嵌网页登录器。Picacg、
  JM、HT 有密码登录入口；服务端拒绝匿名或要求额外验证时保留其登录要求。
- 评论和评分只读；没有自定义 JS 来源、同步、旧数据导入、追更、本地文件夹库或图片收藏。
- 适配器依赖源站当前协议，其他五源需要在可访问网络下逐源验证推荐、搜索、详情、
  图片、登录、收藏和下载，不能以固定输入测试推断实际可用性。
- 没有自动发布。

新增直接依赖为 html、image、pointycastle、scrollable_positioned_list。image 保持
与现有 archive 3.x 兼容的 4.3.x，版本由 pubspec.lock 固定；未引入 QuickJS。


## 实施交接

- `task_brief`：整合六源漫画闭环、匿名音声入口和分域设置，保留既有音声行为。
- `dispatch`：`read_only` 为下表三项；`writer` 为主执行者；`writer_sequence`
  为游客与设置、共用界面、漫画服务、阅读下载、验证与文档。`skipped` 为额外写入者
  和重复领域顾问，避免并发改动及职责重复。
- `implementation_plan`：上述四个实施阶段已落到代码；平台与真实账号验收按限制表继续。
- `verification`：命令、自动测试覆盖、联网观察和平台边界见上文。
- `dependency_risks`：新增依赖与版本边界见上文；源站协议变化需要独立验证。
- `conflicts`：[]。
- `handoff`：`what` 为未完成的源站与设备验收；`why` 为账号、网络和平台条件未具备；
  `next` 为在可访问网络和对应原生平台上运行列出的检查并验证真实音声会话。

`agents`：

| name | focus | result | risks | next_step |
| --- | --- | --- | --- | --- |
| inspect_audio_shell | 音声导航、设置、Dock 和账号入口 | 共用标签和工具栏，保留音声 Dock 专用路由 | 原生导航与音频交互需设备检查 | 对应平台交互验收 |
| source_protocols | 六源协议与阅读搜索交互 | Dart 适配器、图片处理和六模式阅读边界 | 源站接口与图片域名可变化 | 网络可达环境逐源验证 |
| review_comic_services | 资料库、下载与会话隔离 | 独立模型和存储、串行凭证提交、下载完成信号清理 | 真人账号流程尚未验收 | 用真实账号验证登录、退出、收藏 |

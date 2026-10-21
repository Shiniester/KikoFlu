# JP-ASMR 访问验证

Android 主页的 HTTP 403 与站点访问验证有关。
用户确认同一手机浏览器需要先完成 Cloudflare 验证。
普通 HTTP 客户端不能执行验证页所需的 JavaScript。

Android 主页和搜索页提供“完成网站验证”入口。
验证通过后，应用重新加载作品。

## 现场结果

2026-10-20，通过同一网络检查公开页面：

| 请求 | HTTP 状态 | 响应 |
| --- | --- | --- |
| `https://japaneseasmr.com/` | 200 | 作品目录 |
| `https://japaneseasmr.com/?s=RaRo` | 403 | `Just a moment...` 验证页 |
| `https://japaneseasmr.com/?s=RJ01726738` | 403 | `Just a moment...` 验证页 |
| `https://japaneseasmr.com/search/RaRo/` | 200 | 搜索结果 |
| `https://japaneseasmr.com/search/RaRo/page/2/` | 200 | 搜索结果第 2 页 |
| `https://japaneseasmr.com/search/耳かき%20%26%20voice/` | 200 | 对应关键词的搜索结果 |
| `https://japaneseasmr.com/151342/` | 200 | 作品详情 |
| `https://v.weeab0o.xyz/RJ01726738.m3u8` | 200 | HLS 播放清单 |
| `https://japaneseasmr.com/dlc.php?f=RJ01726738` | 403 | `Just a moment...` 验证页 |

实际 `JapaneseAsmrService` 请求也复现了查询参数搜索的 403。
添加浏览器 User-Agent 和 Referer 后，该地址仍返回 403。
搜索结果页的分页链接使用 `/search/关键词/page/页码/`。

## Android 验证流程

应用识别 `cf-mitigated: challenge` 响应头和验证页标记。
主页和搜索页显示验证说明，不再直接显示这类 Dio 错误。

Android 系统 WebView 展示站点验证页。
验证页与作品请求使用相同的代理配置。
当作品目录出现后，验证窗口自动关闭。
应用保留验证 Cookie 和 WebView 的真实 User-Agent。
验证 Cookie 只用于 JP-ASMR 的 HTTPS 请求。
取消验证不触发作品刷新。

## 搜索地址

`JapaneseAsmrService` 使用原生搜索路径。
关键词作为单个路径段编码，保留空格、日文和特殊字符。
搜索翻页沿用原生路径。

## 相关推荐

2026-10-21，公开[作品详情页](https://japaneseasmr.com/151342/)包含原生的
“More Like This”列表。
推荐作品位于 `.yarpp-related`，包含作品链接、标题和封面。

JP-ASMR 作品的相关推荐按源站顺序展示。
推荐请求复用详情页缓存和访问验证会话。
推荐作品沿用 JP-ASMR 的负数内部 ID。
推荐列表沿用已有屏蔽逻辑。
源站卡片未提供的标签、声优和社团字段无法用于屏蔽。
源站列表为空或请求失败时，不回退到 ASMR.ONE。

## 验证范围

以下命令中的 75 项测试全部通过：

```text
flutter test --no-pub test/japanese_asmr_service_test.dart test/japanese_asmr_access_prompt_test.dart
flutter test --no-pub test/audio_screen_test.dart test/kikoeru_api_japanese_source_test.dart test/works_provider_source_switch_test.dart
```

测试覆盖搜索地址、关键词编码、分页总数和账户凭据隔离。
API 分发和音声源切换测试也通过。
验证取消、失败重试和已有作品时的验证入口均有回归覆盖。
正常页面的 Cloudflare 后台脚本不会触发验证提示。
修改的服务和测试通过定向 `flutter analyze --no-pub` 检查。
修复后的实际服务搜索返回 20 个作品，总数为 247。

Android 验证桥通过 `:app:compileDebugKotlin` 编译。
`flutter build apk --debug --no-pub` 已构建调试安装包。
安装包位于 `build/app/outputs/flutter-apk/app-debug.apk`。
调试版与正式版并存。

手机验证步骤：

1. 安装调试版。
2. 选择 JP-ASMR。
3. 如果出现验证提示，选择“完成网站验证”。
4. 完成网站验证，确认作品列表自动加载。

## 真机结果

2026-10-20，在 ABR-AL60、Android 12 上检查调试版。
系统 WebView 为 `com.huawei.webview`，版本为 `114.0.5.302`。

| 检查 | 结果 |
| --- | --- |
| JP-ASMR 主页 | 作品列表加载正常 |
| 关闭后重新打开应用 | JP-ASMR 主页加载正常 |
| 搜索 `RARO` | 返回 247 个作品 |
| 作品 `RJ01726738` | 详情和音频资源列表加载正常 |
| 作品分页 | 进入第 2 / 861 页，总数为 34,415 |
| 原生验证窗口与会话回传 | 返回成功，随后加载 20 个作品 |

原生验证记录保存在 `build/jp-device-verification/native-result.json`。
手机已恢复为正常入口的调试版。
正式版的版本和安装时间记录未改变。

## 限制

本轮真机检查没有复现主页 403。
人工交互式挑战、原生播放器和完整下载尚未验证。
本次检查的下载索引返回了访问验证页。
搜索地址修改不能解除下载索引的访问验证。
第三方下载主机也不接收 JP-ASMR 的验证 Cookie。
应用内验证入口仅支持 Android。
其他平台仍可更换网络或代理后重试。
目录和搜索需要读取末页来计算精确总数。
如果末页请求失败，当前列表请求也会失败。

Cloudflare 对嵌入式浏览器的支持有限。
如果验证仍失败，需要在实际手机上核查。
浏览器支持范围见 [Cloudflare 支持的浏览器](https://developers.cloudflare.com/cloudflare-challenges/reference/supported-browsers/)。

音声源的身份和功能范围见 [ADR 0003](../adr/0003-independent-audio-sources.md)。

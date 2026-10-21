# JP-ASMR 搜索目录

## 已确定的需求

JP-ASMR 在全局作品搜索中补充标签、声优、社团目录。
交互沿用 ASMR.ONE 的搜索逻辑。

- 选择搜索类型后，空输入显示目录候选。
- 输入名称后，按名称筛选目录候选。
- 点击候选项后，将候选项加入搜索条件。
- 点击“搜索”后，打开作品结果。
- 搜索条件沿用现有的组合、删除和排除操作。

## 验收要求

- 目录项属于当前音声源，不混用 ASMR.ONE 的目录数据。
- 目录条件按源站分类查找作品，不能替换成同名关键词搜索。
- 组合、排除和关键词并用的结果符合现有搜索条件的含义。
- 作品结果分页保留完整搜索条件。
- ASMR.ONE 的现有搜索行为保持不变。

## 目录数据

2026-10-21，通过普通 HTTP 请求读取了 3 类目录的完整 HTML。

| 目录 | 地址 | 分类路径 |
| --- | --- | --- |
| 标签 | [Tags](https://japaneseasmr.com/tags/) | `/tag/分类标识/` |
| 声优 | [CV](https://japaneseasmr.com/cv/) | `/tag/分类标识/` |
| 社团 | [Circles](https://japaneseasmr.com/circles/) | `/category/分类标识/` |

目录项位于 `.entry-content .tag-groups-tag a`。
链接提供真实分类路径，`.tag-groups-label` 提供名称。
链接的 `title` 提供作品数。
目录中的作品数属于源站快照，不能代替查询结果总数。

搜索条件和搜索历史保留真实分类路径及音声源。
显示名称不用于推导分类路径。

## 查询与分页

单项正选使用源站分类归档。
多个正选标签或声优使用 `+` 连接分类标识。
分隔符保留为 `+`，编码成 `%2B` 会返回 404。

混合分类、排除、关键词与目录组合按作品卡片的分类信息筛选。
源站归档页的 `body` 提供分类身份。
作品卡片的分类 CSS 类用于判断条件是否匹配。
日文分类可能使用数字身份，不能直接把分类标识拼成 CSS 类。

筛选查询按需读取源站页面，填满当前结果页并检查下一项。
筛选查询在总数未知时保留上一页和下一页，不显示虚假总数。
原生归档查询沿用精确总数分页。

源站[说明](https://japaneseasmr.com/info/)列出了排除语法。
实测 `/tag/binaural+-asmr/` 仍返回带 ASMR 标签的作品，不能用于精确排除。

## 验证

2026-10-21，以下定向回归共 45 项通过：

```text
flutter test --no-pub test/japanese_asmr_catalog_test.dart test/japanese_asmr_service_test.dart test/kikoeru_api_japanese_source_test.dart test/online_subtitle_feed_pagination_test.dart test/japanese_search_history_test.dart test/japanese_search_keyboard_test.dart test/browse_motion_test.dart
```

真实源站 HTML 回放的 3 项测试通过。
回放覆盖 3 类目录解析、日文分类、声优与社团的交集和排除。
本次修改的 13 个 Dart 文件通过定向 `flutter analyze --no-pub` 检查。
独立代码审查未发现需要修复的问题。

本次未检查真机交互。
组合筛选可能读取多个源站页面。

交互依据见 `lib/src/screens/search_screen.dart`。
音声源边界见 [ADR 0003](../adr/0003-independent-audio-sources.md)。

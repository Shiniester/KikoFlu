# Android 共享路径性能改动与候选

本轮收窄全局主题订阅，延后隐藏历史页的自动刷新。
Hive 初始化也已移出首帧关键路径。
悬浮字幕查找和历史排序仍是后续候选。

## 1. 全局主题只监听使用的颜色

启用动态色彩时，[应用根组件](../../lib/main.dart)只读取 `seed`。
原来监听整个 `ArtworkThemeSeedState`。
切换同一封面的曲目也会更新描述符和加载状态。
颜色未变时，这些状态仍会让消费者重建。
根组件还会重新构造亮色、暗色方案和主题。

使用真实 `ArtworkThemeSeedNotifier`、相同封面缓存和两个独立消费者的 Widget 探针，测得：

| 同封面切歌 | 消费者新增重建次数 |
| --- | ---: |
| 修改前的整状态订阅 | 1 |
| 修改后采用的 `select((state) => state.seed)` | 0 |

根组件现已采用颜色选择器。
[音声播放器](../../lib/src/screens/audio_player_screen.dart)也使用同一写法。
主题测试覆盖封面切换、提色失败和关闭动态色彩。
探针测量的是消费者重建次数，没有测量完整应用的帧耗时。

## 2. 隐藏历史页只记录待刷新状态

[播放历史服务](../../lib/src/services/playback_history_service.dart#L108)在播放期间每 5 秒检查一次进度。
成功保存后会发出历史更新通知。
[历史状态管理器](../../lib/src/providers/history_provider.dart)原来只按 10 秒节流刷新。
原来没有检查页面是否可见。
一次刷新会查询当前页和总数，并更新加载状态和结果状态。

修改前的隔离探针先监听历史状态，再关闭全部页面监听。
超过 10 秒后发出一次真实服务的历史更新通知，仍测得 2 次状态更新。
探针使用临时数据库和假的历史写入存储，不访问用户记录。

[历史页](../../lib/src/screens/history_screen.dart)监听整个历史状态。
应用标签页会保留访问过的页面，因此隐藏页仍有刷新路径。
本轮复用 `DeferredTabContent` 的标签页活动信号。
历史页也检查当前路由和应用前后台状态。
页面销毁时，历史状态管理器恢复隐藏状态。

隐藏时，播放通知和 `addOrUpdate` 只标记待刷新。
`addOrUpdate` 仍会把记录写入数据库。
回到页面后，历史状态管理器合并通知并刷新一次。
查询期间，历史页保留旧列表。

首次创建状态管理器仍会加载一次列表。
手动刷新、删除和清空历史保留原有行为。

省略播放进度的更新从数据库读取现有记录。
隐藏列表中的旧数据不再作为写入依据。
每 5 秒检查进度的规则保持原样。

## 3. Hive 初始化移出首帧关键路径

[启动关键阶段](../../lib/main.dart)原来等待 Hive backend 初始化。
完成初始化后，应用才调用 `runApp`。
当前恢复登录状态使用 SharedPreferences。
Hive 的账户管理数据由 `StorageService.initSecondary` 打开。
已有测试确认关键阶段不会打开 `users` box。

[存储服务](../../lib/src/services/storage_service.dart)现已统一初始化入口。
`initSecondary` 先初始化 Hive backend，再打开 `users` box。
首帧后的任务或账户管理首次访问会触发这个入口。
并发调用等待同一个 Future；失败后可以重试。
关键阶段只读取 SharedPreferences，不再初始化 Hive。
Windows、Linux 和 macOS 仍使用文档目录下的 `KikoFlu` 子目录。
Android 和 iOS 仍使用原来的文档目录。
`bootstrapHiveBackendMs` 和 Timeline 记录已保留。

回归测试覆盖延迟初始化、并发调用、失败重试和账户读写。
测试还核对了 Windows 的账户文件路径。

首帧后的任务由串行调度器执行。
下一次设备测量还应记录 `playback-restore` 的排队时间。
代理刷新可能是网络播放恢复的前置条件，调度等待本身不能证明应改为并行。

## 4. 悬浮字幕避免从头重复查找

启用悬浮字幕且音声正在播放时，[后台计时器](../../lib/src/providers/floating_lyric_provider.dart#L292)每 50 ms 查找一次当前字幕。
[查找函数](../../lib/src/models/lyric/lyric_parser.dart#L51)每次从列表开头线性扫描。
偏移后的字幕列表已经缓存，相同文本也不会重复发送给原生窗口。
可减少的工作集中在重复查找。

主机探针调用生产查找函数，查询最后一行：

| 字幕行数 | 单次列表读取次数 | 按 20 Hz 推算的每秒读取次数 | 主机单次查找中位数 |
| --- | ---: | ---: | ---: |
| 1,000 | 1,999 | 39,980 | 0.0015 ms |
| 10,000 | 19,999 | 399,980 | 0.0166 ms |

建议缓存当前行索引，或提取带结束时间校验的查找函数。
拖动进度、切换字幕和改变偏移时需要重新定位。
现有解析器保留不足 1 秒间隔的上一行。
长间隔返回空值。
后续改动需要保留这些语义。

计数确认了线性增长，但主机上的绝对耗时较低。
这项只影响开启悬浮字幕的播放场景，优先级低于前两项。
20 Hz 是按计时器周期推算的频率，不是设备实测采样率。

## 5. 历史排序索引可后做

[历史查询](../../lib/src/services/history_database.dart#L88)按 `last_played_time DESC` 取一页。
当前建表语句没有该字段的排序索引。
用生产建表语句和相同查询，在主机内存 SQLite 中比较了临时索引：

| 记录数 | 现行 SQL 中位数 | 临时添加排序索引后的中位数 |
| --- | ---: | ---: |
| 1,000 | 0.0910 ms | 0.0219 ms |
| 10,000 | 0.5771 ms | 0.0232 ms |

现行执行计划包含全表扫描和临时排序树。
添加索引后，查询使用索引，20 条返回记录保持相同。
这些数据来自 SQLite 3.53.1、预热后的 50 次查询。
主机上的绝对耗时不足 1 ms，因此不建议优先靠这项解决整体卡顿。
历史记录规模和 Android 查询耗时需要另外确认。
后续若添加索引，应覆盖现有数据库升级和原始排序结果。

## 验证与边界

本轮检查日期为 2026-10-25，基线为 `4d81eaf`。
修改前的基线测试 63 项通过。
主题重建与历史刷新探针各 1 项通过。
字幕计数和 SQLite 排序实验的断言通过。
本轮改动后的验证结果如下。

| 检查 | 结果 |
| --- | --- |
| 主题、历史、音声页、启动、登录和后台调度回归 | 9 个文件，共 94 项通过 |
| 真实主题状态管理器的隔离探针 | 同封面切歌时，整状态消费者重建 1 次，颜色消费者重建 0 次 |
| 隐藏历史页回归 | 隐藏写入与通知不发布列表状态；恢复后发布加载和结果各 1 次 |
| 账户存储回归 | 关键阶段不初始化 Hive；并发调用、失败重试、文件路径和读写通过 |
| 独立代码复核 | 未发现剩余必修问题 |
| `flutter analyze --no-pub --fatal-infos` | 通过，无诊断 |

```powershell
flutter test --no-pub test/history_visibility_test.dart test/audio_screen_test.dart test/playback_history_service_test.dart test/artwork_theme_provider_test.dart test/theme_color_scheme_test.dart test/storage_service_bootstrap_test.dart test/app_bootstrap_coordinator_test.dart test/anonymous_auth_test.dart test/background_work_scheduler_test.dart
```

历史回归还覆盖省略进度时保留数据库最新记录。
删除和清空历史仍会立即更新列表。
回归使用临时数据库，不访问用户记录。

本机测量文件位于被 Git 忽略的 `build/`：

- `shared_theme_probe_test.dart.txt`、`shared-theme-probe.json`
- `shared_history_activity_probe_test.dart.txt`
- `shared_lyric_probe.dart.txt`、`shared-lyric-probe.json`
- `shared_history_probe.py`、`shared-history-probe.json`
- `shared-paths-probes.log`

这些探针使用生成数据和临时存储。
历史刷新探针记录修改前行为。
当前行为以 `test/history_visibility_test.dart` 的断言为准。
时间数据来自 Windows 主机；字幕计数使用带读取计数的列表和 Dart JIT。
主机没有连接 Android 设备。
本轮没有 Android CPU、进程内存或帧耗时结果。
Hive 初始化和首帧的 Android 耗时也未测量。
不能据此推算设备帧耗时。
前一轮视频改动及其验证见[视频性能排查](video-performance.md)。

## 实施交接

- `task_brief`：实施主题订阅、隐藏历史刷新和 Hive 延迟初始化。
- `dispatch`：`read_only` 为 `browser_lifecycle_review`，复核生命周期和存储入口。
  `write_stages` 包含并行修改与串行验收两个阶段。
  主执行者负责 `main.dart`、文档及全部 Flutter 命令。
  `video_ui_map` 负责历史状态管理器、历史页及可见性测试。
  `defer_hive_storage` 负责存储服务及启动测试。
  `skipped` 为移动端、构建和依赖角色；本轮不改原生代码或依赖。
- `agents`：`video_ui_map` 按标签页、路由和应用状态控制刷新。
  `defer_hive_storage` 合并 Hive backend 和 box 初始化。
  `browser_lifecycle_review` 检查路径兼容和历史进度写入。
  已完成的启动顾问 `video_background_map` 提供关键阶段与调度证据。
- `implementation_plan`：先用回归确认旧行为，再实施并组合验证。
  三项修改的文件归属独立，接口不互相依赖。
  写入者可以并行修改文件；共享 SDK 和缓存的命令串行执行。
- `verification`：覆盖主题变化、历史页生命周期及账户存储初始化。
  Android Profile 验证未执行。
- `dependency_risks`：无新增应用依赖，无数据格式变更。
- `conflicts`：`[]`。
- `handoff`：本轮减少重复重建、隐藏页查询和首帧等待。
  后续在 Android Profile 构建中测量冷启动与帧耗时。

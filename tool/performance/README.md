# KikoFlu Android Profile 性能闭环

这套工具在同一实体 Android 设备上运行 5 轮固定 Profile 场景，并追加一次真实账号的 Media3 soak。严格比较只接受 schema 2 报告；报告必须包含不同的 baseline/candidate Git SHA、相同 fixture SHA-256 和有效 thermal 状态。

## 固定数据与场景

- 500 个作品卡片及连续首页滚动。
- 1,000 个下载任务，其中 3 个活动任务按 500ms 更新。任务通过仅性能构建可用的内存入口注入真实下载页面，不持久化。
- 播放器位置连续更新与 50 次确定性 UI 状态切换。
- 10,000 个主机生成的字幕文件，通过字幕服务的可注入路径入口扫描。
- 512MB、含嵌套 ZIP 的主机生成归档，通过字幕服务的可注入路径入口导入。
- 真实账号队列连续播放 30 分钟，再执行 50 次真实 Media3 切歌。

fixture 默认写入 `build/performance_fixtures`，仅生成一次并由两版本复用：

```powershell
dart run tool/performance/generate_fixtures.dart `
  --output build/performance_fixtures `
  --with-zip `
  --zip-uncompressed-mb 512
```

清单记录每类数据的哈希及组合 `contentHash`。如需重建必须显式增加 `--force`。原始 fixture、设备序列号、JSON 报告和真实播放清单都位于被 Git 忽略的 `build/` 下。

## 运行 baseline 与 candidate

设备要求 API 24 以上、`/data` 至少 8GB 可用空间、Wi-Fi 已启用、关闭省电模式并保持相同动画倍率。脚本在每轮前强制停止应用并等待 thermal status 不高于 2；运行后过热的轮次会自动作废重跑。

设备上的 KikoFlu 必须已登录真实服务器账号。工具只读取应用现有会话，不会把 host、用户名、token、cookie 或媒体 URL写入报告。baseline 会从稳定排序结果中选择至少 10 个可播放 hash；candidate 必须复用该未跟踪清单。

在基线测量提交运行：

```powershell
pwsh -File tool/performance/run_android_profile.ps1 `
  -DeviceId <adb-serial> `
  -Label baseline
```

切换到候选 SHA 后运行，并提供基线报告：

```powershell
pwsh -File tool/performance/run_android_profile.ps1 `
  -DeviceId <adb-serial> `
  -Label candidate `
  -BaselineReport build/performance_reports/<baseline-run>/baseline.json
```

脚本固定以 `KIKOFLU_PERFORMANCE=true` 构建 Profile APK。普通构建调用下载 fixture 注入或计数接口会抛出 `StateError`。每轮只清理解压输出，不清除应用账号、缓存或播放历史。

`-SkipSoak` 仅用于本地调试；缺少 soak 指标的报告不能通过严格比较。可单独比较已有报告：

```powershell
dart run tool/performance/compare.dart baseline.json candidate.json `
  --json-output comparison.json `
  --markdown-output comparison.md
```

## 验收门槛

- 冷启动、首次可交互、扫描/ZIP 耗时与峰值 PSS、下载构建/临时分配、真实切歌 median/p95 至少改善 25%。
- 首页与播放器帧 p95 至少改善 25% 或达到 16.7ms；已达预算的基线最多回退 5%。
- 卡顿帧不得增加；下载进度延迟不超过 750ms。
- 两版本都必须完成至少 30 分钟播放和 50 次真实切歌。
- candidate 的非预期缓冲、播放错误和缓存错误必须为 0，且不得高于 baseline。
- 其他 lower-is-better 指标回退不得超过 5%。

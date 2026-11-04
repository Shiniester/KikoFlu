# ADR 0008: 按视频源区分本机资料并保留 MissAV 旧标识

视频源之间分别保存视频续播进度和视频下载。
MissAV 保留现有本机标识，避免迁移旧进度和下载目录。

## 决策

`VideoItem.id` 保留源站原生 ID。
`VideoItem.sourceKey` 标识视频源。
旧资料缺少 `sourceKey` 时，按 MissAV 读取。

本机资料统一使用 `VideoItem.storageKey`：

- MissAV 使用原始 `id`。
- Jable 使用 `jable:<id>`。

视频续播进度、下载任务和集合条目使用这个标识。
下载目录继续沿用现有编码方式。

## 原因

不同视频源可能使用相同的作品 ID。
直接共用 ID 会让下载任务或视频续播进度互相覆盖。
保留 MissAV 原标识后，现有资料无需改写即可继续读取。

原生 ID 与本机标识分开后，源站请求继续使用原生 ID。
账号接口中的 `VideoLink.sourceKey` 保留现有含义。

# JP-ASMR 下载、搜索和标签翻译设计

状态：已完成。

## 章节原文件下载

章节下载优先使用 Eara 为同一曲目返回的原文件地址。
原文件保留实际音频格式，不转码为 AAC。
原文件与章节按同一曲目节点关联，不按列表位置配对。

原文件缺失、请求失败或返回无效音频时，自动尝试现有 HLS 章节下载。
HLS 下载仍按章节时间范围提取 AAC。
用户取消下载或本地保存失败时，停止下载。

下载成功后，本地播放使用章节文件自身的时间轴。
本地播放不再应用在线章节的起止范围。
原文件和 HLS 下载沿用同一章节身份，保留已有下载记录。

## 搜索年龄分级

JP-ASMR 全局作品搜索的排序菜单提供年龄分级筛选。
选项为“全部”和“全年龄”，独立于结果排序。
选择“全年龄”时，请求带上 `allAges=true`。
切换年龄分级后，结果从第 1 页开始。

搜索初始为“全部”，搜索历史保存并恢复选择。
搜索年龄分级与作品主页的年龄分级独立。

## 点击搜索与标签译名

点击标签、声优或社团后，打开所属音声源的全局作品搜索。
请求使用原始名称作为关键词，不使用分类 ID 精确筛选。

音声标签保留 Eara 提供的原名和多语言名称。
标签译名跟随应用语言，缺少对应译名时显示原名。
搜索候选同时匹配原名和译名。
选中标签后，使用原名请求 Eara。

### 标签候选范围

使用 Eara 搜索建议和已加载作品中的标签作为候选。
没有匹配候选时，输入内容作为普通关键词提交。
候选不代表完整的 JP-ASMR 标签目录。

## 实施位置

- 曲目与标签数据：在 `JapaneseAsmrService` 保留原文件地址和多语言名称。
- 章节下载：在现有下载流程中加入原文件优先及 HLS 回退。
- 搜索界面：复用排序菜单、搜索历史和候选名称匹配。
- 标签显示：接入 Eara 译名，沿用应用语言。

## 验证要求

- 原文件下载成功时，不请求 HLS。
- 原文件与章节正确关联，保留实际音频格式。
- 原文件缺失、网络失败或音频无效时，回退到对应章节的 HLS。
- 用户取消或本地保存失败时，不触发 HLS 回退。
- 原文件与 HLS 章节的本地播放均不重复裁剪时间范围。
- 搜索菜单仅提供来源支持的年龄分级，并正确传递请求参数。
- 年龄分级切换重置分页，搜索历史正确恢复筛选。
- 标签原名和译名均能匹配候选，最终请求使用原名。
- 点击标签、声优和社团时，搜索使用作品所属音声源。
- 缺少标签译名时显示原名，切换应用语言后刷新显示。

## 接口依据

以下源码均来自 Eara 提交 `448f5ef19262f157c1f8f5a50ca135e9db06b5cd`。

- [曲目模型及原文件字段](https://github.com/eValDoll/EaraAsmrPlayer/blob/448f5ef19262f157c1f8f5a50ca135e9db06b5cd/app/src/main/java/com/asmr/player/data/remote/api/AsmrOneApi.kt)
- [下载流程](https://github.com/eValDoll/EaraAsmrPlayer/blob/448f5ef19262f157c1f8f5a50ca135e9db06b5cd/app/src/main/java/com/asmr/player/data/remote/download/DownloadWorker.kt)
- [搜索参数](https://github.com/eValDoll/EaraAsmrPlayer/blob/448f5ef19262f157c1f8f5a50ca135e9db06b5cd/app/src/main/java/com/asmr/player/data/remote/api/AsmrOneAvailabilityApi.kt)
- [标签多语言模型](https://github.com/eValDoll/EaraAsmrPlayer/blob/448f5ef19262f157c1f8f5a50ca135e9db06b5cd/app/src/main/java/com/asmr/player/domain/model/AlbumTag.kt)
- [搜索建议及标签译名](https://github.com/eValDoll/EaraAsmrPlayer/blob/448f5ef19262f157c1f8f5a50ca135e9db06b5cd/app/src/main/java/com/asmr/player/hotlistening/HotListeningApi.kt)

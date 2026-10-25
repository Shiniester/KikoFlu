# 视频播放器复刻约定

## 参照版本

KikoFlu 的视频播放器以 [PiliPlus 2.1.6.2](https://github.com/bggRGjQaUbCoE/PiliPlus/releases/tag/2.1.6.2) 为复刻基准。
源码固定为提交 [`b2d6a5befb6dd292b9f7ad98794f3620f6dfb818`](https://github.com/bggRGjQaUbCoE/PiliPlus/tree/b2d6a5befb6dd292b9f7ad98794f3620f6dfb818)。
后续源码对照与验收使用该提交。

## 覆盖平台

复刻覆盖 Android、iOS、Windows、macOS 和 Linux。
各平台分别验收。
各平台以参照版本对应平台的界面与行为为准。

## 功能范围

复刻包含 KikoFlu 已有和缺少的通用视频播放能力。
播放操作与选项遵循 PiliPlus 参照版本，以下保留规则除外。

清晰度、字幕和音轨等功能适配现有视频源。
缺少源数据的功能入口不显示。
本次不新增 B 站视频源、账号或接口接入。

### 保留规则

- 音声与视频允许同时播放，应用内音量分别调整。
- 返回前台时，已暂停的视频需要手动继续播放。
- 音轨选择等 KikoFlu 独有能力继续保留。
  入口采用 PiliPlus 菜单样式，名称按实际能力填写。

## 界面范围

复刻包含以下范围：

- 内嵌与全屏的视频画面。
- 播放控件与播放手势。
- 播放器弹出菜单。
- 视频播放设置。

视频详情页保留现有结构。
视频信息和“相关推荐”继续使用现有界面。

## 播放行为

| 行为 | 复刻后的规则 |
| --- | --- |
| 双击画面 | 按 PiliPlus 参照版本启用快退与快进，默认跳转 10 秒 |
| 长按加速 | 按 PiliPlus 参照版本临时加速，默认切换到 3 倍速 |
| 音量调整 | 调整视频的应用内音量，不改系统音量或音声的应用内音量 |
| 从后台返回 | 已暂停的视频保持暂停，手动继续播放 |
| 音轨选择 | 保留源提供的音轨选择，不改称“音质” |

## 新增播放能力

按参照版本补齐以下能力：

- 亮度和音量手势。
- 全屏锁定和截图。
- 缩放、画面比例和裁切。
- 循环模式和键盘快捷键。
- 字幕显示与设置。
- 后台播放和画中画。

后台播放与画中画的暂停规则尚待确认。

## 实施顺序

1. 按固定源码核对控件、菜单、设置项与平台差异。
2. 复刻内嵌与全屏界面，接入现有视频源和本地视频播放。
3. 补齐通用播放能力，保留独立音量、手动续播和音轨选择。
4. 验证界面、播放行为与各平台的系统能力。

## 验收标准

- 在相同窗口尺寸、主题、语言和文字缩放下对照播放器界面。
  核对控件位置、尺寸、图标、文案、进度条及菜单。
- 播放手势、快捷键和设置项遵循参照版本。
  播放设置跨重启保留。
- 在线视频和本地下载都能播放、跳转、切换全屏及恢复进度。
- 清晰度、字幕和音轨使用视频源实际提供的内容。
  缺少数据时不显示对应入口。
- 音声与视频同时播放时，双方的应用内音量互不影响。
- 已暂停的视频返回前台后保持暂停。
- Android、iOS、Windows、macOS 和 Linux 分别验证播放与画中画。
  未验证的平台保留未验证状态，不以其他平台的结果代替。

## 源码依据

现有代码见[视频播放器](../../lib/src/videos/ui/video_playback_panel.dart)。
保留的音量与手动续播规则见 [ADR 0005](../adr/0005-native-video-and-source-account.md)。
PiliPlus 的行为见固定提交的[播放设置](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/b2d6a5befb6dd292b9f7ad98794f3620f6dfb818/lib/pages/setting/models/play_settings.dart)、[音量控制](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/b2d6a5befb6dd292b9f7ad98794f3620f6dfb818/lib/plugin/pl_player/controller.dart)、[播放视图](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/b2d6a5befb6dd292b9f7ad98794f3620f6dfb818/lib/plugin/pl_player/view/view.dart)和[顶栏控件](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/b2d6a5befb6dd292b9f7ad98794f3620f6dfb818/lib/pages/video/widgets/header_control.dart)。
画面比例与快捷键见固定提交的[比例选项](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/b2d6a5befb6dd292b9f7ad98794f3620f6dfb818/lib/plugin/pl_player/models/video_fit_type.dart)和[快捷键](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/b2d6a5befb6dd292b9f7ad98794f3620f6dfb818/lib/pages/video/widgets/player_focus.dart)。

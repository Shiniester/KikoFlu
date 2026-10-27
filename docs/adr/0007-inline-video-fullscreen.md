# ADR 0007: 视频全屏沿用详情页中的播放器

视频全屏采用 [PiliPlus 参照版本的同页切换方式](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/b2d6a5befb6dd292b9f7ad98794f3620f6dfb818/lib/plugin/pl_player/controller.dart#L1492-L1532)。
内嵌与全屏保留同一播放会话和视频画面控件，由视频详情页调整显示范围。
这项选择让视频画面在内嵌与全屏之间保持连续。

移动端保留 KikoFlu 的方向恢复规则。
退出全屏时直接恢复详情页，方向恢复期间不单独显示竖屏全屏播放器。
原生窗口回执与 Flutter 窗口方向一致后，完成退出流程。
横屏详情页采用左侧 40% 固定播放器、右侧 60% 独立滚动的信息栏。
保持横屏进入全屏时，播放器连续展开，信息栏同步退场。
退出全屏时，播放器连续缩回详情页中的位置，信息栏同步显示。
系统禁用动画时直接恢复详情页布局。

本决策补充 [ADR 0006](0006-piliplus-video-player-parity.md)。
完整行为和验收标准见[视频播放器复刻约定](../development/video-player-piliplus-parity.md)。

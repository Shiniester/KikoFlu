# 播放条横滑请求解耦

范围：`lib/src/widgets/mini_player.dart`。

每次达到原有 36px／500px/s 阈值的横滑立即调用服务上一首／下一首。视觉只读取已提交曲目及 `PlayerTrackChangePresentation` 的方向；请求完成顺序不更新画面。服务公开接口不变，不增加请求队列。

文字使用曲目有界图层，正常 180ms。拖动偏移独立收尾；新手势停止收尾并从当前视觉偏移继续。单次手势距离单独记录，高速手势按速度方向判断，避免继承的视觉偏移误判反向请求。减少动态效果时清空偏移并立即显示最新内容。

自动覆盖：`test/audio_player_latest_request_test.dart` 使用真实服务与受控播放器验证加载中第二次横滑、过渡中反向请求与最终曲目；`test/mini_player_route_gesture_test.dart` 保持封面和控制区固定及 180ms 文字轨迹。

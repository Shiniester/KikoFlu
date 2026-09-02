import 'package:flutter/material.dart';

/// A vertical-only drag target. Using Flutter's directional recognizer keeps
/// horizontal player paging in a separate gesture arena and avoids treating a
/// fast upward queue gesture as a lyric/details page change.
class PlayerVerticalSwipeRegion extends StatefulWidget {
  const PlayerVerticalSwipeRegion({
    super.key,
    required this.child,
    this.onSwipeUp,
    this.onSwipeDown,
    this.minimumDistance = 36,
  });

  final Widget child;
  final VoidCallback? onSwipeUp;
  final VoidCallback? onSwipeDown;
  final double minimumDistance;

  @override
  State<PlayerVerticalSwipeRegion> createState() =>
      _PlayerVerticalSwipeRegionState();
}

class _PlayerVerticalSwipeRegionState extends State<PlayerVerticalSwipeRegion> {
  double _distance = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => _distance = 0,
      onVerticalDragUpdate: (details) => _distance += details.delta.dy,
      onVerticalDragCancel: () => _distance = 0,
      onVerticalDragEnd: (details) {
        final distance = _distance;
        _distance = 0;
        final velocity = details.primaryVelocity ?? 0;
        if (distance.abs() < 14) return;
        if (distance.abs() < widget.minimumDistance && velocity.abs() < 650) {
          return;
        }
        if (velocity.abs() > 250 && velocity.sign != distance.sign) return;
        if (distance < 0) {
          widget.onSwipeUp?.call();
        } else {
          widget.onSwipeDown?.call();
        }
      },
      child: widget.child,
    );
  }
}

/// Converts deliberate overscroll at a scrollable's two vertical edges into
/// player actions. Programmatic lyric positioning has no [DragStartDetails],
/// so it cannot accidentally dismiss the player or open the queue.
class PlayerScrollEdgeActions extends StatefulWidget {
  const PlayerScrollEdgeActions({
    super.key,
    required this.child,
    this.onPullDownAtTop,
    this.onPushUpAtBottom,
    this.threshold = 52,
  });

  final Widget child;
  final VoidCallback? onPullDownAtTop;
  final VoidCallback? onPushUpAtBottom;
  final double threshold;

  @override
  State<PlayerScrollEdgeActions> createState() =>
      _PlayerScrollEdgeActionsState();
}

class _PlayerScrollEdgeActionsState extends State<PlayerScrollEdgeActions> {
  double _topDistance = 0;
  double _bottomDistance = 0;
  bool _triggered = false;
  bool _startedAtTop = false;
  bool _startedAtBottom = false;

  void _reset() {
    _topDistance = 0;
    _bottomDistance = 0;
    _triggered = false;
    _startedAtTop = false;
    _startedAtBottom = false;
  }

  void _dispatch(VoidCallback? callback) {
    if (_triggered || callback == null) return;
    _triggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback();
    });
  }

  bool _handleNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical || notification.depth != 0) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _reset();
      _startedAtTop = notification.metrics.extentBefore <= 0.5;
      _startedAtBottom = notification.metrics.extentAfter <= 0.5;
      return false;
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        !_triggered) {
      if (_startedAtTop &&
          notification.overscroll < 0 &&
          notification.metrics.extentBefore <= 0.5) {
        _topDistance += -notification.overscroll;
        _bottomDistance = 0;
        if (_topDistance >= widget.threshold) {
          _dispatch(widget.onPullDownAtTop);
        }
      } else if (_startedAtBottom &&
          notification.overscroll > 0 &&
          notification.metrics.extentAfter <= 0.5) {
        _bottomDistance += notification.overscroll;
        _topDistance = 0;
        if (_bottomDistance >= widget.threshold) {
          _dispatch(widget.onPushUpAtBottom);
        }
      }
    } else if (notification is ScrollEndNotification) {
      _reset();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleNotification,
      child: widget.child,
    );
  }
}

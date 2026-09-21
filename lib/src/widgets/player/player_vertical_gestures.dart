import 'package:flutter/material.dart';

enum PlayerInitialSurface { main, queue }

enum PlayerDismissVisualMode { main, secondary }

const double playerVerticalCommitDistanceFraction = 0.22;
const double playerVerticalCommitVelocity = 650;
const double playerVerticalDismissCommitProgress = 0.78;

bool shouldCompletePlayerOpenGesture({
  required double visualProgress,
  required double velocity,
}) {
  return visualProgress >= playerVerticalCommitDistanceFraction ||
      velocity < -playerVerticalCommitVelocity;
}

bool shouldDismissPlayerGesture({
  required double visualProgress,
  required double velocity,
}) {
  return visualProgress <= playerVerticalDismissCommitProgress ||
      velocity > playerVerticalCommitVelocity;
}

bool shouldCompletePlayerDismissDrag({
  required double distance,
  required double velocity,
  required double extent,
}) {
  return distance / extent.clamp(1, double.infinity) >=
          playerVerticalCommitDistanceFraction ||
      velocity > playerVerticalCommitVelocity;
}

/// Implemented by the player route so in-page drag regions can drive the
/// route without introducing a circular dependency between the route and the
/// player screen.
abstract interface class PlayerInteractiveDismissRoute {
  void setDismissVisualMode(PlayerDismissVisualMode mode);

  bool beginVerticalDismissGesture(PlayerDismissVisualMode mode);

  void updateVerticalDismissGesture({
    required double distance,
    required double extent,
  });

  void endVerticalDismissGesture({
    required double velocity,
    required double extent,
  });

  void cancelVerticalDismissGesture();
}

class PlayerVerticalDragCallbacks {
  const PlayerVerticalDragCallbacks({
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
  });

  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  final void Function(double distance, double velocity) onEnd;
  final VoidCallback onCancel;
}

/// Coordinates the player route's downward drag without making the screen
/// own route-session state.
class PlayerVerticalDismissCoordinator {
  PlayerVerticalDismissCoordinator({
    required this.currentVisualMode,
    required this.canDismiss,
    required this.releaseTextInputFocus,
  });

  final PlayerDismissVisualMode Function() currentVisualMode;
  final bool Function({
    required bool mainBodyOnly,
    required bool allowDirectQueue,
  })
  canDismiss;
  final VoidCallback releaseTextInputFocus;

  bool _routeDismissDragAccepted = false;
  bool _reduceMotionDismissDrag = false;
  PlayerInteractiveDismissRoute? _activeDismissRoute;
  PlayerInteractiveDismissRoute? _playerRouteForModeSync;
  int _routeDismissModeSyncGeneration = 0;
  bool _disposed = false;

  PlayerVerticalDragCallbacks callbacks(
    BuildContext gestureContext, {
    bool mainBodyOnly = false,
    bool allowDirectQueue = false,
  }) => PlayerVerticalDragCallbacks(
    onStart: () => _begin(
      gestureContext,
      mainBodyOnly: mainBodyOnly,
      allowDirectQueue: allowDirectQueue,
    ),
    onUpdate: (distance) => _update(gestureContext, distance),
    onEnd: (distance, velocity) => _end(gestureContext, distance, velocity),
    onCancel: _cancel,
  );

  void scheduleVisualModeSync(BuildContext context) {
    final request = ++_routeDismissModeSyncGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed ||
          !context.mounted ||
          request != _routeDismissModeSyncGeneration) {
        return;
      }
      syncVisualMode(context);
    });
  }

  void syncVisualMode(BuildContext context) {
    if (_disposed) return;
    final route = ModalRoute.of(context);
    _playerRouteForModeSync = route is PlayerInteractiveDismissRoute
        ? route as PlayerInteractiveDismissRoute
        : null;
    _playerRouteForModeSync?.setDismissVisualMode(currentVisualMode());
  }

  void _begin(
    BuildContext gestureContext, {
    required bool mainBodyOnly,
    required bool allowDirectQueue,
  }) {
    _routeDismissDragAccepted = false;
    _reduceMotionDismissDrag = false;
    _activeDismissRoute = null;
    if (_disposed ||
        !canDismiss(
          mainBodyOnly: mainBodyOnly,
          allowDirectQueue: allowDirectQueue,
        )) {
      return;
    }
    final mode = currentVisualMode();
    releaseTextInputFocus();
    final route = ModalRoute.of(gestureContext);
    if (route is! PlayerInteractiveDismissRoute) return;
    final dismissRoute = route as PlayerInteractiveDismissRoute;
    dismissRoute.setDismissVisualMode(mode);
    if (MediaQuery.disableAnimationsOf(gestureContext)) {
      _reduceMotionDismissDrag = true;
      _activeDismissRoute = dismissRoute;
      return;
    }
    if (dismissRoute.beginVerticalDismissGesture(mode)) {
      _routeDismissDragAccepted = true;
      _activeDismissRoute = dismissRoute;
    }
  }

  void _update(BuildContext gestureContext, double distance) {
    if (!_routeDismissDragAccepted || _reduceMotionDismissDrag) return;
    _activeDismissRoute?.updateVerticalDismissGesture(
      distance: distance,
      extent: MediaQuery.sizeOf(gestureContext).height,
    );
  }

  void _end(BuildContext gestureContext, double distance, double velocity) {
    final route = _activeDismissRoute;
    final accepted = _routeDismissDragAccepted;
    final reduceMotion = _reduceMotionDismissDrag;
    _routeDismissDragAccepted = false;
    _reduceMotionDismissDrag = false;
    _activeDismissRoute = null;
    if (route == null) return;
    final extent = MediaQuery.sizeOf(gestureContext).height;
    if (reduceMotion) {
      final dismiss = shouldCompletePlayerDismissDrag(
        distance: distance,
        velocity: velocity,
        extent: extent,
      );
      if (!dismiss || !route.beginVerticalDismissGesture(currentVisualMode())) {
        return;
      }
      route.updateVerticalDismissGesture(distance: extent, extent: extent);
      route.endVerticalDismissGesture(velocity: velocity, extent: extent);
      return;
    }
    if (!accepted) return;
    route.endVerticalDismissGesture(velocity: velocity, extent: extent);
  }

  void _cancel() {
    final route = _activeDismissRoute;
    final accepted = _routeDismissDragAccepted;
    _routeDismissDragAccepted = false;
    _reduceMotionDismissDrag = false;
    _activeDismissRoute = null;
    if (accepted) route?.cancelVerticalDismissGesture();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _routeDismissModeSyncGeneration++;
    _activeDismissRoute?.cancelVerticalDismissGesture();
    _activeDismissRoute = null;
  }
}

/// A vertical-only drag target. Using Flutter's directional recognizer keeps
/// horizontal player paging in a separate gesture arena and avoids treating a
/// fast upward queue gesture as a lyric/details page change.
class PlayerVerticalSwipeRegion extends StatefulWidget {
  const PlayerVerticalSwipeRegion({
    super.key,
    required this.child,
    this.onSwipeUp,
    this.onSwipeDown,
    this.swipeUpDrag,
    this.swipeDownDrag,
    this.minimumDistance = 36,
  });

  final Widget child;
  final VoidCallback? onSwipeUp;
  final VoidCallback? onSwipeDown;
  final PlayerVerticalDragCallbacks? swipeUpDrag;
  final PlayerVerticalDragCallbacks? swipeDownDrag;
  final double minimumDistance;

  @override
  State<PlayerVerticalSwipeRegion> createState() =>
      _PlayerVerticalSwipeRegionState();
}

class _PlayerVerticalSwipeRegionState extends State<PlayerVerticalSwipeRegion> {
  double _distance = 0;
  int _progressiveDirection = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) {
        _distance = 0;
        _progressiveDirection = 0;
      },
      onVerticalDragUpdate: (details) {
        _distance += details.delta.dy;
        if (_progressiveDirection == 0 && _distance.abs() >= 8) {
          if (_distance > 0 && widget.swipeDownDrag != null) {
            _progressiveDirection = 1;
            widget.swipeDownDrag!.onStart();
          } else if (_distance < 0 && widget.swipeUpDrag != null) {
            _progressiveDirection = -1;
            widget.swipeUpDrag!.onStart();
          }
        }
        if (_progressiveDirection == 1) {
          widget.swipeDownDrag?.onUpdate(_distance.clamp(0, double.infinity));
        } else if (_progressiveDirection == -1) {
          widget.swipeUpDrag?.onUpdate((-_distance).clamp(0, double.infinity));
        }
      },
      onVerticalDragCancel: () {
        if (_progressiveDirection == 1) {
          widget.swipeDownDrag?.onCancel();
        } else if (_progressiveDirection == -1) {
          widget.swipeUpDrag?.onCancel();
        }
        _distance = 0;
        _progressiveDirection = 0;
      },
      onVerticalDragEnd: (details) {
        final distance = _distance;
        _distance = 0;
        final velocity = details.primaryVelocity ?? 0;
        if (_progressiveDirection == 1) {
          _progressiveDirection = 0;
          widget.swipeDownDrag?.onEnd(
            distance.clamp(0, double.infinity),
            velocity,
          );
          return;
        } else if (_progressiveDirection == -1) {
          _progressiveDirection = 0;
          widget.swipeUpDrag?.onEnd(
            (-distance).clamp(0, double.infinity),
            velocity,
          );
          return;
        }
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
    this.pullDownDrag,
    this.pushUpDrag,
    this.threshold = 52,
  });

  final Widget child;
  final VoidCallback? onPullDownAtTop;
  final VoidCallback? onPushUpAtBottom;
  final PlayerVerticalDragCallbacks? pullDownDrag;
  final PlayerVerticalDragCallbacks? pushUpDrag;
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
  bool _progressiveTopDrag = false;
  bool _progressiveBottomDrag = false;
  double? _progressiveOriginY;
  double _progressiveOriginDistance = 0;

  void _reset() {
    _topDistance = 0;
    _bottomDistance = 0;
    _triggered = false;
    _startedAtTop = false;
    _startedAtBottom = false;
    _progressiveTopDrag = false;
    _progressiveBottomDrag = false;
    _progressiveOriginY = null;
    _progressiveOriginDistance = 0;
  }

  void _captureProgressiveOrigin(DragUpdateDetails details, double distance) {
    _progressiveOriginY = details.globalPosition.dy;
    _progressiveOriginDistance = distance;
  }

  void _updateProgressiveDistance(DragUpdateDetails details) {
    final originY = _progressiveOriginY;
    if (originY == null) return;
    final pointerDelta = details.globalPosition.dy - originY;
    if (_progressiveTopDrag) {
      _topDistance = (_progressiveOriginDistance + pointerDelta).clamp(
        0,
        double.infinity,
      );
      widget.pullDownDrag?.onUpdate(_topDistance);
    } else if (_progressiveBottomDrag) {
      _bottomDistance = (_progressiveOriginDistance - pointerDelta).clamp(
        0,
        double.infinity,
      );
      widget.pushUpDrag?.onUpdate(_bottomDistance);
    }
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
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        (_progressiveTopDrag || _progressiveBottomDrag)) {
      _updateProgressiveDistance(notification.dragDetails!);
      return false;
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        !_triggered) {
      if (_progressiveTopDrag || _progressiveBottomDrag) {
        _updateProgressiveDistance(notification.dragDetails!);
        return false;
      }
      if (_startedAtTop &&
          notification.overscroll < 0 &&
          notification.metrics.extentBefore <= 0.5) {
        _topDistance += -notification.overscroll;
        _bottomDistance = 0;
        final drag = widget.pullDownDrag;
        if (drag != null) {
          if (!_progressiveTopDrag) {
            _progressiveTopDrag = true;
            _captureProgressiveOrigin(notification.dragDetails!, _topDistance);
            drag.onStart();
          }
          drag.onUpdate(_topDistance);
        } else if (_topDistance >= widget.threshold) {
          _dispatch(widget.onPullDownAtTop);
        }
      } else if (_startedAtBottom &&
          notification.overscroll > 0 &&
          notification.metrics.extentAfter <= 0.5) {
        _bottomDistance += notification.overscroll;
        _topDistance = 0;
        final drag = widget.pushUpDrag;
        if (drag != null) {
          if (!_progressiveBottomDrag) {
            _progressiveBottomDrag = true;
            _captureProgressiveOrigin(
              notification.dragDetails!,
              _bottomDistance,
            );
            drag.onStart();
          }
          drag.onUpdate(_bottomDistance);
        } else if (_bottomDistance >= widget.threshold) {
          _dispatch(widget.onPushUpAtBottom);
        }
      }
    } else if (notification is ScrollEndNotification) {
      if (_progressiveTopDrag) {
        widget.pullDownDrag?.onEnd(
          _topDistance,
          notification.dragDetails?.primaryVelocity ?? 0,
        );
      }
      if (_progressiveBottomDrag) {
        widget.pushUpDrag?.onEnd(
          _bottomDistance,
          notification.dragDetails?.primaryVelocity ?? 0,
        );
      }
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

  @override
  void dispose() {
    if (_progressiveTopDrag) widget.pullDownDrag?.onCancel();
    if (_progressiveBottomDrag) widget.pushUpDrag?.onCancel();
    super.dispose();
  }
}

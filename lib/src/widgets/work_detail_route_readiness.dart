import 'dart:async';

import 'package:flutter/widgets.dart';

/// Waits until a work detail route has finished entering and is visible again.
class WorkDetailRouteReadiness {
  ModalRoute<dynamic>? _route;
  NavigatorState? _navigator;
  Completer<void>? _changed;
  int _revision = 0;
  int _bindingGeneration = 0;
  int? _idleRevision;
  bool? _lastObservedCurrent;
  bool _bound = false;
  bool _disposed = false;
  bool _popped = false;

  bool get isIdle {
    if (!_bound || _disposed || _popped) return false;
    final route = _route;
    final navigator = _navigator;
    final primaryStatus = route?.animation?.status;
    final secondaryStatus = route?.secondaryAnimation?.status;
    return (route == null || route.isCurrent) &&
        (primaryStatus == null || primaryStatus == AnimationStatus.completed) &&
        (secondaryStatus == null ||
            secondaryStatus == AnimationStatus.dismissed) &&
        !(navigator?.userGestureInProgress ?? false);
  }

  void bind({
    required ModalRoute<dynamic>? route,
    required NavigatorState? navigator,
  }) {
    if (_disposed) {
      return;
    }
    if (_bound &&
        identical(_route, route) &&
        identical(_navigator, navigator)) {
      final current = route?.isCurrent ?? true;
      if (_lastObservedCurrent != current) {
        _lastObservedCurrent = current;
        _notifyChanged();
      }
      return;
    }

    _route?.animation?.removeStatusListener(_onAnimationStatus);
    _route?.secondaryAnimation?.removeStatusListener(_onAnimationStatus);
    _navigator?.userGestureInProgressNotifier.removeListener(_onGestureChanged);

    _route = route;
    _navigator = navigator;
    _lastObservedCurrent = route?.isCurrent ?? true;
    _popped = false;
    _bound = true;
    final generation = ++_bindingGeneration;
    route?.animation?.addStatusListener(_onAnimationStatus);
    route?.secondaryAnimation?.addStatusListener(_onAnimationStatus);
    navigator?.userGestureInProgressNotifier.addListener(_onGestureChanged);
    if (route != null) {
      unawaited(
        route.popped.then<void>((_) {
          if (_disposed || generation != _bindingGeneration) return;
          _popped = true;
          _notifyChanged();
        }),
      );
    }
    _notifyChanged();
  }

  Future<bool> waitForIdle() async {
    if (!_bound) return false;

    while (true) {
      if (_disposed || _popped) return false;
      if (!isIdle) {
        await _waitForChange();
        continue;
      }
      if (_idleRevision == _revision) return true;

      final revision = _revision;
      await WidgetsBinding.instance.endOfFrame;
      if (_disposed || _popped) return false;
      if (revision == _revision && isIdle) {
        _idleRevision = revision;
        return true;
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _route?.animation?.removeStatusListener(_onAnimationStatus);
    _route?.secondaryAnimation?.removeStatusListener(_onAnimationStatus);
    _navigator?.userGestureInProgressNotifier.removeListener(_onGestureChanged);
    _notifyChanged();
  }

  Future<void> _waitForChange() {
    return (_changed ??= Completer<void>()).future;
  }

  void _onAnimationStatus(AnimationStatus _) => _notifyChanged();

  void _onGestureChanged() => _notifyChanged();

  void _notifyChanged() {
    _revision++;
    final changed = _changed;
    _changed = null;
    if (changed != null && !changed.isCompleted) changed.complete();
  }
}

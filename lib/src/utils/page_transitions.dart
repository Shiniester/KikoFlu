import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/app_bottom_dock_transition.dart';

/// Uses Cupertino page transitions while retaining Android route snapshots.
class AppPageTransitionsBuilder extends CupertinoPageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _PageTransition(
    route: route,
    animation: animation,
    secondaryAnimation: secondaryAnimation,
    child: child,
  );
}

class _PageTransition extends StatefulWidget {
  const _PageTransition({
    required this.route,
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_PageTransition> createState() => _PageTransitionState();
}

class _PageTransitionState extends State<_PageTransition>
    with WidgetsBindingObserver {
  static const _dismissedAnimation = AlwaysStoppedAnimation<double>(0);
  static const _completedAnimation = AlwaysStoppedAnimation<double>(1);

  final SnapshotController _snapshotController = SnapshotController();
  late CurvedAnimation _secondaryTransitionCurve;
  NavigatorState? _gestureNavigator;
  Animation<double>? _settlingAnimation;
  bool _dragging = false;
  bool _completionScheduled = false;
  bool _semanticsRestored = false;
  bool _semanticsRestoreScheduled = false;
  bool _dockSnapshotSwitching = false;

  bool _onDockSnapshotChanged(AppBottomDockSnapshotNotification notification) {
    _snapshotController.clear();
    _snapshotController.allowSnapshotting = false;
    if (_dockSnapshotSwitching) return true;
    _dockSnapshotSwitching = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _dockSnapshotSwitching = false);
    });
    return true;
  }

  @override
  void initState() {
    super.initState();
    _secondaryTransitionCurve = _createSecondaryTransitionCurve(
      widget.secondaryAnimation,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  // This follows the next page's primary motion, not this page's secondary parallax.
  CurvedAnimation _createSecondaryTransitionCurve(Animation<double> animation) =>
      CurvedAnimation(
        parent: animation,
        curve: Curves.fastEaseInToSlowEaseOut,
        reverseCurve: Curves.fastEaseInToSlowEaseOut.flipped,
      );

  @override
  void didUpdateWidget(covariant _PageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.secondaryAnimation != widget.secondaryAnimation) {
      _secondaryTransitionCurve.dispose();
      _secondaryTransitionCurve = _createSecondaryTransitionCurve(
        widget.secondaryAnimation,
      );
    }
  }

  bool get _enabled => widget.route.isCurrent && widget.route.popGestureEnabled;

  bool _isSnapshotFrame(Animation<double> animation) =>
      (animation.status == AnimationStatus.forward ||
          animation.status == AnimationStatus.reverse) &&
      animation.value > 0 &&
      animation.value < 1;

  bool get _pageStopped =>
      widget.animation.status == AnimationStatus.completed &&
      widget.secondaryAnimation.status == AnimationStatus.dismissed &&
      widget.secondaryAnimation.value == 0 &&
      !widget.route.popGestureInProgress;

  Animation<double> _animationWithoutMotion(
    Animation<double> animation,
  ) => switch (animation.status) {
    AnimationStatus.forward || AnimationStatus.completed => _completedAnimation,
    AnimationStatus.reverse || AnimationStatus.dismissed => _dismissedAnimation,
  };

  void _startGesture({double progress = 1}) {
    if (!_enabled) return;
    _dragging = true;
    _gestureNavigator = widget.route.navigator;
    widget.route.handleStartBackGesture(progress: progress);
  }

  void _endGesture({required bool commit}) {
    if (!_dragging) return;
    _dragging = false;
    final route = widget.route;
    final animation = route.animation!;
    if (route.isCurrent && commit) {
      // Keep the current drag position instead of restarting a full-width pop.
      _gestureNavigator!.pop();
    } else if (route.isActive) {
      route.handleCancelBackGesture();
      _gestureNavigator = null;
      return;
    }
    if (animation.status == AnimationStatus.forward ||
        animation.status == AnimationStatus.reverse) {
      _settlingAnimation = animation;
      animation.addStatusListener(_onSettled);
    } else {
      _stopGesture();
    }
  }

  void _onSettled(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _stopGesture();
    }
  }

  void _stopGesture() {
    _settlingAnimation?.removeStatusListener(_onSettled);
    _settlingAnimation = null;
    _gestureNavigator?.didStopUserGesture();
    _gestureNavigator = null;
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (Theme.of(context).platform != TargetPlatform.android ||
        backEvent.isButtonEvent ||
        !_enabled) {
      return false;
    }
    _startGesture(progress: 1 - backEvent.progress);
    return _dragging;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_dragging) {
      widget.route.handleUpdateBackGestureProgress(
        progress: 1 - backEvent.progress,
      );
    }
  }

  @override
  void handleCancelBackGesture() => _endGesture(commit: false);

  @override
  void handleCommitBackGesture() => _endGesture(commit: true);

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_completionScheduled) {
      _completionScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _completionScheduled = false;
        if (!mounted || !MediaQuery.disableAnimationsOf(context)) return;
        // A theme builder does not own the route, but must finish its clock to
        // remove a reduced-motion outgoing page and complete any Hero flight.
        // ignore: invalid_use_of_protected_member
        final controller = widget.route.controller;
        if (controller == null || !controller.isAnimating) return;
        controller.value = controller.status == AnimationStatus.reverse ? 0 : 1;
      });
    }
    final platform = Theme.of(context).platform;
    final secondaryAnimation = reduceMotion
        ? _dismissedAnimation
        : widget.secondaryAnimation;
    return NotificationListener<AppBottomDockSnapshotNotification>(
      onNotification: _onDockSnapshotChanged,
      child: ClipRect(
        clipper: _ExposedPageClipper(
          curvedAnimation: _secondaryTransitionCurve,
          linearAnimation: secondaryAnimation,
          route: widget.route,
          textDirection: Directionality.of(context),
          reduceMotion: reduceMotion,
        ),
        child: AnimatedBuilder(
          animation: Listenable.merge([
            widget.animation,
            widget.secondaryAnimation,
          ]),
          child: SnapshotWidget(
            controller: _snapshotController,
            mode: SnapshotMode.permissive,
            autoresize: true,
            child: widget.child,
          ),
          builder: (context, child) {
            _snapshotController.allowSnapshotting =
                platform == TargetPlatform.android &&
                !reduceMotion &&
                !_dockSnapshotSwitching &&
                widget.route.allowSnapshotting &&
                (widget.route.popGestureInProgress ||
                    _isSnapshotFrame(widget.animation) ||
                    // Reuse the covered page's snapshot until its reveal finishes.
                    widget.secondaryAnimation.value > 0);
            final pageStopped = _pageStopped;
            if (!pageStopped) {
              _semanticsRestored = false;
            } else if (!_semanticsRestored && !_semanticsRestoreScheduled) {
              _semanticsRestoreScheduled = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _semanticsRestoreScheduled = false;
                if (!mounted || !_pageStopped) return;
                setState(() => _semanticsRestored = true);
              });
            }

            final primaryAnimation = reduceMotion
                ? _animationWithoutMotion(widget.animation)
                : widget.animation;
            return const CupertinoPageTransitionsBuilder()
                .buildTransitions<dynamic>(
                  widget.route,
                  context,
                  primaryAnimation,
                  secondaryAnimation,
                  ExcludeSemantics(
                    // Restore semantics after the final moving frame.
                    excluding: !reduceMotion && !_semanticsRestored,
                    child: ClipRect(child: child!),
                  ),
                );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopGesture();
    _secondaryTransitionCurve.dispose();
    _snapshotController.allowSnapshotting = false;
    _snapshotController.dispose();
    super.dispose();
  }
}

class _ExposedPageClipper extends CustomClipper<Rect> {
  _ExposedPageClipper({
    required this.curvedAnimation,
    required this.linearAnimation,
    required this.route,
    required this.textDirection,
    required this.reduceMotion,
  }) : super(reclip: curvedAnimation);

  final CurvedAnimation curvedAnimation;
  final Animation<double> linearAnimation;
  final PageRoute<dynamic> route;
  final TextDirection textDirection;
  final bool reduceMotion;

  @override
  Rect getClip(Size size) {
    final progress = reduceMotion
        ? 0.0
        : route.popGestureInProgress
        ? linearAnimation.value
        : curvedAnimation.value;
    if (textDirection == TextDirection.rtl) {
      return Rect.fromLTRB(
        size.width * progress,
        0,
        size.width,
        size.height,
      );
    }
    return Rect.fromLTWH(0, 0, size.width * (1 - progress), size.height);
  }

  @override
  bool shouldReclip(_ExposedPageClipper oldClipper) =>
      curvedAnimation != oldClipper.curvedAnimation ||
      linearAnimation != oldClipper.linearAnimation ||
      route != oldClipper.route ||
      textDirection != oldClipper.textDirection ||
      reduceMotion != oldClipper.reduceMotion;
}

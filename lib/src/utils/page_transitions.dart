import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Slides only the entering/leaving page; shared elements fly in the overlay.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => transitionDuration;

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
  final SnapshotController _snapshotController = SnapshotController();
  late final HorizontalDragGestureRecognizer _edgeDrag;
  NavigatorState? _gestureNavigator;
  Animation<double>? _settlingAnimation;
  bool _dragging = false;
  bool _completionScheduled = false;
  bool _semanticsRestored = false;
  bool _semanticsRestoreScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _edgeDrag = HorizontalDragGestureRecognizer(debugOwner: this)
      ..onStart = (_) {
        _startGesture();
      }
      ..onUpdate = (details) {
        if (!_dragging) return;
        widget.route.handleUpdateBackGestureProgress(
          progress:
              (widget.animation.value -
                      details.primaryDelta! / MediaQuery.sizeOf(context).width)
                  .clamp(0.0, 1.0),
        );
      }
      ..onEnd = (details) {
        final velocity =
            details.velocity.pixelsPerSecond.dx /
            MediaQuery.sizeOf(context).width;
        _endGesture(
          commit: velocity.abs() >= 1
              ? velocity > 0
              : widget.animation.value < 0.5,
        );
      }
      ..onCancel = () => _endGesture(commit: false);
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
    final transition = Stack(
      fit: StackFit.passthrough,
      children: [
        AnimatedBuilder(
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
                widget.route.allowSnapshotting &&
                (widget.route.popGestureInProgress ||
                    _isSnapshotFrame(widget.animation) ||
                    _isSnapshotFrame(widget.secondaryAnimation));
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
            final progress = reduceMotion
                ? 1.0
                : widget.route.popGestureInProgress
                ? widget.animation.value
                : Curves.ease.transform(widget.animation.value);
            return FractionalTranslation(
              translation: Offset(1 - progress, 0),
              child: Stack(
                fit: StackFit.passthrough,
                clipBehavior: Clip.none,
                children: [
                  const Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 24,
                    child: PhysicalModel(
                      color: Colors.transparent,
                      elevation: 6,
                      child: SizedBox.expand(),
                    ),
                  ),
                  ExcludeSemantics(
                    // Restore semantics after the final moving frame.
                    excluding: !reduceMotion && !_semanticsRestored,
                    child: ClipRect(child: child),
                  ),
                ],
              ),
            );
          },
        ),
        if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: math.max(20, MediaQuery.paddingOf(context).left),
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                if (_enabled) _edgeDrag.addPointer(event);
              },
            ),
          ),
      ],
    );
    return ClipRect(
      clipper: _ExposedPageClipper(widget.secondaryAnimation, widget.route),
      child: transition,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _edgeDrag.dispose();
    _stopGesture();
    _snapshotController.dispose();
    super.dispose();
  }
}

class _ExposedPageClipper extends CustomClipper<Rect> {
  _ExposedPageClipper(this.animation, this.route) : super(reclip: animation);

  final Animation<double> animation;
  final PageRoute<dynamic> route;

  @override
  Rect getClip(Size size) {
    final progress = route.navigator?.userGestureInProgress == true
        ? animation.value
        : Curves.ease.transform(animation.value);
    return Rect.fromLTWH(0, 0, size.width * (1 - progress), size.height);
  }

  @override
  bool shouldReclip(_ExposedPageClipper oldClipper) =>
      animation != oldClipper.animation || route != oldClipper.route;
}

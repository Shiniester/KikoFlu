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
  ) => _PageTransition(route: route, animation: animation, child: child);
}

class _PageTransition extends StatefulWidget {
  const _PageTransition({
    required this.route,
    required this.animation,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final Animation<double> animation;
  final Widget child;

  @override
  State<_PageTransition> createState() => _PageTransitionState();
}

class _PageTransitionState extends State<_PageTransition>
    with WidgetsBindingObserver {
  late final HorizontalDragGestureRecognizer _edgeDrag;
  NavigatorState? _gestureNavigator;
  Animation<double>? _settlingAnimation;
  bool _dragging = false;
  bool _completionScheduled = false;

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
    return Stack(
      fit: StackFit.passthrough,
      children: [
        AnimatedBuilder(
          animation: widget.animation,
          child: widget.child,
          builder: (context, child) {
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
                  ClipRect(child: child),
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _edgeDrag.dispose();
    _stopGesture();
    super.dispose();
  }
}

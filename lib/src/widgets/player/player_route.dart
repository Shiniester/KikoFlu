import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../screens/audio_player_screen.dart';
import 'player_vertical_gestures.dart';
import 'player_visual_palette.dart';

const Duration playerRouteTransitionDuration = Duration(milliseconds: 500);

AudioPlayerPageRoute<T> createAudioPlayerRoute<T>({
  PlayerVisualPalette? initialPalette,
  String? initialPaletteTrackId,
  PlayerInitialSurface initialSurface = PlayerInitialSurface.main,
  bool skipInitialTransition = false,
}) {
  return AudioPlayerPageRoute<T>(
    skipInitialTransition: skipInitialTransition,
    initialDismissVisualMode: initialSurface == PlayerInitialSurface.queue
        ? PlayerDismissVisualMode.secondary
        : PlayerDismissVisualMode.main,
    builder: (context) => AudioPlayerScreen(
      initialPalette: initialPalette,
      initialPaletteTrackId: initialPaletteTrackId,
      initialSurface: initialSurface,
    ),
  );
}

/// Frozen inputs shared by a Mini Player tap, an interactive drag preview,
/// and the final Navigator handoff.
class AudioPlayerOpenConfiguration {
  const AudioPlayerOpenConfiguration({
    required this.initialPalette,
    required this.initialPaletteTrackId,
  });

  final PlayerVisualPalette initialPalette;
  final String initialPaletteTrackId;

  AudioPlayerPageRoute<void> createRoute({
    bool handoff = false,
    PlayerInitialSurface initialSurface = PlayerInitialSurface.main,
  }) {
    return createAudioPlayerRoute<void>(
      initialPalette: initialPalette,
      initialPaletteTrackId: initialPaletteTrackId,
      initialSurface: initialSurface,
      skipInitialTransition: handoff,
    );
  }
}

Future<T?> openAudioPlayer<T>(
  BuildContext context, {
  PlayerVisualPalette? initialPalette,
  String? initialPaletteTrackId,
  PlayerInitialSurface initialSurface = PlayerInitialSurface.main,
}) {
  return Navigator.of(context).push<T>(
    createAudioPlayerRoute<T>(
      initialPalette: initialPalette,
      initialPaletteTrackId: initialPaletteTrackId,
      initialSurface: initialSurface,
    ),
  );
}

/// Shared route used by every global Mini Player entry point.
///
/// The full page always travels one viewport height. The Player Cover Page's
/// artwork consumes this route's visual progress through a staged Hero path;
/// the Player Queue Page has no artwork Hero and moves as one page.
class AudioPlayerPageRoute<T> extends PageRoute<T>
    with CupertinoRouteTransitionMixin<T>
    implements PlayerInteractiveDismissRoute {
  AudioPlayerPageRoute({
    required this.builder,
    this.skipInitialTransition = false,
    PlayerDismissVisualMode initialDismissVisualMode =
        PlayerDismissVisualMode.main,
  }) : _dismissVisualMode = ValueNotifier(initialDismissVisualMode);

  final WidgetBuilder builder;
  final bool skipInitialTransition;
  bool _verticalGestureInProgress = false;
  bool _verticalGestureOpening = false;
  double _verticalGestureStartValue = 0;
  Size _viewportSize = Size.zero;
  int _verticalSettleGeneration = 0;
  NavigatorState? _gestureNavigator;
  final ValueNotifier<PlayerDismissVisualMode> _dismissVisualMode;
  late final Animation<double> _controllerAnimation;
  late final CurvedAnimation _automaticVisualAnimation;
  late final ProxyAnimation _visualAnimation;

  @override
  Widget buildContent(BuildContext context) => builder(context);

  @override
  String? get title => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration =>
      skipInitialTransition ? Duration.zero : playerRouteTransitionDuration;

  @override
  Duration get reverseTransitionDuration => playerRouteTransitionDuration;

  @override
  Animation<double> createAnimation() {
    _controllerAnimation = super.createAnimation();
    _automaticVisualAnimation = CurvedAnimation(
      parent: _controllerAnimation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _visualAnimation = ProxyAnimation(_automaticVisualAnimation);
    return _visualAnimation;
  }

  bool get verticalGestureInProgress => _verticalGestureInProgress;

  @visibleForTesting
  double get debugTransitionValue => controller?.value ?? 0;

  @visibleForTesting
  AnimationStatus? get debugTransitionStatus => animation?.status;

  @visibleForTesting
  double get debugVisualValue => _visualAnimation.value;

  @visibleForTesting
  Duration? get debugConfiguredDuration => controller?.duration;

  @visibleForTesting
  void debugSetControllerValue(double value) {
    controller!.value = value.clamp(0.0, 1.0);
  }

  @visibleForTesting
  void debugContinueForward() {
    unawaited(controller!.forward());
  }

  @visibleForTesting
  void debugContinueReverse() {
    unawaited(controller!.reverse());
  }

  @visibleForTesting
  PlayerDismissVisualMode get debugDismissVisualMode =>
      _dismissVisualMode.value;

  @visibleForTesting
  double get debugRouteTravelDistance =>
      _viewportSize.height > 0 ? _viewportSize.height : 1;

  @visibleForTesting
  double get debugRouteTranslation => debugRouteTravelDistance;

  @visibleForTesting
  Duration get debugFullTravelDuration => playerRouteTransitionDuration;

  @visibleForTesting
  Duration debugSettleDuration({required bool showRoute}) {
    final target = showRoute ? 1.0 : 0.0;
    final remaining = ((controller?.value ?? 0) - target).abs();
    return _durationForFraction(remaining);
  }

  @override
  void setDismissVisualMode(PlayerDismissVisualMode mode) {
    if (_dismissVisualMode.value == mode) return;
    _dismissVisualMode.value = mode;
  }

  /// Takes over the just-pushed route for an upward Mini Player drag.
  bool beginVerticalOpenGesture({double initialValue = 0}) {
    final animationController = controller;
    final routeNavigator = navigator;
    if (animationController == null ||
        routeNavigator == null ||
        !isActive ||
        popGestureInProgress) {
      return false;
    }
    _beginVerticalGesture(
      opening: true,
      resetValue: _verticalGestureInProgress
          ? null
          : initialValue.clamp(0.0, 1.0),
    );
    return true;
  }

  @override
  bool beginVerticalDismissGesture(PlayerDismissVisualMode mode) {
    final animationController = controller;
    final routeNavigator = navigator;
    if (animationController == null ||
        routeNavigator == null ||
        !isCurrent ||
        popGestureInProgress) {
      return false;
    }
    setDismissVisualMode(mode);
    _beginVerticalGesture(opening: false);
    return true;
  }

  void _beginVerticalGesture({required bool opening, double? resetValue}) {
    final animationController = controller!;
    _verticalSettleGeneration++;
    animationController.stop();
    if (resetValue != null &&
        resetValue > 0 &&
        (animationController.value - resetValue).abs() > 0.0001) {
      animationController.value = resetValue;
    }
    if (opening) {
      if (animationController.status != AnimationStatus.forward) {
        // Starting without a `from` value restores forward status without
        // briefly announcing dismissed at zero and ending an active flight.
        unawaited(animationController.forward());
        animationController.stop();
      }
    } else {
      // Direct value updates preserve the controller's last direction. Mark
      // this session as a reverse transition before notifying HeroController
      // so an interactive dismissal produces a reverse artwork flight.
      unawaited(
        animationController.animateBack(
          animationController.value,
          duration: Duration.zero,
        ),
      );
      animationController.stop();
    }
    if (!_verticalGestureInProgress) {
      _verticalGestureInProgress = true;
      _gestureNavigator = navigator;
      _gestureNavigator!.didStartUserGesture();
    }
    _verticalGestureOpening = opening;
    _verticalGestureStartValue = animationController.value;
    _visualAnimation.parent = _controllerAnimation;
  }

  void updateVerticalOpenGesture({
    required double distance,
    required double extent,
  }) {
    if (!_verticalGestureInProgress || !_verticalGestureOpening) return;
    _updateVerticalGesture(distance: distance, extent: extent, opening: true);
  }

  @override
  void updateVerticalDismissGesture({
    required double distance,
    required double extent,
  }) {
    if (!_verticalGestureInProgress || _verticalGestureOpening) return;
    _updateVerticalGesture(distance: distance, extent: extent, opening: false);
  }

  void _updateVerticalGesture({
    required double distance,
    required double extent,
    required bool opening,
  }) {
    final normalizedDistance = distance / extent.clamp(1, double.infinity);
    controller!.value =
        (_verticalGestureStartValue +
                (opening ? normalizedDistance : -normalizedDistance))
            .clamp(0.0, 1.0);
  }

  Future<bool> endVerticalOpenGesture({
    required double velocity,
    required double extent,
  }) {
    if (!_verticalGestureInProgress || !_verticalGestureOpening) {
      return Future<bool>.value(false);
    }
    final showRoute = controller!.value >= 0.22 || velocity < -650;
    return _settleVerticalGesture(showRoute: showRoute);
  }

  @override
  void endVerticalDismissGesture({
    required double velocity,
    required double extent,
  }) {
    if (!_verticalGestureInProgress || _verticalGestureOpening) return;
    final dismissRoute = controller!.value <= 0.78 || velocity > 650;
    unawaited(_settleVerticalGesture(showRoute: !dismissRoute));
  }

  Future<bool> cancelVerticalOpenGesture() {
    if (!_verticalGestureInProgress || !_verticalGestureOpening) {
      return Future<bool>.value(false);
    }
    return _settleVerticalGesture(showRoute: false);
  }

  @override
  void cancelVerticalDismissGesture() {
    if (!_verticalGestureInProgress || _verticalGestureOpening) return;
    unawaited(_settleVerticalGesture(showRoute: true));
  }

  Future<bool> _settleVerticalGesture({required bool showRoute}) async {
    final animationController = controller;
    final routeNavigator = _gestureNavigator;
    if (animationController == null || routeNavigator == null) return false;
    final request = ++_verticalSettleGeneration;
    final target = showRoute ? 1.0 : 0.0;
    final duration = _durationForFraction(
      (animationController.value - target).abs(),
    );
    animationController.stop();
    try {
      if (duration == Duration.zero) {
        animationController.value = target;
      } else if (target < animationController.value) {
        await animationController
            .animateBack(target, duration: duration, curve: Curves.easeOutCubic)
            .orCancel;
      } else {
        await animationController
            .animateTo(target, duration: duration, curve: Curves.easeOutCubic)
            .orCancel;
      }
    } catch (_) {
      return false;
    }
    if (request != _verticalSettleGeneration || !_verticalGestureInProgress) {
      return false;
    }
    if (!showRoute) {
      if (isCurrent) {
        routeNavigator.pop<T>();
      } else if (isActive) {
        routeNavigator.removeRoute(this);
      }
    }
    _stopVerticalGesture();
    return showRoute;
  }

  Duration _durationForFraction(double fraction) {
    final microseconds =
        (playerRouteTransitionDuration.inMicroseconds * fraction).round();
    return Duration(microseconds: microseconds);
  }

  void _stopVerticalGesture() {
    if (!_verticalGestureInProgress) return;
    _verticalGestureInProgress = false;
    _visualAnimation.parent = _automaticVisualAnimation;
    final routeNavigator = _gestureNavigator;
    _gestureNavigator = null;
    routeNavigator?.didStopUserGesture();
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    _viewportSize = MediaQuery.sizeOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final routeAnimation = reduceMotion
        ? const AlwaysStoppedAnimation<double>(1)
        : animation;
    return ValueListenableBuilder<PlayerDismissVisualMode>(
      valueListenable: _dismissVisualMode,
      child: child,
      builder: (context, mode, child) => HeroMode(
        enabled: !reduceMotion && mode == PlayerDismissVisualMode.main,
        child: _buildVerticalSlide(context, routeAnimation, child!),
      ),
    );
  }

  Widget _buildVerticalSlide(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: animation,
        child: RepaintBoundary(child: child),
        builder: (context, child) {
          final height = MediaQuery.sizeOf(context).height;
          return Transform.translate(
            key: const ValueKey('player-route-vertical-translation'),
            offset: Offset(0, height * (1 - animation.value)),
            transformHitTests: false,
            child: child,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _verticalSettleGeneration++;
    _stopVerticalGesture();
    _visualAnimation.parent = null;
    _automaticVisualAnimation.dispose();
    _dismissVisualMode.dispose();
    super.dispose();
  }
}

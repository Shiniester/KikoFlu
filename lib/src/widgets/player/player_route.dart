import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../screens/audio_player_screen.dart';
import 'player_vertical_gestures.dart';
import 'player_visual_palette.dart';

const Duration playerRouteTransitionDuration = Duration(milliseconds: 450);

/// A measured, render-only endpoint shared by preview and root routes.
class PlayerTransitionSource {
  const PlayerTransitionSource({
    required this.miniRect,
    required this.miniPlayerBuilder,
    required this.surfaceColor,
    this.artworkRect,
    this.artworkHeroEnabled = false,
    this.tabBar,
    this.tabBarRect,
  });

  final Rect miniRect;
  final Rect? artworkRect;
  final Widget Function(BuildContext context, bool hideArtwork)
  miniPlayerBuilder;
  final Color surfaceColor;
  final bool artworkHeroEnabled;
  final Widget? tabBar;
  final Rect? tabBarRect;
}

AudioPlayerPageRoute<T> createAudioPlayerRoute<T>({
  PlayerVisualPalette? initialPalette,
  String? initialPaletteTrackId,
  PlayerTransitionSource? source,
  PlayerTransitionSource? Function()? sourceProvider,
  PlayerInitialSurface initialSurface = PlayerInitialSurface.main,
  bool skipInitialTransition = false,
}) {
  return AudioPlayerPageRoute<T>(
    skipInitialTransition: skipInitialTransition,
    source: source,
    sourceProvider: sourceProvider,
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
    this.source,
    this.sourceProvider,
  });

  final PlayerVisualPalette initialPalette;
  final String initialPaletteTrackId;
  final PlayerTransitionSource? source;
  final PlayerTransitionSource? Function()? sourceProvider;

  AudioPlayerPageRoute<void> createRoute({
    bool handoff = false,
    PlayerInitialSurface initialSurface = PlayerInitialSurface.main,
  }) {
    return createAudioPlayerRoute<void>(
      initialPalette: initialPalette,
      initialPaletteTrackId: initialPaletteTrackId,
      source: source,
      sourceProvider: sourceProvider,
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
/// The player surface is revealed upward from the captured Mini Player bounds.
/// The Player Cover Page's artwork consumes the same route progress through a
/// straight shared-element flight; queue and lyric surfaces do not attach it.
class AudioPlayerPageRoute<T> extends PageRoute<T>
    with CupertinoRouteTransitionMixin<T>
    implements PlayerInteractiveDismissRoute {
  AudioPlayerPageRoute({
    required this.builder,
    this.skipInitialTransition = false,
    this.source,
    this.sourceProvider,
    PlayerDismissVisualMode initialDismissVisualMode =
        PlayerDismissVisualMode.main,
  }) : _dismissVisualMode = ValueNotifier(initialDismissVisualMode);

  final WidgetBuilder builder;
  final bool skipInitialTransition;
  final PlayerTransitionSource? source;
  final PlayerTransitionSource? Function()? sourceProvider;
  bool _verticalGestureInProgress = false;
  bool _verticalGestureOpening = false;
  double _verticalGestureStartValue = 0;
  Size _viewportSize = Size.zero;
  int _verticalSettleGeneration = 0;
  bool _reduceMotion = false;
  AnimationStatus? _lastAnimationStatus;
  bool _dismissGeometryCaptured = true;
  PlayerTransitionSource? _activeSource;
  bool _artworkHeroAvailable = false;
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
    _activeSource = source;
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
      (_activeSource?.miniRect.top ??
              (_viewportSize.height > 0 ? _viewportSize.height : 1))
          .clamp(1.0, double.infinity);

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

  @override
  void setArtworkHeroAvailable(bool available) {
    if (_artworkHeroAvailable == available) return;
    _artworkHeroAvailable = available;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator != null) changedInternalState();
    });
  }

  @override
  bool didPop(T? result) {
    _captureDismissSource();
    return super.didPop(result);
  }

  /// Takes over the just-pushed route for an upward Mini Player drag.
  bool beginVerticalOpenGesture({double initialValue = 0}) {
    final animationController = controller;
    final routeNavigator = navigator;
    if (animationController == null ||
        routeNavigator == null ||
        !isActive ||
        (popGestureInProgress && !_verticalGestureInProgress)) {
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
        (popGestureInProgress && !_verticalGestureInProgress)) {
      return false;
    }
    setDismissVisualMode(mode);
    _beginVerticalGesture(opening: false);
    return true;
  }

  void _beginVerticalGesture({required bool opening, double? resetValue}) {
    final animationController = controller!;
    final visualValue = _visualAnimation.value;
    _verticalSettleGeneration++;
    animationController.stop();
    // Keep observers on the current visual position while changing clocks.
    _visualAnimation.parent = AlwaysStoppedAnimation(visualValue);
    animationController.value = resetValue ?? visualValue;
    if (!opening && visualValue == 1) _captureDismissSource();
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
    _visualAnimation.parent = _controllerAnimation;
    if (!_verticalGestureInProgress) {
      _verticalGestureInProgress = true;
      _gestureNavigator = navigator;
      _gestureNavigator!.didStartUserGesture();
    }
    _verticalGestureOpening = opening;
    _verticalGestureStartValue = animationController.value;
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
    final duration = _reduceMotion
        ? Duration.zero
        : _durationForFraction((animationController.value - target).abs());
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
    final status = animation.status;
    if (status == AnimationStatus.completed &&
        _lastAnimationStatus != AnimationStatus.completed) {
      _dismissGeometryCaptured = false;
    }
    _lastAnimationStatus = status;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_reduceMotion) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator == null || !_reduceMotion) return;
        final animationController = controller!;
        if (animationController.isAnimating) {
          // Completing the shared animation also ends its active Hero flight.
          final target = animationController.status == AnimationStatus.reverse
              ? 0.0
              : 1.0;
          // Preserve the result awaited by an interactive Mini Player handoff.
          animationController.stop(canceled: false);
          animationController.value = target;
        }
      });
    }
    _reduceMotion = reduceMotion;
    final routeAnimation = reduceMotion
        ? const AlwaysStoppedAnimation<double>(1)
        : animation;
    return ValueListenableBuilder<PlayerDismissVisualMode>(
      valueListenable: _dismissVisualMode,
      child: child,
      builder: (context, mode, child) => HeroMode(
        enabled: !reduceMotion && mode == PlayerDismissVisualMode.main,
        child: _buildVerticalReveal(context, routeAnimation, mode, child!),
      ),
    );
  }

  void _captureDismissSource() {
    if (_dismissGeometryCaptured) return;
    _activeSource = sourceProvider?.call() ?? _activeSource;
    _dismissGeometryCaptured = true;
  }

  Widget _buildVerticalReveal(
    BuildContext context,
    Animation<double> animation,
    PlayerDismissVisualMode mode,
    Widget child,
  ) {
    return AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: child),
      builder: (context, child) {
        final size = MediaQuery.sizeOf(context);
        final progress = animation.value.clamp(0.0, 1.0);
        final source = _activeSource;
        final sourceRect = source?.miniRect;
        final revealTop =
            (sourceRect?.top ?? size.height) * (1 - progress).clamp(0.0, 1.0);
        final miniOpacity = 1 - _fadeProgress(progress, 0, 0.20);
        final tabBarRect = source?.tabBarRect;
        return Stack(
          key: const ValueKey('player-route-vertical-reveal'),
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            ClipRect(
              key: const ValueKey('player-route-background-reveal'),
              clipper: _TopRevealClipper(revealTop),
              child: child,
            ),
            if (source != null && sourceRect != null && miniOpacity > 0) ...[
              Positioned(
                left: 0,
                right: 0,
                top: sourceRect.top,
                bottom: 0,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: miniOpacity,
                    child: ColoredBox(color: source.surfaceColor),
                  ),
                ),
              ),
              Positioned.fromRect(
                rect: sourceRect,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: Opacity(
                      key: const ValueKey('player-route-mini-player-opacity'),
                      opacity: miniOpacity,
                      child: source.miniPlayerBuilder(
                        context,
                        source.artworkHeroEnabled &&
                            mode == PlayerDismissVisualMode.main &&
                            !_reduceMotion &&
                            _artworkHeroAvailable,
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (source?.tabBar != null && tabBarRect != null && progress < 1)
              Positioned.fromRect(
                rect: tabBarRect.shift(
                  Offset(0, (size.height - tabBarRect.top) * progress),
                ),
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: KeyedSubtree(
                      key: const ValueKey('player-route-bottom-dock'),
                      child: source!.tabBar!,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  double _fadeProgress(double value, double start, double end) {
    if (value <= start) return 0;
    if (value >= end) return 1;
    final t = (value - start) / (end - start);
    return t * t * (3 - 2 * t);
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

class _TopRevealClipper extends CustomClipper<Rect> {
  const _TopRevealClipper(this.top);

  final double top;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, top.clamp(0, size.height), size.width, size.height);

  @override
  bool shouldReclip(_TopRevealClipper oldClipper) => top != oldClipper.top;
}

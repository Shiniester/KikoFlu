import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../screens/audio_player_screen.dart';
import 'player_vertical_gestures.dart';
import 'player_visual_palette.dart';

AudioPlayerPageRoute<T> createAudioPlayerRoute<T>({
  PlayerVisualPalette? initialPalette,
  String? initialPaletteTrackId,
}) {
  return AudioPlayerPageRoute<T>(
    builder: (context) => AudioPlayerScreen(
      initialPalette: initialPalette,
      initialPaletteTrackId: initialPaletteTrackId,
    ),
  );
}

Future<T?> openAudioPlayer<T>(
  BuildContext context, {
  PlayerVisualPalette? initialPalette,
  String? initialPaletteTrackId,
}) {
  return Navigator.of(context).push<T>(
    createAudioPlayerRoute<T>(
      initialPalette: initialPalette,
      initialPaletteTrackId: initialPaletteTrackId,
    ),
  );
}

/// Shared route used by every global Mini Player entry point.
///
/// The full page travels vertically to and from the Mini Player. Artwork uses
/// an independent Hero only while the semantic main page is active.
class AudioPlayerPageRoute<T> extends PageRoute<T>
    with CupertinoRouteTransitionMixin<T>
    implements PlayerInteractiveDismissRoute {
  AudioPlayerPageRoute({required this.builder});

  final WidgetBuilder builder;
  bool _verticalGestureInProgress = false;
  bool _verticalGestureOpening = false;
  double _verticalGestureStartValue = 0;
  int _verticalSettleGeneration = 0;
  NavigatorState? _gestureNavigator;
  final ValueNotifier<PlayerDismissVisualMode> _dismissVisualMode =
      ValueNotifier(PlayerDismissVisualMode.main);

  @override
  Widget buildContent(BuildContext context) => builder(context);

  @override
  String? get title => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 280);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 260);

  bool get verticalGestureInProgress => _verticalGestureInProgress;

  @visibleForTesting
  double get debugTransitionValue => controller?.value ?? 0;

  @visibleForTesting
  AnimationStatus? get debugTransitionStatus => animation?.status;

  @visibleForTesting
  PlayerDismissVisualMode get debugDismissVisualMode =>
      _dismissVisualMode.value;

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
    if (resetValue != null) animationController.value = resetValue;
    if (!opening) {
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

  void endVerticalOpenGesture({
    required double velocity,
    required double extent,
  }) {
    if (!_verticalGestureInProgress || !_verticalGestureOpening) return;
    final showRoute = controller!.value >= 0.22 || velocity < -650;
    _settleVerticalGesture(showRoute: showRoute);
  }

  @override
  void endVerticalDismissGesture({
    required double velocity,
    required double extent,
  }) {
    if (!_verticalGestureInProgress || _verticalGestureOpening) return;
    final dismissRoute = controller!.value <= 0.78 || velocity > 650;
    _settleVerticalGesture(showRoute: !dismissRoute);
  }

  void cancelVerticalOpenGesture() {
    if (!_verticalGestureInProgress || !_verticalGestureOpening) return;
    _settleVerticalGesture(showRoute: false);
  }

  @override
  void cancelVerticalDismissGesture() {
    if (!_verticalGestureInProgress || _verticalGestureOpening) return;
    _settleVerticalGesture(showRoute: true);
  }

  void _settleVerticalGesture({required bool showRoute}) {
    final animationController = controller;
    final routeNavigator = _gestureNavigator;
    if (animationController == null || routeNavigator == null) return;
    final request = ++_verticalSettleGeneration;
    final target = showRoute ? 1.0 : 0.0;
    final remaining = (animationController.value - target).abs();
    final duration = remaining <= 0.001
        ? Duration.zero
        : Duration(milliseconds: (260 * remaining).round().clamp(90, 260));
    animationController.stop();
    unawaited(() async {
      try {
        if (duration == Duration.zero) {
          animationController.value = target;
        } else if (target < animationController.value) {
          await animationController.animateBack(
            target,
            duration: duration,
            curve: Curves.fastEaseInToSlowEaseOut,
          );
        } else {
          await animationController.animateTo(
            target,
            duration: duration,
            curve: Curves.fastEaseInToSlowEaseOut,
          );
        }
      } catch (_) {
        return;
      }
      if (request != _verticalSettleGeneration || !_verticalGestureInProgress) {
        return;
      }
      if (!showRoute && isCurrent) {
        routeNavigator.pop<T>();
      }
      _stopVerticalGesture();
    }());
  }

  void _stopVerticalGesture() {
    if (!_verticalGestureInProgress) return;
    _verticalGestureInProgress = false;
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
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final routeAnimation = reduceMotion
        ? const AlwaysStoppedAnimation<double>(1)
        : _verticalGestureInProgress || popGestureInProgress
        ? animation
        : CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
    return ValueListenableBuilder<PlayerDismissVisualMode>(
      valueListenable: _dismissVisualMode,
      child: child,
      builder: (context, mode, child) => HeroMode(
        enabled: !reduceMotion && mode == PlayerDismissVisualMode.main,
        child: _buildVerticalSlide(routeAnimation, child!),
      ),
    );
  }

  Widget _buildVerticalSlide(Animation<double> animation, Widget child) {
    return ClipRect(
      child: SlideTransition(
        key: const ValueKey('player-route-vertical-slide'),
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(animation),
        transformHitTests: false,
        child: RepaintBoundary(child: child),
      ),
    );
  }

  @override
  void dispose() {
    _verticalSettleGeneration++;
    _stopVerticalGesture();
    _dismissVisualMode.dispose();
    super.dispose();
  }
}

import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';

import '../../screens/audio_player_screen.dart';
import 'player_visual_palette.dart';

Future<T?> openAudioPlayer<T>(
  BuildContext context, {
  PlayerVisualPalette? initialPalette,
  String? initialPaletteTrackId,
}) {
  return Navigator.of(context).push<T>(
    AudioPlayerPageRoute<T>(
      builder: (context) => AudioPlayerScreen(
        initialPalette: initialPalette,
        initialPaletteTrackId: initialPaletteTrackId,
      ),
    ),
  );
}

/// Shared route used by every global Mini Player entry point.
///
/// The full page is clipped at the bottom edge and revealed upward from the
/// Mini Player. Artwork travels independently through its Hero, avoiding a
/// scale transform on the gradient background.
class AudioPlayerPageRoute<T> extends PageRoute<T>
    with CupertinoRouteTransitionMixin<T> {
  AudioPlayerPageRoute({required this.builder});

  final WidgetBuilder builder;

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

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    if (Platform.isIOS && popGestureInProgress) {
      return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
        this,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    if (Platform.isIOS && animation.status == AnimationStatus.reverse) {
      return FadeTransition(opacity: animation, child: child);
    }

    final reveal = _buildBottomReveal(animation, child);
    if (!Platform.isIOS) return reveal;
    return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
      this,
      context,
      const AlwaysStoppedAnimation(1),
      const AlwaysStoppedAnimation(0),
      reveal,
    );
  }

  Widget _buildBottomReveal(Animation<double> animation, Widget child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SizedBox.expand(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ClipRect(
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: curved.value,
            child: child,
          ),
        ),
      ),
    );
  }
}

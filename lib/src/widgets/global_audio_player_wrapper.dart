import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/audio_provider.dart';
import 'app_bottom_dock_transition.dart';
import 'main_bottom_navigation_bar.dart';
import 'mini_player.dart';
import 'player/player_cover_widget.dart';

/// Global wrapper that shows the mini player on all screens except login
class GlobalAudioPlayerWrapper extends ConsumerStatefulWidget {
  final Widget child;
  final bool showMiniPlayer;
  final bool workDetailTransitionTarget;

  const GlobalAudioPlayerWrapper({
    super.key,
    required this.child,
    this.showMiniPlayer = true,
    this.workDetailTransitionTarget = false,
  });

  @override
  ConsumerState<GlobalAudioPlayerWrapper> createState() =>
      _GlobalAudioPlayerWrapperState();
}

class _GlobalAudioPlayerWrapperState
    extends ConsumerState<GlobalAudioPlayerWrapper> {
  final GlobalKey _miniPlayerKey = GlobalKey();
  bool _suspendWorkDetailDockHero = false;

  @override
  Widget build(BuildContext context) {
    final currentTrack = ref.watch(currentTrackProvider);

    final rawMiniPlayer = currentTrack.when(
      data: (track) => track != null
          ? MiniPlayer(
              key: _miniPlayerKey,
              enableArtworkHero: true,
              initialArtworkFlightTarget: widget.workDetailTransitionTarget
                  ? PlayerArtworkFlightTarget.none
                  : PlayerArtworkFlightTarget.main,
              onArtworkHeroActivationChanged: widget.workDetailTransitionTarget
                  ? (active) {
                      if (mounted && _suspendWorkDetailDockHero != active) {
                        setState(() => _suspendWorkDetailDockHero = active);
                      }
                    }
                  : null,
            )
          : const SizedBox.shrink(),
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
    final hasMiniPlayer = currentTrack.asData?.value != null;
    final miniPlayer = !hasMiniPlayer
        ? rawMiniPlayer
        : widget.workDetailTransitionTarget && !_suspendWorkDetailDockHero
        ? AppBottomDockMiniPlayerHero.target(child: rawMiniPlayer)
        : widget.workDetailTransitionTarget
        ? rawMiniPlayer
        : AppBottomDockMiniPlayerHero.source(child: rawMiniPlayer);

    final content = Column(
      children: [
        Expanded(child: widget.child),
        if (widget.showMiniPlayer) miniPlayer,
      ],
    );
    final body =
        widget.workDetailTransitionTarget &&
            MediaQuery.orientationOf(context) == Orientation.portrait
        ? Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              content,
              Align(
                alignment: Alignment.bottomCenter,
                child: AppBottomDockTabBarHero.offstageTarget(
                  height: MainBottomNavigationBar.layoutExtent(context),
                ),
              ),
            ],
          )
        : content;
    return AppBottomDockTransitionScope(child: Scaffold(body: body));
  }
}

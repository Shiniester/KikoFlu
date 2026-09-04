import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/audio_provider.dart';
import 'app_bottom_dock.dart';
import 'app_bottom_dock_transition.dart';
import 'mini_player.dart';
import 'player/player_cover_widget.dart';

/// Global wrapper that shows the mini player on all screens except login
class GlobalAudioPlayerWrapper extends ConsumerStatefulWidget {
  final Widget child;
  final bool showMiniPlayer;
  final AppBottomDockRole bottomDockRole;

  const GlobalAudioPlayerWrapper({
    super.key,
    required this.child,
    this.showMiniPlayer = true,
  }) : bottomDockRole = AppBottomDockRole.source;

  const GlobalAudioPlayerWrapper.workDetails({
    super.key,
    required this.child,
    this.showMiniPlayer = true,
  }) : bottomDockRole = AppBottomDockRole.workDetailsTarget;

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
    final isWorkDetailsTarget =
        widget.bottomDockRole == AppBottomDockRole.workDetailsTarget;

    final rawMiniPlayer = currentTrack.when(
      data: (track) => track != null
          ? MiniPlayer(
              key: _miniPlayerKey,
              enableArtworkHero: true,
              initialArtworkFlightTarget: isWorkDetailsTarget
                  ? PlayerArtworkFlightTarget.none
                  : PlayerArtworkFlightTarget.main,
              onArtworkHeroActivationChanged: isWorkDetailsTarget
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
        : isWorkDetailsTarget && !_suspendWorkDetailDockHero
        ? AppBottomDockMiniPlayerHero.target(child: rawMiniPlayer)
        : isWorkDetailsTarget
        ? rawMiniPlayer
        : AppBottomDockMiniPlayerHero.source(child: rawMiniPlayer);

    final content = Column(
      children: [
        Expanded(child: widget.child),
        if (widget.showMiniPlayer) miniPlayer,
      ],
    );
    final body =
        isWorkDetailsTarget &&
            MediaQuery.orientationOf(context) == Orientation.portrait
        ? Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              content,
              Align(
                alignment: Alignment.bottomCenter,
                child: AppBottomDockTabBarHero.offstageTarget(
                  height: AppBottomDock.layoutExtent(context),
                ),
              ),
            ],
          )
        : content;
    return AppBottomDockTransitionScope(child: Scaffold(body: body));
  }
}

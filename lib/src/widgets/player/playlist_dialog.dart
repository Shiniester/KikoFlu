import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/audio_tap_playlist_mode.dart';
import '../../models/audio_track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../utils/l10n_extensions.dart';
import '../../utils/local_file_url.dart';
import 'player_glass_surface.dart';
import 'player_cover_widget.dart';
import 'player_action_icons.dart';
import 'player_vertical_gestures.dart';

const List<AudioTapPlaylistMode> _playlistModeMenuOrder = [
  AudioTapPlaylistMode.addToQueue,
  AudioTapPlaylistMode.playNext,
  AudioTapPlaylistMode.replaceQueue,
];

Future<bool> confirmClearPlaybackQueue(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => PlayerGlassAlertDialog(
          title: Text(S.of(dialogContext).clearPlaybackQueueTitle),
          content: Text(S.of(dialogContext).clearPlaybackQueueMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(S.of(dialogContext).cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(S.of(dialogContext).clear),
            ),
          ],
        ),
      ) ??
      false;
}

/// Reusable queue content for the player page and legacy dialog entry points.
class PlayerQueueSurface extends ConsumerStatefulWidget {
  const PlayerQueueSurface({
    super.key,
    this.onClose,
    this.onTrackSelected,
    this.onClear,
    this.onDismissRequested,
    this.dismissDrag,
    this.showCloseButton = false,
    this.horizontalPadding = 8,
    this.artworkHeroTarget = PlayerArtworkFlightTarget.none,
  });

  final VoidCallback? onClose;
  final VoidCallback? onTrackSelected;
  final Future<void> Function()? onClear;
  final VoidCallback? onDismissRequested;
  final PlayerVerticalDragCallbacks? dismissDrag;
  final bool showCloseButton;
  final double horizontalPadding;
  final PlayerArtworkFlightTarget artworkHeroTarget;

  @override
  ConsumerState<PlayerQueueSurface> createState() => _PlayerQueueSurfaceState();
}

class _PlayerQueueSurfaceState extends ConsumerState<PlayerQueueSurface> {
  @override
  Widget build(BuildContext context) {
    final queueAsync = ref.watch(queueProvider);
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;
    final authState = ref.watch(authProvider);
    final tracks =
        queueAsync.valueOrNull ?? ref.read(audioPlayerServiceProvider).queue;
    final currentIndex = tracks.indexWhere(
      (track) => track.id == currentTrack?.id,
    );
    final colorScheme = Theme.of(context).colorScheme;
    final queueMetaStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant);

    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (currentTrack != null)
            PlayerVerticalSwipeRegion(
              onSwipeDown: widget.onDismissRequested,
              swipeDownDrag: widget.dismissDrag,
              child: _NowPlayingQueueHeader(
                track: currentTrack,
                horizontalPadding: widget.horizontalPadding,
                coverUrl: _resolveCoverUrl(
                  currentTrack,
                  host: authState.host,
                  token: authState.token,
                ),
                artworkHeroTarget: widget.artworkHeroTarget,
              ),
            ),
          PlayerVerticalSwipeRegion(
            key: const ValueKey('player-queue-title-dismiss-surface'),
            onSwipeDown: widget.onDismissRequested,
            swipeDownDrag: widget.dismissDrag,
            child: Padding(
              key: const ValueKey('player-queue-title-bar'),
              padding: EdgeInsets.fromLTRB(
                widget.horizontalPadding,
                8,
                widget.horizontalPadding,
                10,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 68,
                    child: Text(
                      tracks.isEmpty
                          ? '0 / 0'
                          : '${currentIndex < 0 ? 0 : currentIndex + 1} / ${tracks.length}',
                      style: queueMetaStyle,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      S.of(context).playlistTitle,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 68,
                    child: tracks.isEmpty || widget.onClear == null
                        ? const SizedBox.shrink()
                        : TextButton(
                            onPressed: widget.onClear,
                            style: TextButton.styleFrom(
                              foregroundColor: colorScheme.onSurfaceVariant,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              minimumSize: const Size(0, 36),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                            child: Text(
                              S.of(context).clear,
                              style: queueMetaStyle,
                            ),
                          ),
                  ),
                  if (widget.showCloseButton)
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: tracks.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(S.of(context).playlistEmpty),
                    ),
                  )
                : PlayerScrollEdgeActions(
                    onPullDownAtTop: widget.onDismissRequested,
                    pullDownDrag: widget.dismissDrag,
                    child: ReorderableListView.builder(
                      key: const ValueKey('player-queue-list'),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: ClampingScrollPhysics(),
                      ),
                      itemCount: tracks.length,
                      buildDefaultDragHandles: false,
                      proxyDecorator: (child, index, animation) => child,
                      onReorderItem: (oldIndex, newIndex) {
                        ref
                            .read(audioPlayerControllerProvider.notifier)
                            .moveTrack(oldIndex, newIndex);
                      },
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        final isCurrentTrack = track.id == currentTrack?.id;
                        final coverUrl = _resolveCoverUrl(
                          track,
                          host: authState.host,
                          token: authState.token,
                        );
                        return ReorderableDelayedDragStartListener(
                          key: ValueKey(track.id),
                          index: index,
                          child: _QueueTrackTile(
                            track: track,
                            horizontalPadding: widget.horizontalPadding,
                            coverUrl: coverUrl,
                            isCurrentTrack: isCurrentTrack,
                            onTap: () async {
                              await ref
                                  .read(audioPlayerControllerProvider.notifier)
                                  .skipToIndex(index);
                              widget.onTrackSelected?.call();
                            },
                            onRemove: () => ref
                                .read(audioPlayerControllerProvider.notifier)
                                .removeTrackAt(index),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              widget.horizontalPadding,
              12,
              widget.horizontalPadding,
              16,
            ),
            child: const Align(
              alignment: Alignment.centerLeft,
              child: PlaylistModePill(),
            ),
          ),
        ],
      ),
    );
  }
}

class _NowPlayingQueueHeader extends StatelessWidget {
  const _NowPlayingQueueHeader({
    required this.track,
    required this.coverUrl,
    required this.horizontalPadding,
    required this.artworkHeroTarget,
  });

  final AudioTrack track;
  final String? coverUrl;
  final double horizontalPadding;
  final PlayerArtworkFlightTarget artworkHeroTarget;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('player-queue-now-playing'),
      padding: EdgeInsets.fromLTRB(horizontalPadding, 16, horizontalPadding, 8),
      child: Row(
        children: [
          _QueueArtwork(
            key: const ValueKey('player-queue-now-playing-artwork'),
            track: track,
            url: coverUrl,
            heroTarget: artworkHeroTarget,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Transform.translate(
              offset: const Offset(0, 1),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontSize: 14,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (track.artist?.trim().isNotEmpty == true)
                    Text(
                      track.artist!.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueTrackTile extends StatelessWidget {
  const _QueueTrackTile({
    required this.track,
    required this.coverUrl,
    required this.isCurrentTrack,
    required this.horizontalPadding,
    required this.onTap,
    required this.onRemove,
  });

  final AudioTrack track;
  final String? coverUrl;
  final bool isCurrentTrack;
  final double horizontalPadding;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Material(
        key: ValueKey('player-queue-track-${track.id}'),
        color: isCurrentTrack
            ? colorScheme.onSurface.withValues(alpha: 0.10)
            : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                _QueueArtwork(
                  key: ValueKey('player-queue-artwork-${track.id}'),
                  track: track,
                  url: coverUrl,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Transform.translate(
                    offset: const Offset(0, 1),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontSize: 12.5,
                                height: 1.12,
                                fontWeight: isCurrentTrack
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                        ),
                        if (track.artist?.trim().isNotEmpty == true)
                          Text(
                            track.artist!.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ),
                if (isCurrentTrack)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(Icons.graphic_eq, color: colorScheme.primary),
                  ),
                PlayerCompactAction(
                  tooltip: S.of(context).remove,
                  onPressed: onRemove,
                  icon: Icons.remove,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueArtwork extends StatelessWidget {
  const _QueueArtwork({
    super.key,
    required this.track,
    required this.url,
    this.heroTarget = PlayerArtworkFlightTarget.none,
  });

  final AudioTrack track;
  final String? url;
  final PlayerArtworkFlightTarget heroTarget;

  @override
  Widget build(BuildContext context) {
    return PlayerArtworkHero(
      trackId: track.id,
      target: heroTarget,
      cornerRadius: PlayerCompactArtwork.cornerRadius,
      flightChild: PlayerCompactArtwork(
        track: track,
        url: url,
        forFlight: true,
      ),
      child: PlayerCompactArtwork(track: track, url: url),
    );
  }
}

String? _resolveCoverUrl(
  AudioTrack track, {
  required String? host,
  required String? token,
}) {
  if (LocalFileUrl.isLocalFileUrl(track.artworkUrl)) return track.artworkUrl;
  if (track.workId == null || host == null || host.isEmpty) {
    return track.artworkUrl;
  }
  var normalizedHost = host;
  if (!normalizedHost.startsWith('http://') &&
      !normalizedHost.startsWith('https://')) {
    normalizedHost = 'https://$normalizedHost';
  }
  return token != null && token.isNotEmpty
      ? '$normalizedHost/api/cover/${track.workId}?token=$token'
      : '$normalizedHost/api/cover/${track.workId}';
}

/// Legacy dialog wrapper kept for non-player entry points.
class PlaylistDialog extends ConsumerWidget {
  const PlaylistDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final borderRadius = BorderRadius.circular(24);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: borderRadius),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.76,
          width: MediaQuery.sizeOf(context).width.clamp(320, 720),
          child: PlayerQueueSurface(
            showCloseButton: true,
            onClose: () => Navigator.of(context).pop(),
            onTrackSelected: () => Navigator.of(context).pop(),
            onClear: () async {
              if (!await confirmClearPlaybackQueue(context)) return;
              await ref
                  .read(audioPlayerControllerProvider.notifier)
                  .clearQueueAndStop();
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ),
      ),
    );
  }

  static void show(BuildContext context) {
    showDialog(context: context, builder: (_) => const PlaylistDialog());
  }
}

class PlaylistModePill extends ConsumerStatefulWidget {
  const PlaylistModePill({super.key});

  @override
  ConsumerState<PlaylistModePill> createState() => _PlaylistModePillState();
}

class _PlaylistModePillState extends ConsumerState<PlaylistModePill> {
  bool _expanded = false;
  final GlobalKey _pillKey = GlobalKey();
  double? _pillWidth;

  void _toggleExpanded() {
    if (!_expanded) {
      final box = _pillKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) _pillWidth = box.size.width;
    }
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(audioTapPlaylistModeProvider);
    final colors = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: duration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomLeft,
          child: !_expanded
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    width: _pillWidth,
                    child: PlayerTransientGlassSurface(
                      key: const ValueKey('playlist-mode-expanded-options'),
                      borderRadius: BorderRadius.circular(14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final option in _playlistModeMenuOrder)
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                key: ValueKey(
                                  'playlist-mode-option-${option.name}',
                                ),
                                onTap: () {
                                  ref
                                      .read(
                                        audioTapPlaylistModeProvider.notifier,
                                      )
                                      .updateMode(option);
                                  setState(() => _expanded = false);
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        PlaylistModeToggle.modeIcon(option),
                                        size: 19,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          option.localizedName(context),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Icon(
                                        Icons.check,
                                        size: 18,
                                        color: option == mode
                                            ? colors.primary
                                            : Colors.transparent,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
        Semantics(
          button: true,
          expanded: _expanded,
          label:
              '${S.of(context).audioTapPlaylistMode}: ${mode.localizedName(context)}',
          child: SizedBox(
            key: _pillKey,
            child: PlayerGlassSurface(
              key: const ValueKey('playlist-mode-pill'),
              onTap: _toggleExpanded,
              borderRadius: BorderRadius.circular(999),
              borderColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(PlaylistModeToggle.modeIcon(mode), size: 20),
                  const SizedBox(width: 8),
                  Flexible(child: Text(mode.localizedName(context))),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: duration,
                    child: const Icon(Icons.keyboard_arrow_up, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class PlaylistModeToggle extends ConsumerWidget {
  const PlaylistModeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(audioTapPlaylistModeProvider);
    return PopupMenuButton<AudioTapPlaylistMode>(
      tooltip:
          '${S.of(context).audioTapPlaylistMode}: ${mode.localizedName(context)}',
      initialValue: mode,
      icon: Icon(modeIcon(mode)),
      onSelected: (nextMode) {
        ref.read(audioTapPlaylistModeProvider.notifier).updateMode(nextMode);
      },
      itemBuilder: (context) => [
        for (final option in _playlistModeMenuOrder)
          CheckedPopupMenuItem(
            value: option,
            checked: option == mode,
            child: Text(option.localizedName(context)),
          ),
      ],
    );
  }

  static IconData modeIcon(AudioTapPlaylistMode mode) {
    return switch (mode) {
      AudioTapPlaylistMode.replaceQueue => Icons.playlist_play,
      AudioTapPlaylistMode.addToQueue => Icons.playlist_add,
      AudioTapPlaylistMode.playNext => playerPlayNextIcon,
    };
  }
}

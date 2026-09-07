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
  });

  final VoidCallback? onClose;
  final VoidCallback? onTrackSelected;
  final Future<void> Function()? onClear;
  final VoidCallback? onDismissRequested;
  final PlayerVerticalDragCallbacks? dismissDrag;
  final bool showCloseButton;
  final double horizontalPadding;

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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final queueMetaStyle = theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final nowPlayingMetadataHeight = _reservedQueueMetadataHeight(
      context,
      titleStyle:
          theme.textTheme.titleMedium?.copyWith(
            fontSize: 14,
            height: 1.15,
            fontWeight: FontWeight.w700,
          ) ??
          const TextStyle(
            fontSize: 14,
            height: 1.15,
            fontWeight: FontWeight.w700,
          ),
      artistStyle:
          theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ) ??
          TextStyle(color: colorScheme.onSurfaceVariant),
    );
    final trackMetadataHeight = _reservedQueueMetadataHeight(
      context,
      titleStyle:
          theme.textTheme.titleMedium?.copyWith(
            fontSize: 12.5,
            height: 1.12,
            fontWeight: FontWeight.w700,
          ) ??
          const TextStyle(
            fontSize: 12.5,
            height: 1.12,
            fontWeight: FontWeight.w700,
          ),
      artistStyle:
          theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ) ??
          TextStyle(color: colorScheme.onSurfaceVariant),
    );
    final extendsBeyondContent = widget.horizontalPadding == 10;
    final titleSideWidth = extendsBeyondContent ? 78.0 : 68.0;
    final clearButton = TextButton(
      key: const ValueKey('player-queue-clear-button'),
      onPressed: widget.onClear,
      style: TextButton.styleFrom(
        foregroundColor: colorScheme.onSurfaceVariant,
        padding: extendsBeyondContent
            ? const EdgeInsets.symmetric(horizontal: 10)
            : EdgeInsets.zero,
        minimumSize: extendsBeyondContent ? Size.zero : const Size(48, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        alignment: extendsBeyondContent
            ? Alignment.center
            : Alignment.centerRight,
      ),
      child: Text(S.of(context).clear, style: queueMetaStyle),
    );

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
                metadataHeight: nowPlayingMetadataHeight,
                coverUrl: _resolveCoverUrl(
                  currentTrack,
                  host: authState.host,
                  token: authState.token,
                ),
              ),
            ),
          PlayerVerticalSwipeRegion(
            key: const ValueKey('player-queue-title-dismiss-surface'),
            onSwipeDown: widget.onDismissRequested,
            swipeDownDrag: widget.dismissDrag,
            child: Padding(
              key: const ValueKey('player-queue-title-bar'),
              padding: EdgeInsets.fromLTRB(
                extendsBeyondContent ? 0 : widget.horizontalPadding,
                8,
                extendsBeyondContent ? 0 : widget.horizontalPadding,
                10,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: titleSideWidth,
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: extendsBeyondContent ? 10 : 0,
                      ),
                      child: Text(
                        tracks.isEmpty
                            ? '0 / 0'
                            : '${currentIndex < 0 ? 0 : currentIndex + 1} / ${tracks.length}',
                        style: queueMetaStyle,
                      ),
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
                    width: titleSideWidth,
                    child: tracks.isEmpty || widget.onClear == null
                        ? const SizedBox.shrink()
                        : Align(
                            alignment: Alignment.centerRight,
                            child: extendsBeyondContent
                                ? IntrinsicWidth(
                                    child: SizedBox(
                                      height: 36,
                                      child: clearButton,
                                    ),
                                  )
                                : SizedBox(
                                    width: 48,
                                    height: 36,
                                    child: clearButton,
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
                            metadataHeight: trackMetadataHeight,
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
    required this.metadataHeight,
  });

  final AudioTrack track;
  final String? coverUrl;
  final double horizontalPadding;
  final double metadataHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle =
        theme.textTheme.titleMedium?.copyWith(
          fontSize: 14,
          height: 1.15,
          fontWeight: FontWeight.w700,
        ) ??
        const TextStyle(
          fontSize: 14,
          height: 1.15,
          fontWeight: FontWeight.w700,
        );
    final artistStyle =
        theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ) ??
        TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      key: const ValueKey('player-queue-now-playing'),
      padding: EdgeInsets.fromLTRB(horizontalPadding, 16, horizontalPadding, 8),
      child: Row(
        children: [
          _QueueArtwork(
            key: const ValueKey('player-queue-now-playing-artwork'),
            track: track,
            url: coverUrl,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              key: const ValueKey('player-queue-now-playing-metadata'),
              height: metadataHeight,
              child: Align(
                alignment: Alignment.centerLeft,
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
                        style: titleStyle,
                      ),
                      if (track.artist?.trim().isNotEmpty == true)
                        Text(
                          track.artist!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: artistStyle,
                        ),
                    ],
                  ),
                ),
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
    required this.metadataHeight,
    required this.onTap,
    required this.onRemove,
  });

  final AudioTrack track;
  final String? coverUrl;
  final bool isCurrentTrack;
  final double horizontalPadding;
  final double metadataHeight;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final titleStyle =
        theme.textTheme.titleMedium?.copyWith(
          fontSize: 12.5,
          height: 1.12,
          fontWeight: isCurrentTrack ? FontWeight.w700 : FontWeight.w500,
        ) ??
        TextStyle(
          fontSize: 12.5,
          height: 1.12,
          fontWeight: isCurrentTrack ? FontWeight.w700 : FontWeight.w500,
        );
    final artistStyle =
        theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ) ??
        TextStyle(color: colorScheme.onSurfaceVariant);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            left: -10,
            right: -10,
            child: Material(
              key: ValueKey('player-queue-track-${track.id}'),
              color: isCurrentTrack
                  ? colorScheme.onSurface.withValues(alpha: 0.10)
                  : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          Material(
            key: ValueKey('player-queue-track-content-${track.id}'),
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(14),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              splashFactory: NoSplash.splashFactory,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    _QueueArtwork(
                      key: ValueKey('player-queue-artwork-${track.id}'),
                      track: track,
                      url: coverUrl,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        key: ValueKey('player-queue-metadata-${track.id}'),
                        height: metadataHeight,
                        child: Align(
                          alignment: Alignment.centerLeft,
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
                                  style: titleStyle,
                                ),
                                if (track.artist?.trim().isNotEmpty == true)
                                  Text(
                                    track.artist!.trim(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: artistStyle,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      key: ValueKey(
                        'player-queue-current-indicator-slot-${track.id}',
                      ),
                      width: 36,
                      child: isCurrentTrack
                          ? Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Icon(
                                Icons.graphic_eq,
                                color: colorScheme.primary,
                              ),
                            )
                          : null,
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
        ],
      ),
    );
  }
}

class _QueueArtwork extends StatelessWidget {
  const _QueueArtwork({super.key, required this.track, required this.url});

  final AudioTrack track;
  final String? url;

  @override
  Widget build(BuildContext context) {
    return PlayerCompactArtwork(track: track, url: url);
  }
}

double _reservedQueueMetadataHeight(
  BuildContext context, {
  required TextStyle titleStyle,
  required TextStyle artistStyle,
}) {
  final textScaler = MediaQuery.textScalerOf(context);
  final textDirection = Directionality.of(context);

  double lineHeight(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: 'Hg', style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final height = painter.preferredLineHeight;
    painter.dispose();
    return height;
  }

  final textHeight = lineHeight(titleStyle) * 2 + lineHeight(artistStyle);
  return textHeight < PlayerCompactArtwork.height
      ? PlayerCompactArtwork.height
      : textHeight;
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

class PlaylistModePill extends ConsumerWidget {
  const PlaylistModePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(audioTapPlaylistModeProvider);
    final modeIndex = _playlistModeMenuOrder.indexOf(mode);
    final nextMode =
        _playlistModeMenuOrder[(modeIndex + 1) % _playlistModeMenuOrder.length];
    return Semantics(
      button: true,
      label:
          '${S.of(context).audioTapPlaylistMode}: ${mode.localizedName(context)}',
      child: SizedBox(
        key: const ValueKey('playlist-mode-pill-tap-target'),
        height: 48,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            PlayerGlassSurface(
              key: const ValueKey('playlist-mode-pill'),
              borderRadius: BorderRadius.circular(999),
              borderColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(PlaylistModeToggle.modeIcon(mode), size: 18),
                  const SizedBox(width: 8),
                  Flexible(child: Text(mode.localizedName(context))),
                ],
              ),
            ),
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => ref
                      .read(audioTapPlaylistModeProvider.notifier)
                      .updateMode(nextMode),
                  borderRadius: BorderRadius.circular(999),
                  overlayColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  splashFactory: NoSplash.splashFactory,
                ),
              ),
            ),
          ],
        ),
      ),
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

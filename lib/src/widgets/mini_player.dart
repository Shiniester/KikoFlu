import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../models/audio_track.dart';
import '../providers/artwork_theme_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/lyric_provider.dart';
import '../providers/player_lyric_style_provider.dart';
import '../services/audio_player_service.dart';
import '../utils/snackbar_util.dart';
import 'volume_control.dart';
import 'player/player_cover_widget.dart';
import 'player/player_launch_region.dart';
import 'player/player_route.dart';
import 'player/player_track_layers.dart';
import 'player/player_visual_palette.dart';

class MiniPlayer extends ConsumerStatefulWidget {
  final bool enableArtworkHero;
  final PlayerArtworkFlightTarget initialArtworkFlightTarget;
  final ValueChanged<bool>? onArtworkHeroActivationChanged;

  const MiniPlayer({
    super.key,
    this.enableArtworkHero = true,
    this.initialArtworkFlightTarget = PlayerArtworkFlightTarget.main,
    this.onArtworkHeroActivationChanged,
  });

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  String? _lastTrackId;
  bool _isAdjustingVolume = false;
  double _tempVolume = 1.0;

  @override
  Widget build(BuildContext context) {
    final currentTrack = ref.watch(currentTrackProvider);
    final currentArtwork = ref.watch(currentArtworkDescriptorProvider);
    final isMiniPlayerVisible = ref.watch(miniPlayerVisibilityProvider);
    final artworkHeroEnabled = widget.enableArtworkHero;

    // 启用自动字幕加载器
    ref.watch(lyricAutoLoaderProvider);

    final player = currentTrack.when(
      data: (track) {
        // A newly loaded track always re-opens a Mini Player that the user
        // previously dismissed. Dismissal clears the queue asynchronously, so
        // keeping the old id until the null event also avoids a re-show race.
        if (track == null) {
          _lastTrackId = null;
        } else if (_lastTrackId != track.id) {
          _lastTrackId = track.id;
          if (!isMiniPlayerVisible) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                ref.read(miniPlayerVisibilityProvider.notifier).show();
              }
            });
          }
        }

        if (track == null || !isMiniPlayerVisible) {
          return const SizedBox.shrink();
        }

        final artwork = currentArtwork?.trackIdentity == track.id
            ? currentArtwork
            : null;
        final workCoverUrl = artwork?.source;

        // Start the low-resolution seed extraction while the Mini Player is
        // visible. The same stable seed is shared with the application theme
        // and the full player during track changes.
        final playerTheme = Theme.of(context);
        final artworkThemeSeed = ref.watch(artworkThemeSeedProvider).seed;
        final preparedPalette = PlayerVisualPalette.fromDominant(
          artworkThemeSeed ?? playerTheme.colorScheme.primary,
          brightness: playerTheme.brightness,
          accent: playerTheme.colorScheme.primary,
          onAccent: playerTheme.colorScheme.onPrimary,
        );

        return PlayerLaunchRegion(
          sessionIdentity: track.id,
          createConfiguration: () {
            return AudioPlayerOpenConfiguration(
              initialPalette: preparedPalette,
              initialPaletteTrackId: track.id,
            );
          },
          artworkHeroEnabled:
              artworkHeroEnabled && !MediaQuery.disableAnimationsOf(context),
          artworkBuilder: (context) =>
              _buildArtworkImage(context, track, workCoverUrl: workCoverUrl),
          initialArtworkFlightTarget: widget.initialArtworkFlightTarget,
          onArtworkHeroActivationChanged: widget.onArtworkHeroActivationChanged,
          builder: (context, launcher, artwork) => Dismissible(
            key: const ValueKey('mini-player-dismissible'),
            direction: DismissDirection.down,
            background: Container(color: Colors.transparent),
            confirmDismiss: (_) async =>
                launcher.allowPendingMiniPlayerDismiss(),
            onDismissed: (direction) {
              unawaited(
                ref
                    .read(audioPlayerControllerProvider.notifier)
                    .dismissMiniPlayer(),
              );
            },
            child: Consumer(
              builder: (context, ref, child) {
                final isPlaying = ref.watch(isPlayingProvider);
                final hasLyrics = ref.watch(
                  lyricControllerProvider.select(
                    (state) => state.lyrics.isNotEmpty,
                  ),
                );
                final hasCurrentLyric = ref.watch(
                  currentLyricTextProvider.select((lyric) => lyric != null),
                );
                final shouldShowLyric =
                    isPlaying && hasLyrics && hasCurrentLyric;
                final playerHeight = shouldShowLyric ? 88.0 : 72.0;

                final playerContent = Container(
                  height: playerHeight,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    border: Border(
                      top: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.outline.withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Column(
                    children: [
                      const _MiniPlayerProgressArea(),
                      // Player controls
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final isPortrait =
                                MediaQuery.orientationOf(context) ==
                                Orientation.portrait;
                            final leadingInset = isPortrait
                                ? (constraints.maxWidth / 8 - 32)
                                      .clamp(0.0, double.infinity)
                                      .toDouble()
                                : 16.0;
                            final trailingInset = isPortrait ? 0.0 : 16.0;
                            return Padding(
                              padding: EdgeInsets.fromLTRB(
                                leadingInset,
                                8,
                                trailingInset,
                                8,
                              ),
                              child: Row(
                                children: [
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: launcher.openPlayer,
                                    child: artwork,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _MiniPlayerTrackSwitcher(
                                      track: track,
                                      presentation: ref.watch(
                                        playerTrackChangePresentationProvider,
                                      ),
                                      onTap: launcher.openPlayer,
                                      onPrevious: () =>
                                          _skipTrack(context, next: false),
                                      onNext: () =>
                                          _skipTrack(context, next: true),
                                    ),
                                  ),
                                  _buildVolumeControl(),
                                  if (isPortrait)
                                    SizedBox(
                                      width: constraints.maxWidth / 4,
                                      child: _MiniPlayerAlignedControls(
                                        onQueuePressed: () async {
                                          await launcher.openQueue();
                                        },
                                      ),
                                    )
                                  else
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const _MiniPlayerPlayButton(),
                                        IconButton(
                                          key: const ValueKey(
                                            'mini-player-queue-button',
                                          ),
                                          tooltip: S.of(context).playlistTitle,
                                          onPressed: launcher.openQueue,
                                          icon: const Icon(
                                            Icons.queue_music,
                                            key: ValueKey(
                                              'mini-player-queue-icon',
                                            ),
                                          ),
                                          iconSize: 24,
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );

                return playerContent;
              },
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (error, stack) => const SizedBox.shrink(),
    );

    return player;
  }

  Widget _buildVolumeControl() {
    return Consumer(
      builder: (context, ref, child) {
        final volume = ref.watch(
          audioPlayerControllerProvider.select((state) => state.volume),
        );
        final displayVolume = _isAdjustingVolume ? _tempVolume : volume;
        return VolumeControl(
          volume: displayVolume,
          onVolumeChanged: (value) {
            setState(() {
              _isAdjustingVolume = true;
              _tempVolume = value;
            });
            ref.read(audioPlayerControllerProvider.notifier).setVolume(value);
          },
          onVolumeChangeEnd: () {
            setState(() {
              _isAdjustingVolume = false;
            });
          },
          iconSize: 24,
        );
      },
    );
  }

  Widget _buildArtworkImage(
    BuildContext context,
    AudioTrack track, {
    String? workCoverUrl,
  }) {
    return PlayerCompactArtwork(
      key: const ValueKey('mini-player-artwork-frame'),
      track: track,
      url: workCoverUrl ?? track.artworkUrl,
    );
  }

  Future<bool> _skipTrack(BuildContext context, {required bool next}) async {
    try {
      final controller = ref.read(audioPlayerControllerProvider.notifier);
      if (next) {
        await controller.skipToNext();
      } else {
        await controller.skipToPrevious();
      }
      return true;
    } catch (error) {
      if (!context.mounted) return false;
      SnackBarUtil.showInfo(
        context,
        error.toString().replaceAll('Exception: ', ''),
        duration: const Duration(seconds: 1),
      );
      return false;
    }
  }
}

class _MiniPlayerTrackSwitcher extends StatefulWidget {
  const _MiniPlayerTrackSwitcher({
    required this.track,
    required this.presentation,
    required this.onTap,
    required this.onPrevious,
    required this.onNext,
  });

  final AudioTrack track;
  final PlayerTrackChangePresentation? presentation;
  final VoidCallback onTap;
  final Future<bool> Function() onPrevious;
  final Future<bool> Function() onNext;

  @override
  State<_MiniPlayerTrackSwitcher> createState() =>
      _MiniPlayerTrackSwitcherState();
}

class _MiniPlayerTrackSwitcherState extends State<_MiniPlayerTrackSwitcher>
    with TickerProviderStateMixin {
  static const double _switchDistance = 36;
  static const double _switchVelocity = 500;
  static const double _maximumDrag = 72;
  static const Duration _trackTransitionDuration = Duration(milliseconds: 180);
  late final AnimationController _settleController;
  late final PlayerTrackLayers<AudioTrack> _presentation;
  double _dragOffset = 0;
  double _gestureDistance = 0;
  double _settleStart = 0;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _settleController = AnimationController(
      vsync: this,
      duration: _trackTransitionDuration,
    )..addListener(_updateSettlingOffset);
    _presentation = PlayerTrackLayers<AudioTrack>(
      vsync: this,
      initialValue: widget.track,
      sameContent: (a, b) => a.id == b.id,
      kind: PlayerTrackVisualKind.title,
      duration: _trackTransitionDuration,
    )..addListener(_layersChanged);
  }

  void _layersChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_reduceMotion) {
      _settleController.stop();
      _dragOffset = 0;
      _presentation.showImmediately(widget.track);
    }
    _reduceMotion = reduceMotion;
  }

  @override
  void didUpdateWidget(covariant _MiniPlayerTrackSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track == widget.track &&
        oldWidget.presentation == widget.presentation) {
      return;
    }
    final metadata = widget.presentation;
    final direction = metadata?.trackId == widget.track.id
        ? metadata!.direction
        : PlayerTrackChangeDirection.none;
    if (_reduceMotion || direction == PlayerTrackChangeDirection.none) {
      _presentation.showImmediately(widget.track);
    } else {
      _presentation.present(
        widget.track,
        direction: direction == PlayerTrackChangeDirection.previous ? -1 : 1,
      );
    }
  }

  @override
  void dispose() {
    _settleController
      ..removeListener(_updateSettlingOffset)
      ..dispose();
    _presentation
      ..removeListener(_layersChanged)
      ..dispose();
    super.dispose();
  }

  void _updateSettlingOffset() {
    if (mounted) {
      setState(
        () => _dragOffset =
            _settleStart *
            (1 - Curves.easeOutCubic.transform(_settleController.value)),
      );
    }
  }

  void _settleToOrigin() {
    _settleController.stop();
    _settleStart = _dragOffset;
    if (_reduceMotion || _settleStart.abs() < 0.5) {
      setState(() => _dragOffset = 0);
      return;
    }
    _settleController.duration = Duration(
      milliseconds: (180 * (_settleStart.abs() / _maximumDrag)).round().clamp(
        90,
        180,
      ),
    );
    _settleController.forward(from: 0);
  }

  void _handleDragStart(DragStartDetails details) {
    _settleController.stop();
    _gestureDistance = 0;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _gestureDistance += details.delta.dx;
    setState(
      () => _dragOffset = (_dragOffset + details.delta.dx).clamp(
        -_maximumDrag,
        _maximumDrag,
      ),
    );
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final distance = velocity.abs() >= _switchVelocity
        ? velocity
        : _gestureDistance;
    if (distance <= -_switchDistance) {
      unawaited(_requestSwitch(next: true));
    } else if (distance >= _switchDistance) {
      unawaited(_requestSwitch(next: false));
    } else {
      _settleToOrigin();
    }
  }

  Future<void> _requestSwitch({required bool next}) async {
    _settleToOrigin();
    await (next ? widget.onNext() : widget.onPrevious());
  }

  Widget _buildTrackContent(BuildContext context, AudioTrack track) {
    return SizedBox(
      key: ValueKey('mini-player-track-info-${track.id}'),
      width: double.infinity,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              track.title,
              textAlign: TextAlign.start,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (track.artist case final artist?) ...[
              const SizedBox(height: 2),
              Text(
                artist,
                textAlign: TextAlign.start,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTrackTransition(BuildContext context) {
    return ExcludeSemantics(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (final layer in _presentation.layers)
              KeyedSubtree(
                key: ValueKey('mini-track-layer-${layer.token}'),
                child: FadeTransition(
                  opacity: layer.opacity,
                  child: SlideTransition(
                    position: layer.offset,
                    child: RepaintBoundary(
                      child: _buildTrackContent(context, layer.value),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final previousAction = CustomSemanticsAction(
      label: S.of(context).previousPage,
    );
    final nextAction = CustomSemanticsAction(label: S.of(context).nextPage);
    final semanticsTrack = widget.track;

    return Semantics(
      button: true,
      label: semanticsTrack.artist == null
          ? semanticsTrack.title
          : '${semanticsTrack.title}, ${semanticsTrack.artist}',
      onTap: widget.onTap,
      customSemanticsActions: {
        previousAction: () => unawaited(_requestSwitch(next: false)),
        nextAction: () => unawaited(_requestSwitch(next: true)),
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              unawaited(_requestSwitch(next: false)),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              unawaited(_requestSwitch(next: true)),
        },
        child: Focus(
          child: GestureDetector(
            key: const ValueKey('mini-player-track-swipe-region'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onHorizontalDragStart: _handleDragStart,
            onHorizontalDragUpdate: _handleDragUpdate,
            onHorizontalDragEnd: _handleDragEnd,
            onHorizontalDragCancel: _settleToOrigin,
            child: ClipRect(
              child: Transform.translate(
                key: const ValueKey('mini-player-track-swipe-transform'),
                offset: Offset(_dragOffset, 0),
                child: _buildTrackTransition(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniPlayerProgressArea extends ConsumerStatefulWidget {
  const _MiniPlayerProgressArea();

  @override
  ConsumerState<_MiniPlayerProgressArea> createState() =>
      _MiniPlayerProgressAreaState();
}

class _MiniPlayerProgressAreaState
    extends ConsumerState<_MiniPlayerProgressArea> {
  bool _isDragging = false;
  double _dragValue = 0;

  void _seek(double value, Duration duration) {
    if (duration <= Duration.zero) return;
    ref
        .read(audioPlayerControllerProvider.notifier)
        .seekAndPersist(
          Duration(milliseconds: (value * duration.inMilliseconds).round()),
        );
  }

  double _valueFromPointer(Offset localPosition, BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || box.size.width <= 0) return _dragValue;
    return (localPosition.dx / box.size.width).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final position = ref.watch(positionProvider).valueOrNull ?? Duration.zero;
    final duration = ref.watch(durationProvider).valueOrNull ?? Duration.zero;
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;
    final displayProgress = _isDragging ? _dragValue : progress;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => setState(() => _isDragging = true),
      onHorizontalDragUpdate: (details) {
        setState(() {
          _dragValue = _valueFromPointer(details.localPosition, context);
        });
      },
      onHorizontalDragEnd: (_) {
        _seek(_dragValue, duration);
        setState(() => _isDragging = false);
      },
      onTapUp: (details) {
        _seek(_valueFromPointer(details.localPosition, context), duration);
      },
      child: Column(
        children: [
          const _MiniPlayerLyricLine(),
          SizedBox(
            height: 4,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 0,
                  disabledThumbRadius: 0,
                ),
                overlayShape: SliderComponentShape.noOverlay,
                activeTrackColor: Theme.of(context).colorScheme.primary,
                inactiveTrackColor: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.2),
              ),
              child: Slider(
                value: displayProgress.clamp(0.0, 1.0),
                onChanged: (value) {
                  setState(() {
                    _isDragging = true;
                    _dragValue = value;
                  });
                },
                onChangeEnd: (value) {
                  _seek(value, duration);
                  setState(() => _isDragging = false);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniPlayerLyricLine extends ConsumerWidget {
  const _MiniPlayerLyricLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = ref.watch(isPlayingProvider);
    final currentLyric = ref.watch(currentLyricTextProvider);
    final hasLyrics = ref.watch(
      lyricControllerProvider.select((state) => state.lyrics.isNotEmpty),
    );
    final lyricSettings = ref.watch(playerLyricSettingsProvider);
    if (!isPlaying || !hasLyrics || currentLyric == null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Text(
        currentLyric,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontSize: lyricSettings.miniFontSize,
          height: lyricSettings.miniLineHeight,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _MiniPlayerAlignedControls extends StatelessWidget {
  const _MiniPlayerAlignedControls({required this.onQueuePressed});

  final VoidCallback onQueuePressed;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final segmentWidth = constraints.maxWidth / 2;
        double alignmentForLeft({
          required double childWidth,
          required double desiredLeft,
        }) {
          final availableWidth = (segmentWidth - childWidth).clamp(
            0.0,
            double.infinity,
          );
          if (availableWidth == 0) return -1;
          final left = desiredLeft.clamp(0.0, availableWidth);
          return 2 * left / availableWidth - 1;
        }

        final playAlignmentX = alignmentForLeft(
          childWidth: 28,
          desiredLeft: segmentWidth - 32,
        );
        final queueAlignmentX = alignmentForLeft(
          childWidth: 24,
          desiredLeft: 8,
        );
        return Row(
          children: [
            Expanded(
              child: _MiniPlayerPlayButton(
                expand: true,
                alignment: Alignment(playAlignmentX, 0),
              ),
            ),
            Expanded(
              child: IconButton(
                key: const ValueKey('mini-player-queue-button'),
                tooltip: S.of(context).playlistTitle,
                onPressed: onQueuePressed,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.expand(),
                alignment: Alignment(queueAlignmentX, 0),
                icon: const Icon(
                  Icons.queue_music,
                  key: ValueKey('mini-player-queue-icon'),
                ),
                iconSize: 24,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MiniPlayerPlayButton extends ConsumerWidget {
  const _MiniPlayerPlayButton({
    this.expand = false,
    this.alignment = Alignment.center,
  });

  final bool expand;
  final Alignment alignment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTrackLoading =
        ref.watch(isTrackLoadingProvider).valueOrNull ?? false;
    if (isTrackLoading) {
      const indicator = SizedBox(
        width: 28,
        height: 28,
        child: Padding(
          padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
      return expand
          ? SizedBox.expand(
              child: Align(alignment: alignment, child: indicator),
            )
          : indicator;
    }

    final isPlaying = ref.watch(isPlayingProvider);
    final visualLeftInset = isPlaying ? 28 * 6 / 24 : 28 * 8 / 24;
    return IconButton(
      key: const ValueKey('mini-player-play-button'),
      onPressed: () {
        final controller = ref.read(audioPlayerControllerProvider.notifier);
        if (isPlaying) {
          controller.pause();
        } else {
          controller.play();
        }
      },
      padding: expand ? EdgeInsets.zero : null,
      constraints: expand ? const BoxConstraints.expand() : null,
      alignment: alignment,
      icon: Transform.translate(
        offset: Offset(-visualLeftInset, 0),
        child: Icon(
          isPlaying ? Icons.pause : Icons.play_arrow,
          key: const ValueKey('mini-player-play-icon'),
        ),
      ),
      iconSize: 28,
    );
  }
}

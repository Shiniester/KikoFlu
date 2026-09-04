import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

import '../../l10n/app_localizations.dart';
import '../models/audio_track.dart';
import '../providers/artwork_theme_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/lyric_provider.dart';
import '../providers/player_lyric_style_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/snackbar_util.dart';
import 'volume_control.dart';
import 'liquid_glass_layout.dart';
import 'player/player_cover_widget.dart';
import 'player/player_route.dart';
import 'player/player_vertical_gestures.dart';
import 'player/player_visual_palette.dart';

class MiniPlayer extends ConsumerStatefulWidget {
  final bool enableArtworkHero;

  /// Replaces only the liquid-glass surface with an equal-height placeholder.
  /// Playback and the Mini Player state remain active behind the modal route.
  final bool suppressLiquidGlassSurface;

  const MiniPlayer({
    super.key,
    this.enableArtworkHero = true,
    this.suppressLiquidGlassSurface = false,
  });

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  String? _lastTrackId;
  bool _isAdjustingVolume = false;
  double _tempVolume = 1.0;
  final GlobalKey _miniArtworkKey = GlobalKey();
  final ValueNotifier<bool> _interactiveArtworkHidden = ValueNotifier(false);
  final GlobalKey<_MiniPlayerUpwardLauncherState> _playerLauncherKey =
      GlobalKey<_MiniPlayerUpwardLauncherState>();
  PlayerArtworkFlightTarget _artworkFlightTarget =
      PlayerArtworkFlightTarget.main;

  @override
  void dispose() {
    _interactiveArtworkHidden.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentTrack = ref.watch(currentTrackProvider);
    final currentArtwork = ref.watch(currentArtworkDescriptorProvider);
    final isMiniPlayerVisible = ref.watch(miniPlayerVisibilityProvider);
    final useLiquidGlass = ref.watch(liquidGlassNavigationProvider);
    final fallbackGlassTransparency = ref.watch(
      fallbackGlassTransparencyProvider,
    );

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

        return _MiniPlayerUpwardLauncher(
          key: _playerLauncherKey,
          sessionIdentity: track.id,
          createConfiguration: () {
            return AudioPlayerOpenConfiguration(
              initialPalette: preparedPalette,
              initialPaletteTrackId: track.id,
            );
          },
          artworkRect: _miniArtworkRect,
          artworkHeroEnabled:
              widget.enableArtworkHero &&
              !MediaQuery.disableAnimationsOf(context),
          artworkBuilder: (context) =>
              _buildArtworkImage(context, track, workCoverUrl: workCoverUrl),
          prepareArtworkTarget: _prepareArtworkTarget,
          restoreArtworkTarget: _restoreArtworkTarget,
          onInteractiveArtworkVisibilityChanged: (hidden) {
            _interactiveArtworkHidden.value = hidden;
          },
          child: Dismissible(
            key: const ValueKey('mini-player-dismissible'),
            direction: DismissDirection.down,
            background: Container(color: Colors.transparent),
            confirmDismiss: (_) async =>
                _playerLauncherKey.currentState
                    ?.allowPendingMiniPlayerDismiss() ??
                true,
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
                    color: useLiquidGlass
                        ? Colors.transparent
                        : Theme.of(context).colorScheme.surface,
                    border: useLiquidGlass
                        ? null
                        : Border(
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
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () async {
                                  await _playerLauncherKey.currentState
                                      ?.openPlayer();
                                },
                                child: _buildArtwork(
                                  context,
                                  track,
                                  workCoverUrl: workCoverUrl,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _MiniPlayerTrackSwitcher(
                                  track: track,
                                  onTap: () async {
                                    await _playerLauncherKey.currentState
                                        ?.openPlayer();
                                  },
                                  onPrevious: () =>
                                      _skipTrack(context, next: false),
                                  onNext: () => _skipTrack(context, next: true),
                                ),
                              ),
                              // Controls (do not trigger navigation)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const _MiniPlayerPlayButton(),
                                  IconButton(
                                    key: const ValueKey(
                                      'mini-player-queue-button',
                                    ),
                                    tooltip: S.of(context).playlistTitle,
                                    onPressed: () async {
                                      await _playerLauncherKey.currentState
                                          ?.openQueue();
                                    },
                                    icon: const Icon(Icons.queue_music),
                                    iconSize: 24,
                                  ),
                                  // Volume control (desktop platforms only)
                                  Consumer(
                                    builder: (context, ref, child) {
                                      final volume = ref.watch(
                                        audioPlayerControllerProvider.select(
                                          (state) => state.volume,
                                        ),
                                      );
                                      // 使用临时音量值避免拖动时重建
                                      final displayVolume = _isAdjustingVolume
                                          ? _tempVolume
                                          : volume;
                                      return VolumeControl(
                                        volume: displayVolume,
                                        onVolumeChanged: (value) {
                                          setState(() {
                                            _isAdjustingVolume = true;
                                            _tempVolume = value;
                                          });
                                          ref
                                              .read(
                                                audioPlayerControllerProvider
                                                    .notifier,
                                              )
                                              .setVolume(value);
                                        },
                                        onVolumeChangeEnd: () {
                                          setState(() {
                                            _isAdjustingVolume = false;
                                          });
                                        },
                                        iconSize: 24,
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );

                if (!useLiquidGlass) return playerContent;
                if (widget.suppressLiquidGlassSurface) {
                  return SizedBox(
                    height:
                        playerHeight + LiquidGlassLayout.verticalPadding * 2,
                  );
                }

                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LiquidGlassLayout.horizontalPadding,
                    vertical: LiquidGlassLayout.verticalPadding,
                  ),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: LiquidGlassContainer(
                      shape: const LiquidGlassShape.roundedRectangle(
                        LiquidGlassLayout.cornerRadius,
                      ),
                      style: LiquidGlassStyle.regular,
                      fallbackIntensity: fallbackGlassTransparency,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          LiquidGlassLayout.cornerRadius,
                        ),
                        child: playerContent,
                      ),
                    ),
                  ),
                );
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

  Widget _buildArtwork(
    BuildContext context,
    AudioTrack track, {
    String? workCoverUrl,
  }) {
    final image = _buildArtworkImage(
      context,
      track,
      workCoverUrl: workCoverUrl,
    );
    final artwork = PlayerArtworkHero(
      trackId: track.id,
      target: _artworkFlightTarget,
      cornerRadius: PlayerCompactArtwork.cornerRadius,
      enabled: widget.enableArtworkHero,
      child: image,
    );
    return KeyedSubtree(
      key: _miniArtworkKey,
      child: ValueListenableBuilder<bool>(
        valueListenable: _interactiveArtworkHidden,
        child: RepaintBoundary(child: artwork),
        builder: (context, hidden, child) =>
            Opacity(opacity: hidden ? 0 : 1, child: child),
      ),
    );
  }

  Rect? _miniArtworkRect() {
    final renderObject = _miniArtworkKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
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

  Future<void> _prepareArtworkTarget(PlayerInitialSurface surface) async {
    final target = surface == PlayerInitialSurface.queue
        ? PlayerArtworkFlightTarget.none
        : PlayerArtworkFlightTarget.main;
    if (_artworkFlightTarget != target && mounted) {
      setState(() => _artworkFlightTarget = target);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void _restoreArtworkTarget() {
    if (!mounted || _artworkFlightTarget == PlayerArtworkFlightTarget.main) {
      return;
    }
    setState(() => _artworkFlightTarget = PlayerArtworkFlightTarget.main);
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
    required this.onTap,
    required this.onPrevious,
    required this.onNext,
  });

  final AudioTrack track;
  final VoidCallback onTap;
  final Future<bool> Function() onPrevious;
  final Future<bool> Function() onNext;

  @override
  State<_MiniPlayerTrackSwitcher> createState() =>
      _MiniPlayerTrackSwitcherState();
}

class _MiniPlayerTrackSwitcherState extends State<_MiniPlayerTrackSwitcher>
    with SingleTickerProviderStateMixin {
  static const double _switchDistance = 36;
  static const double _switchVelocity = 500;
  static const double _maximumDrag = 72;

  late final AnimationController _settleController;
  double _dragOffset = 0;
  double _settleStart = 0;
  bool _switchInProgress = false;

  @override
  void initState() {
    super.initState();
    _settleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(_updateSettlingOffset);
  }

  @override
  void didUpdateWidget(covariant _MiniPlayerTrackSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id == widget.track.id) return;
    _switchInProgress = false;
    _settleToOrigin();
  }

  @override
  void dispose() {
    _settleController
      ..removeListener(_updateSettlingOffset)
      ..dispose();
    super.dispose();
  }

  void _updateSettlingOffset() {
    if (!mounted) return;
    final eased = Curves.easeOutCubic.transform(_settleController.value);
    setState(() => _dragOffset = _settleStart * (1 - eased));
  }

  void _settleToOrigin() {
    _settleController.stop();
    _settleStart = _dragOffset;
    if (_settleStart.abs() < 0.5) {
      _dragOffset = 0;
      return;
    }
    final milliseconds = (180 * (_settleStart.abs() / _maximumDrag))
        .round()
        .clamp(90, 180);
    _settleController.duration = Duration(milliseconds: milliseconds);
    _settleController.forward(from: 0);
  }

  void _handleDragStart(DragStartDetails details) {
    if (_switchInProgress) return;
    _settleController.stop();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (_switchInProgress) return;
    setState(() {
      _dragOffset = (_dragOffset + details.delta.dx).clamp(
        -_maximumDrag,
        _maximumDrag,
      );
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    if (_switchInProgress) return;
    final velocity = details.primaryVelocity ?? 0;
    final goNext =
        _dragOffset <= -_switchDistance || velocity <= -_switchVelocity;
    final goPrevious =
        _dragOffset >= _switchDistance || velocity >= _switchVelocity;
    if (goNext) {
      unawaited(_requestSwitch(next: true));
    } else if (goPrevious) {
      unawaited(_requestSwitch(next: false));
    } else {
      _settleToOrigin();
    }
  }

  Future<void> _requestSwitch({required bool next}) async {
    if (_switchInProgress) return;
    setState(() => _switchInProgress = true);
    _settleToOrigin();
    await (next ? widget.onNext() : widget.onPrevious());
    if (mounted) setState(() => _switchInProgress = false);
  }

  @override
  Widget build(BuildContext context) {
    final previousAction = CustomSemanticsAction(
      label: S.of(context).previousPage,
    );
    final nextAction = CustomSemanticsAction(label: S.of(context).nextPage);
    final trackContent = Column(
      key: ValueKey('mini-player-track-info-${widget.track.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          widget.track.title,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (widget.track.artist case final artist?) ...[
          const SizedBox(height: 2),
          Text(
            artist,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );

    return Semantics(
      button: true,
      label: widget.track.artist == null
          ? widget.track.title
          : '${widget.track.title}, ${widget.track.artist}',
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
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeOutCubic,
                  child: trackContent,
                ),
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

class _MiniPlayerUpwardLauncher extends StatefulWidget {
  const _MiniPlayerUpwardLauncher({
    super.key,
    required this.child,
    required this.sessionIdentity,
    required this.createConfiguration,
    required this.artworkRect,
    required this.artworkBuilder,
    required this.artworkHeroEnabled,
    required this.prepareArtworkTarget,
    required this.restoreArtworkTarget,
    required this.onInteractiveArtworkVisibilityChanged,
  });

  final Widget child;
  final Object sessionIdentity;
  final AudioPlayerOpenConfiguration Function() createConfiguration;
  final Rect? Function() artworkRect;
  final WidgetBuilder artworkBuilder;
  final bool artworkHeroEnabled;
  final Future<void> Function(PlayerInitialSurface surface)
  prepareArtworkTarget;
  final VoidCallback restoreArtworkTarget;
  final ValueChanged<bool> onInteractiveArtworkVisibilityChanged;

  @override
  State<_MiniPlayerUpwardLauncher> createState() =>
      _MiniPlayerUpwardLauncherState();
}

class _MiniPlayerUpwardLauncherState extends State<_MiniPlayerUpwardLauncher>
    with WidgetsBindingObserver {
  int? _pointer;
  Offset? _startPosition;
  VelocityTracker? _velocityTracker;
  bool _directionLocked = false;
  bool _directionRejected = false;
  bool _launchInProgress = false;
  bool _rejectPendingMiniDismiss = false;
  double _latestOpenDistance = 0;
  double _latestExtent = 1;
  _InteractivePlayerOpenSession? _interactiveSession;
  int _sessionGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> openPlayer() async {
    await _openSurface(PlayerInitialSurface.main);
  }

  Future<void> openQueue() async {
    await _openSurface(PlayerInitialSurface.queue);
  }

  Future<void> _openSurface(PlayerInitialSurface initialSurface) async {
    if (!mounted || _launchInProgress) return;
    _launchInProgress = true;
    try {
      await widget.prepareArtworkTarget(initialSurface);
      if (!mounted) return;
      final route = widget.createConfiguration().createRoute(
        initialSurface: initialSurface,
      );
      if (!mounted) return;
      await Navigator.of(context).push<void>(route);
    } finally {
      widget.restoreArtworkTarget();
      _launchInProgress = false;
    }
  }

  bool allowPendingMiniPlayerDismiss() {
    if (!_rejectPendingMiniDismiss) return true;
    _rejectPendingMiniDismiss = false;
    return false;
  }

  @override
  void didUpdateWidget(covariant _MiniPlayerUpwardLauncher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionIdentity != widget.sessionIdentity) {
      _abortInteractiveSession();
      _clearPointer();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _abortInteractiveSession();
    _clearPointer();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      key: const ValueKey('mini-player-upward-launcher'),
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: widget.child,
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_pointer != null || _launchInProgress) return;
    _pointer = event.pointer;
    _startPosition = event.position;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    _directionLocked = false;
    _directionRejected = false;
    _rejectPendingMiniDismiss = false;
    _latestOpenDistance = 0;
    _latestExtent = MediaQuery.sizeOf(context).height.clamp(1, double.infinity);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _directionRejected) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    final start = _startPosition;
    if (start == null) return;
    final offset = event.position - start;
    if (!_directionLocked) {
      if (offset.distance < 8) return;
      if (offset.dy >= 0 || offset.dy.abs() < offset.dx.abs() * 1.2) {
        _directionRejected = true;
        return;
      }
      _directionLocked = true;
      _rejectPendingMiniDismiss = true;
      if (!MediaQuery.disableAnimationsOf(context)) {
        _startInteractiveSession();
      }
    }
    _latestOpenDistance = (-offset.dy).clamp(0.0, _latestExtent);
    _interactiveSession?.update(
      distance: _latestOpenDistance,
      extent: _latestExtent,
    );
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    final start = _startPosition;
    final distance = start == null ? 0.0 : start.dy - event.position.dy;
    final velocity = _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0;
    if (_directionLocked) {
      final extent = _latestExtent;
      final shouldOpen = distance / extent >= 0.22 || velocity < -650;
      final session = _interactiveSession;
      if (session != null) {
        unawaited(
          _finishInteractiveSession(
            session,
            velocity: velocity,
            extent: extent,
          ),
        );
      } else if (shouldOpen) {
        unawaited(openPlayer());
      }
      _clearPointer();
      return;
    }
    _clearPointer();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    final session = _interactiveSession;
    if (session != null) {
      unawaited(_cancelInteractiveSession(session));
    }
    _clearPointer();
  }

  void _startInteractiveSession() {
    if (!mounted || _interactiveSession != null || _launchInProgress) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final rootNavigator = Navigator.of(context);
    final configuration = widget.createConfiguration();
    final generation = ++_sessionGeneration;
    _launchInProgress = true;
    final session = _InteractivePlayerOpenSession(
      overlay: overlay,
      rootNavigator: rootNavigator,
      configuration: configuration,
      artworkRect: widget.artworkRect(),
      artworkBuilder: widget.artworkBuilder,
      artworkTrackId: widget.sessionIdentity.toString(),
      artworkHeroEnabled: widget.artworkHeroEnabled,
      onArtworkVisibilityChanged: widget.onInteractiveArtworkVisibilityChanged,
      onRootRouteClosed: () {
        if (!mounted || generation != _sessionGeneration) return;
        _launchInProgress = false;
      },
    );
    _interactiveSession = session;
    session.update(distance: _latestOpenDistance, extent: _latestExtent);
    unawaited(session.start());
  }

  Future<void> _finishInteractiveSession(
    _InteractivePlayerOpenSession session, {
    required double velocity,
    required double extent,
  }) async {
    final completed = await session.finish(velocity: velocity, extent: extent);
    if (!mounted || !identical(_interactiveSession, session)) return;
    _interactiveSession = null;
    if (!completed) _launchInProgress = false;
  }

  Future<void> _cancelInteractiveSession(
    _InteractivePlayerOpenSession session,
  ) async {
    await session.cancel();
    if (!mounted || !identical(_interactiveSession, session)) return;
    _interactiveSession = null;
    _launchInProgress = false;
  }

  void _abortInteractiveSession() {
    _sessionGeneration++;
    _interactiveSession?.abort();
    _interactiveSession = null;
    _launchInProgress = false;
  }

  void _clearPointer() {
    _pointer = null;
    _startPosition = null;
    _velocityTracker = null;
    _directionLocked = false;
    _directionRejected = false;
    _latestOpenDistance = 0;
    _latestExtent = 1;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _abortInteractiveSession();
    _clearPointer();
    super.dispose();
  }
}

/// A short-lived route host used only while an upward Mini Player pointer is
/// still active. Pushing into this nested Navigator avoids the root
/// Navigator's pointer cancellation, while still rendering the canonical
/// [AudioPlayerPageRoute] and its Hero flight.
class _InteractivePlayerOpenSession {
  _InteractivePlayerOpenSession({
    required this.overlay,
    required this.rootNavigator,
    required this.configuration,
    required this.artworkRect,
    required this.artworkBuilder,
    required this.artworkTrackId,
    required this.artworkHeroEnabled,
    required this.onArtworkVisibilityChanged,
    required this.onRootRouteClosed,
  });

  final OverlayState overlay;
  final NavigatorState rootNavigator;
  final AudioPlayerOpenConfiguration configuration;
  final Rect? artworkRect;
  final WidgetBuilder artworkBuilder;
  final String artworkTrackId;
  final bool artworkHeroEnabled;
  final ValueChanged<bool> onArtworkVisibilityChanged;
  final VoidCallback onRootRouteClosed;

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final Completer<void> _routeReady = Completer<void>();
  late final HeroController _heroController = HeroController(
    createRectTween: (begin, end) => createPlayerArtworkRectTween(
      begin,
      end,
      viewportHeight: MediaQuery.sizeOf(overlay.context).height,
    ),
  );
  OverlayEntry? _entry;
  AudioPlayerPageRoute<void>? _route;
  double _distance = 0;
  double _extent = 1;
  bool _started = false;
  bool _disposed = false;
  bool _settling = false;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _entry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: IgnorePointer(
          child: Navigator(
            key: _navigatorKey,
            observers: [_heroController],
            requestFocus: false,
            onGenerateInitialRoutes: (navigator, initialRoute) => [
              PageRouteBuilder<void>(
                settings: const RouteSettings(
                  name: '_interactive_player_source',
                ),
                opaque: false,
                barrierColor: Colors.transparent,
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (context, animation, secondaryAnimation) =>
                    _InteractivePlayerHeroSource(
                      artworkRect: artworkRect,
                      artworkBuilder: artworkBuilder,
                      artworkTrackId: artworkTrackId,
                      artworkHeroEnabled: artworkHeroEnabled,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
    await WidgetsBinding.instance.endOfFrame;
    if (_disposed) return;
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      abort();
      return;
    }
    final route = configuration.createRoute();
    _route = route;
    if (artworkHeroEnabled) onArtworkVisibilityChanged(true);
    unawaited(navigator.push<void>(route));
    await WidgetsBinding.instance.endOfFrame;
    if (_disposed) return;
    if (!route.beginVerticalOpenGesture()) {
      abort();
      return;
    }
    route.updateVerticalOpenGesture(distance: _distance, extent: _extent);
    if (!_routeReady.isCompleted) _routeReady.complete();
  }

  void update({required double distance, required double extent}) {
    if (_disposed || _settling) return;
    _distance = distance.clamp(0.0, extent);
    _extent = extent.clamp(1, double.infinity);
    _route?.updateVerticalOpenGesture(distance: _distance, extent: _extent);
  }

  Future<bool> finish({required double velocity, required double extent}) {
    return _settle(complete: true, velocity: velocity, extent: extent);
  }

  Future<bool> cancel() {
    return _settle(complete: false, velocity: 0, extent: _extent);
  }

  Future<bool> _settle({
    required bool complete,
    required double velocity,
    required double extent,
  }) async {
    if (_disposed || _settling) return false;
    _settling = true;
    if (!_routeReady.isCompleted) {
      try {
        await _routeReady.future;
      } catch (_) {
        abort();
        return false;
      }
    }
    if (_disposed) return false;
    final route = _route;
    if (route == null) {
      abort();
      return false;
    }
    final opened = complete
        ? await route.endVerticalOpenGesture(velocity: velocity, extent: extent)
        : await route.cancelVerticalOpenGesture();
    if (_disposed) return false;
    if (!opened) {
      _removeOverlay();
      return false;
    }

    final rootRoute = configuration.createRoute(handoff: true);
    final rootRouteClosed = rootNavigator.push<void>(rootRoute);
    unawaited(rootRouteClosed.whenComplete(onRootRouteClosed));
    await WidgetsBinding.instance.endOfFrame;
    if (!_disposed) _removeOverlay();
    return true;
  }

  void abort() {
    if (_disposed) return;
    _disposed = true;
    if (!_routeReady.isCompleted) _routeReady.complete();
    _entry?.remove();
    _entry = null;
    onArtworkVisibilityChanged(false);
  }

  void _removeOverlay() {
    if (_disposed) return;
    _disposed = true;
    _entry?.remove();
    _entry = null;
    onArtworkVisibilityChanged(false);
  }
}

class _InteractivePlayerHeroSource extends StatelessWidget {
  const _InteractivePlayerHeroSource({
    required this.artworkRect,
    required this.artworkBuilder,
    required this.artworkTrackId,
    required this.artworkHeroEnabled,
  });

  final Rect? artworkRect;
  final WidgetBuilder artworkBuilder;
  final String artworkTrackId;
  final bool artworkHeroEnabled;

  @override
  Widget build(BuildContext context) {
    final rect = artworkRect;
    if (!artworkHeroEnabled || rect == null) {
      return const SizedBox.expand();
    }
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: rect,
            child: PlayerArtworkHero(
              trackId: artworkTrackId,
              target: PlayerArtworkFlightTarget.main,
              cornerRadius: PlayerCompactArtwork.cornerRadius,
              enabled: artworkHeroEnabled,
              child: artworkBuilder(context),
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

class _MiniPlayerPlayButton extends ConsumerWidget {
  const _MiniPlayerPlayButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTrackLoading =
        ref.watch(isTrackLoadingProvider).valueOrNull ?? false;
    if (isTrackLoading) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: Padding(
          padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    final isPlaying = ref.watch(isPlayingProvider);
    return IconButton(
      onPressed: () {
        final controller = ref.read(audioPlayerControllerProvider.notifier);
        if (isPlaying) {
          controller.pause();
        } else {
          controller.play();
        }
      },
      icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
      iconSize: 28,
    );
  }
}

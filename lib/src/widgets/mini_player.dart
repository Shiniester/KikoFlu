import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:real_liquid_glass/real_liquid_glass.dart';

import '../models/audio_track.dart';
import '../providers/audio_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/lyric_provider.dart';
import '../providers/player_lyric_style_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/local_file_url.dart';
import 'privacy_blur_cover.dart';
import 'volume_control.dart';
import 'liquid_glass_layout.dart';
import 'player/player_route.dart';
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

  @override
  void dispose() {
    _interactiveArtworkHidden.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentTrack = ref.watch(currentTrackProvider);
    final auth = ref.watch(
      authProvider.select(
        (state) => (host: state.host ?? '', token: state.token ?? ''),
      ),
    );
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

        // Build work cover URL（优先使用本地文件）
        String? workCoverUrl;
        // 优先使用 track.artworkUrl（可能是本地文件 file://）
        if (LocalFileUrl.isLocalFileUrl(track.artworkUrl)) {
          workCoverUrl = track.artworkUrl;
        } else if (track.workId != null) {
          final host = auth.host;
          final token = auth.token;
          if (host.isNotEmpty) {
            var normalizedHost = host;
            if (!normalizedHost.startsWith('http://') &&
                !normalizedHost.startsWith('https://')) {
              normalizedHost = 'https://$normalizedHost';
            }
            workCoverUrl = token.isNotEmpty
                ? '$normalizedHost/api/cover/${track.workId}?token=$token'
                : '$normalizedHost/api/cover/${track.workId}';
          }
        }

        // Start the low-resolution palette extraction while the Mini Player is
        // visible. Opening the full player can then use the artwork palette on
        // its very first frame instead of briefly revealing the theme seed.
        final playerTheme = Theme.of(context);
        final privacy = ref.watch(privacyModeSettingsProvider);
        final paletteRequest = PlayerPaletteRequest(
          source: workCoverUrl ?? track.artworkUrl,
          cacheKey: track.workId != null
              ? 'work_cover_${track.workId}'
              : track.hash ?? track.id,
          brightness: playerTheme.brightness,
          fallbackSeed: playerTheme.colorScheme.primary,
          suppressArtwork: privacy.enabled && privacy.blurCoverInApp,
        );
        final preparedPalette = ref.watch(
          playerVisualPaletteProvider(paletteRequest),
        );

        return _MiniPlayerUpwardLauncher(
          key: _playerLauncherKey,
          sessionIdentity: track.id,
          createConfiguration: () {
            final initialPalette =
                preparedPalette.valueOrNull ??
                PlayerVisualPalette.fallback(
                  seed: playerTheme.colorScheme.primary,
                  brightness: playerTheme.brightness,
                );
            return AudioPlayerOpenConfiguration(
              initialPalette: initialPalette,
              initialPaletteTrackId: track.id,
            );
          },
          artworkRect: _miniArtworkRect,
          artworkHeroTag: 'audio_player_artwork_${track.id}',
          artworkHeroEnabled:
              widget.enableArtworkHero &&
              !MediaQuery.disableAnimationsOf(context),
          artworkBuilder: (context) =>
              _buildArtworkImage(context, track, workCoverUrl: workCoverUrl),
          onInteractiveArtworkVisibilityChanged: (hidden) {
            _interactiveArtworkHidden.value = hidden;
          },
          child: Dismissible(
            key: Key('miniplayer_${track.id}'),
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
                              // Left tap area: artwork + info opens full player
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () async {
                                    await _playerLauncherKey.currentState
                                        ?.openPlayer();
                                  },
                                  child: Row(
                                    children: [
                                      // Album art (use work cover) with optional Hero animation
                                      _buildArtwork(
                                        context,
                                        track,
                                        workCoverUrl: workCoverUrl,
                                      ),
                                      const SizedBox(width: 12),
                                      // Track info
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              track.title,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (track.artist != null) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                track.artist!,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              // Controls (do not trigger navigation)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    onPressed: () async {
                                      try {
                                        await ref
                                            .read(
                                              audioPlayerControllerProvider
                                                  .notifier,
                                            )
                                            .skipToPrevious();
                                      } catch (e) {
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              e.toString().replaceAll(
                                                'Exception: ',
                                                '',
                                              ),
                                            ),
                                            duration: const Duration(
                                              seconds: 1,
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.skip_previous),
                                    iconSize: 24,
                                  ),
                                  const _MiniPlayerPlayButton(),
                                  IconButton(
                                    onPressed: () async {
                                      try {
                                        await ref
                                            .read(
                                              audioPlayerControllerProvider
                                                  .notifier,
                                            )
                                            .skipToNext();
                                      } catch (e) {
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              e.toString().replaceAll(
                                                'Exception: ',
                                                '',
                                              ),
                                            ),
                                            duration: const Duration(
                                              seconds: 1,
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.skip_next),
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
    final artwork =
        !widget.enableArtworkHero || MediaQuery.disableAnimationsOf(context)
        ? image
        : Hero(
            tag: 'audio_player_artwork_${track.id}',
            transitionOnUserGestures: true,
            child: image,
          );
    return KeyedSubtree(
      key: _miniArtworkKey,
      child: ValueListenableBuilder<bool>(
        valueListenable: _interactiveArtworkHidden,
        child: artwork,
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
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: (workCoverUrl ?? track.artworkUrl) != null
          ? PrivacyBlurCover(
              borderRadius: BorderRadius.circular(8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child:
                    LocalFileUrl.isLocalFileUrl(
                      workCoverUrl ?? track.artworkUrl,
                    )
                    ? Image.file(
                        File(
                          LocalFileUrl.pathFromUrl(
                            workCoverUrl ?? track.artworkUrl,
                          )!,
                        ),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return const Icon(Icons.album, size: 32);
                        },
                      )
                    : CachedNetworkImage(
                        imageUrl: (workCoverUrl ?? track.artworkUrl)!,
                        cacheKey: track.workId != null
                            ? 'work_cover_${track.workId}'
                            : null,
                        fit: BoxFit.cover,
                        errorWidget: (context, url, error) =>
                            const Icon(Icons.album, size: 32),
                        placeholder: (context, url) =>
                            const Center(child: CircularProgressIndicator()),
                      ),
              ),
            )
          : const Icon(Icons.album, size: 32),
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
    required this.artworkHeroTag,
    required this.artworkHeroEnabled,
    required this.onInteractiveArtworkVisibilityChanged,
  });

  final Widget child;
  final Object sessionIdentity;
  final AudioPlayerOpenConfiguration Function() createConfiguration;
  final Rect? Function() artworkRect;
  final WidgetBuilder artworkBuilder;
  final Object artworkHeroTag;
  final bool artworkHeroEnabled;
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
    if (!mounted || _launchInProgress) return;
    _launchInProgress = true;
    try {
      final route = widget.createConfiguration().createRoute();
      if (!mounted) return;
      await Navigator.of(context).push<void>(route);
    } finally {
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
      artworkHeroTag: widget.artworkHeroTag,
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
    required this.artworkHeroTag,
    required this.artworkHeroEnabled,
    required this.onArtworkVisibilityChanged,
    required this.onRootRouteClosed,
  });

  final OverlayState overlay;
  final NavigatorState rootNavigator;
  final AudioPlayerOpenConfiguration configuration;
  final Rect? artworkRect;
  final WidgetBuilder artworkBuilder;
  final Object artworkHeroTag;
  final bool artworkHeroEnabled;
  final ValueChanged<bool> onArtworkVisibilityChanged;
  final VoidCallback onRootRouteClosed;

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final Completer<void> _routeReady = Completer<void>();
  late final HeroController _heroController = HeroController(
    createRectTween: (begin, end) =>
        MaterialRectArcTween(begin: begin, end: end),
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
                      artworkHeroTag: artworkHeroTag,
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
    required this.artworkHeroTag,
    required this.artworkHeroEnabled,
  });

  final Rect? artworkRect;
  final WidgetBuilder artworkBuilder;
  final Object artworkHeroTag;
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
            child: Hero(
              tag: artworkHeroTag,
              transitionOnUserGestures: true,
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

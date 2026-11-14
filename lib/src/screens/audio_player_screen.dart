import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import '../models/work.dart';
import '../models/audio_track.dart';
import '../providers/artwork_theme_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/lyric_provider.dart';
import '../providers/player_buttons_provider.dart';
import '../providers/player_lyric_style_provider.dart';
import '../providers/player_work_details_provider.dart';
import '../services/audio_player_service.dart';
import '../utils/local_file_url.dart';
import '../utils/snackbar_util.dart';
import '../utils/system_ui_style.dart';
import '../widgets/player/player_cover_widget.dart';
import '../widgets/player/player_track_layers.dart';
import '../widgets/player/player_controls_widget.dart';
import '../widgets/player/player_action_slot.dart';
import '../widgets/player/lyric_display_widget.dart';
import '../widgets/player/player_seek_preview.dart';
import '../widgets/player/playlist_dialog.dart';
import '../widgets/player/player_info_panel.dart';
import '../widgets/player/player_audio_details_panel.dart';
import '../widgets/player/player_lyrics_surface.dart';
import '../widgets/player/player_glass_surface.dart';
import '../widgets/player/player_visual_palette.dart';
import '../widgets/player/player_palette_background.dart';
import '../widgets/player/player_vertical_gestures.dart';
import '../widgets/player/player_scroll_drag_handoff.dart';
import '../widgets/player/player_page_scroll_physics.dart';
import '../widgets/text_preview_screen.dart';
import '../widgets/work_bookmark_manager.dart';
import '../providers/automatic_work_marking_provider.dart';
import '../widgets/app_bottom_dock_transition.dart';
import '../widgets/app_navigation_scope.dart';
import '../widgets/cover_preview_dialog.dart';
import '../widgets/responsive_dialog.dart';
import '../widgets/lyric_translation_confirmation.dart';
import 'work_detail_screen.dart';
import '../../l10n/app_localizations.dart';

/// 音频播放器主屏幕
enum PlayerRightPane { details, controls, lyrics, queue }

@immutable
class _PlayerQueueReturnState {
  const _PlayerQueueReturnState({required this.rightPane});

  final PlayerRightPane rightPane;
}

const double playerWideLayoutBreakpoint = 840;
const double playerShortStageWidthBreakpoint = 568;
const double playerShortStageAspectRatio = 1.6;
const double playerShortControlsHeightBreakpoint = 440;
const double playerNarrowWideLayoutBreakpoint = 640;
const double _compactPortraitLyricSlotHeight = 144;
const double _compactPlayerLyricGap = 16;

bool usesWidePlayerLayout(double width, {required double height}) =>
    width >= playerWideLayoutBreakpoint ||
    (width >= playerShortStageWidthBreakpoint &&
        width >= height * playerShortStageAspectRatio);

class AudioPlayerScreen extends ConsumerStatefulWidget {
  const AudioPlayerScreen({
    super.key,
    this.initialPalette,
    this.initialPaletteTrackId,
    this.initialSurface = PlayerInitialSurface.main,
    this.initialQueueHistory = false,
  });

  final PlayerVisualPalette? initialPalette;
  final String? initialPaletteTrackId;
  final PlayerInitialSurface initialSurface;
  final bool initialQueueHistory;

  @override
  ConsumerState<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends ConsumerState<AudioPlayerScreen> {
  static const Duration _pageTransitionDuration = Duration(milliseconds: 300);
  static const Curve _pageTransitionCurve = Curves.ease;

  final ValueNotifier<String?> _workProgress = ValueNotifier(null);
  String? _onlineWorkProgress;
  String? get _currentProgress => _workProgress.value;
  int? _currentRating;
  int? _currentWorkId;
  final ValueNotifier<PlayerSeekPreview?> _seekPreview =
      ValueNotifier<PlayerSeekPreview?>(null);
  Timer? _seekPreviewClearTimer;
  bool get _isSeekingManually => _seekPreview.value?.isSeekingManually ?? false;
  double get _seekValue => _seekPreview.value?.seekValue ?? 0;
  Duration? get _seekingPosition => _seekPreview.value?.position;
  bool _showLyricView = false;
  PlayerRightPane _rightPane = PlayerRightPane.controls;
  int _compactPage = 1;
  _PlayerQueueReturnState? _queueReturnState;
  late bool _queueHasBeenOpened;
  final PageController _compactPageController = PageController(initialPage: 1);
  final PageController _wideRightPageController = PageController(
    initialPage: 1,
  );
  final PageController _compactVerticalPageController = PageController();
  final PageController _wideVerticalPageController = PageController();
  late final PlayerScrollDragHandoffCoordinator _compactPageHandoff =
      PlayerScrollDragHandoffCoordinator(
        _compactVerticalPageController,
        onPageDragStart: _prepareQueueForPageDrag,
      );
  late final PlayerScrollDragHandoffCoordinator _widePageHandoff =
      PlayerScrollDragHandoffCoordinator(
        _wideVerticalPageController,
        onPageDragStart: _prepareQueueForPageDrag,
      );
  late final ScrollController _compactDetailsScrollController =
      _compactPageHandoff.createScrollController(
        debugLabel: 'compact-player-details',
      );
  late final ScrollController _compactLyricsScrollController =
      _compactPageHandoff.createScrollController(
        debugLabel: 'compact-player-lyrics',
      );
  late final ScrollController _wideDetailsScrollController = _widePageHandoff
      .createScrollController(debugLabel: 'wide-player-details');
  late final ScrollController _wideLyricsScrollController = _widePageHandoff
      .createScrollController(debugLabel: 'wide-player-lyrics');
  late final ScrollController _wideControlsScrollController = _widePageHandoff
      .createScrollController(debugLabel: 'wide-player-controls');
  final GlobalKey _queueBrowserKey = GlobalKey();
  final GlobalKey _wideLyricPreviewKey = GlobalKey();
  final Map<PageController, int> _requestedPageTargets = {};
  final Map<PageController, int> _pageDragOrigins = {};
  final FocusNode _keyboardFocusNode = FocusNode(debugLabel: 'audio-player');
  bool? _lastWasWide;
  bool _initialQueueHistorySelected = false;
  double? _compactSharedWidth;
  Animation<double>? _paletteRouteAnimation;
  ValueNotifier<bool>? _paletteRouteGesture;
  bool _paletteReleaseScheduled = false;
  PlayerVisualPalette? _resolvedRoutePalette;
  PlayerVisualPalette? _displayedRoutePalette;
  Timer? _unlockButtonTimer;
  bool _routePaletteFrozen = false;
  late final bool _directQueueEntry;
  late bool _playerPagesActivated;
  ModalRoute<dynamic>? _entryRoute;
  Animation<double>? _entryRouteAnimation;
  final ValueNotifier<bool> _deferredPlayerPagesReady = ValueNotifier(true);
  bool _entryReadinessInitialized = false;
  int _semanticTransitionGeneration = 0;
  Size? _lastPlayerStageSize;
  bool _queueTransitionActive = false;
  bool _verticalPageDragActive = false;
  bool _reduceMotion = false;
  bool _openingWorkDetail = false;
  final ValueNotifier<String?> _coverPreviewHeroTrackId = ValueNotifier(null);
  final LayerLink _coverLoadingLayerLink = LayerLink();
  late final PlayerVerticalDismissCoordinator _dismissCoordinator =
      PlayerVerticalDismissCoordinator(
        currentVisualMode: () => _currentPlayerDismissVisualMode,
        canDismiss: _canDismissPlayer,
        releaseTextInputFocus: _releaseTextInputFocus,
      );
  final ValueNotifier<int> _semanticPageRevision = ValueNotifier<int>(0);
  final ValueNotifier<bool> _progressGestureActive = ValueNotifier<bool>(false);

  // 全屏锁定状态
  bool _isLyricLocked = false;
  bool _showUnlockButton = false;

  @override
  void initState() {
    super.initState();
    _directQueueEntry = widget.initialSurface == PlayerInitialSurface.queue;
    _playerPagesActivated = !_directQueueEntry;
    _queueHasBeenOpened = _directQueueEntry;
    if (_directQueueEntry) _rightPane = PlayerRightPane.queue;
    _routePaletteFrozen = widget.initialPalette != null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindEntryRouteAnimation();
    final route = ModalRoute.of(context);
    if (_routePaletteFrozen) {
      _detachPaletteRouteListeners();
      _paletteRouteAnimation = route?.animation;
      _paletteRouteGesture = route?.navigator?.userGestureInProgressNotifier;
      _paletteRouteAnimation?.addStatusListener(_onPaletteRouteStatus);
      _paletteRouteGesture?.addListener(_schedulePaletteRelease);
      _schedulePaletteRelease();
    }
    _dismissCoordinator.scheduleVisualModeSync(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion &&
        !_reduceMotion &&
        _queueTransitionActive &&
        !_verticalPageDragActive) {
      for (final entry in _requestedPageTargets.entries.toList()) {
        if (entry.key.hasClients) entry.key.jumpToPage(entry.value);
      }
      _requestedPageTargets.clear();
      _queueTransitionActive = false;
    }
    _reduceMotion = reduceMotion;
  }

  void _bindEntryRouteAnimation() {
    final route = ModalRoute.of(context);
    final animation = route?.animation;
    if (!identical(animation, _entryRouteAnimation)) {
      _entryRouteAnimation?.removeStatusListener(_onEntryRouteStatus);
      _entryRouteAnimation = animation;
      animation?.addStatusListener(_onEntryRouteStatus);
    }
    _entryRoute = route;
    if (!_entryReadinessInitialized) {
      _deferredPlayerPagesReady.value = _entryPagesSettled;
      _entryReadinessInitialized = true;
    }
    _settleEntryPagesIfReady();
  }

  void _onEntryRouteStatus(AnimationStatus _) {
    _settleEntryPagesIfReady();
  }

  bool get _entryPagesSettled {
    final route = _entryRoute;
    if (route == null || MediaQuery.disableAnimationsOf(context)) return true;
    if (route is PlayerEntranceRoute) {
      return (route as PlayerEntranceRoute).isEntranceSettled;
    }
    final animation = route.animation;
    return animation == null || animation.value >= 1;
  }

  void _settleEntryPagesIfReady() {
    if (!mounted || _deferredPlayerPagesReady.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _deferredPlayerPagesReady.value || !_entryPagesSettled) {
        return;
      }
      _deferredPlayerPagesReady.value = true;
    });
  }

  void _activateDeferredPlayerPages() {
    if (!mounted || _deferredPlayerPagesReady.value) return;
    _deferredPlayerPagesReady.value = true;
  }

  Widget _deferredPlayerPage({
    required bool ready,
    required Key placeholderKey,
    required Widget Function() builder,
  }) {
    return ready ? builder() : SizedBox.shrink(key: placeholderKey);
  }

  void _onPaletteRouteStatus(AnimationStatus status) {
    _schedulePaletteRelease();
  }

  bool get _canReleaseRoutePalette =>
      (_paletteRouteAnimation == null ||
          _paletteRouteAnimation!.status == AnimationStatus.completed) &&
      !(_paletteRouteGesture?.value ?? false);

  void _schedulePaletteRelease() {
    if (!_routePaletteFrozen ||
        _paletteReleaseScheduled ||
        !_canReleaseRoutePalette) {
      return;
    }
    _paletteReleaseScheduled = true;
    // Keep palette work out of the final transition frame and wait for a
    // gesture held at full expansion to actually finish.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _paletteReleaseScheduled = false;
      if (!mounted || !_routePaletteFrozen || !_canReleaseRoutePalette) return;
      _routePaletteFrozen = false;
      _detachPaletteRouteListeners();
      if (_resolvedRoutePalette != _displayedRoutePalette) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _detachPaletteRouteListeners() {
    _paletteRouteAnimation?.removeStatusListener(_onPaletteRouteStatus);
    _paletteRouteGesture?.removeListener(_schedulePaletteRelease);
    _paletteRouteAnimation = null;
    _paletteRouteGesture = null;
  }

  /// 进入全屏锁定模式
  void _enterLyricFullscreen() {
    if (_isLyricLocked) return;
    _unlockButtonTimer?.cancel();
    setState(() {
      _isLyricLocked = true;
      _showUnlockButton = false;
    });
    // 隐藏状态栏和导航栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// 退出全屏锁定模式
  void _exitLyricFullscreen() {
    if (!_isLyricLocked) return;
    _unlockButtonTimer?.cancel();
    setState(() {
      _isLyricLocked = false;
      _showUnlockButton = false;
    });
    // 恢复系统UI，并在 Android 上重新启用 edge-to-edge。
    unawaited(
      restoreSystemUiAfterImmersiveMode(useEdgeToEdge: Platform.isAndroid),
    );
  }

  @override
  void dispose() {
    if (_isLyricLocked) {
      unawaited(
        restoreSystemUiAfterImmersiveMode(useEdgeToEdge: Platform.isAndroid),
      );
    }
    _compactPageController.dispose();
    _wideRightPageController.dispose();
    _compactPageHandoff.cancelActiveDrags();
    _widePageHandoff.cancelActiveDrags();
    _compactVerticalPageController.dispose();
    _wideVerticalPageController.dispose();
    _compactDetailsScrollController.dispose();
    _compactLyricsScrollController.dispose();
    _wideDetailsScrollController.dispose();
    _wideLyricsScrollController.dispose();
    _wideControlsScrollController.dispose();
    _keyboardFocusNode.dispose();
    _detachPaletteRouteListeners();
    _entryRoute = null;
    _entryRouteAnimation?.removeStatusListener(_onEntryRouteStatus);
    _deferredPlayerPagesReady.dispose();
    _unlockButtonTimer?.cancel();
    _semanticPageRevision.dispose();
    _coverPreviewHeroTrackId.dispose();
    _progressGestureActive.dispose();
    _seekPreviewClearTimer?.cancel();
    _seekPreview.dispose();
    _workProgress.dispose();
    _semanticTransitionGeneration++;
    _dismissCoordinator.dispose();
    super.dispose();
  }

  /// 处理锁定状态下的点击
  void _handleLockedTap() {
    _unlockButtonTimer?.cancel();
    setState(() {
      _showUnlockButton = !_showUnlockButton;
    });
    // 如果显示解锁按钮，3秒后自动隐藏
    if (_showUnlockButton) {
      _unlockButtonTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && _showUnlockButton) {
          setState(() {
            _showUnlockButton = false;
          });
        }
      });
    }
  }

  Future<void> _loadCurrentProgress(int workId) async {
    try {
      final apiService = ref.read(kikoeruApiServiceProvider);
      final workData = await apiService.getWork(workId);
      final work = Work.fromJson(workData);

      if (mounted && _currentWorkId == workId) {
        _currentRating = work.userRating;
        _onlineWorkProgress = work.progress;
        _workProgress.value = ref
            .read(automaticWorkMarkingProvider)
            .progressFor(workId, work.progress);
      }
    } catch (e) {
      debugPrint('Failed to load progress for work $workId: $e');
    }
  }

  String? _buildWorkCoverUrl(int? workId, String? artworkUrl) {
    final authState = ref.read(authProvider);
    return resolveArtworkSource(
      workId: workId,
      artworkUrl: artworkUrl,
      host: authState.host ?? '',
      token: authState.token ?? '',
    );
  }

  void _handleSeekChanged(double value) {
    if (ref.read(isTrackLoadingProvider).valueOrNull ?? false) return;
    _seekPreviewClearTimer?.cancel();
    final dur = ref.read(durationProvider).value ?? Duration.zero;
    _seekPreview.value = (
      isSeekingManually: true,
      seekValue: value,
      position: Duration(milliseconds: (value * dur.inMilliseconds).round()),
    );
  }

  void _handleSeekEnd(double value) {
    if (ref.read(isTrackLoadingProvider).valueOrNull ?? false) return;
    _seekPreviewClearTimer?.cancel();
    final dur = ref.read(durationProvider).value ?? Duration.zero;
    final newPosition = Duration(
      milliseconds: (value * dur.inMilliseconds).round(),
    );

    _seekPreview.value = (
      isSeekingManually: true,
      seekValue: value,
      position: newPosition,
    );

    ref
        .read(audioPlayerControllerProvider.notifier)
        .seekAndPersist(newPosition);

    _seekPreviewClearTimer = Timer(const Duration(milliseconds: 100), () {
      _seekPreviewClearTimer = null;
      if (mounted) {
        _seekPreview.value = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(automaticWorkMarkingRevisionProvider, (_, __) {
      final workId = _currentWorkId;
      if (workId != null) {
        _workProgress.value = ref
            .read(automaticWorkMarkingProvider)
            .progressFor(workId, _onlineWorkProgress);
      }
    });
    final currentTrack = ref.watch(currentTrackProvider);
    final isTrackLoading =
        ref.watch(isTrackLoadingProvider).valueOrNull ?? false;

    // 启用自动字幕加载器
    ref.watch(lyricAutoLoaderProvider);
    // Keep the adjacent information page warm so its cards move with the
    // PageView instead of appearing only after the page settles.
    if (_playerPagesActivated) {
      ref.listen(playerWorkDetailsProvider, (_, __) {});
    }

    return currentTrack.when(
      data: (track) {
        if (track == null) {
          if (_directQueueEntry) {
            return Scaffold(
              body: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.escape): _handleBack,
                },
                child: Focus(
                  autofocus: true,
                  focusNode: _keyboardFocusNode,
                  child: SafeArea(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final size = MediaQuery.sizeOf(context);
                        final isWide = usesWidePlayerLayout(
                          size.width,
                          height: size.height,
                        );
                        _lastWasWide = isWide;
                        if (!isWide) {
                          _compactSharedWidth = math.max(
                            0,
                            constraints.maxWidth - 56,
                          );
                        }
                        return _buildQueuePane(context, isWide: isWide);
                      },
                    ),
                  ),
                ),
              ),
            );
          }
          return Scaffold(
            body: Center(child: Text(S.of(context).noAudioPlaying)),
          );
        }
        if (_playerPagesActivated) _scheduleProgressLoad(track);
        final coverUrl = _buildWorkCoverUrl(track.workId, track.artworkUrl);
        final baseTheme = Theme.of(context);
        final artworkThemeSeed = ref.watch(
          artworkThemeSeedProvider.select((state) => state.seed),
        );
        final resolvedPalette = PlayerVisualPalette.fromDominant(
          artworkThemeSeed ?? baseTheme.colorScheme.primary,
          brightness: baseTheme.brightness,
          accent: baseTheme.colorScheme.primary,
          onAccent: baseTheme.colorScheme.onPrimary,
        );
        final palette =
            _routePaletteFrozen &&
                widget.initialPaletteTrackId == track.id &&
                widget.initialPalette != null
            ? widget.initialPalette!
            : resolvedPalette;
        _resolvedRoutePalette = resolvedPalette;
        _displayedRoutePalette = palette;
        return _buildSaltPlayerShell(
          context,
          track: track,
          coverUrl: coverUrl,
          palette: palette,
          isTrackLoading: isTrackLoading,
        );
      },
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, stack) => Scaffold(
        body: Center(
          child: Text(S.of(context).errorWithMessage(error.toString())),
        ),
      ),
    );
  }

  void _scheduleProgressLoad(AudioTrack track) {
    if (track.workId == null || _currentWorkId == track.workId) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _currentWorkId == track.workId) return;
      _currentWorkId = track.workId;
      _onlineWorkProgress = null;
      _currentRating = null;
      _workProgress.value = null;
      _loadCurrentProgress(track.workId!);
    });
  }

  Widget _buildSaltPlayerShell(
    BuildContext context, {
    required AudioTrack track,
    required String? coverUrl,
    required PlayerVisualPalette palette,
    required bool isTrackLoading,
  }) {
    final baseTheme = Theme.of(context);
    final playerScheme = baseTheme.colorScheme.copyWith(
      primary: palette.accent,
      onPrimary: palette.onAccent,
      primaryContainer: palette.foreground.withValues(alpha: 0.16),
      onPrimaryContainer: palette.foreground,
      surface: Colors.transparent,
      onSurface: palette.foreground,
      onSurfaceVariant: palette.secondaryForeground,
      surfaceContainerHighest: palette.panelColor,
      outline: palette.panelStroke,
      outlineVariant: palette.panelStroke,
    );
    final playerTheme = baseTheme.copyWith(
      colorScheme: playerScheme,
      scaffoldBackgroundColor: Colors.transparent,
      dividerColor: palette.panelStroke,
      iconTheme: baseTheme.iconTheme.copyWith(color: palette.foreground),
      textTheme: baseTheme.textTheme.apply(
        bodyColor: palette.foreground,
        displayColor: palette.foreground,
      ),
      sliderTheme: baseTheme.sliderTheme.copyWith(
        activeTrackColor: palette.foreground,
        thumbColor: palette.foreground,
        overlayColor: palette.foreground.withValues(alpha: 0.12),
        inactiveTrackColor: palette.foreground.withValues(alpha: 0.20),
      ),
    );
    final backgroundBrightness = palette.foreground.computeLuminance() > 0.5
        ? Brightness.dark
        : Brightness.light;
    final motionDuration = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 280);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: transparentSystemBarsForBrightness(backgroundBrightness),
      child: Theme(
        data: playerTheme,
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.escape): _handleBack,
            },
            child: Focus(
              autofocus: true,
              focusNode: _keyboardFocusNode,
              child: ValueListenableBuilder<int>(
                valueListenable: _semanticPageRevision,
                builder: (context, _, child) => PopScope(
                  canPop:
                      !_isLyricLocked &&
                      !_queueTransitionActive &&
                      (_directQueueEntry ||
                          _rightPane != PlayerRightPane.queue),
                  onPopInvokedWithResult: (didPop, result) {
                    if (!didPop) _handleBack();
                  },
                  child: child!,
                ),
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) => _activateDeferredPlayerPages(),
                  child: PlayerBackdropGroup(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: RepaintBoundary(
                            key: const ValueKey('player-palette-background'),
                            child: PlayerPaletteBackground(
                              duration: motionDuration,
                              gradient: palette.backgroundGradient,
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: Offstage(
                            key: const ValueKey(
                              'player-stage-under-fullscreen',
                            ),
                            offstage: _isLyricLocked,
                            child: IgnorePointer(
                              ignoring: _isLyricLocked,
                              child: TickerMode(
                                enabled: !_isLyricLocked,
                                child: ValueListenableBuilder<bool>(
                                  valueListenable: _deferredPlayerPagesReady,
                                  builder: (context, _, __) => LayoutBuilder(
                                    builder: (context, constraints) {
                                      final isWide = usesWidePlayerLayout(
                                        constraints.maxWidth,
                                        height: constraints.maxHeight,
                                      );
                                      _syncResponsivePageController(
                                        isWide,
                                        constraints.biggest,
                                      );
                                      return isWide
                                          ? _buildWidePlayer(
                                              context,
                                              track: track,
                                              coverUrl: coverUrl,
                                              previewPalette: palette,
                                              availableWidth:
                                                  constraints.maxWidth,
                                              availableHeight:
                                                  constraints.maxHeight,
                                            )
                                          : _buildCompactPlayer(
                                              context,
                                              track: track,
                                              coverUrl: coverUrl,
                                              previewPalette: palette,
                                            );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_isLyricLocked)
                          Positioned.fill(child: _buildPortraitLyricView()),
                        if (isTrackLoading)
                          ValueListenableBuilder<int>(
                            valueListenable: _semanticPageRevision,
                            builder: (context, _, __) =>
                                _buildTrackLoadingOverlay(context),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _syncResponsivePageController(bool isWide, Size stageSize) {
    final oldWide = _lastWasWide;
    final modeChanged = oldWide != null && oldWide != isWide;
    final sizeChanged =
        _lastPlayerStageSize != null && _lastPlayerStageSize != stageSize;
    if (oldWide == null) {
      _lastWasWide = isWide;
      _lastPlayerStageSize = stageSize;
      _dismissCoordinator.scheduleVisualModeSync(context);
      return;
    }
    if (!modeChanged && !sizeChanged) return;

    final dragOrigins = Map<PageController, int>.of(_pageDragOrigins);
    final requestedTargets = Map<PageController, int>.of(_requestedPageTargets);
    final oldCompactPage = _pageAfterResize(
      _compactPageController,
      dragOrigins,
      requestedTargets,
      _semanticCompactPage,
    );
    final oldRightPage = _pageAfterResize(
      _wideRightPageController,
      dragOrigins,
      requestedTargets,
      _pageForRightPane(
        _rightPane == PlayerRightPane.queue
            ? _queueReturnState?.rightPane ?? PlayerRightPane.controls
            : _rightPane,
      ),
    );
    final oldVerticalController = oldWide
        ? _wideVerticalPageController
        : _compactVerticalPageController;
    final oldVerticalPage = _directQueueEntry
        ? 0
        : _pageAfterResize(
            oldVerticalController,
            dragOrigins,
            requestedTargets,
            _rightPane == PlayerRightPane.queue ? 1 : 0,
          );

    if (oldWide) {
      _applyWidePageSemantics(
        oldRightPage,
        applyRight: _rightPane != PlayerRightPane.queue,
      );
    } else if (_rightPane != PlayerRightPane.queue) {
      _applyCompactPageSemantics(oldCompactPage);
    }

    final queuePageSelected = !_directQueueEntry && oldVerticalPage == 1;
    if (queuePageSelected && _rightPane != PlayerRightPane.queue) {
      _captureQueueOrigin();
    }
    if (queuePageSelected) {
      _queueHasBeenOpened = true;
      _rightPane = PlayerRightPane.queue;
    } else if (!_directQueueEntry && _rightPane == PlayerRightPane.queue) {
      _restoreQueueSemanticFields();
    }

    if (queuePageSelected && oldWide && !isWide) {
      _compactPage = _pageForRightPane(
        _queueReturnState?.rightPane ?? PlayerRightPane.controls,
      );
    }

    _pageDragOrigins.clear();
    _requestedPageTargets.clear();
    _verticalPageDragActive = false;
    _queueTransitionActive = false;
    _semanticTransitionGeneration++;
    _compactPageHandoff.cancelActiveDrags();
    _widePageHandoff.cancelActiveDrags();
    _lastWasWide = isWide;
    _lastPlayerStageSize = stageSize;
    final compactTarget = oldWide
        ? queuePageSelected && !isWide
              ? _compactPage
              : _semanticCompactPage
        : _compactPage;
    _compactPage = compactTarget;
    _dismissCoordinator.scheduleVisualModeSync(context);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (isWide) {
        _restorePageController(
          _wideRightPageController,
          _pageForRightPane(
            _rightPane == PlayerRightPane.queue
                ? _queueReturnState?.rightPane ?? PlayerRightPane.controls
                : _rightPane,
          ),
        );
        _restorePageController(
          _wideVerticalPageController,
          _directQueueEntry
              ? 0
              : _rightPane == PlayerRightPane.queue
              ? 1
              : 0,
        );
      } else {
        _restorePageController(_compactPageController, compactTarget);
        _restorePageController(
          _compactVerticalPageController,
          _directQueueEntry
              ? 0
              : _rightPane == PlayerRightPane.queue
              ? 1
              : 0,
        );
      }
    });
  }

  void _applyCompactPageSemantics(int page) {
    if (_rightPane == PlayerRightPane.queue || page == _compactPage) return;
    _compactPage = page.clamp(0, 2).toInt();
    _rightPane = _rightPaneForPage(_compactPage);
  }

  void _applyWidePageSemantics(int rightPage, {required bool applyRight}) {
    if (!applyRight) return;
    _rightPane = _rightPaneForPage(rightPage);
    _compactPage = _pageForRightPane(_rightPane);
  }

  void _restoreQueueSemanticFields() {
    _rightPane = _queueReturnState?.rightPane ?? PlayerRightPane.controls;
    if (_rightPane == PlayerRightPane.queue) {
      _rightPane = PlayerRightPane.controls;
    }
    _compactPage = _pageForRightPane(_rightPane);
    _queueReturnState = null;
  }

  int _pageAfterResize(
    PageController controller,
    Map<PageController, int> dragOrigins,
    Map<PageController, int> requestedTargets,
    int fallback,
  ) {
    final requested = requestedTargets[controller];
    if (requested != null) return requested;
    if (!controller.hasClients || controller.positions.length != 1) {
      return fallback;
    }
    final page = controller.page;
    if (page == null) return fallback;
    final floorPage = page.floor();
    final fraction = page - floorPage;
    if ((fraction - 0.5).abs() <= 0.0001) {
      return dragOrigins[controller] ?? fallback;
    }
    return fraction < 0.5 ? floorPage : floorPage + 1;
  }

  void _restorePageController(PageController controller, int page) {
    if (controller.hasClients && controller.positions.length == 1) {
      controller.jumpToPage(page);
    }
  }

  bool _handlePageScrollNotification(
    ScrollNotification notification,
    PageController controller, {
    required bool vertical,
  }) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      final origin = _pageAfterResize(
        controller,
        const {},
        const {},
        _semanticPageForController(controller),
      );
      _pageDragOrigins[controller] = origin;
      _requestedPageTargets.remove(controller);
      if (vertical) {
        _verticalPageDragActive = true;
        _prepareQueueForPageDrag();
        if (!_queueTransitionActive && mounted) {
          _commitSemanticPage(() => _queueTransitionActive = true);
        }
      }
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        !_pageDragOrigins.containsKey(controller)) {
      final viewportDimension = notification.metrics.viewportDimension;
      final scrollDelta = notification.scrollDelta ?? 0;
      final pageBeforeUpdate = viewportDimension == 0
          ? controller.initialPage.toDouble()
          : (notification.metrics.pixels - scrollDelta) / viewportDimension;
      final fallback = _semanticPageForController(controller);
      final floorPage = pageBeforeUpdate.floor();
      final fraction = pageBeforeUpdate - floorPage;
      _pageDragOrigins[controller] = (fraction - 0.5).abs() <= 0.0001
          ? fallback
          : fraction < 0.5
          ? floorPage
          : floorPage + 1;
      _requestedPageTargets.remove(controller);
      if (vertical) {
        _verticalPageDragActive = true;
        _prepareQueueForPageDrag();
        if (!_queueTransitionActive && mounted) {
          _commitSemanticPage(() => _queueTransitionActive = true);
        }
      }
    } else if (notification is ScrollEndNotification) {
      _pageDragOrigins.remove(controller);
      if (vertical) {
        _verticalPageDragActive = false;
        if (!_directQueueEntry &&
            _rightPane != PlayerRightPane.queue &&
            (controller.page ?? 0) < 0.5 &&
            _requestedPageTargets[controller] != 1) {
          _queueReturnState = null;
        }
        if (_queueTransitionActive &&
            _requestedPageTargets.isEmpty &&
            mounted) {
          _commitSemanticPage(() => _queueTransitionActive = false);
        }
      }
    }
    return false;
  }

  int _semanticPageForController(PageController controller) {
    if (identical(controller, _compactPageController)) {
      return _semanticCompactPage;
    }
    if (identical(controller, _wideRightPageController)) {
      return _pageForRightPane(
        _rightPane == PlayerRightPane.queue
            ? _queueReturnState?.rightPane ?? PlayerRightPane.controls
            : _rightPane,
      );
    }
    return _rightPane == PlayerRightPane.queue ? 1 : 0;
  }

  int get _semanticCompactPage => _compactPage;

  int _pageForRightPane(PlayerRightPane pane) => switch (pane) {
    PlayerRightPane.details => 0,
    PlayerRightPane.controls => 1,
    PlayerRightPane.lyrics => 2,
    PlayerRightPane.queue => 1,
  };

  PlayerRightPane _rightPaneForPage(int page) => switch (page) {
    0 => PlayerRightPane.details,
    2 => PlayerRightPane.lyrics,
    _ => PlayerRightPane.controls,
  };

  Widget _buildWidePlayer(
    BuildContext context, {
    required AudioTrack track,
    required String? coverUrl,
    required PlayerVisualPalette previewPalette,
    required double availableWidth,
    required double availableHeight,
  }) {
    final directQueueOnly = _directQueueEntry && !_playerPagesActivated;
    final shortStage = availableHeight <= playerShortControlsHeightBreakpoint;
    final titleDismissDrag = _dismissCoordinator.callbacks(context);
    final mainBodyDismissDrag = _dismissCoordinator.callbacks(
      context,
      mainBodyOnly: true,
    );
    final safeAreaPadding = MediaQuery.paddingOf(context);
    final safeWidth = math.max(
      0.0,
      availableWidth - safeAreaPadding.horizontal,
    );
    final outerPadding = safeWidth >= 1200
        ? 48.0
        : safeWidth < playerNarrowWideLayoutBreakpoint
        ? 8.0
        : safeWidth < playerWideLayoutBreakpoint
        ? 16.0
        : 24.0;
    final rowWidth =
        availableWidth -
        math.max(safeAreaPadding.left, outerPadding) -
        math.max(safeAreaPadding.right, outerPadding);
    final narrowWide = rowWidth < playerNarrowWideLayoutBreakpoint;
    final gap = safeWidth >= 1200
        ? 40.0
        : narrowWide
        ? 12.0
        : 20.0;
    // The main controls need 266 px plus the pane's 12 px padding on each side.
    final rightPaneWidth = narrowWide
        ? math.max(290.0, (rowWidth - gap) * 0.55)
        : (rowWidth - gap) / 2;
    final deferredPagesReady = _deferredPlayerPagesReady.value;
    final wideRightPageChildren = <Widget>[
      _withOriginalPlayerGestureSettings(
        context,
        _PlayerPageBoundary(
          key: const ValueKey('wide-details-page-boundary'),
          pageController: _wideRightPageController,
          pageIndex: 0,
          child: _deferredPlayerPage(
            ready: deferredPagesReady,
            placeholderKey: const ValueKey('wide-details-page-placeholder'),
            builder: () => LayoutBuilder(
              builder: (context, constraints) {
                final detailsWidth = math.min(
                  704.0,
                  constraints.maxWidth * 0.90,
                );
                return Center(
                  child: SizedBox(
                    width: detailsWidth,
                    height: double.infinity,
                    child: ValueListenableBuilder<int>(
                      valueListenable: _semanticPageRevision,
                      builder: (context, _, __) => PlayerAudioDetailsPanel(
                        key: const ValueKey('wide-audio-details-pane'),
                        onOpenWork: _openKnownWork,
                        scrollController: _wideDetailsScrollController,
                        isActive:
                            !_isLyricLocked &&
                            _rightPane == PlayerRightPane.details,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
      _withOriginalPlayerGestureSettings(
        context,
        _PlayerPageBoundary(
          key: const ValueKey('wide-controls-page-boundary'),
          pageController: _wideRightPageController,
          pageIndex: 1,
          child: _buildControlsPane(
            context,
            track: track,
            isWide: true,
            showTrackHeader: false,
            shortStage: shortStage,
            dismissDrag: mainBodyDismissDrag,
          ),
        ),
      ),
      _withOriginalPlayerGestureSettings(
        context,
        _PlayerPageBoundary(
          key: const ValueKey('wide-lyrics-page-boundary'),
          pageController: _wideRightPageController,
          pageIndex: 2,
          child: _deferredPlayerPage(
            ready: deferredPagesReady,
            placeholderKey: const ValueKey('wide-lyrics-page-placeholder'),
            builder: () => _buildLyricsPane(context, isWide: true),
          ),
        ),
      ),
    ];
    return SafeArea(
      maintainBottomViewPadding: true,
      minimum: EdgeInsets.fromLTRB(outerPadding, 18, outerPadding, 18),
      child: Row(
        key: const ValueKey('wide-player-layout'),
        children: [
          Expanded(
            child: Column(
              children: [
                _buildWideHeader(
                  context,
                  track,
                  dismissDrag: titleDismissDrag,
                  allowTitleAnimation: !directQueueOnly,
                ),
                Expanded(
                  child: PlayerVerticalSwipeRegion(
                    key: const ValueKey('wide-cover-dismiss-surface'),
                    swipeDownDrag: mainBodyDismissDrag,
                    child: _buildCoverPane(
                      context,
                      track: track,
                      coverUrl: coverUrl,
                      isWide: true,
                      previewPalette: previewPalette,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: gap),
          SizedBox(
            width: rightPaneWidth,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) => _handlePageScrollNotification(
                notification,
                _wideVerticalPageController,
                vertical: true,
              ),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: PageView(
                  key: const ValueKey('wide-vertical-player-pages'),
                  controller: _wideVerticalPageController,
                  physics: const PlayerPageScrollPhysics(),
                  scrollDirection: Axis.vertical,
                  allowImplicitScrolling: true,
                  onPageChanged: _onWideVerticalPageChanged,
                  children: directQueueOnly
                      ? <Widget>[
                          _PlayerPageBoundary(
                            key: const ValueKey('wide-direct-queue-page'),
                            pageController: _wideVerticalPageController,
                            pageIndex: 0,
                            child: _buildQueuePane(context, isWide: true),
                          ),
                        ]
                      : <Widget>[
                          _PlayerPageBoundary(
                            key: const ValueKey('wide-right-base-page'),
                            pageController: _wideVerticalPageController,
                            pageIndex: 0,
                            // Match the slider's slop before a rebuild can disable paging.
                            child: _withOriginalPlayerGestureSettings(
                              context,
                              ValueListenableBuilder<bool>(
                                valueListenable: _progressGestureActive,
                                builder: (_, progressGestureActive, _) =>
                                    NotificationListener<ScrollNotification>(
                                      onNotification: (notification) =>
                                          _handlePageScrollNotification(
                                            notification,
                                            _wideRightPageController,
                                            vertical: false,
                                          ),
                                      child: PageView(
                                        key: const ValueKey('wide-right-pages'),
                                        controller: _wideRightPageController,
                                        physics: progressGestureActive
                                            ? const NeverScrollableScrollPhysics()
                                            : const PlayerPageScrollPhysics(),
                                        allowImplicitScrolling: true,
                                        onPageChanged: _onWideRightPageChanged,
                                        children: wideRightPageChildren,
                                      ),
                                    ),
                              ),
                            ),
                          ),
                          _queueHasBeenOpened
                              ? _PlayerPageBoundary(
                                  key: const ValueKey('wide-queue-page'),
                                  pageController: _wideVerticalPageController,
                                  pageIndex: 1,
                                  child: _buildQueuePane(context, isWide: true),
                                )
                              : const SizedBox.shrink(
                                  key: ValueKey('wide-queue-page-placeholder'),
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

  Widget _buildWideHeader(
    BuildContext context,
    AudioTrack track, {
    required PlayerVerticalDragCallbacks dismissDrag,
    required bool allowTitleAnimation,
  }) {
    return PlayerVerticalSwipeRegion(
      key: const ValueKey('wide-header-dismiss-surface'),
      swipeDownDrag: dismissDrag,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 704),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildTrackTitleBlock(
                    context,
                    track,
                    true,
                    allowAnimation: allowTitleAnimation,
                  ),
                ),
                const SizedBox(width: 20),
                IconButton(
                  key: const ValueKey('player-more-button-wide'),
                  tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                  onPressed: () => _showMoreSheet(context, track),
                  icon: const Icon(Icons.more_vert),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactPlayer(
    BuildContext context, {
    required AudioTrack track,
    required String? coverUrl,
    required PlayerVisualPalette previewPalette,
  }) {
    return SafeArea(
      maintainBottomViewPadding: true,
      minimum: const EdgeInsets.fromLTRB(0, 10, 0, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
          final headerReserve = 72 + (textScale.clamp(1, 2) - 1) * 60;
          final compactLayout = _compactContentLayout(
            context,
            BoxConstraints(
              maxWidth: constraints.maxWidth,
              maxHeight: math.max(
                0,
                constraints.maxHeight - headerReserve - 12,
              ),
            ),
          );
          final sharedWidth = compactLayout.width;
          final actionWidth = math.min(sharedWidth + 24, constraints.maxWidth);
          _compactSharedWidth = sharedWidth;
          final titleDismissDrag = _dismissCoordinator.callbacks(context);
          final mainBodyDismissDrag = _dismissCoordinator.callbacks(
            context,
            mainBodyOnly: true,
          );
          final deferredPagesReady = _deferredPlayerPagesReady.value;
          final compactPageChildren = _playerPagesActivated
              ? SliverChildListDelegate([
                  _withOriginalPlayerGestureSettings(
                    context,
                    _PlayerPageBoundary(
                      key: const ValueKey('compact-details-page-boundary'),
                      pageController: _compactPageController,
                      pageIndex: 0,
                      child: _deferredPlayerPage(
                        ready: deferredPagesReady,
                        placeholderKey: const ValueKey(
                          'compact-details-page-placeholder',
                        ),
                        builder: () => Center(
                          child: SizedBox(
                            width: sharedWidth,
                            height: double.infinity,
                            child: ValueListenableBuilder<int>(
                              valueListenable: _semanticPageRevision,
                              builder: (context, _, __) =>
                                  PlayerAudioDetailsPanel(
                                    key: const ValueKey(
                                      'compact-audio-details-pane',
                                    ),
                                    onOpenWork: _openKnownWork,
                                    scrollController:
                                        _compactDetailsScrollController,
                                    isActive:
                                        !_isLyricLocked &&
                                        !_queueTransitionActive &&
                                        _compactPage == 0 &&
                                        _rightPane != PlayerRightPane.queue,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _withOriginalPlayerGestureSettings(
                    context,
                    _PlayerPageBoundary(
                      key: const ValueKey('compact-main-page-boundary'),
                      pageController: _compactPageController,
                      pageIndex: 1,
                      child: _buildCompactMain(
                        context,
                        track: track,
                        coverUrl: coverUrl,
                        sharedWidth: sharedWidth,
                        actionWidth: actionWidth,
                        previewMaxHeight: compactLayout.previewMaxHeight,
                        dismissDrag: mainBodyDismissDrag,
                        previewPalette: previewPalette,
                      ),
                    ),
                  ),
                  _withOriginalPlayerGestureSettings(
                    context,
                    _PlayerPageBoundary(
                      key: const ValueKey('compact-lyrics-page-boundary'),
                      pageController: _compactPageController,
                      pageIndex: 2,
                      child: _deferredPlayerPage(
                        ready: deferredPagesReady,
                        placeholderKey: const ValueKey(
                          'compact-lyrics-page-placeholder',
                        ),
                        builder: () => _buildLyricsPane(
                          context,
                          isWide: false,
                          actionWidth: actionWidth,
                        ),
                      ),
                    ),
                  ),
                ], addRepaintBoundaries: false)
              : null;
          final playerStage = !_playerPagesActivated
              ? const SizedBox.shrink()
              : Column(
                  key: const ValueKey('compact-player-layout'),
                  children: [
                    _buildCompactHeader(
                      context,
                      track,
                      sharedWidth,
                      dismissDrag: titleDismissDrag,
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _progressGestureActive,
                          builder: (context, progressGestureActive, _) =>
                              NotificationListener<ScrollNotification>(
                                onNotification: (notification) =>
                                    _handlePageScrollNotification(
                                      notification,
                                      _compactPageController,
                                      vertical: false,
                                    ),
                                child: _withEarlierPlayerPageGestureStart(
                                  context,
                                  PageView.custom(
                                    key: const ValueKey('compact-player-pages'),
                                    controller: _compactPageController,
                                    physics: progressGestureActive
                                        ? const NeverScrollableScrollPhysics()
                                        : const PlayerPageScrollPhysics(),
                                    allowImplicitScrolling: true,
                                    onPageChanged: _onCompactPageChanged,
                                    childrenDelegate: compactPageChildren!,
                                  ),
                                ),
                              ),
                        ),
                      ),
                    ),
                  ],
                );
          final queueStage = _queueHasBeenOpened
              ? _buildQueuePane(context, isWide: false)
              : const SizedBox.shrink(
                  key: ValueKey('compact-queue-page-placeholder'),
                );
          final verticalPages = _directQueueEntry && !_playerPagesActivated
              ? <Widget>[
                  _PlayerPageBoundary(
                    key: const ValueKey('compact-direct-queue-page'),
                    pageController: _compactVerticalPageController,
                    pageIndex: 0,
                    child: queueStage,
                  ),
                ]
              : <Widget>[
                  _PlayerPageBoundary(
                    key: const ValueKey('compact-base-page'),
                    pageController: _compactVerticalPageController,
                    pageIndex: 0,
                    child: playerStage,
                  ),
                  _queueHasBeenOpened
                      ? _PlayerPageBoundary(
                          key: const ValueKey('compact-queue-page'),
                          pageController: _compactVerticalPageController,
                          pageIndex: 1,
                          child: queueStage,
                        )
                      : queueStage,
                ];
          return KeyedSubtree(
            key: const ValueKey('compact-player-vertical-pages'),
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) => _handlePageScrollNotification(
                notification,
                _compactVerticalPageController,
                vertical: true,
              ),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: PageView(
                  key: const ValueKey('compact-vertical-player-pages'),
                  controller: _compactVerticalPageController,
                  physics: const PlayerPageScrollPhysics(),
                  scrollDirection: Axis.vertical,
                  allowImplicitScrolling: true,
                  onPageChanged: _onCompactVerticalPageChanged,
                  children: verticalPages,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCompactHeader(
    BuildContext context,
    AudioTrack track,
    double sharedWidth, {
    required PlayerVerticalDragCallbacks dismissDrag,
  }) {
    const leftPadding = 12.0;
    const titleGap = 20.0;
    const actionSize = 48.0;
    final stackHeader = sharedWidth <= leftPadding + titleGap + actionSize;
    final title = ValueListenableBuilder<int>(
      valueListenable: _semanticPageRevision,
      builder: (context, _, __) => _buildTrackTitleBlock(
        context,
        track,
        false,
        allowAnimation:
            !_queueTransitionActive && _rightPane != PlayerRightPane.queue,
      ),
    );
    final moreButton = IconButton(
      key: const ValueKey('player-more-button'),
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      onPressed: () => _showMoreSheet(context, track),
      padding: EdgeInsets.zero,
      alignment: Alignment.center,
      constraints: const BoxConstraints(
        minWidth: actionSize,
        minHeight: actionSize,
      ),
      icon: const Icon(Icons.more_vert),
    );
    return PlayerVerticalSwipeRegion(
      key: const ValueKey('compact-header-dismiss-surface'),
      swipeDownDrag: dismissDrag,
      pageDragCoordinator: _compactPageHandoff,
      child: Center(
        child: SizedBox(
          width: sharedWidth + 24,
          child: Padding(
            padding: EdgeInsets.only(
              left: stackHeader ? 0 : leftPadding,
              top: 12,
            ),
            child: stackHeader
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      title,
                      Align(
                        alignment: Alignment.centerRight,
                        child: moreButton,
                      ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: titleGap),
                      moreButton,
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrackTitleBlock(
    BuildContext context,
    AudioTrack track,
    bool isWide, {
    required bool allowAnimation,
  }) {
    final presentation = ref.watch(playerTrackChangePresentationProvider);
    final presentationMatches = presentation?.trackId == track.id;
    final direction = presentationMatches
        ? presentation!.direction
        : PlayerTrackChangeDirection.none;
    final presentationRevision = presentationMatches
        ? presentation!.revision
        : null;
    return _PlayerTrackTitleSwitcher(
      track: track,
      isWide: isWide,
      allowAnimation: allowAnimation,
      direction: direction,
      presentationRevision: presentationRevision,
      onOpenWorkDetails: (track) => _openTrackWorkDetails(context, track),
    );
  }

  void _togglePlayback() {
    final controller = ref.read(audioPlayerControllerProvider.notifier);
    if (controller.isPlaying) {
      unawaited(controller.pause());
    } else {
      unawaited(controller.play());
    }
  }

  Widget _buildCompactMain(
    BuildContext context, {
    required AudioTrack track,
    required String? coverUrl,
    required double sharedWidth,
    required double actionWidth,
    required double previewMaxHeight,
    required PlayerVerticalDragCallbacks dismissDrag,
    required PlayerVisualPalette previewPalette,
  }) {
    final size = MediaQuery.sizeOf(context);
    final isPortrait = size.width <= size.height;
    final lyricSettings = ref.watch(playerLyricSettingsProvider);
    final minimumPreviewHeight = playerLyricPreviewHeight(
      width: sharedWidth,
      fontSize: lyricSettings.smallFontSize,
      lineHeight: lyricSettings.smallLineHeight,
      textScaler: MediaQuery.textScalerOf(context),
      lineCount: 1,
      compact: false,
    );
    final verticalGap =
        sharedWidth < PlayerControlsWidget.primaryRowMinimumWidth ||
            (!isPortrait && size.height <= playerShortControlsHeightBreakpoint)
        ? 0.0
        : _compactPlayerLyricGap;
    final content = Center(
      child: LayoutBuilder(
        builder: (context, mainConstraints) => SizedBox(
          key: const ValueKey('compact-main-shared-width'),
          width: sharedWidth,
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final bodyHeight = math.max(
                      0.0,
                      constraints.maxHeight - verticalGap,
                    );
                    final lyricAreaHeight = math.min(
                      isPortrait
                          ? _compactPortraitLyricSlotHeight
                          : previewMaxHeight,
                      isPortrait
                          ? math.min(
                              bodyHeight,
                              math.max(
                                minimumPreviewHeight,
                                bodyHeight -
                                    sharedWidth /
                                        PlayerCoverWidget.preferredAspectRatio,
                              ),
                            )
                          : bodyHeight,
                    );
                    final coverAreaHeight = math.max(
                      0.0,
                      bodyHeight - lyricAreaHeight,
                    );
                    final coverHeight =
                        math.min(
                          sharedWidth,
                          coverAreaHeight *
                              PlayerCoverWidget.preferredAspectRatio,
                        ) /
                        PlayerCoverWidget.preferredAspectRatio;
                    final coverBottomGap = math.max(
                      0.0,
                      (coverAreaHeight - coverHeight) / 2,
                    );
                    final coverBottom = coverAreaHeight - coverBottomGap;
                    final trackTop =
                        constraints.maxHeight +
                        PlayerProgressSection.compactTrackTopInset;
                    final availablePreviewHeight = isPortrait
                        ? math.max(
                            0.0,
                            trackTop - coverBottom - _compactPlayerLyricGap * 2,
                          )
                        : lyricAreaHeight + coverBottomGap;
                    final visiblePreviewHeight = math.min(
                      previewMaxHeight,
                      availablePreviewHeight,
                    );
                    final previewTop = isPortrait
                        ? (coverBottom + trackTop - visiblePreviewHeight) / 2
                        : bodyHeight - visiblePreviewHeight;
                    return Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        Column(
                          children: [
                            Expanded(
                              child: PlayerVerticalSwipeRegion(
                                key: const ValueKey(
                                  'compact-main-cover-dismiss-surface',
                                ),
                                swipeDownDrag: dismissDrag,
                                pageDragCoordinator: _compactPageHandoff,
                                child: RepaintBoundary(
                                  child: _buildPlayerCoverArtwork(
                                    track: track,
                                    coverUrl: coverUrl,
                                    isWide: false,
                                    previewPalette: previewPalette,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              key: const ValueKey('compact-main-lyric-area'),
                              height: lyricAreaHeight,
                            ),
                            SizedBox(height: verticalGap),
                          ],
                        ),
                        Positioned(
                          key: const ValueKey(
                            'compact-main-lyric-expanded-area',
                          ),
                          left: 0,
                          right: 0,
                          top: previewTop,
                          height: visiblePreviewHeight,
                          child: SizedBox(
                            key: const ValueKey(
                              'compact-main-lyric-width-boundary',
                            ),
                            width: sharedWidth,
                            height: isPortrait ? null : double.infinity,
                            child: ThreeLineLyricDisplay(
                              key: const ValueKey(
                                'compact-main-lyric-scroll-surface',
                              ),
                              onSeekRequested: (position) => ref
                                  .read(audioPlayerControllerProvider.notifier)
                                  .seekAndPersist(position),
                              onLineDoubleTap: _togglePlayback,
                              enableLineTapFeedback: true,
                              lineCount: 5,
                              textHorizontalPadding: 12,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              PlayerVerticalSwipeRegion(
                key: const ValueKey('compact-main-controls-dismiss-surface'),
                swipeDownDrag: dismissDrag,
                pageDragCoordinator: _compactPageHandoff,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.max(
                      0.0,
                      mainConstraints.maxHeight - verticalGap,
                    ),
                  ),
                  child: SingleChildScrollView(
                    key: const ValueKey('compact-main-controls-scroll'),
                    primary: false,
                    physics: const ClampingScrollPhysics(),
                    child: _buildControlsPane(
                      context,
                      track: track,
                      isWide: false,
                      showTrackHeader: false,
                      enableQueueGesture: false,
                      horizontalPadding: 0,
                      additionalActionWidth: actionWidth,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return KeyedSubtree(
      key: const ValueKey('compact-main-page'),
      child: RepaintBoundary(child: content),
    );
  }

  Widget _buildPlayerCoverArtwork({
    required AudioTrack track,
    required String? coverUrl,
    required bool isWide,
    required PlayerVisualPalette previewPalette,
  }) {
    return Consumer(
      builder: (context, ref, child) {
        final service = ref.read(audioPlayerServiceProvider);
        final state =
            ref.watch(playerStateProvider).valueOrNull ?? service.playerState;
        final loading =
            ref.watch(isTrackLoadingProvider).valueOrNull ??
            service.isTrackLoading;
        return ValueListenableBuilder<bool?>(
          valueListenable: service.coverExpandedDuringSeek,
          builder: (context, expandedDuringSeek, child) {
            final expanded =
                expandedDuringSeek ??
                state.playing &&
                    state.processingState == ProcessingState.ready &&
                    !loading;
            final scale = expanded ? 1.0 : 0.9;
            final disableAnimations = MediaQuery.disableAnimationsOf(context);
            return TweenAnimationBuilder<double>(
              tween: Tween(end: scale),
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 500),
              curve: const Cubic(0.34, 1.56, 0.64, 1),
              builder: (context, value, child) => Transform.scale(
                scale: disableAnimations ? scale : value,
                child: child,
              ),
              child: child,
            );
          },
          child: child,
        );
      },
      child: ValueListenableBuilder<int>(
        valueListenable: _semanticPageRevision,
        builder: (context, _, __) {
          return ValueListenableBuilder<String?>(
            valueListenable: _coverPreviewHeroTrackId,
            builder: (context, previewHeroTrackId, _) {
              final previewHeroActive = previewHeroTrackId == track.id;
              final cover = PlayerCoverWidget(
                track: track,
                workCoverUrl: coverUrl,
                isLandscape: isWide,
                artworkLayerLink: _coverLoadingLayerLink,
                animateTrackChanges: _isPlayerCoverVisible(isWide: isWide),
                onTap: coverUrl == null
                    ? null
                    : () => _showCoverPreview(track, coverUrl, previewPalette),
                previewHeroTag: playerCoverPreviewHeroTag(track.id),
                previewHeroEnabled: previewHeroActive,
              );
              // Only the active cover preview participates in its Hero flight.
              return HeroMode(enabled: previewHeroActive, child: cover);
            },
          );
        },
      ),
    );
  }

  ({double width, double previewMaxHeight}) _compactContentLayout(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final reservedHeight = 364 + (textScale.clamp(1, 2) - 1) * 72;
    final availableWidth = math.max(0.0, constraints.maxWidth - 56);
    final heightBound =
        math.max(160.0, constraints.maxHeight - reservedHeight) *
        PlayerCoverWidget.preferredAspectRatio;
    final minWidth = math.min(
      PlayerControlsWidget.compactMinimumWidth,
      constraints.maxWidth,
    );
    final paddedWidth = math.max(minWidth, constraints.maxWidth - 24);
    final originalWidth = math.max(
      math.min(PlayerControlsWidget.compactPreferredWidth, paddedWidth),
      math.min(availableWidth, heightBound),
    );
    final size = MediaQuery.sizeOf(context);
    final isPortrait = size.width <= size.height;
    final hasLyrics = ref.watch(
      lyricControllerProvider.select((state) => state.displayLyrics.isNotEmpty),
    );
    if (!hasLyrics) {
      return (
        width: originalWidth,
        previewMaxHeight: _compactPortraitLyricSlotHeight,
      );
    }
    final lyricSettings = ref.watch(playerLyricSettingsProvider);
    if (isPortrait) {
      return (
        width: originalWidth,
        previewMaxHeight: playerLyricPreviewHeight(
          width: originalWidth,
          fontSize: lyricSettings.smallFontSize,
          lineHeight: lyricSettings.smallLineHeight,
          textScaler: MediaQuery.textScalerOf(context),
          lineCount: 5,
          compact: false,
        ),
      );
    }
    final preferredPreviewHeight = math.min(
      constraints.maxHeight * 0.32,
      playerLyricPreviewHeight(
        width: originalWidth,
        fontSize: lyricSettings.smallFontSize,
        lineHeight: lyricSettings.smallLineHeight,
        textScaler: MediaQuery.textScalerOf(context),
        lineCount: 5,
        compact: false,
      ),
    );
    final extraHeight = math.max(0.0, preferredPreviewHeight - 144);
    final width = math.max(
      math.min(originalWidth, PlayerControlsWidget.compactPreferredWidth),
      math.min(
        originalWidth,
        math.max(160.0, constraints.maxHeight - reservedHeight - extraHeight) *
            PlayerCoverWidget.preferredAspectRatio,
      ),
    );
    final spareHeight = math.max(
      0.0,
      constraints.maxHeight -
          reservedHeight -
          width / PlayerCoverWidget.preferredAspectRatio,
    );
    // reservedHeight already includes the original 144-pixel preview.
    return (
      width: width,
      previewMaxHeight: math.max(
        playerLyricPreviewHeight(
          width: width,
          fontSize: lyricSettings.smallFontSize,
          lineHeight: lyricSettings.smallLineHeight,
          textScaler: MediaQuery.textScalerOf(context),
          lineCount: 3,
          compact: false,
        ),
        math.min(constraints.maxHeight * 0.32, 144 + spareHeight),
      ),
    );
  }

  Widget _buildCoverPane(
    BuildContext context, {
    required AudioTrack track,
    required String? coverUrl,
    required bool isWide,
    required PlayerVisualPalette previewPalette,
  }) {
    return Padding(
      key: ValueKey('cover-pane-${isWide ? 'wide' : 'compact'}'),
      padding: EdgeInsets.symmetric(horizontal: isWide ? 12 : 4),
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = math.min(
                  constraints.maxWidth * 0.90,
                  constraints.maxHeight *
                      0.84 *
                      PlayerCoverWidget.preferredAspectRatio,
                );
                final height = width / PlayerCoverWidget.preferredAspectRatio;
                return Center(
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: RepaintBoundary(
                      child: _buildPlayerCoverArtwork(
                        track: track,
                        coverUrl: coverUrl,
                        isWide: isWide,
                        previewPalette: previewPalette,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (!isWide) _buildLyricPreview(track),
        ],
      ),
    );
  }

  Widget _buildLyricPreview(
    AudioTrack track, {
    Key? key,
    int lineCount = 5,
    bool compact = false,
    double verticalPadding = 10,
  }) {
    return Consumer(
      builder: (context, ref, _) {
        final hasLyrics = ref.watch(
          lyricControllerProvider.select((state) => state.lyrics.isNotEmpty),
        );
        final preview = Padding(
          key: const ValueKey('player-lyric-preview'),
          padding: EdgeInsets.symmetric(vertical: verticalPadding),
          child: Stack(
            alignment: Alignment.center,
            fit: StackFit.passthrough,
            children: [
              if (!hasLyrics) LyricDisplay(albumName: track.displayAlbum),
              Visibility(
                key: const ValueKey('player-lyric-preview-visibility'),
                visible: hasLyrics,
                maintainState: true,
                child: ThreeLineLyricDisplay(
                  key: key,
                  onSeekRequested: (position) => ref
                      .read(audioPlayerControllerProvider.notifier)
                      .seekAndPersist(position),
                  onLineDoubleTap: _togglePlayback,
                  compact: compact,
                  lineCount: lineCount,
                  textHorizontalPadding: 16,
                ),
              ),
            ],
          ),
        );
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: hasLyrics ? null : _showLyrics,
          child: preview,
        );
      },
    );
  }

  Widget _buildControlsPane(
    BuildContext context, {
    required AudioTrack track,
    required bool isWide,
    bool shortStage = false,
    bool showTrackHeader = true,
    bool enableQueueGesture = true,
    double? horizontalPadding,
    double? additionalActionWidth,
    PlayerVerticalDragCallbacks? dismissDrag,
  }) {
    final size = MediaQuery.sizeOf(context);
    final progressTrackTopInset = !isWide && size.width <= size.height
        ? PlayerProgressSection.compactTrackTopInset
        : PlayerProgressSection.centeredTrackTopInset;
    Widget buildControls(bool compactSpacing) =>
        ValueListenableBuilder<String?>(
          valueListenable: _workProgress,
          builder: (_, progress, _) => PlayerControlsWidget(
            isLandscape: isWide,
            compactSpacing: compactSpacing,
            progressTrackTopInset: progressTrackTopInset,
            isSeekingManually: _isSeekingManually,
            seekValue: _seekValue,
            onSeekChanged: _handleSeekChanged,
            onSeekEnd: _handleSeekEnd,
            onSeekInteractionChanged: _setProgressGestureActive,
            seekingPosition: _seekingPosition,
            seekingPositionListenable: _seekPreview,
            workId: track.workId,
            currentProgress: progress,
            onMarkPressed: track.workId == null
                ? null
                : () => _showMarkDialog(
                    context,
                    track.workId!,
                    track.displayTitle,
                  ),
            onDetailPressed: track.workId == null
                ? null
                : () => _navigateToWorkDetail(context, track.workId!),
            onQueuePressed: _showQueue,
            visibleActionCount: 5,
            additionalActionWidth: additionalActionWidth,
          ),
        );
    Widget buildContent({
      int previewLineCount = 5,
      double previewMaxHeight = double.infinity,
      double previewMinHeight = 0,
      bool tightPreview = false,
      bool compactSpacing = false,
    }) => Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isWide ? 680 : double.infinity),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding ?? 12,
              vertical: isWide && !shortStage ? 18 : 0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showTrackHeader) ...[
                  Text(
                    track.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      height: 1.14,
                    ),
                  ),
                  if (track.artist case final artist?)
                    Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  SizedBox(height: isWide ? 24 : 12),
                ],
                if (isWide) ...[
                  PlayerVerticalSwipeRegion(
                    key: const ValueKey('wide-controls-lyric-preview-surface'),
                    swipeDownDrag: dismissDrag,
                    pageDragCoordinator: _widePageHandoff,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: previewMinHeight,
                        maxHeight: previewMaxHeight,
                      ),
                      child: _buildLyricPreview(
                        track,
                        key: _wideLyricPreviewKey,
                        lineCount: previewLineCount,
                        compact: previewLineCount == 3,
                        verticalPadding: tightPreview ? 0 : 10,
                      ),
                    ),
                  ),
                  SizedBox(height: tightPreview ? 0 : 12),
                ],
                buildControls(compactSpacing),
              ],
            ),
          ),
        ),
      ),
    );

    if (!isWide) {
      return KeyedSubtree(
        key: const ValueKey('controls-pane-compact'),
        child: buildContent(),
      );
    }

    // Keep the wide-screen page gesture on a dedicated, non-interactive strip.
    // The control scroller only hands a downward overscroll to the route when
    // it is already at its top, so sliders and buttons retain their gestures.
    return Column(
      key: const ValueKey('controls-pane-wide'),
      children: [
        if (enableQueueGesture)
          SizedBox(
            height: shortStage ? 24 : 72,
            width: double.infinity,
            child: PlayerVerticalSwipeRegion(
              key: const ValueKey('controls-queue-swipe-surface-wide'),
              swipeDownDrag: dismissDrag,
              pageDragCoordinator: _widePageHandoff,
              child: const SizedBox.expand(),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final lyricSettings = ref.watch(playerLyricSettingsProvider);
              final lyricPreviewWidth = math.max(
                0.0,
                math.min(680.0, constraints.maxWidth) - 24,
              );
              final lyricTextScaler = MediaQuery.textScalerOf(context);
              final timeStyle = Theme.of(context).textTheme.bodySmall;
              final timePainter = TextPainter(
                text: TextSpan(text: '00:00', style: timeStyle),
                textDirection: Directionality.of(context),
                textScaler: lyricTextScaler,
              )..layout();
              final timeLabelHeight = timePainter.height;
              timePainter.dispose();
              // Reserve every control row before expanding the lyric preview.
              final fullPreviewHeight =
                  playerLyricPreviewHeight(
                    width: lyricPreviewWidth,
                    fontSize: lyricSettings.smallFontSize,
                    lineHeight: lyricSettings.smallLineHeight,
                    textScaler: lyricTextScaler,
                    lineCount: 5,
                    compact: false,
                  ) +
                  20 +
                  12;
              final threeLinePreviewHeight = playerLyricPreviewHeight(
                width: lyricPreviewWidth,
                fontSize: lyricSettings.smallFontSize,
                lineHeight: lyricSettings.smallLineHeight,
                textScaler: lyricTextScaler,
                lineCount: 3,
                compact: true,
              );
              final preferredPreviewHeight = threeLinePreviewHeight + 20;
              final isDesktop = !Platform.isAndroid && !Platform.isIOS;
              final visibleButtons = ref
                  .watch(
                    isDesktop
                        ? playerButtonsConfigDesktopProvider
                        : playerButtonsConfigMobileProvider,
                  )
                  .getVisibleButtons(slotCount: 5);
              final hasStatusButton =
                  visibleButtons.contains(PlayerButtonType.speed) ||
                  visibleButtons.contains(PlayerButtonType.sleepTimer);
              final actionRowHeight =
                  PlayerActionSlot.buttonHeight +
                  (hasStatusButton
                      ? lyricTextScaler.scale(PlayerActionSlot.labelFontSize)
                      : 0);
              final fullControlsHeight =
                  32 + timeLabelHeight + 18 + 62 + 16 + actionRowHeight;
              final verticalPadding = shortStage ? 0.0 : 36.0;
              final compactSpacing =
                  constraints.maxHeight <
                  preferredPreviewHeight +
                      12 +
                      fullControlsHeight +
                      verticalPadding;
              final controlsHeight =
                  fullControlsHeight - (compactSpacing ? 18 + 16 : 0);
              final fiveLineContentHeight =
                  fullPreviewHeight + controlsHeight + verticalPadding;
              final previewLineCount =
                  constraints.maxHeight >= fiveLineContentHeight ? 5 : 3;
              final size = MediaQuery.sizeOf(context);
              final isLandscape = size.width > size.height;
              final hasLyrics = ref.watch(
                lyricControllerProvider.select(
                  (state) => state.lyrics.isNotEmpty,
                ),
              );
              final tightPreview =
                  isLandscape &&
                  hasLyrics &&
                  constraints.maxHeight <
                      preferredPreviewHeight +
                          12 +
                          controlsHeight +
                          verticalPadding;
              final previewBottomSpacing = tightPreview ? 0.0 : 12.0;
              final availablePreviewHeight = math.max(
                52.0,
                constraints.maxHeight -
                    controlsHeight -
                    previewBottomSpacing -
                    verticalPadding,
              );
              final previewMaxHeight = isLandscape
                  ? availablePreviewHeight
                  : math.min(availablePreviewHeight, 144.0 + 20);
              final previewMinHeight = tightPreview
                  ? math.min(previewMaxHeight, threeLinePreviewHeight)
                  : 0.0;
              return PlayerScrollEdgeActions(
                pullDownDrag: dismissDrag,
                child: KeyedSubtree(
                  key: const PageStorageKey('player-wide-controls-scroll'),
                  child: SingleChildScrollView(
                    controller: _wideControlsScrollController,
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: ClampingScrollPhysics(),
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Center(
                        child:
                            !isLandscape && hasLyrics && previewLineCount == 5
                            ? ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 680,
                                ),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: horizontalPadding ?? 12,
                                  ),
                                  child: SizedBox(
                                    height: constraints.maxHeight,
                                    child: CustomMultiChildLayout(
                                      delegate: _WidePlayerPreviewLayout(
                                        reservedPreviewHeight:
                                            playerLyricPreviewHeight(
                                              width: lyricPreviewWidth,
                                              fontSize:
                                                  lyricSettings.smallFontSize,
                                              lineHeight:
                                                  lyricSettings.smallLineHeight,
                                              textScaler: lyricTextScaler,
                                              lineCount: 5,
                                              compact: false,
                                              maxHeight: previewMaxHeight - 20,
                                            ) +
                                            20,
                                        maxPreviewHeight:
                                            fullPreviewHeight - 12,
                                        controlsGap: previewBottomSpacing,
                                      ),
                                      children: [
                                        LayoutId(
                                          id: _WidePlayerPreviewPart.preview,
                                          child: PlayerVerticalSwipeRegion(
                                            key: const ValueKey(
                                              'wide-controls-lyric-preview-surface',
                                            ),
                                            swipeDownDrag: dismissDrag,
                                            pageDragCoordinator:
                                                _widePageHandoff,
                                            child: _buildLyricPreview(
                                              track,
                                              key: _wideLyricPreviewKey,
                                            ),
                                          ),
                                        ),
                                        LayoutId(
                                          id: _WidePlayerPreviewPart.controls,
                                          child: buildControls(compactSpacing),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            : buildContent(
                                previewLineCount: previewLineCount,
                                previewMaxHeight: previewMaxHeight,
                                previewMinHeight: previewMinHeight,
                                tightPreview: tightPreview,
                                compactSpacing: compactSpacing,
                              ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _setProgressGestureActive(bool active) {
    if (_progressGestureActive.value == active) return;
    _progressGestureActive.value = active;
  }

  Widget _buildLyricsPane(
    BuildContext context, {
    required bool isWide,
    double? actionWidth,
  }) {
    return Consumer(
      key: ValueKey('lyrics-pane-${isWide ? 'wide' : 'compact'}'),
      builder: (context, ref, child) {
        final lyricState = ref.watch(lyricControllerProvider);
        return ValueListenableBuilder<int>(
          valueListenable: _semanticPageRevision,
          builder: (context, _, __) => PlayerVerticalSwipeRegion(
            key: ValueKey('lyrics-page-gesture-forwarder-$isWide'),
            pageDragCoordinator: isWide
                ? _widePageHandoff
                : _compactPageHandoff,
            child: PlayerLyricsSurface(
              isWide: isWide,
              isActive: isWide
                  ? !_isLyricLocked && _rightPane == PlayerRightPane.lyrics
                  : !_isLyricLocked &&
                        _compactPage == 2 &&
                        _rightPane != PlayerRightPane.queue,
              keepScrollActiveDuringPageDrag:
                  !_isLyricLocked &&
                  _verticalPageDragActive &&
                  (isWide ? _widePageHandoff : _compactPageHandoff)
                      .hasActiveDrag &&
                  _pageDragOrigins[isWide
                          ? _wideVerticalPageController
                          : _compactVerticalPageController] ==
                      0 &&
                  (_queueReturnState?.rightPane ?? _rightPane) ==
                      PlayerRightPane.lyrics,
              seekingPosition: _seekingPosition,
              seekingPositionListenable: _seekPreview,
              onTogglePlayback: _togglePlayback,
              onFullscreen: _enterLyricFullscreen,
              onLongPress: _enterLyricFullscreen,
              scrollController: isWide
                  ? _wideLyricsScrollController
                  : _compactLyricsScrollController,
              actionWidth: actionWidth,
              searchWidth: isWide ? null : _compactSharedWidth,
              translateButton: _buildLyricTranslateAppBarButton(context),
              onDownload: lyricState.source?.canSaveOriginal == true
                  ? () => _openCurrentLyricSource(context, lyricState.source!)
                  : null,
            ),
          ),
        );
      },
    );
  }

  Widget _buildQueuePane(BuildContext context, {required bool isWide}) {
    final directQueueOnly = _directQueueEntry && !_playerPagesActivated;
    final directQueueDismissDrag = directQueueOnly
        ? _dismissCoordinator.callbacks(context, allowDirectQueue: true)
        : null;
    return Align(
      key: const ValueKey('player-queue-pane'),
      alignment: Alignment.center,
      child: SizedBox(
        width: double.infinity,
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => ValueListenableBuilder<int>(
                  valueListenable: _semanticPageRevision,
                  builder: (context, _, __) => PlayerQueueBrowser(
                    key: _queueBrowserKey,
                    isActive:
                        _rightPane == PlayerRightPane.queue ||
                        _queueTransitionActive,
                    initialQueueHistory:
                        widget.initialQueueHistory &&
                        !_initialQueueHistorySelected,
                    onInitialHistorySelected: () {
                      _initialQueueHistorySelected = true;
                    },
                    onTrackSelected: () {},
                    onClear: _clearQueueAndClosePlayer,
                    onDismissRequested: directQueueOnly ? _dismissPlayer : null,
                    dismissDrag: directQueueDismissDrag,
                    pageDragCoordinator: directQueueOnly
                        ? null
                        : isWide
                        ? _widePageHandoff
                        : _compactPageHandoff,
                    showPageButtons: isWide,
                    horizontalPadding: 10,
                    contentWidth: isWide
                        ? constraints.maxWidth - 20
                        : math.min(
                            _compactSharedWidth! + 20,
                            constraints.maxWidth,
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Duration _motionDuration(BuildContext context) {
    return MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : _pageTransitionDuration;
  }

  bool _isMainDismissSurfaceVisible({required bool isWide}) {
    if (_directQueueEntry ||
        _queueTransitionActive ||
        _rightPane == PlayerRightPane.queue) {
      return false;
    }
    return isWide || _compactPage == 1;
  }

  PlayerDismissVisualMode get _currentPlayerDismissVisualMode {
    if (_rightPane == PlayerRightPane.queue) {
      return PlayerDismissVisualMode.secondary;
    }
    final size = MediaQuery.sizeOf(context);
    final isWide =
        _lastWasWide ?? usesWidePlayerLayout(size.width, height: size.height);
    return _isMainDismissSurfaceVisible(isWide: isWide)
        ? PlayerDismissVisualMode.main
        : PlayerDismissVisualMode.secondary;
  }

  bool _canDismissPlayer({
    required bool mainBodyOnly,
    required bool allowDirectQueue,
  }) {
    if (!mounted ||
        _isLyricLocked ||
        _queueTransitionActive ||
        (_rightPane == PlayerRightPane.queue &&
            !(allowDirectQueue && _directQueueEntry)) ||
        !ModalRoute.of(context)!.isCurrent) {
      return false;
    }
    if (mainBodyOnly &&
        _currentPlayerDismissVisualMode != PlayerDismissVisualMode.main) {
      return false;
    }
    return true;
  }

  void _dismissPlayer() {
    _dismissCoordinator.syncVisualMode(context);
    _releaseTextInputFocus();
    Navigator.of(context).pop();
  }

  void _commitSemanticPage(VoidCallback update) {
    update();
    if (!_playerPagesActivated && _rightPane != PlayerRightPane.queue) {
      setState(() => _playerPagesActivated = true);
    }
    _semanticPageRevision.value++;
    _dismissCoordinator.syncVisualMode(context);
  }

  void _onCompactPageChanged(int index) {
    if (_rightPane == PlayerRightPane.queue ||
        _queueTransitionActive ||
        index == _compactPage) {
      return;
    }
    _commitSemanticPage(() {
      _compactPage = index;
      _rightPane = _rightPaneForPage(index);
    });
  }

  void _onWideRightPageChanged(int index) {
    final pane = _rightPaneForPage(index);
    if (_rightPane == PlayerRightPane.queue || _rightPane == pane) return;
    _commitSemanticPage(() {
      _rightPane = pane;
      _compactPage = _pageForRightPane(pane);
    });
  }

  void _onCompactVerticalPageChanged(int index) {
    if (_directQueueEntry) return;
    if (index == 1 && _rightPane != PlayerRightPane.queue) {
      _captureQueueOrigin();
      _commitSemanticPage(() {
        _queueHasBeenOpened = true;
        _rightPane = PlayerRightPane.queue;
      });
    } else if (index == 0 && _rightPane == PlayerRightPane.queue) {
      _restoreQueueState();
    }
  }

  void _onWideVerticalPageChanged(int index) {
    if (_directQueueEntry) return;
    if (index == 1 && _rightPane != PlayerRightPane.queue) {
      _captureQueueOrigin();
      _commitSemanticPage(() {
        _queueHasBeenOpened = true;
        _rightPane = PlayerRightPane.queue;
      });
    } else if (index == 0 && _rightPane == PlayerRightPane.queue) {
      _restoreQueueState();
    }
  }

  Future<void> _showCoverPreview(
    AudioTrack track,
    String coverUrl,
    PlayerVisualPalette palette,
  ) async {
    if (_coverPreviewHeroTrackId.value != null) return;
    _coverPreviewHeroTrackId.value = track.id;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final localPath = LocalFileUrl.pathFromUrl(coverUrl);
    try {
      await CoverPreviewDialog.show(
        context,
        imageUrl: localPath == null ? coverUrl : null,
        localPath: localPath,
        identifier: track.workId?.toString() ?? track.hash ?? track.id,
        heroTag: playerCoverPreviewHeroTag(track.id),
        cacheKey: track.workId != null
            ? 'work_cover_${track.workId}'
            : track.hash ?? coverUrl,
        isJapaneseAsmr: track.workId != null && track.workId! < 0,
        backgroundPalette: palette,
      );
    } finally {
      if (mounted && _coverPreviewHeroTrackId.value == track.id) {
        _coverPreviewHeroTrackId.value = null;
      }
    }
  }

  void _showLyrics() {
    _commitSemanticPage(() {
      _rightPane = PlayerRightPane.lyrics;
      _compactPage = 2;
    });
    _animateSemanticPage(
      wideController: _wideRightPageController,
      widePage: 2,
      compactPage: 2,
    );
  }

  void _animateSemanticPage({
    required PageController wideController,
    required int widePage,
    required int compactPage,
  }) {
    final size = MediaQuery.sizeOf(context);
    final controller =
        (_lastWasWide ?? usesWidePlayerLayout(size.width, height: size.height))
        ? wideController
        : _compactPageController;
    final page = identical(controller, _compactPageController)
        ? compactPage
        : widePage;
    _requestedPageTargets[controller] = page;
    final request = ++_semanticTransitionGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _semanticTransitionGeneration) return;
      if (!controller.hasClients || controller.positions.length != 1) return;
      final currentPage = controller.page;
      if (currentPage != null && (currentPage - page).abs() < 0.001) {
        if (_requestedPageTargets[controller] == page) {
          _requestedPageTargets.remove(controller);
        }
        return;
      }
      final duration = _motionDuration(context);
      if (duration == Duration.zero) {
        controller.jumpToPage(page);
        if (_requestedPageTargets[controller] == page) {
          _requestedPageTargets.remove(controller);
        }
        return;
      }
      unawaited(() async {
        try {
          await controller.animateToPage(
            page,
            duration: duration,
            curve: _pageTransitionCurve,
          );
        } catch (_) {
          // A newer page request or responsive layout change can detach it.
        } finally {
          if (_requestedPageTargets[controller] == page) {
            _requestedPageTargets.remove(controller);
          }
        }
      }());
    });
  }

  void _showQueue() {
    if (_directQueueEntry || _rightPane == PlayerRightPane.queue) return;
    _semanticTransitionGeneration++;
    _captureQueueOrigin();
    final mountQueue = !_queueHasBeenOpened;
    _commitSemanticPage(() {
      _queueHasBeenOpened = true;
      _rightPane = PlayerRightPane.queue;
      _queueTransitionActive = true;
    });
    if (mountQueue) setState(() {});
    _animateQueuePageTo(1);
  }

  void _prepareQueueForPageDrag() {
    if (_directQueueEntry) return;
    _releaseTextInputFocus();
    final activatePlayer = !_playerPagesActivated;
    final mountQueue = !_queueHasBeenOpened;
    _captureQueueOrigin();
    if (activatePlayer || mountQueue) {
      setState(() {
        _playerPagesActivated = true;
        _queueHasBeenOpened = true;
      });
    }
  }

  PageController get _activeVerticalPageController => _lastWasWide == true
      ? _wideVerticalPageController
      : _compactVerticalPageController;

  void _animateQueuePageTo(int page) {
    final controller = _activeVerticalPageController;
    final request = ++_semanticTransitionGeneration;
    _requestedPageTargets[controller] = page;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _semanticTransitionGeneration) return;
      if (!controller.hasClients || controller.positions.length != 1) {
        return;
      }
      final currentPage = controller.page;
      if (currentPage != null && (currentPage - page).abs() < 0.001) {
        if (_requestedPageTargets[controller] == page) {
          _requestedPageTargets.remove(controller);
        }
        if (_queueTransitionActive && !_verticalPageDragActive) {
          _commitSemanticPage(() => _queueTransitionActive = false);
        }
        return;
      }
      final duration = _motionDuration(context);
      if (duration == Duration.zero) {
        controller.jumpToPage(page);
        if (_requestedPageTargets[controller] == page) {
          _requestedPageTargets.remove(controller);
        }
        if (_queueTransitionActive && !_verticalPageDragActive) {
          _commitSemanticPage(() => _queueTransitionActive = false);
        }
        return;
      }
      unawaited(() async {
        try {
          await controller.animateToPage(
            page,
            duration: duration,
            curve: _pageTransitionCurve,
          );
        } catch (_) {
          // A viewport change or a new gesture can cancel this motion.
        } finally {
          if (mounted && request == _semanticTransitionGeneration) {
            if (_requestedPageTargets[controller] == page) {
              _requestedPageTargets.remove(controller);
            }
            if (_queueTransitionActive &&
                !_verticalPageDragActive &&
                _requestedPageTargets.isEmpty) {
              _commitSemanticPage(() => _queueTransitionActive = false);
            }
          }
        }
      }());
    });
  }

  void _captureQueueOrigin() {
    if (_rightPane == PlayerRightPane.queue) return;
    _queueReturnState = _PlayerQueueReturnState(rightPane: _rightPane);
  }

  void _closeQueue() {
    if (_directQueueEntry) {
      _dismissPlayer();
      return;
    }
    if (_rightPane != PlayerRightPane.queue) return;
    _semanticTransitionGeneration++;
    _commitSemanticPage(() => _queueTransitionActive = true);
    _animateQueuePageTo(0);
  }

  void _restoreQueueState() {
    if (_rightPane != PlayerRightPane.queue && _queueReturnState == null) {
      return;
    }
    _commitSemanticPage(_restoreQueueSemanticFields);
    final restoredRight = _rightPane;
    final compactPage = _compactPage;
    _dismissCoordinator.scheduleVisualModeSync(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = MediaQuery.sizeOf(context);
      if ((_lastWasWide ??
          usesWidePlayerLayout(size.width, height: size.height))) {
        if (_wideRightPageController.hasClients) {
          _wideRightPageController.jumpToPage(_pageForRightPane(restoredRight));
        }
      } else if (_compactPageController.hasClients) {
        _compactPageController.jumpToPage(compactPage);
      }
    });
  }

  Future<void> _clearQueueAndClosePlayer() async {
    if (!await confirmClearPlaybackQueue(context)) return;
    try {
      await ref
          .read(audioPlayerControllerProvider.notifier)
          .clearQueueAndStop();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      SnackBarUtil.showError(context, error.toString());
    }
  }

  void _handleBack() {
    if (_isLyricLocked) {
      _exitLyricFullscreen();
      return;
    }
    if (_rightPane == PlayerRightPane.queue) {
      if (_directQueueEntry) {
        _dismissPlayer();
        return;
      }
      _closeQueue();
      return;
    }
    _dismissPlayer();
  }

  Future<void> _showMoreSheet(BuildContext context, AudioTrack track) async {
    _releaseTextInputFocus();
    try {
      await showResponsiveBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => ValueListenableBuilder<String?>(
          valueListenable: _workProgress,
          builder: (_, progress, _) => PlayerInfoPanel(
            track: track,
            currentProgress: progress,
            onMarkPressed: track.workId == null
                ? null
                : () => _showMarkDialog(
                    context,
                    track.workId!,
                    track.displayTitle,
                  ),
            onDetailPressed: track.workId == null
                ? null
                : () {
                    Navigator.of(sheetContext).pop();
                    _navigateToWorkDetail(context, track.workId!);
                  },
            onQueuePressed: () {
              Navigator.of(sheetContext).pop();
              _showQueue();
            },
            onImmersiveLyrics: () {
              Navigator.of(sheetContext).pop();
              _enterLyricFullscreen();
            },
            onLyricSettings: () {
              Navigator.of(sheetContext).pop();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) showPlayerLyricSettingsSheet(context);
              });
            },
            visibleActionCount: 5,
          ),
        ),
      );
    } finally {
      if (mounted) {
        _releaseTextInputFocus();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _releaseTextInputFocus();
        });
      }
    }
  }

  void _releaseTextInputFocus() {
    FocusManager.instance.primaryFocus?.unfocus(
      disposition: UnfocusDisposition.scope,
    );
    if (_keyboardFocusNode.canRequestFocus) {
      _keyboardFocusNode.requestFocus();
    }
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  Future<void> _openTrackWorkDetails(
    BuildContext context,
    AudioTrack track,
  ) async {
    final workId = track.workId;
    if (workId == null || _openingWorkDetail) return;
    _openingWorkDetail = true;
    try {
      if (_dismissPlayerForVisibleWork(context, workId)) return;
      _releaseTextInputFocus();
      PlayerWorkDetailsData? details = ref
          .read(playerWorkDetailsProvider)
          .valueOrNull;
      if (details?.work.id != workId) {
        try {
          details = await ref.read(playerWorkDetailsProvider.future);
        } catch (_) {
          details = null;
        }
      }
      if (!mounted || !context.mounted) return;
      if (details != null && details.work.id == workId) {
        await _openKnownWork(details.work);
      } else {
        await _navigateToWorkDetail(context, workId);
      }
    } finally {
      _openingWorkDetail = false;
    }
  }

  Future<void> _openKnownWork(Work work) async {
    if (_dismissPlayerForVisibleWork(context, work.id)) return;
    final initialCover = _initialWorkDetailCover(work);
    Widget builder(BuildContext context) =>
        WorkDetailScreen(work: work, initialCoverImageProvider: initialCover);
    await pushAudioPlayerHandoffRoute(context, builder: builder);
  }

  bool _dismissPlayerForVisibleWork(BuildContext context, int workId) {
    if (AppNavigationScope.maybeOf(
          context,
        )?.isAudioPlayerDirectlyAboveWork(workId) !=
        true) {
      return false;
    }
    Navigator.of(context).pop();
    return true;
  }

  ImageProvider<Object>? _initialWorkDetailCover(Work work) {
    final track = ref.read(currentTrackProvider).valueOrNull;
    if (track == null || track.workId != work.id) return null;
    final url = _buildWorkCoverUrl(track.workId, track.artworkUrl);
    if (url == null) return null;
    final ImageProvider<Object> provider = LocalFileUrl.isLocalFileUrl(url)
        ? FileImage(File(LocalFileUrl.pathFromUrl(url) ?? url))
        : CachedNetworkImageProvider(url, cacheKey: 'work_cover_${work.id}');
    return PaintingBinding.instance.imageCache.statusForKey(provider).tracked
        ? provider
        : null;
  }

  void _openCurrentLyricSource(
    BuildContext context,
    LyricSourceDescriptor source,
  ) {
    final sourceUrl = source.localPath?.isNotEmpty == true
        ? LocalFileUrl.fromPath(source.localPath!)
        : source.url;
    if (sourceUrl == null || sourceUrl.isEmpty) {
      SnackBarUtil.showInfo(context, S.of(context).noContentToSave);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => TextPreviewScreen(
          textUrl: sourceUrl,
          title: source.title,
          workId: source.workId,
          hash: source.hash,
          showSaveOptionsOnLoad: true,
        ),
      ),
    );
  }

  // ignore: unused_element
  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    SystemUiOverlayStyle systemOverlayStyle,
    AsyncValue currentTrack,
  ) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: systemOverlayStyle,
      leading: Padding(
        padding: const EdgeInsets.only(left: 8.0),
        child: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      actions: [
        Consumer(
          builder: (context, ref, child) {
            final lyricState = ref.watch(lyricControllerProvider);
            if (lyricState.lyrics.isEmpty || lyricState.isLoading) {
              return const SizedBox.shrink();
            }

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  onPressed: _enterLyricFullscreen,
                  tooltip: S.of(context).fullscreenLyrics,
                ),
                _buildLyricTranslateAppBarButton(context),
              ],
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8.0),
          child: IconButton(
            icon: const Icon(Icons.queue_music),
            onPressed: () => PlaylistDialog.show(context),
            tooltip: S.of(context).playlistTitle,
          ),
        ),
      ],
      automaticallyImplyLeading: false,
    );
  }

  // ignore: unused_element
  Widget _buildPortraitLayout(
    BuildContext context,
    AsyncValue currentTrack,
    bool isTrackLoading,
  ) {
    return Stack(
      children: [
        currentTrack.when(
          data: (track) {
            if (track == null) {
              return Center(child: Text(S.of(context).noAudioPlaying));
            }

            // 加载进度信息
            _scheduleProgressLoad(track);

            final workCoverUrl = _buildWorkCoverUrl(
              track.workId,
              track.artworkUrl,
            );

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                children: [
                  if (_showLyricView)
                    Expanded(child: _buildPortraitLyricView())
                  else ...[
                    Flexible(
                      child: Consumer(
                        builder: (context, ref, child) {
                          final lyricState = ref.watch(lyricControllerProvider);
                          final hasLyrics = lyricState.lyrics.isNotEmpty;

                          return PlayerCoverWidget(
                            track: track,
                            workCoverUrl: workCoverUrl,
                            onTap: hasLyrics
                                ? () {
                                    setState(() {
                                      _showLyricView = true;
                                    });
                                  }
                                : null,
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    Consumer(
                      builder: (context, ref, child) {
                        final lyricState = ref.watch(lyricControllerProvider);
                        final hasLyrics = lyricState.lyrics.isNotEmpty;

                        return GestureDetector(
                          onTap: hasLyrics
                              ? () {
                                  setState(() {
                                    _showLyricView = true;
                                  });
                                }
                              : null,
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  track.displayTitle,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                  textAlign: TextAlign.center,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                if (track.artist != null)
                                  Text(
                                    track.artist!,
                                    style: Theme.of(context).textTheme.bodyLarge
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                LyricDisplay(albumName: track.displayAlbum),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 4),
                  ],
                  ValueListenableBuilder<String?>(
                    valueListenable: _workProgress,
                    builder: (_, progress, _) => PlayerControlsWidget(
                      isLandscape: false,
                      isSeekingManually: _isSeekingManually,
                      seekValue: _seekValue,
                      onSeekChanged: _handleSeekChanged,
                      onSeekEnd: _handleSeekEnd,
                      seekingPosition: _seekingPosition,
                      seekingPositionListenable: _seekPreview,
                      workId: track.workId,
                      currentProgress: progress,
                      onMarkPressed: track.workId != null
                          ? () => _showMarkDialog(
                              context,
                              track.workId!,
                              track.displayTitle,
                            )
                          : null,
                      onDetailPressed: track.workId != null
                          ? () => _navigateToWorkDetail(context, track.workId!)
                          : null,
                    ),
                  ),
                ],
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(
            child: Text(S.of(context).errorWithMessage(error.toString())),
          ),
        ),
        if (isTrackLoading) _buildTrackLoadingOverlay(context),
      ],
    );
  }

  // ignore: unused_element
  Widget _buildLandscapeLayout(
    BuildContext context,
    AsyncValue currentTrack,
    bool isTrackLoading,
  ) {
    final content = currentTrack.when(
      data: (track) {
        if (track == null) {
          return Center(child: Text(S.of(context).noAudioPlaying));
        }

        // 加载进度信息
        _scheduleProgressLoad(track);

        final workCoverUrl = _buildWorkCoverUrl(track.workId, track.artworkUrl);

        return Row(
          children: [
            // 左侧：封面和控制
            Expanded(
              flex: 2,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 计算所有固定元素的高度
                  const double padding = 32.0; // 上下padding 16 * 2
                  const double titleHeight = 60.0; // 标题预估高度（2行）
                  const double artistHeight = 20.0; // 艺术家名称高度
                  const double controlsHeight = 200.0; // 控制组件预估高度

                  // 计算封面之间和控制组件之间需要的间距
                  const double minSpacing1 = 12.0; // 封面到标题最小间距
                  const double minSpacing2 = 6.0; // 标题到艺术家最小间距
                  const double minSpacing3 = 12.0; // 艺术家到控制器最小间距
                  const double minTotalSpacing =
                      minSpacing1 + minSpacing2 + minSpacing3;

                  // 固定元素总高度
                  final fixedHeight =
                      padding +
                      titleHeight +
                      (track.artist != null ? artistHeight : 0.0) +
                      controlsHeight +
                      minTotalSpacing;

                  // 可用于封面的高度
                  final availableForCover = constraints.maxHeight - fixedHeight;

                  // 封面最大高度限制
                  final maxCoverHeight = constraints.maxHeight * 0.6;
                  final coverHeight = availableForCover.clamp(
                    120.0,
                    maxCoverHeight,
                  );

                  // 计算剩余可分配的空间
                  final usedHeight =
                      padding +
                      coverHeight +
                      titleHeight +
                      (track.artist != null ? artistHeight : 0.0) +
                      controlsHeight +
                      minTotalSpacing;
                  final extraSpace = (constraints.maxHeight - usedHeight).clamp(
                    0.0,
                    double.infinity,
                  );

                  // 将额外空间分配到间距上
                  final spacing1 = minSpacing1 + (extraSpace * 0.4);
                  final spacing2 = minSpacing2 + (extraSpace * 0.1);
                  final spacing3 = minSpacing3 + (extraSpace * 0.5);

                  // 判断是否需要滚动
                  final needsScroll = usedHeight > constraints.maxHeight;

                  final content = Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisAlignment: needsScroll
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      children: [
                        // 封面
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: coverHeight,
                            maxWidth: constraints.maxWidth - 32,
                          ),
                          child: PlayerCoverWidget(
                            track: track,
                            workCoverUrl: workCoverUrl,
                            isLandscape: true,
                          ),
                        ),
                        SizedBox(height: spacing1),
                        // 标题
                        Text(
                          track.displayTitle,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (track.artist != null) ...[
                          SizedBox(height: spacing2),
                          Text(
                            track.artist!,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        SizedBox(height: spacing3),
                        // 控制组件
                        ValueListenableBuilder<String?>(
                          valueListenable: _workProgress,
                          builder: (context, progress, _) =>
                              PlayerControlsWidget(
                                isLandscape: true,
                                isSeekingManually: _isSeekingManually,
                                seekValue: _seekValue,
                                onSeekChanged: _handleSeekChanged,
                                onSeekEnd: _handleSeekEnd,
                                seekingPosition: _seekingPosition,
                                seekingPositionListenable: _seekPreview,
                                workId: track.workId,
                                currentProgress: progress,
                                onMarkPressed: track.workId != null
                                    ? () => _showMarkDialog(
                                        context,
                                        track.workId!,
                                        track.displayTitle,
                                      )
                                    : null,
                                onDetailPressed: track.workId != null
                                    ? () => _navigateToWorkDetail(
                                        context,
                                        track.workId!,
                                      )
                                    : null,
                              ),
                        ),
                      ],
                    ),
                  );

                  // 根据是否需要滚动返回不同的widget
                  return needsScroll
                      ? SingleChildScrollView(child: content)
                      : content;
                },
              ),
            ),
            const VerticalDivider(width: 1, thickness: 1),
            // 右侧：字幕
            Expanded(
              flex: 3,
              child: Consumer(
                builder: (context, ref, child) {
                  final lyricState = ref.watch(lyricControllerProvider);
                  final hasLyrics = lyricState.lyrics.isNotEmpty;

                  if (!hasLyrics) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.lyrics_outlined,
                            size: 64,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            S.of(context).noSubtitlesAvailable,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    );
                  }

                  return Stack(
                    children: [
                      FullLyricDisplay(
                        seekingPosition: _seekingPosition,
                        seekingPositionListenable: _seekPreview,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) =>
          Center(child: Text(S.of(context).errorWithMessage(error.toString()))),
    );
    return _buildTrackLoadingState(
      context: context,
      isLoading: isTrackLoading,
      child: content,
    );
  }

  Widget _buildTrackLoadingState({
    required BuildContext context,
    required Widget child,
    required bool isLoading,
  }) {
    if (!isLoading) return child;
    return Stack(children: [child, _buildTrackLoadingOverlay(context)]);
  }

  bool _shouldShowTrackLoadingSpinner() {
    final size = MediaQuery.sizeOf(context);
    final isWide =
        _lastWasWide ?? usesWidePlayerLayout(size.width, height: size.height);
    return _isPlayerCoverVisible(isWide: isWide);
  }

  bool _isPlayerCoverVisible({required bool isWide}) {
    if (isWide) return true;
    return !_queueTransitionActive &&
        _rightPane != PlayerRightPane.queue &&
        _compactPage == 1;
  }

  Widget _buildTrackLoadingOverlay(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final showSpinner = _shouldShowTrackLoadingSpinner();
    return Positioned.fill(
      child: IgnorePointer(
        key: const ValueKey('player-track-loading-absorber'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showSpinner)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: CompositedTransformFollower(
                    key: const ValueKey('player-track-loading-spinner-anchor'),
                    link: _coverLoadingLayerLink,
                    showWhenUnlinked: false,
                    targetAnchor: Alignment.center,
                    followerAnchor: Alignment.center,
                    child: SizedBox(
                      key: const ValueKey('player-track-loading-spinner'),
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortraitLyricView() {
    final theme = Theme.of(context);

    // 全屏锁定模式
    if (_isLyricLocked) {
      return GestureDetector(
        onTap: _handleLockedTap,
        onLongPress: _handleLockedTap,
        child: Stack(
          children: [
            FullLyricDisplay(
              seekingPosition: _seekingPosition,
              seekingPositionListenable: _seekPreview,
              isPortrait: true,
              isLocked: true,
            ),
            // 解锁按钮
            if (_showUnlockButton)
              Positioned(
                top: MediaQuery.of(context).padding.top + 16,
                left: 0,
                right: 0,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _showUnlockButton ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _exitLyricFullscreen,
                          borderRadius: BorderRadius.circular(24),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.lock_open,
                                  size: 20,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  S.of(context).unlock,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    // 正常模式
    return Stack(
      children: [
        FullLyricDisplay(
          seekingPosition: _seekingPosition,
          seekingPositionListenable: _seekPreview,
          isPortrait: true,
          onLongPress: _enterLyricFullscreen,
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            onPressed: () {
              setState(() {
                _showLyricView = false;
              });
            },
            tooltip: S.of(context).backToCover,
            child: const Icon(Icons.album),
          ),
        ),
      ],
    );
  }

  Widget _buildLyricTranslateAppBarButton(BuildContext context) {
    return Consumer(
      builder: (context, ref, child) {
        final lyricState = ref.watch(lyricControllerProvider);

        if (lyricState.lyrics.isEmpty || lyricState.isLoading) {
          return IconButton(
            onPressed: null,
            tooltip: S.of(context).translateLyrics,
            icon: const Icon(Icons.translate),
          );
        }

        final isTranslating = lyricState.isTranslating;
        final isTranslated = lyricState.isTranslated;
        final showTranslated = lyricState.showTranslated;
        final total = lyricState.translationTotal;
        final completed = total > 0
            ? lyricState.translatedCount.clamp(0, total).toInt()
            : 0;
        final progressValue = total > 0 ? completed / total : null;
        final progressLabel = total > 0 ? '$completed/$total' : null;

        final String tooltip;
        if (isTranslating) {
          tooltip = total > 0
              ? S.of(context).translatingProgress(completed, total)
              : S.of(context).translatingLyrics;
        } else if (isTranslated && showTranslated) {
          tooltip = S.of(context).showOriginalLyrics;
        } else if (isTranslated && !showTranslated) {
          tooltip = S.of(context).showTranslatedLyrics;
        } else {
          tooltip = S.of(context).translateLyrics;
        }

        return IconButton(
          onPressed: isTranslating
              ? null
              : () async {
                  try {
                    final controller = ref.read(
                      lyricControllerProvider.notifier,
                    );

                    if (isTranslated) {
                      await controller.toggleTranslation();
                      return;
                    }

                    final confirmed = await confirmLyricTranslationIfNeeded(
                      context,
                    );
                    if (!confirmed) return;

                    final savedPath = await controller
                        .translateAndSaveCurrentLyrics();
                    if (context.mounted) {
                      SnackBarUtil.showInfo(
                        context,
                        savedPath != null
                            ? S.of(context).savedToSubtitleLibrary
                            : S.of(context).translatedLyricsNotSaved,
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      SnackBarUtil.showError(
                        context,
                        S.of(context).lyricTranslationFailed,
                      );
                    }
                  }
                },
          tooltip: tooltip,
          icon: isTranslating
              ? SizedBox(
                  width: 32,
                  height: 32,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: progressValue?.toDouble(),
                        ),
                      ),
                      if (progressLabel != null)
                        SizedBox(
                          width: 24,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              progressLabel,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    fontSize: 8,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                        ),
                    ],
                  ),
                )
              : Icon(
                  Icons.translate,
                  color: (isTranslated && showTranslated)
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
        );
      },
    );
  }

  Future<void> _showMarkDialog(
    BuildContext context,
    int workId,
    String? workTitle,
  ) async {
    final manager = WorkBookmarkManager(ref: ref, context: context);

    await manager.showMarkDialog(
      workId: workId,
      currentProgress: _currentProgress,
      currentRating: _currentRating,
      workTitle: workTitle,
      onChanged: (newProgress, newRating) {
        if (mounted && _currentWorkId == workId) {
          _currentRating = newRating;
          _workProgress.value = newProgress;
          _onlineWorkProgress = newProgress;
        }
      },
    );
  }

  Future<void> _navigateToWorkDetail(BuildContext context, int workId) async {
    if (_dismissPlayerForVisibleWork(context, workId)) return;
    try {
      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              const Center(child: CircularProgressIndicator()),
        );
      }

      final apiService = ref.read(kikoeruApiServiceProvider);
      final workData = await apiService.getWork(workId);
      final work = Work.fromJson(workData);

      if (context.mounted) {
        Navigator.of(context).pop();

        unawaited(_openKnownWork(work));
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop();

        SnackBarUtil.showError(
          context,
          S.of(context).loadFailedWithError(e.toString()),
        );
      }
    }
  }
}

class _PlayerTrackTitleSwitcher extends StatefulWidget {
  const _PlayerTrackTitleSwitcher({
    required this.track,
    required this.isWide,
    required this.allowAnimation,
    required this.direction,
    required this.presentationRevision,
    required this.onOpenWorkDetails,
  });

  static const duration = Duration(milliseconds: 500);

  final AudioTrack track;
  final bool isWide;
  final bool allowAnimation;
  final PlayerTrackChangeDirection direction;
  final int? presentationRevision;
  final ValueChanged<AudioTrack> onOpenWorkDetails;

  @override
  State<_PlayerTrackTitleSwitcher> createState() =>
      _PlayerTrackTitleSwitcherState();
}

class _PlayerTrackTitleSwitcherState extends State<_PlayerTrackTitleSwitcher>
    with TickerProviderStateMixin {
  late final PlayerTrackLayers<AudioTrack> _presentation;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _presentation = PlayerTrackLayers<AudioTrack>(
      vsync: this,
      initialValue: widget.track,
      sameContent: (a, b) => a.id == b.id,
      kind: PlayerTrackVisualKind.title,
      duration: _PlayerTrackTitleSwitcher.duration,
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
      _presentation.showImmediately(widget.track);
    }
    _reduceMotion = reduceMotion;
  }

  @override
  void didUpdateWidget(covariant _PlayerTrackTitleSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.allowAnimation ||
        _reduceMotion ||
        widget.direction == PlayerTrackChangeDirection.none) {
      _presentation.showImmediately(widget.track);
    } else if (oldWidget.track != widget.track ||
        oldWidget.presentationRevision != widget.presentationRevision) {
      _presentation.present(
        widget.track,
        direction: widget.direction == PlayerTrackChangeDirection.previous
            ? -1
            : 1,
      );
    }
  }

  @override
  void dispose() {
    _presentation
      ..removeListener(_layersChanged)
      ..dispose();
    super.dispose();
  }

  Widget _buildTrackContent(
    BuildContext context,
    AudioTrack track, {
    required bool interactive,
  }) {
    final artist = track.artist;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          track.displayTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontSize: widget.isWide ? 22 : 20,
            fontWeight: FontWeight.w700,
            height: 1.12,
          ),
        ),
        if (artist != null) ...[
          if (!widget.isWide) const SizedBox(height: 2),
          Text(
            artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontSize: widget.isWide ? null : 14,
              height: widget.isWide ? null : 1.15,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    final keyedContent = KeyedSubtree(
      key: ValueKey('player-track-title-content-${track.id}'),
      child: content,
    );
    if (!interactive || track.workId == null) return keyedContent;
    return Semantics(
      button: true,
      label: '${track.displayTitle}, ${S.of(context).viewDetail}',
      child: InkWell(
        key: ValueKey(
          widget.isWide
              ? 'player-track-title-button-wide'
              : 'player-track-title-button',
        ),
        borderRadius: BorderRadius.circular(8),
        onTap: () => widget.onOpenWorkDetails(track),
        child: keyedContent,
      ),
    );
  }

  double _viewportHeight(BuildContext context) {
    final scale = (MediaQuery.textScalerOf(context).scale(16) / 16).clamp(
      1.0,
      2.0,
    );
    return (widget.isWide ? 72.0 : 64.0) * scale;
  }

  @override
  Widget build(BuildContext context) {
    final layers = _presentation.layers;
    return SizedBox(
      height: _viewportHeight(context),
      child: ClipRect(
        key: ValueKey(
          'player-track-title-viewport-${widget.isWide ? 'wide' : 'compact'}',
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!_presentation.isTransitioning) {
              return _buildTrackContent(
                context,
                layers.single.value,
                interactive: true,
              );
            }
            final outgoing = layers.where((layer) => layer.exiting).firstOrNull;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                for (final layer in layers)
                  KeyedSubtree(
                    key: ValueKey('player-title-layer-${layer.token}'),
                    child: _buildTitleLayer(
                      context,
                      layer,
                      constraints.maxWidth,
                      identical(layer, outgoing),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTitleLayer(
    BuildContext context,
    PlayerTrackLayer<AudioTrack> layer,
    double width,
    bool primaryOutgoing,
  ) {
    final role = layer.exiting
        ? (primaryOutgoing ? 'outgoing' : 'outgoing-${layer.token}')
        : 'incoming';
    final interactive = layer.value.id == widget.track.id && !layer.exiting;
    Widget content = SlideTransition(
      key: ValueKey('player-track-title-$role'),
      position: layer.offset,
      child: RepaintBoundary(
        key: ValueKey('player-track-title-$role-layer'),
        child: ExcludeSemantics(
          excluding: !interactive,
          child: ExcludeFocus(
            excluding: !interactive,
            child: IgnorePointer(
              ignoring: !interactive,
              child: SizedBox(
                width: width,
                child: _buildTrackContent(
                  context,
                  layer.value,
                  interactive: interactive,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (layer.fades) {
      content = FadeTransition(opacity: layer.opacity, child: content);
    }
    return content;
  }
}

enum _WidePlayerPreviewPart { preview, controls }

class _WidePlayerPreviewLayout extends MultiChildLayoutDelegate {
  _WidePlayerPreviewLayout({
    required this.reservedPreviewHeight,
    required this.maxPreviewHeight,
    required this.controlsGap,
  });

  final double reservedPreviewHeight;
  final double maxPreviewHeight;
  final double controlsGap;

  @override
  void performLayout(Size size) {
    final controls = layoutChild(
      _WidePlayerPreviewPart.controls,
      BoxConstraints.tightFor(width: size.width),
    );
    // Keep the original centered controls while the preview expands upward.
    final controlsTop =
        (size.height + reservedPreviewHeight + controlsGap - controls.height) /
        2;
    positionChild(_WidePlayerPreviewPart.controls, Offset(0, controlsTop));
    final previewBottom = controlsTop - controlsGap;
    final preview = layoutChild(
      _WidePlayerPreviewPart.preview,
      BoxConstraints.tightFor(
        width: size.width,
        height: math.min(maxPreviewHeight, math.max(0.0, previewBottom)),
      ),
    );
    positionChild(
      _WidePlayerPreviewPart.preview,
      Offset(0, previewBottom - preview.height),
    );
  }

  @override
  bool shouldRelayout(covariant _WidePlayerPreviewLayout oldDelegate) =>
      reservedPreviewHeight != oldDelegate.reservedPreviewHeight ||
      maxPreviewHeight != oldDelegate.maxPreviewHeight ||
      controlsGap != oldDelegate.controlsGap;
}

class _PlayerPageBoundary extends StatefulWidget {
  const _PlayerPageBoundary({
    super.key,
    required this.child,
    this.pageController,
    this.pageIndex = 0,
  });

  final Widget child;
  final PageController? pageController;
  final int pageIndex;

  @override
  State<_PlayerPageBoundary> createState() => _PlayerPageBoundaryState();
}

class _PlayerPageBoundaryState extends State<_PlayerPageBoundary>
    with AutomaticKeepAliveClientMixin<_PlayerPageBoundary> {
  bool _visible = true;

  bool get _pageIsVisible {
    final controller = widget.pageController;
    if (controller == null) return true;
    final page =
        controller.hasClients && controller.position.hasContentDimensions
        ? controller.page ?? controller.initialPage.toDouble()
        : controller.initialPage.toDouble();
    // Both pages keep their animations throughout a drag or page transition.
    return widget.pageIndex == page.floor() || widget.pageIndex == page.ceil();
  }

  @override
  void initState() {
    super.initState();
    _visible = _pageIsVisible;
    widget.pageController?.addListener(_updateVisibility);
  }

  @override
  void didUpdateWidget(covariant _PlayerPageBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageController != widget.pageController) {
      oldWidget.pageController?.removeListener(_updateVisibility);
      widget.pageController?.addListener(_updateVisibility);
    }
    _visible = _pageIsVisible;
  }

  void _updateVisibility() {
    final visible = _pageIsVisible;
    if (_visible != visible) setState(() => _visible = visible);
  }

  @override
  void dispose() {
    widget.pageController?.removeListener(_updateVisibility);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TickerMode(enabled: _visible, child: widget.child);
  }
}

Widget _withEarlierPlayerPageGestureStart(BuildContext context, Widget child) {
  final mediaQuery = MediaQuery.of(context);
  final touchSlop = mediaQuery.gestureSettings.touchSlop ?? kTouchSlop;
  // Gesture overrides must retain the padding already consumed by SafeArea.
  return Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        gestureSettings: DeviceGestureSettings(touchSlop: touchSlop * 0.85),
      ),
      child: child,
    ),
  );
}

Widget _withOriginalPlayerGestureSettings(BuildContext context, Widget child) {
  final gestureSettings = MediaQuery.gestureSettingsOf(context);
  return Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(gestureSettings: gestureSettings),
      child: child,
    ),
  );
}

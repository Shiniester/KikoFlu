import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/work.dart';
import '../models/audio_track.dart';
import '../providers/artwork_theme_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/lyric_provider.dart';
import '../providers/player_work_details_provider.dart';
import '../services/audio_player_service.dart';
import '../utils/local_file_url.dart';
import '../utils/snackbar_util.dart';
import '../utils/system_ui_style.dart';
import '../widgets/player/player_cover_widget.dart';
import '../widgets/player/player_track_layers.dart';
import '../widgets/player/player_controls_widget.dart';
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
import '../widgets/app_bottom_dock_transition.dart';
import '../widgets/cover_preview_dialog.dart';
import 'work_detail_screen.dart';
import '../../l10n/app_localizations.dart';

/// 音频播放器主屏幕
enum PlayerLeftPane { cover, information }

enum PlayerRightPane { controls, lyrics, queue }

enum PlayerOperatedRegion { left, right }

@immutable
class _PlayerQueueReturnState {
  const _PlayerQueueReturnState({
    required this.compactPage,
    required this.rightPane,
    required this.lastOperatedRegion,
  });

  final int compactPage;
  final PlayerRightPane rightPane;
  final PlayerOperatedRegion lastOperatedRegion;
}

const double playerWideLayoutBreakpoint = 840;

bool usesWidePlayerLayout(double width) => width >= playerWideLayoutBreakpoint;

class AudioPlayerScreen extends ConsumerStatefulWidget {
  const AudioPlayerScreen({
    super.key,
    this.initialPalette,
    this.initialPaletteTrackId,
    this.initialSurface = PlayerInitialSurface.main,
  });

  final PlayerVisualPalette? initialPalette;
  final String? initialPaletteTrackId;
  final PlayerInitialSurface initialSurface;

  @override
  ConsumerState<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends ConsumerState<AudioPlayerScreen> {
  static const _lyricTranslationConfirmKey = 'lyric_translation_confirmed_once';
  static const Duration _pageTransitionDuration = Duration(milliseconds: 300);
  static const Curve _pageTransitionCurve = Curves.ease;

  final ValueNotifier<String?> _workProgress = ValueNotifier(null);
  String? get _currentProgress => _workProgress.value;
  int? _currentRating;
  int? _currentWorkId;
  final ValueNotifier<PlayerSeekPreview?> _seekPreview =
      ValueNotifier<PlayerSeekPreview?>(null);
  bool get _isSeekingManually => _seekPreview.value?.isSeekingManually ?? false;
  double get _seekValue => _seekPreview.value?.seekValue ?? 0;
  Duration? get _seekingPosition => _seekPreview.value?.position;
  bool _showLyricView = false;
  PlayerLeftPane _leftPane = PlayerLeftPane.cover;
  PlayerRightPane _rightPane = PlayerRightPane.controls;
  int _compactPage = 1;
  PlayerOperatedRegion _lastOperatedRegion = PlayerOperatedRegion.right;
  _PlayerQueueReturnState? _queueReturnState;
  late bool _queueHasBeenOpened;
  final PageController _compactPageController = PageController(initialPage: 1);
  final PageController _wideLeftPageController = PageController(initialPage: 1);
  final PageController _wideRightPageController = PageController();
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
  late final ScrollController _compactQueueScrollController =
      _compactPageHandoff.createScrollController(
        debugLabel: 'compact-player-queue',
      );
  late final ScrollController _wideLyricsScrollController = _widePageHandoff
      .createScrollController(debugLabel: 'wide-player-lyrics');
  late final ScrollController _wideControlsScrollController = _widePageHandoff
      .createScrollController(debugLabel: 'wide-player-controls');
  late final ScrollController _wideQueueScrollController = _widePageHandoff
      .createScrollController(debugLabel: 'wide-player-queue');
  final Map<PageController, int> _requestedPageTargets = {};
  final Map<PageController, int> _pageDragOrigins = {};
  final FocusNode _keyboardFocusNode = FocusNode(debugLabel: 'audio-player');
  bool? _lastWasWide;
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
    _wideLeftPageController.dispose();
    _wideRightPageController.dispose();
    _compactPageHandoff.cancelActiveDrags();
    _widePageHandoff.cancelActiveDrags();
    _compactVerticalPageController.dispose();
    _wideVerticalPageController.dispose();
    _compactDetailsScrollController.dispose();
    _compactLyricsScrollController.dispose();
    _compactQueueScrollController.dispose();
    _wideLyricsScrollController.dispose();
    _wideControlsScrollController.dispose();
    _wideQueueScrollController.dispose();
    _keyboardFocusNode.dispose();
    _detachPaletteRouteListeners();
    _unlockButtonTimer?.cancel();
    _semanticPageRevision.dispose();
    _coverPreviewHeroTrackId.dispose();
    _progressGestureActive.dispose();
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
        _workProgress.value = work.progress;
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
    final dur = ref.read(durationProvider).value ?? Duration.zero;
    _seekPreview.value = (
      isSeekingManually: true,
      seekValue: value,
      position: Duration(milliseconds: (value * dur.inMilliseconds).round()),
    );
  }

  void _handleSeekEnd(double value) {
    if (ref.read(isTrackLoadingProvider).valueOrNull ?? false) return;
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

    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        _seekPreview.value = null;
      }
    });
  }

  Future<bool> _confirmLyricTranslationIfNeeded(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_lyricTranslationConfirmKey) ?? false) {
      return true;
    }
    if (!context.mounted) return false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => PlayerGlassAlertDialog(
        title: Text(S.of(dialogContext).translateLyrics),
        content: Text(S.of(dialogContext).lyricTranslationConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(S.of(dialogContext).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(S.of(dialogContext).confirm),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await prefs.setBool(_lyricTranslationConfirmKey, true);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
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
                          key: const ValueKey('player-stage-under-fullscreen'),
                          offstage: _isLyricLocked,
                          child: IgnorePointer(
                            ignoring: _isLyricLocked,
                            child: TickerMode(
                              enabled: !_isLyricLocked,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final isWide = usesWidePlayerLayout(
                                    constraints.maxWidth,
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
    final oldLeftPage = _pageAfterResize(
      _wideLeftPageController,
      dragOrigins,
      requestedTargets,
      _leftPane == PlayerLeftPane.information ? 0 : 1,
    );
    final oldRightPage = _pageAfterResize(
      _wideRightPageController,
      dragOrigins,
      requestedTargets,
      _rightPane == PlayerRightPane.lyrics ? 1 : 0,
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
        oldLeftPage,
        oldRightPage,
        applyRight: _rightPane != PlayerRightPane.queue,
      );
    } else if (_rightPane != PlayerRightPane.queue) {
      _applyCompactPageSemantics(oldCompactPage);
    }

    final queuePageSelected = !_directQueueEntry && oldVerticalPage == 1;
    if (queuePageSelected && _rightPane != PlayerRightPane.queue) {
      _captureQueueOrigin(compactOriginPage: oldCompactPage);
    }
    if (queuePageSelected) {
      _queueHasBeenOpened = true;
      _rightPane = PlayerRightPane.queue;
    } else if (!_directQueueEntry && _rightPane == PlayerRightPane.queue) {
      _restoreQueueSemanticFields(wasWide: oldWide);
    }

    if (queuePageSelected && oldWide && !isWide) {
      final returnState = _queueReturnState;
      final returnRight = returnState?.rightPane == PlayerRightPane.lyrics
          ? PlayerRightPane.lyrics
          : PlayerRightPane.controls;
      final compactReturnPage = _compactPageForSemantics(
        leftPane: _leftPane,
        rightPane: returnRight,
        lastRegion: _lastOperatedRegion,
      );
      _compactPage = compactReturnPage;
      _queueReturnState = _PlayerQueueReturnState(
        compactPage: compactReturnPage,
        rightPane: returnRight,
        lastOperatedRegion: _lastOperatedRegion,
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
          _wideLeftPageController,
          _leftPane == PlayerLeftPane.information ? 0 : 1,
        );
        _restorePageController(
          _wideRightPageController,
          (_rightPane == PlayerRightPane.queue
                      ? _queueReturnState?.rightPane
                      : _rightPane) ==
                  PlayerRightPane.lyrics
              ? 1
              : 0,
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
    final previous = _compactPage;
    _compactPage = page.clamp(0, 2).toInt();
    if (_compactPage == 0) {
      _leftPane = PlayerLeftPane.information;
      _lastOperatedRegion = PlayerOperatedRegion.left;
    } else if (_compactPage == 2) {
      _rightPane = PlayerRightPane.lyrics;
      _lastOperatedRegion = PlayerOperatedRegion.right;
    } else if (previous == 0) {
      _leftPane = PlayerLeftPane.cover;
      _lastOperatedRegion = PlayerOperatedRegion.left;
    } else if (previous == 2) {
      _rightPane = PlayerRightPane.controls;
      _lastOperatedRegion = PlayerOperatedRegion.right;
    }
  }

  void _applyWidePageSemantics(
    int leftPage,
    int rightPage, {
    required bool applyRight,
  }) {
    final leftPane = leftPage == 0
        ? PlayerLeftPane.information
        : PlayerLeftPane.cover;
    if (_leftPane != leftPane) {
      _leftPane = leftPane;
      _lastOperatedRegion = PlayerOperatedRegion.left;
    }
    if (!applyRight) return;
    final rightPane = rightPage == 1
        ? PlayerRightPane.lyrics
        : PlayerRightPane.controls;
    if (_rightPane != rightPane) {
      _rightPane = rightPane;
      _lastOperatedRegion = PlayerOperatedRegion.right;
    }
  }

  void _restoreQueueSemanticFields({required bool wasWide}) {
    final restored =
        _queueReturnState ??
        const _PlayerQueueReturnState(
          compactPage: 1,
          rightPane: PlayerRightPane.controls,
          lastOperatedRegion: PlayerOperatedRegion.right,
        );
    final restoredRight = restored.rightPane == PlayerRightPane.queue
        ? PlayerRightPane.controls
        : restored.rightPane;
    _rightPane = restoredRight;
    if (wasWide) {
      _compactPage = _compactPageForSemantics(
        leftPane: _leftPane,
        rightPane: restoredRight,
        lastRegion: _lastOperatedRegion,
      );
    } else {
      _compactPage = restored.compactPage;
      _lastOperatedRegion = restored.lastOperatedRegion;
      if (_compactPage == 0) _leftPane = PlayerLeftPane.information;
      if (_compactPage == 2) _rightPane = PlayerRightPane.lyrics;
    }
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
    if (identical(controller, _wideLeftPageController)) {
      return _leftPane == PlayerLeftPane.information ? 0 : 1;
    }
    if (identical(controller, _wideRightPageController)) {
      return _rightPane == PlayerRightPane.lyrics ? 1 : 0;
    }
    return _rightPane == PlayerRightPane.queue ? 1 : 0;
  }

  int get _semanticCompactPage {
    return _compactPageForSemantics(
      leftPane: _leftPane,
      rightPane: _rightPane,
      lastRegion: _lastOperatedRegion,
    );
  }

  int _compactPageForSemantics({
    required PlayerLeftPane leftPane,
    required PlayerRightPane rightPane,
    required PlayerOperatedRegion lastRegion,
  }) {
    if (lastRegion == PlayerOperatedRegion.left &&
        leftPane == PlayerLeftPane.information) {
      return 0;
    }
    if (lastRegion == PlayerOperatedRegion.right &&
        rightPane == PlayerRightPane.lyrics) {
      return 2;
    }
    if (rightPane == PlayerRightPane.lyrics) return 2;
    if (leftPane == PlayerLeftPane.information) return 0;
    return 1;
  }

  Widget _buildWidePlayer(
    BuildContext context, {
    required AudioTrack track,
    required String? coverUrl,
    required PlayerVisualPalette previewPalette,
  }) {
    final directQueueOnly = _directQueueEntry && !_playerPagesActivated;
    final width = MediaQuery.sizeOf(context).width;
    final titleDismissDrag = _dismissCoordinator.callbacks(context);
    final mainBodyDismissDrag = _dismissCoordinator.callbacks(
      context,
      mainBodyOnly: true,
    );
    final outerPadding = width >= 1200 ? 48.0 : 24.0;
    final gap = width >= 1200 ? 40.0 : 20.0;
    return SafeArea(
      minimum: EdgeInsets.fromLTRB(outerPadding, 18, outerPadding, 18),
      child: Row(
        key: const ValueKey('wide-player-layout'),
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final detailsWidth = math.max(
                  0.0,
                  (constraints.maxWidth - 24) * 0.90,
                );
                return directQueueOnly
                    ? _buildCoverPane(
                        context,
                        track: track,
                        coverUrl: coverUrl,
                        isWide: true,
                        previewPalette: previewPalette,
                      )
                    : Directionality(
                        textDirection: TextDirection.ltr,
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (notification) =>
                              _handlePageScrollNotification(
                                notification,
                                _wideLeftPageController,
                                vertical: false,
                              ),
                          child: _withEarlierPlayerPageGestureStart(
                            context,
                            PageView(
                              key: const ValueKey('wide-left-pages'),
                              controller: _wideLeftPageController,
                              physics: const PlayerPageScrollPhysics(),
                              allowImplicitScrolling: true,
                              onPageChanged: _onWideLeftPageChanged,
                              children: [
                                _withOriginalPlayerGestureSettings(
                                  context,
                                  _PlayerPageBoundary(
                                    key: const ValueKey(
                                      'wide-details-page-boundary',
                                    ),
                                    pageController: _wideLeftPageController,
                                    pageIndex: 0,
                                    child: Center(
                                      child: SizedBox(
                                        width: detailsWidth,
                                        height: double.infinity,
                                        child: ValueListenableBuilder<int>(
                                          valueListenable:
                                              _semanticPageRevision,
                                          builder: (context, _, __) =>
                                              PlayerAudioDetailsPanel(
                                                key: const ValueKey(
                                                  'wide-audio-details-pane',
                                                ),
                                                onOpenWork: _openKnownWork,
                                                isActive:
                                                    !_isLyricLocked &&
                                                    _leftPane ==
                                                        PlayerLeftPane
                                                            .information,
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                _withOriginalPlayerGestureSettings(
                                  context,
                                  _PlayerPageBoundary(
                                    key: const ValueKey(
                                      'wide-cover-page-boundary',
                                    ),
                                    pageController: _wideLeftPageController,
                                    pageIndex: 1,
                                    child: PlayerVerticalSwipeRegion(
                                      key: const ValueKey(
                                        'wide-cover-dismiss-surface',
                                      ),
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
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
              },
            ),
          ),
          SizedBox(width: gap),
          Expanded(
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
                            child: Column(
                              children: [
                                _buildWideHeader(
                                  context,
                                  track,
                                  dismissDrag: titleDismissDrag,
                                  allowTitleAnimation: true,
                                  pageDragCoordinator: _widePageHandoff,
                                ),
                                Expanded(
                                  child: NotificationListener<ScrollNotification>(
                                    onNotification: (notification) =>
                                        _handlePageScrollNotification(
                                          notification,
                                          _wideRightPageController,
                                          vertical: false,
                                        ),
                                    child: _withEarlierPlayerPageGestureStart(
                                      context,
                                      PageView(
                                        key: const ValueKey('wide-right-pages'),
                                        controller: _wideRightPageController,
                                        physics:
                                            const PlayerPageScrollPhysics(),
                                        allowImplicitScrolling: true,
                                        onPageChanged: _onWideRightPageChanged,
                                        children: [
                                          _withOriginalPlayerGestureSettings(
                                            context,
                                            _PlayerPageBoundary(
                                              key: const ValueKey(
                                                'wide-controls-page-boundary',
                                              ),
                                              pageController:
                                                  _wideRightPageController,
                                              pageIndex: 0,
                                              child: _buildControlsPane(
                                                context,
                                                track: track,
                                                isWide: true,
                                                showTrackHeader: false,
                                                dismissDrag:
                                                    mainBodyDismissDrag,
                                              ),
                                            ),
                                          ),
                                          _withOriginalPlayerGestureSettings(
                                            context,
                                            _PlayerPageBoundary(
                                              key: const ValueKey(
                                                'wide-lyrics-page-boundary',
                                              ),
                                              pageController:
                                                  _wideRightPageController,
                                              pageIndex: 1,
                                              child: _buildLyricsPane(
                                                context,
                                                isWide: true,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
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
    required PlayerScrollDragHandoffCoordinator pageDragCoordinator,
  }) {
    return PlayerVerticalSwipeRegion(
      key: const ValueKey('wide-header-dismiss-surface'),
      swipeDownDrag: dismissDrag,
      pageDragCoordinator: pageDragCoordinator,
      child: _buildPlayerCoverHeaderTransition(
        context,
        key: const ValueKey('wide-player-cover-header-opacity'),
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
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).moreButtonTooltip,
                    onPressed: () => _showMoreSheet(context, track),
                    icon: const Icon(Icons.more_horiz),
                  ),
                ],
              ),
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
      minimum: const EdgeInsets.fromLTRB(0, 10, 0, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
          final headerReserve = 72 + (textScale.clamp(1, 2) - 1) * 60;
          final sharedWidth = _compactContentWidth(
            context,
            BoxConstraints(
              maxWidth: constraints.maxWidth,
              maxHeight: math.max(
                0,
                constraints.maxHeight - headerReserve - 12,
              ),
            ),
          );
          _compactSharedWidth = sharedWidth;
          final titleDismissDrag = _dismissCoordinator.callbacks(context);
          final mainBodyDismissDrag = _dismissCoordinator.callbacks(
            context,
            mainBodyOnly: true,
          );
          final compactPageChildren = _playerPagesActivated
              ? SliverChildListDelegate([
                  _withOriginalPlayerGestureSettings(
                    context,
                    _PlayerPageBoundary(
                      key: const ValueKey('compact-details-page-boundary'),
                      pageController: _compactPageController,
                      pageIndex: 0,
                      child: Center(
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
                      child: _buildLyricsPane(context, isWide: false),
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
    return PlayerVerticalSwipeRegion(
      key: const ValueKey('compact-header-dismiss-surface'),
      swipeDownDrag: dismissDrag,
      pageDragCoordinator: _compactPageHandoff,
      child: _buildPlayerCoverHeaderTransition(
        context,
        key: const ValueKey('compact-player-cover-header-opacity'),
        child: Center(
          child: SizedBox(
            width: sharedWidth + 24,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, top: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ValueListenableBuilder<int>(
                      valueListenable: _semanticPageRevision,
                      builder: (context, _, __) => _buildTrackTitleBlock(
                        context,
                        track,
                        false,
                        allowAnimation:
                            !_queueTransitionActive &&
                            _rightPane != PlayerRightPane.queue,
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  IconButton(
                    key: const ValueKey('player-more-button'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).moreButtonTooltip,
                    onPressed: () => _showMoreSheet(context, track),
                    padding: EdgeInsets.zero,
                    alignment: Alignment.center,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: const Icon(Icons.more_horiz),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerCoverHeaderTransition(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) {
    return ValueListenableBuilder<int>(
      valueListenable: _semanticPageRevision,
      child: child,
      builder: (context, _, child) {
        final routeAnimation = ModalRoute.of(context)?.animation;
        final reduceMotion = MediaQuery.disableAnimationsOf(context);
        if (routeAnimation == null ||
            reduceMotion ||
            _currentPlayerDismissVisualMode != PlayerDismissVisualMode.main) {
          return Opacity(key: key, opacity: 1, child: child);
        }
        return AnimatedBuilder(
          animation: routeAnimation,
          child: child,
          builder: (context, child) => Opacity(
            key: key,
            opacity: playerCoverHeaderOpacity(routeAnimation.value),
            child: child,
          ),
        );
      },
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
    required PlayerVerticalDragCallbacks dismissDrag,
    required PlayerVisualPalette previewPalette,
  }) {
    final content = Center(
      child: SizedBox(
        key: const ValueKey('compact-main-shared-width'),
        width: sharedWidth,
        child: Column(
          children: [
            Expanded(
              child: PlayerVerticalSwipeRegion(
                key: const ValueKey('compact-main-cover-dismiss-surface'),
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
              width: sharedWidth,
              height: 144,
              child: Center(
                child: SizedBox(
                  key: const ValueKey('compact-main-lyric-width-boundary'),
                  width: sharedWidth,
                  child: ThreeLineLyricDisplay(
                    key: const ValueKey('compact-main-lyric-scroll-surface'),
                    onSeekRequested: (position) => unawaited(
                      ref
                          .read(audioPlayerControllerProvider.notifier)
                          .seekAndPersist(position),
                    ),
                    onLineDoubleTap: _togglePlayback,
                    enableLineTapFeedback: true,
                    lineCount: 5,
                    textHorizontalPadding: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            PlayerVerticalSwipeRegion(
              key: const ValueKey('compact-main-controls-dismiss-surface'),
              swipeDownDrag: dismissDrag,
              pageDragCoordinator: _compactPageHandoff,
              child: _buildControlsPane(
                context,
                track: track,
                isWide: false,
                showTrackHeader: false,
                enableQueueGesture: false,
                horizontalPadding: 0,
              ),
            ),
          ],
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
    return ValueListenableBuilder<int>(
      valueListenable: _semanticPageRevision,
      builder: (context, _, __) {
        final heroEnabled = _shouldEnableMainArtworkHero(isWide: isWide);
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
              heroEnabled: heroEnabled && !previewHeroActive,
              heroTarget: heroEnabled
                  ? PlayerArtworkFlightTarget.main
                  : PlayerArtworkFlightTarget.none,
              onTap: coverUrl == null
                  ? null
                  : () => _showCoverPreview(track, coverUrl, previewPalette),
              previewHeroTag: playerCoverPreviewHeroTag(track.id),
              previewHeroEnabled: previewHeroActive,
            );
            return cover;
          },
        );
      },
    );
  }

  double _compactContentWidth(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final reservedHeight = 364 + (textScale.clamp(1, 2) - 1) * 72;
    final availableWidth = math.max(0.0, constraints.maxWidth - 56);
    final heightBound =
        math.max(160.0, constraints.maxHeight - reservedHeight) *
        PlayerCoverWidget.preferredAspectRatio;
    return math.min(availableWidth, heightBound);
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
          InkWell(
            key: const ValueKey('player-cover-lyric-preview'),
            borderRadius: BorderRadius.circular(12),
            onTap: _showLyrics,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: LyricDisplay(albumName: track.album),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsPane(
    BuildContext context, {
    required AudioTrack track,
    required bool isWide,
    bool showTrackHeader = true,
    bool enableQueueGesture = true,
    double? horizontalPadding,
    PlayerVerticalDragCallbacks? dismissDrag,
  }) {
    final controls = ValueListenableBuilder<String?>(
      valueListenable: _workProgress,
      builder: (_, progress, _) => PlayerControlsWidget(
        isLandscape: isWide,
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
            : () => _showMarkDialog(context, track.workId!, track.title),
        onDetailPressed: track.workId == null
            ? null
            : () => _navigateToWorkDetail(context, track.workId!),
        onQueuePressed: _showQueue,
        visibleActionCount: 5,
        additionalActionWidth: isWide || _compactSharedWidth == null
            ? null
            : _compactSharedWidth! + 24,
      ),
    );
    final content = Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding ?? 12,
              vertical: isWide ? 18 : 0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showTrackHeader) ...[
                  Text(
                    track.title,
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
                controls,
              ],
            ),
          ),
        ),
      ),
    );

    if (!isWide) {
      return KeyedSubtree(
        key: const ValueKey('controls-pane-compact'),
        child: content,
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
            height: 72,
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
                      child: Center(child: content),
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

  Widget _buildLyricsPane(BuildContext context, {required bool isWide}) {
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
                        !_queueTransitionActive &&
                        _compactPage == 2 &&
                        _rightPane != PlayerRightPane.queue,
              seekingPosition: _seekingPosition,
              seekingPositionListenable: _seekPreview,
              onTogglePlayback: _togglePlayback,
              onFullscreen: _enterLyricFullscreen,
              onLongPress: _enterLyricFullscreen,
              scrollController: isWide
                  ? _wideLyricsScrollController
                  : _compactLyricsScrollController,
              lyricContentWidth: isWide ? null : _compactSharedWidth,
              actionWidth: isWide || _compactSharedWidth == null
                  ? null
                  : _compactSharedWidth! + 24,
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
        key: const ValueKey('player-queue-width-boundary'),
        width: isWide ? double.infinity : _compactSharedWidth! + 20,
        child: Column(
          children: [
            Expanded(
              child: PlayerQueueSurface(
                onTrackSelected: () {},
                onClear: _clearQueueAndClosePlayer,
                onDismissRequested: directQueueOnly ? _dismissPlayer : null,
                dismissDrag: directQueueDismissDrag,
                scrollController: directQueueOnly
                    ? null
                    : isWide
                    ? _wideQueueScrollController
                    : _compactQueueScrollController,
                pageDragCoordinator: directQueueOnly
                    ? null
                    : isWide
                    ? _widePageHandoff
                    : _compactPageHandoff,
                horizontalPadding: isWide ? 0 : 10,
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

  bool _shouldEnableMainArtworkHero({required bool isWide}) {
    if (_directQueueEntry ||
        _queueTransitionActive ||
        _rightPane == PlayerRightPane.queue) {
      return false;
    }
    return isWide ? _leftPane == PlayerLeftPane.cover : _compactPage == 1;
  }

  PlayerDismissVisualMode get _currentPlayerDismissVisualMode {
    if (_rightPane == PlayerRightPane.queue) {
      return PlayerDismissVisualMode.secondary;
    }
    final isWide =
        _lastWasWide ?? usesWidePlayerLayout(MediaQuery.sizeOf(context).width);
    return _shouldEnableMainArtworkHero(isWide: isWide)
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
    final previous = _compactPage;
    _commitSemanticPage(() {
      _compactPage = index;
      if (index == 0) {
        _leftPane = PlayerLeftPane.information;
        _lastOperatedRegion = PlayerOperatedRegion.left;
      } else if (index == 2) {
        _rightPane = PlayerRightPane.lyrics;
        _lastOperatedRegion = PlayerOperatedRegion.right;
      } else if (previous == 0) {
        _leftPane = PlayerLeftPane.cover;
        _lastOperatedRegion = PlayerOperatedRegion.left;
      } else if (previous == 2) {
        _rightPane = PlayerRightPane.controls;
        _lastOperatedRegion = PlayerOperatedRegion.right;
      }
    });
  }

  void _onWideLeftPageChanged(int index) {
    final pane = index == 0 ? PlayerLeftPane.information : PlayerLeftPane.cover;
    if (_leftPane == pane) return;
    _commitSemanticPage(() {
      _leftPane = pane;
      _lastOperatedRegion = PlayerOperatedRegion.left;
    });
  }

  void _onWideRightPageChanged(int index) {
    final pane = index == 0 ? PlayerRightPane.controls : PlayerRightPane.lyrics;
    if (_rightPane == PlayerRightPane.queue || _rightPane == pane) return;
    _commitSemanticPage(() {
      _rightPane = pane;
      _lastOperatedRegion = PlayerOperatedRegion.right;
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
      _lastOperatedRegion = PlayerOperatedRegion.right;
    });
    _animateSemanticPage(
      wideController: _wideRightPageController,
      widePage: 1,
      compactPage: 2,
    );
  }

  void _animateSemanticPage({
    required PageController wideController,
    required int widePage,
    required int compactPage,
  }) {
    final controller = usesWidePlayerLayout(MediaQuery.sizeOf(context).width)
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

  void _showQueue({int? compactOriginPage}) {
    if (_directQueueEntry || _rightPane == PlayerRightPane.queue) return;
    _semanticTransitionGeneration++;
    _captureQueueOrigin(compactOriginPage: compactOriginPage);
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

  void _captureQueueOrigin({int? compactOriginPage}) {
    if (_rightPane == PlayerRightPane.queue) return;
    final controllerPage = _compactPageController.hasClients
        ? _compactPageController.page?.round()
        : null;
    final resolvedCompactPage =
        (compactOriginPage ?? controllerPage ?? _compactPage)
            .clamp(0, 2)
            .toInt();
    _queueReturnState = _PlayerQueueReturnState(
      compactPage: resolvedCompactPage,
      rightPane: _rightPane,
      lastOperatedRegion: _lastOperatedRegion,
    );
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
    final wasWide = _lastWasWide == true;
    _commitSemanticPage(() => _restoreQueueSemanticFields(wasWide: wasWide));
    final restoredRight = _rightPane;
    final compactPage = _compactPage;
    _dismissCoordinator.scheduleVisualModeSync(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (usesWidePlayerLayout(MediaQuery.sizeOf(context).width)) {
        if (_wideRightPageController.hasClients) {
          _wideRightPageController.jumpToPage(
            restoredRight == PlayerRightPane.lyrics ? 1 : 0,
          );
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
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: false,
        requestFocus: false,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.transparent,
        builder: (sheetContext) => PlayerBackdropGroup(
          child: PlayerTransientGlassSurface(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: math.min(
                  MediaQuery.sizeOf(sheetContext).height * 0.62,
                  520,
                ),
                child: ValueListenableBuilder<String?>(
                  valueListenable: _workProgress,
                  builder: (_, progress, _) => PlayerInfoPanel(
                    track: track,
                    currentProgress: progress,
                    onMarkPressed: track.workId == null
                        ? null
                        : () => _showMarkDialog(
                            context,
                            track.workId!,
                            track.title,
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
              ),
            ),
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
    _releaseTextInputFocus();
    try {
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

  Future<void> _openKnownWork(Work work) {
    return pushWorkDetailRoute(
      context,
      builder: (context) => WorkDetailScreen(work: work),
    );
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
                                  track.title,
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
                                LyricDisplay(albumName: track.album),
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
                              track.title,
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
                          track.title,
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
                                        track.title,
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
    final isWide =
        _lastWasWide ?? usesWidePlayerLayout(MediaQuery.sizeOf(context).width);
    return _isPlayerCoverVisible(isWide: isWide);
  }

  bool _isPlayerCoverVisible({required bool isWide}) {
    if (isWide) {
      return _leftPane == PlayerLeftPane.cover;
    }
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

                    final confirmed = await _confirmLyricTranslationIfNeeded(
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
        }
      },
    );
  }

  Future<void> _navigateToWorkDetail(BuildContext context, int workId) async {
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

        pushWorkDetailRoute(
          context,
          builder: (context) => WorkDetailScreen(work: work),
        );
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

  static const duration = Duration(milliseconds: 260);

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
          track.title,
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
      label: '${track.title}, ${S.of(context).viewDetail}',
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
  return MediaQuery(
    data: mediaQuery.copyWith(
      gestureSettings: DeviceGestureSettings(touchSlop: touchSlop * 0.85),
    ),
    child: child,
  );
}

Widget _withOriginalPlayerGestureSettings(BuildContext context, Widget child) =>
    MediaQuery(data: MediaQuery.of(context), child: child);

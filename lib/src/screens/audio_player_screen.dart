import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/work.dart';
import '../models/audio_track.dart';
import '../providers/audio_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/lyric_provider.dart';
import '../providers/player_work_details_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/local_file_url.dart';
import '../utils/system_ui_style.dart';
import '../widgets/player/player_cover_widget.dart';
import '../widgets/player/player_controls_widget.dart';
import '../widgets/player/lyric_display_widget.dart';
import '../widgets/player/playlist_dialog.dart';
import '../widgets/player/player_info_panel.dart';
import '../widgets/player/player_audio_details_panel.dart';
import '../widgets/player/player_lyrics_surface.dart';
import '../widgets/player/player_glass_surface.dart';
import '../widgets/player/player_visual_palette.dart';
import '../widgets/player/player_vertical_gestures.dart';
import '../widgets/text_preview_screen.dart';
import '../widgets/work_bookmark_manager.dart';
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
    required this.leftPane,
    required this.rightPane,
    required this.lastOperatedRegion,
  });

  final int compactPage;
  final PlayerLeftPane leftPane;
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
  });

  final PlayerVisualPalette? initialPalette;
  final String? initialPaletteTrackId;

  @override
  ConsumerState<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends ConsumerState<AudioPlayerScreen>
    with SingleTickerProviderStateMixin {
  static const _lyricTranslationConfirmKey = 'lyric_translation_confirmed_once';

  bool _isSeekingManually = false;
  double _seekValue = 0.0;
  bool _showLyricHint = false;
  String? _currentProgress;
  int? _currentRating;
  int? _currentWorkId;
  Duration? _seekingPosition;
  bool _showLyricView = false;
  PlayerLeftPane _leftPane = PlayerLeftPane.cover;
  PlayerRightPane _rightPane = PlayerRightPane.controls;
  int _compactPage = 1;
  PlayerOperatedRegion _lastOperatedRegion = PlayerOperatedRegion.right;
  _PlayerQueueReturnState? _queueReturnState;
  final PageController _compactPageController = PageController(initialPage: 1);
  final PageController _wideLeftPageController = PageController();
  final PageController _wideRightPageController = PageController(
    initialPage: 1,
  );
  final FocusNode _keyboardFocusNode = FocusNode(debugLabel: 'audio-player');
  bool? _lastWasWide;
  double? _compactSharedWidth;
  Timer? _routePaletteTimer;
  Timer? _unlockButtonTimer;
  bool _routePaletteFrozen = false;
  int _semanticTransitionGeneration = 0;
  late final AnimationController _compactQueueTransitionController;
  int _queueTransitionGeneration = 0;
  bool _queueDragActive = false;
  bool _queueDragOpening = false;
  double _queueDragStartValue = 0;
  double _compactQueueExtent = 1;
  bool _queueTransitionActive = false;
  bool _dismissRequested = false;
  int _routeDismissGestureGeneration = 0;

  // 全屏锁定状态
  bool _isLyricLocked = false;
  bool _showUnlockButton = false;

  @override
  void initState() {
    super.initState();
    _compactQueueTransitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 260),
    );
    _routePaletteFrozen = widget.initialPalette != null;
    if (_routePaletteFrozen) {
      _routePaletteTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _routePaletteFrozen = false);
      });
    }
    _checkAndShowLyricHint();
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
    _compactQueueTransitionController.dispose();
    _wideLeftPageController.dispose();
    _wideRightPageController.dispose();
    _keyboardFocusNode.dispose();
    _routePaletteTimer?.cancel();
    _unlockButtonTimer?.cancel();
    _semanticTransitionGeneration++;
    _queueTransitionGeneration++;
    _routeDismissGestureGeneration++;
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

  Future<void> _checkAndShowLyricHint() async {
    final prefs = await SharedPreferences.getInstance();
    final hasShown = prefs.getBool('lyric_hint_has_shown') ?? false;

    if (!hasShown && mounted) {
      setState(() {
        _showLyricHint = true;
      });

      await prefs.setBool('lyric_hint_has_shown', true);

      Future.delayed(const Duration(seconds: 8), () {
        if (mounted) {
          setState(() {
            _showLyricHint = false;
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
        setState(() {
          _currentProgress = work.progress;
          _currentRating = work.userRating;
        });
      }
    } catch (e) {
      debugPrint('Failed to load progress for work $workId: $e');
    }
  }

  String? _buildWorkCoverUrl(int? workId, String? artworkUrl) {
    // 优先使用 track.artworkUrl（可能是本地文件 file://）
    if (LocalFileUrl.isLocalFileUrl(artworkUrl)) {
      return artworkUrl;
    }

    if (workId == null) return null;

    final authState = ref.read(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';

    if (host.isEmpty) return null;

    var normalizedHost = host;
    if (!normalizedHost.startsWith('http://') &&
        !normalizedHost.startsWith('https://')) {
      normalizedHost = 'https://$normalizedHost';
    }

    return token.isNotEmpty
        ? '$normalizedHost/api/cover/$workId?token=$token'
        : '$normalizedHost/api/cover/$workId';
  }

  void _handleSeekChanged(double value) {
    final dur = ref.read(durationProvider).value ?? Duration.zero;
    setState(() {
      _isSeekingManually = true;
      _seekValue = value;
      _seekingPosition = Duration(
        milliseconds: (value * dur.inMilliseconds).round(),
      );
    });
  }

  void _handleSeekEnd(double value) {
    final dur = ref.read(durationProvider).value ?? Duration.zero;
    final newPosition = Duration(
      milliseconds: (value * dur.inMilliseconds).round(),
    );

    setState(() {
      _seekingPosition = newPosition;
    });

    ref
        .read(audioPlayerControllerProvider.notifier)
        .seekAndPersist(newPosition);

    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          _isSeekingManually = false;
          _seekingPosition = null;
        });
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
    ref.listen(playerWorkDetailsProvider, (_, __) {});

    return currentTrack.when(
      data: (track) {
        if (track == null) {
          return Scaffold(
            body: Center(child: Text(S.of(context).noAudioPlaying)),
          );
        }
        _scheduleProgressLoad(track);
        final coverUrl = _buildWorkCoverUrl(track.workId, track.artworkUrl);
        final privacyHidesArtwork = ref.watch(
          privacyModeSettingsProvider.select(
            (settings) => settings.enabled && settings.blurCoverInApp,
          ),
        );
        final baseTheme = Theme.of(context);
        final request = PlayerPaletteRequest(
          source: coverUrl ?? track.artworkUrl,
          cacheKey: track.workId != null
              ? 'work_cover_${track.workId}'
              : track.hash ?? track.id,
          brightness: baseTheme.brightness,
          fallbackSeed: baseTheme.colorScheme.primary,
          suppressArtwork: privacyHidesArtwork,
        );
        final resolvedPalette =
            ref.watch(playerVisualPaletteProvider(request)).value ??
            PlayerVisualPalette.fallback(
              seed: baseTheme.colorScheme.primary,
              brightness: baseTheme.brightness,
            );
        final palette =
            _routePaletteFrozen &&
                widget.initialPaletteTrackId == track.id &&
                widget.initialPalette != null
            ? widget.initialPalette!
            : resolvedPalette;
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
      setState(() {
        _currentWorkId = track.workId;
        _currentProgress = null;
      });
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
              child: PopScope(
                canPop:
                    _dismissRequested ||
                    (!_isLyricLocked &&
                        !_queueTransitionActive &&
                        _rightPane == PlayerRightPane.controls &&
                        (_lastWasWide == true
                            ? _leftPane == PlayerLeftPane.cover
                            : _compactPage == 1)),
                onPopInvokedWithResult: (didPop, result) {
                  if (!didPop) _handleBack();
                },
                child: PlayerBackdropGroup(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: AnimatedSwitcher(
                          duration: motionDuration,
                          layoutBuilder: (currentChild, previousChildren) =>
                              Stack(
                                fit: StackFit.expand,
                                children: [
                                  ...previousChildren,
                                  if (currentChild != null) currentChild,
                                ],
                              ),
                          child: RepaintBoundary(
                            key: ValueKey(
                              '${palette.backgroundStart.toARGB32()}:'
                              '${palette.backgroundEnd.toARGB32()}',
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    palette.backgroundStart,
                                    palette.backgroundMiddle,
                                    palette.backgroundEnd,
                                  ],
                                  stops: const [0, 0.56, 1],
                                ),
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: RadialGradient(
                                    center: const Alignment(-0.72, 0.62),
                                    radius: 1.15,
                                    colors: [
                                      palette.accent.withValues(alpha: 0.18),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
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
                                  _syncResponsivePageController(isWide);
                                  return AnimatedSwitcher(
                                    duration: motionDuration,
                                    child: isWide
                                        ? _buildWidePlayer(
                                            context,
                                            track: track,
                                            coverUrl: coverUrl,
                                          )
                                        : _buildCompactPlayer(
                                            context,
                                            track: track,
                                            coverUrl: coverUrl,
                                          ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_isLyricLocked)
                        Positioned.fill(child: _buildPortraitLyricView()),
                      if (_showLyricHint && !_isLyricLocked)
                        _buildLyricHintBanner(),
                      if (isTrackLoading) _buildTrackLoadingOverlay(context),
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

  void _syncResponsivePageController(bool isWide) {
    if (_lastWasWide == isWide) return;
    _lastWasWide = isWide;
    final compactTarget = _semanticCompactPage;
    _compactPage = compactTarget;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (isWide) {
        _queueTransitionGeneration++;
        _queueDragActive = false;
        _queueTransitionActive = false;
        _compactQueueTransitionController.value = 0;
        if (_wideLeftPageController.hasClients) {
          _wideLeftPageController.jumpToPage(
            _leftPane == PlayerLeftPane.information ? 1 : 0,
          );
        }
        if (_wideRightPageController.hasClients) {
          _wideRightPageController.jumpToPage(
            _rightPane == PlayerRightPane.lyrics ? 0 : 1,
          );
        }
      } else {
        if (_compactPageController.hasClients) {
          _compactPageController.jumpToPage(compactTarget);
        }
        _compactQueueTransitionController.value =
            _rightPane == PlayerRightPane.queue ? 1 : 0;
      }
    });
  }

  int get _semanticCompactPage {
    if (_lastOperatedRegion == PlayerOperatedRegion.left &&
        _leftPane == PlayerLeftPane.information) {
      return 0;
    }
    if (_lastOperatedRegion == PlayerOperatedRegion.right &&
        _rightPane == PlayerRightPane.lyrics) {
      return 2;
    }
    if (_rightPane == PlayerRightPane.lyrics) return 2;
    if (_leftPane == PlayerLeftPane.information) return 0;
    return 1;
  }

  Widget _buildWidePlayer(
    BuildContext context, {
    required AudioTrack track,
    required String? coverUrl,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    final dismissDrag = _playerDismissDragCallbacks(context);
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
                return _rightPane == PlayerRightPane.queue
                    ? _buildCoverPane(
                        context,
                        track: track,
                        coverUrl: coverUrl,
                        isWide: true,
                      )
                    : Directionality(
                        textDirection: TextDirection.ltr,
                        child: PageView(
                          key: const ValueKey('wide-left-pages'),
                          controller: _wideLeftPageController,
                          allowImplicitScrolling: true,
                          onPageChanged: _onWideLeftPageChanged,
                          children: [
                            _buildCoverPane(
                              context,
                              track: track,
                              coverUrl: coverUrl,
                              isWide: true,
                            ),
                            Center(
                              child: SizedBox(
                                width: detailsWidth,
                                height: double.infinity,
                                child: PlayerAudioDetailsPanel(
                                  key: const ValueKey(
                                    'wide-audio-details-pane',
                                  ),
                                  onOpenWork: _openKnownWork,
                                  isActive:
                                      !_isLyricLocked &&
                                      _leftPane == PlayerLeftPane.information &&
                                      _rightPane != PlayerRightPane.queue,
                                  onDismissPlayer: _dismissPlayer,
                                  dismissDrag: dismissDrag,
                                  onShowQueue: () => _showQueue(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
              },
            ),
          ),
          SizedBox(width: gap),
          Expanded(
            child: Column(
              children: [
                if (_rightPane != PlayerRightPane.queue)
                  _buildWideHeader(context, track, dismissDrag: dismissDrag),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: _motionDuration(context),
                    child: _rightPane == PlayerRightPane.queue
                        ? _buildQueuePane(context, isWide: true)
                        : Directionality(
                            textDirection: TextDirection.ltr,
                            child: PageView(
                              key: const ValueKey('wide-right-pages'),
                              controller: _wideRightPageController,
                              physics: const NeverScrollableScrollPhysics(),
                              onPageChanged: _onWideRightPageChanged,
                              children: [
                                _buildLyricsPane(
                                  context,
                                  isWide: true,
                                  dismissDrag: dismissDrag,
                                ),
                                _buildControlsPane(
                                  context,
                                  track: track,
                                  isWide: true,
                                  showTrackHeader: false,
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWideHeader(
    BuildContext context,
    AudioTrack track, {
    PlayerVerticalDragCallbacks? dismissDrag,
  }) {
    return PlayerVerticalSwipeRegion(
      key: const ValueKey('wide-header-dismiss-surface'),
      onSwipeDown: _dismissPlayer,
      swipeDownDrag: dismissDrag,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          height: 1.12,
                        ),
                      ),
                      if (track.artist case final artist?)
                        Text(
                          artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('player-more-button-wide'),
                  tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                  onPressed: () => _showMoreSheet(context, track),
                  icon: const Icon(Icons.more_horiz),
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
              maxHeight: math.max(0, constraints.maxHeight - headerReserve - 4),
            ),
          );
          _compactSharedWidth = sharedWidth;
          _compactQueueExtent = math.max(1, constraints.maxHeight);
          final dismissDrag = _playerDismissDragCallbacks(context);
          final playerStage = Column(
            key: const ValueKey('compact-player-layout'),
            children: [
              _buildCompactHeader(
                context,
                track,
                sharedWidth,
                dismissDrag: dismissDrag,
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: PageView(
                    key: const ValueKey('compact-player-pages'),
                    controller: _compactPageController,
                    allowImplicitScrolling: true,
                    onPageChanged: _onCompactPageChanged,
                    children: [
                      Center(
                        child: SizedBox(
                          width: sharedWidth,
                          height: double.infinity,
                          child: PlayerAudioDetailsPanel(
                            key: const ValueKey('compact-audio-details-pane'),
                            onOpenWork: _openKnownWork,
                            isActive:
                                !_isLyricLocked &&
                                !_queueTransitionActive &&
                                _compactPage == 0 &&
                                _rightPane != PlayerRightPane.queue,
                            onDismissPlayer: _dismissPlayer,
                            dismissDrag: dismissDrag,
                            onShowQueue: () => _showQueue(compactOriginPage: 0),
                            showQueueDrag: _queueOpenDragCallbacks(0),
                          ),
                        ),
                      ),
                      _buildCompactMain(
                        context,
                        track: track,
                        coverUrl: coverUrl,
                        sharedWidth: sharedWidth,
                        dismissDrag: dismissDrag,
                      ),
                      _buildLyricsPane(
                        context,
                        isWide: false,
                        dismissDrag: dismissDrag,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
          final queueStage = _buildQueuePane(context, isWide: false);
          return ClipRect(
            key: const ValueKey('compact-player-vertical-pages'),
            child: AnimatedBuilder(
              animation: _compactQueueTransitionController,
              builder: (context, _) {
                final progress = _compactQueueTransitionController.value;
                final height = constraints.maxHeight;
                final playerOffstage =
                    !_queueTransitionActive && progress >= 0.999;
                final queueOffstage =
                    !_queueTransitionActive && progress <= 0.001;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Transform.translate(
                      key: const ValueKey('compact-player-stage-transform'),
                      offset: Offset(0, -height * progress),
                      child: Offstage(
                        offstage: playerOffstage,
                        child: RepaintBoundary(child: playerStage),
                      ),
                    ),
                    Transform.translate(
                      key: const ValueKey('compact-queue-stage-transform'),
                      offset: Offset(0, height * (1 - progress)),
                      child: Offstage(
                        offstage: queueOffstage,
                        child: RepaintBoundary(child: queueStage),
                      ),
                    ),
                  ],
                );
              },
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
    PlayerVerticalDragCallbacks? dismissDrag,
  }) {
    return PlayerVerticalSwipeRegion(
      key: const ValueKey('compact-header-dismiss-surface'),
      onSwipeDown: _dismissPlayer,
      swipeDownDrag: dismissDrag,
      onSwipeUp: () => _showQueue(compactOriginPage: _compactPage),
      swipeUpDrag: _queueOpenDragCallbacks(_compactPage),
      child: Center(
        child: SizedBox(
          width: sharedWidth,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          height: 1.12,
                        ),
                      ),
                      if (track.artist case final artist?) ...[
                        const SizedBox(height: 2),
                        Text(
                          artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontSize: 14,
                                height: 1.15,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('player-more-button'),
                  tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                  onPressed: () => _showMoreSheet(context, track),
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactMain(
    BuildContext context, {
    required AudioTrack track,
    required String? coverUrl,
    required double sharedWidth,
    PlayerVerticalDragCallbacks? dismissDrag,
  }) {
    final content = Center(
      child: SizedBox(
        key: const ValueKey('compact-main-shared-width'),
        width: sharedWidth,
        child: Column(
          children: [
            Expanded(
              child: RepaintBoundary(
                child: PlayerCoverWidget(
                  track: track,
                  workCoverUrl: coverUrl,
                  onTap: _showLyrics,
                ),
              ),
            ),
            ThreeLineLyricDisplay(onTap: _showLyrics, lineCount: 5),
            const SizedBox(height: 16),
            _buildControlsPane(
              context,
              track: track,
              isWide: false,
              showTrackHeader: false,
              enableQueueGesture: false,
              horizontalPadding: 0,
            ),
          ],
        ),
      ),
    );
    return PlayerVerticalSwipeRegion(
      key: const ValueKey('compact-main-queue-swipe-surface'),
      onSwipeDown: _dismissPlayer,
      swipeDownDrag: dismissDrag,
      onSwipeUp: () => _showQueue(compactOriginPage: 1),
      swipeUpDrag: _queueOpenDragCallbacks(1),
      child: KeyedSubtree(
        key: const ValueKey('compact-main-page'),
        child: content,
      ),
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
                      child: PlayerCoverWidget(
                        track: track,
                        workCoverUrl: coverUrl,
                        isLandscape: isWide,
                        onTap: _showLyrics,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          InkWell(
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
  }) {
    final controls = PlayerControlsWidget(
      isLandscape: isWide,
      isSeekingManually: _isSeekingManually,
      seekValue: _seekValue,
      onSeekChanged: _handleSeekChanged,
      onSeekEnd: _handleSeekEnd,
      seekingPosition: _seekingPosition,
      workId: track.workId,
      currentProgress: _currentProgress,
      onMarkPressed: track.workId == null
          ? null
          : () => _showMarkDialog(context, track.workId!, track.title),
      onDetailPressed: track.workId == null
          ? null
          : () => _navigateToWorkDetail(context, track.workId!),
      onQueuePressed: _showQueue,
      visibleActionCount: 5,
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
    // A full-size detector behind the scroll view loses hit testing to the
    // scrollable and can also make sliders/buttons compete for the drag.
    return Column(
      key: const ValueKey('controls-pane-wide'),
      children: [
        if (enableQueueGesture)
          SizedBox(
            height: 72,
            width: double.infinity,
            child: GestureDetector(
              key: const ValueKey('controls-queue-swipe-surface-wide'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) < -550) _showQueue();
              },
              onHorizontalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) > 550) _showLyrics();
              },
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(child: content),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLyricsPane(
    BuildContext context, {
    required bool isWide,
    PlayerVerticalDragCallbacks? dismissDrag,
  }) {
    return Consumer(
      key: ValueKey('lyrics-pane-${isWide ? 'wide' : 'compact'}'),
      builder: (context, ref, child) {
        final lyricState = ref.watch(lyricControllerProvider);
        return GestureDetector(
          key: ValueKey('lyrics-swipe-surface-${isWide ? 'wide' : 'compact'}'),
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: isWide
              ? (details) {
                  if ((details.primaryVelocity ?? 0) < -550) _showControls();
                }
              : null,
          child: PlayerLyricsSurface(
            isWide: isWide,
            isActive: isWide
                ? !_isLyricLocked && _rightPane == PlayerRightPane.lyrics
                : !_isLyricLocked &&
                      !_queueTransitionActive &&
                      _compactPage == 2 &&
                      _rightPane != PlayerRightPane.queue,
            seekingPosition: _seekingPosition,
            onFullscreen: _enterLyricFullscreen,
            onLongPress: _enterLyricFullscreen,
            onDismissPlayer: _dismissPlayer,
            dismissDrag: dismissDrag,
            onShowQueue: () => _showQueue(compactOriginPage: isWide ? null : 2),
            showQueueDrag: isWide ? null : _queueOpenDragCallbacks(2),
            actionWidth: isWide ? null : _compactSharedWidth,
            translateButton: _buildLyricTranslateAppBarButton(context),
            onDownload: lyricState.source?.canSaveOriginal == true
                ? () => _openCurrentLyricSource(context, lyricState.source!)
                : null,
          ),
        );
      },
    );
  }

  Widget _buildQueuePane(BuildContext context, {required bool isWide}) {
    return Align(
      key: const ValueKey('player-queue-pane'),
      alignment: Alignment.center,
      child: SizedBox(
        key: const ValueKey('player-queue-width-boundary'),
        width: isWide ? double.infinity : _compactSharedWidth,
        child: Column(
          children: [
            Expanded(
              child: PlayerQueueSurface(
                onTrackSelected: () {},
                onClear: _clearQueueAndClosePlayer,
                onDismissRequested: _closeQueue,
                dismissDrag: isWide ? null : _queueCloseDragCallbacks,
                horizontalPadding: 0,
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
        : const Duration(milliseconds: 260);
  }

  PlayerVerticalDragCallbacks? _playerDismissDragCallbacks(
    BuildContext context,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return null;
    final route = ModalRoute.of(context);
    if (route is! PlayerInteractiveDismissRoute) return null;
    final interactiveRoute = route as PlayerInteractiveDismissRoute;
    final extent = math.max(1.0, MediaQuery.sizeOf(context).height);
    return PlayerVerticalDragCallbacks(
      onStart: () {
        if (!interactiveRoute.beginVerticalDismissGesture()) return;
        _routeDismissGestureGeneration++;
        if (!_dismissRequested) setState(() => _dismissRequested = true);
        _releaseTextInputFocus();
      },
      onUpdate: (distance) => interactiveRoute.updateVerticalDismissGesture(
        distance: distance,
        extent: extent,
      ),
      onEnd: (distance, velocity) {
        interactiveRoute.endVerticalDismissGesture(
          velocity: velocity,
          extent: extent,
        );
        _scheduleInteractiveDismissReset();
      },
      onCancel: () {
        interactiveRoute.cancelVerticalDismissGesture();
        _scheduleInteractiveDismissReset();
      },
    );
  }

  void _scheduleInteractiveDismissReset() {
    final request = _routeDismissGestureGeneration;
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (!mounted || request != _routeDismissGestureGeneration) return;
      if (_dismissRequested) setState(() => _dismissRequested = false);
    });
  }

  void _onCompactPageChanged(int index) {
    if (_rightPane == PlayerRightPane.queue ||
        _queueTransitionActive ||
        index == _compactPage) {
      return;
    }
    final previous = _compactPage;
    setState(() {
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
    final pane = index == 0 ? PlayerLeftPane.cover : PlayerLeftPane.information;
    if (_leftPane == pane) return;
    setState(() {
      _leftPane = pane;
      _lastOperatedRegion = PlayerOperatedRegion.left;
    });
  }

  void _onWideRightPageChanged(int index) {
    final pane = index == 0 ? PlayerRightPane.lyrics : PlayerRightPane.controls;
    if (_rightPane == PlayerRightPane.queue || _rightPane == pane) return;
    setState(() {
      _rightPane = pane;
      _lastOperatedRegion = PlayerOperatedRegion.right;
    });
  }

  void _showLyrics() {
    setState(() {
      _rightPane = PlayerRightPane.lyrics;
      _lastOperatedRegion = PlayerOperatedRegion.right;
      if (_lastWasWide != true) _compactPage = 2;
    });
    _animateSemanticPage(
      wideController: _wideRightPageController,
      widePage: 0,
      compactPage: 2,
    );
  }

  void _showControls() {
    setState(() {
      _rightPane = PlayerRightPane.controls;
      _lastOperatedRegion = PlayerOperatedRegion.right;
      if (_lastWasWide != true) _compactPage = 1;
    });
    _animateSemanticPage(
      wideController: _wideRightPageController,
      widePage: 1,
      compactPage: 1,
    );
  }

  void _showCover() {
    setState(() {
      _leftPane = PlayerLeftPane.cover;
      _lastOperatedRegion = PlayerOperatedRegion.left;
      if (_lastWasWide != true) _compactPage = 1;
    });
    _animateSemanticPage(
      wideController: _wideLeftPageController,
      widePage: 0,
      compactPage: 1,
    );
  }

  void _animateSemanticPage({
    required PageController wideController,
    required int widePage,
    required int compactPage,
  }) {
    final request = ++_semanticTransitionGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _semanticTransitionGeneration) return;
      final controller = usesWidePlayerLayout(MediaQuery.sizeOf(context).width)
          ? wideController
          : _compactPageController;
      final page = identical(controller, _compactPageController)
          ? compactPage
          : widePage;
      if (!controller.hasClients) return;
      final currentPage = controller.page;
      if (currentPage != null && (currentPage - page).abs() < 0.001) return;
      final duration = _motionDuration(context);
      if (duration == Duration.zero) {
        controller.jumpToPage(page);
      } else {
        unawaited(() async {
          try {
            await controller.animateToPage(
              page,
              duration: duration,
              curve: Curves.easeOutCubic,
            );
          } catch (_) {
            // A newer page or queue request can detach this controller.
          }
        }());
      }
    });
  }

  void _showQueue({int? compactOriginPage}) {
    if (_lastWasWide == true) {
      if (_rightPane == PlayerRightPane.queue) return;
      _semanticTransitionGeneration++;
      _activateQueueState(compactOriginPage: compactOriginPage);
      return;
    }
    if (_rightPane == PlayerRightPane.queue &&
        _compactQueueTransitionController.value >= 1) {
      return;
    }
    _semanticTransitionGeneration++;
    _captureQueueOrigin(compactOriginPage: compactOriginPage);
    _settleCompactQueue(open: true, restoreOnClose: false);
  }

  void _activateQueueState({int? compactOriginPage}) {
    if (_rightPane == PlayerRightPane.queue) return;
    _captureQueueOrigin(compactOriginPage: compactOriginPage);
    setState(() {
      _rightPane = PlayerRightPane.queue;
    });
  }

  void _captureQueueOrigin({int? compactOriginPage}) {
    if (_queueReturnState != null || _rightPane == PlayerRightPane.queue) {
      return;
    }
    final controllerPage = _compactPageController.hasClients
        ? _compactPageController.page?.round()
        : null;
    final resolvedCompactPage =
        (compactOriginPage ?? controllerPage ?? _compactPage)
            .clamp(0, 2)
            .toInt();
    _queueReturnState = _PlayerQueueReturnState(
      compactPage: resolvedCompactPage,
      leftPane: _leftPane,
      rightPane: _rightPane,
      lastOperatedRegion: _lastOperatedRegion,
    );
  }

  void _closeQueue() {
    if (_lastWasWide == true) {
      if (_rightPane != PlayerRightPane.queue) return;
      _semanticTransitionGeneration++;
      _restoreQueueState();
      return;
    }
    if (_compactQueueTransitionController.value <= 0 &&
        _rightPane != PlayerRightPane.queue) {
      return;
    }
    _semanticTransitionGeneration++;
    _settleCompactQueue(
      open: false,
      restoreOnClose: _rightPane == PlayerRightPane.queue,
    );
  }

  void _restoreQueueState() {
    final returnState = _queueReturnState;
    if (_rightPane != PlayerRightPane.queue && returnState == null) return;
    final restored =
        returnState ??
        const _PlayerQueueReturnState(
          compactPage: 1,
          leftPane: PlayerLeftPane.cover,
          rightPane: PlayerRightPane.controls,
          lastOperatedRegion: PlayerOperatedRegion.right,
        );
    final restoredRight = restored.rightPane == PlayerRightPane.queue
        ? PlayerRightPane.controls
        : restored.rightPane;
    setState(() {
      _leftPane = restored.leftPane;
      _rightPane = restoredRight;
      _compactPage = restored.compactPage;
      _lastOperatedRegion = restored.lastOperatedRegion;
    });
    _queueReturnState = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (usesWidePlayerLayout(MediaQuery.sizeOf(context).width)) {
        if (_wideLeftPageController.hasClients) {
          _wideLeftPageController.jumpToPage(
            restored.leftPane == PlayerLeftPane.information ? 1 : 0,
          );
        }
        if (_wideRightPageController.hasClients) {
          _wideRightPageController.jumpToPage(
            restoredRight == PlayerRightPane.lyrics ? 0 : 1,
          );
        }
      } else if (_compactPageController.hasClients) {
        _compactPageController.jumpToPage(restored.compactPage);
      }
    });
  }

  void _settleCompactQueue({required bool open, required bool restoreOnClose}) {
    if (!mounted || _lastWasWide == true) return;
    final request = ++_queueTransitionGeneration;
    _queueDragActive = false;
    _compactQueueTransitionController.stop();
    if (!_queueTransitionActive) {
      setState(() => _queueTransitionActive = true);
    }
    final target = open ? 1.0 : 0.0;
    final remaining = (_compactQueueTransitionController.value - target).abs();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion || remaining <= 0.001
        ? Duration.zero
        : Duration(milliseconds: (260 * remaining).round().clamp(90, 260));

    unawaited(() async {
      try {
        if (duration == Duration.zero) {
          _compactQueueTransitionController.value = target;
        } else {
          await _compactQueueTransitionController.animateTo(
            target,
            duration: duration,
            curve: Curves.fastEaseInToSlowEaseOut,
          );
        }
      } catch (_) {
        return;
      }
      if (!mounted || request != _queueTransitionGeneration) return;
      if (open) {
        _activateQueueState();
      } else if (restoreOnClose || _rightPane == PlayerRightPane.queue) {
        _restoreQueueState();
      } else {
        _queueReturnState = null;
      }
      if (mounted) setState(() => _queueTransitionActive = false);
    }());
  }

  PlayerVerticalDragCallbacks _queueOpenDragCallbacks(int compactOriginPage) =>
      PlayerVerticalDragCallbacks(
        onStart: () => _beginQueueOpenDrag(compactOriginPage),
        onUpdate: (distance) => _updateQueueEdgeDrag(distance, opening: true),
        onEnd: _endQueueOpenDrag,
        onCancel: _cancelQueueOpenDrag,
      );

  PlayerVerticalDragCallbacks get _queueCloseDragCallbacks =>
      PlayerVerticalDragCallbacks(
        onStart: _beginQueueCloseDrag,
        onUpdate: (distance) => _updateQueueEdgeDrag(distance, opening: false),
        onEnd: _endQueueCloseDrag,
        onCancel: _cancelQueueCloseDrag,
      );

  void _beginQueueOpenDrag(int compactOriginPage) {
    if (!mounted ||
        _lastWasWide == true ||
        _queueDragActive ||
        _compactQueueTransitionController.value >= 1) {
      return;
    }
    _captureQueueOrigin(compactOriginPage: compactOriginPage);
    _semanticTransitionGeneration++;
    _queueTransitionGeneration++;
    _compactQueueTransitionController.stop();
    _queueDragActive = true;
    _queueDragOpening = true;
    _queueDragStartValue = _compactQueueTransitionController.value;
    if (!_queueTransitionActive) {
      setState(() => _queueTransitionActive = true);
    }
  }

  void _beginQueueCloseDrag() {
    if (!mounted ||
        _lastWasWide == true ||
        _queueDragActive ||
        _compactQueueTransitionController.value <= 0) {
      return;
    }
    _semanticTransitionGeneration++;
    _queueTransitionGeneration++;
    _compactQueueTransitionController.stop();
    _queueDragActive = true;
    _queueDragOpening = false;
    _queueDragStartValue = _compactQueueTransitionController.value;
    if (!_queueTransitionActive) {
      setState(() => _queueTransitionActive = true);
    }
  }

  void _updateQueueEdgeDrag(double distance, {required bool opening}) {
    if (!_queueDragActive || _queueDragOpening != opening) return;
    final delta = distance / _compactQueueExtent;
    _compactQueueTransitionController.value =
        (_queueDragStartValue + (opening ? delta : -delta)).clamp(0.0, 1.0);
  }

  void _endQueueOpenDrag(double distance, double velocity) {
    if (!_queueDragActive || !_queueDragOpening) return;
    _queueDragActive = false;
    final complete =
        _compactQueueTransitionController.value >= 0.22 || velocity < -650;
    _settleCompactQueue(
      open: complete,
      restoreOnClose: !complete && _rightPane == PlayerRightPane.queue,
    );
  }

  void _cancelQueueOpenDrag() {
    if (!_queueDragActive || !_queueDragOpening) return;
    _queueDragActive = false;
    final wasOpen = _rightPane == PlayerRightPane.queue;
    _settleCompactQueue(open: wasOpen, restoreOnClose: false);
  }

  void _endQueueCloseDrag(double distance, double velocity) {
    if (!_queueDragActive || _queueDragOpening) return;
    _queueDragActive = false;
    final close =
        _compactQueueTransitionController.value <= 0.78 || velocity > 650;
    _settleCompactQueue(
      open: !close,
      restoreOnClose: close && _rightPane == PlayerRightPane.queue,
    );
  }

  void _cancelQueueCloseDrag() {
    if (!_queueDragActive || _queueDragOpening) return;
    _queueDragActive = false;
    _settleCompactQueue(
      open: _rightPane == PlayerRightPane.queue,
      restoreOnClose: false,
    );
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  void _dismissPlayer() {
    if (!mounted || _dismissRequested) return;
    setState(() => _dismissRequested = true);
    _semanticTransitionGeneration++;
    _queueTransitionGeneration++;
    _compactQueueTransitionController.stop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(() async {
        final popped = await Navigator.of(context).maybePop();
        if (mounted && !popped) {
          setState(() => _dismissRequested = false);
        }
      }());
    });
  }

  void _handleBack() {
    if (_isLyricLocked) {
      _exitLyricFullscreen();
      return;
    }
    if (_rightPane == PlayerRightPane.queue ||
        (_lastWasWide != true &&
            _compactQueueTransitionController.value > 0.001)) {
      _closeQueue();
      return;
    }
    if (_lastWasWide == true) {
      if (_lastOperatedRegion == PlayerOperatedRegion.right &&
          _rightPane == PlayerRightPane.lyrics) {
        _showControls();
        return;
      }
      if (_lastOperatedRegion == PlayerOperatedRegion.left &&
          _leftPane == PlayerLeftPane.information) {
        _showCover();
        return;
      }
      if (_rightPane == PlayerRightPane.lyrics) {
        _showControls();
        return;
      }
      if (_leftPane == PlayerLeftPane.information) {
        _showCover();
        return;
      }
    } else {
      if (_compactPage == 0) {
        _showCover();
        return;
      }
      if (_compactPage == 2) {
        _showControls();
        return;
      }
    }
    Navigator.of(context).maybePop();
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
                child: PlayerInfoPanel(
                  track: track,
                  currentProgress: _currentProgress,
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
                  visibleActionCount: 5,
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

  void _openKnownWork(Work work) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => WorkDetailScreen(work: work),
      ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(S.of(context).noContentToSave)));
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
            if (track.workId != null && _currentWorkId != track.workId) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() {
                    _currentWorkId = track.workId;
                    _currentProgress = null;
                  });
                  _loadCurrentProgress(track.workId!);
                }
              });
            }

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
                  PlayerControlsWidget(
                    isLandscape: false,
                    isSeekingManually: _isSeekingManually,
                    seekValue: _seekValue,
                    onSeekChanged: _handleSeekChanged,
                    onSeekEnd: _handleSeekEnd,
                    seekingPosition: _seekingPosition,
                    workId: track.workId,
                    currentProgress: _currentProgress,
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
                ],
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(
            child: Text(S.of(context).errorWithMessage(error.toString())),
          ),
        ),
        if (_showLyricHint) _buildLyricHintBanner(),
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
        if (track.workId != null && _currentWorkId != track.workId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _currentWorkId = track.workId;
                _currentProgress = null;
              });
              _loadCurrentProgress(track.workId!);
            }
          });
        }

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
                        PlayerControlsWidget(
                          isLandscape: true,
                          isSeekingManually: _isSeekingManually,
                          seekValue: _seekValue,
                          onSeekChanged: _handleSeekChanged,
                          onSeekEnd: _handleSeekEnd,
                          seekingPosition: _seekingPosition,
                          workId: track.workId,
                          currentProgress: _currentProgress,
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
                      FullLyricDisplay(seekingPosition: _seekingPosition),
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

  Widget _buildTrackLoadingOverlay(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: colorScheme.surface.withValues(alpha: 0.18),
          child: Center(
            child: SizedBox(
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
          return const SizedBox.shrink();
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
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            savedPath != null
                                ? S.of(context).savedToSubtitleLibrary
                                : S.of(context).translatedLyricsNotSaved,
                          ),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(S.of(context).lyricTranslationFailed),
                          behavior: SnackBarBehavior.floating,
                        ),
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

  Widget _buildLyricHintBanner() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Consumer(
        builder: (context, ref, child) {
          final lyricState = ref.watch(lyricControllerProvider);
          if (lyricState.lyrics.isEmpty) {
            return const SizedBox.shrink();
          }

          return Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      S.of(context).lyricHintTapCover,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _showLyricHint = false;
                      });
                    },
                    icon: Icon(
                      Icons.close,
                      size: 18,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          );
        },
      ),
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
        if (mounted) {
          setState(() {
            _currentProgress = newProgress;
            _currentRating = newRating;
          });
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

        Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => WorkDetailScreen(work: work)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).loadFailedWithError(e.toString())),
          ),
        );
      }
    }
  }
}

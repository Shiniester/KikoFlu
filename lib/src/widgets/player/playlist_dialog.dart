import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/audio_tap_playlist_mode.dart';
import '../../models/audio_track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/artwork_theme_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/playback_session_store.dart';
import '../../utils/l10n_extensions.dart';
import '../responsive_dialog.dart';
import '../animated_menu_anchor.dart';
import 'player_glass_surface.dart';
import 'player_cover_widget.dart';
import 'player_action_icons.dart';
import 'player_vertical_gestures.dart';
import 'player_scroll_drag_handoff.dart';

const List<AudioTapPlaylistMode> _playlistModeMenuOrder = [
  AudioTapPlaylistMode.addToQueue,
  AudioTapPlaylistMode.playNext,
  AudioTapPlaylistMode.replaceQueue,
];

Future<bool> confirmClearPlaybackQueue(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => ResponsiveAlertDialog(
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
    this.scrollController,
    this.pageDragCoordinator,
    this.positionCurrentTrack = false,
    this.onCurrentTrackPositioned,
    this.showTitleBar = true,
    this.showFooter = true,
    this.showCloseButton = false,
    this.horizontalPadding = 8,
  });

  final VoidCallback? onClose;
  final VoidCallback? onTrackSelected;
  final Future<void> Function()? onClear;
  final VoidCallback? onDismissRequested;
  final PlayerVerticalDragCallbacks? dismissDrag;
  final ScrollController? scrollController;
  final PlayerScrollDragHandoffCoordinator? pageDragCoordinator;
  final bool positionCurrentTrack;
  final VoidCallback? onCurrentTrackPositioned;
  final bool showTitleBar;
  final bool showFooter;
  final bool showCloseButton;
  final double horizontalPadding;

  @override
  ConsumerState<PlayerQueueSurface> createState() => _PlayerQueueSurfaceState();
}

class _PlayerQueueSurfaceState extends ConsumerState<PlayerQueueSurface> {
  bool _positionScheduled = false;

  @override
  void didUpdateWidget(covariant PlayerQueueSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.positionCurrentTrack) _positionScheduled = false;
  }

  void _positionCurrentTrack(int currentIndex, double itemExtent) {
    if (!widget.positionCurrentTrack ||
        _positionScheduled ||
        currentIndex < 0) {
      return;
    }
    _positionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.positionCurrentTrack) return;
      final controller = widget.scrollController;
      if (controller == null || !controller.hasClients) return;
      final position = controller.position;
      final visibleRows = math.max(
        1,
        (position.viewportDimension / itemExtent).floor(),
      );
      final targetRow = (visibleRows * .4).ceil() - 1;
      controller.jumpTo(
        (8 + (currentIndex - targetRow) * itemExtent).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      widget.onCurrentTrackPositioned?.call();
    });
  }

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
    final trackMetadataHeight = _queueTrackMetadataHeight(context);
    final itemExtent = trackMetadataHeight + 16;
    _positionCurrentTrack(currentIndex, itemExtent);
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
    final queueList = KeyedSubtree(
      key: const PageStorageKey('player-queue-scroll'),
      child: tracks.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(S.of(context).playlistEmpty),
              ),
            )
          : ReorderableListView.builder(
              key: const ValueKey('player-queue-list'),
              scrollController: widget.scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              itemCount: tracks.length,
              itemExtent: itemExtent,
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
    );

    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showTitleBar)
            PlayerVerticalSwipeRegion(
              key: const ValueKey('player-queue-title-dismiss-surface'),
              onSwipeDown: widget.onDismissRequested,
              swipeDownDrag: widget.dismissDrag,
              pageDragCoordinator: widget.pageDragCoordinator,
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
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
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
            child: widget.pageDragCoordinator != null || tracks.isEmpty
                ? queueList
                : PlayerScrollEdgeActions(
                    onPullDownAtTop: widget.onDismissRequested,
                    pullDownDrag: widget.dismissDrag,
                    child: queueList,
                  ),
          ),
          if (widget.showFooter)
            _QueueFooter(horizontalPadding: widget.horizontalPadding),
        ],
      ),
    );
  }
}

class _QueueFooter extends StatelessWidget {
  const _QueueFooter({required this.horizontalPadding});

  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        12,
        horizontalPadding,
        16,
      ),
      child: const Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _RepeatModePill(),
            ),
          ),
          SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: PlaylistModePill(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Browse the live queue and saved queue snapshots from the player page.
class PlayerQueueBrowser extends ConsumerStatefulWidget {
  const PlayerQueueBrowser({
    super.key,
    this.isActive = true,
    this.initialQueueHistory = false,
    this.onInitialHistorySelected,
    this.onTrackSelected,
    this.onClear,
    this.onDismissRequested,
    this.dismissDrag,
    this.pageDragCoordinator,
    this.showPageButtons = false,
    this.horizontalPadding = 8,
    this.contentWidth,
  });

  final bool isActive;
  final bool initialQueueHistory;
  final VoidCallback? onInitialHistorySelected;
  final VoidCallback? onTrackSelected;
  final Future<void> Function()? onClear;
  final VoidCallback? onDismissRequested;
  final PlayerVerticalDragCallbacks? dismissDrag;
  final PlayerScrollDragHandoffCoordinator? pageDragCoordinator;
  final bool showPageButtons;
  final double horizontalPadding;
  final double? contentWidth;

  @override
  ConsumerState<PlayerQueueBrowser> createState() => _PlayerQueueBrowserState();
}

class _QueueBrowserPage {
  _QueueBrowserPage(this.snapshot, this.scrollController);

  PlaybackSessionSnapshot? snapshot;
  ScrollController scrollController;
}

class _PlayerQueueBrowserState extends ConsumerState<PlayerQueueBrowser> {
  final PageController _pageController = PageController();
  final List<_QueueBrowserPage> _pages = [];
  int _currentPage = 0;
  int? _restoringHistoryIndex;
  int? _restoringTrackIndex;
  ({PlaybackSessionSnapshot snapshot, int index})? _removingHistoricalTrack;
  int _restoreGeneration = 0;
  bool _initialPageScheduled = false;
  bool _initialPageSelected = false;
  bool _reorderOnEntry = true;
  bool _positionCurrentOnEntry = true;
  _QueueBrowserPage? _restoredPage;

  @override
  void initState() {
    super.initState();
    _initialPageSelected = !widget.initialQueueHistory;
  }

  @override
  void didUpdateWidget(covariant PlayerQueueBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _reorderOnEntry = true;
      _positionCurrentOnEntry = true;
    }
    if (!identical(oldWidget.pageDragCoordinator, widget.pageDragCoordinator)) {
      for (final page in _pages) {
        final previous = page.scrollController;
        page.scrollController = _createScrollController(
          initialScrollOffset: previous.hasClients
              ? previous.offset
              : previous.initialScrollOffset,
        );
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final page in _pages) {
      page.scrollController.dispose();
    }
    super.dispose();
  }

  ScrollController _createScrollController({double initialScrollOffset = 0}) {
    final coordinator = widget.pageDragCoordinator;
    return coordinator == null
        ? ScrollController(initialScrollOffset: initialScrollOffset)
        : PlayerScrollDragHandoffController(
            coordinator: coordinator,
            initialScrollOffset: initialScrollOffset,
            debugLabel: 'player-queue',
          );
  }

  void _removePage(_QueueBrowserPage page) {
    _pages.remove(page);
    final controller = page.scrollController;
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }

  void _updatePages(List<PlaybackSessionSnapshot> history) {
    if (_pages.isEmpty) {
      _pages.add(_QueueBrowserPage(null, _createScrollController()));
    }
    final viewedPage = _pages[_currentPage];
    final restoredPage = _restoredPage;
    if (restoredPage != null) {
      final restoredSnapshot = restoredPage.snapshot!;
      if (history.any((item) => item.isSameQueue(restoredSnapshot))) return;
      final outgoingPage = _pages.firstWhere((page) => page.snapshot == null);
      final outgoingSnapshots = history.where(
        (snapshot) => !_pages.any(
          (page) =>
              page.snapshot != null && page.snapshot!.isSameQueue(snapshot),
        ),
      );
      if (outgoingSnapshots.isEmpty) {
        _removePage(outgoingPage);
      } else {
        outgoingPage.snapshot = outgoingSnapshots.first;
      }
      restoredPage.snapshot = null;
      _restoredPage = null;
      _restoringHistoryIndex = null;
      _restoringTrackIndex = null;
    } else if (_restoringHistoryIndex != null) {
      return;
    }

    final remaining = history.toList();
    for (final page in _pages.toList()) {
      final snapshot = page.snapshot;
      if (snapshot == null) continue;
      final index = remaining.indexWhere((item) => item.isSameQueue(snapshot));
      if (index < 0) {
        _removePage(page);
      } else {
        page.snapshot = remaining.removeAt(index);
      }
    }
    for (final snapshot in remaining) {
      final historyIndex = history.indexOf(snapshot);
      final nextIndex = _pages.indexWhere(
        (page) =>
            page.snapshot != null &&
            history.indexWhere((item) => item.isSameQueue(page.snapshot!)) >
                historyIndex,
      );
      _pages.insert(
        nextIndex < 0 ? _pages.length : nextIndex,
        _QueueBrowserPage(snapshot, _createScrollController()),
      );
    }
    if (_reorderOnEntry) {
      final livePage = _pages.firstWhere((page) => page.snapshot == null);
      final ordered = [
        livePage,
        for (final snapshot in history)
          _pages.firstWhere(
            (page) =>
                page.snapshot != null && page.snapshot!.isSameQueue(snapshot),
          ),
      ];
      _pages
        ..clear()
        ..addAll(ordered);
      _reorderOnEntry = false;
      _selectPageAfterLayout(0);
    } else {
      final index = _pages.indexOf(viewedPage);
      final target = index < 0
          ? _pages.indexWhere((page) => page.snapshot == null)
          : index;
      if (target != _currentPage) _selectPageAfterLayout(target);
    }
  }

  void _selectPageAfterLayout(int page) {
    _currentPage = page;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToPage(_currentPage);
    });
  }

  void _scheduleInitialHistoryPage() {
    if (_initialPageScheduled || _initialPageSelected) return;
    _initialPageScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialPageScheduled = false;
      if (!mounted || !_pageController.hasClients) return;
      _initialPageSelected = true;
      _jumpToPage(1);
      widget.onInitialHistorySelected?.call();
    });
  }

  void _setSettledPage(int page) {
    if (_currentPage == page) return;
    setState(() => _currentPage = page);
  }

  void _jumpToPage(int page) {
    if (_pageController.hasClients) _pageController.jumpToPage(page);
    _setSettledPage(page);
  }

  Future<void> _goToPage(int page) async {
    if (!_pageController.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _jumpToPage(page);
      return;
    }
    await _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.ease,
    );
  }

  bool _handlePageScrollEnd(ScrollEndNotification notification) {
    if (notification.depth != 0 || !_pageController.hasClients) return false;
    final page = _pageController.page;
    if (page != null && (page - page.round()).abs() < 0.001) {
      _setSettledPage(page.round());
    }
    return false;
  }

  Future<void> _clearHistoricalQueue(PlaybackSessionSnapshot snapshot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ResponsiveAlertDialog(
        title: Text(S.of(dialogContext).playbackQueueHistory),
        content: Text(S.of(dialogContext).clearHistoricalPlaybackQueueMessage),
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
    );
    if (confirmed != true || !mounted) return;
    try {
      final cleared = await ref
          .read(audioPlayerControllerProvider.notifier)
          .clearHistoricalQueue(snapshot);
      if (cleared && mounted) {
        _jumpToPage(_pages.indexWhere((page) => page.snapshot == null));
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).errorWithMessage(error.toString())),
        ),
      );
    }
  }

  Future<void> _removeHistoricalTrack(
    PlaybackSessionSnapshot snapshot,
    int index,
  ) async {
    if (_removingHistoricalTrack != null || _restoringHistoryIndex != null) {
      return;
    }
    setState(
      () => _removingHistoricalTrack = (snapshot: snapshot, index: index),
    );
    try {
      await ref
          .read(audioPlayerControllerProvider.notifier)
          .removeHistoricalTrackAt(snapshot, index);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).errorWithMessage(error.toString())),
        ),
      );
    } finally {
      if (mounted) setState(() => _removingHistoricalTrack = null);
    }
  }

  Future<void> _restoreHistoricalTrack(
    PlaybackSessionSnapshot snapshot,
    int trackIndex,
  ) async {
    if (_removingHistoricalTrack != null) return;
    if (_restoredPage != null) {
      _updatePages(ref.read(audioPlayerServiceProvider).historicalQueues);
    }
    final pageIndex = _pages.indexWhere(
      (page) => page.snapshot != null && page.snapshot!.isSameQueue(snapshot),
    );
    if (pageIndex < 0) return;
    final page = _pages[pageIndex];
    final generation = ++_restoreGeneration;
    setState(() {
      _restoringHistoryIndex = pageIndex - 1;
      _restoringTrackIndex = trackIndex;
      _restoredPage = null;
      _positionCurrentOnEntry = false;
    });
    try {
      final restored = await ref
          .read(audioPlayerControllerProvider.notifier)
          .restoreHistoricalQueue(snapshot, trackIndex);
      if (!mounted || generation != _restoreGeneration) return;
      if (restored) _restoredPage = page;
    } catch (error) {
      if (!mounted || generation != _restoreGeneration) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).errorWithMessage(error.toString())),
        ),
      );
    } finally {
      if (mounted && generation == _restoreGeneration) {
        setState(() {
          if (_restoredPage == null) {
            _restoringHistoryIndex = null;
            _restoringTrackIndex = null;
          }
        });
      }
    }
  }

  Widget _buildHeader(
    BuildContext context, {
    required int pageCount,
    required List<AudioTrack> currentQueue,
    required PlaybackSessionSnapshot? historicalQueue,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final position = S
        .of(context)
        .queueBrowserPagePosition(pageCount - _currentPage, pageCount);
    final showClearButton =
        historicalQueue != null ||
        (currentQueue.isNotEmpty && widget.onClear != null);
    final titleSidePadding = widget.horizontalPadding == 10
        ? 0.0
        : widget.horizontalPadding;
    final titleSideWidth = widget.horizontalPadding == 10 ? 78.0 : 68.0;
    final clearButton = TextButton(
      key: const ValueKey('player-queue-clear-button'),
      onPressed: historicalQueue == null
          ? widget.onClear
          : () => _clearHistoricalQueue(historicalQueue),
      style: TextButton.styleFrom(
        foregroundColor: colorScheme.onSurfaceVariant,
        padding: widget.horizontalPadding == 10
            ? const EdgeInsets.symmetric(horizontal: 10)
            : EdgeInsets.zero,
        minimumSize: widget.horizontalPadding == 10
            ? Size.zero
            : const Size(48, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        alignment: widget.horizontalPadding == 10
            ? Alignment.center
            : Alignment.centerRight,
      ),
      child: Text(
        S.of(context).clear,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );

    return PlayerVerticalSwipeRegion(
      key: const ValueKey('player-queue-title-dismiss-surface'),
      onSwipeDown: widget.onDismissRequested,
      swipeDownDrag: widget.dismissDrag,
      pageDragCoordinator: widget.pageDragCoordinator,
      child: Padding(
        key: const ValueKey('player-queue-title-bar'),
        padding: EdgeInsets.fromLTRB(titleSidePadding, 8, titleSidePadding, 10),
        child: KeyedSubtree(
          key: const ValueKey('player-queue-browser-header'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                if (widget.showPageButtons)
                  IconButton(
                    key: const ValueKey('player-queue-history-previous-button'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).previousPageTooltip,
                    onPressed: _currentPage >= pageCount - 1
                        ? null
                        : () => _goToPage(_currentPage + 1),
                    icon: const Icon(Icons.arrow_back),
                  ),
                SizedBox(
                  width: titleSideWidth,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: widget.horizontalPadding == 10 ? 10 : 0,
                    ),
                    child: Text(
                      '${pageCount - _currentPage} / $pageCount',
                      key: const ValueKey('player-queue-browser-page-position'),
                      semanticsLabel: position,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    S.of(context).playlistTitle,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SizedBox(
                  width: titleSideWidth,
                  child: showClearButton
                      ? Align(
                          alignment: Alignment.centerRight,
                          child: widget.horizontalPadding == 10
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
                        )
                      : null,
                ),
                if (widget.showPageButtons)
                  IconButton(
                    key: const ValueKey('player-queue-history-next-button'),
                    tooltip: MaterialLocalizations.of(context).nextPageTooltip,
                    onPressed: _currentPage == 0
                        ? null
                        : () => _goToPage(_currentPage - 1),
                    icon: const Icon(Icons.arrow_forward),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryPage(
    BuildContext context, {
    required PlaybackSessionSnapshot snapshot,
    required int historyIndex,
    required AuthState authState,
    required ScrollController scrollController,
  }) {
    final trackMetadataHeight = _queueTrackMetadataHeight(context);
    final pendingRemoval = _removingHistoricalTrack;
    Widget trackList = snapshot.queue.isEmpty
        ? Center(child: Text(S.of(context).playlistEmpty))
        : ListView.builder(
            key: const PageStorageKey('player-queue-scroll'),
            controller: scrollController,
            padding: const EdgeInsets.symmetric(vertical: 8),
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            itemCount: snapshot.queue.length,
            itemExtent: trackMetadataHeight + 16,
            itemBuilder: (context, index) {
              final track = snapshot.queue[index];
              return KeyedSubtree(
                key: ValueKey('player-queue-history-track-${track.id}'),
                child: _QueueTrackTile(
                  track: track,
                  horizontalPadding: widget.horizontalPadding,
                  coverUrl: _resolveCoverUrl(
                    track,
                    host: authState.host,
                    token: authState.token,
                  ),
                  isCurrentTrack: false,
                  metadataHeight: trackMetadataHeight,
                  isLoading:
                      (_restoringHistoryIndex == historyIndex &&
                          _restoringTrackIndex == index) ||
                      (pendingRemoval?.snapshot.isSameQueue(snapshot) == true &&
                          pendingRemoval?.index == index),
                  onTap: pendingRemoval != null
                      ? null
                      : () => _restoreHistoricalTrack(snapshot, index),
                  onRemove:
                      pendingRemoval != null || _restoringHistoryIndex != null
                      ? null
                      : () => _removeHistoricalTrack(snapshot, index),
                ),
              );
            },
          );
    if (snapshot.queue.isNotEmpty && widget.pageDragCoordinator == null) {
      trackList = PlayerScrollEdgeActions(
        onPullDownAtTop: widget.onDismissRequested,
        pullDownDrag: widget.dismissDrag,
        child: trackList,
      );
    }

    return KeyedSubtree(
      key: ValueKey('player-queue-history-page-$historyIndex'),
      child: trackList,
    );
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(historicalQueuesProvider);
    final history =
        historyAsync.valueOrNull ?? const <PlaybackSessionSnapshot>[];
    _updatePages(history);
    final pageCount = _pages.length;
    if (widget.initialQueueHistory && history.isNotEmpty) {
      _scheduleInitialHistoryPage();
    }
    final queueAsync = ref.watch(queueProvider);
    final currentQueue =
        queueAsync.valueOrNull ?? ref.read(audioPlayerServiceProvider).queue;
    final authState = ref.watch(authProvider);

    return RepaintBoundary(
      key: const ValueKey('player-queue-browser'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: SizedBox(
              width: widget.contentWidth,
              child: _buildHeader(
                context,
                pageCount: pageCount,
                currentQueue: currentQueue,
                historicalQueue: _pages[_currentPage].snapshot,
              ),
            ),
          ),
          if (widget.initialQueueHistory && historyAsync.isLoading)
            const LinearProgressIndicator(),
          if (historyAsync.hasError)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                S.of(context).errorWithMessage(historyAsync.error.toString()),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: NotificationListener<ScrollEndNotification>(
              onNotification: _handlePageScrollEnd,
              child: PageView.builder(
                key: const ValueKey('player-queue-history-content'),
                controller: _pageController,
                reverse: true,
                itemCount: pageCount,
                findChildIndexCallback: (key) {
                  final index = _pages.indexWhere(
                    (page) => PageStorageKey(page) == key,
                  );
                  return index < 0 ? null : index;
                },
                itemBuilder: (context, index) => Center(
                  key: PageStorageKey(_pages[index]),
                  child: SizedBox(
                    key: _pages[index].snapshot == null
                        ? const ValueKey('player-queue-width-boundary')
                        : null,
                    width: widget.contentWidth,
                    height: double.infinity,
                    child: _pages[index].snapshot == null
                        ? PlayerQueueSurface(
                            showTitleBar: false,
                            showFooter: false,
                            onTrackSelected: widget.onTrackSelected,
                            onClear: widget.onClear,
                            onDismissRequested: widget.onDismissRequested,
                            dismissDrag: widget.dismissDrag,
                            scrollController: _pages[index].scrollController,
                            positionCurrentTrack:
                                widget.isActive && _positionCurrentOnEntry,
                            onCurrentTrackPositioned: () {
                              _positionCurrentOnEntry = false;
                            },
                            pageDragCoordinator: widget.pageDragCoordinator,
                            horizontalPadding: widget.horizontalPadding,
                          )
                        : _buildHistoryPage(
                            context,
                            snapshot: _pages[index].snapshot!,
                            historyIndex: index - 1,
                            authState: authState,
                            scrollController: _pages[index].scrollController,
                          ),
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: SizedBox(
              width: widget.contentWidth,
              child: _QueueFooter(horizontalPadding: widget.horizontalPadding),
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
    this.isLoading = false,
  });

  final AudioTrack track;
  final String? coverUrl;
  final bool isCurrentTrack;
  final double horizontalPadding;
  final double metadataHeight;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final bool isLoading;

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
                    if (isLoading)
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (onRemove != null)
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
    // Decode queue covers for their physical display size instead of uploading
    // several full-resolution images together during the route transition.
    return PlayerCompactArtwork(
      track: track,
      url: url,
      decodeSize:
          const Size(PlayerCompactArtwork.width, PlayerCompactArtwork.height) *
          MediaQuery.devicePixelRatioOf(context),
    );
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
}) => resolveArtworkSource(
  workId: track.workId,
  artworkUrl: track.artworkUrl,
  host: host ?? '',
  token: token ?? '',
);

double _queueTrackMetadataHeight(BuildContext context) {
  final theme = Theme.of(context);
  final colorScheme = theme.colorScheme;
  return _reservedQueueMetadataHeight(
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
    final label = mode.localizedName(context);
    return _QueueModePill(
      semanticsLabel: '${S.of(context).audioTapPlaylistMode}: $label',
      label: label,
      surfaceKey: const ValueKey('playlist-mode-pill'),
      tapTargetKey: const ValueKey('playlist-mode-pill-tap-target'),
      onTap: () =>
          ref.read(audioTapPlaylistModeProvider.notifier).updateMode(nextMode),
    );
  }
}

class _RepeatModePill extends ConsumerWidget {
  const _RepeatModePill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(
      audioPlayerControllerProvider.select((state) => state.repeatMode),
    );
    final label = switch (mode) {
      LoopMode.off => S.of(context).repeatSequentialQueuePlayback,
      LoopMode.one => S.of(context).repeatSingleTrackPlayback,
      LoopMode.all => S.of(context).repeatQueuePlayback,
    };
    final nextMode = switch (mode) {
      LoopMode.off => LoopMode.one,
      LoopMode.one => LoopMode.all,
      LoopMode.all => LoopMode.off,
    };
    return _QueueModePill(
      semanticsLabel: '${S.of(context).repeatMode}: $label',
      label: label,
      surfaceKey: const ValueKey('repeat-mode-pill'),
      tapTargetKey: const ValueKey('repeat-mode-pill-tap-target'),
      onTap: () => ref
          .read(audioPlayerControllerProvider.notifier)
          .setRepeatMode(nextMode),
    );
  }
}

class _QueueModePill extends StatelessWidget {
  const _QueueModePill({
    required this.semanticsLabel,
    required this.label,
    required this.surfaceKey,
    required this.tapTargetKey,
    required this.onTap,
  });

  final String semanticsLabel;
  final String label;
  final Key surfaceKey;
  final Key tapTargetKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: SizedBox(
        key: tapTargetKey,
        height: 48,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            PlayerGlassSurface(
              key: surfaceKey,
              borderRadius: BorderRadius.circular(999),
              borderColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
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
    return AnimatedMenuAnchor(
      menuStyle: const MenuStyle(
        alignment: AlignmentDirectional.bottomEnd,
        maximumSize: WidgetStatePropertyAll(Size(360, double.infinity)),
      ),
      crossAxisUnconstrained: false,
      menuChildren: [
        for (final option in _playlistModeMenuOrder)
          Semantics(
            selected: option == mode,
            child: MenuItemButton(
              autofocus: option == mode,
              style: AnimatedMenuAnchor.selectedItemStyle(
                context,
                option == mode,
              ),
              onPressed: () {
                ref
                    .read(audioTapPlaylistModeProvider.notifier)
                    .updateMode(option);
              },
              child: Text(
                option.localizedName(context),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip:
            '${S.of(context).audioTapPlaylistMode}: ${mode.localizedName(context)}',
        icon: Icon(modeIcon(mode)),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
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

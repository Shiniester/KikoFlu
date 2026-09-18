import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/works_provider.dart';
import '../utils/scroll_optimization.dart';
import '../widgets/sort_dialog.dart';
import '../widgets/works_grid_view.dart';
import '../widgets/virtualized_sliver_collection.dart';
import '../utils/snackbar_util.dart';
import '../widgets/floating_feed_toolbar.dart';
import '../../l10n/app_localizations.dart';
import '../widgets/download_fab.dart';
import '../models/sort_options.dart';
import '../utils/subtitle_filter.dart';
import '../utils/l10n_extensions.dart';
import '../utils/system_ui_style.dart';
import '../utils/ui_tokens.dart';
import '../widgets/async_state_view.dart';

class WorksScreen extends ConsumerStatefulWidget {
  const WorksScreen({super.key});

  @override
  ConsumerState<WorksScreen> createState() => _WorksScreenState();
}

class _WorksScreenState extends ConsumerState<WorksScreen>
    with AutomaticKeepAliveClientMixin {
  int _slideDirection = 0;
  int _displayGeneration = 0;
  final Map<DisplayMode, double> _scrollPositions = {
    for (final mode in DisplayMode.values) mode: 0.0,
  };

  @override
  bool get wantKeepAlive => true; // 保持状态不被销毁

  @override
  void initState() {
    super.initState();
    // 只在首次加载时获取数据，如果已有数据则不重新加载
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final worksState = ref.read(worksProvider);
      if (worksState.works.isEmpty) {
        ref.read(worksProvider.notifier).loadWorks(refresh: true);
      }
    });
  }

  void _showSortDialog(BuildContext context) {
    final displayMode = ref.read(worksProvider).displayMode;
    final isRecommendMode =
        displayMode == DisplayMode.popular ||
        displayMode == DisplayMode.recommended;

    if (isRecommendMode) {
      SnackBarUtil.showInfo(
        context,
        displayMode == DisplayMode.popular
            ? S.of(context).popularNoSort
            : S.of(context).recommendedNoSort,
      );
      return;
    }

    final state = ref.read(worksProvider);
    showDialog(
      context: context,
      builder: (context) => CommonSortDialog(
        currentOption: state.sortOption,
        currentDirection: state.sortDirection,
        availableOptions: SortOrder.values
            .where((option) => option != SortOrder.updatedAt)
            .toList(),
        onSort: (option, direction) {
          ref.read(worksProvider.notifier).setSortOption(option);
          ref.read(worksProvider.notifier).setSortDirection(direction);
        },
        autoClose: true,
      ),
    );
  }

  IconData _getLayoutIcon(LayoutType layoutType) {
    switch (layoutType) {
      case LayoutType.bigGrid:
        return Icons.grid_3x3;
      case LayoutType.smallGrid:
        return Icons.view_list;
      case LayoutType.list:
        return Icons.view_agenda;
    }
  }

  String _getLayoutTooltip(LayoutType layoutType) {
    switch (layoutType) {
      case LayoutType.bigGrid:
        return S.of(context).switchToSmallGrid;
      case LayoutType.smallGrid:
        return S.of(context).switchToList;
      case LayoutType.list:
        return S.of(context).switchToLargeGrid;
    }
  }

  IconData _getSubtitleFilterIcon(int subtitleFilter) {
    final mode = SubtitleFilterMode.fromValue(subtitleFilter);
    return mode == SubtitleFilterMode.withSubtitles
        ? Icons.closed_caption
        : Icons.closed_caption_disabled;
  }

  void _changeDisplayMode(DisplayMode mode) {
    final currentMode = ref.read(worksProvider).displayMode;
    if (currentMode == mode) return;
    ref.read(worksProvider.notifier).setDisplayMode(mode);
  }

  void _handleSwipe(DragEndDetails details) {
    if (details.primaryVelocity == null) return;

    final velocity = details.primaryVelocity!;
    final worksState = ref.read(worksProvider);

    // Sensitivity threshold
    if (velocity.abs() < 500) return;

    if (velocity < 0) {
      // Swipe Left (Next Tab)
      if (worksState.displayMode == DisplayMode.all) {
        _changeDisplayMode(DisplayMode.popular);
      } else if (worksState.displayMode == DisplayMode.popular) {
        _changeDisplayMode(DisplayMode.recommended);
      }
    } else {
      // Swipe Right (Previous Tab)
      if (worksState.displayMode == DisplayMode.recommended) {
        _changeDisplayMode(DisplayMode.popular);
      } else if (worksState.displayMode == DisplayMode.popular) {
        _changeDisplayMode(DisplayMode.all);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // 必须调用以保持状态
    ref.listen<WorksState>(worksProvider, (previous, next) {
      if (!mounted) return;
      if (previous == null) return;
      if (previous.displayMode == next.displayMode) return;

      final prevIndex = DisplayMode.values.indexOf(previous.displayMode);
      final nextIndex = DisplayMode.values.indexOf(next.displayMode);

      setState(() {
        _slideDirection = nextIndex >= prevIndex ? 1 : -1;
        _displayGeneration++;
      });
    });
    final worksState = ref.watch(worksProvider);
    final isRecommendMode =
        worksState.displayMode == DisplayMode.popular ||
        worksState.displayMode == DisplayMode.recommended;

    final horizontalPadding = FloatingToolbarLayout.horizontalPadding(context);
    final topPadding = MediaQuery.paddingOf(context).top;
    final toolbarTop = topPadding + 8;
    final contentTopPadding = toolbarTop + 56;
    final displayGeneration = _displayGeneration;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final systemOverlayStyle = transparentSystemBarsForBrightness(
      Theme.of(context).brightness,
    );

    return AnnotatedRegion(
      value: systemOverlayStyle,
      child: Scaffold(
        floatingActionButton: const DownloadFab(),
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onHorizontalDragEnd: _handleSwipe,
                child: AnimatedSwitcher(
                  duration: reduceMotion
                      ? const Duration(milliseconds: 200)
                      : const Duration(milliseconds: 250),
                  switchInCurve: Curves.linear,
                  switchOutCurve: Curves.linear,
                  transitionBuilder: (child, animation) {
                    return _WorksModeTransition(
                      animation: animation,
                      direction: _slideDirection,
                      reduceMotion: MediaQuery.disableAnimationsOf(context),
                      child: child,
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey(
                      '${worksState.displayMode.name}-$_displayGeneration',
                    ),
                    child: _WorksModeView(
                      worksState: worksState,
                      initialScrollOffset:
                          _scrollPositions[worksState.displayMode] ?? 0,
                      onScrollOffsetChanged: (offset) {
                        if (displayGeneration == _displayGeneration) {
                          _scrollPositions[worksState.displayMode] = offset;
                        }
                      },
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        contentTopPadding,
                        horizontalPadding,
                        horizontalPadding,
                      ),
                      generation: displayGeneration,
                      builder: _buildLayoutView,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ProgressiveTopScrim(height: topPadding + 72),
            ),
            Positioned(
              top: toolbarTop,
              left: horizontalPadding,
              right: horizontalPadding,
              child: FloatingFeedToolbar(
                collapseModesWhenNeeded: false,
                modeActions: _buildModeActions(context, worksState),
                toolActions: _buildToolActions(
                  context,
                  worksState,
                  isRecommendMode: isRecommendMode,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<FloatingFeedModeAction> _buildModeActions(
    BuildContext context,
    WorksState worksState,
  ) {
    return [
      FloatingFeedModeAction(
        icon: Icons.grid_view,
        label: S.of(context).displayModeAll,
        isSelected: worksState.displayMode == DisplayMode.all,
        onPressed: () => _changeDisplayMode(DisplayMode.all),
      ),
      FloatingFeedModeAction(
        icon: Icons.local_fire_department,
        label: S.of(context).displayModePopular,
        isSelected: worksState.displayMode == DisplayMode.popular,
        onPressed: () => _changeDisplayMode(DisplayMode.popular),
      ),
      FloatingFeedModeAction(
        icon: Icons.auto_awesome,
        label: S.of(context).displayModeRecommended,
        isSelected: worksState.displayMode == DisplayMode.recommended,
        onPressed: () => _changeDisplayMode(DisplayMode.recommended),
      ),
    ];
  }

  List<FloatingFeedToolAction> _buildToolActions(
    BuildContext context,
    WorksState worksState, {
    required bool isRecommendMode,
  }) {
    final subtitleMode = SubtitleFilterMode.fromValue(
      worksState.subtitleFilter,
    );
    return [
      FloatingFeedToolAction(
        icon: _getLayoutIcon(worksState.layoutType),
        tooltip: _getLayoutTooltip(worksState.layoutType),
        onPressed: () => ref.read(worksProvider.notifier).toggleLayoutType(),
      ),
      FloatingFeedToolAction(
        icon: _getSubtitleFilterIcon(worksState.subtitleFilter),
        tooltip: subtitleMode.localizedTooltip(context),
        isSelected: subtitleMode.isActive,
        onPressed: () =>
            ref.read(worksProvider.notifier).toggleSubtitleFilter(),
      ),
      FloatingFeedToolAction(
        icon: Icons.sort,
        tooltip: isRecommendMode
            ? S.of(context).recommendedNoSort
            : S.of(context).sort,
        onPressed: isRecommendMode ? null : () => _showSortDialog(context),
      ),
    ];
  }

  Widget _buildLayoutView(
    WorksState worksState,
    EdgeInsetsGeometry padding,
    ScrollController scrollController,
    int generation,
  ) {
    final notifier = ref.read(worksProvider.notifier);
    bool isActive() =>
        mounted &&
        generation == _displayGeneration &&
        ref.read(worksProvider).displayMode == worksState.displayMode;
    Future<void> guarded(Future<void> Function() action) async {
      if (!isActive()) return;
      await action();
    }

    void guardedRefresh() {
      if (isActive()) unawaited(notifier.refresh());
    }

    return WorksGridView(
      works: worksState.works,
      layoutType: worksState.layoutType,
      scrollController: scrollController,
      padding: padding,
      physics: ScrollOptimization.physics,
      isLoading: worksState.isLoading,
      isRefreshing: worksState.isLoading && worksState.works.isNotEmpty,
      isLoadingMore: worksState.isLoadingMore,
      hasMore: worksState.hasMore,
      error: worksState.error,
      loadMoreError: null,
      onLoadMore: worksState.displayMode == DisplayMode.all
          ? null
          : () => guarded(notifier.loadMore),
      onRetry: guardedRefresh,
      onRefresh: worksState.works.isEmpty
          ? null
          : () => guarded(notifier.refresh),
      pagination: worksState.displayMode == DisplayMode.all
          ? VirtualizedPagination(
              currentPage: worksState.currentPage,
              pageSize: worksState.pageSize,
              totalCount: worksState.totalCount,
              hasMore: worksState.hasMore,
              isLoading: worksState.isLoading || worksState.isRefreshing,
              onPreviousPage: () => guarded(notifier.previousPage),
              onNextPage: () => guarded(notifier.nextPage),
              onGoToPage: (page) => guarded(() => notifier.goToPage(page)),
              nextPageOnOverscroll: true,
              scrollDuration: UiMotion.travel,
              scrollCurve: UiMotion.curve,
              extraBuilder: worksState.rawWorks.length > worksState.works.length
                  ? (context) => Text(
                      S
                          .of(context)
                          .pageExcludedNWorks(
                            worksState.rawWorks.length -
                                worksState.works.length,
                          ),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    )
                  : null,
            )
          : null,
      showEndMessage:
          worksState.displayMode != DisplayMode.all && worksState.isLastPage,
      loadingBuilder: (context) => AsyncStateView(
        icon: const CircularProgressIndicator(),
        message: Text(S.of(context).loading),
        iconToTitleSpacing: UiSpacing.large,
      ),
      errorBuilder: (context, error, retry) => AsyncStateView(
        icon: Icon(
          Icons.error_outline,
          size: 64,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(
          S.of(context).loadFailed,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        message: Text(
          error.toString(),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        action: ElevatedButton.icon(
          onPressed: retry,
          icon: const Icon(Icons.refresh),
          label: Text(S.of(context).retry),
        ),
      ),
      emptyBuilder: (context) => AsyncStateView(
        icon: Icon(
          Icons.audiotrack,
          size: 64,
          color: Theme.of(context).colorScheme.outline,
        ),
        title: Text(
          S.of(context).noWorks,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        message: Text(
          S.of(context).checkNetworkOrRetry,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      endBuilder: (context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  S.of(context).reachedEnd,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            if (worksState.rawWorks.length > worksState.works.length) ...[
              const SizedBox(height: 8),
              Text(
                S
                    .of(context)
                    .excludedNWorks(
                      worksState.rawWorks.length - worksState.works.length,
                    ),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorksModeView extends StatefulWidget {
  const _WorksModeView({
    required this.worksState,
    required this.initialScrollOffset,
    required this.onScrollOffsetChanged,
    required this.padding,
    required this.generation,
    required this.builder,
  });

  final WorksState worksState;
  final double initialScrollOffset;
  final ValueChanged<double> onScrollOffsetChanged;
  final EdgeInsetsGeometry padding;
  final int generation;
  final Widget Function(
    WorksState worksState,
    EdgeInsetsGeometry padding,
    ScrollController controller,
    int generation,
  )
  builder;

  @override
  State<_WorksModeView> createState() => _WorksModeViewState();
}

class _WorksModeViewState extends State<_WorksModeView> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialScrollOffset.clamp(
        0.0,
        double.infinity,
      ),
      keepScrollOffset: false,
    );
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final maxExtent = _scrollController.position.maxScrollExtent;
      final target = widget.initialScrollOffset
          .clamp(0.0, maxExtent.isFinite ? maxExtent : 0.0)
          .toDouble();
      if ((_scrollController.offset - target).abs() > 0.5) {
        _scrollController.jumpTo(target);
      }
    });
  }

  void _handleScroll() {
    if (_scrollController.hasClients) {
      widget.onScrollOffsetChanged(_scrollController.offset);
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(
      widget.worksState,
      widget.padding,
      _scrollController,
      widget.generation,
    );
  }
}

class _WorksModeTransition extends StatefulWidget {
  const _WorksModeTransition({
    required this.animation,
    required this.direction,
    required this.reduceMotion,
    required this.child,
  });

  final Animation<double> animation;
  final int direction;
  final bool reduceMotion;
  final Widget child;

  @override
  State<_WorksModeTransition> createState() => _WorksModeTransitionState();
}

class _WorksModeTransitionState extends State<_WorksModeTransition> {
  late final int _entryDirection;
  bool _exitCaptured = false;
  late double _exitStartValue;
  late double _exitStartOpacity;
  late Offset _exitStartOffset;
  late int _exitDirection;

  @override
  void initState() {
    super.initState();
    _entryDirection = widget.direction >= 0 ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, child) {
        final isOutgoing =
            widget.animation.status == AnimationStatus.reverse ||
            widget.animation.status == AnimationStatus.dismissed;
        if (isOutgoing && !_exitCaptured) {
          _captureExit();
        }
        return _buildTransition(isOutgoing, child!);
      },
      child: widget.child,
    );
  }

  void _captureExit() {
    _exitCaptured = true;
    _exitStartValue = widget.animation.value.clamp(0.0, 1.0);
    final entryProgress = Curves.easeOutCubic.transform(_exitStartValue);
    _exitStartOpacity = entryProgress;
    _exitStartOffset = Offset(_entryDirection * 0.12 * (1 - entryProgress), 0);
    _exitDirection = widget.direction >= 0 ? 1 : -1;
  }

  Widget _buildTransition(bool isOutgoing, Widget child) {
    final progress = widget.animation.value.clamp(0.0, 1.0);
    final easedProgress = Curves.easeOutCubic.transform(progress);
    final offset = widget.reduceMotion
        ? Offset.zero
        : isOutgoing
        ? _exitOffset(progress)
        : Offset(_entryDirection * 0.12 * (1 - easedProgress), 0);
    final opacity = isOutgoing ? _exitOpacity(progress) : easedProgress;
    final fade = FadeTransition(
      opacity: AlwaysStoppedAnimation(opacity),
      child: child,
    );
    final transitioned = SlideTransition(
      position: AlwaysStoppedAnimation(
        widget.reduceMotion ? Offset.zero : offset,
      ),
      child: fade,
    );
    return IgnorePointer(
      ignoring: isOutgoing,
      child: ExcludeFocus(
        excluding: isOutgoing,
        child: ExcludeSemantics(
          excluding: isOutgoing,
          child: HeroMode(enabled: !isOutgoing, child: transitioned),
        ),
      ),
    );
  }

  Offset _exitOffset(double value) {
    if (!_exitCaptured || _exitStartValue <= 0.0001) {
      return Offset(-_exitDirection * 0.12, 0);
    }
    final progress = ((_exitStartValue - value) / _exitStartValue)
        .clamp(0.0, 1.0)
        .toDouble();
    final eased = Curves.easeOutCubic.transform(progress);
    return Offset.lerp(
          _exitStartOffset,
          Offset(-_exitDirection * 0.12, 0),
          eased,
        ) ??
        Offset(-_exitDirection * 0.12, 0);
  }

  double _exitOpacity(double value) {
    if (!_exitCaptured || _exitStartValue <= 0.0001) return 0;
    final progress = ((_exitStartValue - value) / _exitStartValue)
        .clamp(0.0, 1.0)
        .toDouble();
    final eased = Curves.easeOutCubic.transform(progress);
    return _exitStartOpacity * (1 - eased);
  }
}

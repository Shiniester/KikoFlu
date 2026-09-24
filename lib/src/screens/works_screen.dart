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
import '../utils/system_ui_style.dart';
import '../utils/ui_tokens.dart';
import '../widgets/async_state_view.dart';

class WorksScreen extends ConsumerStatefulWidget {
  const WorksScreen({
    super.key,
    this.toolbarTop,
    this.embedded = false,
    this.onSearchOnline,
  });

  final double? toolbarTop;
  final bool embedded;
  final VoidCallback? onSearchOnline;

  @override
  ConsumerState<WorksScreen> createState() => _WorksScreenState();
}

class _WorksScreenState extends ConsumerState<WorksScreen>
    with AutomaticKeepAliveClientMixin {
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

  void _changeDisplayMode(DisplayMode mode) {
    final currentMode = ref.read(worksProvider).displayMode;
    if (currentMode == mode) return;
    ref.read(worksProvider.notifier).setDisplayMode(mode);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // 必须调用以保持状态
    ref.listen<WorksState>(worksProvider, (previous, next) {
      if (!mounted) return;
      if (previous == null) return;
      if (previous.displayMode == next.displayMode) return;

      setState(() => _displayGeneration++);
    });
    final worksState = ref.watch(worksProvider);
    final isRecommendMode =
        worksState.displayMode == DisplayMode.popular ||
        worksState.displayMode == DisplayMode.recommended;

    final horizontalPadding = FloatingToolbarLayout.horizontalPadding(context);
    final topPadding = MediaQuery.paddingOf(context).top;
    final toolbarTop = widget.toolbarTop ?? topPadding + 8;
    final contentTopPadding = toolbarTop + 56;
    final displayGeneration = _displayGeneration;
    final systemOverlayStyle = transparentSystemBarsForBrightness(
      Theme.of(context).brightness,
    );

    return AnnotatedRegion(
      value: systemOverlayStyle,
      child: Scaffold(
        floatingActionButton: widget.embedded ? null : const DownloadFab(),
        body: Stack(
          children: [
            Positioned.fill(
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
    return [
      if (widget.onSearchOnline != null)
        FloatingFeedToolAction(
          icon: Icons.search,
          tooltip: S.of(context).searchOnlineWorks,
          onPressed: widget.onSearchOnline,
        ),
      FloatingFeedToolAction(
        icon: switch (worksState.layoutType) {
          LayoutType.bigGrid => Icons.grid_view,
          LayoutType.smallGrid => Icons.grid_on,
          LayoutType.list => Icons.view_list,
        },
        tooltip: S.of(context).layout,
        onPressed: () => ref.read(worksProvider.notifier).toggleLayoutType(),
      ),
      FloatingFeedToolAction(
        icon: SubtitleFilterMode.fromValue(worksState.subtitleFilter).isActive
            ? Icons.closed_caption
            : Icons.closed_caption_off,
        tooltip: S.of(context).subtitleFilter,
        isSelected: SubtitleFilterMode.fromValue(
          worksState.subtitleFilter,
        ).isActive,
        onPressed: () =>
            ref.read(worksProvider.notifier).toggleSubtitleFilter(),
      ),
      FloatingFeedToolAction(
        icon: Icons.sort,
        tooltip: S.of(context).sort,
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

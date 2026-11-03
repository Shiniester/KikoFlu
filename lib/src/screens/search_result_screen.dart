import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../models/audio_source.dart';
import '../models/sort_options.dart';
import '../providers/audio_source_provider.dart';
import '../providers/search_result_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/works_provider.dart' show LayoutType, worksProvider;
import '../services/log_service.dart';
import '../widgets/works_grid_view.dart';
import '../widgets/virtualized_sliver_collection.dart';
import '../widgets/sort_dialog.dart';
import '../widgets/global_audio_player_wrapper.dart';
import '../widgets/app_bottom_dock_transition.dart';
import '../widgets/app_navigation_scope.dart';
import '../widgets/download_fab.dart';
import '../utils/l10n_extensions.dart';
import '../utils/subtitle_filter.dart';
import '../utils/ui_tokens.dart';
import '../widgets/floating_feed_toolbar.dart';
import '../utils/system_ui_style.dart';
import '../widgets/search_condition_chip.dart';
import '../widgets/async_state_view.dart';
import '../widgets/japanese_asmr_access_prompt.dart';

class SearchResultScreen extends StatelessWidget {
  final String keyword;
  final String? searchTypeLabel;
  final Map<String, dynamic>? searchParams;
  final bool embedded;
  final int queryRevision;
  final SortOrder? initialSortOption;
  final SortDirection? initialSortDirection;
  final int initialSubtitleFilter;
  final void Function(SortOrder option, SortDirection direction)?
  onSortRequested;
  final ValueChanged<int>? onSubtitleFilterRequested;
  final SearchResultState? _initialState;
  final double _initialScrollOffset;
  final int? _pendingPage;

  const SearchResultScreen({
    super.key,
    required this.keyword,
    this.searchTypeLabel,
    this.searchParams,
    this.embedded = false,
    this.queryRevision = 0,
    this.initialSortOption,
    this.initialSortDirection,
    this.initialSubtitleFilter = 0,
    this.onSortRequested,
    this.onSubtitleFilterRequested,
  }) : _initialState = null,
       _initialScrollOffset = 0,
       _pendingPage = null;

  const SearchResultScreen._restore(
    this._initialState,
    this._initialScrollOffset,
    this._pendingPage, {
    required this.keyword,
    this.searchTypeLabel,
    this.searchParams,
  }) : embedded = false,
       queryRevision = 0,
       initialSortOption = null,
       initialSortDirection = null,
       initialSubtitleFilter = 0,
       onSortRequested = null,
       onSubtitleFilterRequested = null;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        searchResultProvider.overrideWith((ref) {
          final apiService = ref.watch(kikoeruApiServiceProvider);
          final pageSize = ref.read(pageSizeProvider);
          final notifier = SearchResultNotifier(
            apiService,
            ref,
            initialPageSize: pageSize,
            initialState:
                _initialState ??
                SearchResultState(
                  basePageSize: pageSize,
                  sortOption: initialSortOption ?? SortOrder.release,
                  sortDirection: initialSortDirection ?? SortDirection.desc,
                  subtitleFilter: initialSubtitleFilter,
                ),
          );

          notifier.syncLayoutType(ref.read(worksProvider).layoutType);
          ref.listen(worksProvider.select((state) => state.layoutType), (
            previous,
            next,
          ) {
            if (previous != next) notifier.syncLayoutType(next);
          });

          ref.listen(pageSizeProvider, (previous, next) {
            if (previous != next) {
              notifier.updatePageSize(next);
            }
          });

          ref.listen(audioSourceProvider, (previous, next) {
            if (previous != next) notifier.onSourceChanged();
          });

          return notifier;
        }),
      ],
      child: _SearchResultContent(
        keyword: keyword,
        searchTypeLabel: searchTypeLabel,
        searchParams: searchParams,
        restored: _initialState != null,
        initialScrollOffset: _initialScrollOffset,
        pendingPage: _pendingPage,
        embedded: embedded,
        queryRevision: queryRevision,
        initialSortOption: initialSortOption,
        initialSortDirection: initialSortDirection,
        initialSubtitleFilter: initialSubtitleFilter,
        onSortRequested: onSortRequested,
        onSubtitleFilterRequested: onSubtitleFilterRequested,
      ),
    );
  }
}

class _SearchResultContent extends ConsumerStatefulWidget {
  final String keyword;
  final String? searchTypeLabel;
  final Map<String, dynamic>? searchParams;
  final bool restored;
  final double initialScrollOffset;
  final int? pendingPage;
  final bool embedded;
  final int queryRevision;
  final SortOrder? initialSortOption;
  final SortDirection? initialSortDirection;
  final int initialSubtitleFilter;
  final void Function(SortOrder option, SortDirection direction)?
  onSortRequested;
  final ValueChanged<int>? onSubtitleFilterRequested;

  const _SearchResultContent({
    required this.keyword,
    this.searchTypeLabel,
    this.searchParams,
    required this.restored,
    required this.initialScrollOffset,
    required this.pendingPage,
    required this.embedded,
    required this.queryRevision,
    required this.initialSortOption,
    required this.initialSortDirection,
    required this.initialSubtitleFilter,
    required this.onSortRequested,
    required this.onSubtitleFilterRequested,
  });

  @override
  ConsumerState<_SearchResultContent> createState() =>
      _SearchResultContentState();
}

class _SearchResultContentState extends ConsumerState<_SearchResultContent> {
  late final ScrollController _scrollController;
  bool _openingWorkDetail = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    );
    logOutput(
      '[SearchResult] Screen initialized with keyword: ${widget.keyword}, type: ${widget.searchTypeLabel}',
    );
    // Load initial data
    if (widget.restored && widget.pendingPage == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.restored) {
        unawaited(
          ref.read(searchResultProvider.notifier).goToPage(widget.pendingPage!),
        );
        return;
      }
      logOutput(
        '[SearchResult] Starting search with params: ${widget.searchParams}',
      );
      ref
          .read(searchResultProvider.notifier)
          .initializeSearch(
            keyword: widget.keyword,
            searchParams: widget.searchParams,
          );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SearchResultContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.restored ||
        (oldWidget.queryRevision == widget.queryRevision &&
            oldWidget.keyword == widget.keyword &&
            mapEquals(oldWidget.searchParams, widget.searchParams))) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      unawaited(
        ref
            .read(searchResultProvider.notifier)
            .initializeSearch(
              keyword: widget.keyword,
              searchParams: widget.searchParams,
              preserveResults: widget.embedded,
              sortOption: widget.initialSortOption,
              sortDirection: widget.initialSortDirection,
              subtitleFilter: widget.initialSubtitleFilter,
            ),
      );
    });
  }

  Future<void> _openWorkDetail(WidgetBuilder builder) async {
    if (widget.embedded) {
      await pushWorkDetailRoute(context, builder: builder);
      return;
    }
    final navigation = AppNavigationScope.maybeOf(context);
    final playerRoute = navigation?.audioPlayerRoute;
    final rootNavigator = navigation?.navigator;
    if (navigation == null || playerRoute == null || rootNavigator == null) {
      await pushWorkDetailRoute(context, builder: builder);
      return;
    }
    if (_openingWorkDetail) return;
    _openingWorkDetail = true;
    try {
      navigation.selectTab(appAudioTabIndex);
      var audioNavigator = navigation.tabNavigator(appAudioTabIndex);
      if (audioNavigator == null) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        audioNavigator = navigation.tabNavigator(appAudioTabIndex);
      }
      if (ModalRoute.of(context)?.isCurrent != true) return;
      if (navigation.audioPlayerRoute != playerRoute) {
        await pushWorkDetailRoute(context, builder: builder);
        return;
      }
      if (audioNavigator == null) {
        rootNavigator.removeRoute(playerRoute);
        await pushWorkDetailRoute(context, builder: builder);
        return;
      }
      final offset = _scrollController.hasClients
          ? _scrollController.offset
          : 0.0;
      final pendingPage = ref
          .read(searchResultProvider.notifier)
          .cancelPendingPage();
      final restoredState = ref.read(searchResultProvider);
      unawaited(
        pushBottomDockRoute(
          context,
          navigator: audioNavigator,
          builder: (_) => SearchResultScreen._restore(
            restoredState,
            offset,
            pendingPage,
            keyword: widget.keyword,
            searchTypeLabel: widget.searchTypeLabel,
            searchParams: widget.searchParams,
          ),
        ),
      );
      final result = pushWorkDetailRoute(
        context,
        navigator: audioNavigator,
        builder: builder,
      );
      rootNavigator.popUntil((route) => route.isFirst);
      await result;
    } finally {
      if (mounted) _openingWorkDetail = false;
    }
  }

  void _showSortDialog(BuildContext context) {
    if (_isJapaneseQuery) return;
    final state = ref.read(searchResultProvider);
    showDialog(
      context: context,
      builder: (context) => CommonSortDialog(
        currentOption: state.sortOption,
        currentDirection: state.sortDirection,
        availableOptions: SortOrder.values
            .where(
              (option) =>
                  option != SortOrder.nsfw && option != SortOrder.updatedAt,
            )
            .toList(),
        onSort: (option, direction) {
          final onSortRequested = widget.onSortRequested;
          if (onSortRequested != null) {
            onSortRequested(option, direction);
            return;
          }
          final notifier = ref.read(searchResultProvider.notifier);
          notifier.updateSort(option, direction);
        },
        autoClose: true,
      ),
    );
  }

  bool get _isJapaneseQuery =>
      widget.searchParams?['source'] == AudioSource.jpAsmr.name ||
      ref.read(audioSourceProvider) == AudioSource.jpAsmr;

  IconData _getLayoutIcon(LayoutType layoutType) {
    switch (layoutType) {
      case LayoutType.bigGrid:
        return Icons.grid_view;
      case LayoutType.smallGrid:
        return Icons.grid_on;
      case LayoutType.list:
        return Icons.view_list;
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

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchResultProvider);
    final layoutType = ref.watch(
      worksProvider.select((state) => state.layoutType),
    );
    final currentSource = ref.watch(audioSourceProvider);
    final isJapaneseAsmr =
        widget.searchParams?['source'] == AudioSource.jpAsmr.name ||
        currentSource == AudioSource.jpAsmr;

    final horizontalPadding = FloatingToolbarLayout.horizontalPadding(context);

    final topPadding = widget.embedded
        ? 0.0
        : MediaQuery.paddingOf(context).top;
    final systemOverlayStyle = transparentSystemBarsForBrightness(
      Theme.of(context).brightness,
    );

    final resultBody = Stack(
      children: [
        Positioned.fill(child: _buildBody(searchState, layoutType)),
        if (!widget.embedded) ...[
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ProgressiveTopScrim(height: topPadding + 72),
          ),
          Positioned(
            top: topPadding + 8,
            left: horizontalPadding,
            right: horizontalPadding,
            child: FloatingToolbarRow(
              children: [
                FloatingToolbarSurface(
                  child: FloatingToolbarIconButton(
                    icon: Icons.arrow_back,
                    tooltip: S.of(context).back,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
                FloatingToolbarSurface(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingToolbarIconButton(
                        icon: _getLayoutIcon(layoutType),
                        tooltip: _getLayoutTooltip(layoutType),
                        onPressed: () => ref
                            .read(searchResultProvider.notifier)
                            .toggleLayoutType(),
                      ),
                      if (!isJapaneseAsmr)
                        FloatingToolbarIconButton(
                          icon: _getSubtitleFilterIcon(
                            searchState.subtitleFilter,
                          ),
                          tooltip: SubtitleFilterMode.fromValue(
                            searchState.subtitleFilter,
                          ).localizedTooltip(context),
                          isSelected: SubtitleFilterMode.fromValue(
                            searchState.subtitleFilter,
                          ).isActive,
                          onPressed: () {
                            final nextFilter = SubtitleFilterMode.fromValue(
                              searchState.subtitleFilter,
                            ).next.value;
                            final onSubtitleFilterRequested =
                                widget.onSubtitleFilterRequested;
                            if (onSubtitleFilterRequested != null) {
                              onSubtitleFilterRequested(nextFilter);
                              return;
                            }
                            ref
                                .read(searchResultProvider.notifier)
                                .toggleSubtitleFilter();
                          },
                        ),
                      if (!isJapaneseAsmr)
                        FloatingToolbarIconButton(
                          icon: Icons.sort,
                          tooltip: S.of(context).sort,
                          onPressed: () => _showSortDialog(context),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );

    if (widget.embedded) return resultBody;
    return GlobalAudioPlayerWrapper(
      child: AnnotatedRegion(
        value: systemOverlayStyle,
        child: Scaffold(
          floatingActionButton: const DownloadFab(),
          body: resultBody,
        ),
      ),
    );
  }

  Widget _buildSearchInfo(BuildContext context, SearchResultState searchState) {
    // 检查是否有详细的搜索条件
    final conditions = widget.searchParams?['conditions'] as List?;
    final minRate = widget.searchParams?['minRate'] as num?;
    final ageRating = widget.searchParams?['ageRating'] as String?;
    final salesRange = widget.searchParams?['salesRange'] as String?;

    // 如果有详细条件，显示为芯片
    if (conditions != null && conditions.isNotEmpty) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // 搜索条件芯片
          ...conditions.map((condition) {
            final type = condition['type'] as String;
            final value = condition['value'] as String;
            final isExclude = condition['isExclude'] as bool? ?? false;
            // RJ号需要添加RJ前缀显示
            final isRjNumber = RegExp(r'^\d+$').hasMatch(value);
            final displayValue = isRjNumber ? 'RJ$value' : value;

            return SearchConditionChip(
              avatar: Icon(
                isExclude
                    ? Icons.remove_circle_outline
                    : _getConditionIcon(type),
                size: UiIconSize.small,
              ),
              label: '$type: $displayValue',
              backgroundColor: isExclude
                  ? Theme.of(context).colorScheme.errorContainer
                  : Theme.of(context).colorScheme.secondaryContainer,
            );
          }),

          // 高级筛选条件芯片
          if (minRate != null && minRate > 0)
            SearchConditionChip(
              avatar: const Icon(Icons.star, size: 16),
              label:
                  '${S.of(context).ratingLabel} ≥ ${minRate.toStringAsFixed(2)}',
              backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
            ),
          if (ageRating != null)
            SearchConditionChip(
              avatar: const Icon(Icons.shield, size: 16),
              label: ageRating,
              backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
            ),
          if (salesRange != null)
            SearchConditionChip(
              avatar: const Icon(Icons.trending_up, size: 16),
              label: salesRange,
              backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
            ),

          // 结果统计
          if (searchState.totalCountKnown && searchState.totalCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                S.of(context).totalNWorks(searchState.totalCount),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      );
    }

    // 原有的简单显示方式（兼容旧逻辑）
    String searchInfo = widget.keyword;
    if (widget.searchTypeLabel != null) {
      searchInfo = '${widget.searchTypeLabel}: $searchInfo';
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search,
                size: 18,
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 6),
              Text(
                searchInfo,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        if (searchState.totalCountKnown && searchState.totalCount > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.numbers,
                  size: 18,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 4),
                Text(
                  S.of(context).totalNWorks(searchState.totalCount),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildBody(SearchResultState searchState, LayoutType layoutType) {
    if (searchState.error != null && searchState.works.isEmpty) {
      final error = searchState.error!;
      if (error.contains('[jp-asmr-verification-required]') &&
          _isJapaneseQuery) {
        void refreshForJapaneseAsmr() {
          if (mounted && _isJapaneseQuery) {
            ref.read(searchResultProvider.notifier).refresh();
          }
        }

        return JapaneseAsmrAccessPrompt(
          onRetry: refreshForJapaneseAsmr,
          onVerified: refreshForJapaneseAsmr,
        );
      }
      return AsyncStateView(
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
          searchState.error!,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        action: ElevatedButton.icon(
          onPressed: () => ref.read(searchResultProvider.notifier).refresh(),
          icon: const Icon(Icons.refresh),
          label: Text(S.of(context).retry),
        ),
      );
    }

    if (searchState.works.isEmpty && searchState.isLoading) {
      return const AsyncStateView(
        icon: CircularProgressIndicator(),
        message: Text('...'),
        iconToTitleSpacing: UiSpacing.large,
      );
    }

    if (searchState.works.isEmpty) {
      return AsyncStateView(
        icon: Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
        title: Text(
          S.of(context).noResults,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      );
    }

    return WorksGridView(
      works: searchState.works,
      onOpenWorkDetail: (builder) => unawaited(_openWorkDetail(builder)),
      layoutType: layoutType,
      scrollController: _scrollController,
      isLoading: searchState.isLoading,
      isRefreshing: false,
      isLoadingMore: searchState.isLoadingMore,
      hasMore: searchState.hasMore,
      error: searchState.works.isEmpty ? searchState.error : null,
      loadMoreError: searchState.loadMoreError,
      onRetry: () => ref.read(searchResultProvider.notifier).refresh(),
      showInlineLoadingIndicator: searchState.isLoading,
      pagination: VirtualizedPagination(
        currentPage: searchState.currentPage,
        pageSize: searchState.pageSize,
        totalCount: searchState.totalCountKnown ? searchState.totalCount : null,
        hasMore: searchState.hasMore,
        isLoading: searchState.isLoading || searchState.isRefreshing,
        onPreviousPage: () => ref
            .read(searchResultProvider.notifier)
            .goToPage(searchState.currentPage - 1),
        onNextPage: () => ref
            .read(searchResultProvider.notifier)
            .goToPage(searchState.currentPage + 1),
        onGoToPage: ref.read(searchResultProvider.notifier).goToPage,
        nextPageOnOverscroll: true,
        scrollDuration: const Duration(milliseconds: 300),
        scrollCurve: Curves.easeOut,
        endMessage: S.of(context).reachedEnd,
        extraBuilder: searchState.rawWorks.length > searchState.works.length
            ? (context) => Text(
                '${searchState.rawWorks.length - searchState.works.length} filtered',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              )
            : null,
      ),
      sliversBefore: [
        SliverToBoxAdapter(
          child: SizedBox(
            height:
                (widget.embedded ? 0.0 : MediaQuery.paddingOf(context).top) +
                64,
          ),
        ),
        if (searchState.isRefreshing && searchState.works.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Semantics(
                liveRegion: true,
                child: Text(S.of(context).searchUpdating),
              ),
            ),
          ),
        if (searchState.error != null && searchState.works.isNotEmpty)
          SliverToBoxAdapter(child: _buildUpdateError(searchState.error!)),
        if (!widget.embedded ||
            (searchState.totalCountKnown && searchState.totalCount > 0))
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                left: MediaQuery.orientationOf(context) == Orientation.landscape
                    ? 24
                    : 8,
                right:
                    MediaQuery.orientationOf(context) == Orientation.landscape
                    ? 24
                    : 8,
                bottom: 8,
              ),
              child: widget.embedded
                  ? Text(S.of(context).totalNWorks(searchState.totalCount))
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: _buildSearchInfo(context, searchState),
                    ),
            ),
          ),
      ],
    );
  }

  Widget _buildUpdateError(String error) {
    if (error.contains('[jp-asmr-verification-required]') && _isJapaneseQuery) {
      return JapaneseAsmrAccessPrompt(
        onRetry: () => ref.read(searchResultProvider.notifier).refresh(),
        onVerified: () => ref.read(searchResultProvider.notifier).refresh(),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              S.of(context).searchUpdateFailedShowingPrevious,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: () => ref.read(searchResultProvider.notifier).refresh(),
            child: Text(S.of(context).retry),
          ),
        ],
      ),
    );
  }

  IconData _getConditionIcon(String type) {
    // type is a localized label, so we match by checking common patterns
    // This is a best-effort fallback; the main UI uses SearchType enum directly
    return Icons.search;
  }
}

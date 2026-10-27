import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/history_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/collection_layout_provider.dart';
import '../utils/work_cover_prefetch.dart';
import '../utils/collection_grid_layout.dart';
import '../utils/scroll_optimization.dart';
import '../widgets/history_work_card.dart';
import '../widgets/virtualized_sliver_collection.dart';
import '../widgets/tab_page_motion.dart';
import '../providers/works_provider.dart' show LayoutType;
import '../../l10n/app_localizations.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key, this.topInset = 0});

  final double topInset;

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen>
    with WidgetsBindingObserver {
  bool _tabActive = false;
  bool _routeActive = true;
  bool _appActive = true;
  bool? _requestedVisibility;
  int _visibilityRevision = 0;
  HistoryNotifier? _historyNotifier;

  bool get _isVisible => _tabActive && _routeActive && _appActive;

  bool _isForeground(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appActive = _isForeground(WidgetsBinding.instance.lifecycleState);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeActive = ModalRoute.of(context)?.isCurrent ?? true;
    _scheduleVisibilityUpdate();
  }

  void _onTabActivityChanged(bool active) {
    _tabActive = active;
    _scheduleVisibilityUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = _isForeground(state);
    _scheduleVisibilityUpdate();
  }

  void _scheduleVisibilityUpdate() {
    final visible = _isVisible;
    if (_requestedVisibility == visible) return;
    _requestedVisibility = visible;
    final revision = ++_visibilityRevision;
    if (!visible) {
      _historyNotifier?.setVisible(false);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _visibilityRevision || !_isVisible) return;
      _historyNotifier = ref.read(historyProvider.notifier);
      _historyNotifier!.setVisible(true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _visibilityRevision++;
    _historyNotifier?.setVisible(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DeferredTabContent(
    onActivityChanged: _onTabActivityChanged,
    builder: (_) => _HistoryContent(topInset: widget.topInset),
  );
}

class _HistoryContent extends ConsumerWidget {
  const _HistoryContent({required this.topInset});

  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyState = ref.watch(historyProvider);
    final history = historyState.records;
    final auth = ref.watch(
      authProvider.select(
        (value) => (host: value.host ?? '', token: value.token ?? ''),
      ),
    );
    final layoutType = ref.watch(
      collectionLayoutProvider(CollectionLayoutKey.history),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final metrics = resolveCollectionGridMetrics(
            context,
            layoutType: layoutType,
            availableWidth: constraints.maxWidth,
            availableHeight: constraints.maxHeight,
          );
          final listCoverSize = layoutType == LayoutType.list
              ? collectionListCoverSizeForTitle(
                  context,
                  titleStyle: historyWorkCardTitleStyle(context),
                )
              : null;
          final listCoverCacheWidth = listCoverSize == null
              ? null
              : resolveWorkCoverCacheWidth(
                  context,
                  crossAxisCount: 1,
                  listCoverWidth: listCoverSize.width,
                );
          return WorkCoverPrefetchScope(
            sourceKey: (auth, history, listCoverCacheWidth),
            builder: (context, coverPrefetch) => VirtualizedSliverCollection(
              retainedItemCount: 100,
              items: history,
              itemId: (record) => record.work.id,
              layout: layoutType == LayoutType.list
                  ? VirtualizedCollectionLayout.list
                  : VirtualizedCollectionLayout.masonry,
              masonryCrossAxisCount: layoutType == LayoutType.list
                  ? null
                  : metrics.crossAxisCount,
              masonryCrossAxisSpacing: metrics.spacing,
              masonryMainAxisSpacing: metrics.spacing,
              padding: metrics.padding,
              physics: ScrollOptimization.physics,
              isInitialLoading: historyState.isLoading && history.isEmpty,
              isRefreshing: historyState.isRefreshing,
              isLoadingMore: historyState.isLoadingMore,
              hasMore: historyState.hasMore,
              error: historyState.error,
              loadMoreError: historyState.loadMoreError,
              onRetry: ref.read(historyProvider.notifier).refresh,
              pagination: VirtualizedPagination(
                currentPage: historyState.currentPage,
                pageSize: historyState.pageSize,
                totalCount: historyState.totalCount,
                hasMore: historyState.hasMore,
                isLoading: historyState.isLoading,
                onPreviousPage: ref.read(historyProvider.notifier).previousPage,
                onNextPage: ref.read(historyProvider.notifier).nextPage,
                onGoToPage: ref.read(historyProvider.notifier).goToPage,
                padding: const EdgeInsets.only(bottom: 80, top: 16),
                scrollToTop: false,
              ),
              sliversBefore: [
                if (topInset > 0)
                  SliverToBoxAdapter(child: SizedBox(height: topInset)),
              ],
              onPrefetch: (records) => coverPrefetch.prefetch(
                context,
                records.map((record) => record.work),
                host: auth.host,
                token: auth.token,
                crossAxisCount: metrics.crossAxisCount,
                listCoverWidth: listCoverSize?.width,
                isListCard: layoutType == LayoutType.list,
              ),
              prefetchKey: listCoverCacheWidth,
              emptyBuilder: (context) => historyState.isLoading
                  ? const SizedBox.shrink()
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.history,
                            size: 64,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            S.of(context).noPlayHistory,
                            style: TextStyle(
                              fontSize: 16,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
              itemBuilder: (context, record, index) => HistoryWorkCard(
                key: ValueKey(record.work.id),
                record: record,
                layoutType: layoutType,
              ),
            ),
          );
        },
      ),
    );
  }
}

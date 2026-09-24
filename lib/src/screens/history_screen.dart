import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/history_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/collection_layout_provider.dart';
import '../providers/work_card_display_provider.dart';
import '../utils/work_cover_prefetch.dart';
import '../utils/collection_grid_layout.dart';
import '../utils/scroll_optimization.dart';
import '../widgets/history_work_card.dart';
import '../widgets/virtualized_sliver_collection.dart';
import '../providers/works_provider.dart' show LayoutType;
import '../../l10n/app_localizations.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key, this.topInset = 0});

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
    final cardSize = ref.watch(
      workCardDisplayProvider.select((settings) => settings.cardSize),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final metrics = resolveCollectionGridMetrics(
            context,
            layoutType: layoutType,
            cardSize: cardSize,
            availableWidth: constraints.maxWidth,
            availableHeight: constraints.maxHeight,
          );
          return WorkCoverPrefetchScope(
            sourceKey: (auth, history),
            builder: (context, coverPrefetch) => VirtualizedSliverCollection(
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
                isListCard: layoutType == LayoutType.list,
              ),
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
      floatingActionButton: history.isNotEmpty
          ? FloatingActionButton(
              onPressed: () => _showClearConfirmation(context, ref),
              tooltip: S.of(context).clearHistory,
              child: const Icon(Icons.delete_outline),
            )
          : null,
    );
  }

  Future<void> _showClearConfirmation(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.of(context).clearHistoryTitle),
        content: Text(S.of(context).clearHistoryConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.of(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.of(context).clear),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(historyProvider.notifier).clear();
    }
  }
}

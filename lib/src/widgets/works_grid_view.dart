import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/work.dart';
import '../providers/work_card_display_provider.dart';
import '../providers/works_provider.dart';
import '../providers/auth_provider.dart';
import '../utils/collection_grid_layout.dart';
import '../utils/work_cover_prefetch.dart';
import 'enhanced_work_card.dart';
import 'virtualized_sliver_collection.dart';

class WorksGridView extends ConsumerWidget {
  const WorksGridView({
    super.key,
    required this.works,
    required this.layoutType,
    this.scrollController,
    this.isLoading = false,
    this.isRefreshing = false,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.error,
    this.loadMoreError,
    this.onRefresh,
    this.onLoadMore,
    this.onRetry,
    this.onPrefetch,
    this.emptyBuilder,
    this.loadingBuilder,
    this.errorBuilder,
    this.endBuilder,
    this.showEndMessage = false,
    this.pagination,
    this.pageStorageKey,
    this.padding,
    this.sliversBefore = const [],
    this.fillEmptyViewport = true,
    this.physics,
    this.showInlineLoadingIndicator = false,
  });

  final List<Work> works;
  final LayoutType layoutType;
  final ScrollController? scrollController;
  final bool isLoading;
  final bool isRefreshing;
  final bool isLoadingMore;
  final bool hasMore;
  final Object? error;
  final Object? loadMoreError;
  final Future<void> Function()? onRefresh;
  final Future<void> Function()? onLoadMore;
  final VoidCallback? onRetry;
  final ValueChanged<List<Work>>? onPrefetch;
  final WidgetBuilder? emptyBuilder;
  final WidgetBuilder? loadingBuilder;
  final VirtualizedErrorBuilder? errorBuilder;
  final WidgetBuilder? endBuilder;
  final bool showEndMessage;
  final VirtualizedPagination? pagination;
  final PageStorageKey<String>? pageStorageKey;
  final EdgeInsetsGeometry? padding;
  final List<Widget> sliversBefore;
  final bool fillEmptyViewport;
  final ScrollPhysics? physics;
  final bool showInlineLoadingIndicator;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displaySettings = ref.watch(workCardDisplayProvider);
    final auth = ref.watch(
      authProvider.select((state) => (state.host ?? '', state.token ?? '')),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaSize = MediaQuery.sizeOf(context);
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth.clamp(0.0, mediaSize.width).toDouble()
            : mediaSize.width;
        final availableHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight.clamp(0.0, mediaSize.height).toDouble()
            : mediaSize.height;
        final metrics = resolveCollectionGridMetrics(
          context,
          layoutType: layoutType,
          cardSize: displaySettings.cardSize,
          padding: padding,
          availableWidth: availableWidth,
          availableHeight: availableHeight,
        );
        final collectionPadding = metrics.padding;
        final resolvedPadding = metrics.padding;
        final spacing = metrics.spacing;
        final crossAxisCount = metrics.crossAxisCount;
        final isGrid = layoutType != LayoutType.list;
        return WorkCoverPrefetchScope(
          sourceKey: (auth.$1, auth.$2, key, pageStorageKey, works),
          builder: (context, coverPrefetch) =>
              VirtualizedSliverCollection<Work>(
                controller: scrollController,
                pageStorageKey: pageStorageKey,
                sliversBefore: sliversBefore,
                items: works,
                itemId: (work) => work.id,
                itemBuilder: (context, work, index) => EnhancedWorkCard(
                  key: ValueKey(work.id),
                  work: work,
                  crossAxisCount: crossAxisCount,
                  isListLayout: layoutType == LayoutType.list,
                ),
                layout: isGrid
                    ? VirtualizedCollectionLayout.masonry
                    : VirtualizedCollectionLayout.list,
                masonryCrossAxisCount: isGrid ? crossAxisCount : null,
                masonryCrossAxisSpacing: spacing,
                masonryMainAxisSpacing: spacing,
                padding: collectionPadding,
                isInitialLoading: isLoading && works.isEmpty,
                isRefreshing: isRefreshing,
                isLoadingMore: isLoadingMore,
                hasMore: hasMore,
                error: works.isEmpty ? error : null,
                loadMoreError: loadMoreError,
                onRefresh: onRefresh,
                onLoadMore: onLoadMore,
                pagination: pagination?.copyWith(
                  padding: EdgeInsets.fromLTRB(
                    resolvedPadding.left,
                    spacing,
                    resolvedPadding.right,
                    24,
                  ),
                ),
                onRetry: onRetry,
                onPrefetch: (items) {
                  coverPrefetch.prefetch(
                    context,
                    items,
                    host: auth.$1,
                    token: auth.$2,
                    crossAxisCount: crossAxisCount,
                    isListCard: layoutType == LayoutType.list,
                  );
                  onPrefetch?.call(items);
                },
                emptyBuilder: emptyBuilder,
                loadingBuilder: loadingBuilder,
                errorBuilder: errorBuilder,
                endBuilder: endBuilder,
                showEndIndicator:
                    pagination == null && showEndMessage && works.isNotEmpty,
                fillEmptyViewport: fillEmptyViewport,
                physics: physics,
                collectionTrailingBuilder:
                    (onLoadMore != null && hasMore) ||
                        showInlineLoadingIndicator
                    ? (context) => isGrid
                          ? const SizedBox(
                              height: 100,
                              child: Center(child: CircularProgressIndicator()),
                            )
                          : const Center(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: CircularProgressIndicator(),
                              ),
                            )
                    : null,
              ),
        );
      },
    );
  }
}

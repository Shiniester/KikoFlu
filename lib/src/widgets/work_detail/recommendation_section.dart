import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../../l10n/app_localizations.dart';
import '../../models/work.dart';
import '../../providers/auth_provider.dart';
import '../../providers/recommendation_provider.dart';
import '../../providers/work_card_display_provider.dart';
import '../../providers/work_detail_display_provider.dart';
import '../../providers/settings_provider.dart' show blockedItemsProvider;
import '../../providers/works_provider.dart' show LayoutType;
import '../../utils/collection_grid_layout.dart';
import '../../utils/work_cover_prefetch.dart';
import '../enhanced_work_card.dart';
import 'work_detail_section_title.dart';

/// 作品详情页底部的相关推荐网格。
class RecommendationSection extends ConsumerStatefulWidget {
  final Work work;

  const RecommendationSection({super.key, required this.work});

  @override
  ConsumerState<RecommendationSection> createState() =>
      _RecommendationSectionState();
}

class _RecommendationSectionState extends ConsumerState<RecommendationSection> {
  bool _attempted = false;
  int _accessId = createRecommendationAccessId();
  Object? _coverPrefetchKey;

  @override
  void didUpdateWidget(RecommendationSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.work.id != widget.work.id) {
      _attempted = false;
      _accessId = createRecommendationAccessId();
      _coverPrefetchKey = null;
    }
  }

  void _loadRecommendations() {
    if (_attempted) return;
    _attempted = true;
    final accessId = _accessId;
    final work = widget.work;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (accessId != _accessId || work.id != widget.work.id) return;
      if (!ref.read(workDetailDisplayProvider).showRecommendations) {
        _attempted = false;
        return;
      }
      final state = ref.read(recommendationProvider(accessId));
      if (state.recommendations.isEmpty && !state.isLoading) {
        ref
            .read(recommendationProvider(accessId).notifier)
            .loadRecommendations(work);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = ref.watch(
      workDetailDisplayProvider.select((s) => s.showRecommendations),
    );
    final state = ref.watch(recommendationProvider(_accessId));
    if (!visible) {
      _coverPrefetchKey = null;
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    _loadRecommendations();
    final auth = ref.watch(
      authProvider.select((state) => (state.host ?? '', state.token ?? '')),
    );
    final blockedItems = ref.watch(blockedItemsProvider);
    final recommendations = state.recommendations
        .where((work) {
          if (work.tags?.any((tag) => blockedItems.tags.contains(tag.name)) ??
              false) {
            return false;
          }
          if (work.vas?.any((va) => blockedItems.cvs.contains(va.name)) ??
              false) {
            return false;
          }
          return work.name == null || !blockedItems.circles.contains(work.name);
        })
        .toList(growable: false);
    final cardSize = ref.watch(
      workCardDisplayProvider.select((s) => s.cardSize),
    );
    return WorkCoverPrefetchScope(
      sourceKey: (_accessId, auth),
      builder: (context, coverPrefetch) => SliverLayoutBuilder(
        builder: (context, constraints) {
          if (!state.isLoading && recommendations.isEmpty) {
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          }
          final metrics = resolveCollectionGridMetrics(
            context,
            layoutType: LayoutType.bigGrid,
            cardSize: cardSize,
            availableWidth: constraints.crossAxisExtent,
            padding: const EdgeInsets.only(bottom: 16),
          );
          final viewportHeight =
              Scrollable.maybeOf(context)?.position.viewportDimension ??
              MediaQuery.sizeOf(context).height;
          final coverWidth =
              (constraints.crossAxisExtent -
                  metrics.padding.horizontal -
                  metrics.spacing * (metrics.crossAxisCount - 1)) /
              metrics.crossAxisCount;
          final coverCount =
              metrics.crossAxisCount *
              (viewportHeight / (coverWidth / collectionCoverAspectRatio))
                  .ceil();
          final prefetchKey = (
            _accessId,
            auth,
            state.recommendations,
            blockedItems,
            cardSize,
            constraints.crossAxisExtent,
            viewportHeight,
            MediaQuery.devicePixelRatioOf(context),
          );
          if (!state.isLoading &&
              recommendations.isNotEmpty &&
              _coverPrefetchKey != prefetchKey) {
            _coverPrefetchKey = prefetchKey;
            final covers = recommendations
                .take(coverCount)
                .toList(growable: false);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted ||
                  _coverPrefetchKey != prefetchKey ||
                  !ref.read(workDetailDisplayProvider).showRecommendations) {
                return;
              }
              coverPrefetch.prefetch(
                context,
                covers,
                host: auth.$1,
                token: auth.$2,
                crossAxisCount: metrics.crossAxisCount,
                isListCard: false,
              );
            });
          }
          return SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: WorkDetailSectionTitle(
                        S.of(context).relatedRecommendations,
                      ),
                    ),
                  ],
                ),
              ),
              SliverPadding(
                padding: metrics.padding,
                sliver: SliverMasonryGrid.count(
                  crossAxisCount: metrics.crossAxisCount,
                  crossAxisSpacing: metrics.spacing,
                  mainAxisSpacing: metrics.spacing,
                  childCount: state.isLoading ? 6 : recommendations.length,
                  itemBuilder: (context, index) => state.isLoading
                      ? _buildShimmerCard(context)
                      : EnhancedWorkCard(
                          key: ValueKey(recommendations[index].id),
                          work: recommendations[index],
                          crossAxisCount: metrics.crossAxisCount,
                          isListLayout: false,
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildShimmerCard(BuildContext context) {
    final color = Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: collectionCoverAspectRatio,
          child: Container(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(height: 14, width: 100, color: color),
        const SizedBox(height: 4),
        Container(height: 12, width: 60, color: color),
      ],
    );
  }
}

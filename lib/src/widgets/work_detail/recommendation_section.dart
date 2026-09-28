import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/work.dart';
import '../../providers/auth_provider.dart';
import '../../providers/recommendation_provider.dart';
import '../../providers/work_detail_display_provider.dart';
import '../../screens/work_detail_screen.dart';
import '../../utils/work_cover_prefetch.dart';
import '../../widgets/privacy_blur_cover.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../work_cover_image.dart';
import 'work_cover_frame.dart';
import '../../../l10n/app_localizations.dart';

/// 作品详情页底部的"相关推荐"横向滚动区域
class RecommendationSection extends ConsumerStatefulWidget {
  final Work work;

  const RecommendationSection({super.key, required this.work});

  @override
  ConsumerState<RecommendationSection> createState() =>
      _RecommendationSectionState();
}

class _RecommendationSectionState extends ConsumerState<RecommendationSection> {
  bool _activated = false;
  bool _attempted = false;

  @override
  void didUpdateWidget(RecommendationSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.work.id != widget.work.id) {
      _activated = false;
      _attempted = false;
    }
  }

  void _loadWhenVisible() {
    if (_attempted) return;
    _attempted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!ref.read(workDetailDisplayProvider).showRecommendations) {
        _attempted = false;
        return;
      }
      final state = ref.read(recommendationProvider(widget.work.id));
      if (state.recommendations.isEmpty && !state.isLoading) {
        ref
            .read(recommendationProvider(widget.work.id).notifier)
            .loadRecommendations(widget.work);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = ref.watch(
      workDetailDisplayProvider.select((s) => s.showRecommendations),
    );
    if (!visible) return const SliverToBoxAdapter(child: SizedBox.shrink());
    final state = ref.watch(recommendationProvider(widget.work.id));
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        if (!_activated && constraints.remainingCacheExtent <= 0) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        _activated = true;
        _loadWhenVisible();
        return SliverToBoxAdapter(child: _buildContent(context, state));
      },
    );
  }

  Widget _buildContent(BuildContext context, RecommendationState state) {
    // 加载中：显示占位骨架
    if (state.isLoading) {
      return _buildSection(
        context,
        child: SizedBox(
          height: 190,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: 5,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, __) => _buildShimmerCard(context),
          ),
        ),
      );
    }

    // 没有推荐 或 出错：不显示
    if (state.recommendations.isEmpty) {
      return const SizedBox.shrink();
    }

    return _buildSection(
      context,
      child: SizedBox(
        height: 190,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: state.recommendations.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            return _RecommendationCard(work: state.recommendations[index]);
          },
        ),
      ),
    );
  }

  Widget _buildSection(BuildContext context, {required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Row(
            children: [
              Icon(
                Icons.recommend_outlined,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                S.of(context).relatedRecommendations,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        child,
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildShimmerCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面占位
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(height: 8),
          // 标题占位
          Container(
            height: 14,
            width: 100,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 4),
          Container(
            height: 12,
            width: 60,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}

/// 推荐作品卡片
class _RecommendationCard extends ConsumerWidget {
  final Work work;

  const _RecommendationCard({required this.work});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';
    final coverCacheWidth = (120 * MediaQuery.of(context).devicePixelRatio)
        .round();
    final initialCoverImageProvider = host.isEmpty
        ? null
        : createWorkCoverImageProvider(
            work: work,
            host: host,
            token: token,
            cacheWidth: coverCacheWidth,
          );

    return SizedBox(
      width: 120,
      child: GestureDetector(
        onTap: () {
          pushWorkDetailRoute(
            context,
            builder: (context) => WorkDetailScreen(
              work: work,
              initialCoverImageProvider: initialCoverImageProvider,
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 120,
                height: 120,
                child: _buildCover(context, host, token),
              ),
            ),
            const SizedBox(height: 6),
            // 标题
            Text(
              work.title,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            // 评分
            if (work.rateAverage != null && work.rateAverage! > 0)
              Row(
                children: [
                  Icon(
                    Icons.star_rounded,
                    size: 14,
                    color: Colors.amber.shade700,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    work.rateAverage!.toStringAsFixed(1),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover(BuildContext context, String host, String token) {
    if (host.isEmpty) {
      return _buildPlaceholder(context);
    }

    return WorkCoverClip(
      cornerRadius: workCoverCompactRadius,
      child: PrivacyBlurCover(
        child: WorkCoverImage(
          image: createWorkCoverImageProvider(
            work: work,
            host: host,
            token: token,
            headers: const {},
            cacheWidth: (120 * MediaQuery.of(context).devicePixelRatio).round(),
          ),
          placeholder: _buildPlaceholder,
          errorBuilder: (context, _, __) => _buildPlaceholder(context),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(
        child: Icon(Icons.audiotrack, color: Colors.grey, size: 32),
      ),
    );
  }
}

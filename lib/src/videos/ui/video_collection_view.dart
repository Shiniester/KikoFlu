import 'package:flutter/material.dart';

import '../../providers/work_card_display_provider.dart';
import '../../providers/works_provider.dart';
import '../../utils/collection_grid_layout.dart';
import '../../widgets/virtualized_sliver_collection.dart';
import '../video_models.dart';

class VideoCollectionView<T> extends StatelessWidget {
  const VideoCollectionView({
    super.key,
    required this.items,
    required this.layoutType,
    required this.itemId,
    required this.itemBuilder,
    required this.controller,
    required this.pageStorageKey,
    required this.emptyBuilder,
    this.pagination,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 12),
  });

  final List<T> items;
  final LayoutType layoutType;
  final Object Function(T item) itemId;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final ScrollController controller;
  final PageStorageKey<String> pageStorageKey;
  final WidgetBuilder emptyBuilder;
  final VirtualizedPagination? pagination;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final mediaSize = MediaQuery.sizeOf(context);
      final metrics = resolveCollectionGridMetrics(
        context,
        layoutType: layoutType,
        cardSize: WorkCardSize.normal,
        padding: padding,
        availableWidth: constraints.maxWidth,
        availableHeight: constraints.hasBoundedHeight
            ? constraints.maxHeight
            : mediaSize.height,
      );
      final isGrid = layoutType != LayoutType.list;
      final contentWidth =
          constraints.maxWidth -
          metrics.padding.horizontal -
          metrics.spacing * (metrics.crossAxisCount - 1);
      final cellWidth = contentWidth / metrics.crossAxisCount;
      var titleHeight = 0.0;
      if (isGrid) {
        final titlePainter = TextPainter(
          text: TextSpan(
            text: 'M\nM',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 2,
          ellipsis: '\u2026',
        );
        titlePainter.layout(
          maxWidth: (cellWidth - 24).clamp(0, double.infinity).toDouble(),
        );
        titleHeight = titlePainter.height;
        titlePainter.dispose();
      }
      final gridMainAxisExtent = (cellWidth - 8) * 9 / 16 + titleHeight + 24;
      return VirtualizedSliverCollection<T>(
        key: pageStorageKey,
        items: items,
        itemId: itemId,
        itemBuilder: itemBuilder,
        controller: controller,
        pageStorageKey: pageStorageKey,
        layout: isGrid
            ? VirtualizedCollectionLayout.grid
            : VirtualizedCollectionLayout.list,
        gridDelegate: isGrid
            ? SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: metrics.crossAxisCount,
                crossAxisSpacing: metrics.spacing,
                mainAxisSpacing: metrics.spacing,
                mainAxisExtent: gridMainAxisExtent,
              )
            : null,
        padding: metrics.padding,
        showEndIndicator: false,
        emptyBuilder: emptyBuilder,
        pagination: pagination,
      );
    },
  );
}

class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.layoutType,
    required this.onTap,
    this.subtitle,
  });

  final VideoItem video;
  final LayoutType layoutType;
  final VoidCallback? onTap;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = _cover();
    if (layoutType == LayoutType.list) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 104,
            child: Row(
              children: [
                SizedBox(
                  width: 128,
                  child: AspectRatio(aspectRatio: 16 / 9, child: cover),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          video.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (video.durationSeconds != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _videoDurationLabel(video.durationSeconds!),
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  cover,
                  if (video.durationSeconds != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .7),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Text(
                            _videoDurationLabel(video.durationSeconds!),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover() => video.cover.isEmpty
      ? const ColoredBox(
          color: Colors.black12,
          child: Center(child: Icon(Icons.movie_outlined)),
        )
      : Image.network(
          video.cover,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const ColoredBox(
            color: Colors.black12,
            child: Center(child: Icon(Icons.movie_outlined)),
          ),
        );
}

String _videoDurationLabel(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainder = seconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = remainder.toString().padLeft(2, '0');
  return hours == 0 ? '$mm:$ss' : '$hours:$mm:$ss';
}

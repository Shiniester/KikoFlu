import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
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
      final metrics = resolveCollectionGridMetrics(
        context,
        layoutType: layoutType,
        cardSize: WorkCardSize.normal,
        padding: padding,
        availableWidth: constraints.maxWidth,
        availableHeight: constraints.hasBoundedHeight
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height,
      );
      final isGrid = layoutType != LayoutType.list;
      return VirtualizedSliverCollection<T>(
        key: pageStorageKey,
        items: items,
        itemId: itemId,
        itemBuilder: itemBuilder,
        controller: controller,
        pageStorageKey: pageStorageKey,
        layout: isGrid
            ? VirtualizedCollectionLayout.masonry
            : VirtualizedCollectionLayout.list,
        masonryCrossAxisCount: isGrid ? metrics.crossAxisCount : null,
        masonryCrossAxisSpacing: metrics.spacing,
        masonryMainAxisSpacing: metrics.spacing,
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
    this.onOpenLink,
  });

  final VideoItem video;
  final LayoutType layoutType;
  final VoidCallback? onTap;
  final String? subtitle;
  final ValueChanged<VideoLink>? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      video.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final isList = layoutType == LayoutType.list;
    return Card(
      margin: isList
          ? const EdgeInsets.symmetric(vertical: 4)
          : EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: isList
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox.fromSize(
                      size: collectionListCoverSize,
                      child: VideoCover(video: video),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [title, _information(context)],
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: collectionCoverAspectRatio,
                    child: VideoCover(video: video),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [title, _information(context)],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _information(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      Widget chip(
        String label,
        bool isActor,
        VoidCallback? onPressed,
      ) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth),
        child: Material(
          color: isActor ? colors.secondaryContainer : colors.tertiaryContainer,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: isActor
                      ? colors.onSecondaryContainer
                      : colors.onTertiaryContainer,
                ),
              ),
            ),
          ),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ],
          for (final (links, limit) in [(video.actors, 2), (video.tags, 3)])
            if (links.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 3,
                runSpacing: 3,
                children: [
                  for (final link in links.take(limit))
                    chip(
                      link.label,
                      link.kind == VideoLinkKind.actor,
                      onOpenLink == null ? null : () => onOpenLink!(link),
                    ),
                  if (links.length > limit)
                    Tooltip(
                      message: links
                          .skip(limit)
                          .map((link) => link.label)
                          .join('、'),
                      child: chip(
                        '+${links.length - limit}',
                        links.first.kind == VideoLinkKind.actor,
                        onTap,
                      ),
                    ),
                ],
              ),
            ],
        ],
      );
    },
  );
}

class VideoCover extends StatelessWidget {
  const VideoCover({super.key, required this.video});

  final VideoItem video;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 120;
      final inset = compact ? 2.0 : 6.0;
      final s = S.of(context);
      Widget badge(Widget child, {Key? key}) => Container(
        key: key,
        padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 5, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(4),
        ),
        child: child,
      );
      final textStyle = TextStyle(
        color: Colors.white,
        fontSize: compact ? 7 : 11,
      );
      return ClipRRect(
        borderRadius: BorderRadius.circular(
          collectionCoverRadius(constraints.maxWidth),
        ),
        child: Stack(
          key: ValueKey('video-cover-${video.id}'),
          fit: StackFit.expand,
          children: [
            _image(),
            if (video.durationSeconds != null)
              Positioned(
                right: inset,
                top: inset,
                child: badge(
                  Text(
                    _videoDurationLabel(video.durationSeconds!),
                    style: textStyle,
                  ),
                  key: ValueKey('video-duration-${video.id}'),
                ),
              ),
            Positioned(
              left: inset,
              right: inset,
              bottom: inset,
              child: Row(
                children: [
                  if (video.hasSubtitles)
                    Tooltip(
                      message: s.videoSubtitle,
                      child: badge(
                        Icon(
                          Icons.closed_caption,
                          color: Colors.white,
                          size: compact ? 10 : 16,
                        ),
                      ),
                    ),
                  if (video.hasSubtitles && video.isUncensored)
                    const SizedBox(width: 3),
                  if (video.isUncensored)
                    Tooltip(
                      message: s.videoUncensored,
                      child: badge(
                        Icon(
                          Icons.no_encryption_outlined,
                          color: Colors.white,
                          size: compact ? 10 : 16,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: video.releaseDate == null
                          ? const SizedBox.shrink()
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Tooltip(
                                message: s.releaseDateInfo,
                                child: badge(
                                  Text(video.releaseDate!, style: textStyle),
                                  key: ValueKey('video-release-${video.id}'),
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _image() => video.cover.isEmpty
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

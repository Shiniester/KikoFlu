import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../providers/work_card_display_provider.dart';
import '../../providers/works_provider.dart';
import '../../utils/collection_grid_layout.dart';
import '../../utils/string_utils.dart';
import '../../widgets/virtualized_sliver_collection.dart';
import '../video_card_display_provider.dart';
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

class VideoCard extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final visibleFields = ref.watch(videoCardDisplayProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final isList = layoutType == LayoutType.list;
        final isCompact =
            layoutType == LayoutType.smallGrid ||
            (layoutType == LayoutType.bigGrid && constraints.maxWidth < 160);
        final titleFontSize = isList
            ? (isLandscape ? 16.0 : 14.0)
            : isCompact
            ? (isLandscape ? 13.5 : 11.0)
            : (isLandscape ? 14.5 : 12.0);
        final bodyFontSize = isList
            ? (isLandscape ? 13.0 : 11.0)
            : (isLandscape ? 13.5 : 10.0);
        final chipFontSize = isList
            ? bodyFontSize
            : (isLandscape ? 13.0 : 10.0);
        final title = Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            height: isList ? 1.3 : 1.1,
            fontSize: titleFontSize,
          ),
        );
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
                            children: [
                              title,
                              _information(
                                context,
                                visibleFields,
                                bodyFontSize,
                                chipFontSize: chipFontSize,
                                isList: isList,
                              ),
                            ],
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
                          children: [
                            title,
                            _information(
                              context,
                              visibleFields,
                              bodyFontSize,
                              chipFontSize: chipFontSize,
                              isList: isList,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _information(
    BuildContext context,
    Set<VideoCardField> visibleFields,
    double bodyFontSize, {
    required double chipFontSize,
    required bool isList,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      Widget chip(String label, bool isActor, VoidCallback? onPressed) =>
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: Material(
              color: isActor
                  ? colors.tertiaryContainer
                  : colors.primaryContainer,
              borderRadius: BorderRadius.circular(isActor && isList ? 12 : 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(isActor && isList ? 12 : 6),
                onTap: onPressed,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isActor && isList ? 6 : 4,
                    vertical: isActor && isList ? 2 : 1,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: chipFontSize,
                      fontWeight: FontWeight.w500,
                      color: isActor
                          ? colors.onTertiaryContainer
                          : colors.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
          );
      Widget metadataLine(String label, List<String> values) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          '$label: ${values.join(', ')}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey[600],
            fontSize: bodyFontSize,
          ),
        ),
      );

      final actors = video.actors;
      final tags = video.cardTags;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey[600],
                fontSize: bodyFontSize,
              ),
            ),
          ],
          if (visibleFields.contains(VideoCardField.makers) &&
              video.cardMakers.isNotEmpty)
            metadataLine(S.of(context).videoCardMakers, video.cardMakers),
          if (visibleFields.contains(VideoCardField.labels) &&
              video.cardLabels.isNotEmpty)
            metadataLine(S.of(context).videoCardLabels, video.cardLabels),
          if (visibleFields.contains(VideoCardField.series) &&
              video.cardSeries.isNotEmpty)
            metadataLine(S.of(context).series, video.cardSeries),
          if (visibleFields.contains(VideoCardField.directors) &&
              video.cardDirectors.isNotEmpty)
            metadataLine(S.of(context).videoCardDirectors, video.cardDirectors),
          VideoDurationInfo(
            videoId: video.id,
            seconds: video.durationSeconds,
            isList: isList,
          ),
          if (actors.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: isList ? 4 : 3,
              runSpacing: isList ? 4 : 2,
              children: [
                for (final actor in actors.take(2))
                  chip(
                    actor.label,
                    true,
                    onOpenLink == null ? null : () => onOpenLink!(actor),
                  ),
                if (actors.length > 2)
                  Tooltip(
                    message: actors.skip(2).map((link) => link.label).join('、'),
                    child: chip('+${actors.length - 2}', true, onTap),
                  ),
              ],
            ),
          ],
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 2),
            Wrap(
              spacing: 3,
              runSpacing: 2,
              children: [
                for (final tag in tags)
                  chip(
                    tag.label,
                    false,
                    onOpenLink == null ? null : () => onOpenLink!(tag),
                  ),
              ],
            ),
          ],
        ],
      );
    },
  );
}

class VideoDurationInfo extends ConsumerWidget {
  const VideoDurationInfo({
    super.key,
    required this.videoId,
    required this.seconds,
    required this.isList,
  });

  final String videoId;
  final int? seconds;
  final bool isList;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(
      videoCardDisplayProvider.select(
        (fields) => fields.contains(VideoCardField.duration),
      ),
    );
    if (!visible || seconds == null) return const SizedBox.shrink();

    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final fontSize = isList
        ? (isLandscape ? 13.0 : 11.0)
        : (isLandscape ? 13.5 : 10.0);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        key: ValueKey('video-duration-$videoId'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.access_time,
            color: Colors.blue,
            size: isList || isLandscape ? 14 : 12,
          ),
          const SizedBox(width: 2),
          Text(
            formatDuration(Duration(seconds: seconds!)),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.blue[700],
              fontSize: fontSize,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class VideoCover extends ConsumerWidget {
  const VideoCover({super.key, required this.video});

  final VideoItem video;

  @override
  Widget build(BuildContext context, WidgetRef ref) => LayoutBuilder(
    builder: (context, constraints) {
      final showReleaseDate = ref.watch(
        videoCardDisplayProvider.select(
          (fields) => fields.contains(VideoCardField.releaseDate),
        ),
      );
      final showSubtitleTag = ref.watch(
        videoCardDisplayProvider.select(
          (fields) => fields.contains(VideoCardField.subtitleTag),
        ),
      );
      final showUncensoredTag = ref.watch(
        videoCardDisplayProvider.select(
          (fields) => fields.contains(VideoCardField.uncensoredTag),
        ),
      );
      final compact = constraints.maxWidth < 120;
      final isLandscape =
          MediaQuery.orientationOf(context) == Orientation.landscape;
      final inset = compact ? 2.0 : 6.0;
      final s = S.of(context);
      Widget badge(Widget child, {Key? key}) => Container(
        key: key,
        padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(4),
        ),
        child: child,
      );
      final textStyle = TextStyle(
        color: Colors.white,
        fontSize: compact ? 7 : (isLandscape ? 13 : 10),
        fontWeight: FontWeight.bold,
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
            Positioned(
              left: inset,
              right: inset,
              bottom: inset,
              child: Row(
                children: [
                  if (showSubtitleTag && video.hasSubtitles)
                    Tooltip(
                      message: s.subtitleTagLabel,
                      child: badge(
                        Icon(
                          Icons.closed_caption,
                          color: Colors.white,
                          size: compact ? 10 : (isLandscape ? 16 : 14),
                        ),
                      ),
                    ),
                  if (showSubtitleTag &&
                      video.hasSubtitles &&
                      showUncensoredTag &&
                      video.isUncensored)
                    const SizedBox(width: 3),
                  if (showUncensoredTag && video.isUncensored)
                    Tooltip(
                      message: s.videoUncensored,
                      child: badge(
                        Icon(
                          Icons.no_encryption_outlined,
                          color: Colors.white,
                          size: compact ? 10 : (isLandscape ? 16 : 14),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: !showReleaseDate || video.releaseDate == null
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

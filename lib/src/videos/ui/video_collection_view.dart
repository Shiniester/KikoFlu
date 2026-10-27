import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../providers/works_provider.dart';
import '../../utils/collection_grid_layout.dart';
import '../../utils/string_utils.dart';
import '../../widgets/virtualized_sliver_collection.dart';
import '../video_card_display_provider.dart';
import '../video_models.dart';

typedef VideoCoverImageKey = ({String videoId, String url, int? cacheWidth});

typedef VideoCoverImageCallback =
    void Function(VideoCoverImageKey key, {required bool failed});
typedef VideoCoverRetryCallback = void Function(VideoCoverImageKey key);
typedef VideoVisibleItemsChanged<T> =
    void Function(List<T> items, int? coverCacheWidth);

TextStyle? videoCollectionListTitleStyle(BuildContext context) {
  final isLandscape =
      MediaQuery.orientationOf(context) == Orientation.landscape;
  return Theme.of(context).textTheme.titleSmall?.copyWith(
    fontWeight: FontWeight.bold,
    height: 1.3,
    fontSize: isLandscape ? 16.0 : 14.0,
  );
}

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
    this.onVisibleItemsChanged,
    this.onCoverCacheWidthChanged,
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
  final VideoVisibleItemsChanged<T>? onVisibleItemsChanged;
  final ValueChanged<int?>? onCoverCacheWidthChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final metrics = resolveCollectionGridMetrics(
        context,
        layoutType: layoutType,
        padding: collectionCardPadding(context, padding: padding),
        availableWidth: constraints.maxWidth,
        availableHeight: constraints.hasBoundedHeight
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height,
      );
      final isGrid = layoutType != LayoutType.list;
      final listCoverSize = isGrid
          ? null
          : collectionListCoverSizeForTitle(
              context,
              titleStyle: videoCollectionListTitleStyle(context),
            );
      final coverWidth = isGrid
          ? (constraints.maxWidth -
                    metrics.padding.horizontal -
                    metrics.spacing * (metrics.crossAxisCount - 1)) /
                metrics.crossAxisCount
          : listCoverSize!.width;
      final coverCacheWidth = _videoCoverCacheWidth(context, coverWidth);
      onCoverCacheWidthChanged?.call(coverCacheWidth);
      return VirtualizedSliverCollection<T>(
        key: onVisibleItemsChanged == null
            ? pageStorageKey
            : ValueKey('${pageStorageKey.value}-$coverCacheWidth'),
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
        onVisibleItemsChanged: onVisibleItemsChanged == null
            ? null
            : (items) => onVisibleItemsChanged!([
                for (final item in items) item.item,
              ], coverCacheWidth),
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
    this.onCoverTerminal,
    this.failedCoverKeys = const {},
    this.onCoverRetry,
  });

  final VideoItem video;
  final LayoutType layoutType;
  final VoidCallback? onTap;
  final String? subtitle;
  final ValueChanged<VideoLink>? onOpenLink;
  final VideoCoverImageCallback? onCoverTerminal;
  final Set<VideoCoverImageKey> failedCoverKeys;
  final VideoCoverRetryCallback? onCoverRetry;

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
        final titleFontSize = isCompact
            ? (isLandscape ? 13.5 : 11.0)
            : (isLandscape ? 14.5 : 12.0);
        final bodyFontSize = isList
            ? (isLandscape ? 13.0 : 11.0)
            : (isLandscape ? 13.5 : 10.0);
        final chipFontSize = isList
            ? bodyFontSize
            : (isLandscape ? 13.0 : 10.0);
        final titleStyle = isList
            ? videoCollectionListTitleStyle(context)
            : Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                height: 1.1,
                fontSize: titleFontSize,
              );
        final listCoverSize = isList
            ? collectionListCoverSizeForTitle(context, titleStyle: titleStyle)
            : null;
        final title = Text(
          video.title,
          maxLines: collectionCardTitleMaxLines,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        );
        return Card(
          margin: isList
              ? const EdgeInsets.symmetric(vertical: 4)
              : EdgeInsets.zero,
          shape: layoutType != LayoutType.smallGrid
              ? null
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    collectionCoverRadius(constraints.maxWidth),
                  ),
                ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: isList
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox.fromSize(
                              size: listCoverSize!,
                              child: VideoCover(
                                video: video,
                                onImageTerminal: onCoverTerminal,
                                failedImageKeys: failedCoverKeys,
                                onImageRetry: onCoverRetry,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: title),
                          ],
                        ),
                        _information(
                          context,
                          visibleFields,
                          bodyFontSize,
                          chipFontSize: chipFontSize,
                          isList: isList,
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
                        child: VideoCover(
                          video: video,
                          onImageTerminal: onCoverTerminal,
                          failedImageKeys: failedCoverKeys,
                          onImageRetry: onCoverRetry,
                        ),
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
          Flexible(
            child: Text(
              formatDuration(Duration(seconds: seconds!)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.blue[700],
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class VideoCover extends ConsumerStatefulWidget {
  const VideoCover({
    super.key,
    required this.video,
    this.onImageTerminal,
    this.failedImageKeys = const {},
    this.onImageRetry,
  });

  final VideoItem video;
  final VideoCoverImageCallback? onImageTerminal;
  final Set<VideoCoverImageKey> failedImageKeys;
  final VideoCoverRetryCallback? onImageRetry;

  @override
  ConsumerState<VideoCover> createState() => _VideoCoverState();
}

class _VideoCoverState extends ConsumerState<VideoCover> {
  static const _loadTimeout = Duration(seconds: 10);

  final Set<VideoCoverImageKey> _reportedKeys = {};
  Timer? _loadTimer;
  VideoCoverImageKey? _loadingKey;
  VideoCoverImageKey? _failedKey;
  int _retryRevision = 0;

  void _reportTerminal(VideoCoverImageKey key, {required bool failed}) {
    if (_loadingKey != key) return;
    _loadTimer?.cancel();
    _loadTimer = null;
    if (!_reportedKeys.add(key)) return;
    widget.onImageTerminal?.call(key, failed: failed);
  }

  Widget _errorPlaceholder(
    VideoItem video,
    int? cacheWidth,
    VideoCoverImageKey key,
    S s,
  ) => ColoredBox(
    color: Colors.black12,
    child: Center(
      child: IconButton(
        tooltip: s.retry,
        onPressed: () async {
          widget.onImageRetry?.call(key);
          await ResizeImage.resizeIfNeeded(
            cacheWidth,
            null,
            NetworkImage(video.cover),
          ).evict();
          if (!mounted) return;
          setState(() {
            _failedKey = null;
            _reportedKeys.remove(key);
            _retryRevision++;
          });
        },
        icon: const Icon(Icons.refresh),
        color: Colors.black54,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final video = widget.video;
      final catalogNumber = video.catalogNumber;
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
      final infoScale = collectionCoverInfoScale(constraints.maxWidth);
      final cacheWidth = constraints.hasBoundedWidth
          ? _videoCoverCacheWidth(context, constraints.maxWidth)
          : null;
      final isLandscape =
          MediaQuery.orientationOf(context) == Orientation.landscape;
      final inset = 6 * infoScale;
      final s = S.of(context);
      Widget badge(Widget child, {Key? key}) => Container(
        key: key,
        padding: EdgeInsets.symmetric(
          horizontal: 6 * infoScale,
          vertical: 2 * infoScale,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(4 * infoScale),
        ),
        child: child,
      );
      final textStyle = TextStyle(
        color: Colors.white,
        fontSize: (isLandscape ? 13.0 : 10.0) * infoScale,
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
            _image(video, cacheWidth, s),
            if (catalogNumber != null)
              Positioned(
                top: inset,
                left: inset,
                right: inset,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: badge(
                      Text(
                        catalogNumber,
                        style: textStyle.copyWith(
                          fontSize: (isLandscape ? 13.0 : 11.0) * infoScale,
                        ),
                      ),
                      key: ValueKey('video-number-${video.id}'),
                    ),
                  ),
                ),
              ),
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
                          size: (isLandscape ? 16.0 : 14.0) * infoScale,
                        ),
                      ),
                    ),
                  if (showSubtitleTag &&
                      video.hasSubtitles &&
                      showUncensoredTag &&
                      video.isUncensored)
                    SizedBox(width: 3 * infoScale),
                  if (showUncensoredTag && video.isUncensored)
                    Tooltip(
                      message: s.videoUncensored,
                      child: badge(
                        Icon(
                          Icons.no_encryption_outlined,
                          color: Colors.white,
                          size: (isLandscape ? 16.0 : 14.0) * infoScale,
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

  Widget _image(VideoItem video, int? cacheWidth, S s) {
    if (video.cover.isEmpty) {
      _loadTimer?.cancel();
      _loadTimer = null;
      _loadingKey = null;
      return const ColoredBox(
        color: Colors.black12,
        child: Center(child: Icon(Icons.movie_outlined)),
      );
    }
    final key = (videoId: video.id, url: video.cover, cacheWidth: cacheWidth);
    if (_loadingKey != key) {
      _loadTimer?.cancel();
      _loadTimer = null;
      _loadingKey = key;
      _reportedKeys.clear();
    }
    if (_failedKey == key || widget.failedImageKeys.contains(key)) {
      _reportTerminal(key, failed: true);
      return _errorPlaceholder(video, cacheWidth, key, s);
    }
    if (!_reportedKeys.contains(key) && _loadTimer == null) {
      _loadTimer = Timer(_loadTimeout, () {
        if (!mounted) return;
        setState(() => _failedKey = key);
        _reportTerminal(key, failed: true);
      });
    }
    return Image.network(
      key: ValueKey('video-cover-${video.id}-$_retryRevision'),
      video.cover,
      cacheWidth: cacheWidth,
      fit: BoxFit.cover,
      frameBuilder: (_, child, frame, _) {
        if (frame != null) _reportTerminal(key, failed: false);
        return child;
      },
      errorBuilder: (context, error, stackTrace) {
        _failedKey = key;
        _reportTerminal(key, failed: true);
        return _errorPlaceholder(video, cacheWidth, key, s);
      },
    );
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    super.dispose();
  }
}

int? _videoCoverCacheWidth(BuildContext context, double width) {
  if (!width.isFinite) return null;
  final displayWidth = (width * MediaQuery.devicePixelRatioOf(context)).ceil();
  return displayWidth < 1 ? 1 : displayWidth;
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/work.dart';
import '../providers/auth_provider.dart';
import '../providers/work_card_display_provider.dart';
import '../providers/subtitle_library_provider.dart';
import '../services/storage_service.dart';
import '../screens/work_detail_screen.dart';
import '../utils/snackbar_util.dart';
import '../utils/string_utils.dart';
import '../utils/age_rating.dart';
import '../utils/work_cover_prefetch.dart';
import '../utils/audio_source_headers.dart';
import '../utils/collection_grid_layout.dart';
import '../../l10n/app_localizations.dart';
import 'tag_chip.dart';
import 'va_chip.dart';
import 'age_rating_chip.dart';
import 'work_bookmark_manager.dart';
import 'privacy_blur_cover.dart';
import 'work_detail/work_cover_frame.dart';
import 'app_bottom_dock_transition.dart';
import 'work_cover_image.dart';

TextStyle? enhancedWorkCardListTitleStyle(BuildContext context) {
  final isLandscape =
      MediaQuery.orientationOf(context) == Orientation.landscape;
  final titleFontSize = isLandscape ? 16.0 : 14.0;
  return Theme.of(context).textTheme.titleSmall?.copyWith(
    fontWeight: FontWeight.bold,
    height: 1.3,
    fontSize: titleFontSize,
  );
}

class EnhancedWorkCard extends ConsumerStatefulWidget {
  final Work work;
  final VoidCallback? onTap;
  final int crossAxisCount;
  final bool? isListLayout;
  final String? localCoverPath;

  const EnhancedWorkCard({
    super.key,
    required this.work,
    this.onTap,
    this.crossAxisCount = 2,
    this.isListLayout,
    this.localCoverPath,
  });

  @override
  ConsumerState<EnhancedWorkCard> createState() => _EnhancedWorkCardState();
}

class _EnhancedWorkCardState extends ConsumerState<EnhancedWorkCard> {
  bool get _isListLayout => widget.isListLayout ?? widget.crossAxisCount <= 1;

  String? _progress; // 当前收藏状态
  int? _rating; // 当前评分
  bool _loadingProgress = false; // 是否在获取状态
  bool _updating = false; // 是否在更新状态

  @override
  void initState() {
    super.initState();
    _progress = widget.work.progress; // 初始来自传入的work
    _rating = widget.work.userRating; // 初始评分
  }

  // 长按逻辑：获取最新详情(含 progress)，然后弹出编辑菜单
  Future<void> _onLongPress() async {
    if (_loadingProgress || _updating) return;
    setState(() => _loadingProgress = true);
    try {
      final api = ref.read(kikoeruApiServiceProvider);
      final json = await api.getWork(widget.work.id);
      final detailed = Work.fromJson(json);
      setState(() {
        _progress = detailed.progress; // 更新最新状态
        _rating = detailed.userRating; // 更新评分
        _loadingProgress = false;
      });
      _showEditSheet();
    } catch (e) {
      setState(() => _loadingProgress = false);
      if (mounted) {
        SnackBarUtil.showError(
          context,
          S.of(context).getStatusFailed(e.toString()),
        );
      }
    }
  }

  // 显示编辑收藏状态对话框
  Future<void> _showEditSheet() async {
    if (_updating) return; // 防止重复操作

    final manager = WorkBookmarkManager(ref: ref, context: context);

    await manager.showMarkDialog(
      workId: widget.work.id,
      currentProgress: _progress,
      currentRating: _rating,
      workTitle: widget.work.title,
      onChanged: (newProgress, newRating) {
        // 更新本地状态
        if (mounted) {
          setState(() {
            _progress = newProgress;
            _rating = newRating;
          });
        }
      },
    );

    setState(() => _updating = false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(
      authProvider.select(
        (state) => (host: state.host ?? '', token: state.token ?? ''),
      ),
    );
    final displaySettings = ref.watch(workCardDisplayProvider);
    final listTitleStyle = enhancedWorkCardListTitleStyle(context);
    final listCoverSize = _isListLayout
        ? collectionListCoverSizeForTitle(context, titleStyle: listTitleStyle)
        : null;
    final visibleTags =
        widget.work.tags
            ?.where(
              (tag) => displaySettings.showUserAddedTags || !tag.isUserAdded,
            )
            .toList(growable: false) ??
        const <Tag>[];
    final hasLocalSubtitle = ref.watch(
      subtitleLibraryProvider.select((ids) => ids.contains(widget.work.id)),
    );
    final coverCacheWidth = resolveWorkCoverCacheWidth(
      context,
      crossAxisCount: widget.crossAxisCount,
      listCoverWidth: listCoverSize?.width,
      isListCard: _isListLayout,
    );
    final initialCoverImageProvider = auth.host.isEmpty
        ? null
        : createWorkCoverImageProvider(
            work: widget.work,
            host: auth.host,
            token: auth.token,
            cacheWidth: coverCacheWidth,
          );

    final cardOnTap =
        widget.onTap ??
        () {
          pushWorkDetailRoute(
            context,
            builder: (context) => WorkDetailScreen(
              work: widget.work,
              initialCoverImageProvider: initialCoverImageProvider,
            ),
          );
        };

    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverWidth = _isListLayout
            ? listCoverSize!.width
            : constraints.maxWidth;
        final coverRadius = collectionCoverRadius(coverWidth);
        final coverInfoScale = collectionCoverInfoScale(coverWidth);
        // A very narrow grid cell should use the compact content variant even
        // when a responsive fallback reduced a nominal grid to two columns.
        final isNarrowGridCell = !_isListLayout && constraints.maxWidth < 160;
        final isCompact =
            !_isListLayout &&
            (widget.crossAxisCount >= 5 ||
                (widget.crossAxisCount == 3 && !isLandscape) ||
                isNarrowGridCell);

        if (_isListLayout) {
          return _buildFullCard(
            context,
            auth.host,
            auth.token,
            cardOnTap,
            displaySettings,
            hasLocalSubtitle,
            coverRadius,
            coverInfoScale,
            visibleTags,
            listCoverSize!,
            listTitleStyle,
            coverCacheWidth,
          );
        }
        if (isCompact) {
          return _buildCompactCard(
            context,
            auth.host,
            auth.token,
            cardOnTap,
            displaySettings,
            hasLocalSubtitle,
            coverRadius,
            coverInfoScale,
            visibleTags,
            coverCacheWidth,
          );
        }
        return _buildMediumCard(
          context,
          auth.host,
          auth.token,
          cardOnTap,
          displaySettings,
          hasLocalSubtitle,
          coverRadius,
          coverInfoScale,
          visibleTags,
          coverCacheWidth,
        );
      },
    );
  }

  // 紧凑卡片 (3列布局)
  Widget _buildCompactCard(
    BuildContext context,
    String host,
    String token,
    VoidCallback cardOnTap,
    WorkCardDisplaySettings displaySettings,
    bool hasLocalSubtitle,
    double coverRadius,
    double coverInfoScale,
    List<Tag> visibleTags,
    int coverCacheWidth,
  ) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final titleFontSize = isLandscape ? 13.5 : 11.0;
    final information = _buildCardInformation(
      context,
      displaySettings: displaySettings,
      visibleTags: visibleTags,
      isList: false,
      showSales: true,
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.all(0),
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(coverRadius),
      ),
      child: InkWell(
        onTap: cardOnTap,
        onLongPress: widget.work.isJapaneseAsmr ? null : _onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, // 让 Column 高度自适应
          children: [
            // 封面图片区域
            AspectRatio(
              aspectRatio: collectionCoverAspectRatio,
              child: Stack(
                children: [
                  _buildCoverImage(
                    context,
                    host,
                    token,
                    cornerRadius: coverRadius,
                    cacheWidth: coverCacheWidth,
                  ),
                  _buildCoverTopInfo(
                    context,
                    displaySettings,
                    coverInfoScale,
                    inset: 6 * coverInfoScale,
                  ),
                  if ((displaySettings.showSubtitleTag &&
                          (widget.work.hasSubtitle == true ||
                              hasLocalSubtitle)) ||
                      (displaySettings.showReleaseDate &&
                          widget.work.release != null))
                    _buildCoverBottomInfo(
                      context,
                      displaySettings,
                      hasLocalSubtitle,
                      coverInfoScale,
                      inset: 6 * coverInfoScale,
                    ),
                ],
              ),
            ),
            // 信息区域 - 自适应高度
            Padding(
              padding: const EdgeInsets.all(collectionGridInfoPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题
                  Text(
                    widget.work.title,
                    maxLines: collectionCardTitleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      height: 1.1,
                      fontSize: titleFontSize,
                    ),
                  ),
                  if (information.isNotEmpty)
                    const SizedBox(height: collectionCardInfoSpacing),
                  ...information,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 中等卡片 (2列布局)
  Widget _buildMediumCard(
    BuildContext context,
    String host,
    String token,
    VoidCallback cardOnTap,
    WorkCardDisplaySettings displaySettings,
    bool hasLocalSubtitle,
    double coverRadius,
    double coverInfoScale,
    List<Tag> visibleTags,
    int coverCacheWidth,
  ) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final titleFontSize = isLandscape ? 14.5 : 12.0;
    final information = _buildCardInformation(
      context,
      displaySettings: displaySettings,
      visibleTags: visibleTags,
      isList: false,
      showSales: false,
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.all(0),
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(coverRadius),
      ),
      child: InkWell(
        onTap: cardOnTap,
        onLongPress: widget.work.isJapaneseAsmr ? null : _onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 封面区域
            AspectRatio(
              aspectRatio: collectionCoverAspectRatio,
              child: Stack(
                children: [
                  _buildCoverImage(
                    context,
                    host,
                    token,
                    cornerRadius: coverRadius,
                    cacheWidth: coverCacheWidth,
                  ),
                  _buildCoverTopInfo(
                    context,
                    displaySettings,
                    coverInfoScale,
                    inset: 6 * coverInfoScale,
                  ),
                  if ((displaySettings.showSubtitleTag &&
                          (widget.work.hasSubtitle == true ||
                              hasLocalSubtitle)) ||
                      (displaySettings.showReleaseDate &&
                          widget.work.release != null))
                    _buildCoverBottomInfo(
                      context,
                      displaySettings,
                      hasLocalSubtitle,
                      coverInfoScale,
                      inset: 6 * coverInfoScale,
                    ),
                ],
              ),
            ),
            // 信息区域 - 自适应高度
            Padding(
              padding: const EdgeInsets.all(collectionGridInfoPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题
                  Text(
                    widget.work.title,
                    maxLines: collectionCardTitleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      height: 1.1,
                      fontSize: titleFontSize,
                    ),
                  ),
                  if (information.isNotEmpty)
                    const SizedBox(height: collectionCardInfoSpacing),
                  ...information,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 完整卡片 (列表布局)
  Widget _buildFullCard(
    BuildContext context,
    String host,
    String token,
    VoidCallback cardOnTap,
    WorkCardDisplaySettings displaySettings,
    bool hasLocalSubtitle,
    double coverRadius,
    double coverInfoScale,
    List<Tag> visibleTags,
    Size listCoverSize,
    TextStyle? titleStyle,
    int coverCacheWidth,
  ) {
    final information = _buildCardInformation(
      context,
      displaySettings: displaySettings,
      visibleTags: visibleTags,
      isList: true,
      showSales: true,
    );

    return Card(
      margin: const EdgeInsets.symmetric(
        vertical: collectionListCardVerticalMargin,
      ),
      elevation: 4,
      child: InkWell(
        onTap: cardOnTap,
        onLongPress: widget.work.isJapaneseAsmr ? null : _onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第一行：封面和标题
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 封面图片
                  SizedBox(
                    width: listCoverSize.width,
                    height: listCoverSize.height,
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(coverRadius),
                          child: _buildCoverImage(
                            context,
                            host,
                            token,
                            cornerRadius: coverRadius,
                            cacheWidth: coverCacheWidth,
                          ),
                        ),
                        _buildCoverTopInfo(
                          context,
                          displaySettings,
                          coverInfoScale,
                          inset: 2 * coverInfoScale,
                        ),
                        if ((displaySettings.showSubtitleTag &&
                                (widget.work.hasSubtitle == true ||
                                    hasLocalSubtitle)) ||
                            (displaySettings.showReleaseDate &&
                                widget.work.release != null))
                          _buildCoverBottomInfo(
                            context,
                            displaySettings,
                            hasLocalSubtitle,
                            coverInfoScale,
                            inset: 2 * coverInfoScale,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 标题
                  Expanded(
                    child: Text(
                      widget.work.title,
                      maxLines: collectionCardTitleMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                  ),
                ],
              ),
              if (information.isNotEmpty)
                const SizedBox(height: collectionCardInfoSpacing),
              ...information,
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildCardInformation(
    BuildContext context, {
    required WorkCardDisplaySettings displaySettings,
    required List<Tag> visibleTags,
    required bool isList,
    required bool showSales,
  }) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final bodyFontSize = isList
        ? (isLandscape ? 14.0 : 12.0)
        : (isLandscape ? 13.5 : 10.0);
    final priceFontSize = isList
        ? (isLandscape ? 13.0 : 11.0)
        : (isLandscape ? 13.5 : 10.0);
    final ratingFontSize = isList
        ? (isLandscape ? 13.0 : 11.0)
        : (isLandscape ? 13.0 : 9.0);
    final tagFontSize = isList
        ? (isLandscape ? 13.0 : 11.0)
        : (isLandscape ? 13.0 : 10.0);
    final iconSize = isList ? 14.0 : (isLandscape ? 14.0 : 12.0);
    final information = <Widget>[];
    void addField(Widget field) {
      if (information.isNotEmpty) {
        information.add(const SizedBox(height: collectionCardInfoSpacing));
      }
      information.add(field);
    }

    final work = widget.work;
    if (displaySettings.showDuration &&
        work.duration != null &&
        work.duration! > 0) {
      addField(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.access_time, color: Colors.blue, size: iconSize),
            const SizedBox(width: 2),
            Flexible(
              child: Text(
                formatDuration(Duration(seconds: work.duration!)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.blue[700],
                  fontSize: priceFontSize,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (work.vas?.isNotEmpty == true) {
      addField(_buildVoiceActorsRow(context, fontSize: tagFontSize));
    }
    if (visibleTags.isNotEmpty) {
      addField(
        _buildTagsRow(context, tags: visibleTags, fontSize: tagFontSize),
      );
    }
    if (displaySettings.showCircle && work.name?.isNotEmpty == true) {
      addField(
        Text(
          work.name!,
          style:
              (isList
                      ? Theme.of(context).textTheme.bodyMedium
                      : Theme.of(context).textTheme.bodySmall)
                  ?.copyWith(color: Colors.grey[600], fontSize: bodyFontSize),
        ),
      );
    }
    if (displaySettings.showPrice && work.price != null) {
      addField(
        Text(
          S.of(context).priceInYen(work.price!),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.red[700],
            fontWeight: FontWeight.w600,
            fontSize: priceFontSize,
          ),
        ),
      );
    }
    if (displaySettings.showRating &&
        work.rateAverage != null &&
        work.rateCount != null &&
        (work.rateCount! > 0 || work.rateAverage! != 0)) {
      addField(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star, color: Colors.amber[700], size: iconSize),
            const SizedBox(width: 2),
            Flexible(
              child: Text(
                '${work.rateAverage!.toStringAsFixed(1)} (${work.rateCount})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.amber[700],
                  fontWeight: FontWeight.w500,
                  fontSize: ratingFontSize,
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (showSales && displaySettings.showSales && work.dlCount != null) {
      addField(
        Text(
          S.of(context).soldCount('${work.dlCount}'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.grey[500],
            fontSize: isList ? priceFontSize : bodyFontSize,
          ),
        ),
      );
    }
    return information;
  }

  Widget _buildCoverImage(
    BuildContext context,
    String host,
    String token, {
    required double cornerRadius,
    required int cacheWidth,
  }) {
    final localCoverPath = widget.localCoverPath;
    if (localCoverPath != null && File(localCoverPath).existsSync()) {
      return WorkCoverClip(
        cornerRadius: cornerRadius,
        child: PrivacyBlurCover(
          child: RepaintBoundary(
            child: Image.file(
              File(localCoverPath),
              gaplessPlayback: true,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              errorBuilder: (context, error, stackTrace) =>
                  _buildPlaceholder(context),
            ),
          ),
        ),
      );
    }

    // 使用缓存网络图片，减少滚动时的解码与网络开销，提升流畅度
    if (host.isEmpty && !widget.work.isJapaneseAsmr) {
      return _buildPlaceholder(context);
    }

    final httpHeaders = sourceAwareMediaHeaders(
      widget.work.id,
      accountHeaders: StorageService.serverCookieHeaders,
    );

    return WorkCoverClip(
      cornerRadius: cornerRadius,
      child: PrivacyBlurCover(
        child: RepaintBoundary(
          child: WorkCoverImage(
            image: createWorkCoverImageProvider(
              work: widget.work,
              host: host,
              token: token,
              headers: httpHeaders,
              cacheWidth: cacheWidth,
            ),
            width: double.infinity,
            height: double.infinity,
            placeholder: _buildPlaceholder,
            errorBuilder: (context, _, __) => _buildPlaceholder(context),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(color: Colors.grey[300]),
      child: const Icon(Icons.audiotrack, color: Colors.grey, size: 32),
    );
  }

  Widget _buildCoverTopInfo(
    BuildContext context,
    WorkCardDisplaySettings displaySettings,
    double coverInfoScale, {
    required double inset,
  }) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final showAgeRating =
        displaySettings.showAgeRating &&
        AgeRatingFormatter.hasValue(widget.work.age);
    final rjFontSize =
        (_isListLayout
            ? (isLandscape ? 11.0 : 10.0)
            : (isLandscape ? 13.0 : 11.0)) *
        coverInfoScale;
    final ageFontSize =
        (_isListLayout ? (isLandscape ? 11.0 : 10.0) : 10.0) * coverInfoScale;

    return Positioned(
      top: inset,
      left: inset,
      right: inset,
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.topStart,
                child: _buildRjTag(rjFontSize, coverInfoScale),
              ),
            ),
          ),
          if (showAgeRating)
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.topEnd,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.topEnd,
                  child: AgeRatingChip(
                    age: widget.work.age,
                    compact: true,
                    fontSize: ageFontSize,
                    padding: EdgeInsets.symmetric(
                      horizontal: 6 * coverInfoScale,
                      vertical: 2 * coverInfoScale,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCoverBottomInfo(
    BuildContext context,
    WorkCardDisplaySettings displaySettings,
    bool hasLocalSubtitle,
    double coverInfoScale, {
    required double inset,
  }) {
    final showSubtitle =
        displaySettings.showSubtitleTag &&
        (widget.work.hasSubtitle == true || hasLocalSubtitle);
    final showReleaseDate =
        displaySettings.showReleaseDate && widget.work.release != null;

    return Positioned(
      bottom: inset,
      left: inset,
      right: inset,
      child: Row(
        children: [
          if (showSubtitle)
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.bottomStart,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.bottomStart,
                  child: _buildSubtitleTag(
                    context,
                    isLocal: hasLocalSubtitle,
                    coverInfoScale: coverInfoScale,
                  ),
                ),
              ),
            ),
          if (showSubtitle && showReleaseDate)
            SizedBox(width: 4 * coverInfoScale),
          if (showReleaseDate)
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.bottomEnd,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.bottomEnd,
                  child: _buildDateTag(coverInfoScale),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRjTag(double fontSize, double coverInfoScale) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 6 * coverInfoScale,
        vertical: 2 * coverInfoScale,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4 * coverInfoScale),
      ),
      child: Text(
        widget.work.displayId,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildDateTag(double coverInfoScale) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final fontSize = (isLandscape ? 13.0 : 10.0) * coverInfoScale;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 6 * coverInfoScale,
        vertical: 2 * coverInfoScale,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4 * coverInfoScale),
      ),
      child: Text(
        widget.work.release!,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildSubtitleTag(
    BuildContext context, {
    bool isLocal = false,
    required double coverInfoScale,
  }) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final iconSize = (isLandscape ? 16.0 : 14.0) * coverInfoScale;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 6 * coverInfoScale,
        vertical: 2 * coverInfoScale,
      ),
      decoration: BoxDecoration(
        color: isLocal
            ? Colors.green.withValues(alpha: 0.9)
            : Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4 * coverInfoScale),
      ),
      child: Icon(Icons.closed_caption, color: Colors.white, size: iconSize),
    );
  }

  Widget _buildTagsRow(
    BuildContext context, {
    required List<Tag> tags,
    required double fontSize,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 14),
      child: Wrap(
        spacing: 3,
        runSpacing: 2,
        children: tags.map((tag) {
          return TagChip(
            tag: tag,
            fontSize: fontSize,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            borderRadius: 6,
            fontWeight: FontWeight.w500,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildVoiceActorsRow(
    BuildContext context, {
    required double fontSize,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 14),
      child: Wrap(
        spacing: 3,
        runSpacing: 2,
        children: widget.work.vas!.map((va) {
          return VaChip(
            va: va,
            fontSize: fontSize,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            borderRadius: 6,
            fontWeight: FontWeight.w500,
          );
        }).toList(),
      ),
    );
  }
}

import 'dart:async';
import '../../widgets/app_bottom_dock_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:math' as math;
import '../../../l10n/app_localizations.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/scrollable_appbar.dart';
import '../../widgets/metadata_search_chip.dart';
import '../../widgets/work_detail/work_cover_frame.dart';
import '../../widgets/work_detail/work_title_header.dart';
import '../../widgets/work_detail/work_detail_section_title.dart';
import '../../widgets/work_detail/work_extra_sections.dart';
import '../../providers/work_card_display_provider.dart';
import '../../providers/works_provider.dart' show LayoutType;
import '../../utils/collection_grid_layout.dart';
import '../../utils/system_ui_style.dart';
import '../../services/log_service.dart';
import '../../services/storage_service.dart';
import 'comic_search_screen.dart';
import '../../utils/snackbar_util.dart';
import '../comic_models.dart';
import '../comic_providers.dart';
import 'comic_widgets.dart';
import 'comic_reader_screen.dart';
import 'comic_actions.dart';
import 'comic_chapter_thumbnails.dart';

class ComicDetailScreen extends ConsumerStatefulWidget {
  const ComicDetailScreen({
    super.key,
    required this.comic,
    this.initialGridCoverWidth,
    this.initialWindowWidth,
    this.initialCoverCacheWidth,
    this.initialCoverAspectRatio,
  });
  final Comic comic;
  final double? initialGridCoverWidth;
  final double? initialWindowWidth;
  final int? initialCoverCacheWidth;
  final double? initialCoverAspectRatio;
  @override
  ConsumerState<ComicDetailScreen> createState() => _ComicDetailScreenState();
}

class _ComicDetailScreenState extends ConsumerState<ComicDetailScreen> {
  late Comic _comic = widget.comic;
  late List<ComicChapter> _chapters = widget.comic.chapters;
  final Stopwatch _loadTime = Stopwatch()..start();
  final Completer<void> _initialContentReady = Completer<void>();
  Animation<double>? _routeAnimation;
  bool _initialContentVisible = false;
  bool _initialContentScheduled = false;
  bool _chapterRequestStarted = false;
  int _metadataGeneration = 0;
  bool _metadataLoading = true;
  bool _chaptersLoading = true;
  Object? _metadataError;
  Object? _chaptersError;
  bool _busy = false;
  Object? _favoriteError;
  MediaQueryData? _readerWindow;
  bool _readerReturning = false;
  Comic get _readyComic => _comic.withChapters(_chapters);

  Future<void> _load() async {
    final downloads = ref.read(comicDownloadsProvider);
    await downloads.ready;
    if (!mounted) return;
    final saved = downloads.completedComics
        .where((c) => c.key == widget.comic.key)
        .firstOrNull;
    if (saved != null) {
      await _initialContentReady.future;
      if (!mounted) return;
      setState(() {
        _comic = saved;
        _chapters = saved.chapters;
        _metadataLoading = false;
        _chaptersLoading = false;
      });
      _logTiming('metadata complete');
      _logTiming('chapters complete');
      return;
    }
    await _loadMetadata();
  }

  void _logTiming(String stage) => LogService.instance.info(
    'Detail $stage ${_loadTime.elapsedMilliseconds}ms (${widget.comic.source})',
    tag: 'Comics',
  );

  Future<void> _loadMetadata() async {
    final generation = ++_metadataGeneration;
    setState(() {
      _metadataLoading = true;
      _metadataError = null;
    });
    Comic? response;
    Object? loadError;
    try {
      response = await ref
          .read(comicSourcesProvider)
          .firstWhere((s) => s.key == widget.comic.source)
          .details(widget.comic.id);
    } catch (error) {
      loadError = error;
    }
    if (!mounted || generation != _metadataGeneration) return;
    if (_chaptersLoading && !_chapterRequestStarted) {
      unawaited(_loadChapters(comic: response ?? _comic));
    }

    await _initialContentReady.future;
    if (!mounted || generation != _metadataGeneration) return;
    try {
      if (response != null) {
        setState(
          () => _comic = Comic.fromJson({
            ...response!.toJson(),
            'extra': {
              ...response.extra,
              if (response.coverDate == null && _comic.coverDate != null)
                'sourceDate': _comic.extra['sourceDate'],
              if (response.publishedDate == null &&
                  _comic.publishedDate != null)
                'publishedAt': _comic.extra['publishedAt'],
              if (response.updatedDate == null && _comic.updatedDate != null)
                'updatedAt': _comic.extra['updatedAt'],
            },
          }),
        );
      } else {
        setState(() => _metadataError = loadError);
      }
    } catch (error) {
      setState(() => _metadataError = error);
    }
    setState(() => _metadataLoading = false);
    _logTiming(
      _metadataError == null ? 'metadata complete' : 'metadata failed',
    );
  }

  Future<void> _loadChapters({Comic? comic}) async {
    if (_chapterRequestStarted) return;
    _chapterRequestStarted = true;
    if (_initialContentVisible) {
      setState(() {
        _chaptersLoading = true;
        _chaptersError = null;
      });
    }
    Object? loadError;
    List<ComicChapter>? response;
    try {
      response = await ref
          .read(comicSourcesProvider)
          .firstWhere((s) => s.key == widget.comic.source)
          .chapters(comic ?? _comic);
    } catch (error) {
      loadError = error;
    }
    await _initialContentReady.future;
    if (!mounted) return;
    _chapterRequestStarted = false;
    setState(() {
      if (loadError == null) {
        _chapters = response!;
        _chaptersError = null;
      } else {
        _chaptersError = loadError;
      }
      _chaptersLoading = false;
    });
    _logTiming(
      _chaptersError == null ? 'chapters complete' : 'chapters failed',
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _logTiming('first visible');
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (_routeAnimation != animation) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = animation;
      animation?.addStatusListener(_onRouteStatus);
    }
    _scheduleInitialContentReady();
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _scheduleInitialContentReady();
  }

  void _scheduleInitialContentReady() {
    if (_initialContentReady.isCompleted || _initialContentScheduled) return;
    final animation = _routeAnimation;
    if (animation != null && animation.status != AnimationStatus.completed) {
      return;
    }
    _initialContentScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialContentScheduled = false;
      if (!mounted ||
          (_routeAnimation != null &&
              _routeAnimation!.status != AnimationStatus.completed)) {
        return;
      }
      _initialContentReady.complete();
      setState(() => _initialContentVisible = true);
    });
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    if (!_initialContentReady.isCompleted) _initialContentReady.complete();
    super.dispose();
  }

  Future<void> _read(
    Comic comic, {
    ComicChapter? chapter,
    int? initialPage,
  }) async {
    if (!_initialContentVisible || comic.chapters.isEmpty) return;
    final progress = await ref.read(comicLibraryProvider).progress(comic);
    chapter ??=
        comic.chapters.where((c) => c.id == progress?.chapterId).firstOrNull ??
        comic.chapters.first;
    if (!mounted) return;
    setState(() {
      _readerWindow = MediaQuery.of(context);
      _readerReturning = false;
    });
    final route = MaterialPageRoute<void>(
      builder: (_) => ComicReaderScreen(
        comic: comic,
        chapter: chapter!,
        initialPage:
            initialPage ??
            (progress?.chapterId == chapter.id ? progress!.page : 0),
      ),
    );
    await Navigator.of(context).push(route);
    await route.completed;
    if (mounted) setState(() => _readerReturning = true);
  }

  Future<void> _favorite(Comic comic) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _favoriteError = null;
    });
    try {
      await saveComicFavorite(ref, comic);
      if (mounted) SnackBarUtil.showSuccess(context, S.of(context).comicSaved);
    } catch (e) {
      if (mounted) setState(() => _favoriteError = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(Comic comic) async {
    if (!_initialContentVisible) return;
    await downloadComicChapters(context, ref, comic);
  }

  void _comments(Comic comic) {
    final source = ref
        .read(comicSourcesProvider)
        .firstWhere((s) => s.key == comic.source);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            _CommentsScreen(comic: comic, load: () => source.comments(comic)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(comicSettingsRevisionProvider);
    final current = MediaQuery.of(context);
    final saved = _readerWindow;
    if (saved != null &&
        (current.size.width != saved.size.width ||
            current.devicePixelRatio != saved.devicePixelRatio ||
            (_readerReturning &&
                current.padding == saved.padding &&
                current.viewPadding == saved.viewPadding))) {
      _readerWindow = null;
    }
    final retained = _readerWindow;
    // Keep both the detail's viewport and safe area while the reader hides
    // system bars, until the platform restores the insets after route removal.
    return MediaQuery(
      data: retained == null
          ? current
          : current.copyWith(
              size: retained.size,
              padding: retained.padding,
              viewPadding: retained.viewPadding,
            ),
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: retained?.size.width,
        maxWidth: retained?.size.width,
        minHeight: retained?.size.height,
        maxHeight: retained?.size.height,
        child: Builder(builder: _buildDetail),
      ),
    );
  }

  Widget _buildDetail(BuildContext context) {
    final s = S.of(context);
    return GlobalAudioPlayerWrapper.workDetails(
      child: Scaffold(
        appBar: ScrollableAppBar(
          systemOverlayStyle: transparentSystemBarsForBrightness(
            Theme.of(context).brightness,
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            _comic.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          actions: [
            IconButton(
              tooltip: s.download,
              icon: const Icon(Icons.download),
              onPressed: !_initialContentVisible || _chapters.isEmpty
                  ? null
                  : () => _download(_readyComic),
            ),
            IconButton(
              tooltip: s.comicFavorites,
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: _busy ? null : () => _favorite(_readyComic),
            ),
          ],
        ),
        body: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final s = S.of(context);
    final comic = _readyComic;
    final showThumbnails =
        StorageService.getBool('comic_chapter_thumbnails') ?? true;
    final hasComments = ref
        .read(comicSourcesProvider)
        .firstWhere((source) => source.key == comic.source)
        .hasComments;
    final sectionCount = hasComments ? 4 : 3;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final metrics = resolveCollectionGridMetrics(
          context,
          layoutType: LayoutType.bigGrid,
          cardSize: WorkCardSize.normal,
          availableWidth: width,
          availableHeight: constraints.maxHeight,
        );
        final detailPadding = metrics.crossAxisCount == 1
            ? metrics.padding.left
            : 16.0;
        final contentWidth = math.min(width, 1200) - detailPadding * 2;
        final gridCoverWidth =
            (width -
                metrics.padding.horizontal -
                metrics.spacing * (metrics.crossAxisCount - 1)) /
            metrics.crossAxisCount;
        final coverWidth = math.min(
          widget.initialWindowWidth == MediaQuery.sizeOf(context).width
              ? widget.initialGridCoverWidth ?? gridCoverWidth
              : gridCoverWidth,
          contentWidth,
        );
        final stacked =
            metrics.crossAxisCount == 1 || contentWidth - coverWidth - 16 < 120;
        final cover = ComicCover(
          key: const ValueKey('comic-detail-cover'),
          source: widget.comic.source,
          page: _comic.coverPage,
          cornerRadius: workCoverDetailRadius,
          maxWidth: coverWidth,
          initialCacheWidth: widget.initialCoverCacheWidth,
          initialAspectRatio: widget.initialCoverAspectRatio,
          deferCacheUpgradeUntilRouteCompleted: true,
          preservePreviousImage: true,
        );
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WorkTitleHeader(title: comic.title, showTranslateButton: false),
            const SizedBox(height: 8),
            Text(
              ref
                  .read(comicSourcesProvider)
                  .firstWhere((s) => s.key == comic.source)
                  .name,
            ),
            if (comic.rating != null) Text('${s.ratingLabel}: ${comic.rating}'),
            if (comic.extra['likes'] != null)
              Row(
                children: [
                  const Icon(Icons.thumb_up_alt_outlined, size: 16),
                  const SizedBox(width: 4),
                  Text('${comic.extra['likes']}'),
                ],
              ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) => Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: math.min(200, constraints.maxWidth - 8),
                    child: FilledButton(
                      onPressed: !_initialContentVisible || _chapters.isEmpty
                          ? null
                          : () => _read(comic),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.menu_book),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              s.comicContinue,
                              textAlign: TextAlign.center,
                              softWrap: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
        return Center(
          child: SizedBox(
            width: math.min(width, 1200),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.all(detailPadding),
                  sliver: SliverMainAxisGroup(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (stacked)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  cover,
                                  const SizedBox(height: 16),
                                  info,
                                ],
                              )
                            else
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(width: coverWidth, child: cover),
                                  const SizedBox(width: 16),
                                  Expanded(child: info),
                                ],
                              ),
                            const SizedBox(height: 16),
                            if (_busy)
                              const RepaintBoundary(
                                child: LinearProgressIndicator(),
                              ),
                            if (_favoriteError != null)
                              _retryBanner(
                                _favoriteError!,
                                () => _favorite(comic),
                              ),
                            if (_metadataLoading)
                              const RepaintBoundary(
                                child: LinearProgressIndicator(),
                              ),
                            if (_metadataError != null)
                              _retryBanner(_metadataError!, _loadMetadata),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                      SliverList.builder(
                        itemCount:
                            sectionCount +
                            (_initialContentVisible ? _chapters.length : 0),
                        itemBuilder: (context, index) {
                          if (index >= sectionCount) {
                            final chapter = _chapters[index - sectionCount];
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ListTile(
                                  title: Text(chapter.title),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => _read(comic, chapter: chapter),
                                ),
                                if (showThumbnails &&
                                    !_metadataLoading &&
                                    !_chaptersLoading)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: ComicChapterThumbnails(
                                      key: ValueKey(
                                        '${comic.key}-${chapter.id}',
                                      ),
                                      comic: comic,
                                      chapter: chapter,
                                      onSelected: (page) => _read(
                                        comic,
                                        chapter: chapter,
                                        initialPage: page,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          }
                          if (index == 0) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: SelectableText(comic.description),
                            );
                          }
                          if (index == 1) {
                            final authors = comic.authors;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (authors.isNotEmpty) ...[
                                  WorkDetailSectionTitle(s.author),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: [
                                      for (final author in authors)
                                        MetadataSearchChip(
                                          label: author,
                                          searchKeyword: author,
                                          searchTypeLabel: s.author,
                                          searchParams: const {},
                                          chipTone: MetadataChipTone.secondary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          borderRadius: 6,
                                          onTap: () => pushBottomDockRoute(
                                            context,
                                            builder: (_) => ComicSearchScreen(
                                              initialSource: comic.source,
                                              initialQuery: author,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                ],
                                if (comic.tags.isNotEmpty) ...[
                                  WorkDetailSectionTitle(s.tagLabel),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: comic.tags
                                        .toSet()
                                        .map(
                                          (tag) => MetadataSearchChip(
                                            label: tag,
                                            searchKeyword: tag,
                                            searchTypeLabel: s.tagLabel,
                                            searchParams: const {},
                                            chipTone: MetadataChipTone.primary,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            borderRadius: 6,
                                            onTap: () => pushBottomDockRoute(
                                              context,
                                              builder: (_) => ComicSearchScreen(
                                                initialSource: comic.source,
                                                initialQuery: tag,
                                              ),
                                            ),
                                          ),
                                        )
                                        .toList(),
                                  ),
                                  const SizedBox(height: 16),
                                ],
                                WorkReleaseDateSection(
                                  release: comic.publishedDate,
                                ),
                                if (comic.updatedDate != null) ...[
                                  WorkDetailSectionTitle(s.lastUpdated),
                                  const SizedBox(height: 8),
                                  Text(
                                    comic.updatedDate!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontSize: 14),
                                  ),
                                  const SizedBox(height: 16),
                                ],
                              ],
                            );
                          }
                          if (hasComments && index == 2) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  s.comicComments,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _comments(comic),
                              ),
                            );
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.comicChapters,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                if (_chaptersLoading)
                                  const RepaintBoundary(
                                    child: LinearProgressIndicator(),
                                  ),
                                if (_chaptersError != null)
                                  _retryBanner(
                                    _chaptersError!,
                                    () => _loadChapters(comic: _comic),
                                  ),
                              ],
                            ),
                          );
                        },
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

  Widget _retryBanner(Object error, VoidCallback retry) => MaterialBanner(
    content: Text('$error'),
    actions: [TextButton(onPressed: retry, child: Text(S.of(context).retry))],
  );
}

class _CommentsScreen extends StatefulWidget {
  const _CommentsScreen({required this.comic, required this.load});
  final Comic comic;
  final Future<List<ComicComment>> Function() load;
  @override
  State<_CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends State<_CommentsScreen> {
  late Future<List<ComicComment>> _comments = widget.load();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(S.of(context).comicComments)),
    body: FutureBuilder<List<ComicComment>>(
      future: _comments,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ComicErrorView(
            error: snapshot.error!,
            retry: () => setState(() => _comments = widget.load()),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          children: [
            for (final c in snapshot.data!)
              ListTile(
                leading: c.avatar == null
                    ? const CircleAvatar(child: Icon(Icons.person_outline))
                    : ClipOval(
                        child: SizedBox.square(
                          dimension: 40,
                          child: Center(
                            child: ComicCover(
                              source: widget.comic.source,
                              page: c.avatar!,
                              maxWidth: 40,
                              maxHeight: 40,
                              placeholderAspectRatio: 1,
                              cornerRadius: 0,
                            ),
                          ),
                        ),
                      ),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.author),
                    if (c.createdAt != null)
                      Text(
                        S
                            .of(context)
                            .comicCommentTime(
                              c.createdAt!.toLocal(),
                              c.createdAt!.toLocal(),
                            ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
                subtitle: Text(c.text),
                trailing: c.score == null ? null : Text(c.score!),
              ),
          ],
        );
      },
    ),
  );
}

import 'dart:async';
import '../../widgets/app_bottom_dock_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:math' as math;
import '../../../l10n/app_localizations.dart';
import '../../widgets/app_navigation_scope.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/scrollable_appbar.dart';
import '../../widgets/metadata_search_chip.dart';
import '../../widgets/cover_preview_dialog.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sliver_tab_page_view.dart';
import '../../widgets/tab_page_motion.dart';
import '../../widgets/work_detail/work_cover_frame.dart';
import '../../widgets/work_detail/work_title_header.dart';
import '../../widgets/work_detail/work_detail_section_title.dart';
import '../../widgets/work_detail/work_detail_date.dart';
import '../../providers/works_provider.dart' show LayoutType;
import '../../utils/collection_grid_layout.dart';
import '../../utils/system_ui_style.dart';
import '../../services/log_service.dart';
import '../../services/storage_service.dart';
import 'comic_search_screen.dart';
import '../../utils/snackbar_util.dart';
import '../comic_models.dart';
import '../comic_source.dart';
import '../comic_providers.dart';
import '../eh_tag_translations.dart';
import 'comic_widgets.dart';
import 'comic_reader_screen.dart';
import 'comic_page_preview.dart';
import 'comic_actions.dart';
import 'comic_chapter_thumbnails.dart';

class ComicDetailScreen extends ConsumerStatefulWidget {
  const ComicDetailScreen({
    super.key,
    required this.comic,
    this.initialCoverCacheWidth,
    this.initialCoverAspectRatio,
  });
  final Comic comic;
  final int? initialCoverCacheWidth;
  final double? initialCoverAspectRatio;
  @override
  ConsumerState<ComicDetailScreen> createState() => _ComicDetailScreenState();
}

class _ComicDetailScreenState extends ConsumerState<ComicDetailScreen>
    with TickerProviderStateMixin {
  late Comic _comic = widget.comic;
  late List<ComicChapter> _chapters = widget.comic.chapters;
  late bool? _remoteFavorite = _sourceFavorite(widget.comic);
  final _chapterPreviewPages = <String, Future<List<ComicPage>>>{};
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
  bool _localFavorite = false;
  bool _favoriteReady = false;
  int _favoriteGeneration = 0;
  int _favoriteVersion = 0;
  bool _busy = false;
  Object? _favoriteError;
  bool? _favoriteRetryValue;
  bool _favoriteRetryRequiresSource = false;
  ComicProgress? _lastProgress;
  int _progressGeneration = 0;
  MediaQueryData? _readerWindow;
  Size? _readerBodySize;
  bool _readerReturning = false;
  late final bool _hasComments;
  late final TabController _detailTabs;
  late final AnimationController _detailPagePosition;
  final _detailTabGroupKey = GlobalKey();
  final _detailTabScrollOffsets = <int, double>{};
  int _selectedDetailTab = 0;
  Future<List<ComicComment>>? _commentsFuture;
  bool _reduceDetailMotion = false;
  bool _detailTabSyncScheduled = false;
  double? _unpinnedDetailOffset;
  int? _detailMotionTarget;
  int _detailMotionGeneration = 0;
  int? _detailTransitionSource;
  Comic get _readyComic => _comic.withChapters(_chapters);
  bool get _isFavorite => _localFavorite || _remoteFavorite == true;

  static bool? _sourceFavorite(Comic comic) {
    if (comic.extra['favoriteId'] != null) return true;
    return comic.extra['isFavorite'] is bool
        ? comic.extra['isFavorite'] as bool
        : null;
  }

  static Comic _withSourceFavorite(Comic comic, bool value) {
    final extra = {...comic.extra, 'isFavorite': value};
    if (!value) extra.remove('favoriteId');
    return Comic.fromJson({...comic.toJson(), 'extra': extra});
  }

  Future<void> _load() async {
    final favoriteVersion = _favoriteVersion;
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
        final extra = {...saved.extra};
        if (_remoteFavorite != null) {
          extra['isFavorite'] = _remoteFavorite;
          if (_remoteFavorite == false) {
            extra.remove('favoriteId');
          } else if (_comic.extra['favoriteId'] != null) {
            extra['favoriteId'] = _comic.extra['favoriteId'];
          }
        }
        _comic = Comic.fromJson({...saved.toJson(), 'extra': extra});
        _chapters = saved.chapters;
        if (_favoriteVersion == favoriteVersion) {
          _remoteFavorite = _sourceFavorite(_comic);
        }
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
    final favoriteVersion = _favoriteVersion;
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
        final updated = Comic.fromJson({
          ...response.toJson(),
          'extra': {
            ...response.extra,
            if (!response.extra.containsKey('isFavorite') &&
                _comic.extra['isFavorite'] == true)
              'isFavorite': true,
            if (response.extra['favoriteId'] == null &&
                _comic.extra['favoriteId'] != null)
              'favoriteId': _comic.extra['favoriteId'],
            if (response.coverDate == null && _comic.coverDate != null)
              'sourceDate': _comic.extra['sourceDate'],
            if (response.publishedDate == null && _comic.publishedDate != null)
              'publishedAt': _comic.extra['publishedAt'],
            if (response.updatedDate == null && _comic.updatedDate != null)
              'updatedAt': _comic.extra['updatedAt'],
          },
        });
        setState(() {
          _comic = updated;
          if (_favoriteVersion == favoriteVersion) {
            _remoteFavorite = _sourceFavorite(updated);
          } else {
            _comic = _withSourceFavorite(updated, _remoteFavorite == true);
          }
        });
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
    _hasComments = ref
        .read(comicSourcesProvider)
        .firstWhere((source) => source.key == widget.comic.source)
        .hasComments;
    _detailTabs = TabController(
      length: _hasComments ? 2 : 1,
      animationDuration: Duration.zero,
      vsync: this,
    );
    _detailPagePosition = AnimationController(
      vsync: this,
      lowerBound: 0,
      upperBound: 1,
    )..addListener(_handleDetailPagePositionChanged);
    if (widget.comic.source == 'ehentai') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) retryEhTagTranslations(ref);
      });
    }
    _load();
    unawaited(_refreshFavorite());
    unawaited(_refreshProgress());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _logTiming('first visible');
    });
  }

  Future<void> _refreshProgress() async {
    final generation = ++_progressGeneration;
    ComicProgress? progress;
    try {
      progress = await ref.read(comicLibraryProvider).progress(_comic);
    } catch (_) {
      // Reading progress is optional detail-page context.
    }
    if (!mounted || generation != _progressGeneration) return;
    setState(() => _lastProgress = progress);
  }

  Future<void> _refreshFavorite() async {
    final generation = ++_favoriteGeneration;
    var favorite = false;
    try {
      favorite = await ref.read(comicLibraryProvider).isFavorite(_comic);
    } catch (_) {
      // The source favorite marker still works if the local library is unavailable.
    }
    if (!mounted || generation != _favoriteGeneration) return;
    setState(() {
      _localFavorite = favorite;
      _favoriteReady = true;
    });
  }

  ComicChapter? _lastReadChapter(ComicProgress progress) =>
      _chapters
          .where((chapter) => chapter.id == progress.chapterId)
          .firstOrNull ??
      progress.comic.chapters
          .where((chapter) => chapter.id == progress.chapterId)
          .firstOrNull;

  Future<void> _showPagePreview(
    Comic comic,
    ComicChapter chapter,
    int initialPage,
    List<ComicPage> pages,
  ) async {
    final source = ref
        .read(comicSourcesProvider)
        .firstWhere((source) => source.key == comic.source);
    final loadImage = ref.read(comicImageLoaderProvider);
    final sheetWidth = ComicPagePreview.sheetWidthFor(context);
    final fillHeight =
        sheetWidth != null &&
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final selected = await showResponsiveBottomSheet<int>(
      context: context,
      maxWidth: sheetWidth,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: fillHeight ? 1 : .7,
        minChildSize: fillHeight ? 1 : .35,
        maxChildSize: fillHeight ? 1 : .95,
        builder: (context, controller) => ComicPagePreview(
          pageCount: pages.length,
          initialPage: initialPage,
          title: chapter.title,
          scrollController: controller,
          loadImage: (index) => loadImage(source, pages[index]),
          onSelected: (page) => Navigator.pop(sheetContext, page),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    await _read(comic, chapter: chapter, initialPage: selected);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion && !_reduceDetailMotion) {
      _reduceDetailMotion = true;
      if (_detailTransitionSource != null) {
        unawaited(
          _animateToDetailPage(
            (_detailMotionTarget ?? _selectedDetailTab).toDouble(),
          ),
        );
      }
    } else {
      _reduceDetailMotion = reduceMotion;
    }
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
    _detailTabs.dispose();
    _detailPagePosition
      ..removeListener(_handleDetailPagePositionChanged)
      ..dispose();
    if (!_initialContentReady.isCompleted) _initialContentReady.complete();
    super.dispose();
  }

  void _moveToDetailTab(int index) {
    syncTabWithPagePosition(_detailTabs, _detailPagePosition.value);
    if ((_detailTransitionSource == null && index == _selectedDetailTab) ||
        (_detailTransitionSource != null && _detailMotionTarget == index)) {
      return;
    }
    _beginDetailTabTransition();
    if (_hasComments && index == 1 && _commentsFuture == null) {
      setState(() {
        _commentsFuture = _loadComments();
      });
    }
    _animateToDetailPage(index.toDouble());
  }

  void _beginDetailTabTransition() {
    final resourceOffset = _detailResourceScrollOffset();
    _unpinnedDetailOffset = resourceOffset < 0 ? resourceOffset : null;
    if (_detailTransitionSource != null) return;
    final source = _selectedDetailTab.clamp(0, _detailTabs.length - 1).toInt();
    setState(() {
      _detailTransitionSource = source;
      _detailTabScrollOffsets[source] = resourceOffset
          .clamp(0.0, double.infinity)
          .toDouble();
    });
  }

  Future<void> _animateToDetailPage(double target) async {
    final page = target
        .clamp(0.0, (_detailTabs.length - 1).toDouble())
        .toDouble();
    if (_detailTransitionSource == null && page.round() != _selectedDetailTab) {
      _beginDetailTabTransition();
    }
    final generation = ++_detailMotionGeneration;
    final targetTab = page.round();
    _detailMotionTarget = targetTab;
    _detailPagePosition.stop(canceled: true);
    if (_reduceDetailMotion) {
      _detailPagePosition.value = page;
    } else {
      await _detailPagePosition.animateTo(
        page,
        duration: tabPageDuration,
        curve: Curves.ease,
      );
    }
    await _restoreDetailPageOffset(targetTab, generation);
  }

  void _updateDetailPagePosition(double pageDelta) {
    _detailMotionTarget = null;
    _detailPagePosition.value = (_detailPagePosition.value + pageDelta)
        .clamp(0.0, (_detailTabs.length - 1).toDouble())
        .toDouble();
  }

  void _settleDetailPagePosition(double velocity) {
    final page = _detailPagePosition.value;
    final target = velocity.abs() > 0.5
        ? (velocity > 0 ? page.floor() + 1 : page.ceil() - 1)
        : page.round();
    _animateToDetailPage(target.clamp(0, _detailTabs.length - 1).toDouble());
  }

  void _handleDetailPagePositionChanged() {
    if (!mounted) return;
    final page = _detailPagePosition.value
        .clamp(0.0, (_detailTabs.length - 1).toDouble())
        .toDouble();
    if (_detailTabs.indexIsChanging) {
      _scheduleDetailTabSync();
    } else {
      syncTabWithPagePosition(_detailTabs, page);
    }
    final selected = page.round();
    if (selected == _selectedDetailTab) return;
    setState(() {
      _selectedDetailTab = selected;
      if (_hasComments && selected == 1) {
        _commentsFuture ??= _loadComments();
      }
    });
  }

  void _scheduleDetailTabSync() {
    if (_detailTabSyncScheduled) return;
    _detailTabSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _detailTabSyncScheduled = false;
      if (!mounted) return;
      if (_detailTabs.indexIsChanging) {
        _scheduleDetailTabSync();
        return;
      }
      syncTabWithPagePosition(_detailTabs, _detailPagePosition.value);
    });
  }

  double _detailResourceScrollOffset() {
    final groupContext = _detailTabGroupKey.currentContext;
    final renderObject = groupContext?.findRenderObject();
    final position = groupContext == null
        ? null
        : Scrollable.maybeOf(groupContext, axis: Axis.vertical)?.position;
    if (position == null ||
        !position.hasContentDimensions ||
        renderObject == null) {
      return 0;
    }
    final viewport = RenderAbstractViewport.maybeOf(renderObject);
    if (viewport == null) return 0;
    final resourceTop = viewport.getOffsetToReveal(renderObject, 0).offset;
    return position.pixels - resourceTop;
  }

  Future<void> _restoreDetailPageOffset(int page, int generation) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _detailMotionGeneration) return;
    final groupContext = _detailTabGroupKey.currentContext;
    final renderObject = groupContext?.findRenderObject();
    final position = groupContext == null || !groupContext.mounted
        ? null
        : Scrollable.maybeOf(groupContext, axis: Axis.vertical)?.position;
    final viewport = renderObject == null
        ? null
        : RenderAbstractViewport.maybeOf(renderObject);
    if (position != null &&
        position.hasContentDimensions &&
        renderObject != null &&
        viewport != null) {
      final resourceTop = viewport.getOffsetToReveal(renderObject, 0).offset;
      final offset =
          (resourceTop +
                  (_unpinnedDetailOffset ?? _detailTabScrollOffsets[page] ?? 0))
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
      if (position.pixels != offset) position.jumpTo(offset);
    }
    if (mounted && generation == _detailMotionGeneration) {
      setState(() {
        _detailTransitionSource = null;
        _detailMotionTarget = null;
        _unpinnedDetailOffset = null;
      });
    }
  }

  Future<List<ComicComment>> _loadComments() {
    final future = ref
        .read(comicSourcesProvider)
        .firstWhere((source) => source.key == _comic.source)
        .comments(_readyComic);
    // The tab's FutureBuilder attaches on the next frame.
    future.ignore();
    return future;
  }

  void _retryComments() => setState(() {
    _commentsFuture = _loadComments();
  });

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
    final readerBodySize = (context.findRenderObject() as RenderBox).size;
    setState(() {
      _readerWindow = MediaQuery.of(context);
      _readerBodySize = readerBodySize;
      _readerReturning = false;
    });
    final route = MaterialPageRoute<void>(
      settings: appImmersiveRouteSettings,
      builder: (_) => ComicReaderScreen(
        comic: comic,
        chapter: chapter!,
        initialPage:
            initialPage ??
            (progress?.chapterId == chapter.id ? progress!.page : 0),
      ),
    );
    await AppNavigationScope.navigatorOf(context).push(route);
    await route.completed;
    if (mounted) {
      setState(() => _readerReturning = true);
      await _refreshProgress();
    }
  }

  Future<Comic?> _findRemoteFavorite(ComicSource source, Comic comic) async {
    String? cursor;
    do {
      final page = await source.favorites(cursor: cursor);
      final favorite = page.items
          .where((item) => item.id == comic.id)
          .firstOrNull;
      if (favorite != null) return favorite;
      cursor = page.next;
    } while (cursor != null);
    return null;
  }

  Future<void> _favorite(Comic comic, {bool? value}) async {
    if (_busy || !_favoriteReady) return;
    final favorite = value ?? !_isFavorite;
    var requiresSource =
        _favoriteRetryRequiresSource && favorite == _favoriteRetryValue;
    setState(() {
      _busy = true;
      _favoriteError = null;
    });
    try {
      final source = ref
          .read(comicSourcesProvider)
          .firstWhere((s) => s.key == comic.source);
      final library = ref.read(comicLibraryProvider);
      final remoteFavoritesRevision = ref.read(
        comicRemoteFavoritesRevisionProvider.notifier,
      );
      var sourceComic = comic;
      final canWriteSource = source.hasRemoteFavorites && source.isLoggedIn;
      if (requiresSource && !canWriteSource) {
        throw ComicSourceException(
          S.of(context).comicLoginRequired,
          loginRequired: true,
        );
      }
      var remoteFavorite = _remoteFavorite == true;
      if (!favorite && canWriteSource && _remoteFavorite == null) {
        requiresSource = true;
        final existing = await _findRemoteFavorite(source, comic);
        requiresSource = false;
        remoteFavorite = existing != null;
        if (existing != null) {
          sourceComic = Comic.fromJson({
            ...comic.toJson(),
            'extra': {...comic.extra, ...existing.extra},
          });
        }
        if (mounted) {
          setState(() {
            _remoteFavorite = remoteFavorite;
            _comic = _withSourceFavorite(_comic, remoteFavorite);
          });
        }
        _favoriteVersion++;
      }
      if (canWriteSource && remoteFavorite != favorite) {
        requiresSource = true;
        await source.setFavorite(sourceComic, favorite);
        requiresSource = false;
        remoteFavoritesRevision.state++;
        _favoriteVersion++;
        _remoteFavorite = favorite;
        if (mounted) {
          setState(() => _comic = _withSourceFavorite(_comic, favorite));
        }
      }
      if (!favorite && !canWriteSource && _remoteFavorite == true) {
        _remoteFavorite = false;
        if (mounted) {
          setState(() => _comic = _withSourceFavorite(_comic, false));
        }
      }
      final localComic = favorite && _remoteFavorite == true
          ? _withSourceFavorite(_readyComic, true)
          : _readyComic;
      await library.favorite(localComic, favorite);
      if (mounted) {
        setState(() {
          _localFavorite = favorite;
          _favoriteError = null;
          _favoriteRetryValue = null;
          _favoriteRetryRequiresSource = false;
        });
        if (favorite) {
          SnackBarUtil.showSuccess(context, S.of(context).comicSaved);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _favoriteError = e;
          _favoriteRetryValue = favorite;
          _favoriteRetryRequiresSource = requiresSource;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(Comic comic) async {
    if (!_initialContentVisible) return;
    await downloadComicChapters(context, ref, comic);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(comicLibraryProvider, (_, __) {
      unawaited(_refreshProgress());
      unawaited(_refreshFavorite());
    });
    ref.listen(comicRemoteFavoritesRevisionProvider, (_, __) {
      if (!_busy && _remoteFavorite == false) {
        _remoteFavorite = null;
        _favoriteVersion++;
      }
    });
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
      _readerBodySize = null;
    }
    final retained = _readerWindow;
    final retainedBodySize = _readerBodySize;
    // Keep the detail's actual body size and safe area while the reader hides
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
        minWidth: retainedBodySize?.width,
        maxWidth: retainedBodySize?.width,
        minHeight: retainedBodySize?.height,
        maxHeight: retainedBodySize?.height,
        child: Builder(builder: _buildDetail),
      ),
    );
  }

  Widget _buildDetail(BuildContext context) {
    final s = S.of(context);
    return GlobalAudioPlayerWrapper(
      child: Scaffold(
        appBar: ScrollableAppBar(
          centerTitle: false,
          titleSpacing: ModalRoute.of(context)?.canPop == true ? 4 : null,
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
              visualDensity: const VisualDensity(horizontal: -2),
              onPressed: !_initialContentVisible || _chapters.isEmpty
                  ? null
                  : () => _download(_readyComic),
            ),
            IconButton(
              tooltip: s.comicFavorites,
              visualDensity: const VisualDensity(horizontal: -2),
              icon: Icon(
                _isFavorite ? Icons.bookmark : Icons.bookmark_add_outlined,
                color: _isFavorite
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onPressed: _busy || !_favoriteReady
                  ? null
                  : () => _favorite(_readyComic),
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
    final source = ref
        .read(comicSourcesProvider)
        .firstWhere((source) => source.key == comic.source);
    final tagTranslations =
        comic.source == 'ehentai' &&
            Localizations.localeOf(context).languageCode == 'zh'
        ? ref.watch(ehTagTranslationsProvider).valueOrNull
        : null;
    final showThumbnails =
        StorageService.getBool('comic_chapter_thumbnails') ?? true;
    final lastProgress = _lastProgress;
    final lastChapter = lastProgress == null
        ? null
        : _lastReadChapter(lastProgress);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final metrics = resolveCollectionGridMetrics(
          context,
          layoutType: LayoutType.bigGrid,
          availableWidth: width,
          availableHeight: constraints.maxHeight,
        );
        final detailPadding = !isLandscape && metrics.crossAxisCount == 1
            ? metrics.padding.left
            : 16.0;
        final contentWidth = math.min(width, 1200) - detailPadding * 2;
        final portraitCoverWidth = (contentWidth - 16) / 2;
        final availableCoverHeight =
            (constraints.maxHeight -
                    (isLandscape ? 16 : detailPadding) -
                    MediaQuery.paddingOf(context).bottom)
                .clamp(0.0, double.infinity)
                .toDouble();
        final landscapeCoverWidth = math.min(width, 1200) * 0.4;
        final coverHeroTag = 'comic-detail-cover-${comic.key}';
        final cover = ComicCover(
          key: const ValueKey('comic-detail-cover'),
          source: widget.comic.source,
          page: _comic.coverPage,
          cornerRadius: workCoverDetailRadius,
          maxWidth: isLandscape ? landscapeCoverWidth : portraitCoverWidth,
          maxHeight: availableCoverHeight,
          initialCacheWidth: widget.initialCoverCacheWidth,
          initialAspectRatio: widget.initialCoverAspectRatio,
          deferCacheUpgradeUntilRouteCompleted: true,
          preservePreviousImage: true,
          previewHeroTag: coverHeroTag,
          onTap: (bytes) => CoverPreviewDialog.show(
            context,
            imageBytes: bytes,
            heroTag: coverHeroTag,
            identifier: '${comic.source}_${comic.id}',
          ),
        );
        final infoStyle = Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontSize: 12, color: Colors.grey[600]);
        final title = WorkTitleHeader(
          title: comic.title,
          showTranslateButton: false,
        );
        final info = Column(
          key: const ValueKey('comic-detail-info'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(source.name, style: infoStyle),
            if (comic.rating != null)
              Text('${s.ratingLabel}: ${comic.rating}', style: infoStyle),
            if (comic.extra['likes'] != null)
              Row(
                children: [
                  Icon(
                    Icons.thumb_up_alt_outlined,
                    size: 16,
                    color: Colors.grey[600],
                  ),
                  const SizedBox(width: 4),
                  Text('${comic.extra['likes']}', style: infoStyle),
                ],
              ),
            if (comic.publishedDate != null || comic.updatedDate != null) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  if (comic.publishedDate != null)
                    WorkDetailDate(
                      label: s.releaseDate,
                      date: comic.publishedDate!,
                    ),
                  if (comic.updatedDate != null)
                    WorkDetailDate(
                      label: s.lastUpdated,
                      date: comic.updatedDate!,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                return Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SizedBox(
                    width: math.min(200, constraints.maxWidth),
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
                              lastProgress == null
                                  ? s.comicStart
                                  : s.comicContinue,
                              textAlign: TextAlign.center,
                              softWrap: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            if (lastProgress != null)
              LayoutBuilder(
                builder: (context, constraints) => Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: SizedBox(
                    width: constraints.maxWidth,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        Icon(Icons.history, size: 16, color: Colors.grey[600]),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${lastChapter?.title ?? lastProgress.chapterId} ${s.comicPreviewPage(lastProgress.page + 1)}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.start,
                            style: infoStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
        Widget buildCommentsSliver(AsyncSnapshot<List<ComicComment>> snapshot) {
          if (snapshot.hasError) {
            return SliverFillRemaining(
              hasScrollBody: false,
              child: ComicErrorView(
                error: snapshot.error!,
                retry: _retryComments,
              ),
            );
          }
          if (!snapshot.hasData) {
            return const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: detailPadding),
            sliver: SliverList.builder(
              itemCount: snapshot.data!.length,
              itemBuilder: (context, index) {
                final comment = snapshot.data![index];
                return ListTile(
                  leading: comment.avatar == null
                      ? const CircleAvatar(child: Icon(Icons.person_outline))
                      : ClipOval(
                          child: SizedBox.square(
                            dimension: 40,
                            child: Center(
                              child: ComicCover(
                                source: comic.source,
                                page: comment.avatar!,
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
                      Text(comment.author),
                      if (comment.createdAt != null)
                        Text(
                          S
                              .of(context)
                              .comicCommentTime(
                                comment.createdAt!.toLocal(),
                                comment.createdAt!.toLocal(),
                              ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                  subtitle: Text(comment.text),
                  trailing: comment.score == null ? null : Text(comment.score!),
                );
              },
            ),
          );
        }

        Widget buildChapterSliver() => SliverLayoutBuilder(
          builder: (context, constraints) {
            // The first chapter otherwise requests offscreen thumbnails.
            if (constraints.remainingCacheExtent == 0 &&
                constraints.scrollOffset == 0) {
              return const SliverToBoxAdapter();
            }
            return SliverPadding(
              padding: EdgeInsets.fromLTRB(
                detailPadding,
                _hasComments ? 0 : 16,
                detailPadding,
                0,
              ),
              sliver: SliverList.builder(
                itemCount: 1 + (_initialContentVisible ? _chapters.length : 0),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!_hasComments)
                            Text(
                              s.comicChapters,
                              style: Theme.of(context).textTheme.titleMedium,
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
                  }
                  final chapter = _chapters[index - 1];
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
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: ComicChapterThumbnails(
                            key: ValueKey('${comic.key}-${chapter.id}'),
                            comic: comic,
                            chapter: chapter,
                            pagesCache: _chapterPreviewPages,
                            onSelected: (page, pages) => unawaited(
                              _showPagePreview(comic, chapter, page, pages),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            );
          },
        );

        final detailTabBar = TabBar(
          key: const ValueKey('comic-detail-tabs'),
          controller: _detailTabs,
          onTap: _moveToDetailTab,
          tabs: [
            Tab(text: s.comicChapters),
            Tab(text: s.comicComments),
          ],
        );
        final detailScroll = CustomScrollView(
          key: const PageStorageKey<String>('comic-detail-scroll'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                detailPadding,
                detailPadding,
                detailPadding,
                16,
              ),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isLandscape) ...[
                          title,
                          const SizedBox(height: 8),
                          info,
                        ] else
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              cover,
                              const SizedBox(width: 16),
                              Expanded(child: info),
                            ],
                          ),
                        if (!isLandscape) ...[
                          const SizedBox(height: 16),
                          title,
                        ],
                        SizedBox(height: isLandscape ? 16 : 8),
                        if (_busy)
                          const RepaintBoundary(
                            child: LinearProgressIndicator(),
                          ),
                        if (_favoriteError != null)
                          _retryBanner(
                            _favoriteError!,
                            () => _favorite(comic, value: _favoriteRetryValue),
                          ),
                        if (_metadataLoading)
                          const RepaintBoundary(
                            child: LinearProgressIndicator(),
                          ),
                        if (_metadataError != null)
                          _retryBanner(_metadataError!, _loadMetadata),
                        if (isLandscape ||
                            _busy ||
                            _favoriteError != null ||
                            _metadataLoading ||
                            _metadataError != null)
                          const SizedBox(height: 16),
                      ],
                    ),
                  ),
                  SliverList.builder(
                    itemCount: 2,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: SelectableText(
                            comic.description,
                            style: infoStyle,
                          ),
                        );
                      }
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
                                    (tag) => buildEhTagLabel(
                                      context: context,
                                      tag: tag,
                                      translations: tagTranslations,
                                      builder: (label) => MetadataSearchChip(
                                        label: label,
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
                                    ),
                                  )
                                  .toList(),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            if (_hasComments)
              SliverLayoutBuilder(
                builder: (context, groupConstraints) => SliverMainAxisGroup(
                  key: _detailTabGroupKey,
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _ComicDetailTabBarDelegate(
                        tabBar: detailTabBar,
                        horizontalPadding: detailPadding,
                      ),
                    ),
                    SliverLayoutBuilder(
                      builder: (context, constraints) {
                        final leadingExtent =
                            constraints.precedingScrollExtent -
                            groupConstraints.precedingScrollExtent;
                        final transitionGeneration = _detailMotionGeneration;
                        return SliverTabPageView(
                          position: _detailPagePosition,
                          minimumPageExtent: math.max(
                            0.0,
                            constraints.viewportMainAxisExtent -
                                detailTabBar.preferredSize.height,
                          ),
                          onDragStart: () {
                            _detailMotionGeneration++;
                            _detailMotionTarget = null;
                            _beginDetailTabTransition();
                            _detailPagePosition.stop(canceled: true);
                          },
                          onDragUpdate: _updateDetailPagePosition,
                          onDragEnd: _settleDetailPagePosition,
                          onDragCancel: () => _settleDetailPagePosition(0),
                          pageResourceOffsets: [
                            for (final page in [0, 1])
                              _unpinnedDetailOffset ??
                                  _detailTabScrollOffsets[page] ??
                                  0,
                          ],
                          leadingExtent: leadingExtent,
                          transitionSourceIndex: _detailTransitionSource,
                          onPageResourceOffsetCorrected:
                              (pageIndex, correction) {
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (!mounted ||
                                      transitionGeneration !=
                                          _detailMotionGeneration) {
                                    return;
                                  }
                                  _detailTabScrollOffsets[pageIndex] =
                                      ((_detailTabScrollOffsets[pageIndex] ??
                                                  0) +
                                              correction)
                                          .clamp(0.0, double.infinity)
                                          .toDouble();
                                  setState(() {});
                                });
                              },
                          pages: [
                            TickerMode(
                              enabled:
                                  _detailTransitionSource != null ||
                                  _selectedDetailTab == 0,
                              child: SliverPadding(
                                key: const ValueKey(
                                  'comic-detail-chapters-page',
                                ),
                                padding: EdgeInsets.zero,
                                sliver: buildChapterSliver(),
                              ),
                            ),
                            TickerMode(
                              enabled:
                                  _detailTransitionSource != null ||
                                  _selectedDetailTab == 1,
                              child: SliverPadding(
                                key: const ValueKey(
                                  'comic-detail-comments-page',
                                ),
                                padding: EdgeInsets.zero,
                                sliver: FutureBuilder<List<ComicComment>>(
                                  future: _commentsFuture,
                                  builder: (context, snapshot) =>
                                      buildCommentsSliver(snapshot),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              )
            else
              buildChapterSliver(),
            SliverToBoxAdapter(
              child: SizedBox(
                height: detailPadding + MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        );
        return Center(
          child: SizedBox(
            width: math.min(width, 1200),
            height: constraints.maxHeight,
            child: isLandscape
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Center(
                          child: Padding(
                            padding: workCoverDetailPadding,
                            child: cover,
                          ),
                        ),
                      ),
                      Expanded(flex: 3, child: detailScroll),
                    ],
                  )
                : detailScroll,
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

class _ComicDetailTabBarDelegate extends SliverPersistentHeaderDelegate {
  const _ComicDetailTabBarDelegate({
    required this.tabBar,
    required this.horizontalPadding,
  });

  final TabBar tabBar;
  final double horizontalPadding;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Material(
    color: Theme.of(context).colorScheme.surface,
    elevation: overlapsContent ? 2 : 0,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: tabBar,
    ),
  );

  @override
  bool shouldRebuild(_ComicDetailTabBarDelegate oldDelegate) =>
      oldDelegate.tabBar != tabBar ||
      oldDelegate.horizontalPadding != horizontalPadding;
}

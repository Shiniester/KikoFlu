import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../providers/works_provider.dart' show LayoutType;
import '../../services/storage_service.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/tab_page_motion.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/library_page_scaffold.dart';
import '../../widgets/pagination_bar.dart';
import '../comic_models.dart';
import '../comic_pagination.dart';
import '../comic_providers.dart';
import 'comic_widgets.dart';
import 'comic_search_screen.dart';
import 'comic_download_screen.dart';
import 'comic_settings_screen.dart';

class ComicScreen extends ConsumerStatefulWidget {
  const ComicScreen({super.key, this.active = true});
  final bool active;
  @override
  ConsumerState<ComicScreen> createState() => _ComicScreenState();
}

class _ComicScreenState extends ConsumerState<ComicScreen> {
  final _pages = PageController();
  final _pageTarget = ValueNotifier<int?>(null);
  int _pageRequest = 0;
  bool _reduceMotion = false;
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    _pages.addListener(_handlePagePosition);
  }

  void _handlePagePosition() {
    if (!_pages.hasClients || !_pages.position.hasContentDimensions) return;
    final page = _pages.page!.round().clamp(0, 3).toInt();
    if (page != _currentTab) setState(() => _currentTab = page);
  }

  void _selectTab(int index) {
    _pageTarget.value = index;
    _handlePagePosition();
    final request = ++_pageRequest;
    moveToTabPage(_pages, index, reduceMotion: _reduceMotion).then((_) {
      if (!mounted || request != _pageRequest) return;
      _pageTarget.value = null;
      _handlePagePosition();
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0 &&
        notification.metrics.axis == Axis.horizontal &&
        notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _pageRequest++;
      _pageTarget.value = null;
    }
    return false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion &&
        !_reduceMotion &&
        _pageTarget.value != null &&
        _pages.hasClients) {
      _pages.jumpToPage(_pageTarget.value!);
    }
    _reduceMotion = reduceMotion;
  }

  @override
  void dispose() {
    _pages.dispose();
    _pageTarget.dispose();
    super.dispose();
  }

  void _search(String query, String? sourceKey) {
    pushWorkDetailRoute(
      context,
      builder: (_) => ComicSearchScreen(
        dockHandoff: true,
        initialQuery: query,
        initialSource: sourceKey,
        libraryTab: _currentTab == 0 ? null : _currentTab,
        onlineFavorites:
            _currentTab == 1 &&
            (StorageService.getBool('comic_online_favorites') ?? false),
      ),
    );
  }

  Future<void> _selectSource(String key) async {
    ref.read(comicSelectedSourceProvider.notifier).state = key;
    _selectTab(0);
    await StorageService.setString('comic_selected_source', key);
  }

  Future<void> _setOnlineFavorites(bool value) async {
    await StorageService.setBool('comic_online_favorites', value);
    if (mounted) {
      ref.read(comicSettingsRevisionProvider.notifier).state++;
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ComicSettingsScreen()),
    );
  }

  Future<void> _categories(String sourceKey) async {
    await pushBottomDockRoute(
      context,
      builder: (_) => ComicCategoryScreen(sourceKey: sourceKey),
    );
  }

  String _collectionTitle(S s, int tab) => switch (tab) {
    1 => s.libraryFavorites,
    2 => s.libraryHistory,
    _ => s.libraryDownloads,
  };

  IconData _collectionIcon(int tab) => switch (tab) {
    1 => Icons.bookmark_outline,
    2 => Icons.history,
    _ => Icons.download_done,
  };

  @override
  Widget build(BuildContext context) {
    ref.watch(comicSettingsRevisionProvider);
    final s = S.of(context);
    final pageOrder = ref.watch(comicCollectionPageOrderProvider);
    final sources = ref.watch(enabledComicSourcesProvider);
    final selectedSource = ref.watch(comicSelectedSourceProvider);
    final currentSource =
        sources.where((source) => source.key == selectedSource).firstOrNull ??
        sources.firstOrNull;
    final pageTitle = _currentTab == 0
        ? s.navHome
        : _collectionTitle(s, _currentTab);
    final onlineFavorites =
        StorageService.getBool('comic_online_favorites') ?? false;
    final downloads = ref.watch(comicDownloadsProvider);

    return LibraryPageScaffold(
      title: pageTitle,
      searchHint: s.librarySearchHint(pageTitle),
      searchScopeKey: (currentSource?.key, _currentTab),
      onSearch: (query) => _search(query, currentSource?.key),
      drawerChildren: [
        LibraryDrawerSection(
          title: s.librarySources,
          children: [
            for (final source in sources)
              LibraryDrawerTile(
                icon: Icons.public,
                title: source.name,
                selected: source.key == currentSource?.key,
                onTap: () => _selectSource(source.key),
              ),
          ],
        ),
        LibraryDrawerSection(
          title: s.libraryPages,
          children: [
            for (final tab in pageOrder)
              LibraryDrawerTile(
                icon: _collectionIcon(tab),
                title: _collectionTitle(s, tab),
                selected: _currentTab == tab,
                onTap: () => _selectTab(tab),
              ),
          ],
        ),
        LibraryDrawerSection(
          title: s.libraryBrowseOptions,
          children: [
            if (_currentTab == 0 && currentSource != null)
              LibraryDrawerTile(
                icon: Icons.category_outlined,
                title: s.comicCategories,
                onTap: () => _categories(currentSource.key),
              ),
            if (_currentTab == 1) ...[
              LibraryDrawerTile(
                icon: Icons.bookmark,
                title: s.comicLocalFavorites,
                selected: !onlineFavorites,
                closeOnTap: false,
                onTap: () => _setOnlineFavorites(false),
              ),
              LibraryDrawerTile(
                icon: Icons.cloud_outlined,
                title: s.comicOnlineFavorites,
                selected: onlineFavorites,
                closeOnTap: false,
                onTap: () => _setOnlineFavorites(true),
              ),
            ],
            LibraryDrawerTile(
              icon: Icons.grid_view,
              title: s.layout,
              trailing: Text(
                switch (ref.watch(comicLayoutProvider)) {
                  LayoutType.bigGrid => s.layoutBigGrid,
                  LayoutType.smallGrid => s.layoutSmallGrid,
                  LayoutType.list => s.layoutList,
                },
              ),
              closeOnTap: false,
              onTap: () => ref.read(comicLayoutProvider.notifier).cycle(),
            ),
            LibraryDrawerTile(
              icon: Icons.settings_outlined,
              title: s.comicSettings,
              onTap: _openSettings,
            ),
          ],
        ),
      ],
      floatingActionButton: downloads.tasks.isEmpty
          ? null
          : FloatingActionButton(
              heroTag: 'comic-downloads',
              tooltip: s.downloadTasks,
              onPressed: () => pushBottomDockRoute(
                context,
                builder: (_) => const ComicDownloadScreen(),
              ),
              child: const Icon(Icons.download_outlined),
            ),
      body: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: TabPageWarmup(
          pages: _pages,
          target: _pageTarget,
          builder: (cacheExtent) => PageView(
            key: const ValueKey('comic-tab-pages'),
            controller: _pages,
            allowImplicitScrolling: cacheExtent > 0,
            scrollCacheExtent: ScrollCacheExtent.viewport(cacheExtent),
            children: [
              for (var i = 0; i < 4; i++)
                LazyTabPage(
                  key: ValueKey('comic-tab-$i'),
                  index: i,
                  target: _pageTarget,
                  pages: _pages,
                  child: _ComicCollection(
                    active: widget.active && _currentTab == i,
                    tab: i,
                    onlineFavorites: onlineFavorites,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComicCollection extends ConsumerStatefulWidget {
  const _ComicCollection({
    required this.active,
    required this.tab,
    required this.onlineFavorites,
  });
  final bool active;
  final int tab;
  final bool onlineFavorites;
  @override
  ConsumerState<_ComicCollection> createState() => _ComicCollectionState();
}

class _ComicCollectionState extends ConsumerState<_ComicCollection> {
  final _scroll = ScrollController();
  ComicPageBuffer? _buffer;
  List<Comic> _items = [];
  bool _loading = false;
  bool _onlineFavorites =
      StorageService.getBool('comic_online_favorites') ?? false;
  bool get _online => widget.tab == 1 && _onlineFavorites;
  Map<String, Object> _errors = {};
  bool _hasMore = false;
  int _page = 1;
  int _pendingPage = 1;
  final _visitedPages = ComicVisitedPages();
  String? _source;
  int _generation = 0;
  int? _pageTurnRequest;
  int? _cancelledPageTurnRequest;
  int? _scrollingRequest;
  int? _interruptedScrollRequest;
  ModalRoute<dynamic>? _route;

  void _routeStatusChanged(AnimationStatus _) {
    final request = _pageTurnRequest;
    if (_route?.isCurrent == false && request != null) {
      _cancelledPageTurnRequest = request;
    }
  }

  void _listenToRoute(ModalRoute<dynamic>? route, {required bool add}) {
    final change = add
        ? (Animation<double>? animation) =>
              animation?.addStatusListener(_routeStatusChanged)
        : (Animation<double>? animation) =>
              animation?.removeStatusListener(_routeStatusChanged);
    change(route?.animation);
    change(route?.secondaryAnimation);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _listenToRoute(_route, add: false);
      _route = route;
      _listenToRoute(route, add: true);
    }
  }

  @override
  void didUpdateWidget(_ComicCollection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active && _pageTurnRequest != null) {
      _cancelledPageTurnRequest = _pageTurnRequest;
      _interruptedScrollRequest = _scrollingRequest;
    }
    if (widget.tab == 1 &&
        oldWidget.onlineFavorites != widget.onlineFavorites &&
        _onlineFavorites != widget.onlineFavorites) {
      _onlineFavorites = widget.onlineFavorites;
      Future.microtask(() => _loadPage(1, reset: true, clearItems: true));
    }
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _loadPage(1, reset: true, clearItems: true));
  }

  @override
  void dispose() {
    _generation++;
    _listenToRoute(_route, add: false);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _removeFromLibrary(Comic comic) async {
    final s = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.tab == 1 ? s.comicRemoveFavorite : s.delete),
        content: Text(comic.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      if (widget.tab == 2) {
        await ref.read(comicLibraryProvider).removeHistory(comic);
      } else if (_online) {
        final source = ref
            .read(comicSourcesProvider)
            .firstWhere((s) => s.key == comic.source);
        await source.setFavorite(comic, false);
        await _loadPage(_page, reset: true);
      } else {
        await ref.read(comicLibraryProvider).favorite(comic, false);
      }
    } catch (error) {
      if (mounted) {
        SnackBarUtil.showError(context, '$error');
      }
    }
  }

  Future<ComicPageBuffer> _createBuffer() async {
    final library = ref.read(comicLibraryProvider);
    if (widget.tab == 2) {
      return ComicPageBuffer.fromItems(
        (await library.history()).map((progress) => progress.comic).toList(),
      );
    }
    if (widget.tab == 3) {
      final downloads = ref.read(comicDownloadsProvider);
      await downloads.ready;
      return ComicPageBuffer.fromItems(downloads.completedComics);
    }
    if (widget.tab == 1 && !_online) {
      return ComicPageBuffer.fromItems(await library.favorites());
    }
    if (_source == null) return ComicPageBuffer.fromItems(const []);
    final source = ref
        .read(comicSourcesProvider)
        .firstWhere((source) => source.key == _source);
    return ComicPageBuffer([
      ComicPageSource(source.key, (cursor) async {
        if (_online && (!source.hasRemoteFavorites || !source.isLoggedIn)) {
          throw const ComicSourceException(
            'Sign in to this source in comic settings.',
            loginRequired: true,
          );
        }
        return _online
            ? source.favorites(cursor: cursor)
            : source.explore(cursor: cursor);
      }),
    ]);
  }

  Future<void> _loadPage(
    int page, {
    bool reset = false,
    bool clearItems = false,
    bool retryFailures = false,
  }) async {
    if (!mounted || (_loading && !reset)) return;
    final request = ++_generation;
    final previousPage = _page;
    final pageTurnRequest = !reset && page != previousPage;
    if (reset) {
      _pageTurnRequest = null;
      _cancelledPageTurnRequest = null;
    } else if (pageTurnRequest) {
      _pageTurnRequest = request;
      _cancelledPageTurnRequest = null;
    }
    final sources = ref.read(enabledComicSourcesProvider);
    final selected = ref.read(comicSelectedSourceProvider);
    _source = sources.any((s) => s.key == selected)
        ? selected
        : sources.firstOrNull?.key;
    setState(() {
      _loading = true;
      if (!retryFailures) _errors = {};
      _pendingPage = page;
      if (clearItems) {
        _items = [];
        _page = page;
        _hasMore = false;
      }
      if (reset) {
        _buffer = null;
        _visitedPages.reset(
          maximum: clearItems || page < _visitedPages.maximum
              ? page
              : _visitedPages.maximum,
        );
      }
    });
    try {
      var buffer = _buffer;
      if (reset || buffer == null) buffer = await _createBuffer();
      if (!mounted || request != _generation) return;
      var displayPage = page;
      var result = await buffer.page(
        displayPage,
        ref.read(comicPageSizeProvider),
        retryFailures: retryFailures,
      );
      while (result.items.isEmpty && result.errors.isEmpty && displayPage > 1) {
        result = await buffer.page(
          --displayPage,
          ref.read(comicPageSizeProvider),
        );
      }
      if (!mounted || request != _generation) return;
      if (pageTurnRequest && _isPageTurnCancelled(request)) {
        setState(() => _pendingPage = previousPage);
        return;
      }
      if (result.errors.isEmpty && (reset || displayPage != previousPage)) {
        final pageTurn = pageTurnRequest && displayPage != previousPage;
        if (pageTurn &&
            (!widget.active || ModalRoute.of(context)?.isCurrent == false)) {
          setState(() => _pendingPage = previousPage);
          return;
        }
        final reachedTop = await _scrollBeforePageCommit(
          request,
          requireCurrentPage: pageTurn,
        );
        if (!mounted || request != _generation) return;
        if (!reachedTop) {
          setState(() => _pendingPage = previousPage);
          return;
        }
        if (pageTurn &&
            (!widget.active || ModalRoute.of(context)?.isCurrent == false)) {
          setState(() => _pendingPage = previousPage);
          return;
        }
      }
      if (!mounted || request != _generation) return;
      setState(() {
        _buffer = buffer;
        _errors = result.errors;
        if (result.errors.isEmpty) {
          _items = result.items;
          _page = displayPage;
          _pendingPage = displayPage;
          if (reset) {
            _visitedPages.reset(maximum: displayPage);
          } else {
            _visitedPages.markDisplayed(displayPage);
          }
          _hasMore = result.hasMore;
        } else if (_items.isEmpty && result.items.isNotEmpty) {
          _items = result.items;
          _page = displayPage;
          _hasMore = false;
        }
      });
    } catch (e) {
      if (mounted && request == _generation) {
        setState(() => _errors = {_source ?? 'comic': e});
      }
    } finally {
      if (_pageTurnRequest == request) _pageTurnRequest = null;
      if (mounted && request == _generation) setState(() => _loading = false);
    }
  }

  bool _isPageTurnCancelled(int request) =>
      _cancelledPageTurnRequest == request ||
      !widget.active ||
      ModalRoute.of(context)?.isCurrent == false;

  Future<bool> _scrollBeforePageCommit(
    int request, {
    required bool requireCurrentPage,
  }) async {
    bool isCurrentPage() =>
        !requireCurrentPage ||
        (widget.active && ModalRoute.of(context)?.isCurrent != false);
    if (!isCurrentPage()) return false;
    if (!_scroll.hasClients || _scroll.position.pixels <= 0) {
      return isCurrentPage();
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(0);
      return isCurrentPage();
    }
    _scrollingRequest = request;
    try {
      await _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
      return mounted &&
          request == _generation &&
          _cancelledPageTurnRequest != request &&
          _interruptedScrollRequest != request &&
          (!requireCurrentPage || isCurrentPage()) &&
          _scroll.hasClients &&
          _scroll.position.pixels <= 1;
    } finally {
      if (_scrollingRequest == request) _scrollingRequest = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      comicSelectedSourceProvider,
      (_, __) => _loadPage(1, reset: true, clearItems: true),
    );
    ref.listen(comicSettingsRevisionProvider, (_, __) {
      _onlineFavorites =
          StorageService.getBool('comic_online_favorites') ?? false;
      _loadPage(1, reset: true, clearItems: true);
    });
    ref.listen(comicRemoteFavoritesRevisionProvider, (_, __) {
      if (widget.tab == 1 && _online) _loadPage(_page, reset: true);
    });
    ref.listen(comicLibraryProvider, (_, __) {
      if ((widget.tab == 1 && !_online) || widget.tab == 2) {
        _loadPage(_page, reset: true);
      }
    });
    ref.listen(comicDownloadsProvider, (_, __) {
      if (widget.tab == 3) _loadPage(_page, reset: true);
    });
    ref.listen(comicPageSizeProvider, (_, __) {
      _loadPage(1, reset: true, clearItems: true);
    });
    final pageSize = ref.watch(comicPageSizeProvider);
    final s = S.of(context);
    final footer = Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_errors.isNotEmpty && _items.isNotEmpty)
            MaterialBanner(
              content: Text(
                _errors.entries
                    .map((entry) {
                      final source = ref
                          .read(comicSourcesProvider)
                          .where((source) => source.key == entry.key)
                          .firstOrNull;
                      return '${source?.name ?? entry.key}: ${entry.value}';
                    })
                    .join('\n'),
              ),
              actions: [
                TextButton(
                  onPressed: _loading
                      ? null
                      : () => _loadPage(_pendingPage, retryFailures: true),
                  child: Text(s.retry),
                ),
              ],
            ),
          PaginationBar(
            currentPage: _page,
            pageSize: pageSize,
            totalCount: null,
            jumpMaxPage: _visitedPages.maximum,
            hasMore: _hasMore && _errors.isEmpty,
            isLoading: _loading,
            onPreviousPage: _page > 1 ? () => _loadPage(_page - 1) : null,
            onNextPage: _hasMore && _errors.isEmpty
                ? () => _loadPage(_page + 1)
                : null,
            onGoToPage: _visitedPages.maximum > 1
                ? (page) => _loadPage(page)
                : null,
          ),
        ],
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: NotificationListener<ScrollStartNotification>(
            onNotification: (notification) {
              final request = _scrollingRequest;
              if (notification.dragDetails != null && request != null) {
                _interruptedScrollRequest = request;
              }
              return false;
            },
            child: RefreshIndicator(
              onRefresh: () => _loadPage(1, reset: true, clearItems: true),
              child: ComicGrid(
                comics: _items,
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                onLongPress: widget.tab == 1 || widget.tab == 2
                    ? _removeFromLibrary
                    : null,
                footer: footer,
              ),
            ),
          ),
        ),
        if (_loading && _items.isEmpty)
          const Center(child: CircularProgressIndicator()),
        if (_errors.isNotEmpty && _items.isEmpty)
          Positioned.fill(
            child: ComicErrorView(
              error: _errors.values.first,
              retry: () =>
                  _loadPage(_pendingPage, retryFailures: _buffer != null),
            ),
          ),
      ],
    );
  }
}

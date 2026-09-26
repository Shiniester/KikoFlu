import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../providers/works_provider.dart' show LayoutType;
import '../../services/storage_service.dart';
import '../../widgets/floating_feed_toolbar.dart';
import '../../widgets/library_tab_strip.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/pagination_bar.dart';
import '../comic_models.dart';
import '../comic_pagination.dart';
import '../comic_providers.dart';
import 'comic_widgets.dart';
import 'comic_search_screen.dart';
import 'comic_download_screen.dart';
import 'comic_settings_screen.dart';

class ComicScreen extends ConsumerStatefulWidget {
  const ComicScreen({super.key});
  @override
  ConsumerState<ComicScreen> createState() => _ComicScreenState();
}

class _ComicScreenState extends ConsumerState<ComicScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  final _visible = ValueNotifier(true);
  @override
  void dispose() {
    _tabs.dispose();
    _visible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final top = MediaQuery.paddingOf(context).top + 8;
    final horizontal = FloatingToolbarLayout.horizontalPadding(context);
    final labels = [s.navHome, s.comicFavorites, s.historyRecord, s.downloaded];
    final icons = [
      Icons.home_outlined,
      Icons.bookmark_outline,
      Icons.history,
      Icons.download_done,
    ];
    return Scaffold(
      floatingActionButton: ref.watch(comicDownloadsProvider).tasks.isEmpty
          ? null
          : FloatingActionButton(
              heroTag: 'comic-downloads',
              tooltip: s.downloadTasks,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ComicDownloadScreen()),
              ),
              child: const Icon(Icons.download_outlined),
            ),
      body: Stack(
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) =>
                  updateLibraryToolbarVisibility(n, _visible),
              child: TabBarView(
                controller: _tabs,
                children: [
                  for (var i = 0; i < 4; i++)
                    ComicKeepAlive(
                      key: ValueKey('comic-tab-$i'),
                      child: AnimatedBuilder(
                        animation: _tabs,
                        builder: (context, child) =>
                            HeroMode(enabled: _tabs.index == i, child: child!),
                        child: _ComicCollection(
                          tab: i,
                          toolbarTop: top + kTextTabBarHeight + 8,
                          collapsedTop: top,
                          visible: _visible,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ProgressiveTopScrim(height: top + 12),
          ),
          Positioned(
            top: top,
            left: horizontal,
            right: horizontal,
            child: LibraryTabStrip(
              controller: _tabs,
              visible: _visible,
              tabs: [
                for (var i = 0; i < 4; i++)
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icons[i], size: 18),
                        const SizedBox(width: 6),
                        Text(labels[i]),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ComicCollection extends ConsumerStatefulWidget {
  const _ComicCollection({
    required this.tab,
    required this.toolbarTop,
    required this.collapsedTop,
    required this.visible,
  });
  final int tab;
  final double toolbarTop, collapsedTop;
  final ValueNotifier<bool> visible;
  @override
  ConsumerState<_ComicCollection> createState() => _ComicCollectionState();
}

class _ComicCollectionState extends ConsumerState<_ComicCollection> {
  final _scroll = ScrollController();
  ComicPageBuffer? _buffer;
  List<Comic> _items = [];
  bool _loading = false;
  bool _online = StorageService.getBool('comic_online_favorites') ?? false;
  Map<String, Object> _errors = {};
  bool _hasMore = false;
  int _page = 1;
  int _pendingPage = 1;
  String? _source;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    Future.microtask(() => _loadPage(1, reset: true, clearItems: true));
  }

  @override
  void dispose() {
    _generation++;
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
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
      if (reset) _buffer = null;
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
      setState(() {
        _buffer = buffer;
        _errors = result.errors;
        if (result.errors.isEmpty) {
          _items = result.items;
          _page = displayPage;
          _pendingPage = displayPage;
          _hasMore = result.hasMore;
        } else if (_items.isEmpty && result.items.isNotEmpty) {
          _items = result.items;
          _page = displayPage;
          _hasMore = false;
        }
      });
      if (result.errors.isEmpty && (reset || displayPage != previousPage)) {
        _scrollToTop();
      }
    } catch (e) {
      if (mounted && request == _generation) {
        setState(() => _errors = {_source ?? 'comic': e});
      }
    } finally {
      if (mounted && request == _generation) setState(() => _loading = false);
    }
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _select(String key) async {
    ref.read(comicSelectedSourceProvider.notifier).state = key;
    await StorageService.setString('comic_selected_source', key);
  }

  void _search() {
    pushWorkDetailRoute(
      context,
      builder: (_) => ComicSearchScreen(
        dockHandoff: true,
        initialSource: _source,
        libraryTab: widget.tab == 0 ? null : widget.tab,
        onlineFavorites: _online,
      ),
    );
  }

  Future<void> _categories() async {
    if (_source == null) return;
    final source = ref
        .read(comicSourcesProvider)
        .firstWhere((s) => s.key == _source);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ComicCategoryScreen(sourceKey: source.key),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      comicSelectedSourceProvider,
      (_, __) => _loadPage(1, reset: true, clearItems: true),
    );
    ref.listen(comicSettingsRevisionProvider, (_, __) {
      _online = StorageService.getBool('comic_online_favorites') ?? false;
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
    final sources = ref.watch(enabledComicSourcesProvider);
    final s = S.of(context);
    final modes = <FloatingFeedModeAction>[];
    if (widget.tab == 0 || (widget.tab == 1 && _online)) {
      for (final source in sources) {
        modes.add(
          FloatingFeedModeAction(
            icon: Icons.public,
            label: source.name,
            isSelected: source.key == _source,
            onPressed: () => _select(source.key),
          ),
        );
      }
    } else if (widget.tab == 1) {
      modes.add(
        FloatingFeedModeAction(
          icon: Icons.bookmark,
          label: s.comicLocalFavorites,
          isSelected: true,
          onPressed: () {},
        ),
      );
    } else {
      modes.add(
        FloatingFeedModeAction(
          icon: widget.tab == 2 ? Icons.history : Icons.download_done,
          label: widget.tab == 2 ? s.historyRecord : s.downloaded,
          isSelected: true,
          onPressed: () {},
        ),
      );
    }
    if (modes.isEmpty) {
      modes.add(
        FloatingFeedModeAction(
          icon: Icons.settings,
          label: s.comicSources,
          isSelected: true,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ComicSettingsScreen()),
          ),
        ),
      );
    }
    final top = widget.toolbarTop + 56;
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
            hasMore: _hasMore && _errors.isEmpty,
            isLoading: _loading,
            onPreviousPage: _page > 1 ? () => _loadPage(_page - 1) : null,
            onNextPage: _hasMore && _errors.isEmpty
                ? () => _loadPage(_page + 1)
                : null,
          ),
        ],
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: RefreshIndicator(
            onRefresh: () => _loadPage(1, reset: true, clearItems: true),
            child: ComicGrid(
              comics: _items,
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                FloatingToolbarLayout.horizontalPadding(context),
                top,
                FloatingToolbarLayout.horizontalPadding(context),
                16,
              ),
              onLongPress: widget.tab == 1 || widget.tab == 2
                  ? _removeFromLibrary
                  : null,
              footer: footer,
            ),
          ),
        ),
        if (_loading && _items.isEmpty)
          const Center(child: CircularProgressIndicator()),
        if (_errors.isNotEmpty && _items.isEmpty)
          Positioned.fill(
            top: top,
            child: ComicErrorView(
              error: _errors.values.first,
              retry: () =>
                  _loadPage(_pendingPage, retryFailures: _buffer != null),
            ),
          ),
        FloatingToolbarPositionFollower(
          primaryToolbarVisible: widget.visible,
          visibleTop: widget.toolbarTop,
          hiddenTop: widget.collapsedTop,
          left: FloatingToolbarLayout.horizontalPadding(context),
          right: FloatingToolbarLayout.horizontalPadding(context),
          child: FloatingFeedToolbar(
            modeActions: modes,
            toolActions: [
              if (widget.tab == 1)
                FloatingFeedToolAction(
                  icon: _online ? Icons.cloud : Icons.bookmark,
                  tooltip: _online
                      ? s.comicOnlineFavorites
                      : s.comicLocalFavorites,
                  onPressed: () {
                    setState(() => _online = !_online);
                    StorageService.setBool('comic_online_favorites', _online);
                    _loadPage(1, reset: true, clearItems: true);
                  },
                ),
              if (widget.tab == 0)
                FloatingFeedToolAction(
                  icon: Icons.category_outlined,
                  tooltip: s.comicCategories,
                  onPressed: _categories,
                ),
              FloatingFeedToolAction(
                icon: Icons.search,
                tooltip: s.search,
                onPressed: _search,
              ),
              FloatingFeedToolAction(
                icon: switch (ref.watch(comicLayoutProvider)) {
                  LayoutType.bigGrid => Icons.grid_view,
                  LayoutType.smallGrid => Icons.grid_on,
                  LayoutType.list => Icons.view_list,
                },
                tooltip: s.layout,
                onPressed: () => ref.read(comicLayoutProvider.notifier).cycle(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

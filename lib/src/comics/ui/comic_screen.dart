import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../services/storage_service.dart';
import '../../widgets/floating_feed_toolbar.dart';
import '../../widgets/library_tab_strip.dart';
import '../comic_models.dart';
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
      floatingActionButton: FloatingActionButton(
        heroTag: 'comic-downloads',
        tooltip: s.downloadTasks,
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ComicDownloadScreen())),
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
                      child: _ComicCollection(
                        tab: i,
                        toolbarTop: top + kTextTabBarHeight + 8,
                        collapsedTop: top,
                        visible: _visible,
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
  final _items = <Comic>[];
  bool _loading = false;
  bool _online = StorageService.getBool('comic_online_favorites') ?? false;
  Object? _error;
  String? _next;
  String? _source;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    Future.microtask(() => _load());
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
        await _load();
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

  void _onScroll() {
    if (_scroll.position.extentAfter < 500 && _next != null && !_loading) {
      _load(more: true);
    }
  }

  Future<void> _load({bool more = false}) async {
    if (!mounted || (more && _loading)) return;
    final request = ++_generation;
    final sources = ref.read(enabledComicSourcesProvider);
    final selected = ref.read(comicSelectedSourceProvider);
    _source = sources.any((s) => s.key == selected)
        ? selected
        : sources.firstOrNull?.key;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _items.clear();
        _next = null;
      }
    });
    try {
      final library = ref.read(comicLibraryProvider);
      ComicResult result;
      if (widget.tab == 2) {
        result = ComicResult(
          (await library.history()).map((p) => p.comic).toList(),
        );
      } else if (widget.tab == 3) {
        final downloads = ref.read(comicDownloadsProvider);
        await downloads.ready;
        result = ComicResult(downloads.completedComics);
      } else if (widget.tab == 1 && !_online) {
        result = ComicResult(await library.favorites());
      } else {
        if (_source == null) {
          result = const ComicResult([]);
        } else {
          final source = sources.firstWhere((s) => s.key == _source);
          if (_online && (!source.hasRemoteFavorites || !source.isLoggedIn)) {
            throw const ComicSourceException(
              'Sign in to this source in comic settings.',
              loginRequired: true,
            );
          }
          result = _online
              ? await source.favorites(cursor: more ? _next : null)
              : await source.explore(cursor: more ? _next : null);
        }
      }
      if (!mounted || request != _generation) return;
      setState(() {
        _items.addAll(
          result.items.where((item) => !_items.any((c) => c.key == item.key)),
        );
        _next = result.next;
      });
    } catch (e) {
      if (mounted && request == _generation) setState(() => _error = e);
    } finally {
      if (mounted && request == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _select(String key) async {
    ref.read(comicSelectedSourceProvider.notifier).state = key;
    await StorageService.setString('comic_selected_source', key);
  }

  void _search() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ComicSearchScreen(
          initialSource: _source,
          libraryTab: widget.tab == 0 ? null : widget.tab,
          onlineFavorites: _online,
        ),
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
    ref.listen(comicSelectedSourceProvider, (_, __) => _load());
    ref.listen(comicSettingsRevisionProvider, (_, __) {
      _online = StorageService.getBool('comic_online_favorites') ?? false;
      _load();
    });
    ref.listen(comicRemoteFavoritesRevisionProvider, (_, __) {
      if (widget.tab == 1 && _online) _load();
    });
    ref.listen(comicLibraryProvider, (_, __) {
      if ((widget.tab == 1 && !_online) || widget.tab == 2) _load();
    });
    ref.listen(comicDownloadsProvider, (_, __) {
      if (widget.tab == 3) _load();
    });
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
    return Stack(
      children: [
        Positioned.fill(
          child: RefreshIndicator(
            onRefresh: () => _load(),
            child: ComicGrid(
              comics: _items,
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(16, top, 16, 90),
              onLongPress: widget.tab == 1 || widget.tab == 2
                  ? _removeFromLibrary
                  : null,
            ),
          ),
        ),
        if (_loading && _items.isEmpty)
          const Center(child: CircularProgressIndicator()),
        if (_error != null)
          Positioned.fill(
            top: top,
            child: ComicErrorView(
              error: _error!,
              retry: () => _load(more: _items.isNotEmpty),
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
                    _load();
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
                icon: ref.watch(comicGridProvider)
                    ? Icons.grid_view
                    : Icons.view_list,
                tooltip: s.comicShowGrid,
                onPressed: () {
                  final value = !ref.read(comicGridProvider);
                  ref.read(comicGridProvider.notifier).state = value;
                  StorageService.setBool('comic_grid', value);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

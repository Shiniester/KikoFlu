import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/pagination_bar.dart';
import '../comic_models.dart';
import '../comic_pagination.dart';
import '../comic_providers.dart';
import '../comic_source.dart';
import 'comic_widgets.dart';

enum ComicSearchMode { single, grouped, merged }

List<Comic> interleaveComicResults(List<List<Comic>> groups) {
  final result = <Comic>[];
  for (var i = 0; groups.any((g) => g.length > i); i++) {
    for (final group in groups) {
      if (i < group.length) result.add(group[i]);
    }
  }
  return result;
}

class ComicSearchScreen extends ConsumerStatefulWidget {
  const ComicSearchScreen({
    super.key,
    this.initialSource,
    this.initialQuery = '',
    this.libraryTab,
    this.onlineFavorites = false,
    this.category,
    this.dockHandoff = false,
  });
  final String? initialSource;
  final String initialQuery;
  final int? libraryTab;
  final bool onlineFavorites;
  final ComicCategory? category;
  final bool dockHandoff;
  @override
  ConsumerState<ComicSearchScreen> createState() => _ComicSearchScreenState();
}

class _ComicSearchScreenState extends ConsumerState<ComicSearchScreen> {
  late final _query = TextEditingController(text: widget.initialQuery);
  late String _source =
      widget.initialSource ?? ref.read(comicSelectedSourceProvider);
  ComicSearchMode _mode = ComicSearchMode.single;
  String? _sort;
  final _results = <String, List<Comic>>{};
  final _errors = <String, Object>{};
  final _pending = <String>{};
  ComicPageBuffer? _buffer;
  List<Comic> _pageItems = [];
  Map<String, Object> _pageErrors = {};
  bool _pageLoading = false, _hasMore = false;
  int _page = 1, _pendingPage = 1;
  int _generation = 0;
  bool _submitted = false;
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty ||
        widget.category != null ||
        widget.libraryTab != null) {
      Future.microtask(_search);
    }
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<ComicSource> get _targets {
    final all = ref.read(enabledComicSourcesProvider);
    return _mode == ComicSearchMode.single
        ? all.where((s) => s.key == _source).toList()
        : all;
  }

  ComicPageBuffer _sourceBuffer(List<ComicSource> sources, String query) {
    final sort = _sort;
    final single = _mode == ComicSearchMode.single;
    return ComicPageBuffer([
      for (final source in sources)
        ComicPageSource(source.key, (cursor) async {
          if (widget.category != null) {
            return source.category(widget.category!, cursor: cursor);
          }
          return source.search(
            query,
            cursor: cursor,
            sort: single ? sort : null,
          );
        }),
    ]);
  }

  Future<ComicPageBuffer> _createBuffer(String query) async {
    if (widget.libraryTab != null) {
      List<Comic> comics;
      final library = ref.read(comicLibraryProvider);
      if (widget.libraryTab == 1 && widget.onlineFavorites) {
        final source = ref
            .read(comicSourcesProvider)
            .firstWhere((source) => source.key == _source);
        return ComicPageBuffer([
          ComicPageSource(source.key, (cursor) async {
            final result = await source.favorites(cursor: cursor);
            final items = _filterLibraryItems(result.items, query);
            return ComicResult(
              items,
              next: result.next,
              totalPages: result.totalPages,
            );
          }),
        ]);
      } else if (widget.libraryTab == 1) {
        comics = await library.favorites();
      } else if (widget.libraryTab == 2) {
        comics = (await library.history())
            .map((progress) => progress.comic)
            .toList();
      } else {
        final downloads = ref.read(comicDownloadsProvider);
        await downloads.ready;
        comics = downloads.completedComics;
      }
      return ComicPageBuffer.fromItems(_filterLibraryItems(comics, query));
    }
    return _sourceBuffer(_targets, query);
  }

  List<Comic> _filterLibraryItems(List<Comic> comics, String query) {
    final needle = query.toLowerCase();
    return comics
        .where(
          (comic) => '${comic.title} ${comic.tags.join(' ')}'
              .toLowerCase()
              .contains(needle),
        )
        .toList();
  }

  Future<void> _loadPage(
    int page, {
    bool reset = false,
    bool retryFailures = false,
  }) async {
    if (!mounted || (_pageLoading && !reset)) return;
    final generation = ++_generation;
    final previousPage = _page;
    final query = _query.text.trim();
    setState(() {
      _submitted = true;
      _pageLoading = true;
      _pendingPage = page;
      if (reset) {
        _buffer = null;
        _pageItems = [];
        _pageErrors = {};
        _errors.clear();
        _pending.clear();
        _page = 1;
        _hasMore = false;
      }
    });
    try {
      var buffer = _buffer;
      if (reset || buffer == null) buffer = await _createBuffer(query);
      if (!mounted || generation != _generation) return;
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
      if (!mounted || generation != _generation) return;
      setState(() {
        _buffer = buffer;
        _pageErrors = result.errors;
        if (result.errors.isEmpty) {
          _pageItems = result.items;
          _page = displayPage;
          _pendingPage = displayPage;
          _hasMore = result.hasMore;
        } else if (_pageItems.isEmpty && result.items.isNotEmpty) {
          _pageItems = result.items;
          _page = displayPage;
          _hasMore = false;
        }
      });
      if (result.errors.isEmpty && (reset || displayPage != previousPage)) {
        _scrollToTop();
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _pageErrors = {'search': error});
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _pageLoading = false);
      }
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

  Future<void> _search({Set<String>? retrySources}) async {
    if (!mounted) return;
    if (_mode != ComicSearchMode.grouped ||
        widget.category != null ||
        widget.libraryTab != null) {
      await _loadPage(1, reset: true);
      return;
    }
    final append = retrySources != null;
    final generation = append ? _generation : ++_generation;
    final query = _query.text.trim();
    setState(() {
      _submitted = true;
      if (!append) {
        _pageLoading = false;
        _pendingPage = 1;
        _hasMore = false;
        _results.clear();
        _errors.clear();
        _pending.clear();
        _buffer = null;
        _pageItems = [];
        _pageErrors = {};
      }
    });
    await Future.wait(
      _targets
          .where(
            (s) => retrySources != null ? retrySources.contains(s.key) : true,
          )
          .map((source) async {
            setState(() => _pending.add(source.key));
            try {
              final result = await source.search(query);
              if (!mounted || generation != _generation) return;
              setState(() {
                _results.putIfAbsent(source.key, () => []).addAll(result.items);
                _errors.remove(source.key);
              });
            } catch (e) {
              if (mounted && generation == _generation) {
                setState(() => _errors[source.key] = e);
              }
            } finally {
              if (mounted && generation == _generation) {
                setState(() => _pending.remove(source.key));
              }
            }
          }),
    );
  }

  String _sortLabel(String sort) {
    final s = S.of(context);
    return switch (sort) {
      'dd' || 'date' || 'mr' => s.comicNewest,
      'da' => s.comicOldest,
      'ld' || 'tf' => s.comicMostLiked,
      'vd' || 'mv' => s.comicMostViewed,
      'mp' => s.comicMostPages,
      'mv_t' || 'popular-today' => s.comicPopularToday,
      'mv_w' || 'popular-week' => s.comicPopularWeek,
      'mv_m' || 'popular-month' => s.comicPopularMonth,
      'popular' => s.displayModePopular,
      _ => sort,
    };
  }

  Widget _group(ComicSource source) {
    final items = _results[source.key] ?? [];
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: Text(source.name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ComicSearchScreen(
                  initialSource: source.key,
                  initialQuery: _query.text,
                ),
              ),
            ),
          ),
          if (_pending.contains(source.key)) const LinearProgressIndicator(),
          if (_errors[source.key] != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Text('${_errors[source.key]}'),
                  TextButton(
                    onPressed: _pending.contains(source.key)
                        ? null
                        : () => _search(retrySources: {source.key}),
                    child: Text(S.of(context).retry),
                  ),
                ],
              ),
            ),
          if (items.isNotEmpty)
            SizedBox(
              height: 210,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                itemBuilder: (context, i) => SizedBox(
                  width: 136,
                  child: InkWell(
                    onTap: () => openComic(context, items[i]),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: HeroMode(
                                enabled: items
                                    .take(i)
                                    .every((c) => c.key != items[i].key),
                                child: ComicCover(
                                  source: source.key,
                                  page: items[i].coverPage,
                                  heroTag: comicCoverHeroTag(items[i]),
                                  maxWidth: 120,
                                  maxHeight: 160,
                                ),
                              ),
                            ),
                          ),
                          Text(
                            items[i].title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(comicPageSizeProvider, (_, __) {
      if (_submitted && _mode != ComicSearchMode.grouped) {
        _loadPage(1, reset: true);
      }
    });
    final pageSize = ref.watch(comicPageSizeProvider);
    final s = S.of(context);
    final sources = ref.watch(enabledComicSourcesProvider);
    final selected = sources.where((s) => s.key == _source).firstOrNull;
    final groupedItems = interleaveComicResults(
      widget.libraryTab != null
          ? _results.values.toList()
          : _targets.map((s) => _results[s.key] ?? <Comic>[]).toList(),
    );
    final items = _mode == ComicSearchMode.grouped ? groupedItems : _pageItems;
    final screen = Scaffold(
      appBar: AppBar(title: Text(widget.category?.title ?? s.search)),
      body: Column(
        children: [
          if (widget.category == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: s.search,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    onPressed: () => _search(),
                    icon: const Icon(Icons.arrow_forward),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ),
          if (widget.libraryTab == null && widget.category == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final mode in ComicSearchMode.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(
                                [
                                  s.comicSearchSingle,
                                  s.comicSearchGrouped,
                                  s.comicSearchMerged,
                                ][mode.index],
                              ),
                              selected: _mode == mode,
                              onSelected: (_) {
                                setState(() => _mode = mode);
                                if (_submitted) _search();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final source in sources)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(source.name),
                              selected:
                                  _mode != ComicSearchMode.single ||
                                  source.key == _source,
                              onSelected: _mode != ComicSearchMode.single
                                  ? null
                                  : (_) {
                                      setState(() {
                                        _source = source.key;
                                        _sort = null;
                                      });
                                      if (_submitted) _search();
                                    },
                            ),
                          ),
                        if (_mode == ComicSearchMode.single &&
                            (selected?.searchSorts.isNotEmpty ?? false))
                          PopupMenuButton<String>(
                            tooltip: s.comicSort,
                            icon: const Icon(Icons.sort),
                            itemBuilder: (_) => selected!.searchSorts
                                .map(
                                  (sort) => PopupMenuItem(
                                    value: sort,
                                    child: Text(_sortLabel(sort)),
                                  ),
                                )
                                .toList(),
                            onSelected: (sort) {
                              setState(() => _sort = sort);
                              if (_submitted) _search();
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (_pending.isNotEmpty || _pageLoading)
            const LinearProgressIndicator(),
          Expanded(
            child: !_submitted
                ? const SizedBox.shrink()
                : _mode == ComicSearchMode.grouped
                ? ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    children: _targets.map(_group).toList(),
                  )
                : Column(
                    children: [
                      Expanded(
                        child: _pageErrors.isNotEmpty && items.isEmpty
                            ? ComicErrorView(
                                error: _pageErrors.values.first,
                                retry: () => _loadPage(
                                  _pendingPage,
                                  retryFailures: _buffer != null,
                                ),
                              )
                            : ComicGrid(comics: items, controller: _scroll),
                      ),
                      if (_pageErrors.isNotEmpty && items.isNotEmpty)
                        MaterialBanner(
                          content: Text(
                            _pageErrors.entries
                                .map((entry) {
                                  final source = sources
                                      .where(
                                        (source) => source.key == entry.key,
                                      )
                                      .firstOrNull;
                                  return '${source?.name ?? entry.key}: ${entry.value}';
                                })
                                .join('\n'),
                          ),
                          actions: [
                            TextButton(
                              onPressed: _pageLoading
                                  ? null
                                  : () => _loadPage(
                                      _pendingPage,
                                      retryFailures: true,
                                    ),
                              child: Text(s.retry),
                            ),
                          ],
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        child: PaginationBar(
                          currentPage: _page,
                          pageSize: pageSize,
                          totalCount: null,
                          hasMore: _hasMore && _pageErrors.isEmpty,
                          isLoading: _pageLoading,
                          onPreviousPage: _page > 1
                              ? () => _loadPage(_page - 1)
                              : null,
                          onNextPage: _hasMore && _pageErrors.isEmpty
                              ? () => _loadPage(_page + 1)
                              : null,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
    return widget.dockHandoff
        ? GlobalAudioPlayerWrapper.workDetails(child: screen)
        : GlobalAudioPlayerWrapper(child: screen);
  }
}

class ComicCategoryScreen extends ConsumerStatefulWidget {
  const ComicCategoryScreen({super.key, required this.sourceKey});
  final String sourceKey;
  @override
  ConsumerState<ComicCategoryScreen> createState() =>
      _ComicCategoryScreenState();
}

class _ComicCategoryScreenState extends ConsumerState<ComicCategoryScreen> {
  late Future<List<ComicCategory>> _categories;
  void _load() {
    _categories = ref
        .read(comicSourcesProvider)
        .firstWhere((s) => s.key == widget.sourceKey)
        .categories();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) => GlobalAudioPlayerWrapper(
    child: Scaffold(
      appBar: AppBar(title: Text(S.of(context).comicCategories)),
      body: FutureBuilder<List<ComicCategory>>(
        future: _categories,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ComicErrorView(
              error: snapshot.error!,
              retry: () => setState(_load),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            children: [
              for (final category in snapshot.data!)
                ListTile(
                  title: Text(category.title),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ComicSearchScreen(
                        initialSource: widget.sourceKey,
                        category: category,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/work_detail/work_cover_frame.dart';
import '../comic_models.dart';
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
  final _next = <String, String?>{};
  final _errors = <String, Object>{};
  final _pending = <String>{};
  int _generation = 0;
  bool _submitted = false;
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
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

  void _onScroll() {
    if (_scroll.position.extentAfter < 600 &&
        _mode != ComicSearchMode.grouped &&
        _pending.isEmpty &&
        _next.values.any((n) => n != null)) {
      _search(more: true);
    }
  }

  List<ComicSource> get _targets {
    final all = ref.read(enabledComicSourcesProvider);
    return _mode == ComicSearchMode.single
        ? all.where((s) => s.key == _source).toList()
        : all;
  }

  Future<void> _search({bool more = false, Set<String>? retrySources}) async {
    if (!mounted) return;
    final append = more || retrySources != null;
    final generation = append ? _generation : ++_generation;
    final query = _query.text.trim();
    setState(() {
      _submitted = true;
      if (!append) {
        _results.clear();
        _next.clear();
        _errors.clear();
        _pending.clear();
      }
    });
    if (widget.libraryTab != null) {
      const key = 'library';
      setState(() => _pending.add(key));
      try {
        List<Comic> comics;
        final library = ref.read(comicLibraryProvider);
        if (widget.libraryTab == 1 && widget.onlineFavorites) {
          final source = ref
              .read(comicSourcesProvider)
              .firstWhere((s) => s.key == _source);
          comics = [];
          String? cursor;
          do {
            final result = await source.favorites(cursor: cursor);
            comics.addAll(result.items);
            cursor = result.next;
            if (!mounted || generation != _generation) return;
          } while (cursor != null);
        } else if (widget.libraryTab == 1) {
          comics = await library.favorites();
        } else if (widget.libraryTab == 2) {
          comics = (await library.history()).map((p) => p.comic).toList();
        } else {
          final downloads = ref.read(comicDownloadsProvider);
          await downloads.ready;
          comics = downloads.completedComics;
        }
        if (mounted && generation == _generation) {
          setState(
            () => _results[key] = comics
                .where(
                  (c) => '${c.title} ${c.tags.join(' ')}'
                      .toLowerCase()
                      .contains(query.toLowerCase()),
                )
                .toList(),
          );
        }
      } catch (e) {
        if (mounted && generation == _generation) {
          setState(() => _errors[key] = e);
        }
      } finally {
        if (mounted && generation == _generation) {
          setState(() => _pending.remove(key));
        }
      }
      return;
    }
    await Future.wait(
      _targets
          .where(
            (s) => retrySources != null
                ? retrySources.contains(s.key)
                : !more || _next[s.key] != null,
          )
          .map((source) async {
            setState(() => _pending.add(source.key));
            try {
              final result = widget.category != null
                  ? await source.category(
                      widget.category!,
                      cursor: append ? _next[source.key] : null,
                    )
                  : await source.search(
                      query,
                      cursor: append ? _next[source.key] : null,
                      sort: _mode == ComicSearchMode.single ? _sort : null,
                    );
              if (!mounted || generation != _generation) return;
              setState(() {
                _results.putIfAbsent(source.key, () => []).addAll(result.items);
                _next[source.key] = result.next;
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
                            child: HeroMode(
                              enabled: items
                                  .take(i)
                                  .every((c) => c.key != items[i].key),
                              child: WorkCoverHeroFrame(
                                heroTag: comicCoverHeroTag(items[i]),
                                cornerRadius: workCoverCompactRadius,
                                child: ComicImage(
                                  source: source.key,
                                  page: items[i].coverPage,
                                  fit: BoxFit.contain,
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
    final s = S.of(context);
    final sources = ref.watch(enabledComicSourcesProvider);
    final selected = sources.where((s) => s.key == _source).firstOrNull;
    final items = interleaveComicResults(
      widget.libraryTab != null
          ? _results.values.toList()
          : _targets.map((s) => _results[s.key] ?? <Comic>[]).toList(),
    );
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
          if (_pending.isNotEmpty) const LinearProgressIndicator(),
          if (_errors.isNotEmpty &&
              _mode != ComicSearchMode.grouped &&
              items.isNotEmpty)
            MaterialBanner(
              content: Text(
                _errors.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
              ),
              actions: [
                TextButton(
                  onPressed: () => _search(retrySources: _errors.keys.toSet()),
                  child: Text(s.retry),
                ),
              ],
            ),
          Expanded(
            child: !_submitted
                ? const SizedBox.shrink()
                : _mode == ComicSearchMode.grouped
                ? ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    children: _targets.map(_group).toList(),
                  )
                : _errors.isNotEmpty && items.isEmpty && _pending.isEmpty
                ? ComicErrorView(
                    error: _errors.values.first,
                    retry: () => _search(),
                  )
                : ComicGrid(comics: items, controller: _scroll),
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

import 'dart:async';

import '../../widgets/app_bottom_dock_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../../../l10n/app_localizations.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/pagination_bar.dart';
import '../../widgets/search_condition_chip.dart';
import '../../widgets/search_history_section.dart';
import '../../widgets/search_input_decoration.dart';
import '../../widgets/search_options_button.dart';
import '../../providers/unified_search_history_provider.dart';
import '../../providers/works_provider.dart' show LayoutType;
import '../comic_models.dart';
import '../comic_pagination.dart';
import '../comic_providers.dart';
import '../comic_source.dart';
import 'comic_widgets.dart';

enum ComicSearchMode { single, grouped, merged }

enum _ComicSearchSuggestionEmptyState { noHistory, noMatches }

class _ComicSearchOptionsList extends StatefulWidget {
  const _ComicSearchOptionsList({
    required this.options,
    required this.highlightedIndex,
    required this.localizations,
    required this.onSelected,
  });

  final Iterable<Object> options;
  final int highlightedIndex;
  final S localizations;
  final ValueChanged<Object> onSelected;

  @override
  State<_ComicSearchOptionsList> createState() =>
      _ComicSearchOptionsListState();
}

class _ComicSearchOptionsListState extends State<_ComicSearchOptionsList> {
  final _scrollController = ItemScrollController();
  final _itemPositions = ItemPositionsListener.create();

  @override
  void didUpdateWidget(_ComicSearchOptionsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlightedIndex == oldWidget.highlightedIndex) return;

    final highlightedIndex = widget.highlightedIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.highlightedIndex != highlightedIndex ||
          !_scrollController.isAttached ||
          highlightedIndex < 0 ||
          highlightedIndex >= widget.options.length) {
        return;
      }
      final highlightedIsVisible = _itemPositions.itemPositions.value.any(
        (position) =>
            position.index == highlightedIndex &&
            position.itemLeadingEdge >= 0 &&
            position.itemTrailingEdge <= 1,
      );
      if (!highlightedIsVisible) {
        _scrollController.jumpTo(index: highlightedIndex);
      }
    }, debugLabel: 'ComicSearchOptions.ensureVisible');
  }

  @override
  Widget build(BuildContext context) => ScrollablePositionedList.builder(
    key: const ValueKey('comic-search-history-suggestions'),
    padding: EdgeInsets.zero,
    shrinkWrap: true,
    initialScrollIndex: widget.options.isEmpty
        ? 0
        : widget.highlightedIndex.clamp(0, widget.options.length - 1).toInt(),
    itemCount: widget.options.length,
    itemScrollController: _scrollController,
    itemPositionsListener: _itemPositions,
    itemBuilder: (context, index) {
      final option = widget.options.elementAt(index);
      if (option is! String) {
        return ListTile(
          leading: const Icon(Icons.history),
          title: Text(
            option == _ComicSearchSuggestionEmptyState.noHistory
                ? widget.localizations.noSearchHistory
                : widget.localizations.noResults,
          ),
          enabled: false,
        );
      }
      return ListTile(
        leading: const Icon(Icons.history),
        title: Text(option, maxLines: 1, overflow: TextOverflow.ellipsis),
        selected: index == widget.highlightedIndex,
        onTap: () => widget.onSelected(option),
      );
    },
  );
}

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
  });
  final String? initialSource;
  final String initialQuery;
  final int? libraryTab;
  final bool onlineFavorites;
  final ComicCategory? category;
  @override
  ConsumerState<ComicSearchScreen> createState() => _ComicSearchScreenState();
}

class _ComicSearchScreenState extends ConsumerState<ComicSearchScreen> {
  late final _query = TextEditingController(text: widget.initialQuery);
  final _searchFocusNode = FocusNode();
  late String _source =
      widget.initialSource ?? ref.read(comicSelectedSourceProvider);
  ComicSearchMode _mode = ComicSearchMode.single;
  ComicSearchMode _displayMode = ComicSearchMode.single;
  Set<String>? _selectedSourceKeys;
  List<ComicSource> _displaySources = [];
  String _displayQuery = '';
  String? _sort;
  final _results = <String, List<Comic>>{};
  final _errors = <String, Object>{};
  final _pending = <String>{};
  ComicPageBuffer? _buffer;
  List<Comic> _pageItems = [];
  Map<String, Object> _pageErrors = {};
  bool _pageLoading = false, _hasMore = false;
  int _page = 1, _pendingPage = 1;
  final _visitedPages = ComicVisitedPages();
  int _generation = 0;
  int? _pageTurnRequest;
  int? _cancelledPageTurnRequest;
  int? _scrollingRequest;
  int? _interruptedScrollRequest;
  ModalRoute<dynamic>? _route;
  bool _submitted = false;
  bool _userSearchSubmitted = false;
  bool _historySessionActive = false;
  bool _showHistory = false;
  bool _keyboardSuggestionNavigated = false;
  bool _queryIsComposing = false;
  bool _searchUpdateFailed = false;
  final _scroll = ScrollController();
  late final _historySession = UnifiedSearchHistorySession(
    ref.read(unifiedSearchHistoryProvider.notifier),
  );

  bool get _hasVisibleResults => _displayMode == ComicSearchMode.grouped
      ? _results.values.any((items) => items.isNotEmpty)
      : _pageItems.isNotEmpty;

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
  void initState() {
    super.initState();
    _showHistory =
        widget.category == null &&
        widget.libraryTab == null &&
        widget.initialQuery.isEmpty;
    _searchFocusNode.addListener(_refreshSearchSuggestions);
    _query.addListener(_queryValueChanged);
    if (widget.initialQuery.isNotEmpty ||
        widget.category != null ||
        widget.libraryTab != null) {
      Future.microtask(() {
        if (!mounted) return;
        if (widget.initialQuery.trim().isNotEmpty) {
          _userSearchSubmitted = true;
          _historySessionActive = true;
          unawaited(_historySession.submit(_historyContext, _historyPayload));
        }
        unawaited(_search());
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _listenToRoute(_route, add: false);
    _searchFocusNode.removeListener(_refreshSearchSuggestions);
    _query.removeListener(_queryValueChanged);
    _query.dispose();
    _searchFocusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<ComicSource> get _targets {
    final all = ref.read(enabledComicSourcesProvider);
    return _mode == ComicSearchMode.single
        ? all.where((s) => s.key == _source).toList()
        : all
              .where(
                (source) =>
                    _selectedSourceKeys == null ||
                    _selectedSourceKeys!.contains(source.key),
              )
              .toList();
  }

  String get _historyEntryScope => switch (widget.libraryTab) {
    1 when widget.onlineFavorites => 'online-favorites',
    1 => 'local-favorites',
    2 => 'history',
    3 => 'downloads',
    _ => 'source-directory',
  };

  String get _historySource => switch (_historyEntryScope) {
    'local-favorites' || 'history' || 'downloads' => 'local',
    _ => _mode == ComicSearchMode.single ? _source : 'multi',
  };

  UnifiedSearchHistoryContext get _historyContext =>
      UnifiedSearchHistoryContext(
        contentType: 'comic',
        entryScope: _historyEntryScope,
        source: _historySource,
      );

  Map<String, Object?> get _historyPayload {
    final sources = switch (_historyEntryScope) {
      'local-favorites' || 'history' || 'downloads' => ['local'],
      'online-favorites' => [_source],
      _ when _mode == ComicSearchMode.single => [_source],
      _ =>
        _selectedSourceKeys?.toList() ??
            _targets.map((source) => source.key).toList(),
    };
    return {
      'keyword': _query.text.trim(),
      'mode': _mode.name,
      'source': _historySource,
      'sources': sources,
      'sort': _sort,
    };
  }

  void _submitSearch() {
    _searchFocusNode.unfocus();
    _keyboardSuggestionNavigated = false;
    _userSearchSubmitted = true;
    _historySessionActive = true;
    if (_showHistory) setState(() => _showHistory = false);
    unawaited(_historySession.submit(_historyContext, _historyPayload));
    unawaited(_search());
  }

  void _queryValueChanged() {
    final isComposing =
        _query.value.composing.isValid && !_query.value.composing.isCollapsed;
    if (isComposing == _queryIsComposing) return;
    _queryIsComposing = isComposing;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshSearchSuggestions();
    });
  }

  void _refreshSearchSuggestions() {
    if (!_searchFocusNode.hasFocus) {
      _keyboardSuggestionNavigated = false;
      return;
    }
    _keyboardSuggestionNavigated = false;
    final value = _query.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    final selection = value.selection;
    // Refresh options without changing the query or its IME composition.
    _query.value = value.copyWith(
      selection: selection.isValid
          ? selection.copyWith(
              affinity: selection.affinity == TextAffinity.upstream
                  ? TextAffinity.downstream
                  : TextAffinity.upstream,
            )
          : TextSelection.collapsed(offset: value.text.length),
    );
  }

  void _clearSearch() {
    _keyboardSuggestionNavigated = false;
    _generation++;
    _pageTurnRequest = null;
    _cancelledPageTurnRequest = null;
    setState(() {
      _query.clear();
      _mode = ComicSearchMode.single;
      _selectedSourceKeys = null;
      _sort = null;
      _submitted = false;
      _userSearchSubmitted = false;
      _historySessionActive = false;
      _showHistory = true;
      _searchUpdateFailed = false;
      _pageLoading = false;
      _hasMore = false;
      _page = 1;
      _pendingPage = 1;
      _buffer = null;
      _pageItems = [];
      _pageErrors = {};
      _results.clear();
      _errors.clear();
      _pending.clear();
      _displayMode = ComicSearchMode.single;
      _displaySources = [];
      _displayQuery = '';
      _visitedPages.reset();
    });
  }

  void _onFilterChanged() {
    _searchFocusNode.unfocus();
    _keyboardSuggestionNavigated = false;
    final query = _query.text.trim();
    final shouldSearch =
        _userSearchSubmitted || query.isNotEmpty || _hasVisibleResults;
    if (!shouldSearch) return;
    if (_showHistory) setState(() => _showHistory = false);
    _userSearchSubmitted = true;
    if (!_historySessionActive && query.isNotEmpty) {
      _historySessionActive = true;
      unawaited(_historySession.submit(_historyContext, _historyPayload));
    } else if (_historySessionActive) {
      unawaited(_historySession.update(_historyContext, _historyPayload));
    }
    unawaited(_search());
  }

  String _historyLabel(UnifiedSearchHistoryEntry entry) {
    final s = S.of(context);
    final payload = entry.payload;
    final rawMode = payload['mode'];
    final mode = ComicSearchMode.values.firstWhere(
      (value) => value.name == rawMode,
      orElse: () => ComicSearchMode.single,
    );
    final modeLabel = [
      s.comicSearchSingle,
      s.comicSearchGrouped,
      s.comicSearchMerged,
    ][mode.index];
    final rawSources = payload['sources'];
    final sourceKeys = rawSources is List
        ? rawSources.whereType<String>().toList()
        : const <String>[];
    final sources = ref.read(comicSourcesProvider);
    final sourceLabel = sourceKeys
        .map(
          (key) =>
              sources.where((source) => source.key == key).firstOrNull?.name ??
              key,
        )
        .join(', ');
    final keyword = payload['keyword'];
    final sort = payload['sort'];
    return [
      if (keyword is String && keyword.isNotEmpty) keyword,
      modeLabel,
      if (sourceLabel.isNotEmpty) sourceLabel,
      if (sort is String) _sortLabel(sort),
    ].join(' · ');
  }

  List<String> _searchHistorySuggestions(
    List<UnifiedSearchHistoryEntry> entries,
    TextEditingValue value,
  ) {
    if (value.composing.isValid && !value.composing.isCollapsed) {
      return const [];
    }
    final query = value.text.trim().toLowerCase();
    final seen = <String>{};
    return entries
        .map((entry) => entry.payload['keyword'])
        .whereType<String>()
        .map((keyword) => keyword.trim())
        .where(
          (keyword) =>
              keyword.isNotEmpty &&
              (query.isEmpty || keyword.toLowerCase().contains(query)) &&
              seen.add(keyword.toLowerCase()),
        )
        .toList();
  }

  void _replayHistory(UnifiedSearchHistoryEntry entry) {
    _keyboardSuggestionNavigated = false;
    final payload = entry.payload;
    final modeName = payload['mode'];
    final mode = ComicSearchMode.values.firstWhere(
      (value) => value.name == modeName,
      orElse: () => ComicSearchMode.single,
    );
    final sourceValue = payload['source'];
    final rawSources = payload['sources'];
    final sourceKeys = rawSources is List
        ? rawSources.whereType<String>().toList()
        : const <String>[];
    final keyword = payload['keyword'];
    final sort = payload['sort'];
    setState(() {
      _query.text = keyword is String ? keyword : '';
      _mode = mode;
      _source = sourceValue is String
          ? sourceValue
          : sourceKeys.firstOrNull ?? _source;
      _selectedSourceKeys = mode == ComicSearchMode.single
          ? null
          : sourceKeys.toSet();
      if (mode != ComicSearchMode.single && sourceKeys.isNotEmpty) {
        _source = sourceKeys.first;
      }
      _sort = sort is String ? sort : null;
      _showHistory = false;
    });
    _userSearchSubmitted = true;
    _historySessionActive = true;
    unawaited(
      _historySession.replay(
        context: _historyContext,
        payload: _historyPayload,
        entry: entry,
      ),
    );
    unawaited(_search());
  }

  void _removeHistoryEntry(UnifiedSearchHistoryEntry entry) {
    unawaited(
      ref
          .read(unifiedSearchHistoryProvider.notifier)
          .remove(entry.context, entry.id),
    );
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
    if (!mounted ||
        (_pageLoading && !reset) ||
        (_pending.isNotEmpty && !reset)) {
      return;
    }
    final generation = ++_generation;
    final previousPage = _page;
    final pageTurnRequest = !reset && page != previousPage;
    if (reset) {
      _pageTurnRequest = null;
      _cancelledPageTurnRequest = null;
    } else if (pageTurnRequest) {
      _pageTurnRequest = generation;
      _cancelledPageTurnRequest = null;
    }
    final query = _query.text.trim();
    final keepPrevious = reset && _hasVisibleResults;
    setState(() {
      _submitted = true;
      _pageLoading = true;
      _pendingPage = page;
      if (reset) {
        _buffer = null;
        if (!keepPrevious) {
          _pageItems = [];
          _results.clear();
          _displayMode = _mode;
        }
        _pageErrors = {};
        _errors.clear();
        _pending.clear();
        _searchUpdateFailed = false;
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
      if (pageTurnRequest && _isPageTurnCancelled(generation)) {
        setState(() => _pendingPage = previousPage);
        return;
      }
      if (result.errors.isEmpty && (reset || displayPage != previousPage)) {
        final pageTurn = pageTurnRequest && displayPage != previousPage;
        if (pageTurn && ModalRoute.of(context)?.isCurrent == false) {
          setState(() => _pendingPage = previousPage);
          return;
        }
        final reachedTop = await _scrollBeforePageCommit(
          generation,
          requireCurrentPage: pageTurn,
        );
        if (!mounted || generation != _generation) return;
        if (!reachedTop) {
          setState(() => _pendingPage = previousPage);
          return;
        }
        if (pageTurn && ModalRoute.of(context)?.isCurrent == false) {
          setState(() => _pendingPage = previousPage);
          return;
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _buffer = buffer;
        _pageErrors = result.errors;
        if (result.errors.isEmpty || (reset && result.items.isNotEmpty)) {
          _pageItems = result.items;
          _results.clear();
          _displayMode = _mode;
          _displaySources = _targets;
          _displayQuery = query;
          _page = displayPage;
          _pendingPage = displayPage;
          if (reset) {
            _visitedPages.reset(maximum: displayPage);
          } else {
            _visitedPages.markDisplayed(displayPage);
          }
          _hasMore = result.errors.isEmpty && result.hasMore;
        } else if (_pageItems.isEmpty && result.items.isNotEmpty) {
          _pageItems = result.items;
          _page = displayPage;
          _hasMore = false;
        } else if (keepPrevious) {
          _searchUpdateFailed = true;
        }
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _pageErrors = {'search': error};
          _searchUpdateFailed = keepPrevious;
        });
      }
    } finally {
      if (_pageTurnRequest == generation) _pageTurnRequest = null;
      if (mounted && generation == _generation) {
        setState(() => _pageLoading = false);
      }
    }
  }

  bool _isPageTurnCancelled(int request) =>
      _cancelledPageTurnRequest == request ||
      ModalRoute.of(context)?.isCurrent == false;

  Future<bool> _scrollBeforePageCommit(
    int request, {
    required bool requireCurrentPage,
  }) async {
    bool isCurrentPage() =>
        !requireCurrentPage || ModalRoute.of(context)?.isCurrent != false;
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
          isCurrentPage() &&
          _scroll.hasClients &&
          _scroll.position.pixels <= 1;
    } finally {
      if (_scrollingRequest == request) _scrollingRequest = null;
    }
  }

  Future<void> _search({Set<String>? retrySources}) async {
    if (!mounted) return;
    final append = retrySources != null;
    if (append && (_pageLoading || _pending.isNotEmpty)) return;
    if (!append &&
        (_mode != ComicSearchMode.grouped ||
            widget.category != null ||
            widget.libraryTab != null)) {
      await _loadPage(1, reset: true);
      return;
    }
    final generation = append ? _generation : ++_generation;
    final query = append ? _displayQuery : _query.text.trim();
    final targets = append ? _displaySources : _targets;
    final keepPrevious = !append && _hasVisibleResults;
    final nextResults = <String, List<Comic>>{};
    final nextErrors = <String, Object>{};
    setState(() {
      _submitted = true;
      if (!append) {
        _pageLoading = false;
        _pendingPage = 1;
        _errors.clear();
        _pending.clear();
        _buffer = null;
        _pageErrors = {};
        _searchUpdateFailed = false;
        if (!keepPrevious) {
          _results.clear();
          _pageItems = [];
          _displayMode = ComicSearchMode.grouped;
          _displaySources = targets;
          _displayQuery = query;
        }
      }
    });
    await Future.wait(
      targets
          .where(
            (s) => retrySources != null ? retrySources.contains(s.key) : true,
          )
          .map((source) async {
            setState(() => _pending.add(source.key));
            try {
              final result = await source.search(query);
              if (!mounted || generation != _generation) return;
              setState(() {
                if (append) {
                  _results[source.key] = result.items;
                  _errors.remove(source.key);
                } else {
                  nextResults[source.key] = result.items;
                }
              });
            } catch (e) {
              if (mounted && generation == _generation) {
                setState(() {
                  if (append) {
                    _errors[source.key] = e;
                  } else {
                    nextErrors[source.key] = e;
                  }
                });
              }
            } finally {
              if (mounted && generation == _generation) {
                setState(() => _pending.remove(source.key));
              }
            }
          }),
    );
    if (!mounted || generation != _generation || append) return;
    setState(() {
      if (keepPrevious && nextResults.isEmpty && nextErrors.isNotEmpty) {
        _searchUpdateFailed = true;
        return;
      }
      _results
        ..clear()
        ..addAll(nextResults);
      _errors
        ..clear()
        ..addAll(nextErrors);
      _pageItems = [];
      _displayMode = ComicSearchMode.grouped;
      _displaySources = targets;
      _displayQuery = query;
    });
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

  Widget _filterChoiceChip({
    required String label,
    required bool selected,
    required ValueChanged<bool>? onSelected,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: onSelected,
        showCheckmark: true,
        checkmarkColor: colors.primary,
        selectedColor: colors.primaryContainer,
        backgroundColor: Colors.transparent,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        labelStyle: theme.textTheme.labelLarge?.copyWith(
          color: selected ? colors.primary : colors.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  Widget _group(ComicSource source) {
    final items = _results[source.key] ?? [];
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Builder(
            builder: (context) => ListTile(
              title: Text(source.name),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => pushBottomDockRoute(
                context,
                builder: (_) => ComicSearchScreen(
                  initialSource: source.key,
                  initialQuery: _displayQuery,
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
                    onPressed: _pending.isNotEmpty || _pageLoading
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
                    onTap: () => openComic(
                      context,
                      items[i],
                      initialCoverWidth: 120,
                      initialCoverMaxHeight: 160,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: ComicCover(
                                source: source.key,
                                page: items[i].coverPage,
                                maxWidth: 120,
                                maxHeight: 160,
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
    ref.listen(unifiedSearchHistoryProvider, (_, __) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshSearchSuggestions();
      });
    });
    ref.listen(comicPageSizeProvider, (_, __) {
      if (_submitted && _mode != ComicSearchMode.grouped) {
        _loadPage(1, reset: true);
      }
    });
    final pageSize = ref.watch(comicPageSizeProvider);
    final layoutType = ref.watch(comicLayoutProvider);
    final s = S.of(context);
    final sources = ref.watch(enabledComicSourcesProvider);
    final searchHistory = ref.watch(unifiedSearchHistoryProvider);
    final historyContext = _historyContext;
    final historyEntries = searchHistory.itemsFor(historyContext);
    final historyNotifier = ref.read(unifiedSearchHistoryProvider.notifier);
    final selected = sources.where((s) => s.key == _source).firstOrNull;
    final isGlobalSearch = widget.category == null && widget.libraryTab == null;
    final groupedItems = interleaveComicResults(
      widget.libraryTab != null
          ? _results.values.toList()
          : _displaySources.map((s) => _results[s.key] ?? <Comic>[]).toList(),
    );
    final items = _displayMode == ComicSearchMode.grouped
        ? groupedItems
        : _pageItems;
    final scopeLabel = switch (widget.libraryTab) {
      1 =>
        widget.onlineFavorites ? s.comicOnlineFavorites : s.comicLocalFavorites,
      2 => s.libraryHistory,
      null => null,
      _ => s.libraryDownloads,
    };
    Widget searchField() => Expanded(
      child: Autocomplete<Object>(
        key: ValueKey((
          historyContext.key,
          searchHistory.entries,
          _queryIsComposing,
        )),
        displayStringForOption: (option) =>
            option is String ? option : _query.text,
        textEditingController: _query,
        focusNode: _searchFocusNode,
        optionsBuilder: (value) {
          if (value.composing.isValid && !value.composing.isCollapsed) {
            return const <Object>[];
          }
          final suggestions = _searchHistorySuggestions(historyEntries, value);
          if (suggestions.isNotEmpty) return suggestions;
          return [
            historyEntries.isEmpty
                ? _ComicSearchSuggestionEmptyState.noHistory
                : _ComicSearchSuggestionEmptyState.noMatches,
          ];
        },
        optionsMaxHeight: 280,
        optionsViewBuilder: (context, onSelected, options) {
          final highlightedIndex = AutocompleteHighlightedOption.of(context);
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 8,
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: _ComicSearchOptionsList(
                  options: options,
                  highlightedIndex: highlightedIndex,
                  localizations: s,
                  onSelected: onSelected,
                ),
              ),
            ),
          );
        },
        onSelected: (option) {
          if (option is String) {
            _keyboardSuggestionNavigated = false;
          }
        },
        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) =>
            Focus(
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }
                if (event.logicalKey == LogicalKeyboardKey.escape) {
                  _keyboardSuggestionNavigated = false;
                  _searchFocusNode.unfocus();
                } else if (_searchHistorySuggestions(
                      historyEntries,
                      _query.value,
                    ).isNotEmpty &&
                    const [
                      LogicalKeyboardKey.arrowDown,
                      LogicalKeyboardKey.arrowUp,
                      LogicalKeyboardKey.pageDown,
                      LogicalKeyboardKey.pageUp,
                    ].contains(event.logicalKey)) {
                  _keyboardSuggestionNavigated = true;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                key: const ValueKey('comic-search-input'),
                controller: controller,
                focusNode: focusNode,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) {
                  final value = _query.value;
                  if (value.composing.isValid && !value.composing.isCollapsed) {
                    return;
                  }
                  if (_keyboardSuggestionNavigated &&
                      _searchHistorySuggestions(
                        historyEntries,
                        value,
                      ).isNotEmpty) {
                    _keyboardSuggestionNavigated = false;
                    onFieldSubmitted();
                  } else {
                    _submitSearch();
                  }
                },
                onChanged: (_) {
                  _keyboardSuggestionNavigated = false;
                  setState(() {});
                },
                decoration: searchInputDecoration(
                  hintText: s.search,
                  suffixIcon: IconButton(
                    tooltip: s.clear,
                    onPressed: _clearSearch,
                    icon: const Icon(Icons.clear),
                  ),
                ),
              ),
            ),
      ),
    );
    Widget searchButton() => IconButton(
      key: const ValueKey('comic-search-submit'),
      tooltip: s.search,
      onPressed: _submitSearch,
      icon: const Icon(Icons.search),
    );
    Widget displaySettingsButton() => SearchOptionsButton(
      icon: Icons.settings_outlined,
      tooltip: s.feedSettings,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s.layout, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (layout, label) in [
                (LayoutType.bigGrid, s.layoutBigGrid),
                (LayoutType.smallGrid, s.layoutSmallGrid),
                (LayoutType.list, s.layoutList),
              ])
                _filterChoiceChip(
                  label: label,
                  selected: layoutType == layout,
                  onSelected: (_) =>
                      ref.read(comicLayoutProvider.notifier).set(layout),
                ),
            ],
          ),
          if (_mode == ComicSearchMode.single &&
              (selected?.searchSorts.isNotEmpty ?? false)) ...[
            const SizedBox(height: 16),
            Text(s.comicSort, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final sort in selected!.searchSorts)
                  _filterChoiceChip(
                    label: _sortLabel(sort),
                    selected: sort == (_sort ?? selected.searchSorts.first),
                    onSelected: (_) {
                      setState(() => _sort = sort);
                      _onFilterChanged();
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    Widget advancedFiltersButton() => SearchOptionsButton(
      icon: Icons.tune,
      tooltip: s.advancedFilter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final mode in ComicSearchMode.values)
                _filterChoiceChip(
                  label: [
                    s.comicSearchSingle,
                    s.comicSearchGrouped,
                    s.comicSearchMerged,
                  ][mode.index],
                  selected: _mode == mode,
                  onSelected: (_) {
                    setState(() {
                      if (_mode == ComicSearchMode.single &&
                          mode != ComicSearchMode.single) {
                        _selectedSourceKeys = null;
                      }
                      _mode = mode;
                    });
                    _onFilterChanged();
                  },
                ),
            ],
          ),
          if (_mode != ComicSearchMode.single && sources.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              s.librarySources,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            for (final source in sources)
              CheckboxListTile(
                value:
                    _selectedSourceKeys == null ||
                    _selectedSourceKeys!.contains(source.key),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onChanged: (selected) {
                  final selectedKeys = Set<String>.of(
                    _selectedSourceKeys ?? sources.map((source) => source.key),
                  );
                  if (selected == true) {
                    selectedKeys.add(source.key);
                  } else {
                    selectedKeys.remove(source.key);
                  }
                  setState(() => _selectedSourceKeys = selectedKeys);
                  _onFilterChanged();
                },
              ),
          ],
        ],
      ),
    );
    final screen = Scaffold(
      appBar: AppBar(
        title: Text(
          widget.category?.title ??
              (scopeLabel == null ? s.search : s.searchInScope(scopeLabel)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (isGlobalSearch) displaySettingsButton(),
          if (isGlobalSearch) advancedFiltersButton(),
          if (widget.category == null)
            IconButton(
              key: const ValueKey('comic-search-history-toggle'),
              tooltip: _showHistory ? s.close : s.searchHistory,
              icon: Icon(_showHistory ? Icons.close : Icons.history),
              onPressed: () => setState(() => _showHistory = !_showHistory),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            if (widget.category == null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * .6,
                ),
                child: SingleChildScrollView(
                  key: const ValueKey('comic-search-top-controls'),
                  primary: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(children: [searchField(), searchButton()]),
                        ),
                        if (isGlobalSearch)
                          SizedBox(
                            height: 48,
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final source in sources)
                                    _filterChoiceChip(
                                      label: source.name,
                                      selected:
                                          _mode == ComicSearchMode.single &&
                                          source.key == _source,
                                      onSelected: (_) {
                                        setState(() {
                                          _mode = ComicSearchMode.single;
                                          if (_source != source.key) {
                                            _sort = null;
                                          }
                                          _source = source.key;
                                        });
                                        _onFilterChanged();
                                      },
                                    ),
                                ],
                              ),
                            ),
                          ),
                        if (isGlobalSearch)
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final colorScheme = Theme.of(context).colorScheme;
                              final conditions = [
                                SearchConditionChip(
                                  label: [
                                    s.comicSearchSingle,
                                    s.comicSearchGrouped,
                                    s.comicSearchMerged,
                                  ][_mode.index],
                                  avatar: const Icon(Icons.search, size: 16),
                                  maxLines: 1,
                                  backgroundColor:
                                      colorScheme.secondaryContainer,
                                ),
                                if (_mode == ComicSearchMode.single &&
                                    selected != null)
                                  SearchConditionChip(
                                    label: selected.name,
                                    avatar: const Icon(
                                      Icons.source_outlined,
                                      size: 16,
                                    ),
                                    maxLines: 1,
                                    backgroundColor:
                                        colorScheme.secondaryContainer,
                                  ),
                                if (_mode != ComicSearchMode.single &&
                                    _targets.isNotEmpty)
                                  SearchConditionChip(
                                    label: _targets
                                        .map((source) => source.name)
                                        .join(', '),
                                    avatar: const Icon(
                                      Icons.source_outlined,
                                      size: 16,
                                    ),
                                    maxLines: 1,
                                    backgroundColor:
                                        colorScheme.secondaryContainer,
                                  ),
                                if (_sort != null)
                                  SearchConditionChip(
                                    label: _sortLabel(_sort!),
                                    avatar: const Icon(Icons.sort, size: 16),
                                    maxLines: 1,
                                    backgroundColor:
                                        colorScheme.secondaryContainer,
                                  ),
                              ];
                              return SizedBox(
                                height: MediaQuery.textScalerOf(
                                  context,
                                ).scale(40),
                                child: ListView.separated(
                                  key: const ValueKey(
                                    'comic-search-selected-conditions',
                                  ),
                                  scrollDirection: Axis.horizontal,
                                  itemCount: conditions.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 8),
                                  itemBuilder: (context, index) =>
                                      ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth: constraints.maxWidth,
                                        ),
                                        child: conditions[index],
                                      ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_pending.isNotEmpty || _pageLoading) ...[
              if (_hasVisibleResults)
                Semantics(liveRegion: true, child: Text(s.searchUpdating)),
              const LinearProgressIndicator(),
            ],
            if (_searchUpdateFailed)
              MaterialBanner(
                content: Text(s.searchUpdateFailedShowingPrevious),
                actions: [TextButton(onPressed: _search, child: Text(s.retry))],
              ),
            Expanded(
              child: _showHistory
                  ? SingleChildScrollView(
                      child: SearchHistorySection(
                        entries: historyEntries,
                        labelFor: _historyLabel,
                        onSelect: _replayHistory,
                        onRemove: _removeHistoryEntry,
                        onClear: () =>
                            unawaited(historyNotifier.clear(historyContext)),
                        isLoading: searchHistory.isLoading,
                        canPersist: historyNotifier.canPersist,
                      ),
                    )
                  : !_submitted
                  ? const SizedBox.shrink()
                  : _displayMode == ComicSearchMode.grouped
                  ? ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.all(16),
                      children: _displaySources.map(_group).toList(),
                    )
                  : NotificationListener<ScrollStartNotification>(
                      onNotification: (notification) {
                        final request = _scrollingRequest;
                        if (notification.dragDetails != null &&
                            request != null) {
                          _interruptedScrollRequest = request;
                        }
                        return false;
                      },
                      child: ComicGrid(
                        comics: items,
                        controller: _scroll,
                        emptyContent: _pageErrors.isNotEmpty && items.isEmpty
                            ? ComicErrorView(
                                error: _pageErrors.values.first,
                                retry: () => _loadPage(
                                  _pendingPage,
                                  retryFailures: _buffer != null,
                                ),
                              )
                            : null,
                        footer: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_pageErrors.isNotEmpty &&
                                  items.isNotEmpty &&
                                  !_searchUpdateFailed)
                                MaterialBanner(
                                  content: Text(
                                    _pageErrors.entries
                                        .map((entry) {
                                          final source = sources
                                              .where(
                                                (source) =>
                                                    source.key == entry.key,
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
                              PaginationBar(
                                currentPage: _page,
                                pageSize: pageSize,
                                totalCount: null,
                                jumpMaxPage: _visitedPages.maximum,
                                hasMore: _hasMore && _pageErrors.isEmpty,
                                isLoading:
                                    _pageLoading ||
                                    _pending.isNotEmpty ||
                                    _searchUpdateFailed,
                                onPreviousPage: _page > 1
                                    ? () => _loadPage(_page - 1)
                                    : null,
                                onNextPage: _hasMore && _pageErrors.isEmpty
                                    ? () => _loadPage(_page + 1)
                                    : null,
                                onGoToPage: _visitedPages.maximum > 1
                                    ? (page) => _loadPage(page)
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
    return GlobalAudioPlayerWrapper(child: screen);
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
                  onTap: () => pushBottomDockRoute(
                    context,
                    builder: (_) => ComicSearchScreen(
                      initialSource: widget.sourceKey,
                      category: category,
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

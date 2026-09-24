import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../models/download_task.dart';
import '../models/playlist.dart';
import '../models/search_query.dart';
import '../models/work.dart';
import '../models/search_scope_session.dart';
import '../providers/auth_provider.dart';
import '../providers/collection_layout_provider.dart';
import '../providers/download_provider.dart';
import '../providers/my_reviews_provider.dart';
import '../providers/work_card_display_provider.dart';
import '../providers/works_provider.dart' show LayoutType;
import '../services/download_service.dart';
import '../services/history_database.dart';
import '../services/scoped_search_matcher.dart';
import '../utils/collection_grid_layout.dart';
import '../utils/l10n_extensions.dart';
import '../utils/scroll_optimization.dart';
import '../utils/string_utils.dart';
import '../utils/work_cover_prefetch.dart';
import '../widgets/enhanced_work_card.dart';
import '../widgets/history_work_card.dart';
import 'offline_work_detail_screen.dart';
import '../widgets/scrollable_appbar.dart';
import '../widgets/virtualized_sliver_collection.dart';
import '../screens/work_detail_screen.dart';
import '../widgets/app_bottom_dock_transition.dart';

class ScopedSearchResultScreen extends ConsumerStatefulWidget {
  const ScopedSearchResultScreen({
    super.key,
    required this.query,
    required this.session,
  });

  final SearchQuery query;
  final SearchScopeSession session;

  @override
  ConsumerState<ScopedSearchResultScreen> createState() =>
      _ScopedSearchResultScreenState();
}

class _ScopedSearchResultScreenState
    extends ConsumerState<ScopedSearchResultScreen> {
  final Map<int, ScopedSearchEntry> _allEntries = {};
  final Map<int, ScopedSearchEntry> _matchingEntries = {};
  final Map<int, ScopedSearchEntry> _unresolvedEntries = {};
  CancelToken? _cancelToken;
  int _generation = 0;
  bool _isSearching = false;
  bool _hasSourceFailure = false;
  final Map<int, Future<String?>> _downloadCoverPathFutures = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _runSearch();
    });
  }

  @override
  void dispose() {
    _cancelToken?.cancel('Search page closed');
    super.dispose();
  }

  void _restartForAccountChange() {
    _runSearch();
  }

  bool _isCurrent(int generation, CancelToken token) =>
      mounted && generation == _generation && !token.isCancelled;

  String _accountKey() {
    final auth = ref.read(authProvider);
    return '${auth.host ?? ''}|${auth.currentUser?.name ?? ''}|${auth.token ?? ''}';
  }

  Future<void> _runSearch({
    bool preserveResults = false,
    bool reloadSource = false,
  }) async {
    _cancelToken?.cancel('Search request superseded');
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    final generation = ++_generation;
    final accountKey = _accountKey();
    if (!preserveResults) {
      _allEntries.clear();
      _matchingEntries.clear();
      _unresolvedEntries.clear();
    }
    setState(() {
      _isSearching = true;
      _hasSourceFailure = false;
    });

    try {
      if (!preserveResults) {
        for (final entry in widget.session.entriesFor(
          widget.query,
          accountKey,
        )) {
          await _acceptEntry(entry, generation, cancelToken);
          if (!_isCurrent(generation, cancelToken)) return;
        }
      }

      if (preserveResults && !reloadSource) {
        final unresolved = _unresolvedEntries.values.toList(growable: false);
        for (final entry in unresolved) {
          await _acceptEntry(
            entry,
            generation,
            cancelToken,
            forceRefresh: true,
          );
          if (!_isCurrent(generation, cancelToken)) return;
        }
        return;
      }

      if (!reloadSource &&
          widget.session.isComplete(widget.query, accountKey)) {
        return;
      }
      switch (widget.query.scope) {
        case SearchScope.globalWorks:
          throw StateError('Global work searches use SearchResultScreen.');
        case SearchScope.onlineMarks:
          await _loadMarkedWorks(generation, cancelToken);
          break;
        case SearchScope.history:
          await _loadHistory(generation, cancelToken);
          break;
        case SearchScope.playlists:
          await _loadPlaylists(generation, cancelToken);
          break;
        case SearchScope.downloads:
          await _loadDownloads(generation, cancelToken);
          break;
      }
      if (_isCurrent(generation, cancelToken)) {
        widget.session.markComplete(widget.query, accountKey);
      }
    } catch (_) {
      if (_isCurrent(generation, cancelToken)) {
        setState(() => _hasSourceFailure = true);
      }
    } finally {
      if (_isCurrent(generation, cancelToken)) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _acceptEntry(
    ScopedSearchEntry entry,
    int generation,
    CancelToken cancelToken, {
    bool forceRefresh = false,
  }) async {
    if (!_isCurrent(generation, cancelToken)) return;
    final accountKey = _accountKey();
    var current = widget.session.add(widget.query, accountKey, entry);

    if (matchesSearchQuery(current.work, widget.query) == null &&
        workNeedsSearchMetadata(current.work, widget.query)) {
      Work detailedWork;
      Map<String, dynamic> detailJson;
      try {
        final api = ref.read(kikoeruApiServiceProvider);
        detailJson = await api.getWork(
          current.work.id,
          forceRefresh: forceRefresh,
          cancelToken: cancelToken,
        );
        if (!_isCurrent(generation, cancelToken)) return;
        detailedWork = _mergeWork(current.work, detailJson);
        if (!forceRefresh &&
            workNeedsSearchMetadata(detailedWork, widget.query)) {
          try {
            final refreshedJson = await api.getWork(
              current.work.id,
              forceRefresh: true,
              cancelToken: cancelToken,
            );
            if (!_isCurrent(generation, cancelToken)) return;
            detailJson = refreshedJson;
            detailedWork = _mergeWork(detailedWork, refreshedJson);
          } catch (_) {
            // Keep the first response; missing fields remain unresolved.
          }
        }
        current = current.copyWith(work: detailedWork);
      } catch (_) {
        if (_isCurrent(generation, cancelToken)) {
          _allEntries[current.work.id] = current;
          _unresolvedEntries[current.work.id] = current;
          widget.session.add(widget.query, accountKey, current);
          setState(() {});
        }
        return;
      }

      if (_isCurrent(generation, cancelToken)) {
        try {
          await _persistEnrichedWork(
            current,
            shouldUpdate: () => _isCurrent(generation, cancelToken),
          );
        } catch (_) {
          // A local write failure does not invalidate fetched search metadata.
        }
      }
    }

    if (!_isCurrent(generation, cancelToken)) return;
    current = widget.session.add(widget.query, accountKey, current);
    _allEntries[current.work.id] = current;
    final matches = matchesSearchQuery(current.work, widget.query);
    if (matches == true) {
      _matchingEntries[current.work.id] = current;
      _unresolvedEntries.remove(current.work.id);
    } else if (matches == false) {
      _matchingEntries.remove(current.work.id);
      _unresolvedEntries.remove(current.work.id);
    } else {
      _unresolvedEntries[current.work.id] = current;
    }
    setState(() {});
  }

  Work _mergeWork(Work current, Map<String, dynamic> detailJson) {
    final mergedJson = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(current.toJson())) as Map,
    );
    for (final field in detailJson.entries) {
      if (field.value != null) mergedJson[field.key] = field.value;
    }
    mergedJson['id'] = current.id;
    if (mergedJson['title'] == null ||
        (mergedJson['title'] as String).isEmpty) {
      mergedJson['title'] = current.title;
    }
    return Work.fromJson(mergedJson);
  }

  Future<void> _persistEnrichedWork(
    ScopedSearchEntry entry, {
    required bool Function() shouldUpdate,
  }) async {
    switch (widget.query.scope) {
      case SearchScope.history:
        await HistoryDatabase.instance.updateWorkMetadata(
          entry.work,
          shouldUpdate: shouldUpdate,
        );
        break;
      case SearchScope.downloads:
        await DownloadService.instance.updateWorkMetadata(
          entry.work.id,
          jsonDecode(jsonEncode(entry.work.toJson())) as Map<String, dynamic>,
          shouldUpdate: shouldUpdate,
        );
        break;
      case SearchScope.globalWorks:
      case SearchScope.onlineMarks:
      case SearchScope.playlists:
        break;
    }
  }

  Future<String?> _downloadCoverPath(int workId) =>
      _downloadCoverPathFutures.putIfAbsent(workId, () async {
        final metadata = await DownloadService.instance.getWorkMetadata(workId);
        final directory = await DownloadService.instance.getWorkDirectory(
          workId,
          metadata: metadata,
        );
        final path = DownloadService.instance.localCoverPathForMetadata(
          directory,
          metadata,
        );
        return path != null && await File(path).exists() ? path : null;
      });

  List<Work> _extractWorks(Map<String, dynamic> response) {
    final raw =
        response['works'] as List? ??
        response['reviews'] as List? ??
        response['data'] as List? ??
        const [];
    return raw
        .map((value) {
          final item = Map<String, dynamic>.from(value as Map);
          final workJson = item['work'] is Map
              ? Map<String, dynamic>.from(item['work'] as Map)
              : item;
          return Work.fromJson(workJson);
        })
        .toList(growable: false);
  }

  int _intValue(dynamic value, int fallback) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? fallback;

  bool _hasNextPage(
    Map<String, dynamic> response,
    int page,
    int requestedPageSize,
    int receivedCount,
  ) {
    final pagination = response['pagination'] as Map?;
    final totalCount = _intValue(pagination?['totalCount'], 0);
    final pageSize = _intValue(pagination?['pageSize'], requestedPageSize);
    if (totalCount > 0) return page * pageSize < totalCount;
    return receivedCount >= requestedPageSize;
  }

  Future<void> _loadMarkedWorks(int generation, CancelToken token) async {
    final api = ref.read(kikoeruApiServiceProvider);
    final filter = widget.query.progressFilter;
    const pageSize = 40;
    var page = 1;
    while (_isCurrent(generation, token)) {
      final response = await api.getMyReviews(
        page: page,
        pageSize: pageSize,
        filter: filter,
        cancelToken: token,
      );
      if (!_isCurrent(generation, token)) return;
      final works = _extractWorks(response);
      for (final work in works) {
        await _acceptEntry(ScopedSearchEntry(work: work), generation, token);
        if (!_isCurrent(generation, token)) return;
      }
      if (!_hasNextPage(response, page, pageSize, works.length)) return;
      page++;
    }
  }

  Future<void> _loadHistory(int generation, CancelToken token) async {
    final records = await HistoryDatabase.instance.getAllHistory();
    if (!_isCurrent(generation, token)) return;
    for (final record in records) {
      await _acceptEntry(
        ScopedSearchEntry(work: record.work, historyRecord: record),
        generation,
        token,
      );
      if (!_isCurrent(generation, token)) return;
    }
  }

  Future<void> _loadPlaylists(int generation, CancelToken token) async {
    final api = ref.read(kikoeruApiServiceProvider);
    const pageSize = 20;
    final playlists = <Playlist>[];
    var page = 1;
    while (_isCurrent(generation, token)) {
      final response = await api.getUserPlaylists(
        page: page,
        pageSize: pageSize,
        filterBy: 'all',
        cancelToken: token,
      );
      if (!_isCurrent(generation, token)) return;
      final values = response['playlists'] as List? ?? const [];
      playlists.addAll(
        values.map(
          (value) => Playlist.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      );
      if (!_hasNextPage(response, page, pageSize, values.length)) break;
      page++;
    }

    const worksPageSize = 20;
    for (final playlist in playlists) {
      if (!_isCurrent(generation, token)) return;
      var worksPage = 1;
      while (_isCurrent(generation, token)) {
        final response = await api.getPlaylistWorks(
          playlistId: playlist.id,
          page: worksPage,
          pageSize: worksPageSize,
          cancelToken: token,
        );
        if (!_isCurrent(generation, token)) return;
        final works = _extractWorks(response);
        for (final work in works) {
          final existing = _allEntries[work.id];
          final names = <String>{
            ...?existing?.playlistNames,
            playlist.name,
          }.toList(growable: false);
          final entry = ScopedSearchEntry(work: work, playlistNames: names);
          await _acceptEntry(entry, generation, token);
          if (!_isCurrent(generation, token)) return;
        }
        if (!_hasNextPage(response, worksPage, worksPageSize, works.length)) {
          break;
        }
        worksPage++;
      }
    }
  }

  Future<void> _loadDownloads(int generation, CancelToken token) async {
    final repository = ref.read(downloadServiceProvider);
    final downloadService = DownloadService.instance;
    final grouped = <int, List<DownloadTask>>{};
    for (final task in repository.tasks) {
      if (task.status == DownloadStatus.completed) {
        grouped.putIfAbsent(task.workId, () => []).add(task);
      }
    }

    for (final tasks in grouped.values) {
      if (!_isCurrent(generation, token)) return;
      final metadata = tasks.firstWhere(
        (task) => task.workMetadata != null,
        orElse: () => tasks.first,
      );
      final workMetadata =
          metadata.workMetadata ??
          await downloadService.getWorkMetadata(metadata.workId);
      if (!_isCurrent(generation, token)) return;
      final json = <String, dynamic>{
        ...?workMetadata,
        'id': metadata.workId,
        'title': workMetadata?['title'] ?? metadata.workTitle,
      };
      Work work;
      try {
        work = Work.fromJson(json);
      } catch (_) {
        work = Work(id: metadata.workId, title: metadata.workTitle);
      }
      await _acceptEntry(
        ScopedSearchEntry(work: work, downloadTasks: tasks),
        generation,
        token,
      );
    }
  }

  Future<void> _retry() =>
      _runSearch(preserveResults: true, reloadSource: _hasSourceFailure);

  LayoutType _currentLayout() {
    return switch (widget.query.scope) {
      SearchScope.onlineMarks => switch (ref
          .watch(myReviewsProvider)
          .layoutType) {
        MyReviewLayoutType.bigGrid => LayoutType.bigGrid,
        MyReviewLayoutType.smallGrid => LayoutType.smallGrid,
        MyReviewLayoutType.list => LayoutType.list,
      },
      SearchScope.history => ref.watch(
        collectionLayoutProvider(CollectionLayoutKey.history),
      ),
      SearchScope.playlists => ref.watch(
        collectionLayoutProvider(CollectionLayoutKey.playlists),
      ),
      SearchScope.downloads => ref.watch(
        collectionLayoutProvider(CollectionLayoutKey.downloads),
      ),
      SearchScope.globalWorks => LayoutType.bigGrid,
    };
  }

  String _scopeLabel(BuildContext context) {
    final s = S.of(context);
    return switch (widget.query.scope) {
      SearchScope.globalWorks => s.navHome,
      SearchScope.onlineMarks => _reviewScopeLabel(context),
      SearchScope.history => s.historyRecord,
      SearchScope.playlists => s.playlists,
      SearchScope.downloads => s.downloaded,
    };
  }

  String _reviewScopeLabel(BuildContext context) {
    final filter = widget.query.progressFilter;
    if (filter == null || filter.isEmpty) return S.of(context).onlineMarks;
    return MyReviewFilter.values
        .firstWhere(
          (value) => value.value == filter,
          orElse: () => MyReviewFilter.all,
        )
        .localizedLabel(context);
  }

  Widget _status(BuildContext context) {
    final s = S.of(context);
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    if (_isSearching) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                s.scopedSearchInProgress,
                style: TextStyle(color: color),
              ),
            ),
          ],
        ),
      );
    }
    if (_hasSourceFailure || _unresolvedEntries.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _hasSourceFailure
                    ? s.scopedSearchSourceFailure
                    : s.scopedSearchPartialFailure(_unresolvedEntries.length),
                style: TextStyle(color: color),
              ),
            ),
            TextButton(onPressed: _retry, child: Text(s.retry)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Text(
        s.scopedSearchResultCount(_matchingEntries.length),
        style: TextStyle(color: color),
      ),
    );
  }

  Widget _buildEntryCard(
    BuildContext context,
    ScopedSearchEntry entry,
    CollectionGridMetrics metrics,
    LayoutType layoutType,
  ) {
    final work = entry.work;
    final isList = layoutType == LayoutType.list;
    if (entry.historyRecord != null) {
      return HistoryWorkCard(
        key: ValueKey(work.id),
        record: entry.historyRecord!,
        layoutType: layoutType,
        onTap: () => pushWorkDetailRoute(
          context,
          builder: (_) => WorkDetailScreen(work: work),
        ),
      );
    }

    Widget card = EnhancedWorkCard(
      key: ValueKey(work.id),
      work: work,
      crossAxisCount: metrics.crossAxisCount,
      isListLayout: isList,
      onTap: () => _openEntry(context, entry),
    );
    if (widget.query.scope == SearchScope.downloads) {
      card = FutureBuilder<String?>(
        future: _downloadCoverPath(work.id),
        builder: (context, snapshot) => EnhancedWorkCard(
          key: ValueKey(work.id),
          work: work,
          crossAxisCount: metrics.crossAxisCount,
          isListLayout: isList,
          localCoverPath: snapshot.data,
          coverHeroTag: 'offline_work_cover_${work.id}',
          onTap: () => _openEntry(context, entry),
        ),
      );
      final size = entry.downloadTasks.fold<int>(
        0,
        (sum, task) => sum + (task.totalBytes ?? 0),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          card,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              S
                  .of(context)
                  .downloadedFilesAndSize(
                    entry.downloadTasks.length,
                    formatBytes(size),
                  ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      );
    }
    if (entry.playlistNames.isEmpty) return card;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        card,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            S
                .of(context)
                .scopedSearchPlaylistMembership(entry.playlistNames.join(', ')),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Future<void> _openEntry(BuildContext context, ScopedSearchEntry entry) async {
    if (widget.query.scope != SearchScope.downloads ||
        entry.downloadTasks.isEmpty) {
      pushWorkDetailRoute(
        context,
        builder: (_) => WorkDetailScreen(work: entry.work),
      );
      return;
    }

    final cachedTask = entry.downloadTasks.firstWhere(
      (task) => task.workMetadata != null,
      orElse: () => entry.downloadTasks.first,
    );
    final metadata =
        await DownloadService.instance.getWorkMetadata(entry.work.id) ??
        cachedTask.workMetadata;
    final directory = await DownloadService.instance.getWorkDirectory(
      entry.work.id,
      metadata: metadata,
    );
    final relativeCoverPath = metadata?['localCoverPath'] as String?;
    final localCoverPath = DownloadService.instance.localCoverPathForMetadata(
      directory,
      metadata,
    );
    if (!context.mounted) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OfflineWorkDetailScreen(
          work: entry.work,
          localCoverPath: localCoverPath,
          localCoverRelativePath: relativeCoverPath,
          localWorkDirPath: directory.path,
          fileTree: metadata?['children'] as List<dynamic>?,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      authProvider.select(
        (value) => (value.host, value.token, value.currentUser?.name),
      ),
      (previous, next) {
        if (previous != null && previous != next) _restartForAccountChange();
      },
    );
    final auth = ref.watch(
      authProvider.select(
        (value) => (
          value.host ?? '',
          value.token ?? '',
          value.currentUser?.name ?? '',
        ),
      ),
    );
    final layoutType = _currentLayout();
    final cardSize = ref.watch(
      workCardDisplayProvider.select((settings) => settings.cardSize),
    );
    final entries = _matchingEntries.values.toList(growable: false);

    return Scaffold(
      appBar: ScrollableAppBar(
        title: Text(
          S.of(context).searchInScope(_scopeLabel(context)),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        leading: IconButton(
          tooltip: S.of(context).back,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        automaticallyImplyLeading: false,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final metrics = resolveCollectionGridMetrics(
            context,
            layoutType: layoutType,
            cardSize: cardSize,
            availableWidth: constraints.maxWidth,
            availableHeight: constraints.maxHeight,
          );
          return WorkCoverPrefetchScope(
            sourceKey: (auth, widget.query.scope, widget.query.progressFilter),
            builder: (context, coverPrefetch) => VirtualizedSliverCollection(
              key: ValueKey(widget.query.scope),
              items: entries,
              itemId: (entry) => entry.work.id,
              layout: layoutType == LayoutType.list
                  ? VirtualizedCollectionLayout.list
                  : VirtualizedCollectionLayout.masonry,
              masonryCrossAxisCount: layoutType == LayoutType.list
                  ? null
                  : metrics.crossAxisCount,
              masonryMainAxisSpacing: metrics.spacing,
              masonryCrossAxisSpacing: metrics.spacing,
              padding: metrics.padding,
              physics: ScrollOptimization.physics,
              sliversBefore: [SliverToBoxAdapter(child: _status(context))],
              isInitialLoading: _isSearching && entries.isEmpty,
              isLoadingMore: _isSearching && entries.isNotEmpty,
              hasMore: _isSearching,
              onRetry: _retry,
              onPrefetch: (items) => coverPrefetch.prefetch(
                context,
                items.map((entry) => entry.work),
                host: auth.$1,
                token: auth.$2,
                crossAxisCount: metrics.crossAxisCount,
                isListCard: layoutType == LayoutType.list,
              ),
              itemBuilder: (context, entry, index) =>
                  _buildEntryCard(context, entry, metrics, layoutType),
              emptyBuilder: (context) {
                if (_isSearching ||
                    _hasSourceFailure ||
                    _unresolvedEntries.isNotEmpty) {
                  return const SizedBox.shrink();
                }
                return Center(
                  child: Text(
                    S.of(context).scopedSearchNoResults,
                    textAlign: TextAlign.center,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

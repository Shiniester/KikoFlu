import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/snackbar_util.dart';
import '../../providers/settings_provider.dart';
import '../../providers/works_provider.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/search_condition_chip.dart';
import '../../widgets/virtualized_sliver_collection.dart';
import '../video_browse_preferences.dart';
import '../missav_client.dart';
import '../video_models.dart';
import '../video_search_history.dart';
import 'video_collection_view.dart';
import 'video_details_screen.dart';
import 'video_screen.dart';

typedef VideoSearchLoader =
    Future<VideoSearchResults> Function(
      String query,
      List<VideoLink> filters,
      bool Function() isCurrent,
    );

typedef VideoSearchFilterLoader =
    Future<VideoCatalogPage> Function(
      VideoSearchFilterKind kind,
      String? pageUrl,
    );

typedef VideoSearchResultItemBuilder =
    Widget Function(
      BuildContext context,
      VideoItem video,
      LayoutType layoutType,
      VoidCallback? onTap,
    );

typedef VideoSearchAccessVerifier =
    Future<bool> Function(
      BuildContext context,
      MissavVerificationRequiredException error,
    );

class VideoSearchResults {
  VideoSearchResults.catalog(VideoCatalogPage page)
    : page = page,
      videos = page.videos;

  const VideoSearchResults.collection(this.videos) : page = null;

  final VideoCatalogPage? page;
  final List<VideoItem> videos;
}

class VideoSearchScreen extends ConsumerStatefulWidget {
  const VideoSearchScreen({
    super.key,
    required this.title,
    required this.search,
    required this.browsePage,
    this.onOpenVideo,
    this.canOpenVideo,
    this.itemBuilder,
    this.initialQuery,
    this.loadFilters,
    this.verifyAccess,
    this.accountClient,
  });

  final String title;
  final VideoSearchLoader search;
  final Future<VideoCatalogPage> Function(String url) browsePage;
  final void Function(BuildContext context, VideoItem video)? onOpenVideo;
  final bool Function(VideoItem video)? canOpenVideo;
  final VideoSearchResultItemBuilder? itemBuilder;
  final String? initialQuery;
  final VideoSearchFilterLoader? loadFilters;
  final VideoSearchAccessVerifier? verifyAccess;
  final MissavClient? accountClient;

  @override
  ConsumerState<VideoSearchScreen> createState() => _VideoSearchScreenState();
}

class _VideoSearchScreenState extends ConsumerState<VideoSearchScreen> {
  final TextEditingController _query = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<VideoLink> _filters = [];
  VideoSearchResults? _results;
  int _localPage = 1;
  String? _error;
  MissavVerificationRequiredException? _verificationError;
  bool _loading = false;
  bool _verifyingAccess = false;
  int _request = 0;
  Future<void> Function()? _retryAction;
  ({bool loggedIn, String? accountName})? _accountIdentity;

  @override
  void initState() {
    super.initState();
    _accountIdentity = _readAccountIdentity(widget.accountClient);
    widget.accountClient?.addListener(_onAccountClientChanged);
    final initialQuery = widget.initialQuery?.trim();
    if (initialQuery != null && initialQuery.isNotEmpty) {
      _query.text = initialQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_runSearch(initialQuery));
      });
    }
  }

  @override
  void didUpdateWidget(covariant VideoSearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountClient != widget.accountClient) {
      oldWidget.accountClient?.removeListener(_onAccountClientChanged);
      widget.accountClient?.addListener(_onAccountClientChanged);
      _accountIdentity = _readAccountIdentity(widget.accountClient);
      _invalidateAccountResults();
    }
  }

  ({bool loggedIn, String? accountName})? _readAccountIdentity(
    MissavClient? client,
  ) => client == null
      ? null
      : (loggedIn: client.isLoggedIn, accountName: client.accountName);

  void _onAccountClientChanged() {
    final identity = _readAccountIdentity(widget.accountClient);
    if (identity == _accountIdentity) return;
    _accountIdentity = identity;
    _invalidateAccountResults();
  }

  void _invalidateAccountResults() {
    _request++;
    _retryAction = null;
    if (!mounted) return;
    setState(() {
      _results = null;
      _localPage = 1;
      _error = null;
      _verificationError = null;
      _loading = false;
      _verifyingAccess = false;
    });
  }

  @override
  void dispose() {
    _request++;
    widget.accountClient?.removeListener(_onAccountClientChanged);
    _query.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String value, {List<VideoLink>? filters}) async {
    final query = value.trim();
    final filtersSnapshot = List<VideoLink>.unmodifiable(filters ?? _filters);
    if (query.isEmpty && filtersSnapshot.isEmpty) {
      _request++;
      _retryAction = null;
      setState(() {
        _results = null;
        _localPage = 1;
        _error = null;
        _verificationError = null;
        _loading = false;
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      return;
    }
    _retryAction = () => _runSearch(query, filters: filtersSnapshot);
    final request = ++_request;
    if (query.isNotEmpty) {
      unawaited(ref.read(videoSearchHistoryProvider.notifier).add(query));
    }
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
      _results = null;
      _localPage = 1;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    try {
      final results = await widget.search(
        query,
        filtersSnapshot,
        () => mounted && request == _request,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error.toString();
        _verificationError = error is MissavVerificationRequiredException
            ? error
            : null;
        _loading = false;
      });
    }
  }

  void _clearInput() {
    _request++;
    _retryAction = null;
    _query.clear();
    _filters.clear();
    setState(() {
      _results = null;
      _localPage = 1;
      _error = null;
      _verificationError = null;
      _loading = false;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  String _filterTitle(VideoSearchFilterKind kind, S s) => switch (kind) {
    VideoSearchFilterKind.genre => s.videoFilterGenre,
    VideoSearchFilterKind.actor => s.videoFilterActor,
    VideoSearchFilterKind.studio => s.videoFilterStudio,
    VideoSearchFilterKind.series => s.videoFilterSeries,
  };

  IconData _filterIcon(VideoSearchFilterKind kind) => switch (kind) {
    VideoSearchFilterKind.genre => Icons.category_outlined,
    VideoSearchFilterKind.actor => Icons.person_outline,
    VideoSearchFilterKind.studio => Icons.business_outlined,
    VideoSearchFilterKind.series => Icons.video_collection_outlined,
  };

  Future<void> _openFilterPicker(VideoSearchFilterKind kind) async {
    final loadFilters = widget.loadFilters;
    if (loadFilters == null) return;
    final selected = await showResponsiveBottomSheet<VideoLink>(
      context: context,
      builder: (_) => _VideoSearchFilterPicker(
        title: _filterTitle(kind, S.of(context)),
        kind: kind,
        loadFilters: loadFilters,
        verifyAccess: widget.verifyAccess,
      ),
    );
    if (!mounted ||
        selected == null ||
        _filters.any((filter) => filter.url == selected.url)) {
      return;
    }
    setState(() => _filters.add(selected));
    unawaited(_runSearch(_query.text));
  }

  void _removeFilter(VideoLink filter) {
    setState(() => _filters.removeWhere((item) => item.url == filter.url));
    unawaited(_runSearch(_query.text));
  }

  Widget _filterControls(S s) {
    final loadFilters = widget.loadFilters;
    if (loadFilters == null) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final kind in VideoSearchFilterKind.values)
                OutlinedButton.icon(
                  key: ValueKey('video-filter-${kind.name}'),
                  onPressed: () => _openFilterPicker(kind),
                  icon: Icon(_filterIcon(kind), size: 18),
                  label: Text(
                    _filterTitle(kind, s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
          if (_filters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Wrap(
                    spacing: 8,
                    runSpacing: 0,
                    children: [
                      for (final filter in _filters)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth,
                          ),
                          child: Tooltip(
                            message: filter.label,
                            child: Semantics(
                              label: filter.label,
                              child: SearchConditionChip(
                                key: ValueKey(
                                  'selected-video-filter-${filter.url}',
                                ),
                                label: filter.label,
                                maxLines: 1,
                                avatar: Icon(
                                  _iconForLink(filter),
                                  size: 16,
                                  color: colorScheme.onSecondaryContainer,
                                ),
                                backgroundColor: colorScheme.secondaryContainer,
                                onDeleted: () => _removeFilter(filter),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  IconData _iconForLink(VideoLink filter) {
    return switch (filter.kind) {
      VideoLinkKind.actor => Icons.person_outline,
      VideoLinkKind.studio => Icons.business_outlined,
      VideoLinkKind.category => Icons.category_outlined,
      VideoLinkKind.tag => Icons.category_outlined,
      VideoLinkKind.collection => Icons.video_collection_outlined,
      _ => Icons.label_outline,
    };
  }

  Future<void> _goToPage(int pageNumber) async {
    final page = _results?.page;
    if (page == null) return;
    await _browsePage(page.pageUrl(pageNumber));
  }

  Future<void> _browsePage(String url) async {
    if (_results?.page == null) return;
    _retryAction = () => _browsePage(url);
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
    });
    try {
      final nextPage = await widget.browsePage(url);
      if (!mounted || request != _request) return;
      setState(() {
        _results = VideoSearchResults.catalog(nextPage);
        _localPage = 1;
        _loading = false;
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error.toString();
        _verificationError = error is MissavVerificationRequiredException
            ? error
            : null;
        _loading = false;
      });
    }
  }

  Future<void> _verifyAndRetry() async {
    final verification = _verificationError;
    final verifyAccess = widget.verifyAccess;
    if (verification == null || verifyAccess == null || _verifyingAccess) {
      return;
    }
    final request = _request;
    setState(() => _verifyingAccess = true);
    var verified = false;
    try {
      verified = await verifyAccess(context, verification);
    } catch (_) {
      verified = false;
    } finally {
      if (mounted) setState(() => _verifyingAccess = false);
    }
    if (!mounted ||
        !verified ||
        request != _request ||
        verification != _verificationError) {
      return;
    }
    final retry = _retryAction;
    if (retry != null) {
      await retry();
    } else {
      await _runSearch(_query.text);
    }
  }

  void _openVideo(VideoItem video) {
    final canOpen = widget.canOpenVideo?.call(video) ?? true;
    if (!canOpen) return;
    final callback = widget.onOpenVideo;
    if (callback != null) {
      callback(context, video);
    } else {
      pushWorkDetailRoute(
        context,
        builder: (_) => VideoDetailsScreen(video: video),
      );
    }
  }

  Widget _history(VideoSearchHistoryState history) {
    final s = S.of(context);
    if (history.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (history.queries.isEmpty) {
      return Center(child: Text(s.searchHistory));
    }
    return ListView.separated(
      key: const PageStorageKey<String>('video-search-history'),
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: history.queries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final query = history.queries[index];
        return ListTile(
          leading: const Icon(Icons.history),
          title: Text(query, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () {
            _query.text = query;
            unawaited(_runSearch(query));
          },
          trailing: IconButton(
            tooltip: S.of(context).delete,
            icon: const Icon(Icons.close),
            onPressed: () =>
                ref.read(videoSearchHistoryProvider.notifier).remove(query),
          ),
        );
      },
    );
  }

  Widget _resultItem(BuildContext context, VideoItem video, LayoutType layout) {
    final canOpen = widget.canOpenVideo?.call(video) ?? true;
    final onTap = canOpen ? () => _openVideo(video) : null;
    final customBuilder = widget.itemBuilder;
    if (customBuilder != null) {
      return customBuilder(context, video, layout, onTap);
    }
    return VideoCard(
      video: video,
      layoutType: layout,
      onTap: onTap,
      onOpenLink: (link) => unawaited(
        pushBottomDockRoute(
          context,
          builder: (_) => VideoScreen.catalog(url: link.url),
        ),
      ),
    );
  }

  Widget _resultsView(VideoSearchResults results, LayoutType layout) {
    final s = S.of(context);
    final page = results.page;
    final pageSize = ref.watch(pageSizeProvider);
    final hasSourcePagination =
        page != null &&
        (page.previousUrl != null ||
            page.nextUrl != null ||
            page.jumpMaxPage != null);
    final localPageCount = ((results.videos.length + pageSize - 1) ~/ pageSize)
        .clamp(1, 1 << 30)
        .toInt();
    final hasLocalPagination =
        !hasSourcePagination && results.videos.length > pageSize;
    final localPage = _localPage.clamp(1, localPageCount).toInt();
    final videos = hasLocalPagination
        ? results.videos
              .skip((localPage - 1) * pageSize)
              .take(pageSize)
              .toList(growable: false)
        : results.videos;
    final pagination = hasSourcePagination
        ? VirtualizedPagination(
            currentPage: page.currentPage,
            pageSize: page.videos.length.clamp(1, 1000).toInt(),
            totalCount: null,
            jumpMaxPage: page.jumpMaxPage,
            hasMore: page.nextUrl != null,
            isLoading: _loading,
            onPreviousPage: page.previousUrl == null
                ? null
                : () => _browsePage(page.previousUrl!),
            onNextPage: page.nextUrl == null
                ? null
                : () => _browsePage(page.nextUrl!),
            onGoToPage: page.jumpMaxPage == null ? null : _goToPage,
            showWhenEmpty: true,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          )
        : VirtualizedPagination(
            currentPage: localPage,
            pageSize: pageSize,
            totalCount: results.videos.length,
            hasMore: localPage < localPageCount,
            isLoading: _loading,
            onPreviousPage: hasLocalPagination && localPage > 1
                ? () => setState(() => _localPage = localPage - 1)
                : null,
            onNextPage: hasLocalPagination && localPage < localPageCount
                ? () => setState(() => _localPage = localPage + 1)
                : null,
            onGoToPage: hasLocalPagination
                ? (targetPage) => setState(() => _localPage = targetPage)
                : null,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          );
    return Column(
      children: [
        Expanded(
          child: VideoCollectionView(
            items: videos,
            layoutType: layout,
            itemId: (video) => video.id,
            controller: _scrollController,
            pageStorageKey: PageStorageKey<String>(
              'video-search-results-${_query.text}',
            ),
            emptyBuilder: (_) => Center(child: Text(s.noResults)),
            itemBuilder: (context, video, _) =>
                _resultItem(context, video, layout),
            pagination: pagination,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final history = ref.watch(videoSearchHistoryProvider);
    final layout = ref.watch(videoBrowseLayoutProvider);
    final searchHistory = ref.read(videoSearchHistoryProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (history.queries.isNotEmpty)
            IconButton(
              tooltip: s.clearSearchHistory,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(s.clearSearchHistory),
                    content: Text(s.clearSearchHistoryConfirm),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(s.cancel),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: Text(s.confirm),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await searchHistory.clear();
                  if (context.mounted) {
                    SnackBarUtil.showFromSnackBar(
                      context,
                      SnackBar(content: Text(s.searchHistoryCleared)),
                    );
                  }
                }
              },
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .6,
              ),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: TextField(
                        key: const ValueKey('video-search-input'),
                        controller: _query,
                        autofocus: widget.initialQuery == null,
                        textInputAction: TextInputAction.search,
                        onSubmitted: _runSearch,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: s.videoSearchHint,
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: IconButton(
                            tooltip: s.clear,
                            onPressed: _query.text.isEmpty && _filters.isEmpty
                                ? null
                                : _clearInput,
                            icon: const Icon(Icons.clear),
                          ),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    _filterControls(s),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _verificationError == null
                                    ? s.videoLoadFailed
                                    : s.videoVerificationRequired,
                              ),
                            ),
                            if (_verificationError != null &&
                                widget.verifyAccess != null)
                              TextButton.icon(
                                onPressed: _verifyingAccess
                                    ? null
                                    : _verifyAndRetry,
                                icon: const Icon(Icons.verified_user_outlined),
                                label: Text(s.videoVerifyAccess),
                              ),
                            TextButton(
                              onPressed: _loading
                                  ? null
                                  : () =>
                                        _retryAction?.call() ??
                                        _runSearch(_query.text),
                              child: Text(s.retry),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _results != null
                  ? _resultsView(_results!, layout)
                  : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _history(history),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoSearchFilterPicker extends StatefulWidget {
  const _VideoSearchFilterPicker({
    required this.title,
    required this.kind,
    required this.loadFilters,
    this.verifyAccess,
  });

  final String title;
  final VideoSearchFilterKind kind;
  final VideoSearchFilterLoader loadFilters;
  final VideoSearchAccessVerifier? verifyAccess;

  @override
  State<_VideoSearchFilterPicker> createState() =>
      _VideoSearchFilterPickerState();
}

class _VideoSearchFilterPickerState extends State<_VideoSearchFilterPicker> {
  VideoCatalogPage? _page;
  String? _requestedUrl;
  String? _error;
  MissavVerificationRequiredException? _verificationError;
  bool _loading = true;
  bool _verifyingAccess = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(null));
    });
  }

  Future<void> _load(String? pageUrl) async {
    _requestedUrl = pageUrl;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
    });
    try {
      final page = await widget.loadFilters(widget.kind, pageUrl);
      if (!mounted || request != _request) return;
      setState(() {
        _page = page;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error.toString();
        _verificationError = error is MissavVerificationRequiredException
            ? error
            : null;
        _loading = false;
      });
    }
  }

  Future<void> _verifyAndRetry() async {
    final verification = _verificationError;
    final verifyAccess = widget.verifyAccess;
    if (verification == null || verifyAccess == null || _verifyingAccess) {
      return;
    }
    final request = _request;
    setState(() => _verifyingAccess = true);
    var verified = false;
    try {
      verified = await verifyAccess(context, verification);
    } catch (_) {
      verified = false;
    } finally {
      if (mounted) setState(() => _verifyingAccess = false);
    }
    if (!mounted ||
        !verified ||
        request != _request ||
        verification != _verificationError) {
      return;
    }
    await _load(_requestedUrl);
  }

  Widget _errorView(S s) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _verificationError == null
                ? s.videoLoadFailed
                : s.videoVerificationRequired,
            textAlign: TextAlign.center,
          ),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              if (_verificationError != null && widget.verifyAccess != null)
                TextButton.icon(
                  onPressed: _verifyingAccess ? null : _verifyAndRetry,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: Text(s.videoVerifyAccess),
                ),
              TextButton(
                onPressed: _loading ? null : () => _load(_requestedUrl),
                child: Text(s.retry),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final page = _page;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BottomSheetHeader(title: widget.title),
        Flexible(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _errorView(s)
              : page == null || page.links.isEmpty
              ? Center(child: Text(s.noResults))
              : ListView.separated(
                  itemCount: page.links.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final link = page.links[index];
                    return ListTile(
                      key: ValueKey('video-filter-option-${link.url}'),
                      title: Tooltip(
                        message: link.label,
                        child: Text(
                          link.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).pop(link),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              if (page?.previousUrl != null)
                TextButton.icon(
                  onPressed: _loading ? null : () => _load(page!.previousUrl),
                  icon: const Icon(Icons.chevron_left),
                  label: Text(s.previousPage),
                ),
              if (page?.nextUrl != null)
                TextButton.icon(
                  onPressed: _loading ? null : () => _load(page!.nextUrl),
                  icon: const Icon(Icons.chevron_right),
                  label: Text(s.nextPage),
                ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(s.cancel),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

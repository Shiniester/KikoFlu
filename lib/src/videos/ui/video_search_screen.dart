import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../providers/settings_provider.dart';
import '../../providers/works_provider.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/virtualized_sliver_collection.dart';
import '../video_browse_preferences.dart';
import '../missav_client.dart';
import '../video_models.dart';
import '../video_search_history.dart';
import 'video_collection_view.dart';
import 'video_details_screen.dart';

typedef VideoSearchLoader =
    Future<VideoSearchResults> Function(
      String query,
      bool Function() isCurrent,
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
  final VideoSearchAccessVerifier? verifyAccess;
  final MissavClient? accountClient;

  @override
  ConsumerState<VideoSearchScreen> createState() => _VideoSearchScreenState();
}

class _VideoSearchScreenState extends ConsumerState<VideoSearchScreen> {
  final TextEditingController _query = TextEditingController();
  final ScrollController _scrollController = ScrollController();
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

  Future<void> _runSearch(String value) async {
    final query = value.trim();
    if (query.isEmpty) return;
    _retryAction = () => _runSearch(query);
    final request = ++_request;
    unawaited(ref.read(videoSearchHistoryProvider.notifier).add(query));
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
    setState(() {
      _results = null;
      _localPage = 1;
      _error = null;
      _verificationError = null;
      _loading = false;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
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
    return VideoCard(video: video, layoutType: layout, onTap: onTap);
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(s.searchHistoryCleared)),
                    );
                  }
                }
              },
            ),
        ],
      ),
      body: Column(
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
                  onPressed: _query.text.isEmpty ? null : _clearInput,
                  icon: const Icon(Icons.clear),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
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
                  if (_verificationError != null && widget.verifyAccess != null)
                    TextButton.icon(
                      onPressed: _verifyingAccess ? null : _verifyAndRetry,
                      icon: const Icon(Icons.verified_user_outlined),
                      label: Text(s.videoVerifyAccess),
                    ),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => _retryAction?.call() ?? _runSearch(_query.text),
                    child: Text(s.retry),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _results != null
                ? _resultsView(_results!, layout)
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : _history(history),
          ),
        ],
      ),
    );
  }
}

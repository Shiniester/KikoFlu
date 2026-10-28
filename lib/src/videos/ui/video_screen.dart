import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/snackbar_util.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/library_page_scaffold.dart';
import '../../widgets/virtualized_sliver_collection.dart';
import '../../providers/works_provider.dart';
import '../missav_client.dart';
import '../missav_verification.dart';
import '../video_downloads.dart';
import '../video_library.dart';
import '../video_models.dart';
import '../video_providers.dart';
import '../video_browse_preferences.dart';
import 'video_account_screen.dart';
import 'video_collection_view.dart';
import 'video_details_screen.dart';
import 'video_downloads_screen.dart';
import 'video_search_screen.dart';

typedef _VideoPageCacheKey = ({
  String url,
  String locale,
  int sessionGeneration,
  bool isLoggedIn,
  String? accountName,
});

class _VideoRecommendationSnapshot {
  const _VideoRecommendationSnapshot({
    required this.videos,
    required this.hasMore,
  });

  final List<VideoItem> videos;
  final bool hasMore;
}

class _VideoRecommendationState {
  int currentPage = 1;
  bool hasRequestedSource = false;
  bool exhausted = false;
  String? cursor;
  List<VideoItem> bufferedVideos = const [];
  final Map<int, _VideoRecommendationSnapshot> pages = {};
}

class VideoScreen extends ConsumerStatefulWidget {
  const VideoScreen({super.key, this.active = true}) : initialUrl = null;

  const VideoScreen.catalog({
    super.key,
    required String url,
    this.active = true,
  }) : initialUrl = url;

  final bool active;
  final String? initialUrl;

  @override
  ConsumerState<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends ConsumerState<VideoScreen> {
  static const _approvedCatalogSlugs = {
    'new',
    'release',
    'chinese-subtitle',
    'weekly-hot',
    'uncensored-leak',
  };
  // Keep path normalization aligned with MissavClient's locale handling.
  static const _catalogSourceLanguages = {
    'cn',
    'zh',
    'ja',
    'en',
    'ko',
    'ms',
    'th',
    'de',
    'fr',
    'vi',
    'id',
    'fil',
    'pt',
  };
  static const _maxCachedPages = 4;

  late final MissavClient _client;
  late final VideoLibrary _library;
  late final VideoDownloads _downloads;
  VideoCatalogPage? _page;
  bool _loading = false;
  bool _verifyingAccess = false;
  String? _error;
  MissavVerificationRequiredException? _verificationError;
  Future<void> Function()? _retryRequest;
  int _request = 0;
  bool _dependenciesReady = false;
  bool _accountWasLoggedIn = false;
  String? _accountName;
  String? _loadingUrl;
  String? _pendingAccountReloadUrl;
  ModalRoute<dynamic>? _route;
  final ScrollController _scrollController = ScrollController();
  final ScrollController _stagingScrollController = ScrollController();
  final Map<_VideoPageCacheKey, VideoCatalogPage> _pageCache = {};
  _VideoRecommendationState? _recommendationState;
  final Set<String> _stagingVisibleVideoIds = {};
  final Set<VideoCoverImageKey> _stagingReadyCovers = {};
  final Set<VideoCoverImageKey> _stagingFailedCovers = {};
  final Set<VideoCoverImageKey> _publishedFailedCovers = {};
  CancelToken? _activeBrowseCancelToken;
  VideoCatalogPage? _stagingPage;
  Completer<void>? _stagingReadyCompleter;
  int? _stagingRequest;
  int? _stagingCacheWidth;
  int _stagingRevision = 0;
  bool _stagingMetadataReady = false;
  bool _stagingVisibilityReported = false;
  String? _publishedFailedPageUrl;
  String? _activeCollectionKey;
  String? _sourceLocaleTag;
  int _localPage = 1;
  int _observedSessionGeneration = 0;
  int? _activeRecommendationPageSize;
  int? _recommendationStatePageSize;
  bool _recommendationsActive = false;
  bool _pendingRecommendationReload = false;

  @override
  void initState() {
    super.initState();
    _client = ref.read(videoClientProvider);
    _library = ref.read(videoLibraryProvider);
    _downloads = ref.read(videoDownloadsProvider);
    _accountWasLoggedIn = _client.isLoggedIn;
    _accountName = _client.accountName;
    _observedSessionGeneration = _client.sessionGeneration;
    _client.addListener(_onClientChanged);
    if (widget.active) _scheduleInitialize();
  }

  void _scheduleInitialize() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) unawaited(_initialize());
    });
  }

  void _scheduleLoadUrl(String url, {String? collectionKey}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) {
        unawaited(
          _loadUrl(url, collectionKey: collectionKey, preserveCollection: true),
        );
      }
    });
  }

  void _scheduleRecommendationLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _openRecommendations();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSourceLocale();
    final route = ModalRoute.of(context);
    if (route == _route) return;
    _route?.secondaryAnimation?.removeStatusListener(_onRouteStatusChanged);
    _route = route;
    _route?.secondaryAnimation?.addStatusListener(_onRouteStatusChanged);
  }

  void _syncSourceLocale() {
    final languageTag = Localizations.localeOf(context).toLanguageTag();
    if (_sourceLocaleTag == languageTag) return;
    _sourceLocaleTag = languageTag;
    _client.setLocale(languageTag);
    if (!_dependenciesReady) return;
    final recommendationsActive = _recommendationsActive;
    final url =
        _loadingUrl ??
        _page?.url ??
        _pendingAccountReloadUrl ??
        widget.initialUrl ??
        _defaultCatalogUrl;
    _request++;
    final activeBrowseCancelToken = _activeBrowseCancelToken;
    if (activeBrowseCancelToken != null &&
        !activeBrowseCancelToken.isCancelled) {
      activeBrowseCancelToken.cancel('Video source language changed.');
    }
    _page = null;
    _clearRecommendationStates();
    _loadingUrl = null;
    _publishedFailedPageUrl = null;
    _publishedFailedCovers.clear();
    _discardStaging();
    _loading = false;
    _error = null;
    _verificationError = null;
    if (!widget.active) {
      if (recommendationsActive) {
        _pendingRecommendationReload = true;
      } else {
        _pendingAccountReloadUrl = url;
      }
      return;
    }
    if (ModalRoute.of(context)?.isCurrent == false) {
      if (recommendationsActive) {
        _pendingRecommendationReload = true;
      } else {
        _pendingAccountReloadUrl = url;
      }
      return;
    }
    if (recommendationsActive) {
      _pendingRecommendationReload = false;
      _scheduleRecommendationLoad();
    } else {
      _scheduleLoadUrl(url, collectionKey: _activeCollectionKey);
    }
  }

  @override
  void didUpdateWidget(VideoScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active && _page == null) {
      if (_recommendationsActive) {
        if (_pendingRecommendationReload) {
          _pendingRecommendationReload = false;
          _scheduleRecommendationLoad();
        }
        return;
      }
      if (_pendingRecommendationReload) {
        _pendingRecommendationReload = false;
        _scheduleRecommendationLoad();
        return;
      }
      final url = _pendingAccountReloadUrl;
      _pendingAccountReloadUrl = null;
      if (_dependenciesReady && url != null) {
        _scheduleLoadUrl(url, collectionKey: _activeCollectionKey);
      } else {
        _scheduleInitialize();
      }
    }
    if (widget.active && oldWidget.initialUrl != widget.initialUrl) {
      _scheduleInitialize();
    }
  }

  Future<void> _initialize() async {
    _retryRequest = () => _initialize();
    try {
      await Future.wait([
        _client.initialize(),
        _library.initialize(),
        _downloads.initialize(),
      ]);
      if (!mounted) return;
      _dependenciesReady = true;
      final url =
          _pendingAccountReloadUrl ?? widget.initialUrl ?? _defaultCatalogUrl;
      _pendingAccountReloadUrl = null;
      await _loadUrl(url);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _recordError(error);
      });
    }
  }

  void _onClientChanged() {
    final isLoggedIn = _client.isLoggedIn;
    final accountName = _client.accountName;
    final sessionGeneration = _client.sessionGeneration;
    final sessionChanged = sessionGeneration != _observedSessionGeneration;
    final accountChanged =
        isLoggedIn != _accountWasLoggedIn || accountName != _accountName;
    if (!accountChanged && !sessionChanged) {
      return;
    }
    final recommendationsActive = _recommendationsActive;
    _accountWasLoggedIn = isLoggedIn;
    _accountName = accountName;
    _observedSessionGeneration = sessionGeneration;
    if (!mounted) return;

    final url =
        _loadingUrl ??
        _pendingAccountReloadUrl ??
        _page?.url ??
        widget.initialUrl ??
        _defaultCatalogUrl;
    _clearRecommendationStates();
    if (_activeCollectionKey == null &&
        _collectionKeyForUrl(url) == null &&
        !sessionChanged &&
        !recommendationsActive) {
      setState(() {});
      return;
    }
    final covered = ModalRoute.of(context)?.isCurrent == false;
    if (_loading && !covered && !sessionChanged && !recommendationsActive) {
      return;
    }
    _request++;
    _loadingUrl = null;
    final activeBrowseCancelToken = _activeBrowseCancelToken;
    if (activeBrowseCancelToken != null &&
        !activeBrowseCancelToken.isCancelled) {
      activeBrowseCancelToken.cancel('Video source account changed.');
    }
    setState(() {
      _page = null;
      _publishedFailedPageUrl = null;
      _publishedFailedCovers.clear();
      _discardStaging();
      _error = null;
      _verificationError = null;
      _retryRequest = null;
      _loading = false;
    });
    if (!_dependenciesReady) return;
    if (recommendationsActive) {
      if (widget.active && !covered) {
        _pendingRecommendationReload = false;
        unawaited(
          _loadRecommendationPage(pageSize: ref.read(pageSizeProvider)),
        );
      } else {
        _pendingRecommendationReload = true;
      }
      return;
    }
    if (widget.active && !covered) {
      unawaited(_loadUrl(url));
    } else {
      _pendingAccountReloadUrl = url;
    }
  }

  void _onRouteStatusChanged(AnimationStatus _) {
    if (!mounted || _verifyingAccess) return;
    if (_pendingRecommendationReload &&
        _route?.isCurrent == true &&
        widget.active) {
      _pendingRecommendationReload = false;
      _openRecommendations();
      return;
    }
    final url = _pendingAccountReloadUrl;
    if (url == null || _route?.isCurrent != true || !widget.active) return;
    _pendingAccountReloadUrl = null;
    unawaited(_loadUrl(url));
  }

  _VideoPageCacheKey _pageCacheKey(String url) => (
    url: url,
    locale: _sourceLocaleTag ?? Localizations.localeOf(context).toLanguageTag(),
    sessionGeneration: _client.sessionGeneration,
    isLoggedIn: _client.isLoggedIn,
    accountName: _client.accountName,
  );

  VideoCatalogPage? _takeCachedPage(String url) {
    final key = _pageCacheKey(url);
    final page = _pageCache.remove(key);
    if (page != null) _pageCache[key] = page;
    return page;
  }

  void _rememberPage(String url, VideoCatalogPage page) {
    final key = _pageCacheKey(url);
    _pageCache.remove(key);
    _pageCache[key] = page;
    if (_pageCache.length > _maxCachedPages) {
      _pageCache.remove(_pageCache.keys.first);
    }
  }

  void _clearRecommendationStates() {
    _recommendationState = null;
    _activeRecommendationPageSize = null;
    _recommendationStatePageSize = null;
  }

  List<VideoItem> _stagingVideos(VideoCatalogPage page) {
    if (_collectionLinksForContent(page).isNotEmpty) return const [];
    final pageSize = ref.read(pageSizeProvider);
    final hasSourcePagination =
        page.previousUrl != null ||
        page.nextUrl != null ||
        page.jumpMaxPage != null;
    if (!hasSourcePagination && page.videos.length > pageSize) {
      return page.videos.take(pageSize).toList(growable: false);
    }
    return page.videos;
  }

  void _resetStaging(
    int request,
    VideoCatalogPage page, {
    required bool metadataReady,
    Set<VideoCoverImageKey> failedCovers = const {},
  }) {
    final previous = _stagingReadyCompleter;
    if (previous != null && !previous.isCompleted) previous.complete();
    if (_stagingScrollController.hasClients) {
      _stagingScrollController.jumpTo(0);
    }
    _stagingRequest = request;
    _stagingRevision++;
    _stagingPage = page;
    _stagingMetadataReady = metadataReady;
    _stagingCacheWidth = null;
    _stagingVisibleVideoIds.clear();
    _stagingReadyCovers.clear();
    _stagingFailedCovers
      ..clear()
      ..addAll(failedCovers);
    _stagingVisibilityReported = _stagingVideos(page).isEmpty;
    _stagingReadyCompleter = Completer<void>();
  }

  void _setStagingPage(
    int request,
    VideoCatalogPage page, {
    required bool metadataReady,
  }) {
    if (!mounted || request != _request) return;
    setState(() {
      _resetStaging(request, page, metadataReady: metadataReady);
    });
    _checkStagingReady();
  }

  void _discardStaging() {
    final previous = _stagingReadyCompleter;
    if (previous != null && !previous.isCompleted) previous.complete();
    _stagingRequest = null;
    _stagingPage = null;
    _stagingMetadataReady = false;
    _stagingCacheWidth = null;
    _stagingVisibleVideoIds.clear();
    _stagingReadyCovers.clear();
    _stagingFailedCovers.clear();
    _stagingVisibilityReported = false;
    _stagingReadyCompleter = null;
  }

  void _updateStagingPage(
    int request,
    VideoCatalogPage page, {
    required bool metadataReady,
  }) {
    if (!mounted || request != _request || _stagingRequest != request) return;
    final hasVideos = _stagingVideos(page).isNotEmpty;
    setState(() {
      _stagingRevision++;
      _stagingPage = page;
      _stagingMetadataReady = metadataReady;
      _stagingVisibleVideoIds.clear();
      _stagingVisibilityReported = !hasVideos;
    });
    _checkStagingReady();
  }

  void _onStagingCacheWidthChanged(int request, int? cacheWidth) {
    if (request != _stagingRequest || _stagingCacheWidth == cacheWidth) return;
    _stagingCacheWidth = cacheWidth;
    _stagingVisibleVideoIds.clear();
    _stagingReadyCovers.clear();
    _stagingVisibilityReported = false;
  }

  void _onStagingVisibleItemsChanged(
    int request,
    List<VideoItem> items,
    int? cacheWidth,
  ) {
    if (request != _stagingRequest) return;
    _onStagingCacheWidthChanged(request, cacheWidth);
    _stagingVisibleVideoIds
      ..clear()
      ..addAll(items.map((item) => item.id));
    _stagingVisibilityReported = true;
    _checkStagingReady();
  }

  void _onStagingCoverTerminal(
    int request,
    VideoCoverImageKey key, {
    required bool failed,
  }) {
    if (request != _stagingRequest) return;
    _stagingReadyCovers.add(key);
    if (failed) {
      _stagingFailedCovers.add(key);
    } else {
      _stagingFailedCovers.remove(key);
    }
    _checkStagingReady();
  }

  void _onPublishedCoverTerminal(
    String pageUrl,
    VideoCoverImageKey key, {
    required bool failed,
  }) {
    if (_publishedFailedPageUrl != pageUrl) return;
    if (failed) {
      _publishedFailedCovers.add(key);
    } else {
      _publishedFailedCovers.remove(key);
    }
    if (_stagingPage?.url == pageUrl) {
      _stagingReadyCovers.add(key);
      if (failed) {
        _stagingFailedCovers.add(key);
      } else {
        _stagingFailedCovers.remove(key);
      }
      _checkStagingReady();
    }
  }

  void _onPublishedCoverRetry(String pageUrl, VideoCoverImageKey key) {
    if (_publishedFailedPageUrl == pageUrl) _publishedFailedCovers.remove(key);
    if (_stagingPage?.url == pageUrl) {
      _stagingFailedCovers.remove(key);
      _stagingReadyCovers.remove(key);
    }
  }

  void _publishStagingFailures(VideoCatalogPage page) {
    _publishedFailedPageUrl = page.url;
    _publishedFailedCovers
      ..clear()
      ..addAll(_stagingFailedCovers);
  }

  void _checkStagingReady() {
    final page = _stagingPage;
    final completer = _stagingReadyCompleter;
    if (page == null ||
        completer == null ||
        completer.isCompleted ||
        !_stagingMetadataReady ||
        !_stagingVisibilityReported) {
      return;
    }
    final videosById = {
      for (final video in _stagingVideos(page)) video.id: video,
    };
    for (final id in _stagingVisibleVideoIds) {
      final video = videosById[id];
      if (video == null || video.cover.isEmpty) continue;
      if (!_stagingReadyCovers.contains((
        videoId: video.id,
        url: video.cover,
        cacheWidth: _stagingCacheWidth,
      ))) {
        return;
      }
    }
    completer.complete();
  }

  Future<void> _waitForStaging(int request) async {
    if (_stagingRequest != request) return;
    await _stagingReadyCompleter?.future;
  }

  Future<void> _loadUrl(
    String url, {
    String? collectionKey,
    bool preserveCollection = false,
  }) async {
    _recommendationsActive = false;
    _activeRecommendationPageSize = null;
    _pendingRecommendationReload = false;
    if (collectionKey != null) {
      _activeCollectionKey = collectionKey;
    } else if (!preserveCollection) {
      _activeCollectionKey = _collectionKeyForUrl(url);
    }
    final request = ++_request;
    _loadingUrl = url;
    final previousBrowseCancelToken = _activeBrowseCancelToken;
    if (previousBrowseCancelToken != null &&
        !previousBrowseCancelToken.isCancelled) {
      previousBrowseCancelToken.cancel('Superseded by a newer directory.');
    }
    final cancelToken = CancelToken();
    _activeBrowseCancelToken = cancelToken;
    final cachedPage = _takeCachedPage(url);
    final cachedFailures =
        cachedPage != null && _publishedFailedPageUrl == cachedPage.url
        ? Set<VideoCoverImageKey>.of(_publishedFailedCovers)
        : const <VideoCoverImageKey>{};
    _retryRequest = () => _loadUrl(url);
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
      _discardStaging();
      if (cachedPage != null) {
        _resetStaging(
          request,
          cachedPage,
          metadataReady: true,
          failedCovers: cachedFailures,
        );
      }
    });
    if (cachedPage != null) _checkStagingReady();

    var cacheDisplayed = false;
    VideoCatalogPage? parsedPage;
    void onParsed(VideoCatalogPage page) {
      if (!mounted || request != _request) return;
      parsedPage = page;
      if (cachedPage == null || cacheDisplayed) {
        _setStagingPage(request, page, metadataReady: false);
      }
    }

    VideoCatalogPage? refreshedPage;
    Object? refreshError;
    StackTrace? refreshTrace;
    final browseFuture = _client
        .browse(url, cancelToken: cancelToken, onParsed: onParsed)
        .then<void>(
          (page) {
            refreshedPage = page;
          },
          onError: (Object error, StackTrace trace) {
            refreshError = error;
            refreshTrace = trace;
          },
        );

    try {
      if (cachedPage != null) {
        await _waitForStaging(request);
        if (!mounted || request != _request) return;
        cacheDisplayed = true;
        setState(() {
          _publishStagingFailures(cachedPage);
          _page = cachedPage;
          _localPage = 1;
          _loading = refreshError == null;
          if (refreshError != null) _recordError(refreshError!);
          _discardStaging();
          if (refreshError == null) {
            final stagingPage = refreshedPage ?? parsedPage;
            if (stagingPage != null) {
              _resetStaging(
                request,
                stagingPage,
                metadataReady: refreshedPage != null,
                failedCovers: Set<VideoCoverImageKey>.of(
                  _publishedFailedCovers,
                ),
              );
            }
          }
        });
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || request != _request) return;
        if (refreshError != null) return;
      }

      await browseFuture;
      if (!mounted || request != _request) return;
      if (refreshError != null) {
        if (cachedPage != null) {
          setState(() {
            _loading = false;
            _recordError(refreshError!);
            _discardStaging();
          });
          return;
        }
        Error.throwWithStackTrace(refreshError!, refreshTrace!);
      }
      final page = refreshedPage;
      if (page == null) return;
      if (_stagingRequest == request) {
        _updateStagingPage(request, page, metadataReady: true);
      } else {
        _setStagingPage(request, page, metadataReady: true);
      }
      await _waitForStaging(request);
      if (!mounted || request != _request) return;
      final preserveScroll = cacheDisplayed && _page?.url == page.url;
      setState(() {
        _publishStagingFailures(page);
        _page = page;
        if (!preserveScroll) _localPage = 1;
        _loading = false;
        _error = null;
        _verificationError = null;
        _discardStaging();
      });
      _rememberPage(url, page);
      if (!preserveScroll && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _recordError(error);
        _discardStaging();
      });
    } finally {
      if (identical(_activeBrowseCancelToken, cancelToken)) {
        _activeBrowseCancelToken = null;
      }
      if (request == _request && _loadingUrl == url) _loadingUrl = null;
    }
  }

  Future<void> _search() async {
    final s = S.of(context);
    final collectionKey = _activeCollectionKey;
    await pushWorkDetailRoute(
      context,
      builder: (_) => GlobalAudioPlayerWrapper(
        child: VideoSearchScreen(
          title: s.search,
          search: (query, filters, isCurrent) async {
            if (collectionKey != null &&
                (collectionKey == 'favorites' || collectionKey == 'history')) {
              final videos = await _client.searchCollection(
                _client.collectionUrl(collectionKey),
                query,
                isCurrent: isCurrent,
              );
              return VideoSearchResults.collection(videos);
            }
            if (filters.isNotEmpty) {
              return VideoSearchResults.collection(
                await _client.searchWithFilters(
                  query,
                  filters,
                  isCurrent: isCurrent,
                ),
              );
            }
            return VideoSearchResults.catalog(await _client.search(query));
          },
          loadFilters:
              collectionKey == 'favorites' || collectionKey == 'history'
              ? null
              : (kind, pageUrl) =>
                    _client.searchFilterOptions(kind, pageUrl: pageUrl),
          browsePage: _client.browse,
          accountClient:
              collectionKey == 'favorites' || collectionKey == 'history'
              ? _client
              : null,
          verifyAccess: (searchContext, verification) => verifyMissavAccess(
            searchContext,
            _client,
            sourceUrl: verification.sourceUrl ?? _client.homeUrl,
          ),
        ),
      ),
    );
  }

  void _recordError(Object error) {
    _error = error.toString();
    _verificationError = error is MissavVerificationRequiredException
        ? error
        : null;
  }

  Future<void> _retryCurrentPage() async {
    final retry = _retryRequest;
    if (retry != null) {
      await retry();
    } else {
      await _loadUrl(widget.initialUrl ?? _defaultCatalogUrl);
    }
  }

  Future<void> _verifyAndRetry() async {
    final verification = _verificationError;
    if (verification == null) return;
    final retry =
        _retryRequest ??
        () => _loadUrl(widget.initialUrl ?? _defaultCatalogUrl);
    _verifyingAccess = true;
    var verified = false;
    try {
      verified = await verifyMissavAccess(
        context,
        _client,
        sourceUrl: verification.sourceUrl ?? _client.homeUrl,
      );
    } catch (_) {
      verified = false;
    } finally {
      _verifyingAccess = false;
    }
    if (!mounted) return;
    final pendingAccountReloadUrl = _pendingAccountReloadUrl;
    _pendingAccountReloadUrl = null;
    if (verified) {
      await retry();
    } else if (_pendingRecommendationReload) {
      _pendingRecommendationReload = false;
      _openRecommendations();
    } else if (pendingAccountReloadUrl != null) {
      await _loadUrl(pendingAccountReloadUrl);
    }
  }

  Future<void> _openCatalog(VideoLink link) => _loadUrl(link.url);

  String _catalogUrl(String path) {
    final home = Uri.parse(_client.homeUrl);
    final basePath = home.path.replaceFirst(RegExp(r'/+$'), '');
    return home.replace(path: '$basePath/$path').toString();
  }

  String get _defaultCatalogUrl => _catalogUrl('release');

  void _selectRecommendations() {
    _openRecommendations(refresh: _recommendationsActive);
  }

  void _openRecommendations({int? pageSize, bool refresh = false}) {
    final int size = pageSize ?? ref.read<int>(pageSizeProvider);
    final clearPage =
        refresh ||
        !_recommendationsActive ||
        _activeRecommendationPageSize != size;
    _recommendationsActive = true;
    _activeCollectionKey = null;
    _activeRecommendationPageSize = size;
    if (refresh ||
        _recommendationState == null ||
        _recommendationStatePageSize != size) {
      _recommendationState = _VideoRecommendationState();
      _recommendationStatePageSize = size;
    }
    final state = _recommendationState!;
    final pageNumber = refresh ? 1 : state.currentPage;
    if (state.pages.containsKey(pageNumber)) {
      unawaited(
        _showRecommendationPage(
          pageSize: size,
          pageNumber: pageNumber,
          clearPage: clearPage,
        ),
      );
    } else {
      unawaited(
        _loadRecommendationPage(
          pageSize: size,
          pageNumber: pageNumber,
          clearPage: clearPage,
        ),
      );
    }
  }

  void _openRecommendationPage(int pageSize, int pageNumber) {
    final state = _recommendationState;
    if (_recommendationStatePageSize != pageSize ||
        state == null ||
        pageNumber < 1) {
      return;
    }
    if (state.pages.containsKey(pageNumber)) {
      unawaited(
        _showRecommendationPage(pageSize: pageSize, pageNumber: pageNumber),
      );
    } else if (pageNumber == state.currentPage + 1 &&
        state.pages[state.currentPage]?.hasMore == true) {
      unawaited(
        _loadRecommendationPage(pageSize: pageSize, pageNumber: pageNumber),
      );
    }
  }

  VideoCatalogPage _recommendationCatalogPage(
    _VideoRecommendationSnapshot snapshot,
  ) => VideoCatalogPage(
    title: S.of(context).videoRecommendedForYou,
    url: _client.homeUrl,
    videos: snapshot.videos,
  );

  bool _isCurrentRecommendationRequest(int request, int pageSize) =>
      mounted &&
      request == _request &&
      _recommendationsActive &&
      _activeRecommendationPageSize == pageSize;

  Future<void> _showRecommendationPage({
    required int pageSize,
    required int pageNumber,
    bool clearPage = false,
  }) async {
    final state = _recommendationState;
    if (_recommendationStatePageSize != pageSize || state == null) return;
    final snapshot = state.pages[pageNumber];
    if (snapshot == null) return;

    final request = ++_request;
    _loadingUrl = null;
    final activeBrowseCancelToken = _activeBrowseCancelToken;
    if (activeBrowseCancelToken != null &&
        !activeBrowseCancelToken.isCancelled) {
      activeBrowseCancelToken.cancel('Showing a cached recommendation page.');
    }
    _activeBrowseCancelToken = null;
    final page = _recommendationCatalogPage(snapshot);
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
      _retryRequest = null;
      _discardStaging();
      if (clearPage) _page = null;
      _resetStaging(request, page, metadataReady: true);
    });
    _checkStagingReady();

    try {
      await _waitForStaging(request);
      if (!_isCurrentRecommendationRequest(request, pageSize)) return;
      setState(() {
        _publishStagingFailures(page);
        state.currentPage = pageNumber;
        _page = page;
        _localPage = 1;
        _loading = false;
        _error = null;
        _verificationError = null;
        _discardStaging();
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    } catch (error) {
      if (!_isCurrentRecommendationRequest(request, pageSize)) return;
      setState(() {
        _loading = false;
        _recordError(error);
        _discardStaging();
      });
    }
  }

  Future<void> _loadRecommendationPage({
    required int pageSize,
    int pageNumber = 1,
    bool clearPage = false,
  }) async {
    if (_recommendationState == null ||
        _recommendationStatePageSize != pageSize) {
      _recommendationState = _VideoRecommendationState();
      _recommendationStatePageSize = pageSize;
    }
    final state = _recommendationState!;
    final cachedPage = state.pages[pageNumber];
    if (cachedPage != null) {
      await _showRecommendationPage(
        pageSize: pageSize,
        pageNumber: pageNumber,
        clearPage: clearPage,
      );
      return;
    }
    final previousSnapshot = pageNumber > 1
        ? state.pages[pageNumber - 1]
        : null;
    if (pageNumber > 1 &&
        (previousSnapshot == null || !previousSnapshot.hasMore)) {
      return;
    }

    final request = ++_request;
    _activeRecommendationPageSize = pageSize;
    _loadingUrl = null;
    final previousCancelToken = _activeBrowseCancelToken;
    if (previousCancelToken != null && !previousCancelToken.isCancelled) {
      previousCancelToken.cancel('Superseded by a recommendation request.');
    }
    final cancelToken = CancelToken();
    _activeBrowseCancelToken = cancelToken;
    _retryRequest = () => _loadRecommendationPage(
      pageSize: pageSize,
      pageNumber: pageNumber,
      clearPage: clearPage,
    );
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
      _discardStaging();
      if (clearPage) _page = null;
    });

    try {
      final videos = <VideoItem>[];
      var cursor = state.cursor;
      var hasRequestedSource = state.hasRequestedSource;
      var exhausted = state.exhausted;
      var bufferedVideos = [...state.bufferedVideos];
      var consumedBufferedCount = 0;
      while (videos.length < pageSize) {
        if (consumedBufferedCount < bufferedVideos.length) {
          final remaining = pageSize - videos.length;
          final available = bufferedVideos.length - consumedBufferedCount;
          final takeCount = remaining < available ? remaining : available;
          videos.addAll(
            bufferedVideos.skip(consumedBufferedCount).take(takeCount),
          );
          consumedBufferedCount += takeCount;
          continue;
        }
        if (exhausted) break;
        final requestCursor = hasRequestedSource ? cursor : null;
        final result = await _client.loadRecommendations(
          cursor: requestCursor,
          count: pageSize,
          cancelToken: cancelToken,
        );
        if (!_isCurrentRecommendationRequest(request, pageSize)) return;
        hasRequestedSource = true;
        if (result.videos.isEmpty) {
          cursor = null;
          exhausted = true;
          state
            ..hasRequestedSource = hasRequestedSource
            ..cursor = cursor
            ..exhausted = exhausted;
          break;
        }
        bufferedVideos.addAll(result.videos);
        final nextCursor = result.cursor;
        cursor = nextCursor;
        exhausted = cursor == null;
        state
          ..hasRequestedSource = hasRequestedSource
          ..cursor = cursor
          ..bufferedVideos = List.unmodifiable(bufferedVideos)
          ..exhausted = exhausted;
      }

      if (!_isCurrentRecommendationRequest(request, pageSize)) return;
      if (pageNumber > 1 && videos.isEmpty) {
        final previous = state.pages[pageNumber - 1];
        if (previous != null) {
          state.pages[pageNumber - 1] = _VideoRecommendationSnapshot(
            videos: previous.videos,
            hasMore: false,
          );
        }
        state
          ..hasRequestedSource = hasRequestedSource
          ..cursor = null
          ..bufferedVideos = const []
          ..exhausted = true;
        setState(() {
          _loading = false;
          _error = null;
          _verificationError = null;
        });
        return;
      }

      final snapshot = _VideoRecommendationSnapshot(
        videos: List.unmodifiable(videos),
        hasMore:
            bufferedVideos.length > consumedBufferedCount ||
            (!exhausted && cursor != null),
      );
      final page = _recommendationCatalogPage(snapshot);
      _setStagingPage(request, page, metadataReady: true);
      await _waitForStaging(request);
      if (!_isCurrentRecommendationRequest(request, pageSize)) return;
      setState(() {
        _publishStagingFailures(page);
        state
          ..hasRequestedSource = hasRequestedSource
          ..cursor = cursor
          ..bufferedVideos = List.unmodifiable(
            bufferedVideos.skip(consumedBufferedCount),
          )
          ..exhausted = exhausted;
        state.pages[pageNumber] = snapshot;
        state.currentPage = pageNumber;
        _page = page;
        _localPage = 1;
        _loading = false;
        _error = null;
        _verificationError = null;
        _discardStaging();
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    } catch (error) {
      if (!_isCurrentRecommendationRequest(request, pageSize)) return;
      setState(() {
        _loading = false;
        _recordError(error);
        _discardStaging();
      });
    } finally {
      if (identical(_activeBrowseCancelToken, cancelToken)) {
        _activeBrowseCancelToken = null;
      }
    }
  }

  String? _catalogPath(String url) {
    final segments = Uri.tryParse(url)?.pathSegments
        .where((segment) => segment.isNotEmpty)
        .map((segment) => segment.toLowerCase())
        .toList();
    if (segments == null) return null;
    if (segments.isNotEmpty && RegExp(r'^dm\d+$').hasMatch(segments.first)) {
      segments.removeAt(0);
    }
    if (segments.isNotEmpty &&
        _catalogSourceLanguages.contains(segments.first)) {
      segments.removeAt(0);
    }
    return segments.join('/');
  }

  Map<String, String> _sourceCatalogUrls() {
    final page = _page;
    if (page == null) return const {};
    final urls = <String, String>{};
    for (final link in [...page.navigation, ...page.links]) {
      final slug = _catalogPath(link.url);
      if (slug != null && _approvedCatalogSlugs.contains(slug)) {
        urls.putIfAbsent(slug, () => link.url);
      }
    }
    return urls;
  }

  List<VideoLink> _approvedCatalogLinks(S s) {
    final sourceUrls = _sourceCatalogUrls();
    VideoLink entry(String label, String slug) => VideoLink(
      label: label,
      url: sourceUrls[slug] ?? _catalogUrl(slug),
      kind: VideoLinkKind.navigation,
    );
    return [
      entry(s.videoNewReleases, 'release'),
      entry(s.videoRecentlyUpdated, 'new'),
      entry(s.videoChineseSubtitles, 'chinese-subtitle'),
      entry(s.videoWeeklyHot, 'weekly-hot'),
      entry(s.videoUncensoredLeak, 'uncensored-leak'),
    ];
  }

  Future<void> _openAccount() =>
      pushBottomDockRoute(context, builder: (_) => const VideoAccountScreen());

  Future<void> _openDownloads() => pushBottomDockRoute(
    context,
    builder: (_) => const VideoDownloadsScreen(),
  );

  Future<void> _openDetails(VideoItem video) => pushWorkDetailRoute(
    context,
    builder: (_) => VideoDetailsScreen(video: video),
  );

  bool _isCollectionLink(VideoLink link) {
    final segments = Uri.tryParse(
      link.url,
    )?.pathSegments.map((segment) => segment.toLowerCase()).toList();
    if (segments == null) return false;
    if (segments.isNotEmpty && RegExp(r'^dm\d+$').hasMatch(segments.first)) {
      segments.removeAt(0);
    }
    if (segments.isNotEmpty &&
        _catalogSourceLanguages.contains(segments.first)) {
      segments.removeAt(0);
    }
    if (segments.length == 1) {
      return const {
        'saved',
        'favorites',
        'favourites',
        'bookmarks',
        'history',
        'playlists',
      }.contains(segments.single);
    }
    return segments.length == 2 &&
        const {'saved', 'favorites', 'favourites'}.contains(segments.first) &&
        const {'actresses', 'actors'}.contains(segments.last);
  }

  String? _collectionKeyForUrl(String url) {
    final path = _catalogPath(url);
    if (path == null) return null;
    final segments = path.split('/');
    if (const {
      'favorites',
      'favourites',
      'bookmarks',
    }.contains(segments.first)) {
      return segments.length > 1 &&
              const {'actresses', 'actors'}.contains(segments[1])
          ? 'actorFavorites'
          : 'favorites';
    }
    for (final key in const [
      'favorites',
      'actorFavorites',
      'playlists',
      'history',
    ]) {
      final collectionPath = _catalogPath(_client.collectionUrl(key));
      if (collectionPath == path ||
          (key == 'playlists' && path.startsWith('$collectionPath/'))) {
        return key;
      }
    }
    return null;
  }

  Future<void> _openCollection(String key) =>
      _loadUrl(_client.collectionUrl(key), collectionKey: key);

  IconData _directoryIcon(VideoLink link) => switch (link.kind) {
    VideoLinkKind.actor => Icons.person_outline,
    VideoLinkKind.category => Icons.category_outlined,
    VideoLinkKind.tag => Icons.sell_outlined,
    VideoLinkKind.studio => Icons.movie_creation_outlined,
    VideoLinkKind.playlist => Icons.playlist_play,
    _ => Icons.explore_outlined,
  };

  Widget _collectionLinkTile(VideoLink link) {
    Widget? trailing;
    if (link.kind == VideoLinkKind.actor) {
      final s = S.of(context);
      trailing = PopupMenuButton<String>(
        tooltip: link.label,
        onSelected: (action) {
          if (action == 'favorite') unawaited(_setActorFavorite(link, true));
          if (action == 'unfavorite') unawaited(_setActorFavorite(link, false));
          if (action == 'source') unawaited(_openSource(link.url));
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'favorite', child: Text(s.videoFavoriteActor)),
          PopupMenuItem(
            value: 'unfavorite',
            child: Text(s.videoUnfavoriteActor),
          ),
          PopupMenuItem(value: 'source', child: Text(s.videoOpenSource)),
        ],
      );
    } else if (link.kind == VideoLinkKind.playlist) {
      final s = S.of(context);
      trailing = PopupMenuButton<String>(
        tooltip: link.label,
        onSelected: (action) {
          if (action == 'source') unawaited(_openSource(link.url));
          if (action == 'rename') {
            unawaited(_showPlaylistNameDialog(playlist: link));
          }
          if (action == 'delete') unawaited(_deletePlaylist(link));
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'source', child: Text(s.videoOpenSource)),
          PopupMenuItem(value: 'rename', child: Text(s.videoRenamePlaylist)),
          PopupMenuItem(value: 'delete', child: Text(s.videoDeletePlaylist)),
        ],
      );
    }
    return ListTile(
      leading: Icon(_directoryIcon(link)),
      title: Text(link.label),
      trailing: trailing,
      onTap: () => _openCatalog(link),
    );
  }

  Future<void> _loginRequired() async {
    if (!mounted) return;
    final s = S.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.videoLoginRequired),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(_openAccount());
            },
            child: Text(s.login),
          ),
        ],
      ),
    );
  }

  Future<void> _setActorFavorite(VideoLink actor, bool favorite) async {
    if (!_client.isLoggedIn) {
      await _loginRequired();
      return;
    }
    try {
      await _client.setActorFavorite(actor, favorite);
    } on MissavAuthenticationException {
      await _loginRequired();
    } on MissavException catch (error) {
      await _showSourceFallback(error.sourceUrl ?? actor.url);
    } catch (_) {
      await _showSourceFallback(actor.url);
    }
  }

  Future<void> _confirmClearWatchHistory() async {
    final page = _page;
    if (page == null) return;
    if (!_client.isLoggedIn) {
      await _loginRequired();
      return;
    }
    final s = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.clearHistory),
        content: Text(s.clearHistoryConfirm),
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
    if (!mounted || confirmed != true) return;
    try {
      await _client.clearWatchHistory();
      if (mounted) await _loadUrl(page.url);
    } on MissavAuthenticationException {
      await _loginRequired();
    } on MissavException catch (error) {
      await _showSourceFallback(error.sourceUrl ?? page.url);
    } catch (_) {
      await _showSourceFallback(page.url);
    }
  }

  Future<void> _showSourceFallback(String url) async {
    if (!mounted) return;
    final s = S.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.videoSourceUnavailable),
        content: Text(s.videoOpenSource),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.cancel),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(_openSource(url));
            },
            icon: const Icon(Icons.open_in_new),
            label: Text(s.videoOpenSource),
          ),
        ],
      ),
    );
  }

  Future<void> _openSource(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      SnackBarUtil.showFromSnackBar(
        context,
        SnackBar(content: Text(S.of(context).videoSourceUnavailable)),
      );
    }
  }

  bool _isPlaylistPage(VideoCatalogPage page) =>
      Uri.tryParse(page.url)?.path.toLowerCase().contains('playlist') ?? false;

  bool _isWatchHistoryPage(VideoCatalogPage page) => RegExp(
    r'history|watch',
  ).hasMatch(Uri.tryParse(page.url)?.path.toLowerCase() ?? '');

  Future<void> _showPlaylistNameDialog({VideoLink? playlist}) async {
    final s = S.of(context);
    final nameFieldKey = GlobalKey<_PlaylistNameFieldState>();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          playlist == null ? s.videoCreatePlaylist : s.videoRenamePlaylist,
        ),
        content: _PlaylistNameField(
          key: nameFieldKey,
          initialName: playlist?.label ?? '',
          label: s.videoPlaylistName,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              context,
            ).pop(nameFieldKey.currentState?.value.trim() ?? ''),
            child: Text(s.confirm),
          ),
        ],
      ),
    );
    if (!mounted || title == null || title.isEmpty) return;
    try {
      if (playlist == null) {
        await _client.createPlaylist(title);
      } else {
        await _client.renamePlaylist(playlist, title);
      }
      if (mounted && _page != null) await _loadUrl(_page!.url);
    } on MissavException catch (error) {
      if (mounted) {
        await _showSourceFallback(
          error.sourceUrl ??
              (playlist?.url ?? _client.collectionUrl('playlists')),
        );
      }
    } catch (_) {
      if (mounted) {
        await _showSourceFallback(
          playlist?.url ?? _client.collectionUrl('playlists'),
        );
      }
    }
  }

  Future<void> _deletePlaylist(VideoLink playlist) async {
    final s = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.videoDeletePlaylist),
        content: Text(s.deletePlaylistConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(s.delete),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await _client.deletePlaylist(playlist);
      if (mounted && _page != null) await _loadUrl(_page!.url);
    } on MissavException catch (error) {
      if (mounted) await _showSourceFallback(error.sourceUrl ?? playlist.url);
    } catch (_) {
      if (mounted) await _showSourceFallback(playlist.url);
    }
  }

  String _errorMessage(S s) {
    if (_error == null) return s.videoLoadFailed;
    if (_verificationError != null) return s.videoVerificationRequired;
    final normalized = _error!.toLowerCase();
    if (normalized.contains('login') || normalized.contains('authentication')) {
      return s.videoLoginRequired;
    }
    return s.videoLoadFailed;
  }

  List<VideoLink> _collectionLinksForContent(VideoCatalogPage page) {
    final collectionKey = _collectionKeyForUrl(page.url);
    if (collectionKey != _activeCollectionKey) return const [];
    final kind = switch (collectionKey) {
      'actorFavorites' => VideoLinkKind.actor,
      'playlists' => VideoLinkKind.playlist,
      _ => null,
    };
    if (kind == null) return const [];

    final navigationUrls = page.navigation.map((link) => link.url).toSet();
    final seenUrls = <String>{};
    return page.links
        .where(
          (link) =>
              link.kind == kind &&
              !_isCollectionLink(link) &&
              !navigationUrls.contains(link.url) &&
              seenUrls.add(link.url),
        )
        .toList(growable: false);
  }

  List<Widget> _drawer(LayoutType layoutType) {
    final s = S.of(context);
    final catalogLinks = _approvedCatalogLinks(s);
    return [
      LibraryDrawerSection(
        title: s.videoSourceAccount,
        children: [
          LibraryDrawerTile(
            icon: Icons.account_circle_outlined,
            title: _client.isLoggedIn
                ? (_client.accountName ?? s.videoSourceAccount)
                : s.videoSourceAccount,
            onTap: _openAccount,
          ),
        ],
      ),
      LibraryDrawerSection(
        title: s.videoContent,
        children: [
          for (final link in catalogLinks)
            LibraryDrawerTile(
              icon: Icons.explore_outlined,
              title: link.label,
              onTap: () => _openCatalog(link),
            ),
          LibraryDrawerTile(
            icon: Icons.thumb_up_alt_outlined,
            title: s.videoRecommendedForYou,
            onTap: _selectRecommendations,
          ),
        ],
      ),
      LibraryDrawerSection(
        title: s.libraryBrowseOptions,
        children: [
          LibraryDrawerTile(
            icon: switch (layoutType) {
              LayoutType.bigGrid => Icons.grid_view,
              LayoutType.smallGrid => Icons.apps,
              LayoutType.list => Icons.view_list,
            },
            title: s.layout,
            onTap: () => ref.read(videoBrowseLayoutProvider.notifier).cycle(),
          ),
        ],
      ),
      LibraryDrawerSection(
        title: s.videoSourceAccount,
        children: [
          LibraryDrawerTile(
            icon: Icons.bookmark_outline,
            title: s.videoFavorites,
            onTap: () => _openCollection('favorites'),
          ),
          LibraryDrawerTile(
            icon: Icons.person_outline,
            title: s.videoActorFavorites,
            onTap: () => _openCollection('actorFavorites'),
          ),
          LibraryDrawerTile(
            icon: Icons.playlist_play,
            title: s.playlists,
            onTap: () => _openCollection('playlists'),
          ),
          LibraryDrawerTile(
            icon: Icons.history,
            title: s.videoWatchHistory,
            onTap: () => _openCollection('history'),
          ),
        ],
      ),
      LibraryDrawerSection(
        title: s.videoDownloads,
        children: [
          LibraryDrawerTile(
            icon: Icons.download_outlined,
            title: s.videoDownloads,
            onTap: _openDownloads,
          ),
        ],
      ),
    ];
  }

  Widget _content(S s, LayoutType layoutType) {
    if (_loading && _page == null) {
      return _withStaging(
        const Center(child: CircularProgressIndicator()),
        s,
        layoutType,
      );
    }
    if (_error != null && _page == null) {
      return _withStaging(
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_errorMessage(s), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _retryCurrentPage,
                      icon: const Icon(Icons.refresh),
                      label: Text(s.retry),
                    ),
                    if (_verificationError != null)
                      OutlinedButton.icon(
                        onPressed: _verifyAndRetry,
                        icon: const Icon(Icons.verified_user_outlined),
                        label: Text(s.videoVerifyAccess),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(
                        _openSource(widget.initialUrl ?? _client.homeUrl),
                      ),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(s.videoOpenSource),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        s,
        layoutType,
      );
    }
    final page = _page;
    if (page == null) {
      return _withStaging(const SizedBox.shrink(), s, layoutType);
    }
    final collectionLinks = _collectionLinksForContent(page);
    final pageSize = ref.watch(pageSizeProvider);
    final recommendationPageSize = _activeRecommendationPageSize ?? pageSize;
    final recommendationState =
        _recommendationsActive &&
            _recommendationStatePageSize == recommendationPageSize
        ? _recommendationState
        : null;
    final recommendationPageNumber = recommendationState?.currentPage ?? 1;
    final recommendationSnapshot =
        recommendationState?.pages[recommendationPageNumber];
    final highestVisitedRecommendationPage =
        recommendationState?.pages.keys.fold<int>(
          1,
          (highest, pageNumber) => pageNumber > highest ? pageNumber : highest,
        ) ??
        1;
    final hasSourcePagination =
        !_recommendationsActive &&
        (page.previousUrl != null ||
            page.nextUrl != null ||
            page.jumpMaxPage != null);
    final itemCount = collectionLinks.isEmpty
        ? page.videos.length
        : collectionLinks.length;
    final localPageCount = ((itemCount + pageSize - 1) ~/ pageSize)
        .clamp(1, 1 << 30)
        .toInt();
    final hasLocalPagination = !hasSourcePagination && itemCount > pageSize;
    final localPage = _localPage.clamp(1, localPageCount).toInt();
    final videos = hasLocalPagination
        ? page.videos
              .skip((localPage - 1) * pageSize)
              .take(pageSize)
              .toList(growable: false)
        : page.videos;
    final pagination = VirtualizedPagination(
      currentPage: _recommendationsActive
          ? recommendationPageNumber
          : hasSourcePagination
          ? page.currentPage
          : localPage,
      pageSize: hasSourcePagination
          ? itemCount.clamp(1, 1000).toInt()
          : _recommendationsActive
          ? recommendationPageSize
          : pageSize,
      totalCount: hasSourcePagination || _recommendationsActive
          ? null
          : itemCount,
      jumpMaxPage: _recommendationsActive
          ? highestVisitedRecommendationPage
          : hasSourcePagination
          ? page.jumpMaxPage
          : null,
      hasMore: _recommendationsActive
          ? recommendationSnapshot?.hasMore ?? false
          : hasSourcePagination
          ? page.nextUrl != null
          : hasLocalPagination && localPage < localPageCount,
      isLoading: _loading,
      onPreviousPage: _recommendationsActive
          ? recommendationPageNumber > 1
                ? () => _openRecommendationPage(
                    recommendationPageSize,
                    recommendationPageNumber - 1,
                  )
                : null
          : hasSourcePagination
          ? page.previousUrl == null
                ? null
                : () => _loadUrl(page.previousUrl!, preserveCollection: true)
          : hasLocalPagination && localPage > 1
          ? () => setState(() => _localPage = localPage - 1)
          : null,
      onNextPage: _recommendationsActive
          ? recommendationSnapshot?.hasMore == true
                ? () => _openRecommendationPage(
                    recommendationPageSize,
                    recommendationPageNumber + 1,
                  )
                : null
          : hasSourcePagination
          ? page.nextUrl == null
                ? null
                : () => _loadUrl(page.nextUrl!, preserveCollection: true)
          : hasLocalPagination && localPage < localPageCount
          ? () => setState(() => _localPage = localPage + 1)
          : null,
      onGoToPage: _recommendationsActive
          ? (targetPage) => targetPage <= highestVisitedRecommendationPage
                ? _openRecommendationPage(recommendationPageSize, targetPage)
                : null
          : hasSourcePagination
          ? page.jumpMaxPage == null
                ? null
                : (targetPage) => _loadUrl(
                    page.pageUrl(targetPage),
                    preserveCollection: true,
                  )
          : hasLocalPagination
          ? (targetPage) => setState(() => _localPage = targetPage)
          : null,
      showWhenEmpty: true,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
    );
    return _withStaging(
      LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            children: [
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth - 120,
                            ),
                            child: Text(_errorMessage(s)),
                          ),
                          TextButton(
                            onPressed: _retryCurrentPage,
                            child: Text(s.retry),
                          ),
                          if (_verificationError != null)
                            TextButton.icon(
                              onPressed: _verifyAndRetry,
                              icon: const Icon(Icons.verified_user_outlined),
                              label: Text(s.videoVerifyAccess),
                            ),
                          TextButton(
                            onPressed: () => unawaited(_openSource(page.url)),
                            child: Text(s.videoOpenSource),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: collectionLinks.isNotEmpty
                    ? VirtualizedSliverCollection<VideoLink>(
                        items: hasLocalPagination
                            ? collectionLinks
                                  .skip((localPage - 1) * pageSize)
                                  .take(pageSize)
                                  .toList(growable: false)
                            : collectionLinks,
                        itemId: (link) => link.url,
                        itemBuilder: (context, link, _) =>
                            _collectionLinkTile(link),
                        controller: _scrollController,
                        pageStorageKey: PageStorageKey<String>(
                          'video-links-${page.url}',
                        ),
                        pagination: pagination,
                      )
                    : VideoCollectionView(
                        items: videos,
                        layoutType: layoutType,
                        itemId: (video) => video.id,
                        itemBuilder: (context, video, _) => VideoCard(
                          video: video,
                          layoutType: layoutType,
                          onTap: () => _openDetails(video),
                          onOpenLink: _openCatalog,
                          failedCoverKeys: _publishedFailedPageUrl == page.url
                              ? _publishedFailedCovers
                              : const {},
                          onCoverTerminal: (key, {required failed}) =>
                              _onPublishedCoverTerminal(
                                page.url,
                                key,
                                failed: failed,
                              ),
                          onCoverRetry: (key) =>
                              _onPublishedCoverRetry(page.url, key),
                        ),
                        controller: _scrollController,
                        pageStorageKey: PageStorageKey<String>(
                          _recommendationsActive
                              ? 'video-recommendations-$recommendationPageSize-$recommendationPageNumber'
                              : 'video-${page.url}',
                        ),
                        emptyBuilder: (_) => Center(child: Text(s.noResults)),
                        pagination: pagination,
                      ),
              ),
            ],
          );
        },
      ),
      s,
      layoutType,
    );
  }

  Widget _withStaging(Widget content, S s, LayoutType layoutType) {
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        if (_stagingPage != null)
          Visibility(
            visible: false,
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            child: _stagingContent(s, layoutType),
          ),
      ],
    );
  }

  Widget _stagingContent(S s, LayoutType layoutType) {
    final page = _stagingPage;
    final request = _stagingRequest;
    if (page == null || request == null) return const SizedBox.shrink();
    final videos = _stagingVideos(page);
    return Column(
      children: [
        Expanded(
          child: VideoCollectionView<VideoItem>(
            items: videos,
            layoutType: layoutType,
            itemId: (video) => video.id,
            itemBuilder: (_, video, _) => VideoCard(
              video: video,
              layoutType: layoutType,
              onTap: null,
              onCoverTerminal: (key, {required failed}) =>
                  _onStagingCoverTerminal(request, key, failed: failed),
              failedCoverKeys: _stagingFailedCovers,
            ),
            controller: _stagingScrollController,
            pageStorageKey: PageStorageKey<String>(
              'video-staging-$request-$_stagingRevision-${page.url}',
            ),
            emptyBuilder: (_) => Center(child: Text(s.noResults)),
            onVisibleItemsChanged: (items, cacheWidth) =>
                _onStagingVisibleItemsChanged(request, items, cacheWidth),
            onCoverCacheWidthChanged: (cacheWidth) =>
                _onStagingCacheWidthChanged(request, cacheWidth),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    ref.listen<int>(pageSizeProvider, (previous, next) {
      if (_recommendationsActive && previous != next) {
        _openRecommendations(pageSize: next);
      }
    });
    final layoutType = ref.watch(videoBrowseLayoutProvider);
    final title = _page?.title.isNotEmpty == true ? _page!.title : s.navVideos;
    final page = LibraryPageScaffold(
      title: title,
      searchHint: s.videoSearchHint,
      onSearch: _search,
      drawerChildren: _drawer(layoutType),
      deferDrawerActions: widget.active,
      body: _content(s, layoutType),
      floatingActionButton: _page != null && _isPlaylistPage(_page!)
          ? FloatingActionButton.extended(
              heroTag: 'video-create-playlist',
              onPressed: () => unawaited(_showPlaylistNameDialog()),
              icon: const Icon(Icons.add),
              label: Text(s.videoCreatePlaylist),
            )
          : _page != null && _isWatchHistoryPage(_page!)
          ? FloatingActionButton.extended(
              heroTag: 'video-clear-watch-history',
              onPressed: () => unawaited(_confirmClearWatchHistory()),
              icon: const Icon(Icons.delete_sweep_outlined),
              label: Text(s.clearHistory),
            )
          : null,
    );
    return widget.initialUrl == null
        ? page
        : GlobalAudioPlayerWrapper(child: page);
  }

  @override
  void dispose() {
    _client.removeListener(_onClientChanged);
    _route?.secondaryAnimation?.removeStatusListener(_onRouteStatusChanged);
    _request++;
    final activeBrowseCancelToken = _activeBrowseCancelToken;
    if (activeBrowseCancelToken != null &&
        !activeBrowseCancelToken.isCancelled) {
      activeBrowseCancelToken.cancel('Video screen was disposed.');
    }
    _discardStaging();
    _scrollController.dispose();
    _stagingScrollController.dispose();
    super.dispose();
  }
}

class _PlaylistNameField extends StatefulWidget {
  const _PlaylistNameField({
    super.key,
    required this.initialName,
    required this.label,
  });

  final String initialName;
  final String label;

  @override
  State<_PlaylistNameField> createState() => _PlaylistNameFieldState();
}

class _PlaylistNameFieldState extends State<_PlaylistNameField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  String get value => _controller.text;

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    autofocus: true,
    decoration: InputDecoration(labelText: widget.label),
    onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
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
  String? _pendingAccountReloadUrl;
  ModalRoute<dynamic>? _route;
  final ScrollController _scrollController = ScrollController();
  String? _activeCollectionKey;
  String? _sourceLocaleTag;
  int _localPage = 1;

  @override
  void initState() {
    super.initState();
    _client = ref.read(videoClientProvider);
    _library = ref.read(videoLibraryProvider);
    _downloads = ref.read(videoDownloadsProvider);
    _accountWasLoggedIn = _client.isLoggedIn;
    _accountName = _client.accountName;
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
    final changed = _client.setLocale(languageTag);
    if (!changed || !_dependenciesReady) return;
    final url =
        _page?.url ??
        _pendingAccountReloadUrl ??
        widget.initialUrl ??
        _client.homeUrl;
    if (!widget.active) {
      _pendingAccountReloadUrl = url;
      _page = null;
      return;
    }
    if (ModalRoute.of(context)?.isCurrent == false) {
      _pendingAccountReloadUrl = url;
      return;
    }
    _scheduleLoadUrl(url, collectionKey: _activeCollectionKey);
  }

  @override
  void didUpdateWidget(VideoScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active && _page == null) {
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
          _pendingAccountReloadUrl ?? widget.initialUrl ?? _client.homeUrl;
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
    if (isLoggedIn == _accountWasLoggedIn && accountName == _accountName) {
      return;
    }
    _accountWasLoggedIn = isLoggedIn;
    _accountName = accountName;
    if (!mounted) return;

    final covered = ModalRoute.of(context)?.isCurrent == false;
    if (_loading && !covered) return;
    final url =
        _pendingAccountReloadUrl ??
        _page?.url ??
        widget.initialUrl ??
        _client.homeUrl;
    _request++;
    setState(() {
      _page = null;
      _error = null;
      _verificationError = null;
      _retryRequest = null;
      _loading = false;
    });
    if (!_dependenciesReady) return;
    if (widget.active && !covered) {
      unawaited(_loadUrl(url));
    } else {
      _pendingAccountReloadUrl = url;
    }
  }

  void _onRouteStatusChanged(AnimationStatus _) {
    if (!mounted || _verifyingAccess) return;
    final url = _pendingAccountReloadUrl;
    if (url == null || _route?.isCurrent != true || !widget.active) return;
    _pendingAccountReloadUrl = null;
    unawaited(_loadUrl(url));
  }

  Future<void> _loadUrl(
    String url, {
    String? collectionKey,
    bool preserveCollection = false,
  }) async {
    if (collectionKey != null) {
      _activeCollectionKey = collectionKey;
    } else if (!preserveCollection) {
      _activeCollectionKey = _collectionKeyForUrl(url);
    }
    final request = ++_request;
    _retryRequest = () => _loadUrl(url);
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
    });
    try {
      final page = await _client.browse(url);
      if (!mounted || request != _request) return;
      setState(() {
        _page = page;
        _localPage = 1;
        _loading = false;
        _error = null;
        _verificationError = null;
      });
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _recordError(error);
      });
    }
  }

  Future<void> _search() async {
    final s = S.of(context);
    final collectionKey = _activeCollectionKey;
    await pushWorkDetailRoute(
      context,
      builder: (_) => GlobalAudioPlayerWrapper.workDetails(
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
      await _loadUrl(widget.initialUrl ?? _client.homeUrl);
    }
  }

  Future<void> _verifyAndRetry() async {
    final verification = _verificationError;
    if (verification == null) return;
    final retry =
        _retryRequest ?? () => _loadUrl(widget.initialUrl ?? _client.homeUrl);
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
      entry(s.videoRecentlyUpdated, 'new'),
      entry(s.videoNewReleases, 'release'),
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
    for (final key in const [
      'favorites',
      'actorFavorites',
      'playlists',
      'history',
    ]) {
      final collectionPath = _catalogPath(_client.collectionUrl(key));
      if (collectionPath == path) return key;
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
      ScaffoldMessenger.of(context).showSnackBar(
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
          LibraryDrawerTile(
            icon: Icons.home_outlined,
            title: s.navHome,
            selected:
                _collectionKeyForUrl(_page?.url ?? '') == null &&
                (_page?.url == null ||
                    Uri.tryParse(_page!.url)?.path ==
                        Uri.tryParse(_client.homeUrl)?.path),
            onTap: () => _loadUrl(_client.homeUrl),
          ),
          for (final link in catalogLinks)
            LibraryDrawerTile(
              icon: Icons.explore_outlined,
              title: link.label,
              onTap: () => _openCatalog(link),
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
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _page == null) {
      return Center(
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
      );
    }
    final page = _page;
    if (page == null) return const SizedBox.shrink();
    final collectionLinks = _loading
        ? const <VideoLink>[]
        : _collectionLinksForContent(page);
    final pageSize = ref.watch(pageSizeProvider);
    final hasSourcePagination =
        page.previousUrl != null ||
        page.nextUrl != null ||
        page.jumpMaxPage != null;
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
      currentPage: hasSourcePagination ? page.currentPage : localPage,
      pageSize: hasSourcePagination
          ? itemCount.clamp(1, 1000).toInt()
          : pageSize,
      totalCount: hasSourcePagination ? null : itemCount,
      jumpMaxPage: hasSourcePagination ? page.jumpMaxPage : null,
      hasMore: hasSourcePagination
          ? page.nextUrl != null
          : hasLocalPagination && localPage < localPageCount,
      isLoading: _loading,
      onPreviousPage: hasSourcePagination
          ? page.previousUrl == null
                ? null
                : () => _loadUrl(page.previousUrl!, preserveCollection: true)
          : hasLocalPagination && localPage > 1
          ? () => setState(() => _localPage = localPage - 1)
          : null,
      onNextPage: hasSourcePagination
          ? page.nextUrl == null
                ? null
                : () => _loadUrl(page.nextUrl!, preserveCollection: true)
          : hasLocalPagination && localPage < localPageCount
          ? () => setState(() => _localPage = localPage + 1)
          : null,
      onGoToPage: hasSourcePagination
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
    return LayoutBuilder(
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
                      ),
                      controller: _scrollController,
                      pageStorageKey: PageStorageKey<String>(
                        'video-${page.url}',
                      ),
                      emptyBuilder: (_) => Center(child: Text(s.noResults)),
                      pagination: pagination,
                    ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
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
    _scrollController.dispose();
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

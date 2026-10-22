import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/library_page_scaffold.dart';
import '../missav_client.dart';
import '../video_downloads.dart';
import '../video_library.dart';
import '../video_models.dart';
import '../video_providers.dart';
import 'video_account_screen.dart';
import 'video_details_screen.dart';
import 'video_downloads_screen.dart';

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
  late final MissavClient _client;
  late final VideoLibrary _library;
  late final VideoDownloads _downloads;
  VideoCatalogPage? _page;
  bool _loading = false;
  String? _error;
  int _request = 0;
  bool _dependenciesReady = false;
  bool _accountWasLoggedIn = false;
  String? _accountName;
  String? _pendingAccountReloadUrl;
  ModalRoute<dynamic>? _route;

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

  void _scheduleLoadUrl(String url) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) unawaited(_loadUrl(url));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;
    _route?.secondaryAnimation?.removeStatusListener(_onRouteStatusChanged);
    _route = route;
    _route?.secondaryAnimation?.addStatusListener(_onRouteStatusChanged);
  }

  @override
  void didUpdateWidget(VideoScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active && _page == null) {
      final url = _pendingAccountReloadUrl;
      _pendingAccountReloadUrl = null;
      if (_dependenciesReady && url != null) {
        _scheduleLoadUrl(url);
      } else {
        _scheduleInitialize();
      }
    }
    if (widget.active && oldWidget.initialUrl != widget.initialUrl) {
      _scheduleInitialize();
    }
  }

  Future<void> _initialize() async {
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
        _error = error.toString();
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
    if (!mounted) return;
    final url = _pendingAccountReloadUrl;
    if (url == null || _route?.isCurrent != true || !widget.active) return;
    _pendingAccountReloadUrl = null;
    unawaited(_loadUrl(url));
  }

  Future<void> _loadUrl(String url) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _client.browse(url);
      if (!mounted || request != _request) return;
      setState(() {
        _page = page;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _search() async {
    final s = S.of(context);
    final controller = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.search),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(hintText: s.videoSearchHint),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(s.search),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || query == null || query.isEmpty) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _client.search(query);
      if (!mounted || request != _request) return;
      setState(() {
        _page = page;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _openCatalog(VideoLink link) => pushBottomDockRoute(
    context,
    builder: (_) => VideoScreen.catalog(url: link.url),
  );

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

  VideoLink? _findCollection(String collection) {
    final links = [...?_page?.navigation, ...?_page?.links];
    for (final link in links) {
      final path = Uri.tryParse(link.url)?.path.toLowerCase() ?? '';
      final label = link.label.toLowerCase();
      final isMatch = switch (collection) {
        'favorites' =>
          RegExp(r'favorite|favourite|bookmark|saved').hasMatch(path) ||
              RegExp(r'favorite|favourite|bookmark|saved').hasMatch(label),
        'actorFavorites' =>
          (path.contains('actress') || path.contains('actor')) &&
              RegExp(r'favorite|favourite|saved').hasMatch('$path $label'),
        'playlists' => path.contains('playlist') || label.contains('playlist'),
        'history' => RegExp(r'history|watch').hasMatch('$path $label'),
        _ => false,
      };
      if (isMatch) return link;
    }
    return null;
  }

  bool _isCollectionLink(VideoLink link) {
    final path = Uri.tryParse(link.url)?.path.toLowerCase() ?? '';
    return RegExp(
      r'favorite|favourite|bookmark|saved|history|watch|playlist',
    ).hasMatch(path);
  }

  Future<void> _openCollection(String key) async {
    final link = _findCollection(key);
    if (link != null) {
      await _openCatalog(link);
      return;
    }
    await _showSourceFallback(_page?.url ?? _client.homeUrl);
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
    final controller = TextEditingController(text: playlist?.label ?? '');
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          playlist == null ? s.videoCreatePlaylist : s.videoRenamePlaylist,
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: s.videoPlaylistName),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(s.confirm),
          ),
        ],
      ),
    );
    controller.dispose();
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
          error.sourceUrl ?? _page?.url ?? _client.homeUrl,
        );
      }
    } catch (_) {
      if (mounted) await _showSourceFallback(_page?.url ?? _client.homeUrl);
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

  Widget _linkChip(VideoLink link, {required bool playlistPage}) {
    if (link.kind == VideoLinkKind.actor) {
      final s = S.of(context);
      return PopupMenuButton<String>(
        tooltip: link.label,
        onSelected: (action) {
          switch (action) {
            case 'open':
              unawaited(_openCatalog(link));
              break;
            case 'favorite':
              unawaited(_setActorFavorite(link, true));
              break;
            case 'unfavorite':
              unawaited(_setActorFavorite(link, false));
              break;
            case 'source':
              unawaited(_openSource(link.url));
              break;
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: 'open', child: Text(s.videoCatalog)),
          PopupMenuItem(value: 'favorite', child: Text(s.videoFavoriteActor)),
          PopupMenuItem(
            value: 'unfavorite',
            child: Text(s.videoUnfavoriteActor),
          ),
          PopupMenuItem(value: 'source', child: Text(s.videoOpenSource)),
        ],
        child: Chip(label: Text(link.label)),
      );
    }
    final isPlaylistLink =
        link.kind == VideoLinkKind.playlist ||
        playlistPage &&
            (Uri.tryParse(link.url)?.path.toLowerCase().contains('playlist') ??
                false);
    if (!isPlaylistLink) {
      return ActionChip(
        label: Text(link.label),
        onPressed: () => _openCatalog(link),
      );
    }
    final s = S.of(context);
    return PopupMenuButton<String>(
      tooltip: link.label,
      onSelected: (action) {
        switch (action) {
          case 'open':
            unawaited(_openCatalog(link));
            break;
          case 'source':
            unawaited(_openSource(link.url));
            break;
          case 'rename':
            unawaited(_showPlaylistNameDialog(playlist: link));
            break;
          case 'delete':
            unawaited(_deletePlaylist(link));
            break;
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 'open', child: Text(s.videoCatalog)),
        PopupMenuItem(value: 'source', child: Text(s.videoOpenSource)),
        PopupMenuItem(value: 'rename', child: Text(s.videoRenamePlaylist)),
        PopupMenuItem(value: 'delete', child: Text(s.videoDeletePlaylist)),
      ],
      child: Chip(label: Text(link.label)),
    );
  }

  String _errorMessage(S s) {
    if (_error == null) return s.videoLoadFailed;
    final normalized = _error!.toLowerCase();
    if (normalized.contains('verif') ||
        normalized.contains('challenge') ||
        normalized.contains('captcha') ||
        normalized.contains('403')) {
      return s.videoVerificationRequired;
    }
    if (normalized.contains('login') || normalized.contains('authentication')) {
      return s.videoLoginRequired;
    }
    return s.videoLoadFailed;
  }

  List<Widget> _drawer() {
    final s = S.of(context);
    final navigation = _page?.navigation ?? const <VideoLink>[];
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
        title: s.videoCatalog,
        children: [
          LibraryDrawerTile(
            icon: Icons.home_outlined,
            title: s.videoCatalog,
            selected: widget.initialUrl == null,
            onTap: () => _loadUrl(_client.homeUrl),
          ),
          for (final link in navigation.where(
            (link) => !_isCollectionLink(link),
          ))
            LibraryDrawerTile(
              icon: Icons.explore_outlined,
              title: link.label,
              onTap: () => _openCatalog(link),
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

  Widget _content(S s) {
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
                    onPressed: () => unawaited(
                      _loadUrl(widget.initialUrl ?? _client.homeUrl),
                    ),
                    icon: const Icon(Icons.refresh),
                    label: Text(s.retry),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = (constraints.maxWidth / 184)
            .floor()
            .clamp(1, 6)
            .toInt();
        return Column(
          children: [
            if (page.links.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  scrollDirection: Axis.horizontal,
                  itemBuilder: (context, index) {
                    final link = page.links[index];
                    return _linkChip(link, playlistPage: _isPlaylistPage(page));
                  },
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemCount: page.links.length,
                ),
              ),
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
                          onPressed: () => unawaited(_loadUrl(page.url)),
                          child: Text(s.retry),
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
              child: page.videos.isEmpty
                  ? Center(child: Text(s.noResults))
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: .76,
                      ),
                      itemCount: page.videos.length,
                      itemBuilder: (context, index) => _VideoCard(
                        video: page.videos[index],
                        onTap: () => _openDetails(page.videos[index]),
                      ),
                    ),
            ),
            if (page.previousUrl != null || page.nextUrl != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: page.previousUrl == null
                            ? null
                            : () => _loadUrl(page.previousUrl!),
                        icon: const Icon(Icons.chevron_left),
                        label: Text(s.previousPage),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: page.nextUrl == null
                            ? null
                            : () => _loadUrl(page.nextUrl!),
                        icon: const Icon(Icons.chevron_right),
                        label: Text(s.nextPage),
                      ),
                    ),
                  ],
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
    final title = _page?.title.isNotEmpty == true ? _page!.title : s.navVideos;
    final page = LibraryPageScaffold(
      title: title,
      searchHint: s.videoSearchHint,
      onSearch: _search,
      drawerChildren: _drawer(),
      body: _content(s),
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
    super.dispose();
  }
}

class _VideoCard extends StatelessWidget {
  const _VideoCard({required this.video, required this.onTap});

  final VideoItem video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 5,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (video.cover.isNotEmpty)
                    Image.network(
                      video.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: Colors.black12,
                        child: Center(child: Icon(Icons.movie_outlined)),
                      ),
                    )
                  else
                    const ColoredBox(
                      color: Colors.black12,
                      child: Center(child: Icon(Icons.movie_outlined)),
                    ),
                  if (video.durationSeconds != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .7),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          child: Text(
                            _durationLabel(video.durationSeconds!),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _durationLabel(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainder = seconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = remainder.toString().padLeft(2, '0');
  return hours == 0 ? '$mm:$ss' : '$hours:$mm:$ss';
}

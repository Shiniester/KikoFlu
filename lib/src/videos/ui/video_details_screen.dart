import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../providers/works_provider.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/app_navigation_scope.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/work_detail_route_readiness.dart';
import '../../widgets/work_detail/work_detail_section_title.dart';
import '../../widgets/work_detail/work_title_header.dart';
import '../missav_client.dart';
import '../missav_verification.dart';
import '../video_download_task.dart';
import '../video_downloads.dart';
import '../video_library.dart';
import '../video_models.dart';
import '../video_providers.dart';
import '../video_player_platform.dart';
import 'video_account_screen.dart';
import 'video_collection_view.dart';
import 'video_playback_panel.dart';
import 'video_screen.dart';

class VideoDetailsScreen extends ConsumerStatefulWidget {
  const VideoDetailsScreen({
    super.key,
    required this.video,
    this.downloadedTask,
    this.sessionFactory,
    this.platformFactory,
    this.autoPlayVideo = false,
  });

  final VideoItem video;
  final VideoDownloadTask? downloadedTask;
  final VideoPlaybackSessionFactory? sessionFactory;
  final VideoPlayerPlatform Function()? platformFactory;
  final bool autoPlayVideo;

  @override
  ConsumerState<VideoDetailsScreen> createState() => _VideoDetailsScreenState();
}

class _VideoDetailsScreenState extends ConsumerState<VideoDetailsScreen>
    with SingleTickerProviderStateMixin {
  final WorkDetailRouteReadiness _routeReadiness = WorkDetailRouteReadiness();
  late final MissavClient _client;
  late final VideoLibrary _library;
  late final VideoDownloads _downloads;
  VideoDetails? _details;
  VideoDownloadTask? _downloadedTask;
  VideoStream? _selectedStream;
  bool _loading = true;
  bool _favorite = false;
  bool _savingFavorite = false;
  String? _error;
  MissavVerificationRequiredException? _verificationError;
  bool _verifyingAccess = false;
  bool _accountChangedDuringVerification = false;
  int _loadGeneration = 0;
  bool _accountWasLoggedIn = false;
  String? _accountName;
  late int _sessionGeneration;
  bool _fullscreen = false;
  late final AnimationController _fullscreenTransition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final Animation<double> _fullscreenProgressAnimation =
      _fullscreenTransition.drive(CurveTween(curve: Curves.easeInOut));
  GlobalKey _playerKey = GlobalKey();
  final ScrollController _portraitDetailsController = ScrollController();
  final ScrollController _landscapeDetailsController = ScrollController();

  double get _fullscreenProgress => _fullscreenProgressAnimation.value;

  VideoDownloadTask? get _availableTask =>
      widget.downloadedTask ??
      _downloads.forVideo(widget.video.id) ??
      _downloadedTask;

  // Keep the source chosen at load time when a background download completes.
  bool get _isOffline =>
      _downloadedTask?.status == VideoDownloadStatus.completed &&
      _downloadedTask?.localPath?.isNotEmpty == true;

  @override
  void initState() {
    super.initState();
    _client = ref.read(videoClientProvider);
    _library = ref.read(videoLibraryProvider);
    _downloads = ref.read(videoDownloadsProvider);
    _accountWasLoggedIn = _client.isLoggedIn;
    _accountName = _client.accountName;
    _sessionGeneration = _client.sessionGeneration;
    _client.addListener(_onClientChanged);
    _scheduleInitialize();
  }

  void _scheduleInitialize() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initialize());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.orientationOf(context) != Orientation.landscape ||
        MediaQuery.disableAnimationsOf(context)) {
      final target = _fullscreen ? 1.0 : 0.0;
      if (_fullscreenTransition.value != target) {
        // The shell listens to this animation above the route.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _fullscreenTransition.value = _fullscreen ? 1 : 0;
        });
      }
    }
    _routeReadiness.bind(
      route: ModalRoute.of(context),
      navigator: Navigator.maybeOf(context),
    );
  }

  void _onClientChanged() {
    final isLoggedIn = _client.isLoggedIn;
    final accountName = _client.accountName;
    final sessionChanged = _sessionGeneration != _client.sessionGeneration;
    if (!sessionChanged &&
        isLoggedIn == _accountWasLoggedIn &&
        accountName == _accountName) {
      return;
    }
    _sessionGeneration = _client.sessionGeneration;
    _accountWasLoggedIn = isLoggedIn;
    _accountName = accountName;
    if (!mounted || _isOffline) return;
    if (_verifyingAccess) {
      _loadGeneration++;
      _accountChangedDuringVerification = true;
      return;
    }

    if (_loading && !sessionChanged) return;
    _loadGeneration++;
    unawaited(_reloadAfterClientChanged());
  }

  Future<void> _reloadAfterClientChanged() async {
    final generation = _loadGeneration;
    if (!await _waitForRouteIdle(generation)) return;
    setState(() {
      _details = null;
      _favorite = false;
      _selectedStream = null;
      _error = null;
      _verificationError = null;
      _loading = true;
    });
    await _initialize();
  }

  Future<bool> _waitForRouteIdle(int generation) async {
    if (!mounted || generation != _loadGeneration) return false;
    final ready = await _routeReadiness.waitForIdle();
    return ready && mounted && generation == _loadGeneration;
  }

  Future<void> _initialize({VideoDetails? supplement}) async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _verificationError = null;
    });
    if (!await _waitForRouteIdle(generation)) return;
    try {
      await Future.wait([_library.initialize(), _downloads.initialize()]);
      if (!await _waitForRouteIdle(generation)) return;
      final task = supplement != null
          ? _downloadedTask
          : widget.downloadedTask ?? _downloads.forVideo(widget.video.id);
      if (supplement == null &&
          task?.status == VideoDownloadStatus.completed &&
          task?.localPath?.isNotEmpty == true) {
        setState(() {
          _downloadedTask = task;
          _details = VideoDetails(
            video: task!.video,
            actors: task.video.actors,
            tags: task.video.tags,
            metadata: {
              if (task.video.releaseDate != null)
                S.of(context).releaseDateInfo: task.video.releaseDate!,
            },
          );
          _loading = false;
        });
        return;
      }
      await _client.initialize();
      if (!await _waitForRouteIdle(generation)) return;
      Future<void> onReady(VideoDetails details) async {
        if (!await _waitForRouteIdle(generation)) return;
        setState(() {
          _downloadedTask = task;
          _details = details;
          _favorite = details.isFavorite ?? false;
          if (!details.streams.contains(_selectedStream)) {
            _selectedStream = details.streams.isEmpty
                ? null
                : details.streams.first;
          }
        });
      }

      final details = supplement == null
          ? await _client.details(widget.video, onReady: onReady)
          : await _client.supplementDetails(supplement, onReady: onReady);
      if (!await _waitForRouteIdle(generation)) return;
      setState(() {
        _downloadedTask = task;
        _details = details;
        _favorite = details.isFavorite ?? false;
        if (!details.streams.contains(_selectedStream)) {
          _selectedStream = details.streams.isEmpty
              ? null
              : details.streams.first;
        }
        _loading = false;
      });
    } catch (error) {
      if (!await _waitForRouteIdle(generation)) return;
      setState(() {
        _loading = false;
        _error = error.toString();
        _verificationError = error is MissavVerificationRequiredException
            ? error
            : null;
      });
    }
  }

  @override
  void didUpdateWidget(VideoDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.id != widget.video.id ||
        oldWidget.downloadedTask != widget.downloadedTask) {
      if (oldWidget.video.id != widget.video.id) {
        _playerKey = GlobalKey();
        _fullscreen = false;
        _fullscreenTransition.value = 0;
      }
      _loadGeneration++;
      _scheduleInitialize();
    }
  }

  @override
  void dispose() {
    _client.removeListener(_onClientChanged);
    _routeReadiness.dispose();
    _fullscreenTransition.dispose();
    _portraitDetailsController.dispose();
    _landscapeDetailsController.dispose();
    super.dispose();
  }

  Future<void> _openSource([String? url]) async {
    final uri = Uri.tryParse(url ?? widget.video.pageUrl);
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).videoSourceUnavailable)),
      );
    }
  }

  Future<void> _verifyAndRetry() async {
    if (_verifyingAccess) return;
    final verification =
        _verificationError ??
        MissavVerificationRequiredException(sourceUrl: widget.video.pageUrl);
    _verifyingAccess = true;
    var verified = false;
    try {
      verified = await verifyMissavAccess(
        context,
        _client,
        sourceUrl: verification.sourceUrl ?? widget.video.pageUrl,
      );
    } catch (_) {
      verified = false;
    } finally {
      _verifyingAccess = false;
    }
    if (!await _routeReadiness.waitForIdle() || !mounted) return;
    if (_accountChangedDuringVerification) {
      _accountChangedDuringVerification = false;
      if (!verified) {
        setState(() {
          _details = null;
          _favorite = false;
          _selectedStream = null;
          _loading = false;
          _error = verification.toString();
          _verificationError = verification;
        });
        return;
      }
      setState(() {
        _details = null;
        _favorite = false;
        _selectedStream = null;
        _error = null;
        _verificationError = null;
        _loading = true;
      });
    } else if (!verified) {
      return;
    }
    await _initialize();
  }

  Future<void> _sourceFallback([String? url]) async {
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
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(
                pushBottomDockRoute(
                  this.context,
                  builder: (_) => const VideoAccountScreen(),
                ),
              );
            },
            child: Text(s.login),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(_openSource());
            },
            child: Text(s.videoOpenSource),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleFavorite() async {
    final details = _details;
    if (details == null || _isOffline || _savingFavorite) return;
    if (!_client.isLoggedIn) {
      await _loginRequired();
      return;
    }
    final favorite = !_favorite;
    setState(() => _savingFavorite = true);
    try {
      await _client.setVideoFavorite(details, favorite);
      if (mounted && identical(_details, details)) {
        setState(() => _favorite = favorite);
      }
    } on MissavAuthenticationException {
      await _loginRequired();
    } on MissavException catch (error) {
      await _sourceFallback(error.sourceUrl ?? widget.video.pageUrl);
    } catch (_) {
      await _sourceFallback(widget.video.pageUrl);
    } finally {
      if (mounted) setState(() => _savingFavorite = false);
    }
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
      await _sourceFallback(error.sourceUrl ?? actor.url);
    } catch (_) {
      await _sourceFallback(actor.url);
    }
  }

  Widget _actorChip(VideoLink actor) {
    final s = S.of(context);
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      button: true,
      child: PopupMenuButton<String>(
        tooltip: actor.label,
        onSelected: (action) {
          switch (action) {
            case 'open':
              unawaited(_openCatalog(actor));
              break;
            case 'favorite':
              unawaited(_setActorFavorite(actor, true));
              break;
            case 'unfavorite':
              unawaited(_setActorFavorite(actor, false));
              break;
            case 'source':
              unawaited(_openSource(actor.url));
              break;
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: 'open', child: Text(s.videoCatalog)),
          PopupMenuItem(
            value: 'favorite',
            enabled: !_loading,
            child: Text(s.videoFavoriteActor),
          ),
          PopupMenuItem(
            value: 'unfavorite',
            enabled: !_loading,
            child: Text(s.videoUnfavoriteActor),
          ),
          PopupMenuItem(value: 'source', child: Text(s.videoOpenSource)),
        ],
        child: _metadataPill(
          actor.label,
          colors.tertiaryContainer,
          colors.onTertiaryContainer,
        ),
      ),
    );
  }

  List<_VideoMetadataSection> _metadataSections(S s, VideoDetails details) {
    final genres = <VideoLink>[];
    final makers = <VideoLink>[];
    final labels = <VideoLink>[];
    final series = <VideoLink>[];
    for (final link in [...details.tags, ...details.video.tags]) {
      switch (link.cardMetadataRoute) {
        case 'makers':
          makers.add(link);
          break;
        case 'labels':
          labels.add(link);
          break;
        case 'series':
          series.add(link);
          break;
        case 'directors':
          break;
        default:
          genres.add(link);
          break;
      }
    }

    List<VideoLink> entries(Iterable<VideoLink> links) {
      final values = <String, VideoLink>{};
      for (final link in links) {
        final label = link.label.trim();
        if (label.isEmpty || link.url.trim().isEmpty) continue;
        values.putIfAbsent(label, () => link);
      }
      return values.values.toList();
    }

    return [
      _VideoMetadataSection(
        s.videoDetailCreators,
        _VideoMetadataTone.secondary,
        [...entries(makers), ...entries(labels), ...entries(series)],
      ),
      _VideoMetadataSection(
        s.videoDetailActors,
        _VideoMetadataTone.tertiary,
        entries([...details.actors, ...details.video.actors]),
        isActors: true,
      ),
      _VideoMetadataSection(
        s.tagLabel,
        _VideoMetadataTone.primary,
        entries(genres),
      ),
    ].where((section) => section.entries.isNotEmpty).toList();
  }

  Widget _metadataChip(VideoLink entry, _VideoMetadataTone tone) {
    final entryTone = entry.cardMetadataRoute == 'series'
        ? _VideoMetadataTone.error
        : tone;
    final colors = Theme.of(context).colorScheme;
    final background = switch (entryTone) {
      _VideoMetadataTone.primary => colors.primaryContainer,
      _VideoMetadataTone.secondary => colors.secondaryContainer,
      _VideoMetadataTone.tertiary => colors.tertiaryContainer,
      _VideoMetadataTone.error => colors.errorContainer,
    };
    final foreground = switch (entryTone) {
      _VideoMetadataTone.primary => colors.onPrimaryContainer,
      _VideoMetadataTone.secondary => colors.onSecondaryContainer,
      _VideoMetadataTone.tertiary => colors.onTertiaryContainer,
      _VideoMetadataTone.error => colors.onErrorContainer,
    };
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
    );
    return TextButton(
      onPressed: () => _openCatalog(entry),
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        minimumSize: Size.zero,
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        shape: shape,
      ),
      child: _metadataPill(entry.label.trim(), background, foreground),
    );
  }

  Widget _metadataPill(String label, Color background, Color foreground) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(6),
        ),
        child: _metadataText(label, foreground),
      );

  Widget _metadataText(String label, Color foreground) => Text(
    label,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: foreground,
      fontSize: 12,
      fontWeight: FontWeight.w500,
    ),
  );

  Future<void> _showPlaylists() async {
    if (!_client.isLoggedIn) {
      await _loginRequired();
      return;
    }
    List<VideoLink> playlists;
    try {
      playlists = await _client.playlistsFor(widget.video);
    } on MissavAuthenticationException {
      await _loginRequired();
      return;
    } on MissavException catch (error) {
      await _sourceFallback(error.sourceUrl ?? widget.video.pageUrl);
      return;
    } catch (_) {
      await _sourceFallback(widget.video.pageUrl);
      return;
    }
    if (!mounted) return;
    await showResponsiveBottomSheet<void>(
      context: context,
      builder: (_) => _PlaylistMenu(
        playlists: playlists,
        onMembershipChanged: (playlist, added) =>
            _setPlaylistMembership(playlist, added),
        onCreate: _createPlaylist,
        onOpenSource: () => _openSource(),
      ),
    );
  }

  Future<bool> _setPlaylistMembership(VideoLink playlist, bool added) async {
    try {
      if (added) {
        await _client.addToPlaylist(playlist, widget.video);
      } else {
        await _client.removeFromPlaylist(playlist, widget.video);
      }
      return true;
    } on MissavAuthenticationException {
      await _loginRequired();
    } on MissavException catch (error) {
      await _sourceFallback(error.sourceUrl ?? playlist.url);
    } catch (_) {
      await _sourceFallback(playlist.url);
    }
    return false;
  }

  Future<bool> _createPlaylist() async {
    final s = S.of(context);
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.videoCreatePlaylist),
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
    if (title == null || title.isEmpty) return false;
    try {
      await _client.createPlaylist(title);
      return true;
    } on MissavUnsupportedException catch (error) {
      await _sourceFallback(error.sourceUrl ?? widget.video.pageUrl);
    } on MissavException catch (error) {
      await _sourceFallback(error.sourceUrl ?? widget.video.pageUrl);
    } catch (_) {
      await _sourceFallback(widget.video.pageUrl);
    }
    return false;
  }

  Future<void> _download() async {
    final stream = _selectedStream;
    if (stream == null) return;
    try {
      await _downloads.add(_details?.video ?? widget.video, stream);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).videoDownloadQueued)),
      );
    } catch (_) {
      if (mounted) {
        await _sourceFallback(widget.video.pageUrl);
      }
    }
  }

  Future<void> _openCatalog(VideoLink link) => pushBottomDockRoute(
    context,
    builder: (_) => VideoScreen.catalog(url: link.url),
  );

  Future<void> _openRelated(VideoItem video, {bool autoPlay = false}) {
    Widget builder(BuildContext _) => VideoDetailsScreen(
      video: video,
      sessionFactory: widget.sessionFactory,
      platformFactory: widget.platformFactory,
      autoPlayVideo: autoPlay,
    );
    if (autoPlay) {
      return replaceWorkDetailRoute(context, builder: builder);
    }
    return pushWorkDetailRoute(context, builder: builder);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final details = _details;
    final extendLandscapeDetailsBehindAppBar =
        details != null &&
        MediaQuery.orientationOf(context) == Orientation.landscape;
    ref.watch(videoDownloadsProvider);
    final currentTask = _availableTask;
    return AnimatedBuilder(
      animation: _fullscreenTransition,
      builder: (context, child) => GlobalAudioPlayerWrapper(
        showMiniPlayer: !_fullscreen || !_fullscreenTransition.isCompleted,
        miniPlayerHeightFactor: 1 - _fullscreenProgress,
        child: child!,
      ),
      child: Scaffold(
        extendBodyBehindAppBar: extendLandscapeDetailsBehindAppBar,
        appBar: _fullscreen
            ? null
            : AppBar(
                title: Text(
                  details?.video.title ?? widget.video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [
                  if (!_isOffline)
                    IconButton(
                      tooltip: _favorite ? s.videoFavorites : s.videoFavorites,
                      onPressed:
                          details == null ||
                              _loading ||
                              _savingFavorite ||
                              (_client.isLoggedIn && details.isFavorite == null)
                          ? null
                          : _toggleFavorite,
                      icon: Icon(
                        _favorite ? Icons.bookmark : Icons.bookmark_outline,
                      ),
                    ),
                  if (!_isOffline)
                    IconButton(
                      tooltip: s.videoAddToPlaylist,
                      onPressed: details == null || _loading
                          ? null
                          : _showPlaylists,
                      icon: const Icon(Icons.playlist_add),
                    ),
                  if (!_isOffline)
                    IconButton(
                      tooltip: s.download,
                      onPressed: _loading || _selectedStream == null
                          ? null
                          : _download,
                      icon: Icon(
                        currentTask?.status == VideoDownloadStatus.completed
                            ? Icons.download_done
                            : Icons.download_outlined,
                      ),
                    ),
                  IconButton(
                    tooltip: s.videoOpenSource,
                    onPressed: () => _openSource(),
                    icon: const Icon(Icons.open_in_new),
                  ),
                ],
              ),
        body: _loading && details == null
            ? const Center(child: CircularProgressIndicator())
            : _error != null && details == null
            ? _buildLoadFailure(s)
            : details == null
            ? const SizedBox.shrink()
            : _buildDetails(s, details, currentTask),
      ),
    );
  }

  Widget _buildLoadFailure(S s) {
    final label = _verificationError != null
        ? s.videoVerificationRequired
        : _details != null
        ? s.loadFailed
        : s.videoLoadFailed;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => unawaited(_initialize(supplement: _details)),
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
                  onPressed: () => unawaited(_openSource()),
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

  Widget _buildDetails(S s, VideoDetails details, VideoDownloadTask? task) {
    final nextRelated = _firstRelated(details);
    final metadataSections = _metadataSections(s, details);
    final basicMetadata = details.metadata.entries.where(
      (entry) => !MissavClient.detailMetadataGroups.containsKey(
        entry.key.trim().toLowerCase(),
      ),
    );
    final detailsContent = <Widget>[
      if (!_loading && _error != null) _buildLoadFailure(s),
      const SizedBox(height: 16),
      WorkTitleHeader(title: details.video.title, showTranslateButton: false),
      if (basicMetadata.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final entry in basicMetadata)
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${entry.key}: ',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: entry.value),
                    ],
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontSize: 12),
                ),
            ],
          ),
        ),
      if (details.description.isNotEmpty) ...[
        const SizedBox(height: 16),
        WorkDetailSectionTitle(s.description),
        const SizedBox(height: 8),
        SelectableText(details.description),
      ],
      for (final section in metadataSections) ...[
        const SizedBox(height: 16),
        WorkDetailSectionTitle(section.title),
        const SizedBox(height: 8),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final entry in section.entries)
              section.isActors
                  ? _actorChip(entry)
                  : _metadataChip(entry, section.tone),
          ],
        ),
      ],
      if (details.related.isNotEmpty) ...[
        const SizedBox(height: 16),
        WorkDetailSectionTitle(s.videoRelated),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = (constraints.maxWidth / 180)
                .floor()
                .clamp(1, 4)
                .toInt();
            return MasonryGridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: details.related.length,
              crossAxisCount: columns,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              itemBuilder: (context, index) => VideoCard(
                video: details.related[index],
                layoutType: LayoutType.bigGrid,
                onTap: () => _openRelated(details.related[index]),
                onOpenLink: _openCatalog,
              ),
            );
          },
        ),
      ],
    ];
    final player = RepaintBoundary(
      child: VideoPlaybackPanel(
        key: _playerKey,
        videoId: details.video.id,
        title: details.video.title,
        autoPlayOnStart: widget.autoPlayVideo,
        onPlayNextRelated: nextRelated == null
            ? null
            : () => _openRelated(nextRelated, autoPlay: true),
        platform: widget.platformFactory?.call(),
        library: _library,
        streams: _isOffline ? const [] : details.streams,
        localPath: _isOffline ? task?.localPath : null,
        initialPosition: _library.positionFor(details.video.id),
        initialVolume: _library.volume,
        sessionFactory: widget.sessionFactory,
        onStreamChanged: (stream) => setState(() => _selectedStream = stream),
        onOpenSource: () => unawaited(_openSource()),
        onVerifyAccess: _isOffline ? null : _verifyAndRetry,
        onFullscreenChanged: (fullscreen) {
          if (mounted && _fullscreen != fullscreen) {
            final size = View.of(context).physicalSize;
            if (size.width > size.height &&
                !MediaQuery.disableAnimationsOf(context)) {
              if (fullscreen) {
                _fullscreenTransition.forward();
              } else {
                _fullscreenTransition.reverse();
              }
            } else {
              _fullscreenTransition.value = fullscreen ? 1 : 0;
            }
            setState(() => _fullscreen = fullscreen);
            AppNavigationScope.maybeOf(context)?.setFullscreen(
              ModalRoute.of(context)!,
              fullscreen,
              transition: _fullscreenProgressAnimation,
            );
          }
        },
      ),
    );
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final detailsSliver = SliverList(
      delegate: SliverChildListDelegate([
        for (final child in detailsContent)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: child,
          ),
      ]),
    );
    if (_fullscreen && !isLandscape) {
      return SizedBox.expand(child: player);
    }

    if (_fullscreen || isLandscape) {
      final inlineTop =
          MediaQuery.viewPaddingOf(context).top +
          (AppBarTheme.of(context).toolbarHeight ?? kToolbarHeight);
      final landscapeDetails = CustomScrollView(
        key: PageStorageKey('video-details-landscape-${details.video.id}'),
        controller: _landscapeDetailsController,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
            sliver: detailsSliver,
          ),
        ],
      );
      return LayoutBuilder(
        builder: (context, constraints) {
          final paneWidth = constraints.maxWidth * .4;
          final inlineHeight = constraints.maxHeight - inlineTop;
          final playerWidth = paneWidth < inlineHeight * 16 / 9
              ? paneWidth
              : inlineHeight * 16 / 9;
          final playerHeight = playerWidth * 9 / 16;
          final fullscreenRect = Offset.zero & constraints.biggest;
          final inlineRect = Rect.fromLTWH(
            (paneWidth - playerWidth) / 2,
            inlineTop + (inlineHeight - playerHeight) / 2,
            playerWidth,
            playerHeight,
          );
          return AnimatedBuilder(
            animation: _fullscreenTransition,
            builder: (context, _) {
              final inlineProgress = 1 - _fullscreenProgress;
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fromRect(
                    rect: Rect.lerp(
                      fullscreenRect,
                      inlineRect,
                      inlineProgress,
                    )!,
                    child: player,
                  ),
                  Positioned(
                    left:
                        constraints.maxWidth +
                        (paneWidth - constraints.maxWidth) * inlineProgress,
                    top: inlineTop,
                    width: constraints.maxWidth - paneWidth,
                    height: inlineHeight,
                    child: Offstage(
                      offstage:
                          _fullscreen && _fullscreenTransition.isCompleted,
                      child: Opacity(
                        opacity: inlineProgress,
                        child: landscapeDetails,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      );
    }

    return CustomScrollView(
      key: PageStorageKey('video-details-portrait-${details.video.id}'),
      controller: _portraitDetailsController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
          sliver: SliverToBoxAdapter(child: player),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            0,
            0,
            0,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          sliver: detailsSliver,
        ),
      ],
    );
  }

  VideoItem? _firstRelated(VideoDetails details) {
    for (final related in details.related) {
      if (related.id != details.video.id) return related;
    }
    return null;
  }
}

enum _VideoMetadataTone { primary, secondary, tertiary, error }

class _VideoMetadataSection {
  const _VideoMetadataSection(
    this.title,
    this.tone,
    this.entries, {
    this.isActors = false,
  });

  final String title;
  final _VideoMetadataTone tone;
  final List<VideoLink> entries;
  final bool isActors;
}

class _PlaylistMenu extends StatefulWidget {
  const _PlaylistMenu({
    required this.playlists,
    required this.onMembershipChanged,
    required this.onCreate,
    required this.onOpenSource,
  });

  final List<VideoLink> playlists;
  final Future<bool> Function(VideoLink playlist, bool added)
  onMembershipChanged;
  final Future<bool> Function() onCreate;
  final VoidCallback onOpenSource;

  @override
  State<_PlaylistMenu> createState() => _PlaylistMenuState();
}

class _PlaylistMenuState extends State<_PlaylistMenu> {
  late final List<VideoLink> _playlists = List.of(widget.playlists);
  final Set<String> _busy = {};

  Future<void> _setMembership(VideoLink playlist, bool added) async {
    final key = playlist.sourceKey;
    if (key == null || !_busy.add(key)) return;
    setState(() {});
    final succeeded = await widget.onMembershipChanged(playlist, added);
    if (!mounted) return;
    setState(() {
      _busy.remove(key);
      if (succeeded) {
        final index = _playlists.indexWhere((item) => item.sourceKey == key);
        if (index >= 0) {
          _playlists[index] = VideoLink(
            label: playlist.label,
            url: playlist.url,
            kind: playlist.kind,
            sourceKey: key,
            isAdded: added,
          );
        }
      }
    });
  }

  Future<void> _create() async {
    await widget.onCreate();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BottomSheetHeader(title: s.videoAddToPlaylist),
        if (_playlists.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Text(s.noResults),
          )
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final playlist in _playlists)
                  if (playlist.isAdded != null && playlist.sourceKey != null)
                    CheckboxListTile(
                      value: playlist.isAdded,
                      onChanged: _busy.contains(playlist.sourceKey)
                          ? null
                          : (value) => unawaited(
                              _setMembership(playlist, value ?? false),
                            ),
                      title: Text(playlist.label),
                      controlAffinity: ListTileControlAffinity.leading,
                      secondary: _busy.contains(playlist.sourceKey)
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : null,
                    )
                  else
                    ListTile(
                      title: Text(playlist.label),
                      subtitle: Text(s.videoSourceUnavailable),
                      trailing: IconButton(
                        tooltip: s.videoOpenSource,
                        onPressed: widget.onOpenSource,
                        icon: const Icon(Icons.open_in_new),
                      ),
                    ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: () => unawaited(_create()),
                icon: const Icon(Icons.add),
                label: Text(s.videoCreatePlaylist),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(s.confirm),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../missav_client.dart';
import '../video_download_task.dart';
import '../video_downloads.dart';
import '../video_library.dart';
import '../video_models.dart';
import '../video_providers.dart';
import 'video_account_screen.dart';
import 'video_playback_panel.dart';
import 'video_screen.dart';

class VideoDetailsScreen extends ConsumerStatefulWidget {
  const VideoDetailsScreen({
    super.key,
    required this.video,
    this.downloadedTask,
    this.sessionFactory,
  });

  final VideoItem video;
  final VideoDownloadTask? downloadedTask;
  final VideoPlaybackSessionFactory? sessionFactory;

  @override
  ConsumerState<VideoDetailsScreen> createState() => _VideoDetailsScreenState();
}

class _VideoDetailsScreenState extends ConsumerState<VideoDetailsScreen> {
  late final MissavClient _client;
  late final VideoLibrary _library;
  late final VideoDownloads _downloads;
  VideoDetails? _details;
  VideoDownloadTask? _downloadedTask;
  VideoStream? _selectedStream;
  bool _loading = true;
  bool _favorite = false;
  String? _error;
  int _loadGeneration = 0;
  bool _accountWasLoggedIn = false;
  String? _accountName;

  VideoDownloadTask? get _availableTask =>
      widget.downloadedTask ??
      _downloads.forVideo(widget.video.id) ??
      _downloadedTask;

  bool get _isOffline =>
      _availableTask?.status == VideoDownloadStatus.completed &&
      _availableTask?.localPath?.isNotEmpty == true;

  @override
  void initState() {
    super.initState();
    _client = ref.read(videoClientProvider);
    _library = ref.read(videoLibraryProvider);
    _downloads = ref.read(videoDownloadsProvider);
    _accountWasLoggedIn = _client.isLoggedIn;
    _accountName = _client.accountName;
    _client.addListener(_onClientChanged);
    _scheduleInitialize();
  }

  void _scheduleInitialize() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initialize());
    });
  }

  void _onClientChanged() {
    final isLoggedIn = _client.isLoggedIn;
    final accountName = _client.accountName;
    if (isLoggedIn == _accountWasLoggedIn && accountName == _accountName) {
      return;
    }
    _accountWasLoggedIn = isLoggedIn;
    _accountName = accountName;
    if (!mounted || _isOffline) return;

    final covered = ModalRoute.of(context)?.isCurrent == false;
    if (_loading && !covered) return;
    _loadGeneration++;
    setState(() {
      _details = null;
      _favorite = false;
      _selectedStream = null;
      _error = null;
      _loading = true;
    });
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Future.wait([_library.initialize(), _downloads.initialize()]);
      if (!mounted || generation != _loadGeneration) return;
      final task =
          widget.downloadedTask ?? _downloads.forVideo(widget.video.id);
      if (task?.status == VideoDownloadStatus.completed &&
          task?.localPath?.isNotEmpty == true) {
        setState(() {
          _downloadedTask = task;
          _details = VideoDetails(video: task!.video);
          _loading = false;
        });
        return;
      }
      await _client.initialize();
      if (!mounted || generation != _loadGeneration) return;
      final details = await _client.details(widget.video);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _downloadedTask = task;
        _details = details;
        _favorite = details.isFavorite ?? false;
        _selectedStream = details.streams.isEmpty
            ? null
            : details.streams.first;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  void didUpdateWidget(VideoDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.id != widget.video.id ||
        oldWidget.downloadedTask != widget.downloadedTask) {
      _loadGeneration++;
      _scheduleInitialize();
    }
  }

  @override
  void dispose() {
    _client.removeListener(_onClientChanged);
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
    if (details == null || _isOffline) return;
    if (!_client.isLoggedIn) {
      await _loginRequired();
      return;
    }
    try {
      await _client.setVideoFavorite(details, !_favorite);
      if (mounted) setState(() => _favorite = !_favorite);
    } on MissavAuthenticationException {
      await _loginRequired();
    } on MissavException catch (error) {
      await _sourceFallback(error.sourceUrl ?? widget.video.pageUrl);
    } catch (_) {
      await _sourceFallback(widget.video.pageUrl);
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
    return PopupMenuButton<String>(
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
        PopupMenuItem(value: 'favorite', child: Text(s.videoFavoriteActor)),
        PopupMenuItem(value: 'unfavorite', child: Text(s.videoUnfavoriteActor)),
        PopupMenuItem(value: 'source', child: Text(s.videoOpenSource)),
      ],
      child: Chip(label: Text(actor.label)),
    );
  }

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
    await showDialog<void>(
      context: context,
      builder: (_) => _PlaylistDialog(
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
      await _downloads.add(widget.video, stream);
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

  Future<void> _openRelated(VideoItem video) => pushWorkDetailRoute(
    context,
    builder: (_) => VideoDetailsScreen(video: video),
  );

  bool _isVerificationError(String value) {
    final normalized = value.toLowerCase();
    return normalized.contains('verif') ||
        normalized.contains('challenge') ||
        normalized.contains('captcha') ||
        normalized.contains('403');
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final details = _details;
    ref.watch(videoDownloadsProvider);
    final currentTask = _availableTask;
    return GlobalAudioPlayerWrapper.workDetails(
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            details?.video.title ?? widget.video.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (!_isOffline)
              IconButton(
                tooltip: _favorite ? s.videoFavorites : s.videoFavorites,
                onPressed: details == null ? null : _toggleFavorite,
                icon: Icon(_favorite ? Icons.bookmark : Icons.bookmark_outline),
              ),
            if (!_isOffline)
              IconButton(
                tooltip: s.videoAddToPlaylist,
                onPressed: details == null ? null : _showPlaylists,
                icon: const Icon(Icons.playlist_add),
              ),
            if (!_isOffline)
              IconButton(
                tooltip: s.download,
                onPressed: _selectedStream == null ? null : _download,
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
        body: _loading
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
    final label = _isVerificationError(_error!)
        ? s.videoVerificationRequired
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
                  onPressed: () => unawaited(_initialize()),
                  icon: const Icon(Icons.refresh),
                  label: Text(s.retry),
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

  Widget _buildDetails(S s, VideoDetails details, VideoDownloadTask? task) =>
      ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          VideoPlaybackPanel(
            key: ValueKey('video-player-${details.video.id}'),
            videoId: details.video.id,
            library: _library,
            streams: _isOffline ? const [] : details.streams,
            localPath: _isOffline ? task?.localPath : null,
            initialPosition: _library.positionFor(details.video.id),
            initialVolume: _library.volume,
            sessionFactory: widget.sessionFactory,
            onStreamChanged: (stream) =>
                setState(() => _selectedStream = stream),
            onOpenSource: () => unawaited(_openSource()),
          ),
          const SizedBox(height: 16),
          if (details.metadata.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in details.metadata.entries)
                  Chip(label: Text('${entry.key}: ${entry.value}')),
              ],
            ),
          if (details.description.isNotEmpty) ...[
            const SizedBox(height: 12),
            SelectableText(details.description),
          ],
          if (details.actors.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              s.videoActorFavorites,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final actor in details.actors) _actorChip(actor)],
            ),
          ],
          if (details.tags.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              s.videoCatalog,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in details.tags)
                  ActionChip(
                    label: Text(tag.label),
                    onPressed: () => _openCatalog(tag),
                  ),
              ],
            ),
          ],
          if (details.related.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(s.videoRelated, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = (constraints.maxWidth / 180)
                    .floor()
                    .clamp(1, 4)
                    .toInt();
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: details.related.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: .76,
                  ),
                  itemBuilder: (context, index) => _RelatedVideoCard(
                    video: details.related[index],
                    onTap: () => _openRelated(details.related[index]),
                  ),
                );
              },
            ),
          ],
        ],
      );
}

class _PlaylistDialog extends StatefulWidget {
  const _PlaylistDialog({
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
  State<_PlaylistDialog> createState() => _PlaylistDialogState();
}

class _PlaylistDialogState extends State<_PlaylistDialog> {
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
    return AlertDialog(
      title: Text(s.videoAddToPlaylist),
      content: SizedBox(
        width: 420,
        child: _playlists.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(s.noResults),
              )
            : ListView(
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
      actions: [
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
    );
  }
}

class _RelatedVideoCard extends StatelessWidget {
  const _RelatedVideoCard({required this.video, required this.onTap});

  final VideoItem video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 5,
            child: video.cover.isEmpty
                ? const ColoredBox(
                    color: Colors.black12,
                    child: Center(child: Icon(Icons.movie_outlined)),
                  )
                : Image.network(
                    video.cover,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: Colors.black12,
                      child: Center(child: Icon(Icons.movie_outlined)),
                    ),
                  ),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                video.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

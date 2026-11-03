import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/file_tree_utils.dart';
import '../../utils/snackbar_util.dart';
import '../../widgets/app_navigation_scope.dart';
import '../video_library.dart';
import '../video_models.dart';
import '../video_player_platform.dart';
import '../video_providers.dart';
import 'video_playback_panel.dart';

String workVideoPlaybackId({
  required String sourceIdentity,
  required int workId,
  required String fileIdentity,
}) =>
    'work:${Uri.encodeComponent(sourceIdentity)}:$workId:${Uri.encodeComponent(fileIdentity)}';

String workVideoSourceIdentity({
  required int workId,
  String? host,
  String? localPath,
  String? downloadUrl,
}) {
  if (workId < 0) return 'jp-asmr';
  if (localPath != null) {
    final uri = Uri.tryParse(downloadUrl ?? '');
    var marker = uri?.path.indexOf('/api/media/download/') ?? -1;
    if (marker < 0) {
      marker = uri?.path.indexOf('/api/media/stream/') ?? -1;
    }
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        marker < 0) {
      return 'local:$localPath';
    }
    host = '${uri.origin}${uri.path.substring(0, marker)}';
  }
  final value = host?.trim() ?? '';
  if (value.isNotEmpty) {
    final normalized = value.contains('://') ? value : 'https://$value';
    final uri = Uri.tryParse(normalized);
    if (uri != null && uri.host.isNotEmpty) {
      final basePath = uri.path.replaceFirst(RegExp(r'/+$'), '');
      return '${uri.origin.toLowerCase()}$basePath';
    }
    return value.toLowerCase();
  }
  return 'asmr-one';
}

@immutable
class WorkVideoPlaybackSource {
  const WorkVideoPlaybackSource({
    required this.videoId,
    required this.fileIdentity,
    required this.fileName,
    required this.folderPath,
    this.streams = const [],
    this.localPath,
  });

  final String videoId;
  final String fileIdentity;
  final String fileName;
  final String folderPath;
  final List<VideoStream> streams;
  final String? localPath;
}

typedef WorkVideoSiblingResolver =
    Future<WorkVideoPlaybackSource?> Function(
      BuildContext context,
      FileTreeVideoFile video,
    );

class WorkVideoPlaybackResolutionError implements Exception {
  const WorkVideoPlaybackResolutionError(this.message);

  final String message;
}

class WorkVideoPlaybackScreen extends ConsumerStatefulWidget {
  const WorkVideoPlaybackScreen({
    super.key,
    required this.videoId,
    required this.fileName,
    required this.folderPath,
    this.fileIdentity,
    this.streams = const [],
    this.localPath,
    this.siblingVideos = const [],
    this.resolveSibling,
    this.sessionFactory,
    this.platform,
  });

  final String videoId;
  final String fileName;
  final String folderPath;
  final String? fileIdentity;
  final List<VideoStream> streams;
  final String? localPath;
  final List<FileTreeVideoFile> siblingVideos;
  final WorkVideoSiblingResolver? resolveSibling;
  final VideoPlaybackSessionFactory? sessionFactory;
  final VideoPlayerPlatform? platform;

  @override
  ConsumerState<WorkVideoPlaybackScreen> createState() =>
      _WorkVideoPlaybackScreenState();
}

class _WorkVideoPlaybackScreenState
    extends ConsumerState<WorkVideoPlaybackScreen> {
  static const _playlistRowExtent = 64.0;

  final _playerKey = GlobalKey();
  final _scrollController = ScrollController();
  late WorkVideoPlaybackSource _current;
  late final VideoLibrary _library;
  late final Future<void> _libraryInitialization;
  AppNavigationController? _navigation;
  ModalRoute<dynamic>? _route;
  bool _fullscreen = false;
  String? _pendingFileIdentity;
  int _selectionGeneration = 0;
  double _rowExtent = _playlistRowExtent;
  double _playerHeight = 180;
  double _detailsHeight = 64;
  bool _detailsPinned = true;
  bool _initialScrollScheduled = false;

  @override
  void initState() {
    super.initState();
    _current = _sourceFromWidget();
    _library = ref.read(videoLibraryProvider);
    _libraryInitialization = _library.initialize();
  }

  WorkVideoPlaybackSource _sourceFromWidget() {
    final fileIdentity =
        widget.fileIdentity ??
        FileTreeUtils.itemPath(widget.folderPath, {'title': widget.fileName});
    return WorkVideoPlaybackSource(
      videoId: widget.videoId,
      fileIdentity: fileIdentity,
      fileName: widget.fileName,
      folderPath: widget.folderPath,
      streams: widget.streams,
      localPath: widget.localPath,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigation = AppNavigationScope.maybeOf(context);
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    _route = route;
    if (route == null) return;
    unawaited(
      route.popped.then((_) {
        if (!mounted || !identical(_route, route)) return;
        _selectionGeneration++;
        _pendingFileIdentity = null;
      }),
    );
  }

  @override
  void didUpdateWidget(WorkVideoPlaybackScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.fileIdentity != widget.fileIdentity ||
        oldWidget.localPath != widget.localPath ||
        oldWidget.fileName != widget.fileName ||
        oldWidget.folderPath != widget.folderPath) {
      _selectionGeneration++;
      _current = _sourceFromWidget();
      _pendingFileIdentity = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrentVideo();
      });
    }
  }

  void _setFullscreen(bool fullscreen) {
    if (_fullscreen == fullscreen) return;
    _fullscreen = fullscreen;
    final route = _route;
    if (route != null) _navigation?.setFullscreen(route, fullscreen);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _selectionGeneration++;
    _scrollController.dispose();
    final route = _route;
    if (_fullscreen && route != null) _navigation?.setFullscreen(route, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _libraryInitialization,
    builder: (context, snapshot) {
      return Scaffold(
        appBar: _fullscreen
            ? null
            : AppBar(title: Text(S.of(context).navVideos)),
        body: _fullscreen
            ? SizedBox.expand(child: _buildReadyContent(context, snapshot))
            : SafeArea(
                key: const ValueKey('work-video-screen-safe-area'),
                child: _buildReadyContent(context, snapshot),
              ),
      );
    },
  );

  Widget _buildReadyContent(
    BuildContext context,
    AsyncSnapshot<void> snapshot,
  ) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_initialScrollScheduled) {
      _initialScrollScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrentVideo();
      });
    }
    return _buildPlayerContent(context, initialVolume: _library.volume);
  }

  Widget _buildPlayerContent(
    BuildContext context, {
    required double initialVolume,
  }) {
    final player = VideoPlaybackPanel(
      key: _playerKey,
      videoId: _current.videoId,
      library: _library,
      title: _current.fileName,
      autoPlayOnStart: true,
      streams: _current.streams,
      localPath: _current.localPath,
      initialPosition: _library.positionFor(_current.videoId),
      initialVolume: initialVolume,
      sessionFactory: widget.sessionFactory,
      platform: widget.platform,
      appTabIndex: appAudioTabIndex,
      allowAutomaticFullscreen: false,
      savePositionOnSourceChange: true,
      onFullscreenChanged: _setFullscreen,
    );

    if (_fullscreen) return player;

    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final detailsHeight = math.max(64.0, 44 * textScale + 20);
        final compactRowExtent = math.max(48.0, 16 * textScale + 16);
        final maxPlayerHeight = math.min(
          math.max(
            0.0,
            constraints.maxHeight -
                (widget.siblingVideos.isEmpty ? 0.0 : compactRowExtent),
          ),
          math.max(120.0, constraints.maxHeight * .65),
        );
        final minPlayerWidth = math.min(320.0, constraints.maxWidth);
        final playerWidth = math.min(
          constraints.maxWidth,
          math.max(minPlayerWidth, maxPlayerHeight * 16 / 9),
        );
        final playerHeight = math.min(maxPlayerHeight, playerWidth * 9 / 16);
        final preferredRowExtent = math.max(
          _playlistRowExtent,
          16 * textScale + 32,
        );
        final rowExtent = math.min(
          preferredRowExtent,
          math.max(compactRowExtent, constraints.maxHeight - playerHeight),
        );
        final detailsPinned =
            playerHeight + detailsHeight + rowExtent <= constraints.maxHeight;
        final geometryChanged =
            _rowExtent != rowExtent ||
            _playerHeight != playerHeight ||
            _detailsHeight != detailsHeight ||
            _detailsPinned != detailsPinned;
        _playerHeight = playerHeight;
        _detailsHeight = detailsHeight;
        _detailsPinned = detailsPinned;
        if (_rowExtent != rowExtent) {
          _rowExtent = rowExtent;
        }
        if (geometryChanged) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToCurrentVideo();
          });
        }
        final fileDetails = SizedBox(
          height: detailsHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    _current.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  _current.folderPath.isEmpty
                      ? S.of(context).rootDirectory
                      : _current.folderPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
        return CustomScrollView(
          key: const ValueKey('work-video-playlist-scroll-view'),
          controller: _scrollController,
          slivers: [
            PinnedHeaderSliver(
              child: SizedBox(
                key: const ValueKey('work-video-playlist-pinned-header'),
                height: playerHeight + (detailsPinned ? detailsHeight : 0),
                child: ColoredBox(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: Column(
                    children: [
                      SizedBox(
                        height: playerHeight,
                        child: Center(
                          child: SizedBox(
                            width: playerWidth,
                            height: playerHeight,
                            child: player,
                          ),
                        ),
                      ),
                      if (detailsPinned) fileDetails,
                    ],
                  ),
                ),
              ),
            ),
            if (!detailsPinned) SliverToBoxAdapter(child: fileDetails),
            SliverFixedExtentList.builder(
              key: const ValueKey('work-video-playlist'),
              itemExtent: rowExtent,
              itemCount: widget.siblingVideos.length,
              itemBuilder: (context, index) =>
                  _buildPlaylistItem(context, widget.siblingVideos[index]),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPlaylistItem(BuildContext context, FileTreeVideoFile video) {
    final fileIdentity = FileTreeUtils.itemPath(video.parentPath, video.file);
    final title = FileTreeUtils.titleOf(video.file);
    final isCurrent = fileIdentity == _current.fileIdentity;
    final isPending = fileIdentity == _pendingFileIdentity;
    return ListTile(
      key: ValueKey('work-video-playlist-$fileIdentity'),
      selected: isCurrent,
      dense: _rowExtent <= 48,
      minTileHeight: _rowExtent,
      leading: isPending
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(isCurrent ? Icons.play_arrow : Icons.video_library),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => unawaited(_selectVideo(video, fileIdentity)),
    );
  }

  Future<void> _selectVideo(
    FileTreeVideoFile video,
    String fileIdentity,
  ) async {
    if (fileIdentity == _current.fileIdentity) {
      _selectionGeneration++;
      if (_pendingFileIdentity != null) {
        setState(() => _pendingFileIdentity = null);
      }
      return;
    }
    final resolver = widget.resolveSibling;
    if (resolver == null) return;

    final generation = ++_selectionGeneration;
    setState(() => _pendingFileIdentity = fileIdentity);
    try {
      final resolved = await resolver(context, video);
      if (!mounted || generation != _selectionGeneration) return;
      setState(() {
        if (resolved != null) _current = resolved;
        _pendingFileIdentity = null;
      });
      if (resolved != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToCurrentVideo();
        });
      }
    } catch (error) {
      if (!mounted || generation != _selectionGeneration) return;
      setState(() => _pendingFileIdentity = null);
      if (error is WorkVideoPlaybackResolutionError) {
        SnackBarUtil.showError(context, error.message);
      } else {
        SnackBarUtil.showError(context, S.of(context).videoPlaybackFailed);
      }
    }
  }

  void _scrollToCurrentVideo() {
    if (!mounted || !_scrollController.hasClients) return;
    final index = widget.siblingVideos.indexWhere(
      (video) =>
          FileTreeUtils.itemPath(video.parentPath, video.file) ==
          _current.fileIdentity,
    );
    if (index < 0) return;
    final position = _scrollController.position;
    final headerHeight = _playerHeight + (_detailsPinned ? _detailsHeight : 0);
    final listContentOffset =
        (_detailsPinned ? 0 : _detailsHeight) + index * _rowExtent;
    final itemTop =
        headerHeight +
        (_detailsPinned ? 0 : _detailsHeight) +
        index * _rowExtent;
    final viewportTop = position.pixels + headerHeight;
    final viewportBottom = position.pixels + position.viewportDimension;
    if (itemTop >= viewportTop && itemTop + _rowExtent <= viewportBottom) {
      return;
    }
    final offset = listContentOffset
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    if ((position.pixels - offset).abs() > 1) {
      _scrollController.jumpTo(offset);
    }
  }
}

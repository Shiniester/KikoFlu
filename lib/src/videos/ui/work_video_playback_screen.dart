import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
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

class WorkVideoPlaybackScreen extends ConsumerStatefulWidget {
  const WorkVideoPlaybackScreen({
    super.key,
    required this.videoId,
    required this.fileName,
    required this.folderPath,
    this.streams = const [],
    this.localPath,
    this.sessionFactory,
    this.platform,
  });

  final String videoId;
  final String fileName;
  final String folderPath;
  final List<VideoStream> streams;
  final String? localPath;
  final VideoPlaybackSessionFactory? sessionFactory;
  final VideoPlayerPlatform? platform;

  @override
  ConsumerState<WorkVideoPlaybackScreen> createState() =>
      _WorkVideoPlaybackScreenState();
}

class _WorkVideoPlaybackScreenState
    extends ConsumerState<WorkVideoPlaybackScreen> {
  final _playerKey = GlobalKey();
  late final VideoLibrary _library;
  late final Future<void> _libraryInitialization;
  AppNavigationController? _navigation;
  ModalRoute<dynamic>? _route;
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _library = ref.read(videoLibraryProvider);
    _libraryInitialization = _library.initialize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigation = AppNavigationScope.maybeOf(context);
    _route = ModalRoute.of(context);
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
    return _buildPlayerContent(
      context,
      initialPosition: snapshot.hasError
          ? Duration.zero
          : _library.positionFor(widget.videoId),
      initialVolume: _library.volume,
    );
  }

  Widget _buildPlayerContent(
    BuildContext context, {
    required Duration initialPosition,
    required double initialVolume,
  }) {
    final player = VideoPlaybackPanel(
      key: _playerKey,
      videoId: widget.videoId,
      library: _library,
      title: widget.fileName,
      autoPlayOnStart: true,
      streams: widget.streams,
      localPath: widget.localPath,
      initialPosition: initialPosition,
      initialVolume: initialVolume,
      sessionFactory: widget.sessionFactory,
      platform: widget.platform,
      appTabIndex: appAudioTabIndex,
      allowAutomaticFullscreen: false,
      onFullscreenChanged: _setFullscreen,
    );

    if (_fullscreen) return player;

    return LayoutBuilder(
      builder: (context, constraints) {
        final detailsHeight = (constraints.maxHeight * .28)
            .clamp(100.0, 200.0)
            .toDouble();
        final playerWidth = math.min(
          constraints.maxWidth,
          math.max(320.0, (constraints.maxHeight - detailsHeight) * 16 / 9),
        );
        final playerHeight = playerWidth * 9 / 16;
        final playerSection = Center(
          child: SizedBox(
            width: playerWidth,
            height: playerHeight,
            child: player,
          ),
        );
        final details = Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  widget.fileName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.folderPath.isEmpty
                    ? S.of(context).rootDirectory
                    : widget.folderPath,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
        if (playerHeight + detailsHeight <= constraints.maxHeight) {
          return Column(
            children: [
              playerSection,
              Expanded(child: SingleChildScrollView(child: details)),
            ],
          );
        }
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [playerSection, details],
          ),
        );
      },
    );
  }
}

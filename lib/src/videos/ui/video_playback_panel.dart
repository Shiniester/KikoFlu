import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/proxy_config.dart';
import '../video_library.dart';
import '../video_models.dart';

class VideoPlaybackTrack {
  const VideoPlaybackTrack({required this.id, required this.label});

  final String id;
  final String label;
}

@immutable
class VideoPlaybackSnapshot {
  const VideoPlaybackSnapshot({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.rate = 1,
    this.error,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final double rate;
  final String? error;
  final List<VideoPlaybackTrack> audioTracks;
  final List<VideoPlaybackTrack> subtitleTracks;

  VideoPlaybackSnapshot copyWith({
    Duration? position,
    Duration? duration,
    bool? playing,
    bool? buffering,
    double? rate,
    String? error,
    bool clearError = false,
    List<VideoPlaybackTrack>? audioTracks,
    List<VideoPlaybackTrack>? subtitleTracks,
  }) => VideoPlaybackSnapshot(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    rate: rate ?? this.rate,
    error: clearError ? null : error ?? this.error,
    audioTracks: audioTracks ?? this.audioTracks,
    subtitleTracks: subtitleTracks ?? this.subtitleTracks,
  );
}

abstract interface class VideoPlaybackSession {
  ValueListenable<VideoPlaybackSnapshot> get snapshot;

  Widget buildSurface({required double aspectRatio});

  Future<void> loadStream(
    VideoStream stream, {
    required Duration position,
    required double volume,
  });

  Future<void> loadFile(
    String path, {
    required Duration position,
    required double volume,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> selectAudioTrack(String id);
  Future<void> selectSubtitleTrack(String id);
  Future<void> dispose();
}

typedef VideoPlaybackSessionFactory = VideoPlaybackSession Function();

class MediaKitVideoPlaybackSession implements VideoPlaybackSession {
  MediaKitVideoPlaybackSession({Player? player})
    : _player = player ?? Player() {
    _controller = VideoController(_player);
    _subscriptions.addAll([
      _player.stream.position.listen(
        (value) => _update((old) => old.copyWith(position: value)),
      ),
      _player.stream.duration.listen(
        (value) => _update((old) => old.copyWith(duration: value)),
      ),
      _player.stream.playing.listen(
        (value) => _update((old) => old.copyWith(playing: value)),
      ),
      _player.stream.buffering.listen(
        (value) => _update((old) => old.copyWith(buffering: value)),
      ),
      _player.stream.rate.listen(
        (value) => _update((old) => old.copyWith(rate: value)),
      ),
      _player.stream.tracks.listen(_updateTracks),
      _player.stream.error.listen(
        (value) => _update((old) => old.copyWith(error: value)),
      ),
    ]);

    final proxy = ProxyConfig.httpsProxyUrl;
    final platform = _player.platform;
    if (proxy != null && platform is NativePlayer) {
      _configureProxy = platform.setProperty('http-proxy', proxy);
    }
  }

  final Player _player;
  late final VideoController _controller;
  final ValueNotifier<VideoPlaybackSnapshot> _snapshot = ValueNotifier(
    const VideoPlaybackSnapshot(),
  );
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _configureProxy = Future.value();
  double _rate = 1;
  bool _disposed = false;

  @override
  ValueListenable<VideoPlaybackSnapshot> get snapshot => _snapshot;

  @override
  Widget buildSurface({required double aspectRatio}) => Video(
    controller: _controller,
    aspectRatio: aspectRatio,
    controls: NoVideoControls,
    pauseUponEnteringBackgroundMode: false,
    resumeUponEnteringForegroundMode: false,
  );

  @override
  Future<void> loadStream(
    VideoStream stream, {
    required Duration position,
    required double volume,
  }) async {
    _update((old) => old.copyWith(clearError: true));
    await _configureProxy;
    final platform = _player.platform;
    if (defaultTargetPlatform == TargetPlatform.windows &&
        platform is NativePlayer) {
      await platform.setProperty('load-unsafe-playlists', 'no');
    }
    await _player.setVolume(volume.clamp(0, 100).toDouble());
    await _player.open(
      Media(
        stream.url,
        httpHeaders: stream.headers,
        start: position > Duration.zero ? position : null,
      ),
      play: false,
    );
    await _player.setRate(_rate);
  }

  @override
  Future<void> loadFile(
    String path, {
    required Duration position,
    required double volume,
  }) async {
    _update((old) => old.copyWith(clearError: true));
    await _configureProxy;
    await _player.setVolume(volume.clamp(0, 100).toDouble());
    // media_kit's Windows long-path prefix breaks relative HLS URLs.
    final isWindowsHls =
        defaultTargetPlatform == TargetPlatform.windows &&
        path.toLowerCase().endsWith('.m3u8');
    final platform = _player.platform;
    if (defaultTargetPlatform == TargetPlatform.windows &&
        platform is NativePlayer) {
      // Only the app-generated local HLS manifest may use the lavf protocol.
      await platform.setProperty(
        'load-unsafe-playlists',
        isWindowsHls ? 'yes' : 'no',
      );
    }
    final resource = isWindowsHls
        ? 'lavf://file:${path.replaceAll(r'\', '/')}'
        : path;
    await _player.open(
      Media(resource, start: position > Duration.zero ? position : null),
      play: false,
    );
    await _player.setRate(_rate);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    await _player.setRate(rate);
  }

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0, 100).toDouble());

  @override
  Future<void> selectAudioTrack(String id) async {
    final track = _player.state.tracks.audio.firstWhere(
      (track) => track.id == id,
    );
    await _player.setAudioTrack(track);
  }

  @override
  Future<void> selectSubtitleTrack(String id) async {
    final track = _player.state.tracks.subtitle.firstWhere(
      (track) => track.id == id,
    );
    await _player.setSubtitleTrack(track);
  }

  void _updateTracks(Tracks tracks) {
    final audio = tracks.audio
        .where((track) => track.id != 'auto' && track.id != 'no')
        .map(
          (track) => VideoPlaybackTrack(
            id: track.id,
            label: track.title?.isNotEmpty == true
                ? track.title!
                : track.language?.isNotEmpty == true
                ? track.language!
                : track.id,
          ),
        )
        .toList();
    final subtitles = tracks.subtitle
        .where((track) => track.id != 'auto' && track.id != 'no')
        .map(
          (track) => VideoPlaybackTrack(
            id: track.id,
            label: track.title?.isNotEmpty == true
                ? track.title!
                : track.language?.isNotEmpty == true
                ? track.language!
                : track.id,
          ),
        )
        .toList();
    _update(
      (old) => old.copyWith(audioTracks: audio, subtitleTracks: subtitles),
    );
  }

  void _update(VideoPlaybackSnapshot Function(VideoPlaybackSnapshot) update) {
    if (!_disposed) _snapshot.value = update(_snapshot.value);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    _snapshot.dispose();
  }
}

class VideoPlaybackPanel extends StatefulWidget {
  const VideoPlaybackPanel({
    super.key,
    required this.videoId,
    required this.library,
    this.streams = const [],
    this.localPath,
    this.initialPosition = Duration.zero,
    this.initialVolume = 100,
    this.sessionFactory,
    this.onStreamChanged,
    this.onOpenSource,
  });

  final String videoId;
  final VideoLibrary library;
  final List<VideoStream> streams;
  final String? localPath;
  final Duration initialPosition;
  final double initialVolume;
  final VideoPlaybackSessionFactory? sessionFactory;
  final ValueChanged<VideoStream>? onStreamChanged;
  final VoidCallback? onOpenSource;

  @override
  State<VideoPlaybackPanel> createState() => _VideoPlaybackPanelState();
}

class _VideoPlaybackPanelState extends State<VideoPlaybackPanel>
    with WidgetsBindingObserver {
  late final VideoPlaybackSession _session;
  final ValueNotifier<int> _uiRevision = ValueNotifier(0);
  late double _volume;
  late int _streamIndex;
  late Future<void> _loadTail;
  Timer? _saveTimer;
  Duration? _pendingLoadPosition;
  Duration _pendingLoadBasePosition = Duration.zero;
  ModalRoute<dynamic>? _route;
  bool _loading = true;
  bool _fullscreen = false;
  bool _routeCovered = false;
  bool _appSuspended = false;
  bool _disposed = false;
  bool _sourceLoaded = false;
  int _pauseGeneration = 0;
  int _loadGeneration = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _session = widget.sessionFactory?.call() ?? MediaKitVideoPlaybackSession();
    _session.snapshot.addListener(_onSnapshotChanged);
    _volume = widget.initialVolume.clamp(0, 100).toDouble();
    _streamIndex = 0;
    _loadTail = Future<void>.value();
    WidgetsBinding.instance.addObserver(this);
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_savePosition());
    });
    unawaited(_loadSource(position: widget.initialPosition));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    _route?.secondaryAnimation?.removeListener(_onRouteTransition);
    _route = route;
    _route?.secondaryAnimation?.addListener(_onRouteTransition);
  }

  @override
  void didUpdateWidget(VideoPlaybackPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.localPath != widget.localPath ||
        !listEquals(oldWidget.streams, widget.streams)) {
      if (oldWidget.videoId != widget.videoId) _sourceLoaded = false;
      _streamIndex = 0;
      unawaited(_loadSource(position: widget.initialPosition));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appSuspended = state != AppLifecycleState.resumed;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_pauseAndSave());
    }
  }

  void _onRouteTransition() {
    final route = _route;
    if (route == null) return;
    if (route.isCurrent && (route.secondaryAnimation?.value ?? 0) == 0) {
      _routeCovered = false;
      return;
    }
    if (_fullscreen || route.isCurrent || _routeCovered) return;
    if ((route.secondaryAnimation?.value ?? 0) > 0) {
      _routeCovered = true;
      unawaited(_pauseAndSave());
    }
  }

  Future<void> _loadSource({required Duration position, bool resume = false}) {
    final generation = ++_loadGeneration;
    final pauseGeneration = _pauseGeneration;
    _updatePlayerState(() {
      _loading = true;
      _error = null;
    });
    final operation = _loadTail.then((_) async {
      if (_disposed || generation != _loadGeneration) return;
      _pendingLoadPosition = position > Duration.zero ? position : null;
      _pendingLoadBasePosition = _session.snapshot.value.position;
      if (widget.localPath != null) {
        await _session.loadFile(
          widget.localPath!,
          position: position,
          volume: _volume,
        );
      } else {
        if (widget.streams.isEmpty) return;
        final stream = widget.streams[_streamIndex];
        await _session.loadStream(stream, position: position, volume: _volume);
      }
      if (_disposed || generation != _loadGeneration) return;
      _sourceLoaded = true;
      _onSnapshotChanged();
      if (resume &&
          pauseGeneration == _pauseGeneration &&
          !_routeCovered &&
          !_appSuspended) {
        await _session.play();
      }
      if (!mounted || generation != _loadGeneration) return;
      _updatePlayerState(() => _loading = false);
    });
    _loadTail = operation.catchError((Object error, StackTrace stackTrace) {
      if (!mounted || generation != _loadGeneration) return;
      _updatePlayerState(() {
        _loading = false;
        _error = error.toString();
      });
    });
    return _loadTail;
  }

  Future<void> _invoke(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      _updatePlayerState(() => _error = error.toString());
    }
  }

  Future<void> _setRate(double value) => _invoke(() => _session.setRate(value));

  void _onSnapshotChanged() {
    final pending = _pendingLoadPosition;
    if (pending == null) return;
    final snapshot = _session.snapshot.value;
    if (snapshot.position >= pending &&
        (snapshot.position == pending ||
            snapshot.position != _pendingLoadBasePosition)) {
      _pendingLoadPosition = null;
    }
  }

  Future<void> _selectStream(int index) async {
    if (index < 0 || index >= widget.streams.length || index == _streamIndex) {
      return;
    }
    final previousIndex = _streamIndex;
    final position = _session.snapshot.value.position;
    final resume = _session.snapshot.value.playing;
    _updatePlayerState(() => _streamIndex = index);
    widget.onStreamChanged?.call(widget.streams[index]);
    await _loadSource(position: position, resume: resume);
    if (_error != null && mounted) {
      _updatePlayerState(() => _streamIndex = previousIndex);
      widget.onStreamChanged?.call(widget.streams[previousIndex]);
    }
  }

  Future<void> _setVolume(double value) async {
    final volume = value.clamp(0, 100).toDouble();
    _updatePlayerState(() => _volume = volume);
    await _invoke(() => _session.setVolume(_volume));
  }

  Future<void> _persistVolume(double value) async {
    try {
      await widget.library.setVolume(value);
    } catch (error) {
      if (mounted) _updatePlayerState(() => _error = error.toString());
    }
  }

  Future<void> _pauseAndSave() async {
    _pauseGeneration++;
    try {
      await _session.pause();
    } catch (_) {
      // A player that failed to open still needs its last known position saved.
    }
    await _savePosition();
  }

  void _updatePlayerState(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _uiRevision.value++;
  }

  Future<void> _savePosition() {
    if (!_sourceLoaded && _pendingLoadPosition == null) return Future.value();
    return widget.library.savePosition(
      widget.videoId,
      _pendingLoadPosition ?? _session.snapshot.value.position,
    );
  }

  Future<void> _enterFullscreen() async {
    if (_fullscreen || !mounted) return;
    _updatePlayerState(() => _fullscreen = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (fullScreenContext, animation, secondaryAnimation) =>
            Scaffold(
              backgroundColor: Colors.black,
              body: SafeArea(
                child: ValueListenableBuilder<int>(
                  valueListenable: _uiRevision,
                  builder: (context, _, _) => _buildPlayerLayout(
                    fullScreenContext,
                    fullscreen: true,
                    onFullscreen: () => Navigator.of(fullScreenContext).pop(),
                  ),
                ),
              ),
            ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
    if (mounted) _updatePlayerState(() => _fullscreen = false);
  }

  Widget _buildPlayerLayout(
    BuildContext context, {
    required bool fullscreen,
    required VoidCallback onFullscreen,
  }) => Center(
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: _session.buildSurface(aspectRatio: 16 / 9),
          ),
          ValueListenableBuilder<VideoPlaybackSnapshot>(
            valueListenable: _session.snapshot,
            builder: (context, snapshot, _) {
              if (_loading || snapshot.buffering) {
                return const Center(
                  child: CircularProgressIndicator(
                    key: ValueKey('video-playback-loading'),
                    color: Colors.white,
                  ),
                );
              }
              if (_error != null || snapshot.error != null) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        S.of(context).videoPlaybackFailed,
                        style: const TextStyle(color: Colors.white),
                      ),
                      IconButton(
                        tooltip: S.of(context).retry,
                        color: Colors.white,
                        icon: const Icon(Icons.refresh),
                        onPressed: () => unawaited(
                          _loadSource(
                            position: snapshot.position,
                            resume: snapshot.playing,
                          ),
                        ),
                      ),
                      if (widget.onOpenSource != null)
                        TextButton.icon(
                          onPressed: widget.onOpenSource,
                          icon: const Icon(Icons.open_in_new),
                          label: Text(S.of(context).videoOpenSource),
                        ),
                    ],
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              tooltip: S.of(context).videoFullscreen,
              color: Colors.white,
              icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
              onPressed: onFullscreen,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildControls(context, fullscreen: fullscreen),
          ),
        ],
      ),
    ),
  );

  Widget _buildControls(BuildContext context, {required bool fullscreen}) =>
      ValueListenableBuilder<VideoPlaybackSnapshot>(
        valueListenable: _session.snapshot,
        builder: (context, snapshot, _) {
          final durationMs = snapshot.duration.inMilliseconds;
          final positionMs = snapshot.position.inMilliseconds
              .clamp(0, durationMs > 0 ? durationMs : 0)
              .toDouble();
          final s = S.of(context);
          return Material(
            color: Colors.black.withValues(alpha: .72),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: fullscreen ? 18 : 8,
                vertical: fullscreen ? 8 : 4,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        _formatTime(snapshot.position),
                        style: const TextStyle(color: Colors.white),
                      ),
                      Expanded(
                        child: Slider(
                          min: 0,
                          max: durationMs > 0 ? durationMs.toDouble() : 1,
                          value: durationMs > 0 ? positionMs : 0,
                          onChanged: durationMs <= 0
                              ? null
                              : (value) => unawaited(
                                  _invoke(
                                    () => _session.seek(
                                      Duration(milliseconds: value.round()),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      Text(
                        _formatTime(snapshot.duration),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 0,
                    runSpacing: 0,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      IconButton(
                        tooltip: snapshot.playing ? s.pause : s.videoPlay,
                        color: Colors.white,
                        icon: Icon(
                          snapshot.playing ? Icons.pause : Icons.play_arrow,
                        ),
                        onPressed: () {
                          _routeCovered = false;
                          unawaited(
                            _invoke(
                              snapshot.playing ? _session.pause : _session.play,
                            ),
                          );
                        },
                      ),
                      if (widget.streams.length > 1)
                        PopupMenuButton<int>(
                          tooltip: s.videoQuality,
                          initialValue: _streamIndex,
                          icon: const Icon(
                            Icons.high_quality_outlined,
                            color: Colors.white,
                          ),
                          onSelected: (index) =>
                              unawaited(_selectStream(index)),
                          itemBuilder: (context) => [
                            for (
                              var index = 0;
                              index < widget.streams.length;
                              index++
                            )
                              PopupMenuItem(
                                value: index,
                                child: Text(widget.streams[index].label),
                              ),
                          ],
                        ),
                      if (snapshot.audioTracks.length > 1)
                        PopupMenuButton<String>(
                          tooltip: s.audioFormatPreference,
                          icon: const Icon(
                            Icons.audiotrack_outlined,
                            color: Colors.white,
                          ),
                          onSelected: (id) => unawaited(
                            _invoke(() => _session.selectAudioTrack(id)),
                          ),
                          itemBuilder: (context) => [
                            for (final track in snapshot.audioTracks)
                              PopupMenuItem(
                                value: track.id,
                                child: Text(track.label),
                              ),
                          ],
                        ),
                      if (snapshot.subtitleTracks.isNotEmpty)
                        PopupMenuButton<String>(
                          tooltip: s.videoSubtitle,
                          icon: const Icon(
                            Icons.subtitles_outlined,
                            color: Colors.white,
                          ),
                          onSelected: (id) => unawaited(
                            _invoke(() => _session.selectSubtitleTrack(id)),
                          ),
                          itemBuilder: (context) => [
                            for (final track in snapshot.subtitleTracks)
                              PopupMenuItem(
                                value: track.id,
                                child: Text(track.label),
                              ),
                          ],
                        ),
                      PopupMenuButton<double>(
                        tooltip: s.playbackSpeed,
                        initialValue: snapshot.rate,
                        icon: Text(
                          '${snapshot.rate}×',
                          style: const TextStyle(color: Colors.white),
                        ),
                        onSelected: (rate) => unawaited(_setRate(rate)),
                        itemBuilder: (context) => [
                          for (final rate in const [
                            0.5,
                            0.75,
                            1.0,
                            1.25,
                            1.5,
                            2.0,
                          ])
                            PopupMenuItem(value: rate, child: Text('$rate×')),
                        ],
                      ),
                      SizedBox(
                        width: 136,
                        child: Row(
                          children: [
                            Tooltip(
                              message: s.volume,
                              child: const Icon(
                                Icons.volume_down,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                key: const ValueKey('video-volume-slider'),
                                min: 0,
                                max: 100,
                                value: _volume,
                                onChanged: (value) =>
                                    unawaited(_setVolume(value)),
                                onChangeEnd: (value) =>
                                    unawaited(_persistVolume(value)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    if (widget.localPath == null && widget.streams.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(S.of(context).videoNoStreams),
              if (widget.onOpenSource != null)
                TextButton.icon(
                  onPressed: widget.onOpenSource,
                  icon: const Icon(Icons.open_in_new),
                  label: Text(S.of(context).videoOpenSource),
                ),
            ],
          ),
        ),
      );
    }
    if (_fullscreen) {
      return const ColoredBox(
        key: ValueKey('video-fullscreen-placeholder'),
        color: Colors.black,
      );
    }
    return _buildPlayerLayout(
      context,
      fullscreen: false,
      onFullscreen: _enterFullscreen,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    _saveTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _route?.secondaryAnimation?.removeListener(_onRouteTransition);
    _session.snapshot.removeListener(_onSnapshotChanged);
    _uiRevision.dispose();
    unawaited(_disposeSession());
    super.dispose();
  }

  Future<void> _disposeSession() async {
    try {
      await _pauseAndSave();
    } catch (_) {}
    try {
      await _loadTail;
    } finally {
      try {
        await _session.dispose();
      } catch (_) {}
    }
  }
}

String _formatTime(Duration duration) {
  final seconds = duration.inSeconds;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainingSeconds = seconds % 60;
  final minuteText = minutes.toString().padLeft(2, '0');
  final secondText = remainingSeconds.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:$minuteText:$secondText'
      : '$minuteText:$secondText';
}

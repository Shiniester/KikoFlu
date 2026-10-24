import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
    if (platform is NativePlayer) {
      final uri = Uri.parse(stream.url);
      await platform.setProperty(
        'http-proxy',
        ProxyConfig.findProxyFor(uri) == 'DIRECT'
            ? ''
            : ProxyConfig.httpsProxyUrl ?? '',
      );
    }
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
    this.onVerifyAccess,
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
  final Future<void> Function()? onVerifyAccess;

  @override
  State<VideoPlaybackPanel> createState() => _VideoPlaybackPanelState();
}

class _VideoPlaybackPanelState extends State<VideoPlaybackPanel>
    with WidgetsBindingObserver {
  late final VideoPlaybackSession _session;
  final ValueNotifier<int> _uiRevision = ValueNotifier(0);
  final FocusNode _focusNode = FocusNode(debugLabel: 'Video player');
  late double _volume;
  late int _streamIndex;
  late Future<void> _loadTail;
  Future<void> _rateTail = Future<void>.value();
  Timer? _saveTimer;
  Timer? _controlsTimer;
  Duration? _pendingLoadPosition;
  Duration? _seekPreview;
  Duration? _dragStartPosition;
  double? _dragStartX;
  Duration _pendingLoadBasePosition = Duration.zero;
  ModalRoute<dynamic>? _route;
  PageRoute<void>? _fullscreenRoute;
  double? _temporaryRate;
  bool _controlsVisible = true;
  bool _controlsInteracting = false;
  bool _lastPlaying = false;
  bool _lastBuffering = false;
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
      _stopTemporaryRate();
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
      _stopTemporaryRate();
      _controlsTimer?.cancel();
      _showControls();
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
      _stopTemporaryRate();
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
      _updatePlayerState(() {
        _loading = false;
        _controlsVisible = true;
      });
      _scheduleControlsHide();
    });
    _loadTail = operation.catchError((Object error, StackTrace stackTrace) {
      if (!mounted || generation != _loadGeneration) return;
      _controlsTimer?.cancel();
      _updatePlayerState(() {
        _loading = false;
        _error = error.toString();
        _controlsVisible = true;
      });
    });
    return _loadTail;
  }

  Future<void> _invoke(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      _controlsTimer?.cancel();
      _updatePlayerState(() {
        _error = error.toString();
        _controlsVisible = true;
      });
    }
  }

  Future<void> _setRate(double value) => _queueRate(value);

  Future<void> _queueRate(double rate) {
    final operation = _rateTail.then((_) => _session.setRate(rate));
    _rateTail = operation.catchError((Object error, StackTrace stackTrace) {
      if (!mounted) return;
      _controlsTimer?.cancel();
      _updatePlayerState(() {
        _error = error.toString();
        _controlsVisible = true;
      });
    });
    return _rateTail;
  }

  void _startTemporaryRate() {
    if (_temporaryRate != null || !_session.snapshot.value.playing) return;
    _temporaryRate = _session.snapshot.value.rate;
    _showControls();
    unawaited(_queueRate(2));
  }

  void _stopTemporaryRate() {
    final rate = _temporaryRate;
    if (rate == null) return;
    _temporaryRate = null;
    unawaited(_queueRate(rate));
    _scheduleControlsHide();
  }

  bool _canHideControls(VideoPlaybackSnapshot snapshot) =>
      snapshot.playing &&
      !_loading &&
      !_controlsInteracting &&
      !snapshot.buffering &&
      snapshot.error == null &&
      _error == null &&
      _temporaryRate == null &&
      _seekPreview == null;

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!_canHideControls(_session.snapshot.value)) return;
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _canHideControls(_session.snapshot.value)) {
        _updatePlayerState(() => _controlsVisible = false);
      }
    });
  }

  void _beginControlsInteraction() {
    _controlsInteracting = true;
    _controlsTimer?.cancel();
    if (!_controlsVisible) _updatePlayerState(() => _controlsVisible = true);
  }

  void _endControlsInteraction() {
    if (!_controlsInteracting) return;
    _controlsInteracting = false;
    _scheduleControlsHide();
  }

  void _showControls() {
    if (!_controlsVisible) _updatePlayerState(() => _controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleControls() {
    final snapshot = _session.snapshot.value;
    if (!_canHideControls(snapshot)) {
      _showControls();
      return;
    }
    if (_controlsVisible) {
      _controlsTimer?.cancel();
      _updatePlayerState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  Duration _clampPosition(Duration position, Duration duration) => Duration(
    milliseconds: position.inMilliseconds
        .clamp(0, duration.inMilliseconds > 0 ? duration.inMilliseconds : 0)
        .toInt(),
  );

  void _startSurfaceSeek() {
    _previewSeek(_dragStartPosition);
  }

  void _updateSurfaceSeek(double dx, double width) {
    final startX = _dragStartX;
    final startPosition = _dragStartPosition;
    final duration = _session.snapshot.value.duration;
    if (startX == null || startPosition == null || width <= 0) return;
    final dragDuration = duration < const Duration(seconds: 120)
        ? duration
        : const Duration(seconds: 120);
    final delta = Duration(
      milliseconds: ((dx - startX) / width * dragDuration.inMilliseconds)
          .round(),
    );
    _previewSeek(_clampPosition(startPosition + delta, duration));
  }

  void _previewSeek(Duration? position) {
    if (position == null) return;
    _controlsTimer?.cancel();
    _updatePlayerState(() {
      _seekPreview = position;
      _controlsVisible = true;
    });
  }

  void _finishSeek([Duration? position]) {
    final target = position ?? _seekPreview;
    if (target == null) return;
    final clamped = _clampPosition(target, _session.snapshot.value.duration);
    _updatePlayerState(() {
      _seekPreview = null;
      _dragStartX = null;
      _dragStartPosition = null;
    });
    unawaited(_invoke(() => _session.seek(clamped)));
    _scheduleControlsHide();
  }

  void _cancelSeekPreview() {
    if (_seekPreview == null) return;
    _updatePlayerState(() {
      _seekPreview = null;
      _dragStartX = null;
      _dragStartPosition = null;
    });
    _scheduleControlsHide();
  }

  void _togglePlayback() {
    final snapshot = _session.snapshot.value;
    if (_error != null || snapshot.error != null) return;
    _routeCovered = false;
    unawaited(_invoke(snapshot.playing ? _session.pause : _session.play));
    _showControls();
  }

  KeyEventResult _handlePlayerKey(
    KeyEvent event, {
    required bool fullscreen,
    required VoidCallback onFullscreen,
  }) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final snapshot = _session.snapshot.value;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        _togglePlayback();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowRight:
        if (snapshot.duration <= Duration.zero) return KeyEventResult.handled;
        final base = _seekPreview ?? snapshot.position;
        final amount = Duration(
          seconds: event.logicalKey == LogicalKeyboardKey.arrowLeft ? -5 : 5,
        );
        _finishSeek(base + amount);
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        onFullscreen();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (fullscreen) onFullscreen();
        return fullscreen ? KeyEventResult.handled : KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _onSnapshotChanged() {
    final snapshot = _session.snapshot.value;
    if (snapshot.playing != _lastPlaying) {
      _lastPlaying = snapshot.playing;
      if (snapshot.playing) {
        _controlsVisible = true;
        _scheduleControlsHide();
      } else {
        _controlsTimer?.cancel();
        if (!_controlsVisible && mounted) {
          _updatePlayerState(() => _controlsVisible = true);
        }
      }
    }
    if (snapshot.buffering != _lastBuffering) {
      _lastBuffering = snapshot.buffering;
      if (snapshot.buffering) {
        _controlsTimer?.cancel();
        if (!_controlsVisible && mounted) {
          _updatePlayerState(() => _controlsVisible = true);
        }
      } else if (snapshot.playing) {
        _controlsVisible = true;
        _scheduleControlsHide();
      }
    }
    if (snapshot.error != null) {
      _controlsTimer?.cancel();
      if (!_controlsVisible && mounted) {
        _updatePlayerState(() => _controlsVisible = true);
      }
    }
    final pending = _pendingLoadPosition;
    if (pending == null) return;
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
      if (mounted) {
        _controlsTimer?.cancel();
        _updatePlayerState(() {
          _error = error.toString();
          _controlsVisible = true;
        });
      }
    }
  }

  Future<void> _pauseAndSave() async {
    _pauseGeneration++;
    _controlsInteracting = false;
    _stopTemporaryRate();
    _controlsTimer?.cancel();
    try {
      await _rateTail;
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
    _stopTemporaryRate();
    _endControlsInteraction();
    _cancelSeekPreview();
    _controlsTimer?.cancel();
    _updatePlayerState(() => _fullscreen = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final route = PageRouteBuilder<void>(
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
    );
    _fullscreenRoute = route;
    try {
      final popped = Navigator.of(context).push<void>(route);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        _focusNode.requestFocus();
        _showControls();
      }
      await popped;
      await route.completed;
    } finally {
      _stopTemporaryRate();
      _endControlsInteraction();
      _cancelSeekPreview();
      if (identical(_fullscreenRoute, route)) _fullscreenRoute = null;
      if (mounted) {
        _updatePlayerState(() => _fullscreen = false);
        _focusNode.requestFocus();
        _scheduleControlsHide();
      }
    }
  }

  Future<void> _verifyAccess() async {
    final onVerifyAccess = widget.onVerifyAccess;
    if (onVerifyAccess == null) return;
    final route = _fullscreenRoute;
    if (route != null) {
      if (route.isCurrent) Navigator.of(context).pop();
      await route.completed;
    }
    if (mounted) await _invoke(onVerifyAccess);
  }

  Widget _buildPlayerLayout(
    BuildContext context, {
    required bool fullscreen,
    required VoidCallback onFullscreen,
  }) => Focus(
    key: const ValueKey('video-player-focus'),
    focusNode: _focusNode,
    autofocus: fullscreen,
    onKeyEvent: (node, event) => _handlePlayerKey(
      event,
      fullscreen: fullscreen,
      onFullscreen: onFullscreen,
    ),
    child: Listener(
      onPointerDown: (_) => _focusNode.requestFocus(),
      onPointerCancel: (_) {
        _endControlsInteraction();
        _cancelSeekPreview();
      },
      child: MouseRegion(
        onHover: (_) => _showControls(),
        child: Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    key: const ValueKey('video-gesture-surface'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleControls,
                    onDoubleTap: _togglePlayback,
                    onHorizontalDragStart: (_) => _startSurfaceSeek(),
                    onHorizontalDragUpdate: (details) => _updateSurfaceSeek(
                      details.localPosition.dx,
                      constraints.maxWidth,
                    ),
                    onHorizontalDragEnd: (_) => _finishSeek(),
                    onHorizontalDragCancel: _cancelSeekPreview,
                    onLongPressStart: (_) => _startTemporaryRate(),
                    onLongPressEnd: (_) => _stopTemporaryRate(),
                    onLongPressCancel: _stopTemporaryRate,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) {
                        final snapshot = _session.snapshot.value;
                        _dragStartX = event.localPosition.dx;
                        _dragStartPosition = snapshot.duration > Duration.zero
                            ? _clampPosition(
                                snapshot.position,
                                snapshot.duration,
                              )
                            : null;
                      },
                      onPointerUp: (_) {
                        if (_seekPreview == null) {
                          _dragStartX = null;
                          _dragStartPosition = null;
                        }
                      },
                      onPointerCancel: (_) {
                        _cancelSeekPreview();
                        _dragStartX = null;
                        _dragStartPosition = null;
                      },
                      child: ColoredBox(
                        color: Colors.black,
                        child: _session.buildSurface(aspectRatio: 16 / 9),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<VideoPlaybackSnapshot>(
                    valueListenable: _session.snapshot,
                    builder: (context, snapshot, _) {
                      if (_error != null || snapshot.error != null) {
                        return Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(8, 52, 8, 4),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  S.of(context).videoPlaybackFailed,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white),
                                ),
                                Wrap(
                                  alignment: WrapAlignment.center,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
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
                                    if (widget.onVerifyAccess != null)
                                      TextButton.icon(
                                        onPressed: () =>
                                            unawaited(_verifyAccess()),
                                        icon: const Icon(
                                          Icons.verified_user_outlined,
                                        ),
                                        label: Text(
                                          S.of(context).videoVerifyAccess,
                                        ),
                                      ),
                                    if (widget.onOpenSource != null)
                                      TextButton.icon(
                                        onPressed: widget.onOpenSource,
                                        icon: const Icon(Icons.open_in_new),
                                        label: Text(
                                          S.of(context).videoOpenSource,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      if (_loading || snapshot.buffering) {
                        return const Center(
                          child: CircularProgressIndicator(
                            key: ValueKey('video-playback-loading'),
                            color: Colors.white,
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                  ValueListenableBuilder<VideoPlaybackSnapshot>(
                    valueListenable: _session.snapshot,
                    builder: (context, snapshot, _) {
                      final hasError = _error != null || snapshot.error != null;
                      final controlsVisible =
                          _controlsVisible ||
                          !snapshot.playing ||
                          _loading ||
                          snapshot.buffering ||
                          hasError;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          if (controlsVisible)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.black.withValues(alpha: .42),
                                        Colors.transparent,
                                        Colors.transparent,
                                        Colors.black.withValues(alpha: .78),
                                      ],
                                      stops: const [0, .2, .58, 1],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: IgnorePointer(
                              ignoring: !controlsVisible,
                              child: AnimatedOpacity(
                                key: const ValueKey('video-fullscreen-control'),
                                opacity: controlsVisible ? 1 : 0,
                                duration: const Duration(milliseconds: 180),
                                child: IconButton(
                                  tooltip: S.of(context).videoFullscreen,
                                  color: Colors.white,
                                  icon: Icon(
                                    fullscreen
                                        ? Icons.fullscreen_exit
                                        : Icons.fullscreen,
                                  ),
                                  onPressed: onFullscreen,
                                ),
                              ),
                            ),
                          ),
                          if (!hasError)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: IgnorePointer(
                                ignoring: !controlsVisible,
                                child: AnimatedOpacity(
                                  key: const ValueKey('video-controls'),
                                  opacity: controlsVisible ? 1 : 0,
                                  duration: const Duration(milliseconds: 180),
                                  child: _buildControls(
                                    context,
                                    fullscreen: fullscreen,
                                    snapshot: snapshot,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildControls(
    BuildContext context, {
    required bool fullscreen,
    required VideoPlaybackSnapshot snapshot,
  }) {
    final durationMs = snapshot.duration.inMilliseconds;
    final currentPosition = _seekPreview ?? snapshot.position;
    final position = _clampPosition(currentPosition, snapshot.duration);
    final positionMs = position.inMilliseconds.toDouble();
    final s = S.of(context);
    return Material(
      color: Colors.transparent,
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
                  _formatTime(position),
                  style: const TextStyle(color: Colors.white),
                ),
                Expanded(
                  child: Slider(
                    key: const ValueKey('video-position-slider'),
                    min: 0,
                    max: durationMs > 0 ? durationMs.toDouble() : 1,
                    value: durationMs > 0 ? positionMs : 0,
                    onChangeStart: durationMs <= 0
                        ? null
                        : (_) => _beginControlsInteraction(),
                    onChanged: durationMs <= 0
                        ? null
                        : (value) => _previewSeek(
                            Duration(milliseconds: value.round()),
                          ),
                    onChangeEnd: durationMs <= 0
                        ? null
                        : (_) {
                            _finishSeek();
                            _endControlsInteraction();
                          },
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
                  icon: Icon(snapshot.playing ? Icons.pause : Icons.play_arrow),
                  onPressed: _togglePlayback,
                ),
                if (widget.streams.length > 1)
                  PopupMenuButton<int>(
                    tooltip: s.videoQuality,
                    initialValue: _streamIndex,
                    icon: const Icon(
                      Icons.high_quality_outlined,
                      color: Colors.white,
                    ),
                    onOpened: _beginControlsInteraction,
                    onCanceled: _endControlsInteraction,
                    onSelected: (index) {
                      _endControlsInteraction();
                      unawaited(_selectStream(index));
                    },
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
                    onOpened: _beginControlsInteraction,
                    onCanceled: _endControlsInteraction,
                    onSelected: (id) {
                      _endControlsInteraction();
                      unawaited(_invoke(() => _session.selectAudioTrack(id)));
                    },
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
                    onOpened: _beginControlsInteraction,
                    onCanceled: _endControlsInteraction,
                    onSelected: (id) {
                      _endControlsInteraction();
                      unawaited(
                        _invoke(() => _session.selectSubtitleTrack(id)),
                      );
                    },
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
                  onOpened: _beginControlsInteraction,
                  onCanceled: _endControlsInteraction,
                  onSelected: (rate) {
                    _endControlsInteraction();
                    unawaited(_setRate(rate));
                  },
                  itemBuilder: (context) => [
                    for (final rate in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
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
                          onChangeStart: (_) => _beginControlsInteraction(),
                          onChanged: (value) => unawaited(_setVolume(value)),
                          onChangeEnd: (value) {
                            _endControlsInteraction();
                            unawaited(_persistVolume(value));
                          },
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
  }

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
    _controlsInteracting = false;
    _stopTemporaryRate();
    _disposed = true;
    _loadGeneration++;
    _saveTimer?.cancel();
    _controlsTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _route?.secondaryAnimation?.removeListener(_onRouteTransition);
    _session.snapshot.removeListener(_onSnapshotChanged);
    _focusNode.dispose();
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
      await _rateTail;
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

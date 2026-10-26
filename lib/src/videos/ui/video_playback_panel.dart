import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../l10n/app_localizations.dart';
import '../../services/proxy_config.dart';
import '../../widgets/image_save_service.dart';
import '../../widgets/responsive_dialog.dart';
import '../video_library.dart';
import '../video_models.dart';
import '../video_playback_settings.dart';
import '../video_player_platform.dart';
import '../video_sleep_timer.dart';
import '../video_super_resolution.dart';
import 'video_sleep_timer_sheet.dart';
import 'video_playback_settings_screen.dart';

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
    this.bufferPosition = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.rate = 1,
    this.error,
    this.audioTracks = const [],
    this.selectedAudioTrackId,
    this.subtitleTracks = const [],
  });

  final Duration position;
  final Duration duration;
  final Duration bufferPosition;
  final bool playing;
  final bool buffering;
  final bool completed;
  final double rate;
  final String? error;
  final List<VideoPlaybackTrack> audioTracks;
  final String? selectedAudioTrackId;
  final List<VideoPlaybackTrack> subtitleTracks;

  VideoPlaybackSnapshot copyWith({
    Duration? position,
    Duration? duration,
    Duration? bufferPosition,
    bool? playing,
    bool? buffering,
    bool? completed,
    double? rate,
    String? error,
    bool clearError = false,
    List<VideoPlaybackTrack>? audioTracks,
    String? selectedAudioTrackId,
    List<VideoPlaybackTrack>? subtitleTracks,
  }) => VideoPlaybackSnapshot(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    bufferPosition: bufferPosition ?? this.bufferPosition,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    completed: completed ?? this.completed,
    rate: rate ?? this.rate,
    error: clearError ? null : error ?? this.error,
    audioTracks: audioTracks ?? this.audioTracks,
    selectedAudioTrackId: selectedAudioTrackId ?? this.selectedAudioTrackId,
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

abstract interface class VideoPlaybackAdvancedSession
    implements VideoPlaybackSession {
  VideoController get videoController;
  double get sourceAspectRatio;
  VideoPlaybackInfo get playbackInfo;

  Widget buildConfiguredSurface({
    required double? aspectRatio,
    required BoxFit fit,
    required SubtitleViewConfiguration subtitleViewConfiguration,
  });

  Future<Uint8List?> takeScreenshot();
  Future<void> setLoopSingle(bool enabled);
  Future<void> setSubtitleOffset(double seconds);
  Future<void> loadExternalSubtitle(String path, {required String title});
  Future<void> setSuperResolution(VideoSuperResolution mode);
}

typedef VideoPlaybackInfo = ({
  String? resolution,
  String? videoCodec,
  String? frameRate,
  String? videoBitrate,
  String? audioCodec,
  String? audioFormat,
});

typedef VideoPlaybackSessionFactory = VideoPlaybackSession Function();

class MediaKitVideoPlaybackSession implements VideoPlaybackAdvancedSession {
  MediaKitVideoPlaybackSession({Player? player})
    : _player = player ?? Player() {
    _controller = VideoController(
      _player,
      configuration: defaultTargetPlatform == TargetPlatform.iOS
          ? const VideoControllerConfiguration(
              enableHardwareAcceleration: false,
            )
          : const VideoControllerConfiguration(),
    );
    _subscriptions.addAll([
      _player.stream.position.listen(
        (value) => _update((old) => old.copyWith(position: value)),
      ),
      _player.stream.duration.listen(
        (value) => _update((old) => old.copyWith(duration: value)),
      ),
      _player.stream.buffer.listen(
        (value) => _update((old) => old.copyWith(bufferPosition: value)),
      ),
      _player.stream.playing.listen(
        (value) => _update((old) => old.copyWith(playing: value)),
      ),
      _player.stream.buffering.listen(
        (value) => _update((old) => old.copyWith(buffering: value)),
      ),
      _player.stream.completed.listen(
        (value) => _update((old) => old.copyWith(completed: value)),
      ),
      _player.stream.rate.listen(
        (value) => _update((old) => old.copyWith(rate: value)),
      ),
      _player.stream.tracks.listen(_updateTracks),
      if (_player.platform is! NativePlayer)
        _player.stream.track.listen(
          (track) => _update(
            (old) => old.copyWith(selectedAudioTrackId: track.audio.id),
          ),
        ),
      _player.stream.error.listen(
        (value) => _update((old) => old.copyWith(error: value)),
      ),
    ]);

    final proxy = ProxyConfig.httpsProxyUrl;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      _nativePlayer = platform;
      final hook = _applyNativeSubtitleLoadOptions;
      _nativeSubtitleLoadHook = hook;
      platform.onLoadHooks.add(hook);
      _configureNative = platform.observeProperty('aid', (id) async {
        _update((old) => old.copyWith(selectedAudioTrackId: id));
      });
      if (proxy != null) {
        _configureNative = _configureNative.then(
          (_) => platform.setProperty('http-proxy', proxy),
        );
      }
    }
  }

  final Player _player;
  late final VideoController _controller;
  final ValueNotifier<VideoPlaybackSnapshot> _snapshot = ValueNotifier(
    const VideoPlaybackSnapshot(),
  );
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _configureNative = Future.value();
  Future<void> _superResolutionTail = Future<void>.value();
  NativePlayer? _nativePlayer;
  Future<void> Function()? _nativeSubtitleLoadHook;
  (String path, String title)? _externalSubtitle;
  bool _externalSubtitleDisabled = false;
  double _rate = 1;
  bool _disposed = false;

  @override
  ValueListenable<VideoPlaybackSnapshot> get snapshot => _snapshot;

  @override
  VideoController get videoController => _controller;

  @override
  double get sourceAspectRatio {
    final width = _player.state.width;
    final height = _player.state.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return 16 / 9;
    }
    return width / height;
  }

  @override
  VideoPlaybackInfo get playbackInfo {
    final state = _player.state;
    final width = state.width ?? state.videoParams.w;
    final height = state.height ?? state.videoParams.h;
    final videoBitrate = state.track.video.bitrate;
    final audioFormat = [
      state.audioParams.format,
      if (state.audioParams.sampleRate case final sampleRate?) '$sampleRate Hz',
      state.audioParams.hrChannels,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    return (
      resolution: width != null && height != null ? '$width×$height' : null,
      videoCodec: state.track.video.codec,
      frameRate: state.track.video.fps?.toStringAsFixed(2),
      videoBitrate: videoBitrate == null
          ? null
          : '${(videoBitrate / 1000).round()} kbps',
      audioCodec: state.track.audio.codec,
      audioFormat: audioFormat.isEmpty ? null : audioFormat,
    );
  }

  @override
  Widget buildSurface({required double aspectRatio}) => Video(
    controller: _controller,
    aspectRatio: aspectRatio,
    controls: NoVideoControls,
    wakelock: false,
    pauseUponEnteringBackgroundMode: false,
    resumeUponEnteringForegroundMode: false,
  );

  @override
  Widget buildConfiguredSurface({
    required double? aspectRatio,
    required BoxFit fit,
    required SubtitleViewConfiguration subtitleViewConfiguration,
  }) => Video(
    controller: _controller,
    aspectRatio: aspectRatio,
    fit: fit,
    controls: NoVideoControls,
    wakelock: false,
    pauseUponEnteringBackgroundMode: false,
    resumeUponEnteringForegroundMode: false,
    subtitleViewConfiguration: subtitleViewConfiguration,
  );

  @override
  Future<void> loadStream(
    VideoStream stream, {
    required Duration position,
    required double volume,
  }) async {
    _update((old) => old.copyWith(clearError: true));
    await _configureNative;
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
    if (_nativePlayer == null) await _restoreExternalSubtitle();
    await _player.setRate(_rate);
  }

  @override
  Future<void> loadFile(
    String path, {
    required Duration position,
    required double volume,
  }) async {
    _update((old) => old.copyWith(clearError: true));
    await _configureNative;
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
    if (_nativePlayer == null) await _restoreExternalSubtitle();
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
    switch (id) {
      case 'auto':
        _externalSubtitleDisabled = false;
        final subtitle = _externalSubtitle;
        if (subtitle == null) {
          await _player.setSubtitleTrack(SubtitleTrack.auto());
        } else {
          await _player.setSubtitleTrack(
            SubtitleTrack.uri(subtitle.$1, title: subtitle.$2),
          );
        }
      case 'no':
        _externalSubtitleDisabled = true;
        await _player.setSubtitleTrack(SubtitleTrack.no());
      default:
        _externalSubtitleDisabled = false;
        final track = _player.state.tracks.subtitle.firstWhere(
          (track) => track.id == id,
        );
        await _player.setSubtitleTrack(track);
        final platform = _nativePlayer;
        if (platform == null) {
          _externalSubtitle = null;
          return;
        }
        final trackCount =
            int.tryParse(await platform.getProperty('track-list/count')) ?? 0;
        for (var index = 0; index < trackCount; index++) {
          if (await platform.getProperty('track-list/$index/type') != 'sub' ||
              await platform.getProperty('track-list/$index/id') != id) {
            continue;
          }
          final path = await platform.getProperty(
            'track-list/$index/external-filename',
          );
          _externalSubtitle = path.isEmpty ? null : (path, track.title ?? path);
          break;
        }
    }
  }

  @override
  Future<Uint8List?> takeScreenshot() =>
      _player.screenshot(format: 'image/png', includeLibassSubtitles: true);

  @override
  Future<void> setLoopSingle(bool enabled) => _player.setPlaylistMode(
    enabled ? PlaylistMode.single : PlaylistMode.none,
  );

  @override
  Future<void> setSubtitleOffset(double seconds) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('sub-delay', seconds.toStringAsFixed(2));
    }
  }

  @override
  Future<void> loadExternalSubtitle(String path, {required String title}) =>
      _setExternalSubtitle(path, title);

  Future<void> _setExternalSubtitle(String path, String title) async {
    _externalSubtitle = (path, title);
    _externalSubtitleDisabled = false;
    await _applyNativeSubtitleLoadOptions();
    await _restoreExternalSubtitle();
  }

  Future<void> _restoreExternalSubtitle() async {
    final subtitle = _externalSubtitle;
    if (subtitle != null) {
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(subtitle.$1, title: subtitle.$2),
      );
    } else {
      await _player.setSubtitleTrack(SubtitleTrack.auto());
    }
    if (_externalSubtitleDisabled) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
    }
  }

  Future<void> _applyNativeSubtitleLoadOptions() async {
    final platform = _nativePlayer;
    if (platform == null) return;
    final subtitle = _externalSubtitle;
    // Android's bundled mpv parses an empty sub-files value as a file name.
    if (subtitle != null) {
      await platform.setProperty(
        'file-local-options/sub-files',
        _mpvPathListEntry(subtitle.$1),
        waitForInitialization: false,
      );
    }
    await platform.setProperty(
      'file-local-options/sid',
      _externalSubtitleDisabled ? 'no' : 'auto',
      waitForInitialization: false,
    );
  }

  @override
  Future<void> setSuperResolution(VideoSuperResolution mode) {
    final operation = _superResolutionTail.then((_) async {
      if (_disposed) return;
      await applyVideoSuperResolution(_player, mode);
    });
    _superResolutionTail = operation.catchError((Object _) {});
    return operation;
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
    final nativePlayer = _nativePlayer;
    final subtitleLoadHook = _nativeSubtitleLoadHook;
    if (nativePlayer != null) {
      await _configureNative;
      await nativePlayer.unobserveProperty('aid');
    }
    if (nativePlayer != null && subtitleLoadHook != null) {
      nativePlayer.onLoadHooks.remove(subtitleLoadHook);
    }
    await _superResolutionTail;
    await _player.dispose();
    _snapshot.dispose();
  }
}

String _mpvPathListEntry(String path) {
  final separator = defaultTargetPlatform == TargetPlatform.windows ? ';' : ':';
  return path.replaceAll(separator, '\\$separator');
}

class VideoPlaybackPanel extends StatefulWidget {
  const VideoPlaybackPanel({
    super.key,
    required this.videoId,
    required this.library,
    this.title = '',
    this.autoPlayOnStart = false,
    this.onPlayNextRelated,
    this.streams = const [],
    this.localPath,
    this.initialPosition = Duration.zero,
    this.initialVolume = 100,
    this.sessionFactory,
    this.platform,
    this.onStreamChanged,
    this.onOpenSource,
    this.onVerifyAccess,
  });

  final String videoId;
  final VideoLibrary library;
  final String title;
  final bool autoPlayOnStart;
  final Future<void> Function()? onPlayNextRelated;
  final List<VideoStream> streams;
  final String? localPath;
  final Duration initialPosition;
  final double initialVolume;
  final VideoPlaybackSessionFactory? sessionFactory;
  final VideoPlayerPlatform? platform;
  final ValueChanged<VideoStream>? onStreamChanged;
  final VoidCallback? onOpenSource;
  final Future<void> Function()? onVerifyAccess;

  @override
  State<VideoPlaybackPanel> createState() => _VideoPlaybackPanelState();
}

class _VideoPlaybackPanelState extends State<VideoPlaybackPanel>
    with WidgetsBindingObserver {
  late final VideoPlaybackSession _session;
  late final VideoPlaybackSettings _settings;
  late final VideoPlayerPlatform _platform;
  final ValueNotifier<int> _uiRevision = ValueNotifier(0);
  final FocusNode _focusNode = FocusNode(debugLabel: 'Video player');
  final ValueNotifier<double> _inlineViewportHeight = ValueNotifier(0);
  final Map<int, Offset> _transformPointers = {};
  late double _volume;
  late int _streamIndex;
  late Future<void> _loadTail;
  Future<void> _rateTail = Future<void>.value();
  Future<void> _loopModeTail = Future<void>.value();
  Timer? _saveTimer;
  Timer? _controlsTimer;
  Timer? _keyboardRightTimer;
  Duration? _pendingLoadPosition;
  Duration? _seekPreview;
  Duration? _dragStartPosition;
  double? _dragStartX;
  Duration _pendingLoadBasePosition = Duration.zero;
  ModalRoute<dynamic>? _route;
  PageRoute<void>? _fullscreenRoute;
  PageRoute<void>? _pictureInPictureRoute;
  double? _temporaryRate;
  double? _runtimeRate;
  bool _controlsVisible = true;
  bool _keyboardRightDown = false;
  bool _keyboardRightTemporary = false;
  bool _controlsInteracting = false;
  bool _lastPlaying = false;
  bool _lastBuffering = false;
  bool _loading = true;
  bool _fullscreen = false;
  bool _enteringFullscreen = false;
  bool _routeCovered = false;
  bool _appSuspended = false;
  bool _settingsOpen = false;
  bool _settingsRouteOpen = false;
  bool _pictureInPictureRouteOpen = false;
  bool _enteringPictureInPicture = false;
  bool _controlsLocked = false;
  bool _platformReady = false;
  double _brightness = .5;
  double _videoScale = 1;
  double _pinchStartDistance = 0;
  double _pinchStartScale = 1;
  Offset _videoOffset = Offset.zero;
  Offset _pinchStartOffset = Offset.zero;
  Offset _pinchStartFocalPoint = Offset.zero;
  double _lastNonZeroVolume = 100;
  double? _doubleTapX;
  double? _verticalDragStart;
  double? _brightnessStart;
  double? _volumeStart;
  bool _centerFullscreenGesture = false;
  double _centerSwipeDelta = 0;
  bool _autoExitScheduled = false;
  bool _autoAdvanceScheduled = false;
  bool _refreshingRouteSettings = false;
  bool? _appliedSubtitlesEnabled;
  String _selectedSubtitleTrackId = 'auto';
  VideoSuperResolution? _appliedSuperResolution;
  bool _orientationChanged = false;
  bool _alwaysOnTop = false;
  VideoFullscreenOrientation? _lastAppliedFullscreenOrientation;
  String? _gestureValueLabel;
  Timer? _gestureOverlayTimer;
  Timer? _fullscreenStatusTimer;
  Future<void>? _platformInitialization;
  bool _disposed = false;
  bool _sourceLoaded = false;
  int _pauseGeneration = 0;
  int _loadGeneration = 0;
  String? _error;
  ({int level, bool charging})? _batteryStatus;

  @override
  void initState() {
    super.initState();
    _session = widget.sessionFactory?.call() ?? MediaKitVideoPlaybackSession();
    _settings = VideoPlaybackSettings();
    _platform = widget.platform ?? VideoPlayerPlatform();
    _settings.addListener(_onSettingsChanged);
    _platform.pictureInPicture.addListener(_onPictureInPictureChanged);
    VideoSleepTimer.shared.addListener(_onSleepTimerChanged);
    _session.snapshot.addListener(_onSnapshotChanged);
    _volume = widget.initialVolume.clamp(0, 100).toDouble();
    if (_volume > 0) _lastNonZeroVolume = _volume;
    _streamIndex = 0;
    _loadTail = Future<void>.value();
    WidgetsBinding.instance.addObserver(this);
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_savePosition());
    });
    unawaited(_initializePlatform());
    unawaited(_loadSource(position: widget.initialPosition));
  }

  Future<void> _initializePlatform() => _platformInitialization ??=
      _activatePlatform().whenComplete(() => _platformInitialization = null);

  Future<void> _activatePlatform() async {
    try {
      await _platform.initialize();
      await _settings.initialize();
      if (!mounted) return;
      VideoSleepTimer.shared.attach(
        this,
        onPause: _pauseForSleepTimer,
        isPlaying: () => _session.snapshot.value.playing,
      );
      if (_sourceLoaded) await _applyLoopMode();
      _platformReady = true;
      if (_platform.supportsSystemBrightness) {
        final applied = await _platform.setSystemBrightnessMode(
          _settings.systemBrightness,
        );
        if (!applied && _settings.systemBrightness) {
          await _settings.setSystemBrightness(false);
        }
      }
      _brightness = await _platform.getBrightness();
      if (_isDesktop) _alwaysOnTop = await _platform.isAlwaysOnTop();
      await _platform.setBackgroundPlayback(
        _settings.backgroundPlayback && _session.snapshot.value.playing,
      );
      await _syncAutomaticPictureInPicture();
      await _platform.setKeepScreenOn(_session.snapshot.value.playing);
      if (mounted) _updatePlayerState(() {});
    } catch (_) {
      if (mounted) {
        _platformReady = true;
        _updatePlayerState(() {});
      }
    }
  }

  void _onSettingsChanged() {
    if (_disposed) return;
    if (_sourceLoaded && !_refreshingRouteSettings) {
      unawaited(_invoke(_applySettings));
    }
    if (mounted) {
      _updatePlayerState(() {});
      _scheduleControlsHide();
      if (_fullscreen &&
          _lastAppliedFullscreenOrientation !=
              _settings.fullscreenOrientation) {
        unawaited(_applyFullscreenOrientation(context, entering: true));
      }
    }
  }

  Future<void> _applySettings() async {
    await _platform.setBackgroundPlayback(
      _settings.backgroundPlayback && _session.snapshot.value.playing,
    );
    await _syncAutomaticPictureInPicture();
    final advanced = _session;
    if (advanced is VideoPlaybackAdvancedSession) {
      await _applyLoopMode();
      await advanced.setSubtitleOffset(_settings.subtitleOffsetSeconds);
      final superResolution = supportsVideoSuperResolution
          ? _settings.superResolution
          : VideoSuperResolution.off;
      if (_appliedSuperResolution != superResolution) {
        await advanced.setSuperResolution(superResolution);
        _appliedSuperResolution = superResolution;
      }
    }
    await _applySubtitlePreference();
  }

  void _onSleepTimerChanged() {
    if (_disposed || !_sourceLoaded || !VideoSleepTimer.shared.owns(this)) {
      return;
    }
    unawaited(_invoke(_applyLoopMode));
  }

  Future<void> _applyLoopMode() {
    final advanced = _session;
    if (advanced is! VideoPlaybackAdvancedSession || !_sourceLoaded) {
      return Future<void>.value();
    }
    final operation = _loopModeTail.then((_) {
      final timer = VideoSleepTimer.shared;
      final suppressLoop =
          timer.owns(this) &&
          (timer.waitingForCompletion || timer.actionInProgress);
      return advanced.setLoopSingle(_settings.loopSingle && !suppressLoop);
    });
    _loopModeTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _applySubtitlePreference() async {
    final enabled = _settings.subtitlesEnabled;
    if (_appliedSubtitlesEnabled == enabled) return;
    final id = enabled ? 'auto' : 'no';
    await _session.selectSubtitleTrack(id);
    _selectedSubtitleTrackId = id;
    _appliedSubtitlesEnabled = enabled;
  }

  Future<void> _syncAutomaticPictureInPicture() async {
    final advanced = _session;
    if (advanced is VideoPlaybackAdvancedSession &&
        !kIsWeb &&
        !_isDesktop &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      await _platform.attachVideoController(advanced.videoController);
    }
    final enabled =
        _settings.autoPictureInPicture &&
        _platform.supportsPictureInPicture &&
        advanced is VideoPlaybackAdvancedSession;
    await _platform.setAutoPictureInPicture(
      enabled,
      aspectRatio: advanced is VideoPlaybackAdvancedSession
          ? advanced.sourceAspectRatio
          : 16 / 9,
    );
  }

  Future<bool> _setSystemBrightnessMode(bool enabled) async {
    if (!_platform.supportsSystemBrightness) return false;
    var applied = await _platform.setSystemBrightnessMode(enabled);
    if (!applied && enabled) {
      await _platform.requestSystemBrightnessPermission();
      applied = await _platform.setSystemBrightnessMode(true);
    }
    return applied;
  }

  void _onPictureInPictureChanged() {
    final needsVideoOnlyRoute =
        _isDesktop || defaultTargetPlatform == TargetPlatform.android;
    if (needsVideoOnlyRoute && _platform.pictureInPicture.value) {
      _openPictureInPictureRoute(showExitControl: _isDesktop);
    } else if (needsVideoOnlyRoute && !_platform.pictureInPicture.value) {
      final route = _pictureInPictureRoute;
      if (route?.isCurrent == true && mounted) Navigator.of(context).pop();
    }
    if (!_platform.pictureInPicture.value &&
        _appSuspended &&
        !_settings.backgroundPlayback &&
        !_enteringPictureInPicture) {
      unawaited(_pauseAndSave());
    }
    if (mounted) _updatePlayerState(() {});
    _onSnapshotChanged();
  }

  bool get _isDesktop =>
      !kIsWeb &&
      const {
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }.contains(defaultTargetPlatform);

  void _openPictureInPictureRoute({required bool showExitControl}) {
    if (!mounted || _pictureInPictureRoute != null) return;
    _pictureInPictureRouteOpen = true;
    _updatePlayerState(() {});
    final route = PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (context, animation, secondaryAnimation) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: _buildPlayerLayout(
            context,
            fullscreen: true,
            pipMode: true,
            showPipExitControl: showExitControl,
            onFullscreen: _exitPictureInPicture,
          ),
        ),
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    );
    _pictureInPictureRoute = route;
    unawaited(
      Navigator.of(context).push<void>(route).whenComplete(() async {
        if (!identical(_pictureInPictureRoute, route)) return;
        if (_platform.pictureInPicture.value) {
          await _platform.exitPictureInPicture();
        }
        await route.completed;
        _pictureInPictureRoute = null;
        _pictureInPictureRouteOpen = false;
        if (mounted) _updatePlayerState(() {});
        _onSnapshotChanged();
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    _route?.secondaryAnimation?.removeListener(_onRouteTransition);
    _route = route;
    _route?.secondaryAnimation?.addListener(_onRouteTransition);
    if (route != null) {
      final panel = WeakReference(this);
      unawaited(
        route.popped.then<void>((_) {
          final state = panel.target;
          if (state == null ||
              !state.mounted ||
              !identical(state._route, route)) {
            return;
          }
          state._stopTemporaryRate();
          unawaited(state._pauseAndSave());
        }),
      );
    }
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
      if (_settings.autoPictureInPicture &&
          state == AppLifecycleState.paused &&
          _session.snapshot.value.playing &&
          _platform.supportsPictureInPicture) {
        unawaited(_enterPictureInPicture());
        unawaited(_savePosition());
        return;
      }
      if (_settings.autoPictureInPicture &&
          state == AppLifecycleState.inactive &&
          _session.snapshot.value.playing &&
          _platform.supportsPictureInPicture) {
        unawaited(_savePosition());
        return;
      }
      if (!_settings.backgroundPlayback &&
          !_platform.pictureInPicture.value &&
          !_enteringPictureInPicture) {
        unawaited(_pauseAndSave());
      } else {
        unawaited(_savePosition());
      }
    } else if (state == AppLifecycleState.resumed) {
      _onSnapshotChanged();
    }
  }

  void _onRouteTransition() {
    final route = _route;
    if (route == null) return;
    if (_settingsOpen ||
        _pictureInPictureRouteOpen ||
        _platform.pictureInPicture.value) {
      return;
    }
    if (route.isCurrent && (route.secondaryAnimation?.value ?? 0) == 0) {
      final wasCovered = _routeCovered;
      _routeCovered = false;
      if (wasCovered) unawaited(_reactivateAfterRoute());
      return;
    }
    if (_fullscreen || route.isCurrent || _routeCovered) return;
    if ((route.secondaryAnimation?.value ?? 0) > 0) {
      _routeCovered = true;
      _stopTemporaryRate();
      unawaited(_pauseAndSave());
    }
  }

  Future<void> _reactivateAfterRoute() async {
    _refreshingRouteSettings = true;
    try {
      await _settings.reload();
      if (!mounted || _disposed) return;
      await _initializePlatform();
      if (!mounted || _disposed) return;
      if (_sourceLoaded) await _applySettings();
      _onSnapshotChanged();
    } finally {
      _refreshingRouteSettings = false;
    }
  }

  Future<void> _loadSource({required Duration position, bool resume = false}) {
    final generation = ++_loadGeneration;
    final pauseGeneration = _pauseGeneration;
    final firstSourceLoad = !_sourceLoaded;
    _appliedSubtitlesEnabled = null;
    _autoExitScheduled = false;
    _updatePlayerState(() {
      _loading = true;
      _error = null;
    });
    final operation = _loadTail.then((_) async {
      if (_disposed || generation != _loadGeneration) return;
      await _settings.initialize();
      if (_disposed || generation != _loadGeneration) return;
      final autoPlay =
          firstSourceLoad && (_settings.autoPlay || widget.autoPlayOnStart);
      var autoPlayStarted = false;
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
      final playbackRate = _runtimeRate ?? _settings.defaultSpeed;
      _runtimeRate ??= playbackRate;
      if (playbackRate != _session.snapshot.value.rate) {
        await _session.setRate(playbackRate);
      }
      await _platform.setBackgroundPlayback(
        _settings.backgroundPlayback && _session.snapshot.value.playing,
      );
      final advanced = _session;
      if (advanced is VideoPlaybackAdvancedSession) {
        await _applyLoopMode();
        await advanced.setSubtitleOffset(_settings.subtitleOffsetSeconds);
        final superResolution = supportsVideoSuperResolution
            ? _settings.superResolution
            : VideoSuperResolution.off;
        await advanced.setSuperResolution(superResolution);
        _appliedSuperResolution = superResolution;
      }
      await _applySubtitlePreference();
      await _syncAutomaticPictureInPicture();
      _onSnapshotChanged();
      if ((resume || autoPlay) &&
          pauseGeneration == _pauseGeneration &&
          !_routeCovered &&
          !_appSuspended) {
        await _session.play();
        autoPlayStarted =
            autoPlay &&
            pauseGeneration == _pauseGeneration &&
            !_routeCovered &&
            !_appSuspended &&
            _session.snapshot.value.playing;
      }
      if (!mounted || generation != _loadGeneration) return;
      _updatePlayerState(() {
        _loading = false;
        _controlsVisible = true;
      });
      _onSnapshotChanged();
      if (autoPlayStarted && _settings.autoFullscreen && !_fullscreen) {
        unawaited(_enterFullscreen());
      }
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
    final rate = _settings.dynamicLongPressRate
        ? (_temporaryRate! * 2).clamp(1.5, 4).toDouble()
        : _settings.longPressRate;
    unawaited(_queueRate(rate));
  }

  void _stopTemporaryRate() {
    _keyboardRightTimer?.cancel();
    _keyboardRightTimer = null;
    _keyboardRightDown = false;
    _keyboardRightTemporary = false;
    final rate = _temporaryRate;
    if (rate == null) return;
    _temporaryRate = null;
    unawaited(_queueRate(rate));
    _scheduleControlsHide();
  }

  bool _canHideControls(VideoPlaybackSnapshot snapshot) =>
      _controlsVisible &&
      !_controlsLocked &&
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
    _controlsTimer = Timer(
      Duration(seconds: _settings.extendedControlTime ? 30 : 3),
      () {
        if (mounted && _canHideControls(_session.snapshot.value)) {
          _updatePlayerState(() => _controlsVisible = false);
        }
      },
    );
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
    if (!_disposed && _session.snapshot.value.completed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onSnapshotChanged());
    }
  }

  void _showControls() {
    if (!_controlsVisible) _updatePlayerState(() => _controlsVisible = true);
    _scheduleControlsHide();
  }

  void _toggleControls() {
    if (_controlsLocked) return;
    final snapshot = _session.snapshot.value;
    if (_controlsInteracting || snapshot.error != null || _error != null) {
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
    if (_controlsLocked ||
        _platform.pictureInPicture.value ||
        _transformPointers.length > 1) {
      return;
    }
    final startX = _dragStartX;
    final startPosition = _dragStartPosition;
    final duration = _session.snapshot.value.duration;
    if (startX == null || startPosition == null || width <= 0) return;
    final configuredDuration = _settings.relativeSwipeSeek
        ? Duration(
            milliseconds:
                (duration.inMilliseconds * _settings.swipeSeekDuration / 100)
                    .round(),
          )
        : Duration(seconds: _settings.swipeSeekDuration);
    final dragDuration = duration < configuredDuration
        ? duration
        : configuredDuration;
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

  void _surfaceDoubleTap(double width) {
    if (_controlsLocked) return;
    if (!_settings.enableDoubleTapSeek) {
      _togglePlayback();
      return;
    }
    final x = _doubleTapX;
    final snapshot = _session.snapshot.value;
    if (x == null || width <= 0) {
      _togglePlayback();
      return;
    }
    if (x < width / 3) {
      final target = _clampPosition(
        snapshot.position - Duration(seconds: _settings.doubleTapSeekSeconds),
        snapshot.duration,
      );
      _showGestureValue('−${_settings.doubleTapSeekSeconds}s');
      _finishSeek(target);
    } else if (x > width * 2 / 3) {
      final target = _clampPosition(
        snapshot.position + Duration(seconds: _settings.doubleTapSeekSeconds),
        snapshot.duration,
      );
      _showGestureValue('+${_settings.doubleTapSeekSeconds}s');
      _finishSeek(target);
    } else {
      _togglePlayback();
    }
  }

  void _startVerticalGesture(DragStartDetails details, double width) {
    if (_controlsLocked || _platform.pictureInPicture.value) return;
    _verticalDragStart = details.localPosition.dy;
    final x = details.localPosition.dx;
    if (_settings.enableFullscreenGesture &&
        x >= width / 3 &&
        x <= width * 2 / 3) {
      _centerFullscreenGesture = true;
      _centerSwipeDelta = 0;
    } else if (_settings.enableSideSwipeAdjust &&
        x < width / 2 &&
        _platform.supportsBrightness) {
      _brightnessStart = _brightness;
      _volumeStart = null;
    } else if (_settings.enableSideSwipeAdjust) {
      _volumeStart = _volume;
      _brightnessStart = null;
    }
  }

  void _updateVerticalGesture(DragUpdateDetails details, double height) {
    if (_transformPointers.length > 1) return;
    final start = _verticalDragStart;
    if (start == null || height <= 0) return;
    if (_centerFullscreenGesture) {
      _centerSwipeDelta = details.localPosition.dy - start;
      _showGestureValue(S.of(context).videoFullscreen);
      return;
    }
    final delta = start - details.localPosition.dy;
    if (_brightnessStart case final brightness?) {
      _brightness = (brightness + delta / height).clamp(0.0, 1.0);
      unawaited(_platform.setBrightness(_brightness));
      _showGestureValue(
        '${S.of(context).videoPlayerBrightness}: ${(_brightness * 100).round()}%',
      );
    } else if (_volumeStart case final volume?) {
      final value = (volume + delta / height * 100).clamp(0.0, 100.0);
      unawaited(_setVolume(value));
      _showGestureValue('${S.of(context).volume}: ${value.round()}%');
    }
  }

  void _finishVerticalGesture({
    required bool fullscreen,
    required VoidCallback onFullscreen,
  }) {
    final centerGesture = _centerFullscreenGesture;
    final centerDelta = _centerSwipeDelta;
    _centerFullscreenGesture = false;
    _centerSwipeDelta = 0;
    if (centerGesture && centerDelta.abs() >= 60) {
      final entering = _settings.reverseFullscreenGesture
          ? centerDelta > 0
          : centerDelta < 0;
      if (entering && !fullscreen) {
        unawaited(_enterFullscreen(nativeFullscreen: false));
      } else if (!entering && fullscreen) {
        onFullscreen();
      }
    }
    if (_volumeStart != null) unawaited(_persistVolume(_volume));
    _verticalDragStart = null;
    _brightnessStart = null;
    _volumeStart = null;
  }

  void _cancelVerticalGesture() {
    _centerFullscreenGesture = false;
    _centerSwipeDelta = 0;
    _verticalDragStart = null;
    _brightnessStart = null;
    _volumeStart = null;
  }

  void _showGestureValue(String label) {
    _gestureOverlayTimer?.cancel();
    if (mounted) _updatePlayerState(() => _gestureValueLabel = label);
    _gestureOverlayTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) _updatePlayerState(() => _gestureValueLabel = null);
    });
  }

  void _onTransformPointerDown(
    PointerDownEvent event, {
    required bool pipMode,
  }) {
    if (event.kind != PointerDeviceKind.touch ||
        _controlsLocked ||
        pipMode ||
        _platform.pictureInPicture.value) {
      return;
    }
    _transformPointers[event.pointer] = event.localPosition;
    if (_transformPointers.length != 2) return;
    _cancelSeekPreview();
    _cancelVerticalGesture();
    _dragStartX = null;
    _dragStartPosition = null;
    final points = _transformPointers.values.toList(growable: false);
    _pinchStartDistance = (points[0] - points[1]).distance;
    _pinchStartScale = _videoScale;
    _pinchStartOffset = _videoOffset;
    _pinchStartFocalPoint = (points[0] + points[1]) / 2;
    _showControls();
  }

  void _onTransformPointerMove(PointerMoveEvent event) {
    if (!_transformPointers.containsKey(event.pointer)) return;
    _transformPointers[event.pointer] = event.localPosition;
    if (_transformPointers.length != 2 || _pinchStartDistance <= 0) return;
    final points = _transformPointers.values.toList(growable: false);
    final distance = (points[0] - points[1]).distance;
    final focalPoint = (points[0] + points[1]) / 2;
    final scale = (_pinchStartScale * distance / _pinchStartDistance)
        .clamp(1.0, 4.0)
        .toDouble();
    final screenSize = MediaQuery.sizeOf(context);
    final aspectRatio = _viewportAspectRatio(context, fullscreen: _fullscreen);
    final videoWidth = screenSize.width < screenSize.height * aspectRatio
        ? screenSize.width
        : screenSize.height * aspectRatio;
    final videoHeight = videoWidth / aspectRatio;
    final maxX = videoWidth * (scale - 1) / 2;
    final maxY = videoHeight * (scale - 1) / 2;
    final offset = scale == 1
        ? Offset.zero
        : _pinchStartOffset + (focalPoint - _pinchStartFocalPoint);
    _updatePlayerState(() {
      _videoScale = scale;
      _videoOffset = Offset(
        offset.dx.clamp(-maxX, maxX).toDouble(),
        offset.dy.clamp(-maxY, maxY).toDouble(),
      );
      _controlsVisible = true;
    });
  }

  void _onTransformPointerEnd(PointerEvent event) {
    _transformPointers.remove(event.pointer);
    if (_transformPointers.length < 2) _pinchStartDistance = 0;
  }

  void _restoreVideoTransform() {
    _pinchStartDistance = 0;
    _updatePlayerState(() {
      _videoScale = 1;
      _videoOffset = Offset.zero;
    });
    _scheduleControlsHide();
  }

  void _togglePlayback() {
    final snapshot = _session.snapshot.value;
    if (_error != null || snapshot.error != null) return;
    _routeCovered = false;
    if (snapshot.playing) {
      _pauseGeneration++;
      unawaited(_invoke(_session.pause));
    } else {
      unawaited(
        _invoke(() async {
          await _session.play();
          if (_settings.autoFullscreen && !_fullscreen) {
            unawaited(_enterFullscreen(nativeFullscreen: false));
          }
        }),
      );
    }
    _showControls();
  }

  KeyEventResult _handlePlayerKey(
    KeyEvent event, {
    required bool fullscreen,
    required bool pipMode,
    required VoidCallback onFullscreen,
  }) {
    if (!_settings.keyboardControl) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
          _keyboardRightDown) {
        final wasTemporary = _keyboardRightTemporary;
        _keyboardRightTimer?.cancel();
        _keyboardRightTimer = null;
        _keyboardRightDown = false;
        _keyboardRightTemporary = false;
        if (wasTemporary) {
          _stopTemporaryRate();
        } else {
          _seekByKeyboard(_settings.doubleTapSeekSeconds);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        _togglePlayback();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _seekByKeyboard(-_settings.doubleTapSeekSeconds);
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (!_keyboardRightDown) {
          _keyboardRightDown = true;
          _keyboardRightTemporary = false;
          _keyboardRightTimer = Timer(const Duration(milliseconds: 200), () {
            if (!_keyboardRightDown || !mounted) return;
            _keyboardRightTemporary = true;
            _startTemporaryRate();
          });
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        unawaited(_changeKeyboardVolume(10));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        unawaited(_changeKeyboardVolume(-10));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        if (fullscreen || pipMode) {
          onFullscreen();
        } else {
          unawaited(
            _enterFullscreen(
              nativeFullscreen:
                  !(_isDesktop && HardwareKeyboard.instance.isShiftPressed),
            ),
          );
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyM:
        _toggleMute();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyS:
        if (fullscreen) {
          unawaited(_takeScreenshot());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.keyL:
        if (fullscreen || pipMode) {
          _toggleControlsLock();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.keyP:
        if (_isDesktop && !fullscreen && !pipMode) {
          unawaited(_enterPictureInPicture());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.digit1:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _setRuntimeRate(1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.digit2:
        if (HardwareKeyboard.instance.isShiftPressed) {
          _setRuntimeRate(2);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.escape:
        if (fullscreen) onFullscreen();
        return fullscreen ? KeyEventResult.handled : KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _seekByKeyboard(int seconds) {
    final snapshot = _session.snapshot.value;
    if (snapshot.duration <= Duration.zero) return;
    _finishSeek(
      _clampPosition(
        snapshot.position + Duration(seconds: seconds),
        snapshot.duration,
      ),
    );
    _showGestureValue('${seconds > 0 ? '+' : ''}${seconds}s');
    _showControls();
  }

  Future<void> _changeKeyboardVolume(double delta) async {
    final value = (_volume + delta).clamp(0.0, 100.0).toDouble();
    await _setVolume(value);
    await _persistVolume(value);
    if (!mounted) return;
    _showGestureValue('${S.of(context).volume}: ${value.round()}%');
  }

  void _setRuntimeRate(double rate) {
    _runtimeRate = rate;
    unawaited(_queueRate(rate));
    _showControls();
  }

  void _toggleMute() {
    if (_volume > 0) {
      _lastNonZeroVolume = _volume;
      unawaited(_setVolume(0));
      unawaited(_persistVolume(0));
    } else {
      final volume = _lastNonZeroVolume.clamp(1, 100).toDouble();
      unawaited(_setVolume(volume));
      unawaited(_persistVolume(volume));
    }
    _showControls();
  }

  void _toggleControlsLock() {
    _updatePlayerState(() => _controlsLocked = !_controlsLocked);
    if (_controlsLocked) {
      _controlsTimer?.cancel();
    } else {
      _showControls();
    }
  }

  Future<void> _takeScreenshot() async {
    final advanced = _session;
    if (advanced is! VideoPlaybackAdvancedSession) return;
    try {
      final bytes = await advanced.takeScreenshot();
      if (!mounted) return;
      if (bytes == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(S.of(context).saveImageFailed)));
        return;
      }
      await saveReaderImage(
        context,
        bytes,
        '${widget.title.isEmpty ? widget.videoId : widget.title}.png',
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).saveFailedWithError(error.toString())),
        ),
      );
    }
  }

  Future<void> _openPlaybackSettings() async {
    _settingsOpen = true;
    _settingsRouteOpen = true;
    _controlsTimer?.cancel();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'video-playback-settings'),
          builder: (_) => VideoPlaybackSettingsScreen(
            settings: _settings,
            supportsAutomaticPictureInPicture:
                !_isDesktop && _platform.supportsPictureInPicture,
            supportsBatteryStatus: _platform.supportsBatteryStatus,
            supportsFullscreenOrientation: !_isDesktop,
            supportsGravityRotation:
                defaultTargetPlatform == TargetPlatform.android,
            supportsSystemBrightness: _platform.supportsSystemBrightness,
            onSystemBrightnessChanged: _setSystemBrightnessMode,
            hasRelatedVideos: widget.onPlayNextRelated != null,
          ),
        ),
      );
    } finally {
      _settingsRouteOpen = false;
      _settingsOpen = false;
    }
    if (!mounted) return;
    _routeCovered = false;
    _focusNode.requestFocus();
    _showControls();
  }

  Future<void> _enterPictureInPicture() async {
    final advanced = _session;
    if (advanced is! VideoPlaybackAdvancedSession ||
        !_platform.supportsPictureInPicture ||
        _enteringPictureInPicture) {
      return;
    }
    _enteringPictureInPicture = true;
    _controlsTimer?.cancel();
    var entered = false;
    try {
      entered = await _platform.enterPictureInPicture(
        advanced.videoController,
        aspectRatio: advanced.sourceAspectRatio,
      );
    } finally {
      _enteringPictureInPicture = false;
      if (!entered && _appSuspended && !_settings.backgroundPlayback) {
        await _pauseAndSave();
      }
      if (mounted) _updatePlayerState(() {});
    }
  }

  Future<void> _exitPictureInPicture() => _platform.exitPictureInPicture();

  double _viewportAspectRatio(
    BuildContext context, {
    required bool fullscreen,
  }) {
    if (_settings.fit == VideoPlayerFit.fourThree) return 4 / 3;
    if (_settings.fit == VideoPlayerFit.sixteenNine) return 16 / 9;
    final session = _session;
    final sourceAspectRatio = session is VideoPlaybackAdvancedSession
        ? session.sourceAspectRatio
        : 16 / 9;
    if (_settings.expandVerticalVideo && sourceAspectRatio < 1) {
      final screenSize = MediaQuery.sizeOf(context);
      final screenAspectRatio = screenSize.width / screenSize.height;
      return fullscreen && screenAspectRatio > 1.2 ? 9 / 16 : 1;
    }
    return 16 / 9;
  }

  BoxFit _boxFit() => switch (_settings.fit) {
    VideoPlayerFit.contain => BoxFit.contain,
    VideoPlayerFit.fill => BoxFit.fill,
    VideoPlayerFit.cover => BoxFit.cover,
    VideoPlayerFit.width => BoxFit.fitWidth,
    VideoPlayerFit.height => BoxFit.fitHeight,
    VideoPlayerFit.original => BoxFit.none,
    VideoPlayerFit.scaleDown => BoxFit.scaleDown,
    VideoPlayerFit.fourThree || VideoPlayerFit.sixteenNine => BoxFit.contain,
  };

  String _fitLabel(S s, VideoPlayerFit fit) => switch (fit) {
    VideoPlayerFit.contain => s.videoPlayerFitContain,
    VideoPlayerFit.fill => s.videoPlayerFitFill,
    VideoPlayerFit.cover => s.videoPlayerFitCover,
    VideoPlayerFit.width => s.videoPlayerFitWidth,
    VideoPlayerFit.height => s.videoPlayerFitHeight,
    VideoPlayerFit.original => s.videoPlayerFitOriginal,
    VideoPlayerFit.scaleDown => s.videoPlayerFitScaleDown,
    VideoPlayerFit.fourThree => s.videoPlayerFitFourThree,
    VideoPlayerFit.sixteenNine => s.videoPlayerFitSixteenNine,
  };

  String _superResolutionLabel(S s, VideoSuperResolution mode) =>
      switch (mode) {
        VideoSuperResolution.off => s.videoPlayerSuperResolutionOff,
        VideoSuperResolution.efficiency =>
          s.videoPlayerSuperResolutionEfficiency,
        VideoSuperResolution.quality => s.videoPlayerSuperResolutionQuality,
      };

  Widget _buildSurface(double aspectRatio) {
    final subtitleConfiguration = SubtitleViewConfiguration(
      style: TextStyle(
        height: 1.4,
        fontSize: _settings.subtitleFontSize,
        color: Colors.white,
        backgroundColor: _settings.subtitleBackground
            ? const Color(0xaa000000)
            : Colors.transparent,
      ),
    );
    final session = _session;
    return session is VideoPlaybackAdvancedSession
        ? session.buildConfiguredSurface(
            aspectRatio: switch (_settings.fit) {
              VideoPlayerFit.fourThree => 4 / 3,
              VideoPlayerFit.sixteenNine => 16 / 9,
              _ => null,
            },
            fit: _boxFit(),
            subtitleViewConfiguration: subtitleConfiguration,
          )
        : session.buildSurface(aspectRatio: aspectRatio);
  }

  void _onSnapshotChanged() {
    if (_disposed || !mounted) return;
    final snapshot = _session.snapshot.value;
    if (snapshot.playing != _lastPlaying) {
      _lastPlaying = snapshot.playing;
      if (_platformReady) {
        unawaited(_platform.setKeepScreenOn(snapshot.playing));
        unawaited(
          _platform.setBackgroundPlayback(
            _settings.backgroundPlayback && snapshot.playing,
          ),
        );
      }
      if (snapshot.playing) {
        _controlsVisible = true;
        _scheduleControlsHide();
      } else {
        _controlsTimer?.cancel();
      }
    }
    if (snapshot.buffering != _lastBuffering) {
      _lastBuffering = snapshot.buffering;
      if (snapshot.buffering) {
        _controlsTimer?.cancel();
      } else if (snapshot.playing) {
        _scheduleControlsHide();
      }
    }
    if (snapshot.error != null) {
      _controlsTimer?.cancel();
      if (!_controlsVisible && mounted) {
        _updatePlayerState(() => _controlsVisible = true);
      }
    }
    if (snapshot.completed && VideoSleepTimer.shared.handleCompleted(this)) {
      _autoAdvanceScheduled = true;
      _autoExitScheduled = true;
      return;
    }
    if (!snapshot.completed) _autoExitScheduled = false;
    if (!snapshot.completed) _autoAdvanceScheduled = false;
    if (snapshot.completed &&
        _settings.autoPlayRelated &&
        _settings.repeatMode == VideoPlayerRepeatMode.related &&
        widget.onPlayNextRelated != null &&
        !_loading &&
        !_enteringFullscreen &&
        !_settingsOpen &&
        !_controlsInteracting &&
        !_pictureInPictureRouteOpen &&
        !_platform.pictureInPicture.value &&
        (!_appSuspended || _settings.backgroundPlayback) &&
        (_fullscreen
            ? _fullscreenRoute?.isCurrent == true
            : _route?.isCurrent != false) &&
        !_autoAdvanceScheduled) {
      _autoAdvanceScheduled = true;
      unawaited(_advanceToRelated());
    } else if (snapshot.completed &&
        _settings.autoExitFullscreen &&
        _settings.repeatMode == VideoPlayerRepeatMode.once &&
        _fullscreen &&
        _fullscreenRoute?.isCurrent == true &&
        !_autoExitScheduled) {
      _autoExitScheduled = true;
      final route = _fullscreenRoute;
      if (route?.isCurrent == true && mounted) Navigator.of(context).pop();
    }
    final pending = _pendingLoadPosition;
    if (pending == null ||
        _loading ||
        snapshot.error != null ||
        _error != null) {
      return;
    }
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
    final position = _pendingLoadPosition ?? _session.snapshot.value.position;
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
    if (_platform.pictureInPicture.value ||
        _enteringPictureInPicture ||
        (_appSuspended && _settings.backgroundPlayback)) {
      await _savePosition();
      return;
    }
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

  Future<void> _pauseForSleepTimer() async {
    _pauseGeneration++;
    _controlsInteracting = false;
    _stopTemporaryRate();
    _controlsTimer?.cancel();
    try {
      await _rateTail;
      await _session.pause();
    } finally {
      await _savePosition();
    }
  }

  void _updatePlayerState(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _uiRevision.value++;
  }

  Future<void> _applyFullscreenOrientation(
    BuildContext context, {
    required bool entering,
  }) async {
    if (_isDesktop || kIsWeb) return;
    if (!entering) {
      await _restoreFullscreenOrientation();
      return;
    }

    final mode = _settings.fullscreenOrientation;
    if (_lastAppliedFullscreenOrientation == mode && _orientationChanged) {
      return;
    }
    final wasGravity =
        _lastAppliedFullscreenOrientation == VideoFullscreenOrientation.gravity;
    final wasOrientationChanged = _orientationChanged;
    if (wasGravity && defaultTargetPlatform == TargetPlatform.android) {
      await _platform.setGravityOrientation(false);
    }
    if (wasOrientationChanged) {
      await SystemChrome.setPreferredOrientations(const []);
    }
    _orientationChanged = false;
    _lastAppliedFullscreenOrientation = mode;
    if (mode == VideoFullscreenOrientation.none) return;
    if (mode == VideoFullscreenOrientation.gravity) {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _platform.setGravityOrientation(true);
        _orientationChanged = true;
      }
      return;
    }

    final session = _session;
    final sourceAspectRatio = session is VideoPlaybackAdvancedSession
        ? session.sourceAspectRatio
        : 16 / 9;
    if (!context.mounted) return;
    final screenSize = MediaQuery.sizeOf(context);
    final screenAspectRatio = screenSize.width / screenSize.height;
    final portrait = switch (mode) {
      VideoFullscreenOrientation.auto => sourceAspectRatio < 1,
      VideoFullscreenOrientation.vertical => true,
      VideoFullscreenOrientation.horizontal => false,
      VideoFullscreenOrientation.ratio =>
        sourceAspectRatio < 1 || screenAspectRatio < 1.2,
      VideoFullscreenOrientation.none ||
      VideoFullscreenOrientation.gravity => false,
    };
    await SystemChrome.setPreferredOrientations(
      portrait
          ? const [DeviceOrientation.portraitUp]
          : const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
    );
    _orientationChanged = true;
  }

  Future<void> _advanceToRelated() async {
    final route = _fullscreenRoute;
    if (route?.isCurrent == true && mounted) {
      Navigator.of(context).pop();
      await route!.completed;
    }
    if (mounted) await widget.onPlayNextRelated?.call();
  }

  Future<void> _restoreFullscreenOrientation() async {
    if (_isDesktop || kIsWeb) return;
    if (_lastAppliedFullscreenOrientation ==
            VideoFullscreenOrientation.gravity &&
        defaultTargetPlatform == TargetPlatform.android) {
      await _platform.setGravityOrientation(false);
    }
    if (_orientationChanged) {
      await SystemChrome.setPreferredOrientations(const []);
    }
    _orientationChanged = false;
    _lastAppliedFullscreenOrientation = null;
  }

  Future<void> _savePosition() {
    if (!_sourceLoaded && _pendingLoadPosition == null) return Future.value();
    return widget.library.savePosition(
      widget.videoId,
      _pendingLoadPosition ?? _session.snapshot.value.position,
    );
  }

  void _startFullscreenStatusUpdates() {
    _fullscreenStatusTimer?.cancel();
    unawaited(_refreshBatteryStatus());
    _fullscreenStatusTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted || !_fullscreen) return;
      _updatePlayerState(() {});
      unawaited(_refreshBatteryStatus());
    });
  }

  Future<void> _refreshBatteryStatus() async {
    if (!_platformReady || !_platform.supportsBatteryStatus) return;
    final battery = await _platform.getBatteryStatus();
    if (!mounted || !_fullscreen) return;
    _batteryStatus = battery;
    _updatePlayerState(() {});
  }

  Future<void> _enterFullscreen({bool nativeFullscreen = true}) async {
    if (_fullscreen || _enteringFullscreen || !mounted) return;
    _enteringFullscreen = true;
    final enterNativeFullscreen = _isDesktop && nativeFullscreen;
    try {
      if (enterNativeFullscreen) {
        await _initializePlatform();
        if (!mounted) return;
        await _platform.setNativeFullscreen(true);
      }
      if (!mounted) {
        if (enterNativeFullscreen) await _platform.setNativeFullscreen(false);
        return;
      }
      try {
        await _applyFullscreenOrientation(context, entering: true);
      } catch (_) {
        if (enterNativeFullscreen) await _platform.setNativeFullscreen(false);
        rethrow;
      }
      _stopTemporaryRate();
      _endControlsInteraction();
      _cancelSeekPreview();
      _controlsTimer?.cancel();
      _updatePlayerState(() => _fullscreen = true);
    } finally {
      _enteringFullscreen = false;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      await _restoreFullscreenOrientation();
      if (enterNativeFullscreen) await _platform.setNativeFullscreen(false);
      return;
    }
    final route = PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (fullScreenContext, animation, secondaryAnimation) =>
          Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: ValueListenableBuilder<int>(
                valueListenable: _uiRevision,
                builder: (context, _, _) => _pictureInPictureRouteOpen
                    ? const ColoredBox(
                        key: ValueKey('video-fullscreen-placeholder'),
                        color: Colors.black,
                      )
                    : _buildPlayerLayout(
                        fullScreenContext,
                        fullscreen: true,
                        onFullscreen: () =>
                            Navigator.of(fullScreenContext).pop(),
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
      _startFullscreenStatusUpdates();
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        _focusNode.requestFocus();
        _showControls();
      }
      await popped;
      await route.completed;
    } finally {
      _fullscreenStatusTimer?.cancel();
      _fullscreenStatusTimer = null;
      if (enterNativeFullscreen) await _platform.setNativeFullscreen(false);
      await _restoreFullscreenOrientation();
      _stopTemporaryRate();
      _endControlsInteraction();
      _cancelSeekPreview();
      if (identical(_fullscreenRoute, route)) _fullscreenRoute = null;
      if (mounted) {
        _updatePlayerState(() => _fullscreen = false);
        _focusNode.requestFocus();
        _scheduleControlsHide();
        _onSnapshotChanged();
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

  void _publishInlineViewportHeight(double height) {
    if (_inlineViewportHeight.value == height) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _inlineViewportHeight.value == height) return;
      _inlineViewportHeight.value = height;
    });
  }

  Widget _buildPlayerLayout(
    BuildContext context, {
    required bool fullscreen,
    required VoidCallback onFullscreen,
    VoidCallback? onSecondaryFullscreen,
    bool pipMode = false,
    bool showPipExitControl = true,
  }) => Focus(
    key: const ValueKey('video-player-focus'),
    focusNode: _focusNode,
    autofocus: fullscreen,
    onKeyEvent: (node, event) => _handlePlayerKey(
      event,
      fullscreen: fullscreen,
      pipMode: pipMode,
      onFullscreen: onFullscreen,
    ),
    child: Listener(
      onPointerDown: (event) {
        _focusNode.requestFocus();
        _onTransformPointerDown(event, pipMode: pipMode);
      },
      onPointerMove: _onTransformPointerMove,
      onPointerUp: _onTransformPointerEnd,
      onPointerCancel: (event) {
        _onTransformPointerEnd(event);
        _endControlsInteraction();
        _cancelSeekPreview();
      },
      child: MouseRegion(
        onHover: (_) => _showControls(),
        child: Center(
          child: AspectRatio(
            aspectRatio: _viewportAspectRatio(context, fullscreen: fullscreen),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (!fullscreen && !pipMode) {
                  _publishInlineViewportHeight(constraints.maxHeight);
                }
                return Stack(
                  key: const ValueKey('video-playback-layout'),
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      key: const ValueKey('video-gesture-surface'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _controlsLocked || pipMode
                          ? null
                          : _toggleControls,
                      onDoubleTapDown: pipMode
                          ? null
                          : (details) => _doubleTapX = details.localPosition.dx,
                      onDoubleTap: pipMode
                          ? null
                          : () => _surfaceDoubleTap(constraints.maxWidth),
                      onHorizontalDragStart: _controlsLocked || pipMode
                          ? null
                          : (_) => _startSurfaceSeek(),
                      onHorizontalDragUpdate: (details) => _updateSurfaceSeek(
                        details.localPosition.dx,
                        constraints.maxWidth,
                      ),
                      onHorizontalDragEnd: (_) => _finishSeek(),
                      onHorizontalDragCancel: _cancelSeekPreview,
                      onVerticalDragStart:
                          _controlsLocked ||
                              pipMode ||
                              (!_settings.enableSideSwipeAdjust &&
                                  !_settings.enableFullscreenGesture)
                          ? null
                          : (details) => _startVerticalGesture(
                              details,
                              constraints.maxWidth,
                            ),
                      onVerticalDragUpdate: (details) => _updateVerticalGesture(
                        details,
                        constraints.maxHeight,
                      ),
                      onVerticalDragEnd: (_) => _finishVerticalGesture(
                        fullscreen: fullscreen,
                        onFullscreen: onFullscreen,
                      ),
                      onVerticalDragCancel: _cancelVerticalGesture,
                      onLongPressStart: _controlsLocked || pipMode
                          ? null
                          : (_) => _startTemporaryRate(),
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
                          _cancelVerticalGesture();
                          _dragStartX = null;
                          _dragStartPosition = null;
                        },
                        child: ColoredBox(
                          color: Colors.black,
                          child: ClipRect(
                            child: Transform.translate(
                              offset: _videoOffset,
                              child: Transform.flip(
                                flipX: _settings.flipHorizontal,
                                flipY: _settings.flipVertical,
                                child: Transform.scale(
                                  key: const ValueKey(
                                    'video-surface-transform',
                                  ),
                                  scale: _videoScale,
                                  child: _buildSurface(
                                    _viewportAspectRatio(
                                      context,
                                      fullscreen: fullscreen,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    ValueListenableBuilder<VideoPlaybackSnapshot>(
                      valueListenable: _session.snapshot,
                      builder: (context, snapshot, _) {
                        if (pipMode || constraints.maxWidth < 240) {
                          return const SizedBox.shrink();
                        }
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
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      IconButton(
                                        tooltip: S.of(context).retry,
                                        color: Colors.white,
                                        icon: const Icon(Icons.refresh),
                                        onPressed: () => unawaited(
                                          _loadSource(
                                            position:
                                                _pendingLoadPosition ??
                                                snapshot.position,
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
                          return const IgnorePointer(
                            child: Center(
                              child: CircularProgressIndicator(
                                key: ValueKey('video-playback-loading'),
                                color: Colors.white,
                              ),
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                    ValueListenableBuilder<VideoPlaybackSnapshot>(
                      valueListenable: _session.snapshot,
                      builder: (context, snapshot, _) {
                        final hasError =
                            _error != null || snapshot.error != null;
                        final controlsVisible = _controlsVisible;
                        // Android can briefly report tiny bounds when leaving PiP.
                        if (!pipMode && constraints.maxWidth < 240) {
                          return const SizedBox.shrink();
                        }
                        if (pipMode) {
                          if (!showPipExitControl) {
                            return const SizedBox.shrink();
                          }
                          return Align(
                            alignment: Alignment.topRight,
                            child: IconButton.filledTonal(
                              tooltip: S
                                  .of(context)
                                  .videoPlayerPictureInPicture,
                              color: Colors.white,
                              icon: const Icon(Icons.picture_in_picture_alt),
                              onPressed: _exitPictureInPicture,
                            ),
                          );
                        }
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            if (_shouldShowBottomProgress(
                              snapshot,
                              fullscreen: fullscreen,
                            ))
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: LinearProgressIndicator(
                                  minHeight: 2,
                                  value:
                                      (snapshot.position.inMilliseconds /
                                              snapshot.duration.inMilliseconds)
                                          .clamp(0.0, 1.0),
                                  backgroundColor: Colors.white24,
                                ),
                              ),
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
                            if (hasError)
                              Positioned(
                                top: 4,
                                right: 4,
                                child: IgnorePointer(
                                  ignoring: !controlsVisible,
                                  child: AnimatedOpacity(
                                    key: const ValueKey(
                                      'video-fullscreen-control',
                                    ),
                                    opacity: controlsVisible ? 1 : 0,
                                    duration: const Duration(milliseconds: 100),
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
                              if (controlsVisible && !_controlsLocked)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: 0,
                                  child: AnimatedOpacity(
                                    opacity: controlsVisible ? 1 : 0,
                                    duration: const Duration(milliseconds: 100),
                                    child: _buildTopControls(
                                      context,
                                      fullscreen: fullscreen,
                                      onFullscreen: onFullscreen,
                                      maxHeightListenable: fullscreen || pipMode
                                          ? null
                                          : _inlineViewportHeight,
                                    ),
                                  ),
                                ),
                            if (controlsVisible &&
                                !_controlsLocked &&
                                !pipMode &&
                                _videoScale > 1)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 95,
                                child: Center(
                                  child: FilledButton.tonal(
                                    key: const ValueKey('video-restore-screen'),
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.all(15),
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .secondaryContainer
                                          .withValues(alpha: .8),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                    onPressed: _restoreVideoTransform,
                                    child: Text(
                                      S.of(context).videoPlayerRestoreScreen,
                                    ),
                                  ),
                                ),
                              ),
                            if (_controlsLocked && controlsVisible)
                              Positioned(
                                top: 4,
                                right: 4,
                                child: IconButton(
                                  tooltip: S
                                      .of(context)
                                      .videoPlayerUnlockControls,
                                  color: Colors.white,
                                  icon: const Icon(Icons.lock_outline),
                                  onPressed: _toggleControlsLock,
                                ),
                              ),
                            if (_gestureValueLabel != null)
                              Center(
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: .68,
                                      ),
                                      borderRadius: BorderRadius.circular(28),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                        vertical: 12,
                                      ),
                                      child: Text(
                                        _gestureValueLabel!,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 18,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (!hasError && !_controlsLocked)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: IgnorePointer(
                                  ignoring: !controlsVisible,
                                  child: AnimatedOpacity(
                                    key: const ValueKey('video-controls'),
                                    opacity: controlsVisible ? 1 : 0,
                                    duration: const Duration(milliseconds: 100),
                                    child: _buildControls(
                                      context,
                                      fullscreen: fullscreen,
                                      onFullscreen: onFullscreen,
                                      onSecondaryFullscreen:
                                          onSecondaryFullscreen,
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
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildTopControls(
    BuildContext context, {
    required bool fullscreen,
    required VoidCallback onFullscreen,
    ValueListenable<double>? maxHeightListenable,
  }) {
    final s = S.of(context);
    final showTitle =
        fullscreen ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final canPip =
        _platformReady &&
        _platform.supportsPictureInPicture &&
        _session is VideoPlaybackAdvancedSession;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('video-player-back'),
            tooltip: s.back,
            color: Colors.white,
            icon: const Icon(Icons.arrow_back, size: 15),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 42, height: 34),
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(42, 34),
              maximumSize: const Size(42, 34),
              padding: EdgeInsets.zero,
            ),
            onPressed: fullscreen
                ? onFullscreen
                : () => Navigator.of(context).maybePop(),
          ),
          IconButton(
            key: const ValueKey('video-player-home'),
            tooltip: s.navHome,
            color: Colors.white,
            icon: const Icon(Icons.home, size: 19),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 42, height: 34),
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(42, 34),
              maximumSize: const Size(42, 34),
              padding: EdgeInsets.zero,
            ),
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
          ),
          if (showTitle)
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: Colors.white),
              ),
            )
          else
            const Spacer(),
          if (fullscreen) ...[
            if (_settings.showFullscreenBattery &&
                _platform.supportsBatteryStatus &&
                _batteryStatus != null) ...[
              Text(
                '${_batteryStatus!.level}%',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: Colors.white),
              ),
              const SizedBox(width: 10),
            ],
            Text(
              MaterialLocalizations.of(
                context,
              ).formatTimeOfDay(TimeOfDay.now(), alwaysUse24HourFormat: true),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: Colors.white),
            ),
          ],
          if (_isDesktop)
            IconButton(
              key: const ValueKey('video-player-always-on-top'),
              tooltip: _alwaysOnTop
                  ? s.videoPlayerCancelAlwaysOnTop
                  : s.videoPlayerAlwaysOnTop,
              color: Colors.white,
              icon: Icon(
                _alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
                size: 19,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 42, height: 34),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(42, 34),
                maximumSize: const Size(42, 34),
                padding: EdgeInsets.zero,
              ),
              onPressed: () => unawaited(_toggleAlwaysOnTop()),
            ),
          if (canPip)
            IconButton(
              key: const ValueKey('video-player-pip'),
              tooltip: s.videoPlayerPictureInPicture,
              color: Colors.white,
              icon: const Icon(Icons.picture_in_picture_alt, size: 19),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 42, height: 34),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(42, 34),
                maximumSize: const Size(42, 34),
                padding: EdgeInsets.zero,
              ),
              onPressed: () => unawaited(_enterPictureInPicture()),
            ),
          IconButton(
            key: const ValueKey('video-player-more-menu'),
            tooltip: s.videoPlayerMoreOptions,
            icon: const Icon(Icons.more_vert, color: Colors.white, size: 19),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 42, height: 34),
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(42, 34),
              maximumSize: const Size(42, 34),
              padding: EdgeInsets.zero,
            ),
            onPressed: () => unawaited(
              _showMoreOptions(
                canPip: canPip,
                maxHeightListenable: maxHeightListenable,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleAlwaysOnTop() async {
    final enabled = !_alwaysOnTop;
    await _platform.setAlwaysOnTop(enabled);
    if (mounted) _updatePlayerState(() => _alwaysOnTop = enabled);
  }

  Future<void> _selectSubtitleTrack(String id) => _invoke(() async {
    final enabled = id != 'no';
    await _session.selectSubtitleTrack(id);
    _selectedSubtitleTrackId = id;
    _appliedSubtitlesEnabled = enabled;
    await _settings.setSubtitlesEnabled(enabled);
  });

  Future<void> _loadExternalSubtitle() async {
    final session = _session;
    if (session is! VideoPlaybackAdvancedSession) return;
    await _invoke(() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt'],
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final path = file.path;
      if (path == null) return;
      await session.loadExternalSubtitle(path, title: file.name);
      _appliedSubtitlesEnabled = true;
      await _settings.setSubtitlesEnabled(true);
    });
  }

  Future<void> _reloadSource() {
    final snapshot = _session.snapshot.value;
    return _loadSource(
      position: _pendingLoadPosition ?? snapshot.position,
      resume: snapshot.playing,
    );
  }

  Future<void> _showPlaybackInfo() async {
    final session = _session;
    if (session is! VideoPlaybackAdvancedSession) return;
    final info = session.playbackInfo;
    final s = S.of(context);
    final rows = <(String, String)>[
      if (info.resolution case final value?)
        (s.videoPlayerInfoResolution, value),
      if (info.videoCodec case final value?)
        (s.videoPlayerInfoVideoCodec, value),
      if (info.frameRate case final value?) (s.videoPlayerInfoFrameRate, value),
      if (info.videoBitrate case final value?)
        (s.videoPlayerInfoVideoBitrate, value),
      if (info.audioCodec case final value?)
        (s.videoPlayerInfoAudioCodec, value),
      if (info.audioFormat case final value?)
        (s.videoPlayerInfoAudioFormat, value),
    ];
    if (rows.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.videoPlayerPlaybackInfo),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 132, child: Text(label)),
                      Expanded(child: Text(value)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    _onSnapshotChanged();
  }

  Future<void> _showMoreOptions({
    required bool canPip,
    ValueListenable<double>? maxHeightListenable,
  }) async {
    _settingsOpen = true;
    _beginControlsInteraction();
    var openPlayerSettings = false;
    var openSleepTimer = false;
    var audioTracksExpanded = false;
    try {
      await showResponsiveBottomSheet<void>(
        context: context,
        maxHeightListenable: maxHeightListenable,
        builder: (sheetContext) {
          final s = S.of(sheetContext);
          return StatefulBuilder(
            builder: (context, setSheetState) =>
                ValueListenableBuilder<VideoPlaybackSnapshot>(
                  valueListenable: _session.snapshot,
                  builder: (context, snapshot, _) {
                    final audioTracks = snapshot.audioTracks;
                    String? selectedAudioTrackLabel;
                    for (final track in audioTracks) {
                      if (track.id == snapshot.selectedAudioTrackId) {
                        selectedAudioTrackLabel = track.label;
                        break;
                      }
                    }
                    return AnimatedBuilder(
                      animation: _settings,
                      builder: (context, _) => ListView(
                        shrinkWrap: true,
                        children: [
                          BottomSheetHeader(title: s.videoPlayerMoreOptions),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                            child: Row(
                              children: [
                                const Icon(Icons.volume_down),
                                const SizedBox(width: 12),
                                Text(s.volume),
                                Expanded(
                                  child: StatefulBuilder(
                                    builder: (context, setSheetState) => Slider(
                                      key: const ValueKey(
                                        'video-volume-slider',
                                      ),
                                      min: 0,
                                      max: 100,
                                      value: _volume,
                                      onChanged: (value) {
                                        setSheetState(() {});
                                        unawaited(_setVolume(value));
                                      },
                                      onChangeEnd: _persistVolume,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (audioTracks.length > 1) ...[
                            const Divider(height: 1),
                            ListTile(
                              leading: const Icon(Icons.audiotrack),
                              title: Text(s.videoPlayerAudioTrack),
                              subtitle: selectedAudioTrackLabel == null
                                  ? null
                                  : Text(
                                      selectedAudioTrackLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              trailing: Icon(
                                audioTracksExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                              ),
                              onTap: () => setSheetState(
                                () =>
                                    audioTracksExpanded = !audioTracksExpanded,
                              ),
                            ),
                            if (audioTracksExpanded)
                              RadioGroup<String>(
                                groupValue: snapshot.selectedAudioTrackId,
                                onChanged: (id) {
                                  if (id == null) return;
                                  setSheetState(
                                    () => audioTracksExpanded = false,
                                  );
                                  unawaited(
                                    _invoke(
                                      () => _session.selectAudioTrack(id),
                                    ),
                                  );
                                },
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (final track in audioTracks)
                                      RadioListTile<String>(
                                        value: track.id,
                                        title: Text(
                                          track.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                          const Divider(height: 1),
                          SwitchListTile(
                            title: Text(s.videoPlayerRepeatSingle),
                            value: _settings.loopSingle,
                            onChanged: _settings.setLoopSingle,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  FilterChip(
                                    showCheckmark: false,
                                    selected: _settings.flipHorizontal,
                                    label: Text(s.videoPlayerFlipHorizontal),
                                    onSelected: _settings.setFlipHorizontal,
                                  ),
                                  const SizedBox(width: 10),
                                  FilterChip(
                                    showCheckmark: false,
                                    selected: _settings.flipVertical,
                                    label: Text(s.videoPlayerFlipVertical),
                                    onSelected: _settings.setFlipVertical,
                                  ),
                                  if (!kIsWeb &&
                                      (defaultTargetPlatform ==
                                              TargetPlatform.android ||
                                          defaultTargetPlatform ==
                                              TargetPlatform.iOS)) ...[
                                    const SizedBox(width: 10),
                                    FilterChip(
                                      showCheckmark: false,
                                      selected: _settings.backgroundPlayback,
                                      label: Text(
                                        s.videoPlayerBackgroundPlayback,
                                      ),
                                      onSelected:
                                          _settings.setBackgroundPlayback,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          if (widget.streams.length > 1)
                            PopupMenuButton<int>(
                              tooltip: s.videoQuality,
                              initialValue: _streamIndex,
                              onSelected: (index) {
                                Navigator.pop(sheetContext);
                                unawaited(_selectStream(index));
                              },
                              itemBuilder: (_) => [
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
                              child: ListTile(
                                leading: const Icon(Icons.play_circle_outline),
                                title: Text(s.videoQuality),
                                subtitle: Text(
                                  widget.streams[_streamIndex].label,
                                ),
                              ),
                            ),
                          if (_session is VideoPlaybackAdvancedSession)
                            ListTile(
                              leading: const Icon(Icons.subtitles_outlined),
                              title: Text(s.loadSubtitle),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                unawaited(_loadExternalSubtitle());
                              },
                            ),
                          if (_session is VideoPlaybackAdvancedSession &&
                              supportsVideoSuperResolution)
                            ListTile(
                              title: Text(s.videoPlayerSuperResolution),
                              subtitle: Text(
                                _superResolutionLabel(
                                  s,
                                  _settings.superResolution,
                                ),
                              ),
                              trailing: PopupMenuButton<VideoSuperResolution>(
                                tooltip: s.videoPlayerSuperResolution,
                                onSelected: _settings.setSuperResolution,
                                itemBuilder: (context) => [
                                  for (final mode
                                      in VideoSuperResolution.values)
                                    CheckedPopupMenuItem(
                                      value: mode,
                                      checked:
                                          mode == _settings.superResolution,
                                      child: Text(
                                        _superResolutionLabel(s, mode),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ListTile(
                            leading: const Icon(Icons.refresh),
                            title: Text(s.videoPlayerReload),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              unawaited(_reloadSource());
                            },
                          ),
                          if (_hasPlaybackInfo)
                            ListTile(
                              leading: const Icon(Icons.info_outline),
                              title: Text(s.videoPlayerPlaybackInfo),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                unawaited(_showPlaybackInfo());
                              },
                            ),
                          ListTile(
                            leading: const Icon(Icons.timer_outlined),
                            title: Text(s.videoPlayerSleepTimer),
                            onTap: () {
                              openSleepTimer = true;
                              Navigator.pop(sheetContext);
                            },
                          ),
                          if (_session is VideoPlaybackAdvancedSession &&
                              (!_fullscreen ||
                                  _settings.showFullscreenScreenshotButton))
                            ListTile(
                              leading: const Icon(Icons.screenshot_monitor),
                              title: Text(s.videoPlayerTakeScreenshot),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                unawaited(_takeScreenshot());
                              },
                            ),
                          if (!_fullscreen ||
                              _settings.showFullscreenLockButton)
                            ListTile(
                              leading: const Icon(Icons.lock_outline),
                              title: Text(s.videoPlayerLockControls),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                _toggleControlsLock();
                              },
                            ),
                          if (canPip)
                            ListTile(
                              leading: const Icon(Icons.picture_in_picture_alt),
                              title: Text(s.videoPlayerPictureInPicture),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                unawaited(_enterPictureInPicture());
                              },
                            ),
                          ListTile(
                            leading: const Icon(Icons.settings_outlined),
                            title: Text(s.videoPlayerSettings),
                            onTap: () {
                              openPlayerSettings = true;
                              Navigator.pop(sheetContext);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
          );
        },
      );
    } finally {
      if (!_settingsRouteOpen) _settingsOpen = false;
      _endControlsInteraction();
    }
    if (openSleepTimer && mounted) {
      await showVideoSleepTimerSheet(context);
    }
    if (openPlayerSettings && mounted) await _openPlaybackSettings();
    _onSnapshotChanged();
  }

  bool get _hasPlaybackInfo {
    final session = _session;
    if (session is! VideoPlaybackAdvancedSession) return false;
    final info = session.playbackInfo;
    return info.resolution != null ||
        info.videoCodec != null ||
        info.frameRate != null ||
        info.videoBitrate != null ||
        info.audioCodec != null ||
        info.audioFormat != null;
  }

  bool _shouldShowBottomProgress(
    VideoPlaybackSnapshot snapshot, {
    required bool fullscreen,
  }) {
    if (_controlsVisible ||
        _loading ||
        snapshot.duration <= Duration.zero ||
        _error != null ||
        snapshot.error != null) {
      return false;
    }
    return switch (_settings.bottomProgressMode) {
      VideoBottomProgressMode.always => true,
      VideoBottomProgressMode.never => false,
      VideoBottomProgressMode.fullscreenOnly => fullscreen,
      VideoBottomProgressMode.inlineOnly => !fullscreen,
    };
  }

  Widget _buildControls(
    BuildContext context, {
    required bool fullscreen,
    required VoidCallback onFullscreen,
    VoidCallback? onSecondaryFullscreen,
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 500;
            final buttonWidth = fullscreen ? 42.0 : 35.0;
            final positionSlider = Slider(
              key: const ValueKey('video-position-slider'),
              min: 0,
              max: durationMs > 0 ? durationMs.toDouble() : 1,
              value: durationMs > 0 ? positionMs : 0,
              secondaryTrackValue: durationMs > 0
                  ? snapshot.bufferPosition.inMilliseconds.toDouble().clamp(
                      0,
                      durationMs.toDouble(),
                    )
                  : null,
              onChangeStart: durationMs <= 0
                  ? null
                  : (_) => _beginControlsInteraction(),
              onChanged: durationMs <= 0
                  ? null
                  : (value) =>
                        _previewSeek(Duration(milliseconds: value.round())),
              onChangeEnd: durationMs <= 0
                  ? null
                  : (_) {
                      _finishSeek();
                      _endControlsInteraction();
                    },
            );
            final styledPositionSlider = SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor:
                    Theme.of(context).brightness == Brightness.light
                    ? Theme.of(context).colorScheme.inversePrimary
                    : Theme.of(context).colorScheme.primary,
                trackHeight: 3.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 25),
                inactiveTrackColor: const Color(0x33FFFFFF),
                secondaryActiveTrackColor:
                    (Theme.of(context).brightness == Brightness.light
                            ? Theme.of(context).colorScheme.inversePrimary
                            : Theme.of(context).colorScheme.primary)
                        .withValues(alpha: .4),
                thumbColor: Theme.of(context).brightness == Brightness.light
                    ? Theme.of(context).colorScheme.inversePrimary
                    : Theme.of(context).colorScheme.primary,
                overlayColor:
                    (Theme.of(context).brightness == Brightness.light
                            ? Theme.of(context).colorScheme.inversePrimary
                            : Theme.of(context).colorScheme.primary)
                        .withAlpha(80),
              ),
              child: positionSlider,
            );
            final times = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(position),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                const Text(' / ', style: TextStyle(color: Colors.white70)),
                Text(
                  _formatTime(snapshot.duration),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            );
            final quickControls = <Widget>[
              if (fullscreen || !compact)
                PopupMenuButton<VideoPlayerFit>(
                  tooltip: s.videoPlayerAspectRatio,
                  padding: EdgeInsets.zero,
                  initialValue: _settings.fit,
                  onOpened: _beginControlsInteraction,
                  onCanceled: _endControlsInteraction,
                  onSelected: (fit) {
                    _endControlsInteraction();
                    unawaited(_settings.setFit(fit));
                  },
                  itemBuilder: (context) => [
                    for (final fit in VideoPlayerFit.values)
                      PopupMenuItem(value: fit, child: Text(_fitLabel(s, fit))),
                  ],
                  child: SizedBox(
                    width: buttonWidth,
                    height: 30,
                    child: const Icon(
                      Icons.fit_screen,
                      color: Colors.white,
                      size: 19,
                    ),
                  ),
                ),
              if (snapshot.subtitleTracks.isNotEmpty)
                PopupMenuButton<String>(
                  key: const ValueKey('video-subtitle-menu'),
                  tooltip: s.videoPlayerSubtitleTrack,
                  padding: EdgeInsets.zero,
                  initialValue: _selectedSubtitleTrackId,
                  onOpened: _beginControlsInteraction,
                  onCanceled: _endControlsInteraction,
                  onSelected: (id) {
                    _endControlsInteraction();
                    unawaited(_selectSubtitleTrack(id));
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'no',
                      child: Text(
                        '${s.videoPlayerSubtitleTrack}: ${s.noSubtitle}',
                      ),
                    ),
                    for (final track in snapshot.subtitleTracks)
                      PopupMenuItem(
                        value: track.id,
                        child: Text(
                          '${s.videoPlayerSubtitleTrack}: ${track.label}',
                        ),
                      ),
                  ],
                  child: SizedBox(
                    width: buttonWidth,
                    height: 30,
                    child: const Icon(
                      Icons.closed_caption,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              PopupMenuButton<double>(
                tooltip: s.playbackSpeed,
                padding: EdgeInsets.zero,
                initialValue: snapshot.rate,
                onOpened: _beginControlsInteraction,
                onCanceled: _endControlsInteraction,
                onSelected: (rate) {
                  _endControlsInteraction();
                  _setRuntimeRate(rate);
                },
                itemBuilder: (context) => [
                  for (final rate in _settings.speedList)
                    PopupMenuItem(value: rate, child: Text('${rate}X')),
                ],
                child: SizedBox(
                  width: buttonWidth,
                  height: 30,
                  child: Center(
                    child: Text(
                      '${snapshot.rate}X',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
              ),
              if (widget.streams.length > 1 && (fullscreen || !compact))
                PopupMenuButton<int>(
                  tooltip: s.videoQuality,
                  padding: EdgeInsets.zero,
                  initialValue: _streamIndex,
                  onOpened: _beginControlsInteraction,
                  onCanceled: _endControlsInteraction,
                  onSelected: (index) {
                    _endControlsInteraction();
                    unawaited(_selectStream(index));
                  },
                  itemBuilder: (context) => [
                    for (var index = 0; index < widget.streams.length; index++)
                      PopupMenuItem(
                        value: index,
                        child: Text(widget.streams[index].label),
                      ),
                  ],
                  child: SizedBox(
                    width: buttonWidth,
                    height: 30,
                    child: Center(
                      child: Text(
                        widget.streams[_streamIndex].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              GestureDetector(
                onSecondaryTap: fullscreen ? null : onSecondaryFullscreen,
                child: IconButton(
                  key: const ValueKey('video-fullscreen-control'),
                  tooltip: s.videoFullscreen,
                  color: Colors.white,
                  icon: Icon(
                    fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    size: 24,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints.tightFor(
                    width: buttonWidth,
                    height: 30,
                  ),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: Size(buttonWidth, 30),
                    maximumSize: Size(buttonWidth, 30),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: onFullscreen,
                ),
              ),
            ];
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 7),
                  child: styledPositionSlider,
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: snapshot.playing ? s.pause : s.videoPlay,
                      color: Colors.white,
                      icon: Icon(
                        snapshot.playing ? Icons.pause : Icons.play_arrow,
                        size: 20,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints.tightFor(
                        width: buttonWidth,
                        height: 30,
                      ),
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: Size(buttonWidth, 30),
                        maximumSize: Size(buttonWidth, 30),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: _togglePlayback,
                    ),
                    const SizedBox(width: 8),
                    times,
                    const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: quickControls,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
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
    if (_fullscreen || _pictureInPictureRouteOpen) {
      return const ColoredBox(
        key: ValueKey('video-fullscreen-placeholder'),
        color: Colors.black,
      );
    }
    return _buildPlayerLayout(
      context,
      fullscreen: false,
      onFullscreen: () => _enterFullscreen(nativeFullscreen: _isDesktop),
      onSecondaryFullscreen: () => _enterFullscreen(nativeFullscreen: false),
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
    _fullscreenStatusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _route?.secondaryAnimation?.removeListener(_onRouteTransition);
    _session.snapshot.removeListener(_onSnapshotChanged);
    _settings.removeListener(_onSettingsChanged);
    _platform.pictureInPicture.removeListener(_onPictureInPictureChanged);
    VideoSleepTimer.shared.removeListener(_onSleepTimerChanged);
    _settings.dispose();
    VideoSleepTimer.shared.detach(this);
    _gestureOverlayTimer?.cancel();
    _focusNode.dispose();
    _uiRevision.dispose();
    _inlineViewportHeight.dispose();
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
        await _platform.setKeepScreenOn(false);
        await _platform.dispose();
      } catch (_) {}
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

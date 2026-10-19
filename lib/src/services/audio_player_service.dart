import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path/path.dart' as p;
import 'package:smtc_windows/smtc_windows.dart';

import '../models/audio_track.dart';
import '../models/audio_gain_settings.dart';
import '../models/playback_diagnostic_event.dart';
import '../performance/performance_build_guard.dart';
import '../performance/performance_recorder.dart';
import 'cache_service.dart';
import 'audio_cache_downloader.dart';
import 'audio_cache_files.dart';
import 'audio_haptics_service.dart';
import 'log_service.dart';
import 'playback_history_service.dart';
import 'playback_session_store.dart';
import 'download_path_service.dart';
import 'storage_service.dart';
import 'shared_http_client.dart';
import 'speculative_transfer_coordinator.dart';
import '../utils/image_blur_util.dart';
import '../utils/local_file_url.dart';
import '../utils/reorder_utils.dart';

final _log = LogService.instance;

enum EnqueueNextResult {
  inserted,
  moved,
  alreadyNext,
  currentTrack,
  noActiveQueue,
}

enum ManualSkipDirection { previous, next }

@immutable
class ManualSkipAvailability {
  const ManualSkipAvailability({
    required this.canSkipNext,
    required this.canSkipPrevious,
  });

  static const unavailable = ManualSkipAvailability(
    canSkipNext: false,
    canSkipPrevious: false,
  );

  final bool canSkipNext;
  final bool canSkipPrevious;

  @override
  bool operator ==(Object other) {
    return other is ManualSkipAvailability &&
        other.canSkipNext == canSkipNext &&
        other.canSkipPrevious == canSkipPrevious;
  }

  @override
  int get hashCode => Object.hash(canSkipNext, canSkipPrevious);
}

/// Direction used by the player presentation when a new track is published.
///
/// This is deliberately separate from [ManualSkipDirection]: a track can also
/// be published by natural completion, queue selection, or session restore.
enum PlayerTrackChangeDirection { none, previous, next }

PlayerTrackChangeDirection resolvePlayerTrackChangeDirection({
  required int currentIndex,
  required int targetIndex,
}) {
  if (targetIndex > currentIndex) {
    return PlayerTrackChangeDirection.next;
  }
  if (targetIndex < currentIndex) {
    return PlayerTrackChangeDirection.previous;
  }
  return PlayerTrackChangeDirection.none;
}

class PlayerTrackChangePresentation {
  const PlayerTrackChangePresentation({
    required this.trackId,
    required this.direction,
    required this.revision,
  });

  final String trackId;
  final PlayerTrackChangeDirection direction;
  final int revision;
}

int? resolveManualSkipTarget({
  required int queueLength,
  required int currentIndex,
  required LoopMode repeatMode,
  required ManualSkipDirection direction,
}) {
  if (queueLength <= 0 || currentIndex < 0 || currentIndex >= queueLength) {
    return null;
  }

  final offset = direction == ManualSkipDirection.next ? 1 : -1;
  final target = currentIndex + offset;
  if (target >= 0 && target < queueLength) return target;
  if (repeatMode != LoopMode.all) return null;
  return direction == ManualSkipDirection.next ? 0 : queueLength - 1;
}

class EnqueueNextQueueMutation {
  const EnqueueNextQueueMutation({
    required this.result,
    required this.queue,
    required this.currentIndex,
  });

  final EnqueueNextResult result;
  final List<AudioTrack> queue;
  final int currentIndex;
}

EnqueueNextQueueMutation planEnqueueNext({
  required List<AudioTrack> queue,
  required int currentIndex,
  required AudioTrack track,
}) {
  if (queue.isEmpty || currentIndex < 0 || currentIndex >= queue.length) {
    return EnqueueNextQueueMutation(
      result: EnqueueNextResult.noActiveQueue,
      queue: List<AudioTrack>.unmodifiable(queue),
      currentIndex: currentIndex,
    );
  }

  final currentTrackId = queue[currentIndex].id;
  if (currentTrackId == track.id) {
    return EnqueueNextQueueMutation(
      result: EnqueueNextResult.currentTrack,
      queue: List<AudioTrack>.unmodifiable(queue),
      currentIndex: currentIndex,
    );
  }

  final existingIndex = queue.indexWhere((item) => item.id == track.id);
  if (existingIndex == currentIndex + 1) {
    return EnqueueNextQueueMutation(
      result: EnqueueNextResult.alreadyNext,
      queue: List<AudioTrack>.unmodifiable(queue),
      currentIndex: currentIndex,
    );
  }

  final nextQueue = List<AudioTrack>.of(queue);
  final moved = existingIndex >= 0;
  if (moved) nextQueue.removeAt(existingIndex);
  final nextCurrentIndex = nextQueue.indexWhere(
    (item) => item.id == currentTrackId,
  );
  final insertionIndex = (nextCurrentIndex + 1)
      .clamp(0, nextQueue.length)
      .toInt();
  nextQueue.insert(insertionIndex, track);
  return EnqueueNextQueueMutation(
    result: moved ? EnqueueNextResult.moved : EnqueueNextResult.inserted,
    queue: List<AudioTrack>.unmodifiable(nextQueue),
    currentIndex: nextQueue.indexWhere((item) => item.id == currentTrackId),
  );
}

class AudioPlayerService {
  static AudioPlayerService? _instance;
  static AudioPlayerService get instance =>
      _instance ??= AudioPlayerService._();

  static const Duration _androidBackBufferDuration = Duration(seconds: 30);
  static const Duration _androidCacheStartBuffer = Duration(seconds: 15);
  static const Duration _androidCacheContinueBuffer = Duration(seconds: 5);

  AudioPlayerService._() {
    _androidNativePreload = Platform.isAndroid;
    if (Platform.isAndroid) {
      _androidLoudnessEnhancer = AndroidLoudnessEnhancer();
      _player = AudioPlayer(
        useProxyForRequestHeaders: false,
        audioLoadConfiguration: const AudioLoadConfiguration(
          androidLoadControl: AndroidLoadControl(
            bufferForPlaybackDuration: Duration(milliseconds: 750),
            bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5),
            // Keep the back buffer from crowding out forward buffering.
            backBufferDuration: _androidBackBufferDuration,
            prioritizeTimeOverSizeThresholds: true,
          ),
        ),
        audioPipeline: AudioPipeline(
          androidAudioEffects: [_androidLoudnessEnhancer!],
        ),
      );
    } else {
      _player = AudioPlayer();
    }
    _audioCacheDownloader = _createAudioCacheDownloader();
    _listenForPlaybackErrors();
  }

  late final AudioPlayer _player;

  @visibleForTesting
  AudioPlayerService.forTesting(
    AudioPlayer player, {
    PlaybackSessionStore sessionStore =
        const SharedPreferencesPlaybackSessionStore(),
    bool androidSeekRecovery = false,
    bool androidNativePreload = false,
    Duration seekRecoveryTimeout = const Duration(seconds: 8),
    AudioCacheDownloader? cacheDownloader,
  }) {
    _player = player;
    _playbackSessionStore = sessionStore;
    _androidSeekRecovery = androidSeekRecovery;
    _androidNativePreload = androidNativePreload;
    _seekRecoveryTimeout = seekRecoveryTimeout;
    _audioCacheDownloader = cacheDownloader ?? _createAudioCacheDownloader();
    _listenForPlaybackErrors();
    _setupPlayerListeners();
  }

  AudioCacheDownloader _createAudioCacheDownloader() => AudioCacheDownloader(
    files: CacheService.audioCacheFiles,
    resolveExistingFile: CacheService.getCachedAudioFile,
    headersProvider: () => StorageService.serverCookieHeaders,
    onCacheCompleted: CacheService.checkAndCleanCache,
    logger: _log.captureOutput,
  );

  AndroidLoudnessEnhancer? _androidLoudnessEnhancer;
  final AudioHapticsService _hapticsService = AudioHapticsService.instance;
  final List<AudioTrack> _queue = [];
  int _currentIndex = 0;
  AudioHandler? _audioHandler;
  LoopMode _appLoopMode = LoopMode.off; // Track loop mode at app level
  String? _tempPlaybackFilePath; // 临时音频副本路径，用于规避字幕冲突
  Directory? _tempAudioDirectory;
  AudioCacheFileLease? _cachedPlaybackLease;
  bool _isSwitchingTrack = false; // Flag to indicate track switching state
  int? _performanceActivePlaybackRequestId;
  String? _performanceActivePlaybackTrackId;

  // Track loading is a latest-wins operation. There is at most one native
  // load in flight; a newer intent cancels it once, then the drain starts the
  // newest request after the interrupted Future has unwound.
  _TrackLoadRequest? _activeTrackLoad;
  _TrackLoadRequest? _latestTrackLoad;
  Future<void>? _trackLoadDrain;
  bool _nativeLoadInFlight = false;
  bool _nativeLoadCancelIssued = false;
  Future<void>? _nativeLoadCancel;
  int _trackLoadGeneration = 0;
  int _intentRevision = 0;
  String? _pendingTargetTrackId;
  AudioTrack? _publishedTrack;
  AudioTrack? _resumeTrack;
  bool _desiredPlaying = false;
  bool _sourceNeedsReload = false;
  bool _androidSeekRecovery = Platform.isAndroid;
  late final bool _androidNativePreload;
  ConcatenatingAudioSource? _androidSourceWindow;
  String? _nativePreparedTrackId;
  String? _nativePreparingTrackId;
  String? _nativePreloadUnavailableTrackId;
  Duration? _nativePreloadCurrentPosition;
  Future<void>? _nativeWindowRefresh;
  int _nativeWindowRevision = 0;
  int _nativeWindowHandledRevision = -1;
  bool _shuffleEnabled = false;
  StreamSubscription<int?>? _currentIndexSubscription;
  int _seekRevision = 0;
  Completer<void>? _seekCancellation;
  Completer<void>? _seekError;
  Completer<void>? _nativeWindowError;
  int? _seekRecoveryGeneration;
  StreamSubscription<PlaybackEvent>? _playbackErrorSubscription;
  AudioSource? _failedSeekSource;
  Duration? _failedSeekPosition;
  Duration _seekRecoveryTimeout = const Duration(seconds: 8);
  Future<void>? _stopOperation;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  int _mediaItemRevision = 0;
  int _committedTrackGeneration = 0;
  bool _disposed = false;

  static const Duration _sessionCheckpointInterval = Duration(seconds: 5);
  PlaybackSessionStore _playbackSessionStore =
      const SharedPreferencesPlaybackSessionStore();
  late final AudioCacheDownloader _audioCacheDownloader;
  AudioCacheRequest? _audioCacheTarget;
  Future<void> _sessionWrite = Future.value();
  int _lastSessionPositionMs = 0;
  bool _isRestoringSession = false;
  bool _sessionCompleted = false;
  bool _handlingTrackCompletion = false;
  String? _sessionOwnerKey;

  // 下一首预加载：剩余时长低于此阈值时提前缓存下一首，避免切歌空档
  // null 表示关闭预加载。Android 默认 60 秒，其他平台默认 10 秒。
  Duration? _preloadThreshold = defaultTargetPlatform == TargetPlatform.android
      ? const Duration(seconds: 60)
      : const Duration(seconds: 10);
  StreamSubscription<bool>? _speculativePauseSubscription;

  static const List<String> _lyricExtensions = [
    '.lrc',
    '.srt',
    '.vtt',
    '.ass',
    '.ssa',
  ];

  static const Set<String> _audioExtensions = {
    '.mp3',
    '.wav',
    '.flac',
    '.m4a',
    '.aac',
    '.ogg',
    '.opus',
    '.wma',
    '.m4b',
  };

  bool _completionHandled = false;

  // Windows SMTC support
  SMTCWindows? _smtc;

  // Privacy mode settings
  bool _privacyEnabled = false;
  bool _privacyBlurCover = true;
  bool _privacyMaskTitle = true;
  String _privacyCustomTitle = '正在播放音频';

  // Audio haptics settings
  bool _hapticsEnabled = false;
  double _hapticsIntensity = 0.85;

  // Logical user volume and the independent global gain setting.
  double _userVolume = 1;
  double _audioGainDecibels = AudioGainSettings.defaultDecibels;
  bool _audioPassthroughEnabled = false;

  // Stream controllers
  final StreamController<List<AudioTrack>> _queueController =
      StreamController.broadcast();
  final StreamController<AudioTrack?> _currentTrackController =
      StreamController.broadcast();
  ManualSkipAvailability _manualSkipAvailability =
      ManualSkipAvailability.unavailable;
  final StreamController<ManualSkipAvailability>
  _manualSkipAvailabilityController =
      StreamController<ManualSkipAvailability>.broadcast();
  PlayerTrackChangePresentation? _lastTrackChangePresentation;
  int _trackChangeRevision = 0;
  final StreamController<bool> _trackLoadingController =
      StreamController<bool>.broadcast();
  final StreamController<AudioTrack?> _requestedTrackController =
      StreamController<AudioTrack?>.broadcast();
  final StreamController<PlaybackDiagnosticEvent>
  _playbackDiagnosticController =
      StreamController<PlaybackDiagnosticEvent>.broadcast(sync: true);
  final List<PlaybackDiagnosticEvent> _playbackDiagnostics = [];
  ProcessingState? _lastDiagnosticProcessingState;

  // Initialize the service
  Future<void> initialize() async {
    // Initialize audio service handler for system integration
    _audioHandler = await AudioService.init(
      builder: () => _AudioPlayerHandler(this),
      config: const AudioServiceConfig(
        androidNotificationChannelId:
            'com.example.kikoeru_flutter.channel.audio',
        androidNotificationChannelName: 'Kikoeru Audio',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
        androidShowNotificationBadge: true,
      ),
    );

    // Set initial playback state for all platforms
    _updatePlaybackState();
    _hapticsService.attachPlaybackState(
      positionProvider: () => _player.position,
      playingProvider: () => _player.playing,
    );

    // Initialize Windows SMTC (System Media Transport Controls)
    if (Platform.isWindows) {
      try {
        _smtc = SMTCWindows(
          config: const SMTCConfig(
            fastForwardEnabled: false,
            nextEnabled: true,
            pauseEnabled: true,
            playEnabled: true,
            rewindEnabled: false,
            prevEnabled: true,
            stopEnabled: true,
          ),
        );

        // Register SMTC button callbacks
        _smtc!.buttonPressStream.listen((button) {
          if (_instance == null) return; // Prevent callback after disposal
          switch (button) {
            case PressedButton.play:
              play();
              break;
            case PressedButton.pause:
              pause();
              break;
            case PressedButton.next:
              skipToNext();
              break;
            case PressedButton.previous:
              skipToPrevious();
              break;
            case PressedButton.stop:
              stop();
              break;
            default:
              break;
          }
        });

        // Enable SMTC
        _smtc!.enableSmtc();
      } catch (e) {
        _log.captureOutput(
          '[AudioPlayerService] Failed to initialize SMTC: $e',
        );
      }
    }

    _setupPlayerListeners();
  }

  /// 更新音频会话配置（直通/独占模式）
  Future<void> updateAudioSessionConfig(bool enablePassthrough) async {
    _audioPassthroughEnabled = enablePassthrough;
    await _applyOutputLevel();

    if (!Platform.isAndroid && !Platform.isIOS) return;

    // iOS 平台如果用户认为不支持，则不应用直通配置，或者仅应用基础配置
    // 这里根据需求，如果是在 iOS 上，我们可能不希望开启 "movie" 模式，或者保持默认
    // 但为了代码一致性，我们还是允许配置，但可以通过平台判断来调整参数
    if (Platform.isIOS && enablePassthrough) {
      // 如果用户明确说 iOS 不支持，我们可以选择在这里直接返回，或者应用一个"无害"的配置
      // 暂时保持与 Android 一致的逻辑，但如果用户反馈有问题，可以随时禁用
      // _log.captureOutput('[AudioPlayerService] iOS passthrough requested but might not be fully supported.');
    }

    try {
      _log.captureOutput(
        '[AudioPlayerService] Updating AudioSession config. Passthrough enabled: $enablePassthrough',
      );
      final session = await AudioSession.instance;

      if (enablePassthrough) {
        // Keep Apple playback non-mixable so this app can own the system Now
        // Playing session. The Android attributes remain movie-oriented.
        await session.configure(
          const AudioSessionConfiguration(
            avAudioSessionCategory: AVAudioSessionCategory.playback,
            avAudioSessionMode: AVAudioSessionMode.moviePlayback,
            androidAudioAttributes: AndroidAudioAttributes(
              contentType: AndroidAudioContentType.movie,
              flags: AndroidAudioFlags.none,
              usage: AndroidAudioUsage.media,
            ),
            androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
            androidWillPauseWhenDucked: true,
          ),
        );
      } else {
        await session.configure(const AudioSessionConfiguration.music());
      }
      _log.captureOutput(
        '[AudioPlayerService] AudioSession updated successfully.',
      );
    } catch (e) {
      _log.captureOutput(
        '[AudioPlayerService] Error updating AudioSession: $e',
      );
    }
  }

  void _setupPlayerListeners() {
    _speculativePauseSubscription = SpeculativeTransferCoordinator
        .instance
        .pauseChanges
        .listen((paused) {
          _updateAudioCacheTarget();
        });

    _positionSubscription = _player.positionStream.listen((position) {
      if (_nativePreparedTrackId != null && _player.currentIndex == 0) {
        _nativePreloadCurrentPosition = position;
      }
      if (position > Duration.zero &&
          _player.playing &&
          !_isSwitchingTrack &&
          currentTrack?.id == _performanceActivePlaybackTrackId) {
        PerformanceRecorder.instance.markFirstPlaybackPosition(
          _performanceActivePlaybackRequestId,
        );
      }
      _updateAudioCacheTarget();
      _checkpointPlaybackSession(position);
      _updatePlaybackState();
    });

    _playerStateSubscription = _player.playerStateStream.listen(
      _handlePlayerState,
    );
    if (_androidNativePreload) {
      _currentIndexSubscription = _player.currentIndexStream.listen(
        _handleNativeWindowIndex,
      );
    }
  }

  void _handlePlayerState(PlayerState state) {
    if (state.processingState != ProcessingState.completed &&
        !_handlingTrackCompletion) {
      _completionHandled = false;
    }
    if (state.processingState == ProcessingState.buffering &&
        _lastDiagnosticProcessingState != ProcessingState.buffering &&
        !_isSwitchingTrack &&
        state.playing &&
        _player.position > Duration.zero) {
      _emitPlaybackDiagnostic(
        PlaybackDiagnosticEventType.unexpectedBuffering,
        currentTrack,
      );
    }
    _lastDiagnosticProcessingState = state.processingState;
    SpeculativeTransferCoordinator.instance.setPlayerBuffering(
      state.processingState == ProcessingState.loading ||
          state.processingState == ProcessingState.buffering,
    );
    if (state.processingState == ProcessingState.completed &&
        _activeTrackLoad == null &&
        _latestTrackLoad == null &&
        !_completionHandled) {
      _completionHandled = true;
      unawaited(_handleTrackCompletion());
    }

    _updateAudioCacheTarget();
    _updatePlaybackState();
  }

  // Update audio service playback state for system controls
  void _updatePlaybackState() {
    if (_audioHandler == null) return;

    final playing = _player.playing;
    final processingState = _player.processingState;

    // Determine the effective processing state
    // If we are switching tracks, force buffering state to keep system controls active
    final effectiveProcessingState = _isSwitchingTrack
        ? AudioProcessingState.buffering
        : {
                ProcessingState.idle: AudioProcessingState.idle,
                ProcessingState.loading: AudioProcessingState.loading,
                ProcessingState.buffering: AudioProcessingState.buffering,
                ProcessingState.ready: AudioProcessingState.ready,
                ProcessingState.completed: AudioProcessingState.completed,
              }[processingState] ??
              AudioProcessingState.idle;

    (_audioHandler as _AudioPlayerHandler).playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: effectiveProcessingState,
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _currentIndex >= 0 ? _currentIndex : null,
      ),
    );

    // Update Windows SMTC playback status
    if (Platform.isWindows && _smtc != null) {
      _smtc!.setPlaybackStatus(
        playing ? PlaybackStatus.Playing : PlaybackStatus.Paused,
      );
    }
  }

  // Queue management
  Future<void> updateQueue(
    List<AudioTrack> tracks, {
    int startIndex = 0,
    bool autoplay = false,
    Duration? initialPosition,
  }) async {
    if (tracks.isEmpty) {
      await clearQueue();
      return;
    }

    if (_disposed) throw StateError('AudioPlayerService is disposed');
    _sessionCompleted = false;
    _sessionOwnerKey = _currentSessionOwnerKey();
    _queue.clear();
    _queue.addAll(tracks);
    final targetIndex = startIndex.clamp(0, tracks.length - 1).toInt();
    _pendingTargetTrackId = tracks[targetIndex].id;
    _refreshManualSkipAvailability();
    _queueController.add(List.from(_queue));

    // Load the current track
    final request = _enqueueTrackLoad(
      tracks[targetIndex],
      emitCurrentTrack: true,
      autoplay: autoplay,
      direction: PlayerTrackChangeDirection.none,
      initialPosition: initialPosition,
    );
    try {
      await request.future;
    } catch (_) {
      if (!request.superseded && _isLatestTrackLoad(request)) {
        await _clearQueueAfterLoadFailure(request);
      }
      rethrow;
    }
  }

  Future<void> clearQueue() async {
    _desiredPlaying = false;
    _setAudioCacheTarget(null);
    final clearRevision = ++_intentRevision;
    final stoppedNativeLoad = await _invalidateTrackLoads();
    if (clearRevision != _intentRevision) return;

    _queue.clear();
    _currentIndex = 0;
    _pendingTargetTrackId = null;
    _publishedTrack = null;
    _resumeTrack = null;
    _performanceActivePlaybackRequestId = null;
    _performanceActivePlaybackTrackId = null;
    _desiredPlaying = false;
    _refreshManualSkipAvailability();
    _queueController.add(const []);
    _lastTrackChangePresentation = null;
    _currentTrackController.add(null);
    if (!stoppedNativeLoad) {
      _nativeLoadCancel = _player.stop();
      await _nativeLoadCancel;
    }
    if (clearRevision != _intentRevision) return;
    _updatePlaybackState();
    await _hapticsService.stop();
    if (clearRevision != _intentRevision) return;
    _releaseCachedPlaybackLease();
    if (_audioHandler case final _AudioPlayerHandler handler) {
      handler.mediaItem.add(null);
    }
    await _clearPlaybackSession();
  }

  _TrackLoadRequest _enqueueTrackLoad(
    AudioTrack track, {
    required bool emitCurrentTrack,
    required bool autoplay,
    required PlayerTrackChangeDirection direction,
    Future<void> Function(_TrackLoadRequest request)? beforeCommit,
    AudioSource? sourceToReload,
    Duration? initialPosition,
    int? nativeWindowIndex,
    bool nativeWindowAlreadyCurrent = false,
    String? nativeWindowTrackId,
  }) {
    if (_disposed) throw StateError('AudioPlayerService is disposed');

    final request = _TrackLoadRequest(
      generation: ++_trackLoadGeneration,
      track: track,
      emitCurrentTrack: emitCurrentTrack,
      direction: direction,
      beforeCommit: beforeCommit,
      sourceToReload: sourceToReload,
      initialPosition: initialPosition,
      nativeWindowIndex: nativeWindowIndex,
      nativeWindowAlreadyCurrent: nativeWindowAlreadyCurrent,
      nativeWindowTrackId: nativeWindowTrackId,
      performanceRequestId: PerformanceRecorder.instance.beginPlaybackRequest(
        track.id,
        mode: _performanceModeForTrack(track),
      ),
    );
    _cancelPendingSeek();
    _seekRecoveryGeneration = null;
    _failedSeekSource = sourceToReload;
    _failedSeekPosition = initialPosition;
    final pending = _latestTrackLoad;
    if (pending != null) {
      pending.supersede();
      _completePlaybackMeasurement(pending, incomplete: true);
      pending.complete();
    }
    _latestTrackLoad = request;
    _resumeTrack = track;
    _desiredPlaying = autoplay;
    _pendingTargetTrackId = track.id;
    _refreshManualSkipAvailability();
    _requestedTrackController.add(track);
    _intentRevision++;
    _setTrackLoading(true);
    _setAudioCacheTarget(null);

    final active = _activeTrackLoad;
    if (active != null) _cancelActiveTrackLoad(active);
    _startTrackLoadDrain();
    return request;
  }

  void _startTrackLoadDrain() {
    if (_trackLoadDrain != null) return;
    final drain = _drainTrackLoads();
    _trackLoadDrain = drain;
    unawaited(
      drain.whenComplete(() {
        if (!identical(_trackLoadDrain, drain)) return;
        _trackLoadDrain = null;
        if (_latestTrackLoad != null) _startTrackLoadDrain();
      }),
    );
  }

  Future<void> _drainTrackLoads() async {
    while (true) {
      final request = _latestTrackLoad;
      if (request == null) break;
      _latestTrackLoad = null;
      if (request.superseded) continue;

      _activeTrackLoad = request;
      _nativeLoadInFlight = false;
      try {
        final previousNativeCancel = _nativeLoadCancel;
        if (previousNativeCancel != null) {
          await _awaitNativeCancellation(previousNativeCancel);
        }
        _ensureCurrentTrackLoad(request);
        _nativeLoadCancelIssued = false;
        _nativeLoadCancel = null;
        await _loadTrack(request);
        _ensureCurrentTrackLoad(request);
        if (request.beforeCommit != null) {
          await request.beforeCommit!(request);
          _ensureCurrentTrackLoad(request);
        }
        _commitTrackLoad(request);
        request.complete();
      } on _TrackLoadSuperseded {
        request.supersede();
        _completePlaybackMeasurement(request, incomplete: true);
        request.complete();
      } catch (error, stackTrace) {
        _completePlaybackMeasurement(request, incomplete: true);
        if (!_isCurrentTrackLoad(request)) {
          request.supersede();
          request.complete();
        } else if (!request.completer.isCompleted) {
          request.completer.completeError(error, stackTrace);
        }
      } finally {
        if (identical(_activeTrackLoad, request)) {
          _activeTrackLoad = null;
        }
      }
    }

    if (_latestTrackLoad == null) {
      _pendingTargetTrackId = null;
      _refreshManualSkipAvailability();
      _requestedTrackController.add(null);
      _setTrackLoading(false);
      _updateAudioCacheTarget();
      unawaited(persistPlaybackSession());
    }
  }

  void _setTrackLoading(bool loading) {
    if (_isSwitchingTrack == loading) return;
    _isSwitchingTrack = loading;
    _trackLoadingController.add(loading);
    _updatePlaybackState();
  }

  void _cancelActiveTrackLoad(_TrackLoadRequest request) {
    request.supersede();
    _cancelNativeLoad();
  }

  void _cancelNativeLoad() {
    if (!_nativeLoadInFlight || _nativeLoadCancelIssued) return;
    _nativeLoadCancelIssued = true;
    final cancellation = _player.stop().catchError((error, stackTrace) {
      _log.captureOutput('[Audio] 中止原生加载失败: $error');
    });
    _nativeLoadCancel = cancellation;
    unawaited(cancellation);
  }

  Future<void> _awaitNativeCancellation(Future<void> cancellation) =>
      _androidSeekRecovery
      ? cancellation.timeout(_seekRecoveryTimeout)
      : cancellation;

  Future<bool> _invalidateTrackLoads() async {
    ++_trackLoadGeneration;
    _cancelPendingSeek();
    _seekRecoveryGeneration = null;
    final pending = _latestTrackLoad;
    if (pending != null) {
      pending.supersede();
      _completePlaybackMeasurement(pending, incomplete: true);
      pending.complete();
      _latestTrackLoad = null;
    }
    final active = _activeTrackLoad;
    var stoppedNativeLoad = false;
    if (active != null) {
      final wasInFlight = _nativeLoadInFlight;
      _cancelActiveTrackLoad(active);
      stoppedNativeLoad = wasInFlight && _nativeLoadCancelIssued;
    }
    final drain = _trackLoadDrain;
    if (drain != null) await drain;
    final nativeCancel = _nativeLoadCancel;
    if (nativeCancel != null) await _awaitNativeCancellation(nativeCancel);
    return stoppedNativeLoad;
  }

  bool _isCurrentTrackLoad(_TrackLoadRequest request) {
    return identical(_activeTrackLoad, request) &&
        !request.superseded &&
        request.generation == _trackLoadGeneration;
  }

  bool _isLatestTrackLoad(_TrackLoadRequest request) {
    return request.generation == _trackLoadGeneration &&
        !request.superseded &&
        identical(_activeTrackLoad, request) == false &&
        _latestTrackLoad == null;
  }

  void _ensureCurrentTrackLoad(_TrackLoadRequest request) {
    if (!_isCurrentTrackLoad(request)) throw const _TrackLoadSuperseded();
  }

  String? _performanceModeForTrack(AudioTrack track) {
    final localPath = LocalFileUrl.pathFromUrl(track.url);
    if (localPath == null) return null;
    return track.url.toLowerCase().endsWith('.audio') ? 'cache' : 'downloaded';
  }

  void _completePlaybackMeasurement(
    _TrackLoadRequest request, {
    required bool incomplete,
  }) {
    final recorder = PerformanceRecorder.instance;
    recorder.completePlaybackRequest(
      request.performanceRequestId,
      incomplete: incomplete,
    );
  }

  void _commitTrackLoad(_TrackLoadRequest request) {
    _ensureCurrentTrackLoad(request);
    final index = _queue.indexWhere((item) => item.id == request.track.id);
    if (index < 0) throw const _TrackLoadSuperseded();

    _currentIndex = index;
    _pendingTargetTrackId = null;
    _publishedTrack = request.track;
    _refreshManualSkipAvailability();
    _sourceNeedsReload = false;
    _failedSeekSource = null;
    _failedSeekPosition = null;
    _seekRecoveryGeneration = request.sourceToReload == null
        ? null
        : request.generation;
    _committedTrackGeneration = request.generation;
    if (request.emitCurrentTrack) {
      _publishCurrentTrack(request.track, direction: request.direction);
    }
    _emitPlaybackDiagnostic(
      PlaybackDiagnosticEventType.trackReady,
      request.track,
    );
    PerformanceRecorder.instance.markPlaybackPhase(
      request.performanceRequestId,
      'ready',
    );
    unawaited(
      _updateMediaItem(
        request.track,
        privacyEnabled: _privacyEnabled,
        blurCover: _privacyBlurCover,
        maskTitle: _privacyMaskTitle,
        customTitle: _privacyCustomTitle,
        generation: request.generation,
      ).catchError((Object error, StackTrace stackTrace) {
        _log.captureOutput('[Audio] Failed to update media item: $error');
      }),
    );
    if (request.nativeWindowTrackId != null) {
      _finishNativeWindowPromotion(request.track);
    }
    unawaited(persistPlaybackSession());
    if (_desiredPlaying) {
      _startPlaybackWithSideEffects(
        startHaptics: request.nativeWindowTrackId == null,
      );
    }
  }

  Future<void> _clearQueueAfterLoadFailure(_TrackLoadRequest request) async {
    if (!_isLatestTrackLoad(request)) return;
    await clearQueue();
  }

  Future<void> _loadTrack(_TrackLoadRequest request) async {
    final track = request.track;
    if (request.nativeWindowAlreadyCurrent) {
      try {
        await _waitForNativeWindowReady(request);
        request.nativeWindowTrackId = track.id;
        return;
      } catch (error) {
        if (!_isCurrentTrackLoad(request)) {
          throw const _TrackLoadSuperseded();
        }
        _log.captureOutput('[Audio] Native next was not ready: $error');
        try {
          await _player.stop().timeout(_seekRecoveryTimeout);
        } catch (stopError) {
          _log.captureOutput(
            '[Audio] Failed to stop unready native next: $stopError',
          );
        }
        _clearNativeWindowState();
      }
    }
    if (request.nativeWindowIndex != null &&
        _nativePreparedTrackId == track.id &&
        _androidSourceWindow?.children.length == 2) {
      try {
        final errorSignal = Completer<void>();
        final cancellation = Completer<void>();
        final previousCancellation = _seekCancellation;
        _seekCancellation = cancellation;
        _nativeWindowError = errorSignal;
        try {
          await Future.any<void>([
            _player.seek(null, index: request.nativeWindowIndex),
            errorSignal.future.then((_) {
              throw StateError('Native next source failed during seek');
            }),
            cancellation.future.then((_) {
              throw const _TrackLoadSuperseded();
            }),
          ]).timeout(const Duration(seconds: 3));
        } finally {
          if (identical(_seekCancellation, cancellation)) {
            _seekCancellation = previousCancellation;
          }
          if (identical(_nativeWindowError, errorSignal)) {
            _nativeWindowError = null;
          }
        }
        _ensureCurrentTrackLoad(request);
        if (_player.currentIndex != request.nativeWindowIndex) {
          throw StateError('Prepared audio source did not become current');
        }
        await _waitForNativeWindowReady(request);
        request.nativeWindowTrackId = track.id;
        return;
      } catch (error) {
        if (!_isCurrentTrackLoad(request)) {
          throw const _TrackLoadSuperseded();
        }
        _log.captureOutput('[Audio] Prepared next source seek failed: $error');
        try {
          await _player.stop().timeout(_seekRecoveryTimeout);
        } catch (stopError) {
          _log.captureOutput(
            '[Audio] Failed to stop prepared source: $stopError',
          );
        }
        _clearNativeWindowState();
      }
    }
    _emitPlaybackDiagnostic(
      PlaybackDiagnosticEventType.trackLoadStarted,
      track,
    );
    final localPath = LocalFileUrl.pathFromUrl(track.url);
    final performanceRecorder = PerformanceRecorder.instance;
    final performanceRequestId = request.performanceRequestId;
    _performanceActivePlaybackRequestId = performanceRequestId;
    _performanceActivePlaybackTrackId = track.id;
    final sourceUri = Uri.tryParse(track.url);
    final sourceKind = localPath != null
        ? 'local'
        : (sourceUri?.scheme.isNotEmpty ?? false)
        ? sourceUri!.scheme
        : 'unknown';
    _log.captureOutput(
      '[Audio] _loadTrack: id="${track.id}", title="${track.title}", '
      'source=$sourceKind',
    );

    _sessionCompleted = false;
    _lastSessionPositionMs = 0;
    _completionHandled = false;

    try {
      final sourceToReload = request.sourceToReload;
      if (sourceToReload != null) {
        // A failed Android seek can leave both the decoder and its method
        // result stuck. Deactivate the native player before preparing the same
        // source at the target; a second post-load seek would repeat that path.
        // Keep the cache lease: a seek failure does not mean a corrupt file.
        _sourceNeedsReload = true;
        final stopping = _player.stop();
        // A failed stop rejects this recovery, but must not leave a rejected
        // barrier that would prevent the next requested track from loading.
        _nativeLoadCancel = stopping.catchError((Object error) {
          _log.captureOutput('[Audio] Seek recovery stop failed: $error');
        });
        await stopping.timeout(_seekRecoveryTimeout);
        _ensureCurrentTrackLoad(request);
        await _setAudioSourceForTrackLoad(
          request,
          sourceToReload,
          initialPosition: request.initialPosition,
        );
        _hapticsService.seek(request.initialPosition!);
        return;
      }

      // Cleanup and haptics teardown are independent. Neither should add a
      // second serial wait to every user-initiated track switch.
      await Future.wait<void>([
        if (_player.playing) _player.pause(),
        _cleanupTempPlaybackFile(),
        _hapticsService.stop(),
      ]);
      _ensureCurrentTrackLoad(request);

      String? fallbackStreamUrl;
      bool loaded = false;
      final hash = track.hash;
      String? cachedPath;

      if (hash != null && hash.isNotEmpty) {
        cachedPath = await CacheService.getCachedAudioFile(hash);
        _ensureCurrentTrackLoad(request);
        if (cachedPath != null) {
          loaded = await _tryPlayCachedAudio(
            cachedPath,
            track,
            request: request,
          );
          if (!loaded) fallbackStreamUrl = _remoteAudioUrlForHash(hash);
        }
      }

      if (!loaded && localPath != null) {
        final localFile = File(localPath);
        if (await localFile.exists() &&
            (cachedPath == null ||
                !p.equals(p.normalize(localPath), p.normalize(cachedPath)))) {
          final playbackPath =
              await _prepareLocalPlaybackPath(localPath) ?? localPath;
          _ensureCurrentTrackLoad(request);
          performanceRecorder.markPlaybackPhase(
            performanceRequestId,
            'sourcePrepared',
          );
          performanceRecorder.markPlaybackPhase(
            performanceRequestId,
            'setFilePathStart',
          );
          await _setAudioSourceForTrackLoad(
            request,
            AudioSource.file(playbackPath),
            initialPosition: request.initialPosition,
          );
          performanceRecorder.markPlaybackPhase(
            performanceRequestId,
            'setFilePathEnd',
          );
          _releaseCachedPlaybackLease();
          await _prepareHapticsForDownloadedFile(
            track,
            downloadPath: localPath,
            analysisPath: playbackPath,
          );
          _log.captureOutput('[Audio] 使用本地文件播放: ${track.title}');
          loaded = true;
        }
      }

      if (!loaded) {
        final streamUrl = fallbackStreamUrl ?? track.url;
        _ensureCurrentTrackLoad(request);
        final uri = Uri.parse(streamUrl);
        final source = uri.scheme == 'file'
            ? AudioSource.file(uri.toFilePath())
            : AudioSource.uri(
                uri,
                headers: uri.scheme == 'http' || uri.scheme == 'https'
                    ? mediaRequestHeaders(
                        uri,
                        StorageService.serverCookieHeaders,
                        forceIdentityEncoding: true,
                      )
                    : null,
              );
        performanceRecorder.markPlaybackPhase(
          performanceRequestId,
          'sourcePrepared',
        );
        await _setAudioSourceForTrackLoad(
          request,
          source,
          initialPosition: request.initialPosition,
        );
        _releaseCachedPlaybackLease();
        unawaited(_hapticsService.prepareForTrack(track));
        _log.captureOutput('[Audio] 流式播放: $streamUrl');
      }
    } catch (e) {
      if (!_isCurrentTrackLoad(request)) {
        throw const _TrackLoadSuperseded();
      }
      _emitPlaybackDiagnostic(
        PlaybackDiagnosticEventType.trackLoadFailed,
        track,
        error: e,
      );
      _log.captureOutput('Error loading audio source: $e');
      rethrow;
    }
  }

  Future<void> _waitForNativeWindowReady(_TrackLoadRequest request) async {
    if (_player.currentIndex != 1 ||
        _nativePreparedTrackId != request.track.id) {
      throw StateError('Native next is no longer the prepared child');
    }
    if (_player.processingState == ProcessingState.ready) return;

    final ready = Completer<void>();
    final cancellation = Completer<void>();
    final error = Completer<void>();
    final previousCancellation = _seekCancellation;
    _seekCancellation = cancellation;
    _nativeWindowError = error;
    final subscription = _player.playerStateStream.listen((state) {
      if (_player.currentIndex == 1 &&
          state.processingState == ProcessingState.ready) {
        if (!ready.isCompleted) ready.complete();
      } else if (state.processingState == ProcessingState.idle ||
          state.processingState == ProcessingState.completed) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('Native next stopped before ready'));
        }
      }
    });
    try {
      await Future.any<void>([
        ready.future,
        cancellation.future.then((_) {
          throw const _TrackLoadSuperseded();
        }),
        error.future.then((_) {
          throw StateError('Native next source failed before ready');
        }),
      ]).timeout(_seekRecoveryTimeout);
      _ensureCurrentTrackLoad(request);
      if (_nativePreparedTrackId != request.track.id ||
          _player.currentIndex != 1 ||
          _player.processingState != ProcessingState.ready) {
        throw StateError('Native next did not remain ready');
      }
    } finally {
      await subscription.cancel();
      if (identical(_seekCancellation, cancellation)) {
        _seekCancellation = previousCancellation;
      }
      if (identical(_nativeWindowError, error)) _nativeWindowError = null;
    }
  }

  Future<void> _setAudioSourceForTrackLoad(
    _TrackLoadRequest request,
    AudioSource source, {
    Duration? initialPosition,
  }) async {
    _ensureCurrentTrackLoad(request);
    _sourceNeedsReload = true;
    _nativeLoadInFlight = true;
    if (_androidNativePreload) {
      _clearNativeWindowState();
      final window = ConcatenatingAudioSource(
        children: [source],
        useLazyPreparation: false,
      );
      _androidSourceWindow = window;
      source = window;
    }
    final loading = _player.setAudioSource(
      source,
      initialPosition: initialPosition,
    );
    try {
      if (request.sourceToReload == null) {
        await loading;
      } else {
        try {
          await loading.timeout(_seekRecoveryTimeout);
        } on TimeoutException {
          _cancelNativeLoad();
          // A late load failure also deactivates the player inside just_audio.
          // Keep both raw Futures as a barrier even if waiting for cleanup
          // times out, so a later request cannot start underneath that cleanup.
          final cleanup = Future.wait<void>([
            _nativeLoadCancel!,
            loading.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
          ]).then<void>((_) {});
          _nativeLoadCancel = cleanup;
          await _awaitNativeCancellation(cleanup);
          rethrow;
        }
      }
    } finally {
      _nativeLoadInFlight = false;
    }
    _ensureCurrentTrackLoad(request);
  }

  void _publishCurrentTrack(
    AudioTrack track, {
    required PlayerTrackChangeDirection direction,
  }) {
    _publishedTrack = track;
    _lastTrackChangePresentation = PlayerTrackChangePresentation(
      trackId: track.id,
      direction: direction,
      revision: ++_trackChangeRevision,
    );
    _currentTrackController.add(track);
  }

  // Update media item for system notification
  // privacySettings: 可选的防社死设置，如果提供则应用隐私保护
  Future<void> _updateMediaItem(
    AudioTrack track, {
    bool privacyEnabled = false,
    bool blurCover = true,
    bool maskTitle = true,
    String customTitle = '正在播放音频',
    int? generation,
  }) async {
    if (_audioHandler == null) return;
    final mediaRevision = ++_mediaItemRevision;
    if (!_isCurrentMediaItem(track, generation)) return;

    // 应用防社死设置
    String displayTitle = track.title;
    String? displayArtworkUrl = track.artworkUrl;

    if (privacyEnabled) {
      // 替换标题
      if (maskTitle) {
        displayTitle = customTitle;
      }

      // 模糊封面
      if (blurCover && displayArtworkUrl != null) {
        try {
          // 生成模糊后的封面并保存到临时文件
          final blurredFilePath = await ImageBlurUtil.blurNetworkImageToFile(
            displayArtworkUrl,
            cacheKey: track.workId == null
                ? null
                : 'work_cover_${track.workId}',
          );
          if (blurredFilePath != null) {
            displayArtworkUrl = blurredFilePath;
          } else {
            // 模糊失败，隐藏封面
            displayArtworkUrl = null;
          }
        } catch (e) {
          _log.captureOutput('模糊封面失败: $e');
          displayArtworkUrl = null;
        }
      }
    }

    if (mediaRevision != _mediaItemRevision ||
        !_isCurrentMediaItem(track, generation)) {
      return;
    }

    (_audioHandler as _AudioPlayerHandler).mediaItem.add(
      MediaItem(
        id: track.id,
        album: track.album ?? '',
        title: displayTitle,
        artist: track.artist ?? '',
        duration: track.duration,
        artUri: displayArtworkUrl != null ? Uri.parse(displayArtworkUrl) : null,
      ),
    );

    // Update Windows SMTC media info
    if (Platform.isWindows && _smtc != null) {
      _smtc!.updateMetadata(
        MusicMetadata(
          title: displayTitle,
          artist: track.artist ?? '',
          album: track.album ?? '',
          thumbnail: displayArtworkUrl,
        ),
      );
    }

    // Update playback state immediately after media item change
    _updatePlaybackState();
  }

  bool _isCurrentMediaItem(AudioTrack track, int? generation) {
    if (_publishedTrack?.id != track.id) return false;
    return generation == null || generation == _committedTrackGeneration;
  }

  // Handle track completion logic
  Future<void> _handleTrackCompletion() async {
    if (_sessionCompleted ||
        _handlingTrackCompletion ||
        _activeTrackLoad != null ||
        _latestTrackLoad != null) {
      return;
    }
    _handlingTrackCompletion = true;
    try {
      if (_appLoopMode == LoopMode.one) {
        // Single track repeat - replay current track
        final completedTrack = currentTrack;
        final completionRevision = _intentRevision;
        final completionGeneration = _trackLoadGeneration;
        await seek(Duration.zero);
        final sameTrack = identical(currentTrack, completedTrack);
        final unchangedIntent =
            completionRevision == _intentRevision &&
            completionGeneration == _trackLoadGeneration;
        final recoveredSameTrack =
            sameTrack && _seekRecoveryGeneration == _trackLoadGeneration;
        if (!_disposed &&
            _desiredPlaying &&
            sameTrack &&
            (unchangedIntent || recoveredSameTrack)) {
          unawaited(play());
        }
      } else if (_currentIndex < _queue.length - 1) {
        // Has next track - play it
        await _switchToIndexAndPlay(
          _currentIndex + 1,
          direction: PlayerTrackChangeDirection.next,
        );
      } else if (_appLoopMode == LoopMode.all && _queue.isNotEmpty) {
        // List repeat - go back to first track
        await _switchToIndexAndPlay(
          0,
          direction: PlayerTrackChangeDirection.next,
        );
      } else {
        // A naturally completed non-looping queue must not reappear next launch.
        final completedTrack = currentTrack;
        final completionRevision = _intentRevision;
        final completionGeneration = _trackLoadGeneration;
        _sessionCompleted = true;
        await pause();
        if (_disposed ||
            completionRevision != _intentRevision ||
            completionGeneration != _trackLoadGeneration ||
            !identical(currentTrack, completedTrack) ||
            !_sessionCompleted) {
          return;
        }
        await _clearPlaybackSession();
      }
    } catch (e) {
      _log.captureOutput('[Audio] Failed to advance playback queue: $e');
    } finally {
      if (_player.processingState != ProcessingState.completed) {
        _completionHandled = false;
      }
      _handlingTrackCompletion = false;
    }
  }

  void _updateAudioCacheTarget() {
    AudioCacheRequest? target;
    if (!_disposed &&
        _desiredPlaying &&
        _player.playing &&
        _player.processingState == ProcessingState.ready &&
        !_isSwitchingTrack &&
        _activeTrackLoad == null &&
        _latestTrackLoad == null &&
        !SpeculativeTransferCoordinator
            .instance
            .shouldPauseSpeculativeTransfers) {
      final source = _currentNativeSource() ?? _player.audioSource;
      final position = _player.position;
      final duration = _player.duration;
      final threshold = _preloadThreshold;
      if (threshold != null &&
          threshold > Duration.zero &&
          _appLoopMode != LoopMode.one &&
          duration != null &&
          duration > Duration.zero &&
          duration - position <= threshold &&
          hasNext) {
        if (!_androidNativePreload ||
            defaultTargetPlatform != TargetPlatform.android) {
          target = _audioCacheRequestForTrack(_queue[_currentIndex + 1]);
        }
      }
      target ??= _audioCacheRequestForTrack(currentTrack);
      if (target != null &&
          defaultTargetPlatform == TargetPlatform.android &&
          source is UriAudioSource &&
          (source.uri.scheme == 'http' || source.uri.scheme == 'https')) {
        final existing = _audioCacheTarget;
        final isContinuingTarget =
            existing?.hash == target.hash && existing?.uri == target.uri;
        final requiredBuffer = isContinuingTarget
            ? _androidCacheContinueBuffer
            : _androidCacheStartBuffer;
        final remaining = duration == null
            ? requiredBuffer
            : duration - position;
        final minimumBuffer = remaining <= Duration.zero
            ? Duration.zero
            : remaining < requiredBuffer
            ? remaining
            : requiredBuffer;
        if (remaining <= Duration.zero ||
            _player.bufferedPosition - position < minimumBuffer) {
          target = null;
        }
      }
    }
    _setAudioCacheTarget(target);
    _scheduleNativeWindowRefresh();
  }

  void _scheduleNativeWindowRefresh() {
    if (!_androidNativePreload || _disposed) return;
    _nativeWindowRevision++;
    if (_nativeWindowRefresh != null) return;
    final refresh = _drainNativeWindowRefreshes();
    _nativeWindowRefresh = refresh;
    unawaited(
      refresh.whenComplete(() {
        if (!identical(_nativeWindowRefresh, refresh)) return;
        _nativeWindowRefresh = null;
        if (!_disposed &&
            _nativeWindowHandledRevision != _nativeWindowRevision) {
          _scheduleNativeWindowRefresh();
        }
      }),
    );
  }

  Future<void> _drainNativeWindowRefreshes() async {
    while (!_disposed &&
        _nativeWindowHandledRevision != _nativeWindowRevision) {
      _nativeWindowHandledRevision = _nativeWindowRevision;
      await _refreshNativeWindow();
    }
  }

  Future<void> _refreshNativeWindow() async {
    final window = _androidSourceWindow;
    if (window == null) return;
    final preparedId = _nativePreparedTrackId;
    // The player has already entered the prepared child; let the index handler
    // commit it before any cache/buffer update can remove it.
    if (_player.currentIndex == 1 && preparedId != null) return;

    final current = currentTrack;
    final next = _currentIndex + 1 < _queue.length
        ? _queue[_currentIndex + 1]
        : null;
    if (next?.id != _nativePreloadUnavailableTrackId) {
      _nativePreloadUnavailableTrackId = null;
    }
    final threshold = _preloadThreshold;
    final duration = _player.duration;
    final requiredBuffer = _nativePreparedTrackId == next?.id
        ? _androidCacheContinueBuffer
        : _androidCacheStartBuffer;
    final remaining = duration == null
        ? requiredBuffer
        : duration - _player.position;
    final minimumBuffer = remaining <= Duration.zero
        ? Duration.zero
        : remaining < requiredBuffer
        ? remaining
        : requiredBuffer;
    final eligible =
        !_disposed &&
        _desiredPlaying &&
        _player.playing &&
        _player.processingState == ProcessingState.ready &&
        !_isSwitchingTrack &&
        _activeTrackLoad == null &&
        _latestTrackLoad == null &&
        !SpeculativeTransferCoordinator
            .instance
            .shouldPauseSpeculativeTransfers &&
        threshold != null &&
        threshold > Duration.zero &&
        _appLoopMode != LoopMode.one &&
        !_shuffleEnabled &&
        current != null &&
        next != null &&
        duration != null &&
        duration - _player.position <= threshold &&
        remaining > Duration.zero &&
        _player.bufferedPosition - _player.position >= minimumBuffer &&
        _player.currentIndex == 0;
    final uri = next == null ? null : Uri.tryParse(next.url);
    if (!eligible ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      if (window.children.length > 1) await _removeNativeNext(window);
      return;
    }
    if (_nativePreloadUnavailableTrackId == next.id) {
      if (window.children.length > 1) await _removeNativeNext(window);
      return;
    }
    if (_nativePreparedTrackId == next.id ||
        _nativePreparingTrackId == next.id) {
      return;
    }
    if (window.children.length > 1) await _removeNativeNext(window);

    final capturedCurrentId = current.id;
    final capturedNextId = next.id;
    final capturedIntent = _intentRevision;
    final capturedGeneration = _trackLoadGeneration;
    final hash = next.hash;
    if (hash != null && hash.isNotEmpty) {
      try {
        // Complete cache files still use the ordinary leased load path on tap.
        final cachedPath = await CacheService.getCachedAudioFile(hash);
        if (cachedPath != null) {
          _nativePreloadUnavailableTrackId = capturedNextId;
          return;
        }
      } catch (error) {
        _log.captureOutput('[Audio] Next cache lookup failed: $error');
      }
    }
    if (!_canPrepareNativeNext(
      capturedCurrentId,
      capturedNextId,
      capturedIntent,
      capturedGeneration,
    )) {
      return;
    }

    final source = AudioSource.uri(
      uri,
      headers: mediaRequestHeaders(
        uri,
        StorageService.serverCookieHeaders,
        forceIdentityEncoding: true,
      ),
    );
    _nativePreparingTrackId = capturedNextId;
    _nativePreloadCurrentPosition = _player.position;
    try {
      await window.add(source);
      if (!_canPrepareNativeNext(
        capturedCurrentId,
        capturedNextId,
        capturedIntent,
        capturedGeneration,
      )) {
        if (window.children.length > 1) await _removeNativeNext(window);
        return;
      }
      _nativePreparedTrackId = capturedNextId;
    } catch (error) {
      _nativePreloadUnavailableTrackId = capturedNextId;
      _log.captureOutput('[Audio] Native next preparation failed: $error');
      if (window.children.length > 1) {
        try {
          await _removeNativeNext(window);
        } catch (_) {}
      }
    } finally {
      if (_nativePreparingTrackId == capturedNextId) {
        _nativePreparingTrackId = null;
      }
    }
  }

  bool _canPrepareNativeNext(
    String currentId,
    String nextId,
    int intentRevision,
    int trackLoadGeneration,
  ) {
    final duration = _player.duration;
    final threshold = _preloadThreshold;
    final requiredBuffer =
        _nativePreparingTrackId == nextId || _nativePreparedTrackId == nextId
        ? _androidCacheContinueBuffer
        : _androidCacheStartBuffer;
    final remaining = duration == null
        ? Duration.zero
        : duration - _player.position;
    final minimumBuffer = remaining <= Duration.zero
        ? Duration.zero
        : remaining < requiredBuffer
        ? remaining
        : requiredBuffer;
    return !_disposed &&
        _intentRevision == intentRevision &&
        _trackLoadGeneration == trackLoadGeneration &&
        currentTrack?.id == currentId &&
        _currentIndex + 1 < _queue.length &&
        _queue[_currentIndex + 1].id == nextId &&
        threshold != null &&
        threshold > Duration.zero &&
        duration != null &&
        duration - _player.position <= threshold &&
        _appLoopMode != LoopMode.one &&
        !_shuffleEnabled &&
        _desiredPlaying &&
        _player.playing &&
        _player.processingState == ProcessingState.ready &&
        _player.currentIndex == 0 &&
        remaining > Duration.zero &&
        _player.bufferedPosition - _player.position >= minimumBuffer &&
        !SpeculativeTransferCoordinator
            .instance
            .shouldPauseSpeculativeTransfers;
  }

  Future<void> _removeNativeNext(ConcatenatingAudioSource window) async {
    if (window.children.length < 2 || _player.currentIndex == 1) return;
    _clearNativePreparedTrack();
    await window.removeAt(1);
  }

  void _clearNativePreparedTrack() {
    _nativePreparedTrackId = null;
    _nativePreparingTrackId = null;
    _nativePreloadCurrentPosition = null;
  }

  void _clearNativeWindowState() {
    _clearNativePreparedTrack();
    _androidSourceWindow = null;
  }

  AudioSource? _currentNativeSource() {
    final window = _androidSourceWindow;
    if (window == null) return _player.audioSource;
    final index = _player.currentIndex ?? 0;
    if (index < 0 || index >= window.children.length) return null;
    return window.children[index];
  }

  void _handleNativeWindowIndex(int? index) {
    if (!_androidNativePreload ||
        index != 1 ||
        _disposed ||
        _activeTrackLoad != null ||
        _latestTrackLoad != null ||
        _nativePreparedTrackId == null ||
        _currentIndex + 1 >= _queue.length ||
        _queue[_currentIndex + 1].id != _nativePreparedTrackId ||
        _player.currentIndex != 1) {
      return;
    }
    final next = _queue[_currentIndex + 1];
    final request = _enqueueTrackLoad(
      next,
      emitCurrentTrack: true,
      autoplay: _desiredPlaying,
      direction: PlayerTrackChangeDirection.next,
      nativeWindowAlreadyCurrent: true,
      nativeWindowTrackId: next.id,
    );
    unawaited(
      request.future.catchError((Object error) {
        _log.captureOutput('[Audio] Native next commit failed: $error');
      }),
    );
  }

  void _finishNativeWindowPromotion(AudioTrack track) {
    final window = _androidSourceWindow;
    if (window == null || window.children.length < 2) return;
    _clearNativePreparedTrack();
    final committedGeneration = _committedTrackGeneration;
    unawaited(_prepareNativePromotionHaptics(track, committedGeneration));
    final previousLease = _cachedPlaybackLease;
    if (identical(_cachedPlaybackLease, previousLease)) {
      _cachedPlaybackLease = null;
    }
    unawaited(
      window
          .removeAt(0)
          .then((_) {
            previousLease?.release();
            if (_shuffleEnabled) {
              unawaited(_player.setShuffleModeEnabled(true));
            }
            _scheduleNativeWindowRefresh();
          })
          .catchError((Object error) {
            _log.captureOutput(
              '[Audio] Failed to roll native source window: $error',
            );
          }),
    );
  }

  Future<void> _prepareNativePromotionHaptics(
    AudioTrack track,
    int generation,
  ) async {
    await _hapticsService.stop();
    if (_disposed ||
        generation != _committedTrackGeneration ||
        currentTrack?.id != track.id ||
        !_hapticsEnabled) {
      return;
    }
    await _hapticsService.prepareForTrack(track);
    if (!_disposed &&
        generation == _committedTrackGeneration &&
        currentTrack?.id == track.id &&
        _desiredPlaying) {
      _hapticsService.start();
    }
  }

  AudioCacheRequest? _audioCacheRequestForTrack(AudioTrack? track) {
    final hash = track?.hash;
    final uri = track == null ? null : Uri.tryParse(track.url);
    if (hash == null ||
        hash.isEmpty ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return AudioCacheRequest(uri: uri, hash: hash);
  }

  void _setAudioCacheTarget(AudioCacheRequest? target) {
    final previous = _audioCacheTarget;
    if (previous?.hash == target?.hash && previous?.uri == target?.uri) {
      return;
    }
    _audioCacheTarget = target;
    unawaited(
      _audioCacheDownloader.setTarget(target).catchError((Object error) {
        _log.captureOutput('[Audio] 后台缓存失败: $error');
        return false;
      }),
    );
  }

  // Playback controls
  Future<void> play() async {
    _desiredPlaying = true;
    if (_stopOperation != null ||
        _activeTrackLoad != null ||
        _latestTrackLoad != null) {
      _updatePlaybackState();
      return;
    }
    final published = _publishedTrack;
    final track =
        published != null && _queue.any((item) => item.id == published.id)
        ? published
        : _resumeTrack;
    if (track == null) return;
    if (_sourceNeedsReload || published?.id != track.id) {
      await _enqueueTrackLoad(
        track,
        emitCurrentTrack: published?.id != track.id,
        autoplay: true,
        direction: PlayerTrackChangeDirection.none,
        sourceToReload: _failedSeekSource,
        initialPosition: _failedSeekPosition,
      ).future;
      return;
    }
    _startPlaybackWithSideEffects();
  }

  void _startPlaybackWithSideEffects({bool startHaptics = true}) {
    _sessionCompleted = false;

    final playbackGeneration = _committedTrackGeneration;
    final playbackTrackId = currentTrack?.id;
    final playback = _player.play();
    _updatePlaybackState();
    _updateAudioCacheTarget();
    if (_hapticsEnabled && startHaptics) {
      _hapticsService.start();
    }
    // Position persistence is serialized by the session store and is not
    // required before audio starts. Keeping it off the user-visible play/switch
    // path avoids a SharedPreferences round trip on every track change.
    unawaited(persistPlaybackPosition());

    // just_audio completes this Future when playback is paused, stopped, or
    // reaches the end. Keep observing errors without blocking callers for the
    // lifetime of the track.
    unawaited(
      playback.catchError((Object error, StackTrace stackTrace) {
        if (_activeTrackLoad != null ||
            _latestTrackLoad != null ||
            _committedTrackGeneration != playbackGeneration ||
            _publishedTrack?.id != playbackTrackId) {
          return;
        }
        _emitPlaybackDiagnostic(
          PlaybackDiagnosticEventType.playbackError,
          currentTrack,
          error: error,
        );
        _log.captureOutput('[Audio] Playback failed: $error');
      }),
    );
  }

  Future<void> pause() async {
    _desiredPlaying = false;
    _setAudioCacheTarget(null);
    final revision = _intentRevision;
    await _player.pause();
    if (_desiredPlaying || revision != _intentRevision) return;
    _updatePlaybackState();
    await _hapticsService.pause();
    await persistPlaybackPosition();
  }

  Future<void> stop() async {
    _desiredPlaying = false;
    _setAudioCacheTarget(null);
    final stopRevision = ++_intentRevision;
    final operation = _stopPlayback(stopRevision);
    _stopOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_stopOperation, operation)) {
        _stopOperation = null;
        if (_desiredPlaying) await play();
      }
    }
  }

  Future<void> _stopPlayback(int stopRevision) async {
    final stoppedNativeLoad = await _invalidateTrackLoads();
    if (stopRevision != _intentRevision) return;
    if (!stoppedNativeLoad) _nativeLoadCancel = _player.stop();
    if (_nativeLoadCancel != null) await _nativeLoadCancel!;
    if (stopRevision != _intentRevision) return;
    _updatePlaybackState();
    await _hapticsService.stop();
    if (stopRevision != _intentRevision) return;
    await persistPlaybackPosition();
  }

  void _listenForPlaybackErrors() {
    if (!_androidSeekRecovery) return;
    _playbackErrorSubscription = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        final nativeCandidate =
            _nativePreparingTrackId ?? _nativePreparedTrackId;
        if (_androidNativePreload &&
            nativeCandidate != null &&
            _seekError == null) {
          _handleNativePreloadError(nativeCandidate, error, stackTrace);
          return;
        }
        if (_disposed ||
            _sourceNeedsReload ||
            _stopOperation != null ||
            _activeTrackLoad != null ||
            _latestTrackLoad != null ||
            _seekRecoveryGeneration != _trackLoadGeneration ||
            currentTrack == null) {
          return;
        }
        final source = _currentNativeSource();
        if (source == null) return;
        _failedSeekSource = source;
        _failedSeekPosition = _player.position;
        _sourceNeedsReload = true;
        final seekError = _seekError;
        if (seekError != null) {
          if (!seekError.isCompleted) {
            seekError.completeError(error, stackTrace);
          }
          return;
        }
        // Errors can arrive after the native seek callback has returned READY.
        // Pause the failed source; explicit play reloads it at this position.
        // Recovery errors never start an automatic reload loop.
        _emitPlaybackDiagnostic(
          PlaybackDiagnosticEventType.playbackError,
          currentTrack,
          error: error,
        );
        unawaited(
          pause().catchError((Object pauseError) {
            _log.captureOutput(
              '[Audio] Pause after playback error failed: $pauseError',
            );
          }),
        );
      },
    );
  }

  void _handleNativePreloadError(
    String candidateId,
    Object error,
    StackTrace stackTrace,
  ) {
    final window = _androidSourceWindow;
    final track = currentTrack;
    if (_disposed ||
        window == null ||
        window.children.isEmpty ||
        track == null) {
      return;
    }
    _nativePreloadUnavailableTrackId = candidateId;
    final currentSource = window.children.first;
    final position = _nativePreloadCurrentPosition ?? _player.position;
    final nativeWindowError = _nativeWindowError;
    if (nativeWindowError != null && !nativeWindowError.isCompleted) {
      nativeWindowError.complete();
    }
    _clearNativePreparedTrack();
    _log.captureOutput('[Audio] Native next source error: $error');
    if (_activeTrackLoad != null || _latestTrackLoad != null) return;

    final request = _enqueueTrackLoad(
      track,
      emitCurrentTrack: false,
      autoplay: _desiredPlaying,
      direction: PlayerTrackChangeDirection.none,
      sourceToReload: currentSource,
      initialPosition: position,
    );
    unawaited(
      request.future.catchError((
        Object recoveryError,
        StackTrace recoveryStack,
      ) {
        _log.captureOutput(
          '[Audio] Current source recovery after next error failed: $recoveryError',
        );
      }),
    );
  }

  Future<bool> seek(Duration position) async {
    var targetPosition = position;
    final trackAtStart = currentTrack;
    final pendingTrackLoad = _latestTrackLoad ?? _activeTrackLoad;
    _TrackLoadRequest? sameTrackReloadRequest;
    if (pendingTrackLoad != null &&
        !pendingTrackLoad.emitCurrentTrack &&
        pendingTrackLoad.track.id == trackAtStart?.id) {
      sameTrackReloadRequest = pendingTrackLoad;
    }
    if ((_sourceNeedsReload ||
            _isSwitchingTrack ||
            _activeTrackLoad != null ||
            _latestTrackLoad != null) &&
        sameTrackReloadRequest == null) {
      return false;
    }
    final generation = _trackLoadGeneration;
    final revision = ++_seekRevision;
    _cancelPendingSeek();
    bool isCurrentSeek() =>
        !_disposed &&
        generation == _trackLoadGeneration &&
        revision == _seekRevision;
    bool isCurrentSeekLoad(_TrackLoadRequest request) =>
        !_disposed && revision == _seekRevision && _isLatestTrackLoad(request);

    if (sameTrackReloadRequest != null) {
      sameTrackReloadRequest.latestSeekPosition = targetPosition;
      await sameTrackReloadRequest.future;
      if (!isCurrentSeek() ||
          !_isLatestTrackLoad(sameTrackReloadRequest) ||
          currentTrack?.id != trackAtStart?.id) {
        return false;
      }
      final duration = _player.duration;
      if (duration != null && targetPosition > duration) {
        targetPosition = duration;
        sameTrackReloadRequest.latestSeekPosition = targetPosition;
      }
    }

    final source = _androidSeekRecovery ? _currentNativeSource() : null;
    final track = currentTrack;
    _TrackLoadRequest? cachedTrackLoad;
    bool isCurrentSeekResult([_TrackLoadRequest? cacheReload]) =>
        cacheReload == null ? isCurrentSeek() : isCurrentSeekLoad(cacheReload);

    if (source is UriAudioSource &&
        (source.uri.scheme == 'http' || source.uri.scheme == 'https') &&
        track != null &&
        sameTrackReloadRequest == null) {
      final currentPosition = _player.position;
      final outsideBuffer =
          targetPosition > _player.bufferedPosition ||
          targetPosition < currentPosition - _androidBackBufferDuration;
      final hash = track.hash;
      if (outsideBuffer && hash != null && hash.isNotEmpty) {
        String? cachedPath;
        try {
          cachedPath = await CacheService.getCachedAudioFile(hash);
        } catch (error) {
          _log.captureOutput('[Audio] Cached seek lookup failed: $error');
        }
        if (!isCurrentSeek()) return false;

        final latestPosition = _player.position;
        final stillOutsideBuffer =
            targetPosition > _player.bufferedPosition ||
            targetPosition < latestPosition - _androidBackBufferDuration;
        if (cachedPath != null && stillOutsideBuffer) {
          cachedTrackLoad = _enqueueTrackLoad(
            track,
            emitCurrentTrack: false,
            autoplay: _desiredPlaying,
            direction: PlayerTrackChangeDirection.none,
            initialPosition: targetPosition,
          );
          await cachedTrackLoad.future;
          if (!isCurrentSeekLoad(cachedTrackLoad)) return false;
        }
      }
    }

    if (cachedTrackLoad == null && source != null && track != null) {
      _seekRecoveryGeneration = generation;
      final previousPosition = _player.position;
      final cancellation = Completer<void>();
      _seekCancellation = cancellation;
      final nativeError = Completer<void>();
      _seekError = nativeError;
      // just_audio 0.9.44 reports Android seek errors on this stream without
      // completing seek(). Its derived playerStateStream discards the errors.
      try {
        await Future.any<void>([
          _player.seek(targetPosition),
          nativeError.future,
          cancellation.future,
        ]).timeout(_seekRecoveryTimeout);
        if (isCurrentSeek() && _sourceNeedsReload) await nativeError.future;
      } catch (error) {
        if (!isCurrentSeek()) return false;
        // No-op and end-of-track seeks may have no READY transition to finish
        // the native callback. A distant seek with stale READY is not success.
        final readyWithoutCallback =
            error is TimeoutException &&
            ((_player.processingState == ProcessingState.ready &&
                    targetPosition.inMilliseconds ==
                        previousPosition.inMilliseconds) ||
                (_player.processingState == ProcessingState.completed &&
                    _player.duration != null &&
                    targetPosition >= _player.duration!));
        if (!readyWithoutCallback) {
          _emitPlaybackDiagnostic(
            PlaybackDiagnosticEventType.playbackError,
            currentTrack,
            error: error,
          );
          final track = currentTrack;
          if (track == null) rethrow;
          if (identical(_seekError, nativeError)) _seekError = null;
          final recovery = _enqueueTrackLoad(
            track,
            emitCurrentTrack: false,
            autoplay: _desiredPlaying && _player.playing,
            direction: PlayerTrackChangeDirection.none,
            sourceToReload: source,
            initialPosition: targetPosition,
          );
          await recovery.future;
          return isCurrentSeekLoad(recovery);
        }
      } finally {
        if (identical(_seekError, nativeError)) _seekError = null;
        if (identical(_seekCancellation, cancellation)) {
          _seekCancellation = null;
        }
      }
    } else if (cachedTrackLoad == null) {
      await _player.seek(targetPosition);
    }
    if (!isCurrentSeekResult(cachedTrackLoad)) return false;
    if (!_handlingTrackCompletion &&
        _player.processingState != ProcessingState.completed) {
      _completionHandled = false;
    }
    _hapticsService.seek(targetPosition);
    _updateAudioCacheTarget();
    _updatePlaybackState();
    await persistPlaybackPosition();
    return isCurrentSeekResult(cachedTrackLoad);
  }

  void _cancelPendingSeek() {
    final cancellation = _seekCancellation;
    _seekCancellation = null;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  Duration _relativeSeekBasePosition() {
    final track = currentTrack;
    final pendingTrackLoad = _latestTrackLoad ?? _activeTrackLoad;
    if (track != null &&
        pendingTrackLoad != null &&
        !pendingTrackLoad.emitCurrentTrack &&
        pendingTrackLoad.track.id == track.id) {
      return pendingTrackLoad.latestSeekPosition ?? _player.position;
    }
    return _player.position;
  }

  Future<void> seekForward(Duration duration) async {
    final currentPosition = _relativeSeekBasePosition();
    final totalDuration = _player.duration;
    final newPosition = currentPosition + duration;
    await seek(
      totalDuration != null && newPosition > totalDuration
          ? totalDuration
          : newPosition,
    );
  }

  Future<void> seekBackward(Duration duration) async {
    final currentPosition = _relativeSeekBasePosition();
    final newPosition = currentPosition - duration;
    await seek(newPosition < Duration.zero ? Duration.zero : newPosition);
  }

  Future<void> skipToNext() async {
    final target = _resolveManualSkipTarget(ManualSkipDirection.next);
    if (target == null) throw Exception('没有下一首可播放');
    await _switchToIndexAndPlay(
      target,
      direction: PlayerTrackChangeDirection.next,
    );
  }

  Future<void> skipToPrevious() async {
    final target = _resolveManualSkipTarget(ManualSkipDirection.previous);
    if (target == null) throw Exception('没有上一首可播放');
    await _switchToIndexAndPlay(
      target,
      direction: PlayerTrackChangeDirection.previous,
    );
  }

  Future<void> skipToIndex(int index) async {
    final currentIndex = _effectiveQueueIndex;
    if (index < 0 || index >= _queue.length || index == currentIndex) return;
    final direction = resolvePlayerTrackChangeDirection(
      currentIndex: currentIndex,
      targetIndex: index,
    );
    await _switchToIndexAndPlay(index, direction: direction);
  }

  Future<void> _switchToIndexAndPlay(
    int index, {
    required PlayerTrackChangeDirection direction,
  }) async {
    if (index < 0 || index >= _queue.length) return;
    _desiredPlaying = true;
    final useNativeNext =
        _androidNativePreload &&
        direction == PlayerTrackChangeDirection.next &&
        index == _currentIndex + 1 &&
        _nativePreparedTrackId == _queue[index].id &&
        _androidSourceWindow?.children.length == 2;
    final request = _enqueueTrackLoad(
      _queue[index],
      emitCurrentTrack: true,
      autoplay: true,
      direction: direction,
      nativeWindowIndex: useNativeNext ? 1 : null,
    );
    await request.future;
  }

  int get _effectiveQueueIndex {
    if (_queue.isEmpty) return -1;
    final pendingId = _pendingTargetTrackId;
    if (pendingId != null) {
      final pendingIndex = _queue.indexWhere((track) => track.id == pendingId);
      if (pendingIndex >= 0) return pendingIndex;
    }
    if (_publishedTrack != null) {
      final publishedIndex = _queue.indexWhere(
        (track) => track.id == _publishedTrack!.id,
      );
      if (publishedIndex >= 0) return publishedIndex;
    }
    return _currentIndex.clamp(0, _queue.length - 1).toInt();
  }

  int? _resolveManualSkipTarget(ManualSkipDirection direction) {
    return resolveManualSkipTarget(
      queueLength: _queue.length,
      currentIndex: _effectiveQueueIndex,
      repeatMode: _appLoopMode,
      direction: direction,
    );
  }

  void _refreshManualSkipAvailability() {
    final next = ManualSkipAvailability(
      canSkipNext: _resolveManualSkipTarget(ManualSkipDirection.next) != null,
      canSkipPrevious:
          _resolveManualSkipTarget(ManualSkipDirection.previous) != null,
    );
    if (next == _manualSkipAvailability) return;
    _manualSkipAvailability = next;
    _manualSkipAvailabilityController.add(next);
  }

  Future<void> removeTrackAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    ++_intentRevision;

    final removedTrackId = _queue[index].id;
    final targetTrackId = _pendingTargetTrackId ?? _publishedTrack?.id;
    final removesTarget = removedTrackId == targetTrackId;
    final currentTrackId = _publishedTrack?.id;

    _queue.removeAt(index);
    _refreshManualSkipAvailability();
    _queueController.add(List.from(_queue));

    if (_queue.isEmpty) {
      await clearQueue();
      return;
    }

    if (removesTarget) {
      final replacementIndex = index.clamp(0, _queue.length - 1).toInt();
      final request = _enqueueTrackLoad(
        _queue[replacementIndex],
        emitCurrentTrack: true,
        autoplay: true,
        direction: PlayerTrackChangeDirection.none,
      );
      await request.future;
      return;
    }

    if (currentTrackId != null) {
      final updatedIndex = _queue.indexWhere(
        (track) => track.id == currentTrackId,
      );
      if (updatedIndex != -1) {
        _currentIndex = updatedIndex;
      }
    }
    await persistPlaybackSession();
    _updateAudioCacheTarget();
  }

  Future<void> moveTrack(int oldIndex, int newIndex) async {
    ++_intentRevision;
    final currentTrackId = _publishedTrack?.id;
    if (!reorderByFinalIndex(_queue, oldIndex, newIndex)) return;

    if (currentTrackId != null) {
      final updatedIndex = _queue.indexWhere(
        (element) => element.id == currentTrackId,
      );
      if (updatedIndex != -1) {
        _currentIndex = updatedIndex;
      }
    }

    _refreshManualSkipAvailability();
    _queueController.add(List.from(_queue));
    await persistPlaybackSession();
    _updateAudioCacheTarget();
  }

  /// Inserts [track] immediately after the currently playing item without
  /// interrupting playback. Existing queue entries are moved instead of
  /// duplicated so repeated taps stay idempotent.
  Future<EnqueueNextResult> enqueueNext(AudioTrack track) async {
    ++_intentRevision;
    final currentIndex = _effectiveQueueIndex;
    final mutation = planEnqueueNext(
      queue: _queue,
      currentIndex: currentIndex,
      track: track,
    );
    if (mutation.result == EnqueueNextResult.noActiveQueue ||
        mutation.result == EnqueueNextResult.currentTrack ||
        mutation.result == EnqueueNextResult.alreadyNext) {
      return mutation.result;
    }
    _queue
      ..clear()
      ..addAll(mutation.queue);
    if (_publishedTrack != null) {
      final publishedIndex = _queue.indexWhere(
        (item) => item.id == _publishedTrack!.id,
      );
      if (publishedIndex >= 0) _currentIndex = publishedIndex;
    }

    _refreshManualSkipAvailability();
    _sessionCompleted = false;
    _queueController.add(List<AudioTrack>.from(_queue));
    await persistPlaybackSession();
    _updateAudioCacheTarget();
    return mutation.result;
  }

  Future<Map<String, int>> appendTracks(List<AudioTrack> tracks) async {
    final indexMap = <String, int>{};
    if (tracks.isEmpty) return indexMap;

    if (_queue.isEmpty) {
      await updateQueue(tracks);
      for (var i = 0; i < _queue.length; i++) {
        indexMap[_queue[i].id] = i;
      }
      return indexMap;
    }

    final existingIndex = <String, int>{};
    for (var i = 0; i < _queue.length; i++) {
      existingIndex[_queue[i].id] = i;
    }

    bool appended = false;
    for (final track in tracks) {
      final existing = existingIndex[track.id];
      if (existing != null) {
        indexMap[track.id] = existing;
        continue;
      }

      _queue.add(track);
      final newIndex = _queue.length - 1;
      existingIndex[track.id] = newIndex;
      indexMap[track.id] = newIndex;
      appended = true;
    }

    if (appended) {
      _refreshManualSkipAvailability();
      _queueController.add(List.from(_queue));
      await persistPlaybackSession();
      _updateAudioCacheTarget();
    }

    // Ensure we still report indexes for tracks that already existed
    for (final track in tracks) {
      indexMap[track.id] ??=
          existingIndex[track.id] ??
          _queue.indexWhere((element) => element.id == track.id);
    }

    return indexMap;
  }

  void _checkpointPlaybackSession(Duration position) {
    if (_queue.isEmpty ||
        _isRestoringSession ||
        _isSwitchingTrack ||
        _sessionCompleted) {
      return;
    }

    final positionMs = position.inMilliseconds;
    if ((positionMs - _lastSessionPositionMs).abs() <
        _sessionCheckpointInterval.inMilliseconds) {
      return;
    }
    _lastSessionPositionMs = positionMs;
    unawaited(persistPlaybackPosition());
  }

  Future<void> persistPlaybackSession() {
    if (_queue.isEmpty ||
        _isRestoringSession ||
        _isSwitchingTrack ||
        _sessionCompleted) {
      return _sessionWrite;
    }

    final snapshot = PlaybackSessionSnapshot(
      queue: List<AudioTrack>.from(_queue),
      currentIndex: _currentIndex,
      position: _player.position,
      ownerKey: _sessionOwnerKey ??= _currentSessionOwnerKey() ?? '',
    );
    if (snapshot.ownerKey.isEmpty) return _sessionWrite;
    _lastSessionPositionMs = snapshot.position.inMilliseconds;
    return _enqueueSessionWrite(() => _playbackSessionStore.save(snapshot));
  }

  Future<void> persistPlaybackPosition() {
    if (_queue.isEmpty ||
        _isRestoringSession ||
        _isSwitchingTrack ||
        _activeTrackLoad != null ||
        _latestTrackLoad != null ||
        _sessionCompleted) {
      return _sessionWrite;
    }
    final position = _player.position;
    _lastSessionPositionMs = position.inMilliseconds;
    return _enqueueSessionWrite(
      () => _playbackSessionStore.savePosition(position),
    );
  }

  Future<void> _clearPlaybackSession() {
    return _enqueueSessionWrite(_playbackSessionStore.clear);
  }

  Future<void> _enqueueSessionWrite(Future<void> Function() operation) {
    _sessionWrite = _sessionWrite.then((_) => operation()).catchError((error) {
      _log.captureOutput('[AudioSession] Failed to persist session: $error');
    });
    return _sessionWrite;
  }

  Future<void> restorePlaybackSession() async {
    final restoreRevision = ++_intentRevision;
    final snapshot = await _playbackSessionStore.load();
    if (snapshot == null) return;
    if (restoreRevision != _intentRevision) return;
    final currentOwnerKey = _currentSessionOwnerKey();
    if (currentOwnerKey == null || snapshot.ownerKey != currentOwnerKey) {
      await _clearPlaybackSession();
      return;
    }

    _isRestoringSession = true;
    _sessionCompleted = false;
    _sessionOwnerKey = currentOwnerKey;
    _desiredPlaying = false;
    try {
      final restoredQueue = snapshot.queue
          .map(_refreshStoredTrackCredentials)
          .toList(growable: false);
      _queue
        ..clear()
        ..addAll(restoredQueue);
      final targetIndex = snapshot.currentIndex.clamp(0, _queue.length - 1);
      _pendingTargetTrackId = _queue[targetIndex].id;
      _refreshManualSkipAvailability();
      _queueController.add(List<AudioTrack>.from(_queue));
      _log.captureOutput(
        '[AudioSession] Loading restored source at index=$targetIndex',
      );
      final request = _enqueueTrackLoad(
        _queue[targetIndex],
        emitCurrentTrack: true,
        autoplay: false,
        direction: PlayerTrackChangeDirection.none,
        initialPosition: snapshot.position,
        beforeCommit: (request) async {
          _ensureCurrentTrackLoad(request);
          var restoredPosition = snapshot.position;
          final trackDuration = _player.duration;
          if (trackDuration != null &&
              trackDuration > Duration.zero &&
              restoredPosition >= trackDuration) {
            restoredPosition = trackDuration - const Duration(milliseconds: 1);
            await Future.any<void>([
              _player.seek(restoredPosition),
              request.supersedeSignal.future,
            ]).timeout(_seekRecoveryTimeout);
            _ensureCurrentTrackLoad(request);
          }
          _lastSessionPositionMs = restoredPosition.inMilliseconds;
          _updatePlaybackState();
          _log.captureOutput(
            '[AudioSession] Restored ${_queue.length} tracks at '
            'index=$targetIndex '
            'position=${restoredPosition.inMilliseconds}ms',
          );
        },
      );
      try {
        await request.future;
      } catch (error) {
        if (!request.superseded && _isLatestTrackLoad(request)) {
          await _clearPlaybackSession();
        }
        _log.captureOutput('[AudioSession] Failed to restore session: $error');
      }
    } finally {
      _isRestoringSession = false;
    }
  }

  String? _currentSessionOwnerKey() {
    final host = StorageService.getString(
      'server_host',
    )?.trim().replaceFirst(RegExp(r'/+$'), '').toLowerCase();
    final userName = StorageService.getMap(
      'current_user',
    )?['name']?.toString().trim();
    if (host == null || host.isEmpty) {
      return null;
    }
    return '$host\n${userName == null || userName.isEmpty ? 'anonymous' : userName}';
  }

  AudioTrack _refreshStoredTrackCredentials(AudioTrack track) {
    return track.copyWith(
      url: _refreshStoredUrlToken(track.url) ?? track.url,
      artworkUrl: _refreshStoredUrlToken(track.artworkUrl),
      lyricUrl: _refreshStoredUrlToken(track.lyricUrl),
    );
  }

  String? _refreshStoredUrlToken(String? value) {
    if (value == null || value.isEmpty) return value;
    final token = StorageService.getString('auth_token');
    if (token == null || token.isEmpty) return value;

    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        !uri.queryParameters.containsKey('token')) {
      return value;
    }
    return uri
        .replace(queryParameters: {...uri.queryParameters, 'token': token})
        .toString();
  }

  // Getters and Streams
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<List<AudioTrack>> get queueStream => _queueController.stream;
  Stream<AudioTrack?> get currentTrackStream => _currentTrackController.stream;
  Stream<ManualSkipAvailability> get manualSkipAvailabilityStream =>
      _manualSkipAvailabilityController.stream;
  Stream<bool> get trackLoadingStream => _trackLoadingController.stream;
  bool get isTrackLoading => _isSwitchingTrack;
  Stream<AudioTrack?> get requestedTrackStream =>
      _requestedTrackController.stream;
  AudioTrack? get requestedTrack {
    final index = _queue.indexWhere(
      (track) => track.id == _pendingTargetTrackId,
    );
    return index < 0 ? null : _queue[index];
  }

  PlayerTrackChangePresentation? get lastTrackChangePresentation =>
      _lastTrackChangePresentation;
  Stream<PlaybackDiagnosticEvent> get playbackDiagnosticEventStream =>
      _playbackDiagnosticController.stream;

  List<PlaybackDiagnosticEvent> get debugPlaybackDiagnostics {
    PerformanceBuildGuard.requireEnabled('playback diagnostics');
    return List<PlaybackDiagnosticEvent>.unmodifiable(_playbackDiagnostics);
  }

  void debugClearPlaybackDiagnostics() {
    PerformanceBuildGuard.requireEnabled('playback diagnostics');
    _playbackDiagnostics.clear();
  }

  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  bool get playing => _player.playing;
  PlayerState get playerState => _player.playerState;

  AudioTrack? get currentTrack => _publishedTrack;

  ManualSkipAvailability get manualSkipAvailability => _manualSkipAvailability;

  List<AudioTrack> get queue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;

  bool get hasNext =>
      _effectiveQueueIndex >= 0 && _effectiveQueueIndex < _queue.length - 1;
  bool get hasPrevious => _effectiveQueueIndex > 0;
  bool get canSkipNextManually => manualSkipAvailability.canSkipNext;
  bool get canSkipPreviousManually => manualSkipAvailability.canSkipPrevious;

  void _emitPlaybackDiagnostic(
    PlaybackDiagnosticEventType type,
    AudioTrack? track, {
    Object? error,
  }) {
    if (!PerformanceBuildGuard.enabled) return;
    final event = PlaybackDiagnosticEvent(
      type: type,
      timestamp: DateTime.now().toUtc(),
      trackKey: track?.hash ?? track?.id,
      workId: track?.workId,
      detail: error?.runtimeType.toString(),
    );
    _playbackDiagnostics.add(event);
    _playbackDiagnosticController.add(event);
  }

  // Audio settings
  Future<void> setRepeatMode(LoopMode mode) async {
    // Store the mode at app level
    _appLoopMode = mode;
    _refreshManualSkipAvailability();
    // Always keep the player's loop mode off to prevent single-track looping
    // We handle all repeat logic in the app layer via playerStateStream listener
    await _player.setLoopMode(LoopMode.off);
    _updateAudioCacheTarget();
  }

  Future<void> setShuffleMode(bool enabled) async {
    _shuffleEnabled = enabled;
    if (!enabled) {
      await _player.setShuffleModeEnabled(false);
      _scheduleNativeWindowRefresh();
      _updateAudioCacheTarget();
      return;
    }

    // Drain a pending source-window add before deciding whether native shuffle
    // can safely operate on the remaining source list.
    if (_androidNativePreload && _androidSourceWindow != null) {
      _scheduleNativeWindowRefresh();
      await _nativeWindowRefresh;
    }
    await _player.setShuffleModeEnabled(
      enabled && (_androidSourceWindow?.children.length ?? 0) < 2,
    );
    _updateAudioCacheTarget();
  }

  Future<void> setVolume(double volume) async {
    _userVolume = volume.clamp(0.0, 1.0).toDouble();
    await _applyOutputLevel();
  }

  Future<void> updateAudioGain(double decibels) async {
    _audioGainDecibels = AudioGainSettings.normalize(decibels);
    await _applyOutputLevel();
  }

  Future<void> _applyOutputLevel() async {
    final gainDecibels = _audioPassthroughEnabled
        ? AudioGainSettings.defaultDecibels
        : _audioGainDecibels;

    if (Platform.isAndroid) {
      final enhancer = _androidLoudnessEnhancer;
      if (enhancer != null) {
        await enhancer.setTargetGain(math.max(gainDecibels, 0));
        await enhancer.setEnabled(gainDecibels > 0);
      }
      final effectiveVolume = gainDecibels < 0
          ? _userVolume * AudioGainSettings.linearMultiplier(gainDecibels)
          : _userVolume;
      await _player.setVolume(effectiveVolume);
      return;
    }

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final effectiveVolume =
          _userVolume * AudioGainSettings.linearMultiplier(gainDecibels);
      await _player.setVolume(effectiveVolume);
      return;
    }

    // AVPlayer cannot boost above its native 1.0 ceiling, but attenuation is
    // reliable. Ignore positive values instead of pretending they work.
    final effectiveVolume =
        _userVolume *
        AudioGainSettings.linearMultiplier(math.min(gainDecibels, 0));
    await _player.setVolume(effectiveVolume);
  }

  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed.clamp(0.5, 2.0));
  }

  // Privacy mode settings
  /// 更新防社死设置
  Future<void> updatePrivacySettings({
    required bool enabled,
    required bool blurCover,
    required bool maskTitle,
    required String customTitle,
  }) async {
    _privacyEnabled = enabled;
    _privacyBlurCover = blurCover;
    _privacyMaskTitle = maskTitle;
    _privacyCustomTitle = customTitle;

    // 如果当前有正在播放的音轨，立即更新媒体信息
    if (currentTrack != null) {
      await _updateMediaItem(
        currentTrack!,
        privacyEnabled: _privacyEnabled,
        blurCover: _privacyBlurCover,
        maskTitle: _privacyMaskTitle,
        customTitle: _privacyCustomTitle,
      );
    }
  }

  Future<void> updateHapticsSettings({
    required bool enabled,
    required double intensity,
  }) async {
    _hapticsEnabled = enabled;
    _hapticsIntensity = intensity.clamp(0.2, 1.0);
    await _hapticsService.updateSettings(
      enabled: _hapticsEnabled,
      intensity: _hapticsIntensity,
    );
  }

  /// 更新下一首预加载阈值，null 表示关闭预加载。
  void updatePreloadThreshold(Duration? threshold) {
    if (threshold != null && threshold < Duration.zero) {
      threshold = Duration.zero;
    }
    _preloadThreshold = threshold;
    _updateAudioCacheTarget();
    if (threshold == null || threshold <= Duration.zero) {
      _log.captureOutput('[Audio] 预加载下一首已关闭');
    } else {
      _log.captureOutput('[Audio] 预加载阈值已更新: ${threshold.inSeconds} 秒');
    }
  }

  // Cleanup
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _desiredPlaying = false;
    await _playbackErrorSubscription?.cancel();
    await _currentIndexSubscription?.cancel();
    ++_intentRevision;
    final stoppedNativeLoad = await _invalidateTrackLoads();
    await _positionSubscription?.cancel();
    await persistPlaybackPosition();
    await _speculativePauseSubscription?.cancel();
    _setAudioCacheTarget(null);
    await _hapticsService.stop();
    await _cleanupTempPlaybackFile();
    if (!stoppedNativeLoad) await _player.stop();
    await _playerStateSubscription?.cancel();
    await _queueController.close();
    await _currentTrackController.close();
    await _manualSkipAvailabilityController.close();
    await _trackLoadingController.close();
    await _requestedTrackController.close();
    await _playbackDiagnosticController.close();
    await _player.dispose();
    _releaseCachedPlaybackLease();
    await _audioCacheDownloader.dispose();
  }

  Future<void> _prepareHapticsForDownloadedFile(
    AudioTrack track, {
    required String downloadPath,
    String? analysisPath,
  }) async {
    if (!_hapticsEnabled) return;
    if (!await _isInDownloadDirectory(downloadPath)) {
      _log.captureOutput('[Audio] 跳过触感分析，非下载目录文件: ${track.title}');
      await _hapticsService.skipForTrack(track);
      return;
    }

    final resolvedAnalysisPath = analysisPath ?? downloadPath;
    if (!p.equals(
      p.normalize(resolvedAnalysisPath),
      p.normalize(downloadPath),
    )) {
      _log.captureOutput('[Audio] 使用播放副本进行触感分析: $resolvedAnalysisPath');
    }

    await _hapticsService.prepareForTrack(
      track.copyWith(sourcePath: resolvedAnalysisPath),
    );
  }

  Future<bool> _isInDownloadDirectory(String filePath) async {
    try {
      final downloadDir = await DownloadPathService.getDownloadDirectory();
      final root = p.normalize(downloadDir.path);
      final path = p.normalize(filePath);

      if (p.equals(path, root)) return true;
      return p.isWithin(root, path);
    } catch (e) {
      _log.captureOutput('[Audio] 检查下载目录失败: $e');
      return false;
    }
  }

  Future<void> _cleanupTempPlaybackFile() async {
    if (_tempPlaybackFilePath == null) return;
    try {
      final tempFile = File(_tempPlaybackFilePath!);
      if (await tempFile.exists()) {
        await tempFile.delete();
        _log.captureOutput('[Audio] 已删除临时音频文件: $_tempPlaybackFilePath');
      }
    } catch (e) {
      _log.captureOutput('[Audio] 删除临时音频文件失败: $e');
    } finally {
      _tempPlaybackFilePath = null;
    }
  }

  Future<String?> _prepareLocalPlaybackPath(String originalPath) async {
    // Android's Media3/ExoPlayer accepts the original local path, including
    // Unicode names and sibling subtitle files. Copying an entire FLAC/WAV
    // into a temporary ASCII path only adds latency and I/O on this platform.
    if (Platform.isAndroid) return null;

    final lowerPath = originalPath.toLowerCase();
    final shouldInspect =
        lowerPath.endsWith('.wav') ||
        lowerPath.endsWith('.flac') ||
        lowerPath.endsWith('.m4a') ||
        lowerPath.endsWith('.aac') ||
        lowerPath.endsWith('.ogg') ||
        lowerPath.endsWith('.opus') ||
        lowerPath.endsWith('.mp3');

    if (!shouldInspect) {
      return null;
    }

    final file = File(originalPath);
    final directory = file.parent;
    final baseName = p.basenameWithoutExtension(originalPath);
    final ext = p.extension(originalPath);

    // 检查文件名是否包含非 ASCII 字符（可能导致 MPV 崩溃）
    final hasNonAscii = baseName.codeUnits.any((c) => c > 127);

    // 检查是否有同名字幕文件
    bool hasLyricFile = false;
    for (final lyricExt in _lyricExtensions) {
      final lyricPath = p.join(directory.path, '$baseName$lyricExt');
      final lyricFile = File(lyricPath);
      if (await lyricFile.exists()) {
        hasLyricFile = true;
        _log.captureOutput('[Audio] 检测到同名字幕文件: $lyricPath');
        break;
      }
    }

    // 如果有非 ASCII 字符或同名字幕文件，复制到临时目录使用纯 ASCII 文件名
    if (hasNonAscii || hasLyricFile) {
      final reason = hasNonAscii ? '文件名含非ASCII字符' : '存在同名字幕文件';
      _log.captureOutput('[Audio] $reason，需要使用临时文件');

      final tempDir = await _getTempAudioDirectory();
      // 使用纯 ASCII 文件名：时间戳 + 简单哈希
      final hash = originalPath.hashCode.abs().toRadixString(16);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final newName = 'audio_${timestamp}_$hash$ext';
      final tempPath = p.join(tempDir.path, newName);

      try {
        await file.copy(tempPath);
        _tempPlaybackFilePath = tempPath;
        _log.captureOutput('[Audio] 已复制音频到临时路径: $tempPath');
        return tempPath;
      } catch (e) {
        _log.captureOutput('[Audio] 复制文件失败: $e');
        return null;
      }
    }

    return null;
  }

  /// AVFoundation may reject the historical hash-based `.audio` cache because
  /// it has no media extension. Keep that cache format for compatibility, but
  /// give Darwin a temporary copy with the track's real extension.
  Future<String?> _prepareCachedPlaybackPath(
    String originalPath,
    AudioTrack track,
  ) async {
    if (!(Platform.isIOS || Platform.isMacOS) ||
        !originalPath.toLowerCase().endsWith('.audio')) {
      return null;
    }

    final file = File(originalPath);
    if (!await file.exists()) return null;

    final extension = _audioExtensionForTrack(track);
    final tempDir = await _getTempAudioDirectory();
    final hash = originalPath.hashCode.abs().toRadixString(16);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tempPath = p.join(
      tempDir.path,
      'cached_audio_${timestamp}_$hash$extension',
    );

    try {
      await file.copy(tempPath);
      _tempPlaybackFilePath = tempPath;
      _log.captureOutput('[Audio] 使用带扩展名的缓存播放副本: $tempPath');
      return tempPath;
    } catch (error) {
      _log.captureOutput('[Audio] 创建缓存播放副本失败: $error');
      return null;
    }
  }

  Future<bool> _tryPlayCachedAudio(
    String cachePath,
    AudioTrack track, {
    required _TrackLoadRequest request,
  }) async {
    final candidateLease = AudioCacheFiles.holdCacheFile(cachePath);
    try {
      final playbackPath =
          await _prepareCachedPlaybackPath(cachePath, track) ??
          await _prepareLocalPlaybackPath(cachePath);
      _ensureCurrentTrackLoad(request);
      PerformanceRecorder.instance.markPlaybackPhase(
        request.performanceRequestId,
        'sourcePrepared',
      );
      PerformanceRecorder.instance.markPlaybackPhase(
        request.performanceRequestId,
        'setFilePathStart',
      );
      await _setAudioSourceForTrackLoad(
        request,
        AudioSource.file(playbackPath ?? cachePath),
        initialPosition: request.initialPosition,
      );
      PerformanceRecorder.instance.markPlaybackPhase(
        request.performanceRequestId,
        'setFilePathEnd',
      );
      _ensureCurrentTrackLoad(request);
      try {
        await _prepareHapticsForDownloadedFile(
          track,
          downloadPath: cachePath,
          analysisPath: playbackPath,
        );
      } catch (error) {
        _log.captureOutput('[Audio] 缓存播放的触感准备失败: $error');
      }
      _ensureCurrentTrackLoad(request);
      final previousLease = _cachedPlaybackLease;
      _cachedPlaybackLease = candidateLease;
      previousLease?.release();
      _log.captureOutput('[Audio] 使用缓存文件播放: ${track.title}');
      return true;
    } on PlayerInterruptedException {
      candidateLease.release();
      await _cleanupTempPlaybackFile();
      rethrow;
    } on _TrackLoadSuperseded {
      candidateLease.release();
      await _cleanupTempPlaybackFile();
      rethrow;
    } catch (error) {
      candidateLease.release();
      _ensureCurrentTrackLoad(request);
      // Detach a failed source before invalidating its file, including when
      // the previously committed track holds a lease on the same path.
      _nativeLoadCancel = _player.stop();
      await _nativeLoadCancel;
      _ensureCurrentTrackLoad(request);
      _releaseCachedPlaybackLease();
      _log.captureOutput('[Audio] 缓存文件无法播放，清除后回退到远程流: $error');
      final hash = track.hash;
      if (hash != null && hash.isNotEmpty) {
        unawaited(
          _audioCacheDownloader.invalidate(hash).catchError((Object error) {
            _log.captureOutput('[Audio] 清除失效音频缓存失败: $error');
          }),
        );
      }
      await _cleanupTempPlaybackFile();
      return false;
    }
  }

  void _releaseCachedPlaybackLease() {
    final lease = _cachedPlaybackLease;
    _cachedPlaybackLease = null;
    lease?.release();
  }

  String _audioExtensionForTrack(AudioTrack track) {
    final candidates = <String>[track.title];
    final uri = Uri.tryParse(track.url);
    if (uri != null && uri.path.isNotEmpty) {
      candidates.add(uri.path);
    }

    for (final candidate in candidates) {
      final extension = p.extension(candidate).toLowerCase();
      if (_audioExtensions.contains(extension)) return extension;
    }
    return '.mp3';
  }

  String? _remoteAudioUrlForHash(String hash) {
    final host = StorageService.getString(
      'server_host',
    )?.trim().replaceFirst(RegExp(r'/+$'), '');
    if (host == null || host.isEmpty) return null;

    final normalizedHost =
        host.startsWith('http://') || host.startsWith('https://')
        ? host
        : 'https://$host';
    final token = StorageService.getString('auth_token');
    final uri = Uri.parse('$normalizedHost/api/media/stream/$hash');
    return token == null || token.isEmpty
        ? uri.toString()
        : uri.replace(queryParameters: {'token': token}).toString();
  }

  Future<Directory> _getTempAudioDirectory() async {
    if (_tempAudioDirectory != null) return _tempAudioDirectory!;
    final dir = Directory(
      p.join(Directory.systemTemp.path, 'kikoflu_audio_temp'),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _tempAudioDirectory = dir;
    return dir;
  }
}

class _TrackLoadRequest {
  _TrackLoadRequest({
    required this.generation,
    required this.track,
    required this.emitCurrentTrack,
    required this.direction,
    required this.beforeCommit,
    required this.performanceRequestId,
    this.sourceToReload,
    this.initialPosition,
    this.nativeWindowIndex,
    this.nativeWindowAlreadyCurrent = false,
    this.nativeWindowTrackId,
  }) : latestSeekPosition = initialPosition;

  final int generation;
  final AudioTrack track;
  final bool emitCurrentTrack;
  final PlayerTrackChangeDirection direction;
  final Future<void> Function(_TrackLoadRequest request)? beforeCommit;
  final AudioSource? sourceToReload;
  final Duration? initialPosition;
  Duration? latestSeekPosition;
  final int? nativeWindowIndex;
  final bool nativeWindowAlreadyCurrent;
  String? nativeWindowTrackId;
  final Completer<void> completer = Completer<void>();
  final Completer<void> supersedeSignal = Completer<void>();
  bool superseded = false;
  final int? performanceRequestId;

  Future<void> get future => completer.future;

  void supersede() {
    if (superseded) return;
    superseded = true;
    if (!supersedeSignal.isCompleted) supersedeSignal.complete();
  }

  void complete() {
    if (!completer.isCompleted) completer.complete();
  }
}

class _TrackLoadSuperseded implements Exception {
  const _TrackLoadSuperseded();
}

// Custom AudioHandler for system integration
class _AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayerService _service;

  _AudioPlayerHandler(this._service);

  @override
  Future<void> play() => _service.play();

  @override
  Future<void> pause() async {
    await _service.pause();
    // 系统通知栏/锁屏暂停时也要立即落盘历史
    PlaybackHistoryService.instance.onPaused();
  }

  @override
  Future<void> stop() async {
    await _service.stop();
    // 系统通知栏停止时立即落盘历史
    PlaybackHistoryService.instance.onStopped();
  }

  @override
  Future<void> onTaskRemoved() async {
    await stop();
  }

  @override
  Future<void> seek(Duration position) async {
    final track = _service.currentTrack;
    if (!await _service.seek(position)) return;
    if (_service.isTrackLoading || !identical(track, _service.currentTrack)) {
      return;
    }
    // 系统通知栏/锁屏 seek 时立即落盘历史
    PlaybackHistoryService.instance.onSeekCommitted(_service.position);
  }

  @override
  Future<void> skipToNext() => _service.skipToNext();

  @override
  Future<void> skipToPrevious() => _service.skipToPrevious();
}

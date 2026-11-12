library just_audio_media_kit;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'src/pending_load.dart';
import 'src/set_property.dart';

/// An [AudioPlayerPlatform] which wraps `package:media_kit`'s [Player]
class MediaKitPlayer extends AudioPlayerPlatform {
  static const kErrorCode = 1;
  static const _seekPositionTolerance = Duration(microseconds: 500);
  static const _nativePositionSampleTolerance = Duration(milliseconds: 20);
  static const _positionConfirmationTimeout = Duration(seconds: 8);
  static const _noTransitionConfirmationWindow = Duration(milliseconds: 250);

  /// `package:media_kit`'s [Player]
  late final Player _player;

  /// The subscriptions that have to be disposed
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();

  /// Completes when the player is ready
  Future<void> ready() => _readyCompleter.future;

  static final _logger = Logger('MediaKitPlayer');

  final _eventController =
      StreamController<PlaybackEventMessage>.broadcast(sync: true);
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _mediaOpened = false;
  int _loadGeneration = 0;
  bool _released = false;
  bool _waitingForNextIndex = false;

  /// Overrides only native property-query timing in lifecycle contract tests.
  @visibleForTesting
  final Future<String> Function(NativePlayer, String)? nativePropertyReader;
  NativePlayerConfiguration? _nativePlayerConfiguration;
  NativePlayer? _nativePlayer;
  int _nativeConfigurationRevision = 0;
  Future<void> _nativeConfigurationTail = Future.value();
  int? _errorCode;
  String? _errorMessage;
  MediaKitPendingLoad? _loadCompleter;
  _PositionConfirmation? _positionConfirmation;
  _PositionConfirmation? _setPositionConfirmation;

  /// The index that's currently playing
  int _currentIndex = 0;

  /// Chapter-relative [LoadRequest.initialPosition] or [seek] queued until duration is available.
  Duration? _setPosition;
  Duration? _seekTarget;
  int? _seekCommandGeneration;
  bool _sawSeekUndershoot = false;

  Media? get _currentMedia {
    var medias = _player.state.playlist.medias;
    if (_currentIndex < 0 || _currentIndex >= medias.length) return null;
    return medias[_currentIndex];
  }

  MediaKitPlayer(
    super.id, {
    this.nativePropertyReader,
    NativePlayerConfiguration? nativePlayerConfiguration,
  })  : _nativePlayerConfiguration = nativePlayerConfiguration,
        _nativeConfigurationRevision =
            nativePlayerConfiguration == null ? 0 : 1 {
    _player = Player(
        configuration: PlayerConfiguration(
      osc: true,
      pitch: JustAudioMediaKit.pitch,
      protocolWhitelist: JustAudioMediaKit.protocolWhitelist,
      title: JustAudioMediaKit.title,
      bufferSize: JustAudioMediaKit.bufferSize,
      logLevel: JustAudioMediaKit.mpvLogLevel,
      ready: () async {
        try {
          final native = _player.platform;
          if (native is NativePlayer) {
            await native.setProperty('cache-on-disk', 'no');
            if (await native.getProperty('cache-on-disk') != 'no') {
              throw StateError('Failed to disable native disk cache');
            }
            _nativePlayer = native;
            if (_nativePlayerConfiguration != null) {
              await _enqueueNativePlayerConfiguration(
                _nativeConfigurationRevision,
              );
            }
          }
          _readyCompleter.complete();
        } catch (error, stackTrace) {
          _readyCompleter.completeError(error, stackTrace);
        }
      },
    ));

    if (JustAudioMediaKit.prefetchPlaylist) {
      setProperty(_player, 'prefetch-playlist', 'yes');
    }

    _streamSubscriptions = [
      _player.stream.duration.listen((duration) {
        if (_waitingForNextIndex) return;
        if (_currentMedia?.extras?['overrideDuration'] != null) return;

        if (_setPosition != null && duration > Duration.zero) {
          _dispatchSetPosition();
        }
        _updateDuration(duration);
        _updatePlaybackEvent();
      }),
      _player.stream.position.listen((position) {
        if (_waitingForNextIndex) return;
        // libmpv can still report the old position while the seek is queued.
        if (_seekTarget != null && _seekCommandGeneration == _loadGeneration) {
          return;
        }
        final previousPosition = _position;
        _position = position;
        final start = _currentMedia?.start;
        if (start != null) _position -= start;
        if (_position < Duration.zero) _position = Duration.zero;
        final target = _seekTarget;
        if (target != null) {
          if (_position < target &&
              target - _position <= _seekPositionTolerance) {
            // libmpv can settle one audio sample before the seek target.
            _position = target;
            _sawSeekUndershoot = true;
          } else if ((_sawSeekUndershoot &&
                  _position >= target + _seekPositionTolerance) ||
              (_position < target - _seekPositionTolerance &&
                  previousPosition > target + _seekPositionTolerance)) {
            _seekTarget = null;
            _sawSeekUndershoot = false;
          }
        }
        _updateClippedReadiness();
        _updatePlaybackEvent();
      }),
      _player.stream.buffering.listen((isBuffering) async {
        if (isBuffering &&
            _currentIndex < _player.state.playlist.medias.length - 1 &&
            _player.state.playlistMode == PlaylistMode.none) {
          final generation = _loadGeneration;
          final media = _currentMedia;
          final native = _player.platform;
          if (native is NativePlayer) {
            try {
              final eof = await _readProperty(native, 'eof-reached');
              if (!_currentRead(generation, media) ||
                  isBuffering != _player.state.buffering) {
                return;
              }
              if (eof == 'yes') _waitingForNextIndex = true;
            } catch (error, stackTrace) {
              if (!_currentRead(generation, media) ||
                  isBuffering != _player.state.buffering) {
                return;
              }
              _eventController.addError(error, stackTrace);
              return;
            }
          }
        }
        if (_waitingForNextIndex) return;
        final start = _currentMedia?.start;
        if (!isBuffering &&
            start != null &&
            _bufferedPosition <= start &&
            _player.state.position < start) {
          // Not ready yet, will be triggered by _player.stream.buffer
          return;
        }
        if (_processingState == ProcessingStateMessage.loading) {
          if (!isBuffering && _mediaOpened) {
            _processingState = ProcessingStateMessage.ready;
            if (_loadCompleter?.isCompleted != true) {
              _loadCompleter?.complete(_duration);
            }
          }
        } else if (_processingState != ProcessingStateMessage.completed ||
            isBuffering) {
          _processingState = isBuffering
              ? ProcessingStateMessage.buffering
              : ProcessingStateMessage.ready;
          if (_duration == null) {
            _updateDuration(_player.state.duration);
          }
        }
        _errorCode = null;
        _errorMessage = null;
        _updatePlaybackEvent();
      }),
      _player.stream.buffer.listen(_updateBuffer),
      _player.stream.volume.listen((volume) {
        _dataController.add(PlayerDataMessage(volume: volume / 100.0));
      }),
      _player.stream.completed.listen((completed) {
        if (!completed &&
            _processingState == ProcessingStateMessage.completed) {
          _processingState = _player.state.buffering
              ? ProcessingStateMessage.buffering
              : ProcessingStateMessage.ready;
        }
        if (completed &&
            _currentIndex < _player.state.playlist.medias.length - 1 &&
            _player.state.playlistMode == PlaylistMode.none) {
          _waitingForNextIndex = true;
          return;
        }
        if (completed &&
            // is at the end of the [Playlist]
            _currentIndex == _player.state.playlist.medias.length - 1 &&
            // is not looping (technically this shouldn't be fired if the player is looping)
            _player.state.playlistMode == PlaylistMode.none) {
          _bufferedPosition = _position = Duration.zero;
          _seekTarget = null;
          _sawSeekUndershoot = false;
          _processingState = ProcessingStateMessage.completed;
        }
        _errorCode = null;
        _errorMessage = null;

        _updatePlaybackEvent();
      }),
      _player.stream.error.listen((error) {
        final errorUri = RegExp(r'Failed to open (.*)\.').firstMatch(error)?[1];
        final pendingLoad = _loadCompleter;
        if (pendingLoad != null) {
          // An idle event would dispose the player before the load can fail.
          pendingLoad.fail(error);
        } else if (errorUri == null || errorUri == _currentMedia?.uri) {
          _mediaOpened = false;
          _processingState = ProcessingStateMessage.idle;
          _errorCode = kErrorCode;
          _errorMessage = error;
          _updatePlaybackEvent();
        }
        _logger.severe('ERROR OCCURRED: $error');
      }),
      _player.stream.playlist.listen((playlist) {
        if (_currentIndex != playlist.index) {
          _waitingForNextIndex = false;
          _bufferedPosition = _position = Duration.zero;
          _seekTarget = null;
          _sawSeekUndershoot = false;
          _currentIndex = playlist.index;
          _processingState = _player.state.buffering
              ? ProcessingStateMessage.buffering
              : ProcessingStateMessage.ready;
          unawaited(_updateBuffer(_player.state.buffer));
        }
        final override = _currentMedia?.extras?['overrideDuration'];
        if (override != null) {
          _duration = override;
        } else {
          _updateDuration(_player.state.duration);
        }
        _updatePlaybackEvent();
      }),
      _player.stream.playlistMode.listen((playlistMode) {
        _dataController.add(
            PlayerDataMessage(loopMode: _playlistModeToLoopMode(playlistMode)));
      }),
      _player.stream.pitch.listen((pitch) {
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        // ignore: avoid_print
        print("MPV: [${event.level}] ${event.prefix}: ${event.text}");
      }),
    ];
  }

  Future<void> configureNativePlayer(
    NativePlayerConfiguration configuration,
  ) {
    _nativePlayerConfiguration = configuration;
    final revision = ++_nativeConfigurationRevision;
    if (_released || _nativePlayer == null) return Future.value();
    return _enqueueNativePlayerConfiguration(revision);
  }

  Future<void> _enqueueNativePlayerConfiguration(int revision) {
    final native = _nativePlayer;
    final future = _nativeConfigurationTail.then<void>(
      (_) => _applyNativePlayerConfiguration(revision, native),
      onError: (Object error, StackTrace stackTrace) =>
          _applyNativePlayerConfiguration(revision, native),
    );
    _nativeConfigurationTail = future;
    return future;
  }

  Future<void> _applyNativePlayerConfiguration(
    int revision,
    NativePlayer? native,
  ) async {
    if (_released ||
        native == null ||
        !identical(native, _nativePlayer) ||
        revision != _nativeConfigurationRevision) {
      return;
    }
    await _nativePlayerConfiguration?.call(native);
  }

  Future<String> _readProperty(NativePlayer native, String name) =>
      nativePropertyReader?.call(native, name) ?? native.getProperty(name);

  void _dispatchSetPosition() {
    final target = _setPosition;
    if (target == null) return;

    final media = _currentMedia;
    final confirmation = _setPositionConfirmation;
    confirmation?.media = media;
    confirmation?.startDispatch(
      _playing,
      _player.state.rate,
      _player.state.position,
    );
    _setPosition = null;
    _setPositionConfirmation = null;

    final command = _player.seek(target + (media?.start ?? Duration.zero));
    if (confirmation != null) {
      unawaited(_confirmNativePosition(confirmation, command));
    } else {
      unawaited(command);
    }
  }

  Future<Duration?>? get positionConfirmation => _positionConfirmation?.future;

  _PositionConfirmation? _beginPositionConfirmation(
    int generation,
    Duration target,
  ) {
    _retirePositionConfirmation();
    final confirmation = _PositionConfirmation(generation, target);
    _positionConfirmation = confirmation;
    confirmation.startTimeout(
      _positionConfirmationTimeout,
      () => _failPositionConfirmation(confirmation),
    );
    return confirmation;
  }

  void _retirePositionConfirmation() {
    _positionConfirmation?.complete(null);
    _positionConfirmation = null;
    _setPositionConfirmation = null;
  }

  bool _currentPositionConfirmation(_PositionConfirmation confirmation) =>
      !_released &&
      !_waitingForNextIndex &&
      !confirmation.isCompleted &&
      confirmation.generation == _loadGeneration &&
      identical(confirmation, _positionConfirmation) &&
      identical(confirmation.media, _currentMedia);

  Duration? _validatedNativePosition(
    _PositionConfirmation confirmation,
    String rawPosition, {
    required bool allowPlaybackAdvance,
    bool matchTarget = true,
  }) {
    final media = confirmation.media;
    final seconds = double.tryParse(rawPosition);
    if (media == null || seconds == null || !seconds.isFinite) return null;

    return _validatedNativeDuration(
      confirmation,
      Duration(microseconds: (seconds * 1000000).round()),
      allowPlaybackAdvance: allowPlaybackAdvance,
      matchTarget: matchTarget,
    );
  }

  Duration? _validatedNativeDuration(
    _PositionConfirmation confirmation,
    Duration position, {
    required bool allowPlaybackAdvance,
    bool matchTarget = true,
  }) {
    final media = confirmation.media;
    if (media == null) return null;

    final start = media.start ?? Duration.zero;
    final end = media.end;
    if (position < start) {
      if (start - position > _seekPositionTolerance) return null;
      position = start;
    }
    if (end != null && position > end) return null;

    final chapterPosition = position - start;
    if (!matchTarget) return chapterPosition;

    final difference = chapterPosition - confirmation.target;
    final advance =
        allowPlaybackAdvance && (confirmation.playingAtDispatch || _playing)
            ? Duration(
                  microseconds: (confirmation.dispatchElapsed.inMicroseconds *
                          confirmation.rateAtDispatch)
                      .round(),
                ) +
                _nativePositionSampleTolerance
            : Duration.zero;
    if (difference > advance + _seekPositionTolerance ||
        difference < -_seekPositionTolerance) {
      return null;
    }
    return difference < Duration.zero ? confirmation.target : chapterPosition;
  }

  bool _nativePositionShowsSeekDisplacement(
    _PositionConfirmation confirmation,
    String rawPosition,
  ) {
    final baseline = confirmation.baselinePosition;
    final seconds = double.tryParse(rawPosition);
    if (baseline == null || seconds == null || !seconds.isFinite) return false;

    final position = Duration(microseconds: (seconds * 1000000).round());
    final displacement =
        position > baseline ? position - baseline : baseline - position;
    final ordinaryAdvance = Duration(
          microseconds: (confirmation.dispatchElapsed.inMicroseconds *
                  confirmation.rateAtDispatch)
              .round(),
        ) +
        _nativePositionSampleTolerance;
    return displacement > ordinaryAdvance;
  }

  Future<void> _confirmNativePosition(
    _PositionConfirmation confirmation,
    Future<void> command,
  ) async {
    try {
      await Future.any<void>([
        command,
        confirmation.future.then<void>((_) {}),
      ]);
      if (!_currentPositionConfirmation(confirmation)) return;

      final native = _nativePlayer;
      if (native == null) {
        _failPositionConfirmation(confirmation);
        return;
      }

      var sawSeeking = false;
      final watch = Stopwatch()..start();
      while (watch.elapsed < _positionConfirmationTimeout) {
        if (!_currentPositionConfirmation(confirmation)) return;
        final seeking = await _readProperty(native, 'seeking');
        if (!_currentPositionConfirmation(confirmation)) return;
        if (seeking == 'yes') {
          sawSeeking = true;
        } else if (seeking == 'no') {
          final rawPosition = await _readProperty(native, 'time-pos');
          if (!_currentPositionConfirmation(confirmation)) return;
          final afterPosition = await _readProperty(native, 'seeking');
          if (!_currentPositionConfirmation(confirmation)) return;
          if (afterPosition == 'yes') {
            sawSeeking = true;
          } else if (afterPosition == 'no') {
            final displacement = _nativePositionShowsSeekDisplacement(
              confirmation,
              rawPosition,
            );
            final position = _validatedNativePosition(
              confirmation,
              rawPosition,
              allowPlaybackAdvance: sawSeeking || displacement,
            );
            if (position != null) {
              _publishPositionConfirmation(confirmation, position);
              confirmation.complete(position);
              return;
            }
            if (sawSeeking ||
                watch.elapsed >= _noTransitionConfirmationWindow) {
              _failPositionConfirmation(
                confirmation,
                rawPosition: rawPosition,
              );
              return;
            }
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      _failPositionConfirmation(confirmation);
    } catch (error) {
      if (_currentPositionConfirmation(confirmation)) {
        _logger.fine('native position was not confirmed: $error');
        _failPositionConfirmation(confirmation);
      }
    }
  }

  void _failPositionConfirmation(
    _PositionConfirmation confirmation, {
    String? rawPosition,
  }) {
    if (!_currentPositionConfirmation(confirmation)) {
      confirmation.complete(null);
      return;
    }
    final position = rawPosition == null
        ? null
        : _validatedNativePosition(
            confirmation,
            rawPosition,
            allowPlaybackAdvance: false,
            matchTarget: false,
          );
    final fallback = position ??
        (confirmation.baselinePosition == null
            ? null
            : _validatedNativeDuration(
                confirmation,
                confirmation.baselinePosition!,
                allowPlaybackAdvance: false,
                matchTarget: false,
              ));
    _publishPositionConfirmation(confirmation, fallback);
    confirmation.complete(null);
  }

  void _publishPositionConfirmation(
    _PositionConfirmation confirmation,
    Duration? position,
  ) {
    if (position == null || !_currentPositionConfirmation(confirmation)) return;
    _position = position;
    _updatePlaybackEvent();
  }

  bool _currentRead(int generation, Media? media) =>
      !_released &&
      !_waitingForNextIndex &&
      generation == _loadGeneration &&
      identical(media, _currentMedia);

  Future<void> _updateBuffer(Duration buffer) async {
    if (_waitingForNextIndex) return;
    final generation = _loadGeneration;
    final media = _currentMedia;
    var buffered = buffer;
    final native = _player.platform;
    try {
      if (native is NativePlayer && media != null) {
        final raw = await _readProperty(native, 'demuxer-cache-state');
        if (!_currentRead(generation, media)) return;
        final state = raw.isEmpty ? null : jsonDecode(raw);
        // eof-cached can belong to another seek range; eof is the active range.
        if (state?['eof'] == true && state?['eof-cached'] == true) {
          buffered = _player.state.duration;
        }
      }
    } catch (error, stackTrace) {
      if (!_currentRead(generation, media)) return;
      _eventController.addError(error, stackTrace);
      _loadCompleter?.fail(error.toString());
      return;
    }
    _bufferedPosition = buffered;
    _updateClippedReadiness();
    _updatePlaybackEvent();
  }

  void _updateClippedReadiness() {
    final start = _currentMedia?.start;
    if (start == null ||
        _player.state.buffering ||
        !_mediaOpened ||
        _processingState == ProcessingStateMessage.completed ||
        (_bufferedPosition <= start && _player.state.position < start)) {
      return;
    }
    _processingState = ProcessingStateMessage.ready;
    if (_loadCompleter?.isCompleted != true) {
      _loadCompleter?.complete(_duration);
    }
  }

  void _updateDuration(Duration duration) {
    final start = _currentMedia?.start;
    final end = _currentMedia?.end;
    if (end != null) duration = end;
    if (start != null) duration -= start;
    _duration = duration;
  }

  PlaylistMode _loopModeToPlaylistMode(LoopModeMessage loopMode) {
    return switch (loopMode) {
      LoopModeMessage.off => PlaylistMode.none,
      LoopModeMessage.one => PlaylistMode.single,
      LoopModeMessage.all => PlaylistMode.loop,
    };
  }

  LoopModeMessage _playlistModeToLoopMode(PlaylistMode playlistMode) {
    return switch (playlistMode) {
      PlaylistMode.none => LoopModeMessage.off,
      PlaylistMode.single => LoopModeMessage.one,
      PlaylistMode.loop => LoopModeMessage.all,
    };
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  /// Updates the playback event
  void _updatePlaybackEvent() {
    var buffer = _bufferedPosition - (_currentMedia?.start ?? Duration.zero);
    if (buffer < Duration.zero) buffer = Duration.zero;
    if (_duration != null && buffer > _duration!) buffer = _duration!;
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: buffer,
      duration: _duration,
      icyMetadata: null,
      currentIndex: _currentIndex,
      androidAudioSessionId: null,
      errorCode: _errorCode,
      errorMessage: _errorMessage,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.finest('load(${request.toMap()})');
    final generation = ++_loadGeneration;
    final confirmation = request.initialPosition == null
        ? null
        : _beginPositionConfirmation(generation, request.initialPosition!);
    if (confirmation == null) _retirePositionConfirmation();
    _waitingForNextIndex = false;
    _mediaOpened = false;
    _setPosition = null;
    _setPositionConfirmation = confirmation;
    _seekTarget = request.initialPosition;
    _sawSeekUndershoot = false;
    final pendingLoad = MediaKitPendingLoad();
    _loadCompleter = pendingLoad;
    _currentIndex = request.initialIndex ?? 0;
    _bufferedPosition = Duration.zero;
    _position = Duration.zero;
    _duration = null;
    _processingState = ProcessingStateMessage.loading;
    _errorCode = null;
    _errorMessage = null;
    _updatePlaybackEvent();

    try {
      if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
        final audioSource =
            request.audioSourceMessage as ConcatenatingAudioSourceMessage;
        final playable = Playlist(
            audioSource.children.map(_convertAudioSourceIntoMediaKit).toList(),
            index: _currentIndex);

        await _player.open(playable, play: _playing);
      } else {
        final playable =
            _convertAudioSourceIntoMediaKit(request.audioSourceMessage);
        _logger.finest('playable is ${playable.toString()}');
        await _player.open(playable, play: _playing);
      }
      _mediaOpened = true;

      if (request.initialPosition != null &&
          _loadGeneration == generation &&
          identical(confirmation, _positionConfirmation)) {
        confirmation!.media = _currentMedia;
        confirmation.baselinePosition = _player.state.position;
        _setPosition = _position = request.initialPosition!;
        _setPositionConfirmation = confirmation;
        if (_player.state.duration > Duration.zero) _dispatchSetPosition();
      }

      _updatePlaybackEvent();
      return LoadResponse(duration: await pendingLoad.future);
    } catch (_) {
      if (confirmation != null) _failPositionConfirmation(confirmation);
      if (_loadGeneration == generation) {
        _seekTarget = null;
        _sawSeekUndershoot = false;
        _setPosition = null;
        _setPositionConfirmation = null;
      }
      rethrow;
    } finally {
      if (identical(_loadCompleter, pendingLoad)) _loadCompleter = null;
    }
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _playing = true;
    if (_mediaOpened) {
      await _player.play();
    }
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _playing = false;
    if (_mediaOpened) {
      await _player.pause();
    }
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) {
    return _player
        .setVolume(request.volume * 100.0)
        .then((value) => SetVolumeResponse());
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) {
    return _player.setRate(request.speed).then((_) => SetSpeedResponse());
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    // just_audio sends neutral pitch during every load, even without pitch control.
    if (request.pitch != 1 || _player.platform?.configuration.pitch != false) {
      await _player.setPitch(request.pitch);
    }
    return SetPitchResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    await _player.setPlaylistMode(_loopModeToPlaylistMode(request.loopMode));
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    bool shuffling = request.shuffleMode != ShuffleModeMessage.none;
    await _player.setShuffle(shuffling);

    _dataController.add(PlayerDataMessage(
        shuffleMode:
            shuffling ? ShuffleModeMessage.all : ShuffleModeMessage.none));
    return SetShuffleModeResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _logger.finest('seek(${request.toMap()})');
    final generation = ++_loadGeneration;
    final confirmation = request.position == null
        ? null
        : _beginPositionConfirmation(generation, request.position!);
    if (confirmation == null) _retirePositionConfirmation();
    _setPosition = null;
    _setPositionConfirmation = confirmation;
    _waitingForNextIndex = false;
    _seekTarget = null;
    _sawSeekUndershoot = false;
    final index = request.index;
    final native = _nativePlayer;
    if (index != null && !_playing && native != null) {
      if (_currentIndex != index) {
        _waitingForNextIndex = true;
        _processingState = ProcessingStateMessage.buffering;
        _updatePlaybackEvent();
        try {
          // jump resumes playback before selecting the item.
          await NativePlayer.lock.synchronized(() async {
            if (_loadGeneration == generation) {
              await native.setProperty('playlist-pos', index.toString());
            }
          });
          if (_loadGeneration != generation) return SeekResponse();
          if (_currentIndex != index ||
              _processingState != ProcessingStateMessage.ready) {
            await _eventController.stream
                .where((event) =>
                    event.currentIndex == index &&
                    event.processingState == ProcessingStateMessage.ready)
                .timeout(const Duration(seconds: 3))
                .first;
            // Leave the synchronous event dispatch before publishing the seek.
            await Future<void>.microtask(() {});
          }
        } finally {
          if (_loadGeneration == generation) _waitingForNextIndex = false;
        }
        if (_loadGeneration != generation) return SeekResponse();
      }
    } else if (index != null) {
      if (_currentIndex != index) {
        _currentIndex = index;
        _position = _bufferedPosition = Duration.zero;
        _processingState = ProcessingStateMessage.buffering;
        _updatePlaybackEvent();
      }
      await _player.jump(index);
      if (!_playing) await _player.pause();
    }
    if (_loadGeneration != generation) return SeekResponse();

    final position = request.position;
    if (position != null) {
      _seekTarget = position;
      _position = position;

      final start = _currentMedia?.start;
      var nativePosition = position;
      if (start != null) nativePosition += start;
      try {
        if (_player.state.duration > Duration.zero) {
          confirmation?.media = _currentMedia;
          confirmation?.startDispatch(
            _playing,
            _player.state.rate,
            _player.state.position,
          );
          _seekCommandGeneration = generation;
          final command = _player.seek(nativePosition);
          if (confirmation != null) {
            unawaited(_confirmNativePosition(confirmation, command));
          }
          await command;
        } else {
          _setPosition = position;
        }
      } catch (_) {
        if (confirmation != null) _failPositionConfirmation(confirmation);
        if (_loadGeneration == generation) {
          _seekTarget = null;
          _sawSeekUndershoot = false;
        }
        rethrow;
      } finally {
        if (_seekCommandGeneration == generation) _seekCommandGeneration = null;
      }
    } else {
      _position = Duration.zero;
    }

    // reset position on seek
    if (_loadGeneration == generation) _updatePlaybackEvent();
    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    // _logger.fine('concatenatingInsertAll(${request.toMap()})');
    for (final source in request.children) {
      await _player.add(_convertAudioSourceIntoMediaKit(source));

      final length = _player.state.playlist.medias.length;

      if (length == 0 || length == 1) continue;

      if (request.index < (length - 1) && request.index >= 0) {
        await _player.move(length, request.index);
      }
    }

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    for (var i = request.startIndex; i < request.endIndex; i++) {
      await _player.remove(request.startIndex);
    }

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
      ConcatenatingMoveRequest request) {
    return _player
        .move(
            request.currentIndex,
            // not sure why, but apparently there's an underlying difference between just_audio's move implementation
            // and media_kit, so let's fix it
            request.currentIndex > request.newIndex
                ? request.newIndex
                : request.newIndex + 1)
        .then((_) => ConcatenatingMoveResponse());
  }

  /// Release the resources used by this player.
  Future<void> release() async {
    _logger.info('releasing player resources');
    _loadCompleter?.interrupt();
    ++_loadGeneration;
    _released = true;
    _retirePositionConfirmation();
    _waitingForNextIndex = false;
    _mediaOpened = false;
    try {
      await _nativeConfigurationTail;
    } catch (_) {}
    await _player.dispose();
    for (final StreamSubscription subscription in _streamSubscriptions) {
      unawaited(subscription.cancel());
    }
    _streamSubscriptions.clear();
  }

  /// Converts an [AudioSourceMessage] into a [Media] for playback
  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    switch (audioSource) {
      case final UriAudioSourceMessage uriSource:
        return Media(uriSource.uri, httpHeaders: audioSource.headers);

      // removed because it doesn't seem to be actually working.
      // Related media-kit issue: https://github.com/media-kit/media-kit/issues/28
      // case final SilenceAudioSourceMessage silenceSource:
      //   // from https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137
      //   return Media(
      //     'av://lavfi:anullsrc=d=${silenceSource.duration.inMilliseconds}ms',
      //     extras: {'overrideDuration': silenceSource.duration},
      //   );

      case final ClippingAudioSourceMessage clippingSource:
        return Media(clippingSource.child.uri,
            httpHeaders: clippingSource.child.headers,
            start: clippingSource.start,
            end: clippingSource.end);

      default:
        throw UnsupportedError(
            '${audioSource.runtimeType} is currently not supported');
    }
  }
}

class _PositionConfirmation {
  _PositionConfirmation(this.generation, this.target);

  final int generation;
  final Duration target;
  final Completer<Duration?> _result = Completer<Duration?>();
  final Stopwatch _dispatchTimer = Stopwatch();
  Timer? _timeoutTimer;
  Media? media;
  Duration? baselinePosition;
  bool playingAtDispatch = false;
  double rateAtDispatch = 1.0;

  Future<Duration?> get future => _result.future;
  Duration get dispatchElapsed => _dispatchTimer.elapsed;
  bool get isCompleted => _result.isCompleted;

  void startTimeout(Duration timeout, void Function() onTimeout) {
    _timeoutTimer = Timer(timeout, onTimeout);
  }

  void startDispatch(bool playing, double rate, Duration baselinePosition) {
    if (_dispatchTimer.isRunning) return;
    playingAtDispatch = playing;
    rateAtDispatch = rate;
    this.baselinePosition = baselinePosition;
    _dispatchTimer.start();
  }

  void complete(Duration? position) {
    if (_result.isCompleted) return;
    _timeoutTimer?.cancel();
    _result.complete(position);
  }
}

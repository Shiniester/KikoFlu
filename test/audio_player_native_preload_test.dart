import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/models/audio_slice.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/automatic_marking_event.dart';
import 'package:kikoeru_flutter/src/services/audio_cache_downloader.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/audio_slice_store.dart';
import 'package:kikoeru_flutter/src/services/playback_session_store.dart';
import 'package:kikoeru_flutter/src/services/speculative_transfer_coordinator.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart' show ControlledPlayer, until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _WindowPlayer player;
  late _CacheDownloader downloader;
  late _ControlledAudioSliceStore sliceStore;
  late SharedPreferencesPlaybackSessionStore sessionStore;
  late AudioPlayerService service;
  late StreamController<AudioInterruptionEvent> interruptionEvents;
  const a = AudioTrack(
    id: 'a',
    title: 'a.wav',
    url: 'https://example.invalid/a.wav',
    hash: 'a',
  );
  const b = AudioTrack(
    id: 'b',
    title: 'b.wav',
    url: 'https://example.invalid/b.wav',
    hash: 'b',
  );
  const c = AudioTrack(
    id: 'c',
    title: 'c.wav',
    url: 'https://example.invalid/c.wav',
    hash: 'c',
  );

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SpeculativeTransferCoordinator.instance.resetForTest();
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://example.invalid',
      'current_user': '{"name":"tester"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    interruptionEvents = StreamController<AudioInterruptionEvent>.broadcast(
      sync: true,
    );
    root = await Directory.systemTemp.createTemp('kiko-native-next-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
    player = _WindowPlayer();
    downloader = _CacheDownloader();
    sliceStore = _ControlledAudioSliceStore();
    sessionStore = const SharedPreferencesPlaybackSessionStore();
    service = AudioPlayerService.forTesting(
      player,
      sessionStore: sessionStore,
      sliceStore: sliceStore,
      androidSeekRecovery: true,
      androidNativePreload: true,
      seekRecoveryTimeout: const Duration(milliseconds: 100),
      cacheDownloader: downloader,
      interruptionEvents: interruptionEvents.stream,
    );
  });

  tearDown(() async {
    await service.dispose();
    await interruptionEvents.close();
    SpeculativeTransferCoordinator.instance.resetForTest();
    debugDefaultTargetPlatformOverride = null;
    await root.delete(recursive: true);
  });

  Future<void> buffer(int seconds) async {
    player.bufferedPosition = player.position + Duration(seconds: seconds);
    player.positions.add(player.position);
    // Drain stream delivery and the serialized playlist update, without a timed wait.
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> warm([List<AudioTrack> queue = const [a, b, c]]) async {
    await service.updateQueue(queue, autoplay: true);
    player.position = const Duration(minutes: 4, seconds: 10);
    await buffer(20);
    await until(() => player.window.children.length == 2);
    await Future<void>.delayed(Duration.zero);
  }

  test('manual next reuses the native source without another load', () async {
    final completions = <AutomaticMarkingEvent>[];
    final subscription = service.automaticMarkingEvents
        .where((event) => event.type == AutomaticMarkingEventType.completed)
        .listen(completions.add);
    addTearDown(subscription.cancel);
    await warm();
    expect(player.window.useLazyPreparation, isFalse);
    expect(
      downloader.targets.whereType<AudioCacheRequest>().map((r) => r.hash),
      isNot(contains('b')),
    );
    await service.skipToNext();
    expect(service.currentTrack, b);
    expect(player.loaded, [a.url]);
    expect(player.indexedSeeks, [1]);
    expect(player.activeUri.toString(), b.url);
    expect(player.window.children, hasLength(1));
    expect(completions, isEmpty);
  });

  test(
    'manual next keeps its prepared source during a position refresh',
    () async {
      await warm();
      expect(service.isNativeNextPreparedForTesting(b.id), isTrue);

      final switching = service.skipToNext();
      expect(service.isTrackLoading, isTrue);
      player.positions.add(player.position);

      await switching;

      expect(player.loaded, [a.url]);
      expect(player.indexedSeeks, [1]);
    },
  );

  test(
    'superseded promotion does not block cleanup for the latest request',
    () async {
      await warm();
      sliceStore.hold(b.id);
      final promotion = service.skipToNext();
      Future<void>? replacement;

      try {
        await sliceStore
            .loadStarted(b.id)
            .future
            .timeout(const Duration(seconds: 1));
        replacement = service.skipToIndex(2);
        player.positions.add(player.position);
        await until(() => player.window.children.length == 1);
      } finally {
        sliceStore.release(b.id);
      }

      await Future.wait([promotion, replacement]);
      expect(service.currentTrack, c);
      expect(player.loaded, [a.url, c.url]);
    },
  );

  test('natural transition publishes once after a no-op enqueue', () async {
    final completions = <AutomaticMarkingEvent>[];
    final markingSubscription = service.automaticMarkingEvents
        .where((event) => event.type == AutomaticMarkingEventType.completed)
        .listen(completions.add);
    addTearDown(markingSubscription.cancel);
    final published = <AudioTrack?>[];
    final subscription = service.currentTrackStream.listen(published.add);
    await warm();
    expect(await service.enqueueNext(b), EnqueueNextResult.alreadyNext);
    player.transition(1);
    await until(() => service.currentTrack == b && !service.isTrackLoading);
    expect(player.loaded, [a.url]);
    expect(published.map((track) => track?.id), ['a', 'b']);
    expect(service.currentIndex, 1);
    expect(completions.map((event) => event.track?.id), ['a']);
    await subscription.cancel();
  });

  test('preview blocks and rejects a racing native promotion', () async {
    await warm();
    final trackKey = service.sliceState.trackKey!;
    const preview = AudioSlice(startMs: 250000, endMs: 300000);
    expect(await service.saveSlice(trackKey: trackKey, slice: preview), isTrue);
    final preparedNext = player.window.children[1];

    await service.previewSlice(trackKey, preview);
    await until(() => player.window.children.length == 1);
    expect(service.currentTrack, a);

    player.transitionToPreparedChild(preparedNext);
    await until(
      () =>
          player.currentIndex == 0 &&
          !player.playing &&
          service.sliceState.preview == null,
    );
    expect(service.currentTrack, a);
    expect(player.activeUri.toString(), a.url);
    expect(player.position, const Duration(minutes: 5));
  });

  test('Only Slices removes and bypasses the native successor', () async {
    await warm();
    const firstSlice = AudioSlice(startMs: 10000, endMs: 20000);
    await const SharedPreferencesAudioSliceStore().write(
      audioSliceTrackKey(b),
      const [firstSlice],
    );

    service.setOnlySlices(true);
    await until(() => player.window.children.length == 1);
    await service.skipToNext();

    expect(service.currentTrack, b);
    expect(player.initialPositions.last, const Duration(milliseconds: 10000));
    expect(player.position, const Duration(milliseconds: 10000));
    expect(player.playing, isTrue);
  });

  test(
    'enabling Only Slices after next uses the sliced ordinary load',
    () async {
      await warm();
      const firstSlice = AudioSlice(startMs: 10000, endMs: 20000);
      await sliceStore.write(audioSliceTrackKey(b), const [firstSlice]);

      final switching = service.skipToNext();
      service.setOnlySlices(true);
      await switching;

      expect(service.currentTrack, b);
      expect(player.loaded, [a.url, b.url]);
      expect(player.indexedSeeks, isEmpty);
      expect(player.initialPositions.last, const Duration(milliseconds: 10000));
      expect(player.position, const Duration(milliseconds: 10000));
    },
  );

  test('Only Slices starts a pending native next within its slice', () async {
    await warm([a, b]);
    await sliceStore.write(audioSliceTrackKey(b), const [
      AudioSlice(startMs: 10000, endMs: 20000),
    ]);
    player.deferIndexWhileSeeking = true;
    player.holdNextSeek = true;
    final switching = service.skipToNext();
    await until(() => player.pendingSeek != null);

    service.setOnlySlices(true);
    player.finishSeek();
    await switching;

    expect(service.currentTrack, b);
    expect(player.firstPlaybackPositions[b.url], const Duration(seconds: 10));
    expect(player.loaded, [a.url]);
  });

  test('automatic transition waits for ready and preserves a pause', () async {
    await warm();
    player.transition(1, state: ProcessingState.buffering);
    await until(() => service.isTrackLoading);
    expect(service.currentTrack, a);
    await service.pause();
    player.processingState = ProcessingState.ready;
    player.emitPlayerState();
    await until(() => service.currentTrack == b && !service.isTrackLoading);
    expect(player.playing, isFalse);
    expect(player.loaded, [a.url]);
  });

  test('native preparation keeps 15/5 hysteresis and respects off', () async {
    await warm();
    await buffer(6);
    expect(player.window.children, hasLength(2));
    await buffer(4);
    await until(() => player.window.children.length == 1);
    await buffer(6);
    expect(player.window.children, hasLength(1));
    await buffer(15);
    await until(() => player.window.children.length == 2);
    service.updatePreloadThreshold(null);
    await until(() => player.window.children.length == 1);
    expect(service.currentTrack, a);
  });

  test(
    'native preparation accepts a full buffer when position advances per read',
    () async {
      await service.updateQueue([a, b], autoplay: true);
      service.updatePreloadThreshold(const Duration(seconds: 4));
      await Future<void>.delayed(Duration.zero);
      expect(player.window.children, hasLength(1));

      player.position = const Duration(
        minutes: 4,
        seconds: 59,
        milliseconds: 999,
      );
      player.bufferedPosition = const Duration(minutes: 5);
      player.advancePositionOnRead = true;
      player.emitStoredPosition();

      await until(() => player.window.children.length == 2);
      expect(
        (player.window.children[1] as UriAudioSource).uri.toString(),
        b.url,
      );
    },
  );

  for (final shuffle in [false, true]) {
    test(
      'in-flight preparation handles ${shuffle ? 'shuffle cancellation' : 'buffer headroom falling to ten seconds'}',
      () async {
        const next = AudioTrack(
          id: 'no-cache-key',
          title: 'next.wav',
          url: 'https://example.invalid/next.wav',
        );
        await service.updateQueue([a, next], autoplay: true);
        await Future<void>.delayed(Duration.zero);
        player.position = const Duration(minutes: 4, seconds: 10);
        player.bufferedPosition = player.position + const Duration(seconds: 15);
        player.positions.add(player.position);
        expect(player.window.children, hasLength(2));
        if (shuffle) {
          await service.setShuffleMode(true);
          expect(player.window.children, hasLength(1));
        } else {
          player.bufferedPosition =
              player.position + const Duration(seconds: 10);
          await Future<void>.delayed(Duration.zero);
          expect(player.window.children, hasLength(2));
          await service.skipToNext();
          expect(service.currentTrack, next);
          expect(player.loaded, [a.url]);
        }
      },
    );
  }

  test('queue mutation replaces only the prepared successor', () async {
    await warm();
    await service.moveTrack(2, 1);
    await until(
      () =>
          player.window.children.length == 2 &&
          (player.window.children[1] as UriAudioSource).uri.toString() == c.url,
    );
    await Future<void>.delayed(Duration.zero);
    await service.skipToNext();
    expect(service.currentTrack, c);
    expect(player.loaded, [a.url]);
  });

  test('a newer skip supersedes a pending native indexed seek', () async {
    await warm();
    player.holdNextSeek = true;
    final first = service.skipToNext();
    await until(() => player.pendingSeek != null);
    final second = service.skipToNext();
    await Future.wait([first, second]).timeout(const Duration(seconds: 1));
    expect(service.currentTrack, c);
    expect(player.activeUri.toString(), c.url);
    expect(player.loaded, [a.url, c.url]);
  });

  test('failed indexed seek falls back to ordinary loading', () async {
    await warm();
    player.failIndexedSeek = true;
    await service.skipToNext();
    expect(service.currentTrack, b);
    expect(player.loaded, [a.url, b.url]);
    expect(player.playing, isTrue);
  });

  for (final failWithError in [true, false]) {
    test(
      'automatic unready source falls back (${failWithError ? 'error' : 'timeout'})',
      () async {
        await warm();
        player.transition(1, state: ProcessingState.buffering);
        await until(() => service.isTrackLoading);
        if (failWithError) {
          player.errors.addError(PlayerException(0, 'next unavailable'));
        }
        await until(() => service.currentTrack == b && !service.isTrackLoading);
        expect(player.loaded, [a.url, b.url]);
        expect(player.activeUri.toString(), b.url);
      },
    );
  }

  test(
    'stop cancels an indexed seek without committing the next track',
    () async {
      await warm();
      final currentPosition = player.position;
      await service.persistPlaybackSession();
      player.holdNextSeek = true;
      final switching = service.skipToNext();
      await until(() => player.pendingSeek != null);
      await Future.wait([
        switching,
        service.stop(),
      ]).timeout(const Duration(seconds: 1));
      expect(service.currentTrack, a);
      expect(player.playing, isFalse);
      final stoppedSession = (await sessionStore.load())!;
      expect(stoppedSession.queue[stoppedSession.currentIndex], a);
      expect(stoppedSession.position, currentPosition);

      await service.play();

      expect(service.currentTrack, a);
      expect(player.activeUri.toString(), a.url);
      expect(player.initialPositions.last, currentPosition);
    },
  );

  test(
    'stop restores the committed source after an automatic native transition',
    () async {
      await warm();
      final currentPosition = player.position;
      player.transition(1, state: ProcessingState.buffering);
      await until(() => service.isTrackLoading);

      await service.stop();
      expect(service.currentTrack, a);

      await service.play();

      expect(service.currentTrack, a);
      expect(player.activeUri.toString(), a.url);
      expect(player.initialPositions.last, currentPosition);
    },
  );

  test(
    'stop preserves a newer queue replacement during a native seek',
    () async {
      await warm();
      player.holdNextSeek = true;
      final switching = service.skipToNext();
      await until(() => player.pendingSeek != null);
      player.position = const Duration(seconds: 47);
      final replacing = service.updateQueue(
        [b, c],
        startIndex: 1,
        autoplay: true,
        initialPosition: const Duration(seconds: 23),
      );
      final stopping = service.stop();

      await Future.wait([
        switching,
        replacing,
        stopping,
      ]).timeout(const Duration(seconds: 1));
      await service.persistPlaybackPosition();
      final stoppedSession = (await sessionStore.load())!;
      expect(stoppedSession.queue[stoppedSession.currentIndex], c);
      expect(stoppedSession.position, const Duration(seconds: 23));
      await service.play();

      expect(service.currentTrack, c);
      expect(player.activeUri.toString(), c.url);
      expect(player.initialPositions.last, const Duration(seconds: 23));
    },
  );

  test('a new queue intent during stop loads its own source', () async {
    await warm();
    player.holdNextSeek = true;
    final switching = service.skipToNext();
    await until(() => player.pendingSeek != null);
    final stopping = service.stop();
    final replacing = service.updateQueue([c], autoplay: true);

    await Future.wait([
      switching,
      stopping,
      replacing,
    ]).timeout(const Duration(seconds: 1));

    expect(service.currentTrack, c);
    expect(player.activeUri.toString(), c.url);
    final saved = (await sessionStore.load())!;
    expect(saved.queue[saved.currentIndex], c);
  });

  test('a complete cache seek unwraps the current native child', () async {
    await warm();
    final partial = await CacheService.prepareAudioCacheTempFile('a');
    await partial.writeAsBytes([1, 2, 3]);
    expect(
      await CacheService.finalizeAudioCacheFile('a', expectedSize: 3),
      isTrue,
    );
    const target = Duration(minutes: 4, seconds: 50);
    await service.seek(target);
    expect(service.currentTrack, a);
    expect(player.activeUri.scheme, 'file');
    expect(player.position, target);
    expect(player.window.children.single, isA<UriAudioSource>());
  });

  test('preparation error restores current source and blocks retry', () async {
    await warm();
    final position = player.position;
    player.errors.addError(PlayerException(0, 'source failed'));
    // The Android plugin may advance after emitting the error.
    if (player.window.children.length == 2) player.transition(1);
    await until(() => player.loaded.length == 2 && !service.isTrackLoading);
    expect(service.currentTrack, a);
    expect(player.activeUri.toString(), a.url);
    expect(player.position, position);
    await buffer(20);
    expect(player.window.children, hasLength(1));
    await service.pause();
    await service.play();
    await buffer(20);
    expect(player.window.children, hasLength(1));
  });

  test(
    'repeat one and download saturation withdraw the prepared source',
    () async {
      await warm();
      await service.setRepeatMode(LoopMode.one);
      await until(() => player.window.children.length == 1);
      await service.setRepeatMode(LoopMode.off);
      await until(() => player.window.children.length == 2);
      SpeculativeTransferCoordinator.instance.updateUserDownloads(
        active: 1,
        capacity: 1,
      );
      await until(() => player.window.children.length == 1);
      expect(service.currentTrack, a);
    },
  );

  test('completed cache keeps the ordinary file load path', () async {
    final partial = await CacheService.prepareAudioCacheTempFile('b');
    await partial.writeAsBytes([1, 2, 3]);
    expect(
      await CacheService.finalizeAudioCacheFile('b', expectedSize: 3),
      isTrue,
    );
    await service.updateQueue([a, b], autoplay: true);
    player.position = const Duration(minutes: 4, seconds: 10);
    await buffer(20);
    expect(player.window.children, hasLength(1));
    await service.skipToNext();
    expect(service.currentTrack, b);
    expect(player.activeUri.scheme, 'file');
  });

  test(
    'MPV volume mapping preserves platform volume curves and gain',
    () async {
      await service.setVolume(0.125);
      expect(player.volumes.last, closeTo(0.5, 1e-9));

      await service.updateAudioGain(6);
      expect(player.volumes.last, closeTo(0.6294627, 1e-7));

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await service.setVolume(0.125);
      expect(player.volumes.last, closeTo(0.1573657, 1e-7));
    },
  );

  test(
    'duck end restores gain above normal volume at the current user level',
    () async {
      await service.setVolume(0.5);
      await service.updateAudioGain(12);
      const expected = 1.257930560485005;
      expect(player.volumes.last, closeTo(expected, 1e-9));
      final volumeUpdatesBeforeDuck = player.volumes.length;
      interruptionEvents.add(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      expect(player.volumes, hasLength(volumeUpdatesBeforeDuck));

      // just_audio clamps its duck-end volume restoration to 1.0.
      await player.setVolume(1.0);
      interruptionEvents.add(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );

      await until(() => player.volumes.last > 1.0);
      expect(player.volumes.last, closeTo(expected, 1e-9));
    },
  );
}

class _CacheDownloader extends AudioCacheDownloader {
  _CacheDownloader() : super(files: CacheService.audioCacheFiles);
  final targets = <AudioCacheRequest?>[];
  @override
  Future<bool> setTarget(AudioCacheRequest? request) async {
    targets.add(request);
    return false;
  }
}

class _ControlledAudioSliceStore implements AudioSliceStore {
  final _delegate = const SharedPreferencesAudioSliceStore();
  final _loadStarted = <String, Completer<void>>{};
  final _loadGates = <String, Completer<List<AudioSlice>>>{};

  void hold(String trackKey) {
    _loadStarted[trackKey] = Completer<void>();
    _loadGates[trackKey] = Completer<List<AudioSlice>>();
  }

  Completer<void> loadStarted(String trackKey) => _loadStarted[trackKey]!;

  void release(String trackKey) {
    final gate = _loadGates.remove(trackKey);
    if (gate != null && !gate.isCompleted) gate.complete(const []);
  }

  @override
  Future<List<AudioSlice>> load(String trackKey) async {
    final gate = _loadGates[trackKey];
    if (gate == null) return _delegate.load(trackKey);
    final started = _loadStarted[trackKey]!;
    if (!started.isCompleted) started.complete();
    return gate.future;
  }

  @override
  Future<bool> write(String trackKey, List<AudioSlice> slices) =>
      _delegate.write(trackKey, slices);

  @override
  Future<bool> clear(String trackKey) => _delegate.clear(trackKey);
}

class _WindowPlayer extends ControlledPlayer {
  final indices = StreamController<int?>.broadcast(sync: true);
  final errors = StreamController<PlaybackEvent>.broadcast(sync: true);
  final indexedSeeks = <int>[];
  final firstPlaybackPositions = <String?, Duration>{};
  final volumes = <double>[];
  bool advancePositionOnRead = false;
  int _positionReadOffsetMicros = 0;
  AudioSource? activeChild;
  bool deferIndexWhileSeeking = false;
  bool reportStaleIndex = false;
  bool failIndexedSeek = false;
  ConcatenatingAudioSource get window =>
      loadedAudioSource! as ConcatenatingAudioSource;
  Uri get activeUri => (window.children[currentIndex] as UriAudioSource).uri;
  @override
  Duration get position {
    final position =
        super.position + Duration(microseconds: _positionReadOffsetMicros);
    if (advancePositionOnRead) _positionReadOffsetMicros++;
    return position;
  }

  @override
  set position(Duration value) {
    super.position = value;
    _positionReadOffsetMicros = 0;
  }

  void emitStoredPosition() => positions.add(super.position);

  @override
  int get currentIndex {
    if (reportStaleIndex) return 1;
    if (deferIndexWhileSeeking && pendingSeek != null) return 0;
    final source = loadedAudioSource;
    if (source is! ConcatenatingAudioSource) return 0;
    final index = source.children.indexOf(activeChild!);
    return index < 0 ? 0 : index;
  }

  @override
  Stream<int?> get currentIndexStream => indices.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream => errors.stream;
  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setShuffleModeEnabled(bool enabled) async {}

  @override
  void emitPlayerState() {
    if (playing && processingState == ProcessingState.ready) {
      firstPlaybackPositions.putIfAbsent(source, () => super.position);
    }
    super.emitPlayerState();
  }

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    final child = source is ConcatenatingAudioSource
        ? source.children[initialIndex ?? 0]
        : source;
    activeChild = child;
    reportStaleIndex = false;
    final duration = await super.setAudioSource(
      child,
      preload: preload,
      initialPosition: initialPosition,
    );
    loadedAudioSource = source;
    indices.add(currentIndex);
    return duration;
  }

  void transition(int index, {ProcessingState state = ProcessingState.ready}) {
    activeChild = window.children[index];
    reportStaleIndex = false;
    source = activeUri.toString();
    position = Duration.zero;
    processingState = state;
    indices.add(index);
    emitPlayerState();
  }

  void transitionToPreparedChild(AudioSource child) {
    activeChild = child;
    reportStaleIndex = true;
    source = (child as UriAudioSource).uri.toString();
    position = Duration.zero;
    processingState = ProcessingState.ready;
    indices.add(1);
    emitPlayerState();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (index != null) {
      indexedSeeks.add(index);
      if (failIndexedSeek) {
        failIndexedSeek = false;
        throw PlayerException(0, 'indexed seek failed');
      }
      activeChild = window.children[index];
      reportStaleIndex = false;
      source = activeUri.toString();
      indices.add(index);
    }
    await super.seek(position, index: index);
  }

  @override
  Future<void> stop() async {
    finishSeek();
    await super.stop();
  }

  @override
  Future<void> dispose() async {
    await indices.close();
    await errors.close();
    await super.dispose();
  }
}

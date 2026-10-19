import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/audio_cache_downloader.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/speculative_transfer_coordinator.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart'
    show ControlledPlayer, MemorySessionStore, until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _WindowPlayer player;
  late _CacheDownloader downloader;
  late AudioPlayerService service;
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
    root = await Directory.systemTemp.createTemp('kiko-native-next-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
    player = _WindowPlayer();
    downloader = _CacheDownloader();
    service = AudioPlayerService.forTesting(
      player,
      sessionStore: MemorySessionStore(),
      androidSeekRecovery: true,
      androidNativePreload: true,
      seekRecoveryTimeout: const Duration(milliseconds: 100),
      cacheDownloader: downloader,
    );
  });

  tearDown(() async {
    await service.dispose();
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

  Future<void> warm() async {
    await service.updateQueue([a, b, c], autoplay: true);
    player.position = const Duration(minutes: 4, seconds: 10);
    await buffer(20);
    await until(() => player.window.children.length == 2);
    await Future<void>.delayed(Duration.zero);
  }

  test('manual next reuses the native source without another load', () async {
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
  });

  test('natural transition publishes once after a no-op enqueue', () async {
    final published = <AudioTrack?>[];
    final subscription = service.currentTrackStream.listen(published.add);
    await warm();
    expect(await service.enqueueNext(b), EnqueueNextResult.alreadyNext);
    player.transition(1);
    await until(() => service.currentTrack == b && !service.isTrackLoading);
    expect(player.loaded, [a.url]);
    expect(published.map((track) => track?.id), ['a', 'b']);
    expect(service.currentIndex, 1);
    await subscription.cancel();
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
      player.holdNextSeek = true;
      final switching = service.skipToNext();
      await until(() => player.pendingSeek != null);
      await Future.wait([
        switching,
        service.stop(),
      ]).timeout(const Duration(seconds: 1));
      expect(service.currentTrack, a);
      expect(player.playing, isFalse);
    },
  );

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

class _WindowPlayer extends ControlledPlayer {
  final indices = StreamController<int?>.broadcast(sync: true);
  final errors = StreamController<PlaybackEvent>.broadcast(sync: true);
  final indexedSeeks = <int>[];
  AudioSource? activeChild;
  bool failIndexedSeek = false;
  ConcatenatingAudioSource get window =>
      loadedAudioSource! as ConcatenatingAudioSource;
  Uri get activeUri => (window.children[currentIndex] as UriAudioSource).uri;
  @override
  int get currentIndex {
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
  Future<void> setShuffleModeEnabled(bool enabled) async {}
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
    source = activeUri.toString();
    position = Duration.zero;
    processingState = state;
    indices.add(index);
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

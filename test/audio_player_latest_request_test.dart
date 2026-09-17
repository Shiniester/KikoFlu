import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/playback_session_store.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const tracks = [
  AudioTrack(id: 'a', title: 'A', url: 'https://example.invalid/a.wav'),
  AudioTrack(id: 'b', title: 'B', url: 'https://example.invalid/b.flac'),
  AudioTrack(id: 'c', title: 'C', url: 'https://example.invalid/c.wav'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledPlayer player;
  late AudioPlayerService service;
  late MemorySessionStore sessions;
  late Directory cacheRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://example.invalid',
      'current_user': '{"name":"tester"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    cacheRoot = await Directory.systemTemp.createTemp('kiko-player-request-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => cacheRoot.path,
        );
    player = ControlledPlayer();
    sessions = MemorySessionStore();
    service = AudioPlayerService.forTesting(player, sessionStore: sessions);
    service.updatePreloadThreshold(null);
  });

  tearDown(() async {
    await service.dispose();
    await cacheRoot.delete(recursive: true);
  });

  test(
    'interrupted complete-cache load preserves the file and avoids fallback',
    () async {
      const hash = 'complete-audio';
      final partial = await CacheService.prepareAudioCacheTempFile(hash);
      await partial.writeAsBytes([1, 2, 3, 4]);
      expect(
        await CacheService.finalizeAudioCacheFile(hash, expectedSize: 4),
        isTrue,
      );
      final path = await CacheService.audioCacheFinalPath(hash);
      final cached = AudioTrack(
        id: 'cache',
        title: 'cache.wav',
        url: Uri.file(path).toString(),
        hash: hash,
      );
      player.holdNextLoad = true;
      final first = service.updateQueue([cached, tracks[2]], autoplay: true);
      await until(() => player.pendingLoad != null);
      await service.skipToNext();
      await first;
      expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
      expect(await CacheService.getCachedAudioFile(hash), path);
      expect(player.loaded.where((path) => path.startsWith('http')), [
        tracks[2].url,
      ]);
      expect(service.currentTrack?.id, 'c');
    },
  );

  test('next during A loading merges B and C and publishes only C', () async {
    final published = <String?>[];
    final loading = <bool>[];
    final trackSub = service.currentTrackStream.listen(
      (t) => published.add(t?.id),
    );
    final loadSub = service.trackLoadingStream.listen(loading.add);
    player.holdNextLoad = true;
    final first = service.updateQueue(tracks, autoplay: true);
    await until(() => player.pendingLoad != null);
    final second = service.skipToNext();
    final third = service.skipToNext();
    await Future.wait([first, second, third]);
    await Future<void>.delayed(Duration.zero);
    expect(player.loaded, [tracks[0].url, tracks[2].url]);
    expect(player.stopCount, 1);
    expect(published, ['c']);
    expect(loading, [true, false]);
    expect(service.currentIndex, 2);
    expect(player.played, [tracks[2].url]);
    await service.persistPlaybackSession();
    expect(sessions.snapshot?.currentIndex, 2);
    await trackSub.cancel();
    await loadSub.cancel();
  });

  test('immediately awaited switches do not strand the drain', () async {
    await service.updateQueue(tracks);
    await service.skipToNext();
    await service.skipToNext();
    expect(service.currentTrack?.id, 'c');
    expect(service.isTrackLoading, isFalse);
  });

  testWidgets(
    'loading overlay accepts next while protecting the progress slider',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(() => service.updateQueue(tracks, autoplay: true));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlayerServiceProvider.overrideWithValue(service),
            lyricAutoLoaderProvider.overrideWith((ref) {}),
          ],
          child: const MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: AudioPlayerScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      player.holdNextLoad = true;
      final next = find.byKey(const ValueKey('player-skip-next-button'));
      await tester.runAsync(() => tester.tap(next));
      for (var i = 0; i < 10 && player.pendingLoad == null; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(service.isTrackLoading, isTrue);
      await tester.pump();
      expect(
        tester
            .widget<IgnorePointer>(
              find.byKey(const ValueKey('player-progress-loading-guard')),
            )
            .ignoring,
        isTrue,
      );
      expect(player.seeks, isEmpty);
      await tester.runAsync(() => tester.tap(next));
      for (var i = 0; i < 15 && service.currentTrack?.id != 'c'; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(service.currentTrack?.id, 'c');
      expect(player.played, [tracks[0].url, tracks[2].url]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  test(
    'stopping the initial load retains its selected index for play',
    () async {
      final published = <String?>[];
      final subscription = service.currentTrackStream.listen(
        (track) => published.add(track?.id),
      );
      player.holdNextLoad = true;
      final loading = service.updateQueue(tracks, startIndex: 2);
      await until(() => player.pendingLoad != null);
      await service.stop();
      await loading;
      await service.play();
      await Future<void>.delayed(Duration.zero);
      expect(service.currentTrack?.id, 'c');
      expect(service.currentIndex, 2);
      expect(player.played, [tracks[2].url]);
      expect(published, ['c']);
      await subscription.cancel();
    },
  );

  test(
    'play after canceling a replacement queue resumes its selected track',
    () async {
      await service.updateQueue([tracks[0]], autoplay: true);
      player.holdNextLoad = true;
      final replacement = service.updateQueue([tracks[2]], autoplay: true);
      await until(() => player.pendingLoad != null);
      await service.stop();
      await replacement;
      await service.play();
      expect(service.currentTrack?.id, 'c');
      expect(player.played, [tracks[0].url, tracks[2].url]);
      expect(service.playing, isTrue);
    },
  );

  test('replacement queue waits for an outstanding clear stop', () async {
    await service.updateQueue(tracks, autoplay: true);
    player.stopGate = Completer<void>();
    final clearing = service.clearQueue();
    await until(() => player.stopCount == 1);
    final replacement = service.updateQueue([tracks[2]], autoplay: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.loaded, [tracks[0].url]);
    player.stopGate!.complete();
    await Future.wait([clearing, replacement]);
    expect(service.currentTrack?.id, 'c');
    expect(service.playing, isTrue);
  });

  test('pause during loading prevents automatic playback', () async {
    player.holdNextLoad = true;
    final loading = service.updateQueue(tracks, autoplay: true);
    await until(() => player.pendingLoad != null);
    await service.pause();
    player.finishLoad();
    await loading;
    expect(service.currentTrack?.id, 'a');
    expect(player.played, isEmpty);
    expect(service.playing, isFalse);
  });

  test('stop during B load then play reloads the committed A source', () async {
    await service.updateQueue(tracks, autoplay: true);
    player.holdNextLoad = true;
    final loading = service.skipToNext();
    await until(() => player.pendingLoad != null);
    await service.stop();
    await loading;
    await service.play();
    expect(service.currentTrack?.id, 'a');
    expect(player.source, tracks[0].url);
    expect(player.played, [tracks[0].url, tracks[0].url]);
  });

  test(
    'play while stop is unwinding resumes after its native barrier',
    () async {
      await service.updateQueue(tracks, autoplay: true);
      player.holdNextLoad = true;
      final loading = service.skipToNext();
      await until(() => player.pendingLoad != null);
      player.stopGate = Completer<void>();
      final stopping = service.stop();
      await service.play();
      expect(player.played, [tracks[0].url]);
      player.stopGate!.complete();
      await Future.wait([loading, stopping]);
      expect(player.source, tracks[0].url);
      expect(service.playing, isTrue);
    },
  );

  test(
    'a new selection during stop wins without being stopped afterwards',
    () async {
      await service.updateQueue(tracks, autoplay: true);
      player.stopGate = Completer<void>();
      final stopping = service.stop();
      await until(() => player.stopCount == 1);
      final switching = service.skipToIndex(2);
      player.stopGate!.complete();
      await Future.wait([stopping, switching]);
      expect(player.source, tracks[2].url);
      expect(service.currentTrack?.id, 'c');
      expect(service.playing, isTrue);
    },
  );

  test(
    'superseded history restore cannot seek or play its replacement',
    () async {
      player.holdNextLoad = true;
      final restoring = service.updateQueue(
        [tracks[0]],
        autoplay: true,
        initialPosition: const Duration(seconds: 24),
      );
      await until(() => player.pendingLoad != null);
      final latest = service.updateQueue([tracks[2]], autoplay: true);
      await Future.wait([restoring, latest]);
      expect(player.seeks, isEmpty);
      expect(player.played, [tracks[2].url]);
      expect(service.currentTrack?.id, 'c');
    },
  );

  test(
    'clear during loading leaves no published track or saved session',
    () async {
      await service.updateQueue(tracks, autoplay: true);
      player.holdNextLoad = true;
      final loading = service.skipToNext();
      await until(() => player.pendingLoad != null);
      await service.clearQueue();
      await loading;
      expect(service.queue, isEmpty);
      expect(service.currentTrack, isNull);
      expect(service.isTrackLoading, isFalse);
      expect(player.playing, isFalse);
      expect(sessions.snapshot, isNull);
    },
  );

  test('seek remains protected while the new source is loading', () async {
    player.holdNextLoad = true;
    final loading = service.updateQueue(tracks);
    await until(() => player.pendingLoad != null);
    await service.seek(const Duration(seconds: 8));
    await service.seekForward(const Duration(seconds: 10));
    await service.seekBackward(const Duration(seconds: 10));
    expect(player.seeks, isEmpty);
    player.finishLoad();
    await loading;
    await service.seek(const Duration(seconds: 8));
    expect(player.seeks, [const Duration(seconds: 8)]);
  });

  test(
    'restore read completed after a new queue cannot overwrite it',
    () async {
      sessions.loadGate = Completer<PlaybackSessionSnapshot?>();
      final restore = service.restorePlaybackSession();
      await service.updateQueue([tracks[2]], autoplay: true);
      sessions.loadGate!.complete(
        const PlaybackSessionSnapshot(
          queue: tracks,
          currentIndex: 0,
          position: Duration(seconds: 24),
          ownerKey: 'https://example.invalid\ntester',
        ),
      );
      await restore;
      expect(service.currentTrack?.id, 'c');
      expect(player.seeks, isEmpty);
    },
  );
}

Future<void> until(bool Function() ready) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Expected operation did not start');
}

class ControlledPlayer extends Fake implements AudioPlayer {
  final loaded = <String>[];
  final played = <String?>[];
  final seeks = <Duration>[];
  String? source;
  bool holdNextLoad = false;
  Completer<Duration?>? pendingLoad;
  Completer<void>? stopGate;
  int stopCount = 0;
  @override
  bool playing = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 5);
  @override
  ProcessingState processingState = ProcessingState.idle;
  @override
  PlayerState get playerState => PlayerState(playing, processingState);
  @override
  Stream<PlayerState> get playerStateStream => Stream.value(playerState);
  @override
  Stream<Duration> get positionStream => Stream.value(position);
  @override
  Stream<Duration?> get durationStream => Stream.value(duration);
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setLoopMode(LoopMode mode) async {}

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    source = url;
    loaded.add(url);
    position = Duration.zero;
    processingState = ProcessingState.loading;
    if (holdNextLoad) {
      holdNextLoad = false;
      final pending = Completer<Duration?>();
      pendingLoad = pending;
      await pending.future;
      if (identical(pendingLoad, pending)) pendingLoad = null;
    }
    processingState = ProcessingState.ready;
    return duration;
  }

  @override
  Future<Duration?> setFilePath(
    String path, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) => setUrl(
    path,
    initialPosition: initialPosition,
    preload: preload,
    tag: tag,
  );

  void finishLoad() {
    pendingLoad!.complete(duration);
  }

  @override
  Future<void> play() async {
    playing = true;
    played.add(source);
  }

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> stop() async {
    stopCount++;
    playing = false;
    final pending = pendingLoad;
    pendingLoad = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(PlayerInterruptedException('Loading interrupted'));
    }
    await stopGate?.future;
    processingState = ProcessingState.idle;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    this.position = position ?? Duration.zero;
    seeks.add(this.position);
  }

  @override
  Future<void> dispose() async {}
}

class MemorySessionStore implements PlaybackSessionStore {
  PlaybackSessionSnapshot? snapshot;
  Completer<PlaybackSessionSnapshot?>? loadGate;
  @override
  Future<PlaybackSessionSnapshot?> load() async => loadGate?.future ?? snapshot;
  @override
  Future<void> save(PlaybackSessionSnapshot snapshot) async =>
      this.snapshot = snapshot;
  @override
  Future<void> savePosition(Duration position) async {}
  @override
  Future<void> clear() async => snapshot = null;
}

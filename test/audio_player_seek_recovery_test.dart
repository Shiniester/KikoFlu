import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart'
    show ControlledPlayer, MemorySessionStore, until;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SeekPlayer player;
  late AudioPlayerService service;
  late Directory root;
  late AudioTrack track;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://example.invalid',
      'current_user': '{"name":"tester"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    root = await Directory.systemTemp.createTemp('kiko-seek-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
    final file = await File('${root.path}/local.flac').writeAsBytes([1, 2, 3]);
    track = AudioTrack(
      id: 'local',
      title: 'local.flac',
      url: file.uri.toString(),
    );
    player = SeekPlayer();
    service = AudioPlayerService.forTesting(
      player,
      sessionStore: MemorySessionStore(),
      androidSeekRecovery: true,
      localSeekTimeout: const Duration(milliseconds: 100),
    );
    service.updatePreloadThreshold(null);
    await service.updateQueue([track], autoplay: true);
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await service.dispose();
    await root.delete(recursive: true);
  });

  test(
    'native seek error reloads at the target and resumes playback',
    () async {
      final published = <AudioTrack?>[];
      final subscription = service.currentTrackStream.listen(published.add);
      const target = Duration(minutes: 2);
      final seeking = service.seek(target);
      player.failSeek();
      await until(() => player.reloadPositions.isNotEmpty);
      await seeking;
      expect(player.reloadPositions, [target]);
      expect(player.stopCount, 1);
      expect(player.seeks, [target]);
      expect(service.currentTrack, track);
      expect(player.position, target);
      expect(player.processingState, ProcessingState.ready);
      expect(player.playing, isTrue);
      expect(published, isEmpty);
      await subscription.cancel();
    },
  );

  test('normal seek completes without reloading the source', () async {
    const target = Duration(seconds: 25);
    final seeking = service.seek(target);
    player.finishSeek();
    await seeking;
    expect(player.reloadPositions, isEmpty);
    expect(player.stopCount, 0);
    expect(player.position, target);
    expect(player.playing, isTrue);
  });

  test(
    'a native error after seek returns reloads at the target on play',
    () async {
      const target = Duration(minutes: 2);
      final seeking = service.seek(target);
      player.finishSeek();
      await seeking;
      player.processingState = ProcessingState.buffering;
      player.failSeek();
      await Future<void>.delayed(Duration.zero);
      expect(player.playing, isFalse);
      expect(player.reloadPositions, isEmpty);
      expect(service.isTrackLoading, isFalse);
      await service.pause();
      await service.play();
      expect(player.reloadPositions, [target]);
      expect(player.position, target);
      expect(player.processingState, ProcessingState.ready);
      expect(player.playing, isTrue);
      expect(service.currentTrack, track);
    },
  );

  test(
    'a stalled recovery load times out and can be retried at the target',
    () async {
      const target = Duration(minutes: 2);
      player.holdNextLoad = true;
      final seeking = service.seek(target);
      final failure = expectLater(
        seeking.timeout(const Duration(seconds: 2)),
        throwsA(isA<TimeoutException>()),
      );
      player.failSeek();
      await until(() => player.pendingLoad != null);
      await failure;
      expect(service.isTrackLoading, isFalse);
      expect(player.playing, isFalse);
      expect(player.stopCount, 2);
      await service.play();
      expect(player.reloadPositions, [target, target]);
      expect(player.position, target);
      expect(player.processingState, ProcessingState.ready);
      expect(player.playing, isTrue);
    },
  );

  test('an error arriving with the seek reply is still recovered', () async {
    const target = Duration(minutes: 2);
    final seeking = service.seek(target);
    player.finishSeek();
    player.failSeek();
    await seeking;
    expect(player.reloadPositions, [target]);
    expect(player.processingState, ProcessingState.ready);
    expect(player.playing, isTrue);
  });

  test(
    'late errors while paused wait for explicit play without retrying',
    () async {
      const target = Duration(minutes: 2);
      await service.pause();
      final seeking = service.seek(target);
      player.finishSeek();
      await seeking;
      player.failSeek();
      player.failSeek();
      await Future<void>.delayed(Duration.zero);
      expect(player.playing, isFalse);
      expect(player.reloadPositions, isEmpty);
      await service.play();
      expect(player.reloadPositions, [target]);
      player.failSeek();
      await Future<void>.delayed(Duration.zero);
      expect(player.playing, isFalse);
      expect(player.reloadPositions, [target]);
      await service.play();
      expect(player.reloadPositions, [target, target]);
      expect(player.position, target);
      expect(player.playing, isTrue);
    },
  );

  test(
    'a stalled recovery stop fails without releasing the native barrier',
    () async {
      final gate = Completer<void>();
      player.stopGate = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      const target = Duration(minutes: 2);
      final seeking = service.seek(target);
      final failure = expectLater(seeking, throwsA(isA<TimeoutException>()));
      player.failSeek();
      await failure;
      expect(service.isTrackLoading, isFalse);
      expect(player.reloadPositions, isEmpty);
      await expectLater(service.play(), throwsA(isA<TimeoutException>()));
      expect(service.isTrackLoading, isFalse);
      expect(player.loaded, hasLength(1));
      await expectLater(service.stop(), throwsA(isA<TimeoutException>()));
      expect(player.playing, isFalse);
      gate.complete();
      await service.play();
      expect(player.reloadPositions, [target]);
      expect(player.position, target);
      expect(player.playing, isTrue);
    },
  );

  for (final lateFailure in [false, true]) {
    test(
      'timed-out recovery waits for late ${lateFailure ? 'failure' : 'success'} before the newest track',
      () async {
        player.holdNextLoad = true;
        player.leaveLoadPendingOnStop = true;
        final unwind = Completer<void>();
        player.loadUnwindGate = unwind;
        addTearDown(() {
          if (!unwind.isCompleted) unwind.complete();
          final pending = player.pendingLoad;
          if (pending != null && !pending.isCompleted) player.finishLoad();
        });
        final published = <String?>[];
        final subscription = service.currentTrackStream.listen((value) {
          published.add(value?.id);
        });
        addTearDown(subscription.cancel);
        final seeking = service.seek(const Duration(minutes: 1));
        final failure = expectLater(seeking, throwsA(isA<TimeoutException>()));
        player.failSeek();
        await failure;
        expect(service.isTrackLoading, isFalse);
        expect(player.stopCount, 2);
        expect(player.playing, isFalse);
        const next = AudioTrack(
          id: 'next',
          title: 'Next',
          url: 'https://example.invalid/next.wav',
        );
        const latest = AudioTrack(
          id: 'latest',
          title: 'Latest',
          url: 'https://example.invalid/latest.wav',
        );
        final switching = service.updateQueue([next], autoplay: true);
        final newest = service.updateQueue([latest], autoplay: true);
        await Future<void>.delayed(Duration.zero);
        expect(player.loaded, hasLength(2));
        if (lateFailure) {
          player.pendingLoad!.completeError(
            PlayerInterruptedException('Late abort'),
          );
        } else {
          player.finishLoad();
        }
        await Future<void>.delayed(Duration.zero);
        expect(player.loaded, hasLength(2));
        unwind.complete();
        await Future.wait([switching, newest]);
        expect(published, ['latest']);
        expect(player.source, latest.url);
        expect(service.currentTrack, latest);
        expect(player.playing, isTrue);
        expect(service.isTrackLoading, isFalse);
      },
    );
  }

  test(
    'stopping or replacing the track clears the old seek error ownership',
    () async {
      final seeking = service.seek(const Duration(minutes: 2));
      player.finishSeek();
      await seeking;
      await service.stop();
      player.failSeek();
      await service.play();
      expect(player.reloadPositions, isEmpty);
      final next = track.copyWith(id: 'next');
      await service.updateQueue([next], autoplay: true);
      player.failSeek();
      await Future<void>.delayed(Duration.zero);
      expect(player.playing, isTrue);
      expect(player.reloadPositions, isEmpty);
      expect(service.currentTrack, next);
    },
  );

  test(
    'a local seek stuck buffering recovers once after its deadline',
    () async {
      const target = Duration(minutes: 3);
      final seeking = service.seek(target);
      expect(player.reloadPositions, isEmpty);
      await seeking.timeout(const Duration(seconds: 10));
      expect(player.reloadPositions, [target]);
      expect(player.processingState, ProcessingState.ready);
      expect(player.playing, isTrue);
      player.failSeek();
      await Future<void>.delayed(Duration.zero);
      expect(player.reloadPositions, [target]);
    },
  );

  test('a no-op seek without a READY transition does not reload', () async {
    await service.pause();
    player.position = const Duration(seconds: 20);
    final seeking = service.seek(const Duration(seconds: 20));
    player.processingState = ProcessingState.ready;
    await seeking.timeout(const Duration(seconds: 10));
    expect(player.reloadPositions, isEmpty);
    expect(player.playing, isFalse);
  });

  test(
    'a distant seek with stale READY still recovers when it times out',
    () async {
      const target = Duration(minutes: 2);
      final seeking = service.seek(target);
      player.processingState = ProcessingState.ready;
      await seeking.timeout(const Duration(seconds: 10));
      expect(player.reloadPositions, [target]);
      expect(player.position, target);
      expect(player.playing, isTrue);
    },
  );

  test('pause during the failed seek remains paused after recovery', () async {
    const target = Duration(minutes: 1);
    final seeking = service.seek(target);
    await service.pause();
    player.failSeek();
    await until(() => player.reloadPositions.isNotEmpty);
    await seeking;
    expect(player.position, target);
    expect(player.playing, isFalse);
    await service.play();
    expect(player.playing, isTrue);
    expect(player.reloadPositions, [target]);
  });

  test('pause while recovery is loading prevents automatic playback', () async {
    final seeking = service.seek(const Duration(minutes: 1));
    player.holdNextLoad = true;
    player.failSeek();
    await until(() => player.pendingLoad != null);
    await service.pause();
    player.finishLoad();
    await seeking;
    expect(player.playing, isFalse);
    expect(player.position, const Duration(minutes: 1));
  });

  test(
    'play while recovery is loading resumes at the requested position',
    () async {
      await service.pause();
      final seeking = service.seek(const Duration(minutes: 1));
      player.holdNextLoad = true;
      player.failSeek();
      await until(() => player.pendingLoad != null);
      await service.play();
      player.finishLoad();
      await seeking;
      expect(player.playing, isTrue);
      expect(player.position, const Duration(minutes: 1));
    },
  );

  test(
    'a newer seek cancels the old wait and only recovers the latest target',
    () async {
      final oldSeek = service.seek(const Duration(minutes: 1));
      final oldNativeSeek = player.pendingSeek!;
      const latestTarget = Duration(minutes: 3);
      final latestSeek = service.seek(latestTarget);
      player.failSeek();
      await Future.wait([oldSeek, latestSeek]);
      oldNativeSeek.complete();
      await Future<void>.delayed(Duration.zero);
      expect(player.reloadPositions, [latestTarget]);
      expect(player.position, latestTarget);
    },
  );

  test(
    'stop during a pending seek cancels recovery and remains stopped',
    () async {
      final seeking = service.seek(const Duration(minutes: 1));
      await service.stop();
      player.failSeek();
      await seeking;
      expect(player.reloadPositions, isEmpty);
      expect(player.playing, isFalse);
      expect(player.processingState, ProcessingState.idle);
    },
  );

  test(
    'a new track during a pending seek cannot restore the old track',
    () async {
      final seeking = service.seek(const Duration(minutes: 1));
      const next = AudioTrack(
        id: 'next',
        title: 'Next',
        url: 'https://example.invalid/next.wav',
      );
      await service.updateQueue([next], autoplay: true);
      player.failSeek();
      await seeking;
      expect(player.reloadPositions, isEmpty);
      expect(service.currentTrack, next);
      expect(player.playing, isTrue);
    },
  );

  test('a new track waits for the recovery stop and then wins', () async {
    const next = AudioTrack(
      id: 'next',
      title: 'Next',
      url: 'https://example.invalid/next.wav',
    );
    final seeking = service.seek(const Duration(minutes: 1));
    player.stopGate = Completer<void>();
    player.failSeek();
    await until(() => player.stopCount == 1);
    final switching = service.updateQueue([next], autoplay: true);
    expect(player.loaded, hasLength(1));
    player.stopGate!.complete();
    await Future.wait([seeking, switching]);
    expect(player.reloadPositions, isEmpty);
    expect(player.source, next.url);
    expect(service.currentTrack, next);
    expect(player.playing, isTrue);
  });

  test('stop during recovery loading cannot restart the source', () async {
    final seeking = service.seek(const Duration(minutes: 1));
    player.holdNextLoad = true;
    player.failSeek();
    await until(() => player.pendingLoad != null);
    await service.stop();
    await seeking;
    expect(player.reloadPositions, hasLength(1));
    expect(player.playing, isFalse);
    expect(service.isTrackLoading, isFalse);
  });

  test('a failed recovery stop does not block the next track load', () async {
    player.failNextStop = true;
    final seeking = service.seek(const Duration(minutes: 1));
    final failure = expectLater(seeking, throwsA(isA<PlayerException>()));
    player.failSeek();
    await failure;
    const next = AudioTrack(
      id: 'next',
      title: 'Next',
      url: 'https://example.invalid/next.wav',
    );
    await service.updateQueue([next], autoplay: true);
    expect(service.currentTrack, next);
    expect(player.playing, isTrue);
    expect(service.isTrackLoading, isFalse);
  });

  test(
    'failed seek recovery preserves the complete cache without fallback',
    () async {
      const hash = 'seek-complete-cache';
      final partial = await CacheService.prepareAudioCacheTempFile(hash);
      await partial.writeAsBytes([1, 2, 3, 4]);
      await CacheService.finalizeAudioCacheFile(hash, expectedSize: 4);
      final path = await CacheService.audioCacheFinalPath(hash);
      final cached = AudioTrack(
        id: 'cached',
        title: 'cached.wav',
        url: Uri.file(path).toString(),
        hash: hash,
      );
      await service.updateQueue([cached], autoplay: true);
      player.failReload = true;
      final seeking = service.seek(const Duration(minutes: 1));
      final failure = expectLater(seeking, throwsA(isA<PlayerException>()));
      player.failSeek();
      await failure;
      expect(player.reloadPositions, [const Duration(minutes: 1)]);
      expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
      expect(await CacheService.getCachedAudioFile(hash), path);
      expect(player.loaded.where((url) => url.startsWith('http')), isEmpty);
      expect(player.playing, isFalse);
      expect(service.isTrackLoading, isFalse);
      expect(service.currentTrack, cached);
    },
  );

  test(
    'late error and recovery timeout retain the complete cache for retry',
    () async {
      const hash = 'seek-late-error-cache';
      final partial = await CacheService.prepareAudioCacheTempFile(hash);
      await partial.writeAsBytes([1, 2, 3, 4]);
      await CacheService.finalizeAudioCacheFile(hash, expectedSize: 4);
      final path = await CacheService.audioCacheFinalPath(hash);
      final cached = AudioTrack(
        id: 'cached',
        title: 'cached.wav',
        url: Uri.file(path).toString(),
        hash: hash,
      );
      await service.updateQueue([cached], autoplay: true);
      const target = Duration(minutes: 2);
      final seeking = service.seek(target);
      player.finishSeek();
      await seeking;
      player.failSeek();
      await Future<void>.delayed(Duration.zero);
      player.holdNextLoad = true;
      await expectLater(service.play(), throwsA(isA<TimeoutException>()));
      expect(service.isTrackLoading, isFalse);
      expect(player.playing, isFalse);
      expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
      expect(await CacheService.getCachedAudioFile(hash), path);
      await service.play();
      expect(player.reloadPositions, [target, target]);
      expect(player.position, target);
      expect(player.processingState, ProcessingState.ready);
      expect(player.playing, isTrue);
      expect(player.loaded.where((url) => url.startsWith('http')), isEmpty);
      expect(service.currentTrack, cached);
    },
  );
}

/// Models the just_audio 0.9.44 Android contract: native seek errors arrive on
/// playbackEventStream while the seek Future remains pending. Play/pause alone
/// cannot prepare the failed source again.
class SeekPlayer extends ControlledPlayer {
  final events = StreamController<PlaybackEvent>.broadcast(sync: true);
  final reloadPositions = <Duration?>[];
  Completer<void>? pendingSeek;
  bool failReload = false;
  bool failNextStop = false;
  bool leaveLoadPendingOnStop = false;
  Completer<void>? loadUnwindGate;

  @override
  Stream<PlaybackEvent> get playbackEventStream => events.stream;

  @override
  AudioSource? get audioSource => source == null
      ? null
      : AudioSource.uri(
          source!.startsWith('https:') ? Uri.parse(source!) : Uri.file(source!),
        );

  @override
  Future<void> seek(Duration? position, {int? index}) {
    this.position = position ?? Duration.zero;
    seeks.add(this.position);
    processingState = ProcessingState.buffering;
    pendingSeek = Completer<void>();
    return pendingSeek!.future;
  }

  void failSeek() => events.addError(PlayerException(2, 'Native seek failed'));

  void finishSeek() {
    processingState = ProcessingState.ready;
    pendingSeek!.complete();
  }

  @override
  Future<void> stop() async {
    if (failNextStop) {
      failNextStop = false;
      throw PlayerException(2, 'Native stop failed');
    }
    if (leaveLoadPendingOnStop && pendingLoad != null) {
      stopCount++;
      playing = false;
      processingState = ProcessingState.idle;
      return;
    }
    await super.stop();
  }

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    reloadPositions.add(initialPosition);
    if (failReload) throw PlayerException(2, 'Native prepare failed');
    try {
      await super.setUrl(
        (source as UriAudioSource).uri.toFilePath(),
        initialPosition: initialPosition,
      );
    } finally {
      final gate = loadUnwindGate;
      if (gate != null) {
        await gate.future;
        // just_audio's activation cleanup can deactivate the platform after
        // stop has returned; a new load must wait for this Future to settle.
        playing = false;
        processingState = ProcessingState.idle;
      }
    }
    position = initialPosition ?? Duration.zero;
    return duration;
  }

  @override
  Future<void> dispose() async => events.close();
}

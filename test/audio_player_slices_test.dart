import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/models/audio_slice.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/audio_slice_store.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart'
    show ControlledPlayer, MemorySessionStore, until;

const _duration = Duration(minutes: 5);

AudioTrack _track(String id) => AudioTrack(
  id: id,
  title: id,
  url: 'https://example.invalid/$id.mp3',
  workId: 41,
  duration: _duration,
);

void _emitPosition(ControlledPlayer player, int milliseconds) {
  final position = Duration(milliseconds: milliseconds);
  player.position = position;
  player.positions.add(position);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledPlayer player;
  late AudioPlayerService service;
  late MemorySessionStore sessions;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://example.invalid',
      'current_user': '{"name":"tester"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    player = ControlledPlayer();
    sessions = MemorySessionStore();
    service = AudioPlayerService.forTesting(player, sessionStore: sessions);
    service.updatePreloadThreshold(null);
  });

  tearDown(() async {
    await service.dispose();
  });

  test(
    'marking twice saves a positive, bounded range and rejects overlap',
    () async {
      await service.updateQueue([_track('a')]);
      final trackKey = service.sliceState.trackKey!;

      player.position = const Duration(seconds: 10);
      expect(await service.markSlice(), isTrue);
      expect(service.sliceState.pendingStartMs, 10000);

      player.position = const Duration(seconds: 20);
      expect(await service.markSlice(), isTrue);
      const saved = AudioSlice(startMs: 10000, endMs: 20000);
      expect(service.sliceState.slices, [saved]);
      expect(service.sliceState.pendingStartMs, isNull);

      expect(
        await service.saveSlice(
          trackKey: trackKey,
          slice: const AudioSlice(startMs: 15000, endMs: 25000),
        ),
        isFalse,
      );
      expect(
        await service.saveSlice(
          trackKey: trackKey,
          slice: const AudioSlice(startMs: 20000, endMs: 30000),
        ),
        isTrue,
      );
      expect(
        await service.saveSlice(
          trackKey: trackKey,
          slice: const AudioSlice(startMs: 300000, endMs: 300001),
        ),
        isFalse,
      );
      expect(
        await service.saveSlice(
          trackKey: trackKey,
          slice: const AudioSlice(startMs: 30000, endMs: 30000),
        ),
        isFalse,
      );
    },
  );

  test(
    'marking a slice can use subtitle times without seeking playback',
    () async {
      await service.updateQueue([_track('subtitle-time')]);
      player.position = const Duration(seconds: 90);

      expect(
        await service.markSlice(position: const Duration(seconds: -1)),
        isFalse,
      );
      expect(service.sliceState.pendingStartMs, isNull);
      expect(
        await service.markSlice(position: const Duration(seconds: 10)),
        isTrue,
      );
      expect(service.sliceState.pendingStartMs, 10000);
      expect(
        await service.markSlice(position: const Duration(seconds: 30)),
        isTrue,
      );

      expect(service.sliceState.slices.single.startMs, 10000);
      expect(service.sliceState.slices.single.endMs, 30000);
      expect(player.position, const Duration(seconds: 90));
    },
  );

  test('adjacent slices are allowed and edits/deletes persist', () async {
    final track = _track('a');
    await service.updateQueue([track]);
    final key = service.sliceState.trackKey!;
    const first = AudioSlice(startMs: 1000, endMs: 2000);
    const edited = AudioSlice(startMs: 500, endMs: 1500);
    const adjacent = AudioSlice(startMs: 2000, endMs: 3000);

    expect(await service.saveSlice(trackKey: key, slice: first), isTrue);
    expect(
      await service.saveSlice(trackKey: key, slice: edited, replacing: first),
      isTrue,
    );
    expect(await service.saveSlice(trackKey: key, slice: adjacent), isTrue);
    expect(service.sliceState.slices, [edited, adjacent]);
    expect(await service.deleteSlice(key, edited), isTrue);
    expect(service.sliceState.slices, [adjacent]);
    expect(await service.clearSlices(key), isTrue);

    const store = SharedPreferencesAudioSliceStore();
    expect(await store.load(key), isEmpty);
  });

  test(
    'only-slices skips gaps and resumes a paused seek at the next range',
    () async {
      await service.updateQueue([_track('a')]);
      final key = service.sliceState.trackKey!;
      const first = AudioSlice(startMs: 10000, endMs: 20000);
      const second = AudioSlice(startMs: 30000, endMs: 40000);
      await service.saveSlice(trackKey: key, slice: first);
      await service.saveSlice(trackKey: key, slice: second);
      service.setOnlySlices(true);

      service.setSliceScrubbing(true);
      expect(await service.seek(const Duration(milliseconds: 25000)), isTrue);
      service.setSliceScrubbing(false);
      expect(player.position, const Duration(milliseconds: 25000));

      await service.play();
      expect(player.position, const Duration(milliseconds: 30000));
      expect(player.playing, isTrue);

      _emitPosition(player, 25000);
      await until(() => player.position == const Duration(milliseconds: 30000));
      expect(service.currentTrack?.id, 'a');
    },
  );

  test('autoplay track changes start at the first saved slice', () async {
    const nextTrack = AudioTrack(
      id: 'b',
      title: 'b',
      url: 'https://example.invalid/b.mp3',
      workId: 41,
      hash: 'b',
      duration: _duration,
    );
    const firstSlice = AudioSlice(startMs: 10000, endMs: 20000);
    await const SharedPreferencesAudioSliceStore().write(
      audioSliceTrackKey(nextTrack),
      const [firstSlice],
    );
    await service.updateQueue([_track('a'), nextTrack], autoplay: true);
    service.setOnlySlices(true);

    await service.skipToNext();

    expect(service.currentTrack?.id, 'b');
    expect(player.initialPositions.last, const Duration(milliseconds: 10000));
    expect(player.position, const Duration(milliseconds: 10000));
    expect(player.playing, isTrue);
  });

  test(
    'autoplay initial position past the last slice wraps to the first',
    () async {
      const track = AudioTrack(
        id: 'a',
        title: 'a',
        url: 'https://example.invalid/a.mp3',
        workId: 41,
        hash: 'a',
        duration: _duration,
      );
      await const SharedPreferencesAudioSliceStore()
          .write(audioSliceTrackKey(track), const [
            AudioSlice(startMs: 10000, endMs: 20000),
            AudioSlice(startMs: 30000, endMs: 40000),
          ]);
      service.setOnlySlices(true);

      await service.updateQueue(
        [track],
        autoplay: true,
        initialPosition: const Duration(seconds: 240),
      );

      expect(player.initialPositions.last, const Duration(milliseconds: 10000));
      expect(player.position, const Duration(milliseconds: 10000));
      expect(player.playing, isTrue);
    },
  );

  test(
    'superseding a slice-position correction releases the next load',
    () async {
      const targetTrack = AudioTrack(
        id: 'b',
        title: 'b',
        url: 'https://example.invalid/b.mp3',
        workId: 41,
        hash: 'b',
        duration: _duration,
      );
      const winningTrack = AudioTrack(
        id: 'c',
        title: 'c',
        url: 'https://example.invalid/c.mp3',
        workId: 41,
        hash: 'c',
        duration: _duration,
      );
      await const SharedPreferencesAudioSliceStore().write(
        audioSliceTrackKey(targetTrack),
        const [AudioSlice(startMs: 10000, endMs: 20000)],
      );

      player.holdNextLoad = true;
      final supersededLoad = service.updateQueue([targetTrack], autoplay: true);
      await until(() => player.pendingLoad != null);
      service.setOnlySlices(true);
      player.holdNextSeek = true;
      player.finishLoad();
      await until(() => player.pendingSeek != null);

      await service
          .updateQueue([winningTrack], autoplay: true)
          .timeout(const Duration(seconds: 1));
      await supersededLoad.timeout(const Duration(seconds: 1));
      expect(service.currentTrack?.id, 'c');

      player.finishSeek();
      await until(() => player.pendingSeek == null);
      expect(service.currentTrack?.id, 'c');
      expect(player.position, Duration.zero);
    },
  );

  test(
    'manual seek after the last range wraps to the first while playing',
    () async {
      await service.updateQueue([_track('a')]);
      final key = service.sliceState.trackKey!;
      const first = AudioSlice(startMs: 10000, endMs: 20000);
      const last = AudioSlice(startMs: 30000, endMs: 40000);
      await service.saveSlice(trackKey: key, slice: first);
      await service.saveSlice(trackKey: key, slice: last);
      service.setOnlySlices(true);
      await service.play();
      final seeksBeforeManualPosition = player.seeks.length;
      await service.seek(const Duration(milliseconds: 50000));

      await until(
        () =>
            player.seeks.length > seeksBeforeManualPosition &&
            player.position == const Duration(milliseconds: 10000),
      );
      expect(player.position, const Duration(milliseconds: 10000));
      expect(player.playing, isTrue);
    },
  );

  test(
    'repeat-one restarts the first slice when the track completes',
    () async {
      await service.updateQueue([_track('a')]);
      final key = service.sliceState.trackKey!;
      const first = AudioSlice(startMs: 10000, endMs: 20000);
      await service.saveSlice(trackKey: key, slice: first);
      service.setOnlySlices(true);
      await service.setRepeatMode(LoopMode.one);
      await service.play();

      player.position = _duration;
      player.playing = false;
      player.processingState = ProcessingState.completed;
      player.emitPlayerState();
      await until(
        () =>
            player.seeks.contains(const Duration(milliseconds: 10000)) &&
            player.playing,
      );
      expect(service.currentTrack?.id, 'a');
    },
  );

  test(
    'final slice boundary advances normally or pauses at queue end',
    () async {
      final firstTrack = _track('a');
      final nextTrack = _track('b');
      await service.updateQueue([firstTrack, nextTrack]);
      final key = service.sliceState.trackKey!;
      const last = AudioSlice(startMs: 10000, endMs: 20000);
      await service.saveSlice(trackKey: key, slice: last);
      service.setOnlySlices(true);
      await service.setRepeatMode(LoopMode.all);
      await service.play();
      _emitPosition(player, 20000);

      await until(() => service.currentTrack?.id == 'b');
      expect(player.playing, isTrue);
      expect(service.sliceState.onlySlices, isTrue);

      await service.updateQueue([firstTrack], autoplay: true);
      await service.setRepeatMode(LoopMode.off);
      final clearCountBefore = sessions.clearCount;
      _emitPosition(player, 20000);
      await until(
        () => !player.playing && sessions.clearCount > clearCountBefore,
      );
      expect(sessions.clearCount, greaterThan(clearCountBefore));
    },
  );

  test(
    'preview pauses at its end and does not change only-slices mode',
    () async {
      await service.updateQueue([_track('a')]);
      final key = service.sliceState.trackKey!;
      const preview = AudioSlice(startMs: 10000, endMs: 20000);
      await service.saveSlice(trackKey: key, slice: preview);
      service.setOnlySlices(true);

      await service.previewSlice(key, preview);
      expect(player.playing, isTrue);
      expect(service.sliceState.preview, preview);
      expect(service.sliceState.onlySlices, isTrue);

      _emitPosition(player, preview.endMs);
      await until(() => !player.playing && service.sliceState.preview == null);
      expect(player.position, const Duration(milliseconds: 20000));
      expect(service.sliceState.onlySlices, isTrue);
    },
  );

  test('preview action does not wait for just-audio play completion', () async {
    await service.dispose();
    player = _DeferredPlayPlayer();
    service = AudioPlayerService.forTesting(player, sessionStore: sessions);
    await service.updateQueue([_track('a')]);
    final key = service.sliceState.trackKey!;
    const preview = AudioSlice(startMs: 10000, endMs: 20000);
    await service.saveSlice(trackKey: key, slice: preview);

    await service
        .previewSlice(key, preview)
        .timeout(const Duration(seconds: 1));
    expect(player.playing, isTrue);
    _emitPosition(player, preview.endMs);
    await until(() => !player.playing && service.sliceState.preview == null);
  });

  test('pause wins over a preview with a pending seek', () async {
    await service.updateQueue([_track('a')]);
    final key = service.sliceState.trackKey!;
    const preview = AudioSlice(startMs: 10000, endMs: 20000);
    await service.saveSlice(trackKey: key, slice: preview);

    player.holdNextSeek = true;
    final previewOperation = service.previewSlice(key, preview);
    await until(() => player.pendingSeek != null);

    await service.pause();
    expect(player.playing, isFalse);

    player.finishSeek();
    await previewOperation;

    expect(player.playing, isFalse);
    expect(service.sliceState.preview, preview);
  });

  test('Only Slices toggle preserves a preview with a pending seek', () async {
    await service.updateQueue([_track('a')]);
    final key = service.sliceState.trackKey!;
    const preview = AudioSlice(startMs: 10000, endMs: 20000);
    await service.saveSlice(trackKey: key, slice: preview);

    player.holdNextSeek = true;
    final previewOperation = service.previewSlice(key, preview);
    await until(() => player.pendingSeek != null);

    service.setOnlySlices(true);
    player.finishSeek();
    await previewOperation;

    expect(player.playing, isTrue);
    expect(service.sliceState.preview, preview);
    expect(service.sliceState.onlySlices, isTrue);
  });

  test(
    'preview completion takes priority over natural track completion',
    () async {
      await service.updateQueue([_track('a')]);
      final key = service.sliceState.trackKey!;
      final preview = AudioSlice(
        startMs: 10000,
        endMs: _duration.inMilliseconds,
      );
      await service.saveSlice(trackKey: key, slice: preview);
      await service.previewSlice(key, preview);
      final clearCountBefore = sessions.clearCount;

      player.position = _duration;
      player.playing = false;
      player.processingState = ProcessingState.completed;
      player.emitPlayerState();
      await until(() => service.sliceState.preview == null);
      expect(service.currentTrack?.id, 'a');
      expect(sessions.clearCount, clearCountBefore);
    },
  );

  test('rapid track switches load only the winning track slices', () async {
    final tracks = [_track('a'), _track('b'), _track('c')];
    const store = SharedPreferencesAudioSliceStore();
    const slices = [
      AudioSlice(startMs: 1000, endMs: 2000),
      AudioSlice(startMs: 3000, endMs: 4000),
      AudioSlice(startMs: 5000, endMs: 6000),
    ];
    for (var index = 0; index < tracks.length; index++) {
      await store.write(audioSliceTrackKey(tracks[index]), [slices[index]]);
    }
    await service.updateQueue(tracks);
    service.setOnlySlices(true);

    player.holdNextLoad = true;
    final toSecond = service.skipToNext();
    await until(() => player.pendingLoad != null);
    final toThird = service.skipToNext();
    await Future.wait([toSecond, toThird]);

    expect(service.currentTrack?.id, 'c');
    expect(service.sliceState.trackKey, audioSliceTrackKey(tracks.last));
    expect(service.sliceState.slices, [slices.last]);
    expect(service.sliceState.onlySlices, isTrue);
  });

  test('failed persistence does not publish a saved slice', () async {
    await service.dispose();
    player = ControlledPlayer();
    service = AudioPlayerService.forTesting(
      player,
      sessionStore: sessions,
      sliceStore: const _FailingSliceStore(),
    );
    await service.updateQueue([_track('a')]);
    final key = service.sliceState.trackKey!;

    expect(
      await service.saveSlice(
        trackKey: key,
        slice: const AudioSlice(startMs: 1000, endMs: 2000),
      ),
      isFalse,
    );
    expect(service.sliceState.slices, isEmpty);
  });

  test('failed load hides stale slices and blocks mutations safely', () async {
    await service.dispose();
    player = ControlledPlayer();
    final store = _UnreadableSliceStore();
    service = AudioPlayerService.forTesting(
      player,
      sessionStore: sessions,
      sliceStore: store,
    );
    await service.updateQueue([_track('a')]);

    expect(service.currentTrack?.id, 'a');
    expect(service.sliceState.trackKey, isNull);
    expect(service.sliceState.slices, isEmpty);
    expect(service.sliceState.onlySlices, isFalse);
    expect(
      await service.saveSlice(
        trackKey: audioSliceTrackKey(_track('a')),
        slice: const AudioSlice(startMs: 1000, endMs: 2000),
      ),
      isFalse,
    );
    expect(store.writeCount, 0);
  });
}

class _FailingSliceStore implements AudioSliceStore {
  const _FailingSliceStore();

  @override
  Future<bool> clear(String trackKey) async => false;

  @override
  Future<List<AudioSlice>> load(String trackKey) async => const [];

  @override
  Future<bool> write(String trackKey, List<AudioSlice> slices) async => false;
}

class _UnreadableSliceStore implements AudioSliceStore {
  int writeCount = 0;

  @override
  Future<bool> clear(String trackKey) async => false;

  @override
  Future<List<AudioSlice>> load(String trackKey) async {
    throw StateError('storage unavailable');
  }

  @override
  Future<bool> write(String trackKey, List<AudioSlice> slices) async {
    writeCount++;
    return true;
  }
}

class _DeferredPlayPlayer extends ControlledPlayer {
  final Completer<void> playCompletion = Completer<void>();

  @override
  Future<void> play() async {
    playing = true;
    played.add(source);
    emitPlayerState();
    await playCompletion.future;
  }

  @override
  Future<void> pause() async {
    if (!playCompletion.isCompleted) playCompletion.complete();
    await super.pause();
  }

  @override
  Future<void> dispose() async {
    if (!playCompletion.isCompleted) playCompletion.complete();
    await super.dispose();
  }
}

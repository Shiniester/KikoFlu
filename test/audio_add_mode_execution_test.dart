import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_tap_playlist_mode.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/history_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/playback_session_store.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart'
    show ControlledPlayer, MemorySessionStore, until;

const _tracks = [
  AudioTrack(
    id: 'a',
    title: 'A',
    url: 'https://example.invalid/a.wav',
    workId: 1,
  ),
  AudioTrack(
    id: 'b',
    title: 'B',
    url: 'https://example.invalid/b.wav',
    workId: 1,
  ),
  AudioTrack(
    id: 'c',
    title: 'C',
    url: 'https://example.invalid/c.wav',
    workId: 1,
  ),
];
const _work = Work(id: 1, title: 'Work');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledPlayer player;
  late AudioPlayerService service;
  late _GateSessionStore sessions;
  late ProviderContainer container;
  late AudioPlayerController controller;
  late _History history;
  late _Api api;
  late Directory cacheRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://example.invalid',
      'current_user': '{"name":"tester"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    cacheRoot = await Directory.systemTemp.createTemp('kiko-add-mode-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => cacheRoot.path,
        );
    player = ControlledPlayer();
    sessions = _GateSessionStore();
    service = AudioPlayerService.forTesting(player, sessionStore: sessions);
    service.updatePreloadThreshold(null);
    api = _Api();
    container = ProviderContainer(
      overrides: [
        audioPlayerServiceProvider.overrideWithValue(service),
        kikoeruApiServiceProvider.overrideWithValue(api),
        historyProvider.overrideWith((ref) => _History(ref)),
      ],
    );
    history = container.read(historyProvider.notifier) as _History;
    controller = container.read(audioPlayerControllerProvider.notifier);
    container.read(miniPlayerVisibilityProvider.notifier).hide();
    await container.read(audioTapPlaylistModeProvider.notifier).getMode();
  });

  tearDown(() async {
    container.dispose();
    await service.dispose();
    await cacheRoot.delete(recursive: true);
  });

  Future<void> setMode(AudioTapPlaylistMode mode) =>
      container.read(audioTapPlaylistModeProvider.notifier).updateMode(mode);

  Future<void> select(bool multiple) => multiple
      ? controller.playTracks(_tracks, startIndex: 1, work: _work)
      : controller.playTrack(_tracks[1]);

  Future<void> restoreWithHeldLoad() {
    sessions.snapshot = PlaybackSessionSnapshot(
      queue: [_tracks[0]],
      currentIndex: 0,
      position: Duration.zero,
      ownerKey: 'https://example.invalid\ntester',
    );
    player.holdNextLoad = true;
    return service.restorePlaybackSession();
  }

  for (final selectedIndex in [0, 1]) {
    test(
      'adding audio after a failed restore starts selection $selectedIndex',
      () async {
        final restore = restoreWithHeldLoad();
        await until(() => player.pendingLoad != null);
        player.pendingLoad!.completeError(StateError('restore failed'));
        await restore;

        await controller.playTracks([
          _tracks[selectedIndex],
        ], playlistMode: AudioTapPlaylistMode.addToQueue);
        expect(service.currentTrack?.id, _tracks[selectedIndex].id);
        expect(service.playing, isTrue);
        expect(
          service.queue.map((track) => track.id),
          selectedIndex == 0 ? ['a'] : ['a', 'b'],
        );
        expect(container.read(miniPlayerVisibilityProvider), isTrue);
      },
    );
  }

  for (final mode in [
    AudioTapPlaylistMode.addToQueue,
    AudioTapPlaylistMode.playNext,
  ]) {
    test(
      '$mode starts selected audio while a session restore is pending',
      () async {
        final restore = restoreWithHeldLoad();
        await until(() => player.pendingLoad != null);
        try {
          await controller.playTracks([_tracks[1]], playlistMode: mode);
          expect(service.currentTrack?.id, 'b');
          expect(service.playing, isTrue);
          expect(service.queue.map((track) => track.id), ['a', 'b']);
          expect(container.read(miniPlayerVisibilityProvider), isTrue);
        } finally {
          if (player.pendingLoad != null) player.finishLoad();
          await restore;
        }
      },
    );
  }

  test('selection during failed restore cleanup is persisted', () async {
    sessions.clearGate = Completer<void>();
    sessions.clearStarted = Completer<void>();
    final restore = restoreWithHeldLoad();
    await until(() => player.pendingLoad != null);
    player.pendingLoad!.completeError(StateError('restore failed'));
    await sessions.clearStarted!.future;
    try {
      await controller.playTracks([
        _tracks[0],
      ], playlistMode: AudioTapPlaylistMode.addToQueue);
      expect(service.currentTrack?.id, 'a');
    } finally {
      sessions.clearGate!.complete();
      await restore;
    }
    await until(() => sessions.snapshot != null);
    expect(sessions.snapshot!.queue.map((track) => track.id), ['a']);
  });

  test('a newer selection wins while an addition is saving', () async {
    final restore = restoreWithHeldLoad();
    await until(() => player.pendingLoad != null);
    player.pendingLoad!.completeError(StateError('restore failed'));
    await restore;

    sessions.saveGate = Completer<void>();
    sessions.saveStarted = Completer<void>();
    final adding = controller.playTracks([
      _tracks[1],
    ], playlistMode: AudioTapPlaylistMode.addToQueue);
    await sessions.saveStarted!.future;
    player.holdNextLoad = true;
    final newer = service.updateQueue(
      [_tracks[1], _tracks[2]],
      startIndex: 1,
      autoplay: true,
    );
    await until(() => player.pendingLoad != null);
    try {
      sessions.saveGate!.complete();
      await adding;
      if (player.pendingLoad != null) player.finishLoad();
      await newer;
      expect(service.currentTrack?.id, 'c');
      expect(service.playing, isTrue);
    } finally {
      if (!sessions.saveGate!.isCompleted) sessions.saveGate!.complete();
      if (player.pendingLoad != null) player.finishLoad();
      await Future.wait([adding, newer]);
    }
  });

  for (final multiple in [false, true]) {
    final entry = multiple ? 'playTracks' : 'playTrack';
    for (final mode in AudioTapPlaylistMode.values) {
      for (final empty in [false, true]) {
        test('$entry uses $mode with empty=$empty', () async {
          if (!empty) await service.updateQueue([_tracks[0], _tracks[2]]);
          await setMode(mode);
          await select(multiple);
          final replaces = mode == AudioTapPlaylistMode.replaceQueue;
          expect(
            service.queue.map((track) => track.id).toList(),
            replaces
                ? (multiple ? ['a', 'b', 'c'] : ['b'])
                : empty
                ? ['b']
                : mode == AudioTapPlaylistMode.playNext
                ? ['a', 'b', 'c']
                : ['a', 'c', 'b'],
          );
          expect(service.currentTrack?.id, replaces || empty ? 'b' : 'a');
          expect(service.playing, replaces);
          expect(container.read(miniPlayerVisibilityProvider), isTrue);
          expect(history.calls, hasLength(replaces ? 1 : 0));
          expect(api.requests, replaces && !multiple ? [1] : isEmpty);
          if (replaces) {
            expect(history.calls.single.work.id, 1);
            expect(history.calls.single.track, multiple ? null : _tracks[1]);
            expect(history.calls.single.positionMs, multiple ? null : 0);
          }
        });
      }
    }

    test('$entry waits for queue dismissal', () async {
      await service.updateQueue([_tracks.first]);
      await setMode(AudioTapPlaylistMode.replaceQueue);
      player.stopGate = Completer<void>();
      final clearing = controller.clearQueueAndStop();
      await until(() => player.stopCount > 0);
      final adding = select(multiple);
      await Future<void>.delayed(Duration.zero);
      expect(service.queue, isEmpty);
      expect(player.loaded, hasLength(1));
      player.stopGate!.complete();
      await clearing;
      await adding;
      expect(service.currentTrack?.id, 'b');
      expect(container.read(miniPlayerVisibilityProvider), isTrue);
    });

    test(
      '$entry propagates load failure without visibility or history',
      () async {
        await setMode(AudioTapPlaylistMode.replaceQueue);
        player.holdNextLoad = true;
        final adding = select(multiple);
        final failure = expectLater(adding, throwsStateError);
        await until(() => player.pendingLoad != null);
        player.pendingLoad!.completeError(StateError('load failed'));
        await failure;
        expect(container.read(miniPlayerVisibilityProvider), isFalse);
        expect(history.calls, isEmpty);
        expect(api.requests, isEmpty);
      },
    );

    test('$entry play-next preserves current and already-next items', () async {
      await setMode(AudioTapPlaylistMode.playNext);
      await service.updateQueue(_tracks, startIndex: 1);
      await select(multiple);
      expect(service.queue, _tracks);
      await service.updateQueue(_tracks);
      await select(multiple);
      expect(service.queue, _tracks);
      expect(history.calls, isEmpty);
    });
  }

  test('empty list leaves queue, visibility and history alone', () async {
    await service.updateQueue(_tracks);
    await controller.playTracks([], work: _work);
    expect(service.queue, _tracks);
    expect(container.read(miniPlayerVisibilityProvider), isFalse);
    expect(history.calls, isEmpty);
  });

  for (final index in [-2, 20]) {
    test(
      'explicit mode overrides preference and clamps index $index',
      () async {
        await setMode(AudioTapPlaylistMode.addToQueue);
        await controller.playTracks(
          _tracks,
          startIndex: index,
          playlistMode: AudioTapPlaylistMode.replaceQueue,
        );
        expect(service.queue, _tracks);
        expect(service.currentTrack?.id, index < 0 ? 'a' : 'c');
        expect(service.playing, isTrue);
        expect(history.calls, isEmpty);
      },
    );
  }

  test(
    'single-track history retains position when work metadata arrives',
    () async {
      await setMode(AudioTapPlaylistMode.replaceQueue);
      api.pending = Completer<Map<String, dynamic>>();
      final playing = controller.playTrack(_tracks.first);
      await until(() => api.requests.isNotEmpty);
      player.position = const Duration(seconds: 17);
      api.pending!.complete(_work.toJson());
      await playing;
      expect(history.calls.single.track, _tracks.first);
      expect(history.calls.single.positionMs, 17000);
    },
  );

  test('late work metadata cannot record a superseded single track', () async {
    await setMode(AudioTapPlaylistMode.replaceQueue);
    api.pending = Completer<Map<String, dynamic>>();
    final playing = controller.playTrack(_tracks.first);
    await until(() => api.requests.isNotEmpty);
    await service.updateQueue([_tracks.last]);
    api.pending!.complete(_work.toJson());
    await playing;
    expect(history.calls, isEmpty);
  });
}

class _GateSessionStore extends MemorySessionStore {
  Completer<void>? clearGate;
  Completer<void>? clearStarted;
  Completer<void>? saveGate;
  Completer<void>? saveStarted;

  @override
  Future<void> clear() async {
    clearStarted?.complete();
    await clearGate?.future;
    await super.clear();
  }

  @override
  Future<void> save(PlaybackSessionSnapshot snapshot) async {
    if (saveGate != null && !saveGate!.isCompleted) {
      if (saveStarted?.isCompleted == false) saveStarted!.complete();
      await saveGate!.future;
    }
    await super.save(snapshot);
  }
}

class _Api extends Fake implements KikoeruApiService {
  final requests = <int>[];
  Completer<Map<String, dynamic>>? pending;

  @override
  Future<Map<String, dynamic>> getWork(
    int id, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    requests.add(id);
    return pending == null ? _work.toJson() : pending!.future;
  }
}

class _History extends HistoryNotifier {
  _History(super.ref);
  final calls = <({Work work, AudioTrack? track, int? positionMs})>[];

  @override
  Future<void> load({
    bool refresh = false,
    bool force = false,
    int? targetPage,
  }) async {}

  @override
  Future<void> addOrUpdate(
    Work work, {
    AudioTrack? track,
    int? positionMs,
  }) async {
    calls.add((work: work, track: track, positionMs: positionMs));
  }
}

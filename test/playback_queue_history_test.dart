import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/automatic_marking_event.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/automatic_work_marking_service.dart';
import 'package:kikoeru_flutter/src/services/playback_session_store.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_latest_request_test.dart'
    show ControlledPlayer, MemorySessionStore, until;
import 'automatic_work_marking_test.dart' as marking_fixture;

AudioTrack _track(String id) => AudioTrack(
  id: id,
  title: id,
  url: 'https://example.invalid/$id.mp3',
  workId: 42,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _HistoryTestPlayer player;
  late _MemoryQueueHistoryStore historyStore;
  late MemorySessionStore sessionStore;
  late AudioPlayerService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'server_host': 'https://example.invalid',
      'current_user': '{"name":"alice"}',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    player = _HistoryTestPlayer();
    historyStore = _MemoryQueueHistoryStore();
    sessionStore = MemorySessionStore();
    service = AudioPlayerService.forTesting(
      player,
      sessionStore: sessionStore,
      queueHistoryStore: historyStore,
    );
    service.updatePreloadThreshold(null);
  });

  tearDown(() async {
    await service.dispose();
  });

  test(
    'replacement archives edited queues and explicit clear archives once',
    () async {
      await service.updateQueue([_track('a'), _track('b'), _track('c')]);
      await service.appendTracks([_track('d')]);
      await service.moveTrack(3, 0);
      await service.removeTrackAt(2);
      expect(service.historicalQueues, isEmpty);

      await service.updateQueue([_track('next')]);

      expect(service.historicalQueues, hasLength(1));
      expect(service.historicalQueues.single.queue.map((track) => track.id), [
        'd',
        'a',
        'c',
      ]);
      expect(service.historicalQueues.single.currentIndex, 1);

      await service.clearQueue();
      expect(service.historicalQueues.map((queue) => queue.queue.first.id), [
        'next',
        'd',
      ]);

      await service.updateQueue([_track('last')]);
      await service.removeTrackAt(0);
      expect(service.historicalQueues.map((queue) => queue.queue.first.id), [
        'next',
        'd',
      ]);
    },
  );

  test(
    'restoring history swaps queues, preserves identity, and chooses position',
    () async {
      await service.updateQueue(
        [_track('a'), _track('b')],
        startIndex: 1,
        initialPosition: const Duration(seconds: 20),
      );
      await service.updateQueue([
        _track('c'),
      ], initialPosition: const Duration(seconds: 7));
      final historyA = service.historicalQueues.single;
      final queueAId = historyA.markingQueueId;
      expect(historyA.currentIndex, 1);
      expect(historyA.position, const Duration(seconds: 20));

      expect(await service.restoreHistoricalQueue(historyA, 1), isTrue);
      expect(player.initialPositions.last, const Duration(seconds: 20));
      expect(service.currentTrack?.id, 'b');
      expect(service.historicalQueues.single.queue.single.id, 'c');

      final historyB = service.historicalQueues.single;
      expect(await service.restoreHistoricalQueue(historyB, 0), isTrue);
      expect(player.initialPositions.last, const Duration(seconds: 7));
      expect(service.currentTrack?.id, 'c');
      expect(service.historicalQueues.single.markingQueueId, queueAId);

      final returnedA = service.historicalQueues.single;
      expect(await service.restoreHistoricalQueue(returnedA, 0), isTrue);
      expect(player.initialPositions.last, Duration.zero);
      expect(service.currentTrack?.id, 'a');
      expect(service.historicalQueues.single.queue.single.id, 'c');
    },
  );

  test('historical track selection marks completed audio as replay', () async {
    final (marking, operations) = _observeAutomaticMarking(service);
    await service.updateQueue([marking_fixture.a]);
    await service.persistPlaybackSession();
    await marking.event(
      AutomaticMarkingEventType.completed,
      track: marking_fixture.a,
      queue: [marking_fixture.a],
      queueId: sessionStore.snapshot!.markingQueueId!,
    );
    expect(marking.online[1], 'listened');
    await service.updateQueue([_track('other')]);

    final historical = service.historicalQueues.single;
    expect(await service.restoreHistoricalQueue(historical, 0), isTrue);
    player.position = const Duration(seconds: 1);
    player.positions.add(player.position);
    await Future.wait(operations);

    expect(marking.online[1], 'replay');
  });

  for (final failure in ['source load', 'history save']) {
    test(
      'failed replacement at history capacity preserves older queue completion ($failure)',
      () async {
        final (marking, operations) = _observeAutomaticMarking(service);
        final oldest = await _fillHistoryWithPartialCompletion(
          service,
          sessionStore,
          marking,
        );

        if (failure == 'source load') {
          player.failingUrl = _track('failed').url;
        } else {
          historyStore.failNextSave = true;
        }
        await expectLater(
          service.updateQueue([_track('failed')]),
          throwsStateError,
        );
        expect(
          service.historicalQueues.last.markingQueueId,
          oldest.markingQueueId,
        );

        expect(await service.restoreHistoricalQueue(oldest, 1), isTrue);
        await marking.event(
          AutomaticMarkingEventType.completed,
          track: marking_fixture.b,
          queue: [marking_fixture.a, marking_fixture.b],
          queueId: oldest.markingQueueId!,
        );
        await Future.wait(operations);

        expect(marking.online[1], 'listened');
      },
    );
  }

  test(
    'stopped replacement keeps its identity and completions after a failed session restore',
    () async {
      final (marking, operations) = _observeAutomaticMarking(service);
      final oldest = await _fillHistoryWithPartialCompletion(
        service,
        sessionStore,
        marking,
      );
      await service.persistPlaybackSession();
      final previousQueueId = sessionStore.snapshot!.markingQueueId!;
      player.holdNextLoad = true;
      final replacing = service.updateQueue([_track('failed')]);
      await until(() => player.pendingLoad != null);
      await service.stop();
      await replacing;
      await service.persistPlaybackSession();
      expect(sessionStore.snapshot!.markingQueueId, isNot(previousQueueId));
      await Future.wait(operations);
      await service.dispose();

      player = _HistoryTestPlayer()..failingUrl = _track('failed').url;
      service = AudioPlayerService.forTesting(
        player,
        sessionStore: sessionStore,
        queueHistoryStore: historyStore,
      );
      service.updatePreloadThreshold(null);
      final (restoredMarking, restoredOperations) = _observeAutomaticMarking(
        service,
        saved: marking.persisted,
      );
      await service.restorePlaybackSession();
      expect(sessionStore.snapshot, isNull);
      expect(await service.restoreHistoricalQueue(oldest, 1), isTrue);
      await restoredMarking.event(
        AutomaticMarkingEventType.completed,
        track: marking_fixture.b,
        queue: [marking_fixture.a, marking_fixture.b],
        queueId: oldest.markingQueueId!,
      );
      await Future.wait(restoredOperations);

      expect(restoredMarking.online[1], 'listened');
    },
  );

  test(
    'superseded replacement and explicit clear archive only published queues',
    () async {
      await service.updateQueue([_track('a')]);
      player.holdNextLoad = true;
      final replacingB = service.updateQueue([_track('b')]);
      await until(() => player.pendingLoad != null);
      final replacingC = service.updateQueue([_track('c')]);
      await Future.wait([replacingB, replacingC]);

      expect(service.currentTrack?.id, 'c');
      expect(service.historicalQueues.map((queue) => queue.queue.single.id), [
        'a',
      ]);

      player.holdNextLoad = true;
      final replacingD = service.updateQueue([_track('d')]);
      await until(() => player.pendingLoad != null);
      await service.clearQueue();
      await replacingD;

      expect(service.queue, isEmpty);
      expect(service.historicalQueues.map((queue) => queue.queue.single.id), [
        'c',
        'a',
      ]);
    },
  );

  test(
    'failed historical load keeps its history and restores the published queue',
    () async {
      await service.updateQueue([_track('a')]);
      await service.updateQueue([_track('b')]);
      final historyA = service.historicalQueues.single;
      player.failingUrl = _track('a').url;

      await expectLater(
        service.restoreHistoricalQueue(historyA, 0),
        throwsA(isA<StateError>()),
      );

      expect(service.queue.single.id, 'b');
      expect(service.currentTrack?.id, 'b');
      expect(
        service.historicalQueues.single.markingQueueId,
        historyA.markingQueueId,
      );
    },
  );

  test(
    'history write failure after source load preserves the prior restore point and marking state',
    () async {
      final persisted = <String, dynamic>{};
      const owner = 'https://example.invalid/alice';
      final marking = AutomaticWorkMarkingService(
        enabled: true,
        saved: const {},
        account: () => owner,
        fetchProgress: (id, fresh) async => 'listening',
        writeProgress: (id, progress) async {},
        persist: (data) async {
          final account = data[owner] as Map<String, dynamic>;
          persisted
            ..clear()
            ..addAll(account)
            ..['done'] = List<String>.from(account['done'] as List)
            ..['direct'] = Map<String, dynamic>.from(account['direct'] as Map);
        },
        onChanged: () {},
        onConflict: () {},
        onSynced: () {},
        onError: (_) {},
      );
      final markingOperations = <Future<void>>[];
      final markingEvents = <AutomaticMarkingEvent>[];
      final subscription = service.automaticMarkingEvents.listen((event) {
        markingEvents.add(event);
        markingOperations.add(marking.handle(event));
      });
      addTearDown(() async {
        await subscription.cancel();
        marking.dispose();
      });

      await service.updateQueue([
        _track('a'),
      ], initialPosition: const Duration(seconds: 20));
      await service.updateQueue([
        _track('b'),
      ], initialPosition: const Duration(seconds: 70));
      await Future.wait(markingOperations);
      final historyA = service.historicalQueues.single;
      final queueBId = markingEvents
          .lastWhere((event) => event.type == AutomaticMarkingEventType.replace)
          .queueId;
      expect(queueBId, isNotEmpty);

      await marking.handle(
        AutomaticMarkingEvent(
          AutomaticMarkingEventType.completed,
          queueId: queueBId,
          queue: [_track('b')],
          track: _track('b'),
        ),
      );
      expect(persisted['done'], contains('b'));
      expect(persisted['direct'], contains('b'));

      historyStore.failNextSave = true;
      player.holdNextLoad = true;
      final restoring = service.restoreHistoricalQueue(historyA, 0);
      await until(() => player.pendingLoad != null);
      player.finishLoad();

      await expectLater(restoring, throwsA(isA<StateError>()));
      await Future.wait(markingOperations);
      expect(player.position, const Duration(seconds: 20));
      expect(sessionStore.snapshot?.queue.single.id, 'b');
      expect(sessionStore.snapshot?.position, const Duration(seconds: 70));

      await service.pause();
      await service.appendTracks([_track('c')]);
      expect(sessionStore.snapshot?.queue.map((track) => track.id), ['b', 'c']);
      expect(sessionStore.snapshot?.position, const Duration(seconds: 70));
      expect(persisted['done'], contains('b'));
      expect(persisted['direct'], contains('b'));
      expect(
        service.historicalQueues.single.markingQueueId,
        historyA.markingQueueId,
      );
    },
  );

  test(
    'a newer queue survives clear while its history save is pending',
    () async {
      await service.updateQueue([_track('a')]);
      final saveGate = Completer<void>();
      final saveStarted = Completer<void>();
      historyStore.saveGate = saveGate;
      historyStore.saveStarted = saveStarted;

      final clearing = service.clearQueue();
      await saveStarted.future;
      final replacing = service.updateQueue([_track('b')], autoplay: true);
      await until(() => player.loaded.contains(_track('b').url));
      saveGate.complete();
      await replacing;
      await service.updateQueue([_track('c')], autoplay: true);
      await clearing;

      expect(service.queue.single.id, 'c');
      expect(service.currentTrack?.id, 'c');
      expect(service.historicalQueues.map((queue) => queue.queue.single.id), [
        'b',
        'a',
      ]);
    },
  );

  test(
    'owner change during historical loading keeps the queue and history isolated',
    () async {
      await service.updateQueue([
        _track('a'),
      ], initialPosition: const Duration(seconds: 20));
      await service.updateQueue([
        _track('b'),
      ], initialPosition: const Duration(seconds: 70));
      final historyA = service.historicalQueues.single;
      player.holdNextLoad = true;
      final restoring = service.restoreHistoricalQueue(historyA, 0);
      await until(() => player.pendingLoad != null);

      await StorageService.setMap('current_user', {'name': 'bob'});
      player.finishLoad();

      expect(await restoring, isFalse);
      expect(service.queue.single.id, 'b');
      expect(service.currentTrack?.id, 'b');
      expect(sessionStore.snapshot?.queue.single.id, 'b');
      expect(sessionStore.snapshot?.position, const Duration(seconds: 70));
      expect(
        historyStore.snapshots.single.ownerKey,
        'https://example.invalid\nalice',
      );
      expect(
        historyStore.snapshots.single.markingQueueId,
        historyA.markingQueueId,
      );
      expect(service.historicalQueues, isEmpty);

      await StorageService.setMap('current_user', {'name': 'alice'});
      expect(
        service.historicalQueues.single.markingQueueId,
        historyA.markingQueueId,
      );
    },
  );

  test(
    'owner change during restore without an active queue clears the pending target',
    () async {
      await service.updateQueue([_track('a')]);
      await service.clearQueue();
      final historyA = service.historicalQueues.single;

      player.holdNextLoad = true;
      final restoring = service.restoreHistoricalQueue(historyA, 0);
      await until(() => player.pendingLoad != null);

      await StorageService.setMap('current_user', {'name': 'bob'});
      player.finishLoad();

      expect(await restoring, isFalse);
      expect(service.queue, isEmpty);
      expect(service.currentTrack, isNull);
      expect(service.requestedTrack, isNull);
      final loadedCount = player.loaded.length;
      await service.play();
      expect(player.loaded, hasLength(loadedCount));

      await StorageService.setMap('current_user', {'name': 'alice'});
      expect(
        service.historicalQueues.single.markingQueueId,
        historyA.markingQueueId,
      );
      expect(
        historyStore.snapshots.single.ownerKey,
        'https://example.invalid\nalice',
      );
    },
  );

  test(
    'history is owner-scoped and retains twenty recent queues per owner',
    () async {
      for (var index = 0; index < 21; index++) {
        await service.updateQueue([_track('alice-$index')]);
      }
      expect(service.historicalQueues, hasLength(20));
      expect(service.historicalQueues.first.queue.single.id, 'alice-19');
      expect(service.historicalQueues.last.queue.single.id, 'alice-0');

      await StorageService.setMap('current_user', {'name': 'bob'});
      expect(service.historicalQueues, isEmpty);
      await service.updateQueue([_track('bob-0')]);
      await service.updateQueue([_track('bob-1')]);
      final bobHistory = service.historicalQueues.single;
      expect(bobHistory.queue.single.id, 'bob-0');

      await StorageService.setMap('current_user', {'name': 'alice'});
      expect(service.historicalQueues, hasLength(20));
      expect(await service.restoreHistoricalQueue(bobHistory, 0), isFalse);
      expect(service.historicalQueues.first.queue.single.id, 'alice-20');
      expect(service.historicalQueues.last.queue.single.id, 'alice-1');
    },
  );
}

(marking_fixture.Harness, List<Future<void>>) _observeAutomaticMarking(
  AudioPlayerService service, {
  Map<String, dynamic>? saved,
}) {
  final marking = marking_fixture.Harness(saved: saved);
  final operations = <Future<void>>[];
  final subscription = service.automaticMarkingEvents.listen((event) {
    operations.add(marking.service.handle(event));
  });
  addTearDown(() async {
    await subscription.cancel();
    await Future.wait(operations);
    marking.service.dispose();
  });
  return (marking, operations);
}

Future<PlaybackSessionSnapshot> _fillHistoryWithPartialCompletion(
  AudioPlayerService service,
  MemorySessionStore sessions,
  marking_fixture.Harness marking,
) async {
  await service.updateQueue([marking_fixture.a, marking_fixture.b]);
  await service.persistPlaybackSession();
  final firstQueueId = sessions.snapshot!.markingQueueId!;
  await marking.event(
    AutomaticMarkingEventType.completed,
    track: marking_fixture.a,
    queue: [marking_fixture.a, marking_fixture.b],
    queueId: firstQueueId,
  );
  for (var index = 1; index <= 20; index++) {
    await service.updateQueue([_track('queue-$index')]);
  }
  expect(service.historicalQueues, hasLength(20));
  final oldest = service.historicalQueues.last;
  expect(oldest.markingQueueId, firstQueueId);
  return oldest;
}

class _MemoryQueueHistoryStore implements PlaybackQueueHistoryStore {
  List<PlaybackSessionSnapshot> snapshots = const [];
  Completer<void>? saveGate;
  Completer<void>? saveStarted;
  bool failNextSave = false;

  @override
  Future<List<PlaybackSessionSnapshot>> load() async => snapshots;

  @override
  Future<void> save(List<PlaybackSessionSnapshot> queues) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('history write failed');
    }
    final gate = saveGate;
    if (gate != null) {
      saveGate = null;
      saveStarted?.complete();
      await gate.future;
    }
    snapshots = List.unmodifiable(queues);
  }
}

class _HistoryTestPlayer extends ControlledPlayer {
  String? failingUrl;

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) {
    final source = audioSource is ClippingAudioSource
        ? audioSource.child
        : audioSource;
    if (source is UriAudioSource && source.uri.toString() == failingUrl) {
      throw StateError('historical source failed');
    }
    return super.setAudioSource(
      audioSource,
      preload: preload,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
    );
  }
}

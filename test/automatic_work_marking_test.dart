import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/automatic_marking_event.dart';
import 'package:kikoeru_flutter/src/services/automatic_work_marking_service.dart';

const a = AudioTrack(
  id: 'a',
  hash: 'original-a',
  title: 'A',
  url: 'https://example.invalid/a',
  workId: 1,
);
const b = AudioTrack(
  id: 'b',
  hash: 'original-b',
  title: 'B',
  url: 'https://example.invalid/b',
  workId: 1,
);

class Harness {
  Harness({Map<String, dynamic>? saved}) {
    service = AutomaticWorkMarkingService(
      enabled: true,
      saved: saved,
      account: () => owner,
      fetchProgress: (id, fresh) async {
        if (fresh) await fetchGate?.future;
        if (offline) throw StateError('offline');
        return online[id];
      },
      writeProgress: (id, value) async {
        writes.add(value);
        writeStarted?.complete();
        writeStarted = null;
        await writeGate?.future;
        if (offline) throw StateError('offline');
        online[id] = value;
      },
      persist: (value) async {
        persisted = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
        persistedChanged?.call();
      },
      onChanged: () {
        changes++;
        changed?.call();
      },
      onConflict: () {
        conflicts++;
      },
      onSynced: () {
        synced++;
      },
      onError: errors.add,
    );
  }

  late final AutomaticWorkMarkingService service;
  String? owner = 'https://example.invalid/alice';
  bool offline = false;
  final online = <int, String?>{};
  final writes = <String>[];
  final errors = <Object>[];
  int changes = 0;
  int conflicts = 0;
  int synced = 0;
  Map<String, dynamic> persisted = {};
  Completer<void>? writeGate;
  Completer<void>? writeStarted;
  Completer<void>? fetchGate;
  void Function()? changed;
  void Function()? persistedChanged;

  Future<void> event(
    AutomaticMarkingEventType type, {
    AudioTrack? track,
    List<AudioTrack> queue = const [a, b],
    List<AudioTrack> tracks = const [],
    String queueId = 'queue-1',
  }) => service.handle(
    AutomaticMarkingEvent(
      type,
      queueId: queueId,
      queue: queue,
      track: track ?? (type == AutomaticMarkingEventType.removed ? b : null),
      tracks: tracks,
    ),
  );
}

void main() {
  test(
    'disabling persists pending deletion before a slow online request completes',
    () async {
      final h = Harness();
      h.writeGate = Completer<void>();
      h.writeStarted = Completer<void>();
      final started = h.writeStarted!.future;
      final automatic = h.event(AutomaticMarkingEventType.started, track: a);
      await started;
      await h.service.setEnabled(false);
      expect(
        (h.persisted[h.owner] as Map<String, dynamic>)['pending'],
        isEmpty,
      );
      expect(h.writeGate!.isCompleted, isFalse);
      h.writeGate!.complete();
      await automatic;
    },
  );

  test(
    'track completion reaches disk while an earlier network write is pending',
    () async {
      final h = Harness();
      h.writeGate = Completer<void>();
      h.writeStarted = Completer<void>();
      final started = h.writeStarted!.future;
      final automatic = h.event(AutomaticMarkingEventType.started, track: a);
      await started;
      final persisted = Completer<void>();
      h.persistedChanged = () {
        final completed =
            (h.persisted[h.owner] as Map<String, dynamic>)['completed']
                as List?;
        if (completed?.contains('1/original-a') == true &&
            !persisted.isCompleted) {
          persisted.complete();
        }
      };
      final completing = h.event(
        AutomaticMarkingEventType.completed,
        track: a,
        queue: [a],
      );
      await persisted.future;
      expect(h.writeGate!.isCompleted, isFalse);
      h.writeGate!.complete();
      await Future.wait([automatic, completing]);
    },
  );

  test(
    'accepted refresh invalidates an older intent queued behind another work',
    () async {
      final h = Harness();
      h.service.observeProgress(1, 'marked');
      h.fetchGate = Completer<void>();
      final projected = Completer<void>();
      h.changed = () {
        if (h.service.progressFor(1, null) == 'listening' &&
            !projected.isCompleted) {
          projected.complete();
        }
      };
      final other = h.service.addedToPlaylist(2);
      final oldIntent = h.event(AutomaticMarkingEventType.started, track: a);
      await projected.future;
      h.online[1] = 'postponed';
      h.service.refreshedProgress(
        1,
        'postponed',
        snapshot: h.service.refreshSnapshot(1),
      );
      h.fetchGate!.complete();
      await Future.wait([other, oldIntent]);
      expect(h.online[1], 'postponed');
      expect(h.writes, ['marked']);
    },
  );

  test(
    'known offline state projects immediately before the online read completes',
    () async {
      final h = Harness()..offline = true;
      h.service.observeProgress(1, 'marked');
      h.fetchGate = Completer<void>();
      final projected = Completer<void>();
      h.changed = () {
        if (!projected.isCompleted) projected.complete();
      };
      final operation = h.event(AutomaticMarkingEventType.started, track: a);
      await projected.future;
      expect(h.service.progressFor(1, null), 'listening');
      expect(h.writes, isEmpty);
      h.fetchGate!.complete();
      await operation;
      expect(h.service.progressFor(1, null), 'listening');
    },
  );

  test(
    'rapid wanted listening completed intents stay immediate and supersede old online work',
    () async {
      final h = Harness();
      h.service.observeProgress(1, null);
      h.fetchGate = Completer<void>();
      final wanted = h.event(
        AutomaticMarkingEventType.replace,
        tracks: [a],
        queue: [a],
      );
      final listening = h.event(
        AutomaticMarkingEventType.started,
        track: a,
        queue: [a],
      );
      final completed = h.event(
        AutomaticMarkingEventType.completed,
        track: a,
        queue: [a],
      );
      final projected = Completer<void>();
      h.changed = () {
        if (h.service.progressFor(1, null) == 'listened' &&
            !projected.isCompleted) {
          projected.complete();
        }
      };
      await projected.future;
      expect(h.service.progressFor(1, null), 'listened');
      h.fetchGate!.complete();
      await Future.wait([wanted, listening, completed]);
      expect(h.online[1], 'listened');
      expect(h.writes, ['listened']);
    },
  );

  test('fresh work A response remains valid while work B changes', () async {
    final h = Harness();
    final snapshot = h.service.refreshSnapshot(1);
    await h.service.addedToPlaylist(2);
    h.service.refreshedProgress(1, 'postponed', snapshot: snapshot);
    expect(h.service.progressFor(1, 'postponed'), 'postponed');
  });

  test(
    'fresh response discards pending progress and reports its conservative rollback',
    () async {
      final h = Harness()..offline = true;
      h.service.observeProgress(1, 'marked');
      await h.event(AutomaticMarkingEventType.started, track: a);
      final snapshot = h.service.refreshSnapshot(1);
      h.service.refreshedProgress(1, 'postponed', snapshot: snapshot);
      expect(h.service.progressFor(1, 'postponed'), 'postponed');
      expect(h.conflicts, 1);
    },
  );

  test(
    'queued manual edits while disabled cannot enter a newly selected account',
    () async {
      final h = Harness();
      h.writeGate = Completer<void>();
      h.writeStarted = Completer<void>();
      final started = h.writeStarted!.future;
      final auto = h.event(AutomaticMarkingEventType.started, track: a);
      await started;
      final disabling = h.service.setEnabled(false);
      var manualWrites = 0;
      final manual = h.service.manualUpdate(1, 'postponed', () async {
        manualWrites++;
      });
      h.owner = 'https://example.invalid/bob';
      h.writeGate!.complete();
      await auto;
      await disabling;
      await expectLater(manual, throwsStateError);
      expect(manualWrites, 0);
      h.owner = null;
      await expectLater(
        h.service.manualUpdate(1, 'marked', () async {
          manualWrites++;
        }),
        throwsStateError,
      );
      expect(manualWrites, 0);
    },
  );

  test(
    'another work completing cannot rewrite an already finished work',
    () async {
      final h = Harness();
      const other = AudioTrack(
        id: 'other',
        hash: 'other',
        title: 'Other',
        url: 'https://example.invalid/other',
        workId: 2,
      );
      await h.event(
        AutomaticMarkingEventType.completed,
        track: a,
        queue: [a, other],
      );
      h.online[1] = 'postponed';
      await h.event(
        AutomaticMarkingEventType.completed,
        track: other,
        queue: [a, other],
      );
      expect(h.online[1], 'postponed');
      expect(h.online[2], 'listened');
    },
  );

  test(
    'fresh metadata accepts other-device changes but ignores responses older than a local write',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      final snapshot = h.service.refreshSnapshot(1);
      h.service.refreshedProgress(1, 'postponed', snapshot: snapshot);
      expect(h.service.progressFor(1, 'postponed'), 'postponed');
      final oldSnapshot = h.service.refreshSnapshot(1);
      h.online[1] = 'listened';
      await h.event(AutomaticMarkingEventType.selected, track: a);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.service.progressFor(1, null), 'replay');
      h.service.refreshedProgress(1, 'postponed', snapshot: oldSnapshot);
      expect(h.service.progressFor(1, null), 'replay');
    },
  );

  test(
    'adding or failing to start another track does not revoke the manual override',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.replace, tracks: [a]);
      await h.event(AutomaticMarkingEventType.started, track: a);
      await h.service.manualUpdate(1, 'postponed', () async {
        h.online[1] = 'postponed';
      });
      await h.event(AutomaticMarkingEventType.added, tracks: [b]);
      await h.event(AutomaticMarkingEventType.removed, queue: [a]);
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      expect(h.online[1], 'postponed');
      await h.event(AutomaticMarkingEventType.selected, track: b);
      // A load failure emits no started event.
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      expect(h.online[1], 'postponed');
      await h.event(AutomaticMarkingEventType.started, track: b);
      expect(h.online[1], 'listening');
    },
  );

  test(
    'manual edits while disabled do not suppress new behavior after enabling',
    () async {
      final h = Harness();
      await h.service.setEnabled(false);
      await h.service.manualUpdate(1, 'marked', () async {
        h.online[1] = 'marked';
      });
      await h.service.setEnabled(true);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'listening');
    },
  );

  test(
    'new queue marks wanted, actual start listening, all completed listened',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.replace, tracks: [a, b]);
      expect(h.writes, ['marked']);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'listening');
      await h.event(AutomaticMarkingEventType.completed, track: a);
      expect(h.online[1], 'listening');
      await h.event(AutomaticMarkingEventType.started, track: b);
      await h.event(AutomaticMarkingEventType.completed, track: b);
      expect(h.online[1], 'listened');
      expect(h.synced, 3);
    },
  );

  test('adding never changes an existing mark including postponed', () async {
    for (final progress in [
      'marked',
      'listening',
      'listened',
      'replay',
      'postponed',
    ]) {
      final h = Harness()..online[1] = progress;
      await h.service.addedToPlaylist(1);
      await h.event(AutomaticMarkingEventType.added, tracks: [a]);
      expect(h.writes, isEmpty, reason: progress);
    }
  });

  test(
    'start changes postponed but automatic advancement keeps listened',
    () async {
      final h = Harness()..online[1] = 'postponed';
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'listening');
      h.online[1] = 'listened';
      await h.event(AutomaticMarkingEventType.started, track: b);
      expect(h.online[1], 'listened');
    },
  );

  test(
    'direct replay requires this account to have completed that hash',
    () async {
      final h = Harness()..online[1] = 'listened';
      await h.event(AutomaticMarkingEventType.selected, track: a);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'listening');
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      expect(h.online[1], 'listened');
      await h.event(AutomaticMarkingEventType.selected, track: a);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'replay');
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      expect(h.online[1], 'replay');
    },
  );

  test(
    'listening stays listening when explicitly replaying a finished track',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.completed, track: a);
      h.online[1] = 'listening';
      await h.event(AutomaticMarkingEventType.selected, track: a);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'listening');
    },
  );

  test(
    'user-added track counts as selected when reached automatically later',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      await h.event(AutomaticMarkingEventType.added, tracks: [a]);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'replay');
    },
  );

  test('loop and manual skip do not reselect consumed queue choices', () async {
    final h = Harness();
    await h.event(AutomaticMarkingEventType.replace, tracks: [a], queue: [a]);
    await h.event(AutomaticMarkingEventType.started, track: a, queue: [a]);
    await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
    await h.event(AutomaticMarkingEventType.started, track: a, queue: [a]);
    expect(h.online[1], 'listened');
    expect(h.writes, isNot(contains('replay')));
  });

  test(
    'removing unfinished items finishes the remaining work immediately',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.completed, track: a);
      expect(h.online[1], isNull);
      await h.event(AutomaticMarkingEventType.removed, queue: [a]);
      expect(h.online[1], 'listened');
    },
  );

  test('removing every item does not finish a work', () async {
    final h = Harness();
    await h.event(AutomaticMarkingEventType.removed, queue: []);
    expect(h.writes, isEmpty);
  });

  test(
    'restoring same queue retains completion; replacing resets it',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.completed, track: a);
      final restored = Harness(saved: h.persisted);
      await restored.event(AutomaticMarkingEventType.restore);
      await restored.event(AutomaticMarkingEventType.completed, track: b);
      expect(restored.online[1], 'listened');
      await restored.event(
        AutomaticMarkingEventType.replace,
        tracks: [a, b],
        queueId: 'queue-2',
      );
      restored.online[1] = 'listening';
      await restored.event(
        AutomaticMarkingEventType.completed,
        track: b,
        queueId: 'queue-2',
      );
      expect(restored.online[1], 'listening');
    },
  );

  test(
    'disabled interval records no completions and preserves previous queue completions',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.completed, track: a);
      await h.service.setEnabled(false);
      await h.event(AutomaticMarkingEventType.completed, track: b);
      await h.service.setEnabled(true);
      await h.event(AutomaticMarkingEventType.removed);
      expect(h.online[1], isNull);
      await h.event(AutomaticMarkingEventType.completed, track: b);
      expect(h.online[1], 'listened');
    },
  );

  test(
    'manual mark wins over an in-flight automatic write and suppresses the continuous playback',
    () async {
      final h = Harness();
      h.writeGate = Completer<void>();
      h.writeStarted = Completer<void>();
      final started = h.writeStarted!.future;
      final automatic = h.event(AutomaticMarkingEventType.started, track: a);
      await started;
      final manual = h.service.manualUpdate(1, 'postponed', () async {
        h.online[1] = 'postponed';
      });
      h.writeGate!.complete();
      await automatic;
      await manual;
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      await h.event(AutomaticMarkingEventType.started, track: b);
      expect(h.online[1], 'postponed');
      await h.event(AutomaticMarkingEventType.selected, track: b);
      await h.event(AutomaticMarkingEventType.started, track: b);
      expect(h.online[1], 'listening');
    },
  );

  test(
    'an earlier queue addition cannot revoke a later manual override on start',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.added, tracks: [a]);
      await h.service.manualUpdate(1, 'postponed', () async {
        h.online[1] = 'postponed';
      });
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'postponed');
    },
  );

  test(
    'failed writes persist optimistic state, then discard safely without another PUT',
    () async {
      final h = Harness();
      h.writeGate = Completer<void>();
      h.writeStarted = Completer<void>();
      final started = h.writeStarted!.future;
      final operation = h.event(AutomaticMarkingEventType.started, track: a);
      await started;
      h.offline = true;
      h.writeGate!.complete();
      await operation;
      expect(h.service.progressFor(1, null), 'listening');
      expect(h.synced, 0);
      final restarted = Harness(saved: h.persisted);
      expect(restarted.service.progressFor(1, null), 'listening');
      restarted.online[1] = 'postponed';
      await restarted.service.reconcilePending();
      expect(restarted.service.progressFor(1, null), 'postponed');
      expect(restarted.writes, isEmpty);
      expect(restarted.conflicts, 1);
      await restarted.service.reconcilePending();
      expect(restarted.conflicts, 1);
    },
  );

  test(
    'queued reconciliation preserves a newer live automatic marking intent',
    () async {
      final h = Harness();
      h.service.observeProgress(1, 'marked');
      h.service.observeProgress(2, null);
      h.writeGate = Completer<void>();
      h.writeStarted = Completer<void>();
      final firstWriteStarted = h.writeStarted!.future;
      final first = h.event(AutomaticMarkingEventType.started, track: a);
      await firstWriteStarted;

      final reconciliation = h.service.reconcilePending();
      const secondTrack = AudioTrack(
        id: 'c',
        hash: 'original-c',
        title: 'C',
        url: 'https://example.invalid/c',
        workId: 2,
      );
      final projected = Completer<void>();
      h.changed = () {
        if (h.service.progressFor(2, null) == 'listening' &&
            !projected.isCompleted) {
          projected.complete();
        }
      };
      final second = h.event(
        AutomaticMarkingEventType.started,
        track: secondTrack,
      );
      await projected.future;
      // This no-op waits for the second local projection to enqueue its write.
      await h.service.addedToPlaylist(2);

      h.writeGate!.complete();
      await Future.wait([first, reconciliation, second]);

      expect(h.online[1], 'listening');
      expect(h.online[2], 'listening');
      expect(h.writes, ['listening', 'listening']);
      expect(h.conflicts, 0);
    },
  );

  test(
    'reconciliation recovers pending work after switching away and back',
    () async {
      const alice = 'https://example.invalid/alice';
      final h = Harness();
      h.service.observeProgress(1, 'marked');
      h.service.observeProgress(2, null);
      h.writeGate = Completer<void>();
      h.writeStarted = Completer<void>();
      final firstWriteStarted = h.writeStarted!.future;
      final first = h.event(AutomaticMarkingEventType.started, track: a);
      await firstWriteStarted;

      const secondTrack = AudioTrack(
        id: 'c',
        hash: 'original-c',
        title: 'C',
        url: 'https://example.invalid/c',
        workId: 2,
      );
      final projected = Completer<void>();
      h.changed = () {
        if (h.service.progressFor(2, null) == 'listening' &&
            !projected.isCompleted) {
          projected.complete();
        }
      };
      final second = h.event(
        AutomaticMarkingEventType.started,
        track: secondTrack,
      );
      await projected.future;
      await h.service.addedToPlaylist(2);
      expect(
        ((h.persisted[alice] as Map<String, dynamic>)['pending']
            as Map<String, dynamic>)['2'],
        'listening',
      );

      h.owner = 'https://example.invalid/bob';
      h.writeGate!.complete();
      await Future.wait([first, second]);
      h.owner = alice;

      await h.service.reconcilePending();

      expect((h.persisted[alice] as Map<String, dynamic>)['pending'], isEmpty);
      expect(h.service.progressFor(1, null), 'listening');
      expect(h.service.progressFor(2, null), isNull);
      expect(h.conflicts, 1);
    },
  );

  test(
    'offline known progress is optimistic; missing baseline is never guessed',
    () async {
      final h = Harness()..offline = true;
      h.service.observeProgress(1, 'postponed');
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.service.progressFor(1, null), 'listening');
      expect(h.writes, isEmpty);
      final unknown = Harness()..offline = true;
      await unknown.event(AutomaticMarkingEventType.started, track: a);
      expect(unknown.service.progressFor(1, null), isNull);
      expect(unknown.writes, isEmpty);
    },
  );

  test(
    'new playback events recover after an offline read without cached progress',
    () async {
      final h = Harness()..offline = true;
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.writes, isEmpty);

      h.offline = false;
      await h.service.reconcilePending();
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);

      expect(h.writes, ['listened']);
      expect(h.online[1], 'listened');
      expect(h.errors, isEmpty);
    },
  );

  test(
    'accounts keep independent completion and pending state; anonymous events are not backfilled',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      h.owner = 'https://example.invalid/bob';
      h.online[1] = 'listened';
      await h.event(AutomaticMarkingEventType.selected, track: a);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'listening');
      h.owner = null;
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      h.owner = 'https://example.invalid/charlie';
      h.online[1] = 'listened';
      await h.event(AutomaticMarkingEventType.selected, track: a);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'listening');
    },
  );

  test(
    'download and online audio share original hash, unknown hashes count as unfinished',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      final downloaded = a.copyWith(
        id: 'download-a',
        url: 'file:///download/a',
      );
      await h.event(AutomaticMarkingEventType.selected, track: downloaded);
      await h.event(AutomaticMarkingEventType.started, track: downloaded);
      expect(h.online[1], 'replay');
      h.online[1] = 'listened';
      const unknown = AudioTrack(
        id: 'unknown',
        title: 'unknown',
        url: 'file:///unknown',
        workId: 1,
      );
      await h.event(AutomaticMarkingEventType.selected, track: unknown);
      await h.event(AutomaticMarkingEventType.started, track: unknown);
      expect(h.online[1], 'listening');
    },
  );

  test(
    'clearing completion only affects this account and leaves marks and queue done intact',
    () async {
      final h = Harness();
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      await h.service.clearCompletionHistory();
      expect(h.online[1], 'listened');
      await h.event(AutomaticMarkingEventType.selected, track: a);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'listening');
    },
  );

  test(
    'disabling removes pending updates for every account but keeps completed history',
    () async {
      final h = Harness()..offline = true;
      h.service.observeProgress(1, null);
      await h.event(AutomaticMarkingEventType.completed, track: a, queue: [a]);
      h.owner = 'https://example.invalid/bob';
      h.service.observeProgress(1, null);
      await h.event(AutomaticMarkingEventType.started, track: b);
      await h.service.setEnabled(false);
      for (final data in h.persisted.values.cast<Map<String, dynamic>>()) {
        expect(data['pending'], isEmpty);
      }
      h.owner = 'https://example.invalid/alice';
      h.offline = false;
      h.online[1] = 'listened';
      await h.service.setEnabled(true);
      await h.event(AutomaticMarkingEventType.selected, track: a);
      await h.event(AutomaticMarkingEventType.started, track: a);
      expect(h.online[1], 'replay');
    },
  );

  test('Japanese ASMR works do not produce review writes', () async {
    final h = Harness();
    const jp = AudioTrack(
      id: 'jp',
      hash: 'jp',
      title: 'JP',
      url: 'https://example.invalid/jp',
      workId: -1,
    );
    await h.event(AutomaticMarkingEventType.replace, tracks: [jp], queue: [jp]);
    await h.event(AutomaticMarkingEventType.started, track: jp, queue: [jp]);
    await h.event(AutomaticMarkingEventType.completed, track: jp, queue: [jp]);
    expect(h.writes, isEmpty);
  });
}

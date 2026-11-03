import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/automatic_marking_event.dart';

import 'automatic_work_marking_test.dart' as fixture;

void main() {
  test(
    'restoring a queue resumes its completed tracks before finishing',
    () async {
      final h = fixture.Harness();

      await h.event(
        AutomaticMarkingEventType.replace,
        tracks: [fixture.a, fixture.b],
        queue: [fixture.a, fixture.b],
        queueId: 'queue-a',
      );
      await h.event(
        AutomaticMarkingEventType.completed,
        track: fixture.a,
        queue: [fixture.a, fixture.b],
        queueId: 'queue-a',
      );
      await h.event(
        AutomaticMarkingEventType.replace,
        tracks: [fixture.b],
        queue: [fixture.b],
        queueId: 'queue-b',
      );
      await h.event(
        AutomaticMarkingEventType.restore,
        queue: [fixture.a, fixture.b],
        queueId: 'queue-a',
      );
      await h.event(
        AutomaticMarkingEventType.completed,
        track: fixture.b,
        queue: [fixture.a, fixture.b],
        queueId: 'queue-a',
      );

      expect(h.writes, contains('listened'));
      final data = h.persisted[h.owner] as Map<String, dynamic>;
      expect(data['done'], [fixture.a.id, fixture.b.id]);
      expect(
        (data['queueDone'] as Map<String, dynamic>).containsKey('queue-a'),
        isFalse,
      );
    },
  );

  test(
    'clearing then restoring the same queue preserves completion state',
    () async {
      final h = fixture.Harness();

      await h.event(
        AutomaticMarkingEventType.replace,
        tracks: [fixture.a, fixture.b],
        queue: [fixture.a, fixture.b],
        queueId: 'queue-a',
      );
      await h.event(
        AutomaticMarkingEventType.completed,
        track: fixture.a,
        queue: [fixture.a, fixture.b],
        queueId: 'queue-a',
      );
      await h.event(
        AutomaticMarkingEventType.replace,
        tracks: const [],
        queue: const [],
        queueId: 'queue-a',
      );
      await h.event(
        AutomaticMarkingEventType.restore,
        queue: [fixture.a, fixture.b],
        queueId: 'queue-a',
      );
      await h.event(
        AutomaticMarkingEventType.completed,
        track: fixture.b,
        queue: [fixture.a, fixture.b],
        queueId: 'queue-a',
      );

      expect(h.writes, contains('listened'));
      final data = h.persisted[h.owner] as Map<String, dynamic>;
      expect(data['done'], [fixture.a.id, fixture.b.id]);
    },
  );

  test('queue completion snapshots survive service recreation', () async {
    final h = fixture.Harness();
    await h.event(
      AutomaticMarkingEventType.replace,
      tracks: [fixture.a, fixture.b],
      queue: [fixture.a, fixture.b],
      queueId: 'queue-a',
    );
    await h.event(
      AutomaticMarkingEventType.completed,
      track: fixture.a,
      queue: [fixture.a, fixture.b],
      queueId: 'queue-a',
    );
    await h.event(
      AutomaticMarkingEventType.replace,
      tracks: [fixture.b],
      queue: [fixture.b],
      queueId: 'queue-b',
    );

    final restored = fixture.Harness(saved: h.persisted);
    await restored.event(
      AutomaticMarkingEventType.restore,
      queue: [fixture.a, fixture.b],
      queueId: 'queue-a',
    );
    await restored.event(
      AutomaticMarkingEventType.completed,
      track: fixture.b,
      queue: [fixture.a, fixture.b],
      queueId: 'queue-a',
    );

    expect(restored.writes, contains('listened'));
  });

  test('only the 20 most recently departed queues are retained', () async {
    final h = fixture.Harness();
    for (var index = 0; index <= 20; index++) {
      final queueId = 'queue-$index';
      await h.event(
        AutomaticMarkingEventType.replace,
        tracks: [fixture.a],
        queue: [fixture.a],
        queueId: queueId,
      );
      await h.event(
        AutomaticMarkingEventType.completed,
        track: fixture.a,
        queue: [fixture.a],
        queueId: queueId,
      );
    }
    await h.event(
      AutomaticMarkingEventType.replace,
      tracks: [fixture.b],
      queue: [fixture.b],
      queueId: 'queue-21',
    );
    await h.event(
      AutomaticMarkingEventType.completed,
      track: fixture.b,
      queue: [fixture.b],
      queueId: 'queue-21',
    );

    final data = h.persisted[h.owner] as Map<String, dynamic>;
    final queueDone = data['queueDone'] as Map<String, dynamic>;
    expect(
      queueDone.keys,
      orderedEquals([for (var index = 1; index <= 20; index++) 'queue-$index']),
    );
    expect(data['done'], [fixture.b.id]);

    await h.event(
      AutomaticMarkingEventType.restore,
      queue: [fixture.a],
      queueId: 'queue-1',
    );
    final restoredData = h.persisted[h.owner] as Map<String, dynamic>;
    final restoredQueueDone = restoredData['queueDone'] as Map<String, dynamic>;
    expect(restoredData['done'], [fixture.a.id]);
    expect(
      restoredQueueDone.keys,
      orderedEquals([
        for (var index = 2; index <= 20; index++) 'queue-$index',
        'queue-21',
      ]),
    );
  });

  test('queue completion snapshots stay within their account', () async {
    final h = fixture.Harness();
    await h.event(
      AutomaticMarkingEventType.replace,
      tracks: [fixture.a, fixture.b],
      queue: [fixture.a, fixture.b],
      queueId: 'queue-a',
    );
    await h.event(
      AutomaticMarkingEventType.completed,
      track: fixture.a,
      queue: [fixture.a, fixture.b],
      queueId: 'queue-a',
    );
    await h.event(
      AutomaticMarkingEventType.replace,
      tracks: [fixture.b],
      queue: [fixture.b],
      queueId: 'queue-b',
    );

    h.owner = 'https://example.invalid/bob';
    await h.event(
      AutomaticMarkingEventType.restore,
      queue: [fixture.a, fixture.b],
      queueId: 'queue-a',
    );
    await h.event(
      AutomaticMarkingEventType.completed,
      track: fixture.b,
      queue: [fixture.a, fixture.b],
      queueId: 'queue-a',
    );
    expect(h.writes, isNot(contains('listened')));
    final bobData = h.persisted[h.owner] as Map<String, dynamic>;
    final bobQueueDone = bobData['queueDone'];
    expect(bobQueueDone is Map && bobQueueDone.containsKey('queue-a'), isFalse);

    h.owner = 'https://example.invalid/alice';
    await h.event(
      AutomaticMarkingEventType.restore,
      queue: [fixture.a, fixture.b],
      queueId: 'queue-a',
    );
    await h.event(
      AutomaticMarkingEventType.completed,
      track: fixture.b,
      queue: [fixture.a, fixture.b],
      queueId: 'queue-a',
    );
    expect(h.writes, contains('listened'));
  });
}

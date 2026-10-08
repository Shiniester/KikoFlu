import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/image_prefetch_queue.dart';

void main() {
  test(
    'visible images finish before the whole current page is preloaded',
    () async {
      final started = <int>[];
      final pending = <int, Completer<void>>{};
      final queue = ImagePrefetchQueue<int>(
        keyOf: (item) => item,
        prepare: (item) {
          started.add(item);
          return (pending[item] = Completer<void>()).future;
        },
      );
      addTearDown(queue.dispose);
      queue.update(items: [0, 1, 2, 3, 4], visible: [2, 3], active: true);
      expect(started, [2, 3]);

      pending[2]!.complete();
      await Future<void>.value();
      expect(started, [2, 3]);
      pending[3]!.complete();
      await Future<void>.value();
      expect(started, [2, 3, 0]);
      for (final item in [0, 1, 4]) {
        expect(pending[item], isNotNull);
        pending[item]!.complete();
        await Future<void>.value();
      }
      expect(started, [2, 3, 0, 1, 4]);

      queue.update(items: [0, 1, 2, 3, 4], visible: [0, 1], active: true);
      expect(started, [2, 3, 0, 1, 4]);
    },
  );

  test(
    'scrolling prioritizes new visible images over queued background work',
    () async {
      final started = <int>[];
      final pending = <int, Completer<void>>{};
      final queue = ImagePrefetchQueue<int>(
        keyOf: (item) => item,
        prepare: (item) {
          started.add(item);
          return (pending[item] = Completer<void>()).future;
        },
      );
      addTearDown(queue.dispose);
      final items = [0, 1, 2, 3, 4, 5];
      queue.update(items: items, visible: [2], active: true);
      pending[2]!.complete();
      await Future<void>.value();
      expect(started, [2, 0]);

      queue.update(items: items, visible: [4, 5], active: true);
      expect(started, [2, 0, 4]);
      pending[4]!.complete();
      await Future<void>.value();
      expect(started, [2, 0, 4, 5]);
      pending[0]!.complete();
      await Future<void>.value();
      expect(started, [2, 0, 4, 5]);
      pending[5]!.complete();
      await Future<void>.value();
      expect(started, [2, 0, 4, 5, 1]);
      queue.dispose();
      pending[1]!.complete();
      await Future<void>.value();
      expect(started, [2, 0, 4, 5, 1]);
    },
  );

  test('switching pages drops the old page pending images', () async {
    final started = <int>[];
    final pending = <int, Completer<void>>{};
    final queue = ImagePrefetchQueue<int>(
      keyOf: (item) => item,
      prepare: (item) {
        started.add(item);
        return (pending[item] = Completer<void>()).future;
      },
    );
    addTearDown(queue.dispose);
    queue.update(items: [0, 1, 2], visible: [0], active: true);
    pending[0]!.complete();
    await Future<void>.value();
    expect(started, [0, 1]);
    queue.update(items: [10, 11], visible: [10], active: true);
    expect(started, [0, 1, 10]);
    pending[1]!.complete();
    await Future<void>.value();
    expect(started, [0, 1, 10]);
    pending[10]!.complete();
    await Future<void>.value();
    expect(started, [0, 1, 10, 11]);
    pending[11]!.complete();
    await Future<void>.value();
    expect(started, isNot(contains(2)));
  });

  test('inactive pages do not start pending work and can resume', () async {
    final started = <int>[];
    final pending = <int, Completer<void>>{};
    final queue = ImagePrefetchQueue<int>(
      keyOf: (item) => item,
      prepare: (item) {
        started.add(item);
        return (pending[item] = Completer<void>()).future;
      },
    );
    addTearDown(queue.dispose);
    queue.update(items: [0, 1], visible: [0], active: true);
    queue.update(items: [0, 1], visible: [0], active: false);
    pending[0]!.complete();
    await Future<void>.value();
    expect(started, [0]);
    queue.update(items: [0, 1], visible: [0], active: true);
    expect(started, [0, 1]);
    pending[1]!.complete();
    await Future<void>.value();
  });

  test('a failed visible image does not block the remaining page', () async {
    final started = <int>[];
    final pending = <int, Completer<void>>{};
    final queue = ImagePrefetchQueue<int>(
      keyOf: (item) => item,
      prepare: (item) {
        started.add(item);
        return (pending[item] = Completer<void>()).future;
      },
    );
    addTearDown(queue.dispose);
    queue.update(items: [0, 1], visible: [0], active: true);
    pending[0]!.completeError(StateError('image failed'));
    await Future<void>.value();
    expect(started, [0, 1]);
    pending[1]!.complete();
    await Future<void>.value();
  });

  test(
    'the active page keeps preloading when its images leave the viewport',
    () async {
      final started = <int>[];
      final pending = <int, Completer<void>>{};
      final queue = ImagePrefetchQueue<int>(
        keyOf: (item) => item,
        prepare: (item) {
          started.add(item);
          return (pending[item] = Completer<void>()).future;
        },
      );
      addTearDown(queue.dispose);
      queue.update(items: [0, 1, 2], visible: [0], active: true);
      pending[0]!.complete();
      await Future<void>.value();
      expect(started, [0, 1]);
      queue.update(items: [0, 1, 2], visible: [], active: true);
      pending[1]!.complete();
      await Future<void>.value();
      expect(started, [0, 1, 2]);
      pending[2]!.complete();
      await Future<void>.value();
    },
  );
}

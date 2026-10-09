import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/image_prefetch_queue.dart';

void main() {
  test(
    'upcoming streams retain nearest frames within budget and release on exit',
    () async {
      final image = await createTestImage(width: 2048, height: 2048);
      addTearDown(image.dispose);
      final queue = ImagePrefetchQueue<int>(
        keyOf: (item) => item,
        prepare: (_) async {},
      );
      addTearDown(queue.dispose);
      final items = List.generate(20, (index) => index);
      queue.update(
        items: items,
        visible: List.generate(8, (index) => index),
        active: true,
      );
      final streams = <int, ImageStream>{};
      for (final index in [10, 8, 9]) {
        final stream = ImageStream()
          ..setCompleter(
            OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: image.clone())),
            ),
          );
        streams[index] = stream;
        queue.retainImage(index, stream);
      }
      await Future<void>.delayed(Duration.zero);
      expect(streams[8]!.completer!.hasListeners, isTrue);
      expect(streams[9]!.completer!.hasListeners, isTrue);
      expect(
        streams[10]!.completer!.hasListeners,
        isFalse,
        reason:
            'Decoded frames over 32 MiB must release the furthest upcoming item.',
      );
      queue.update(
        items: items,
        visible: List.generate(8, (index) => index + 8),
        active: true,
      );
      expect(streams[8]!.completer!.hasListeners, isFalse);
      expect(streams[9]!.completer!.hasListeners, isFalse);
      queue.retainImage(8, streams[8]!);
      expect(streams[8]!.completer!.hasListeners, isFalse);

      final nextStream = ImageStream()
        ..setCompleter(
          OneFrameImageStreamCompleter(
            Future.value(ImageInfo(image: image.clone())),
          ),
        );
      queue.retainImage(16, nextStream);
      await Future<void>.delayed(Duration.zero);
      expect(nextStream.completer!.hasListeners, isTrue);
      queue.update(items: items, visible: [8], active: false);
      expect(nextStream.completer!.hasListeners, isFalse);
      queue.retainImage(16, nextStream);
      expect(nextStream.completer!.hasListeners, isFalse);
    },
  );

  test(
    'a slow background image leaves room for nearby images and scrolling',
    () async {
      final started = <int>[];
      final pending = <int, Completer<void>>{};
      var running = 0;
      var peak = 0;
      final queue = ImagePrefetchQueue<int>(
        keyOf: (item) => item,
        prepare: (item) async {
          started.add(item);
          running++;
          if (running > peak) peak = running;
          await (pending[item] = Completer<void>()).future;
          running--;
        },
      );
      addTearDown(queue.dispose);
      final items = List.generate(20, (index) => index);
      queue.update(items: items, visible: [0, 1], active: true);
      pending[0]!.complete();
      pending[1]!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(
        started,
        [0, 1, 2, 3],
        reason:
            'A slow first background picture must not serialize the remaining page.',
      );
      pending[3]!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1, 2, 3, 4]);
      queue.update(items: items, visible: [10, 11], active: true);
      expect(started, [0, 1, 2, 3, 4, 10, 11]);
      expect(
        peak,
        4,
        reason:
            'Background work must leave two slots for newly visible pictures.',
      );
      queue.dispose();
      for (final gate in pending.values) {
        if (!gate.isCompleted) gate.complete();
      }
      await Future<void>.delayed(Duration.zero);
    },
  );

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
      expect(
        started[2],
        4,
        reason:
            'The next pictures below the viewport must precede the page beginning.',
      );
      expect(started, [2, 3, 4, 0]);
      for (final item in [4, 0, 1]) {
        expect(pending[item], isNotNull);
        pending[item]!.complete();
        await Future<void>.value();
      }
      expect(started, [2, 3, 4, 0, 1]);

      queue.update(items: [0, 1, 2, 3, 4], visible: [0, 1], active: true);
      expect(started, [2, 3, 4, 0, 1, 2, 3]);
      queue.dispose();
      pending[2]!.complete();
      pending[3]!.complete();
      await Future<void>.value();
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
      expect(started, [2, 3, 4]);

      queue.update(items: items, visible: [4, 5], active: true);
      expect(started, [2, 3, 4, 5]);
      pending[4]!.complete();
      await Future<void>.value();
      expect(started, [2, 3, 4, 5]);
      pending[3]!.complete();
      await Future<void>.value();
      expect(started, [2, 3, 4, 5]);
      pending[5]!.complete();
      await Future<void>.value();
      expect(started, [2, 3, 4, 5, 0, 1]);
      queue.dispose();
      pending[0]!.complete();
      pending[1]!.complete();
      await Future<void>.value();
      expect(started, [2, 3, 4, 5, 0, 1]);
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
    queue.update(items: [0, 1, 2, 3], visible: [0], active: true);
    pending[0]!.complete();
    await Future<void>.value();
    expect(started, [0, 1, 2]);
    queue.update(items: [10, 11], visible: [10], active: true);
    expect(started, [0, 1, 2, 10]);
    pending[1]!.complete();
    await Future<void>.value();
    expect(started, [0, 1, 2, 10]);
    pending[10]!.complete();
    await Future<void>.value();
    expect(started, [0, 1, 2, 10, 11]);
    pending[11]!.complete();
    await Future<void>.value();
    expect(started, isNot(contains(3)));
    queue.dispose();
    pending[2]!.complete();
    await Future<void>.value();
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
      queue.update(items: [0, 1, 2, 3, 4], visible: [0], active: true);
      pending[0]!.complete();
      await Future<void>.value();
      expect(started, [0, 1, 2]);
      queue.update(items: [0, 1, 2, 3, 4], visible: [], active: true);
      pending[1]!.complete();
      await Future<void>.value();
      expect(started, [0, 1, 2, 3]);
      pending[2]!.complete();
      await Future<void>.value();
      expect(started, [0, 1, 2, 3, 4]);
      pending[3]!.complete();
      pending[4]!.complete();
      await Future<void>.value();
    },
  );
}

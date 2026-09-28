import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/work_cover_prefetch.dart';

void main() {
  testWidgets('production prefetch warms the displayed cover decode', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('cover-precache-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => directory.path,
    );
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final previousCache = CachedNetworkImageProvider.defaultCacheManager;
    CacheService.installImageCacheManager();
    final controller = WorkCoverPrefetchController();
    addTearDown(() async {
      controller.dispose();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      CachedNetworkImageProvider.defaultCacheManager = previousCache;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      await directory.delete(recursive: true);
    });
    const work = Work(id: 123456, title: 'Prefetched');
    const host = 'https://covers.invalid';
    await tester.runAsync(() async {
      await CacheService.imageCacheManager.putFile(
        work.getCoverImageUrl(host, token: ''),
        img.encodePng(img.Image(width: 400, height: 300)),
        key: 'work_cover_${work.id}',
        fileExtension: 'image',
      );
    });
    late BuildContext coverContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            coverContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.runAsync(() async {
      controller.prefetch(
        coverContext,
        const [work],
        host: host,
        token: '',
        crossAxisCount: 2,
      );
      await controller.whenIdle().timeout(const Duration(seconds: 10));
    });
    await tester.pump();
    final provider = createWorkCoverImageProvider(
      work: work,
      host: host,
      token: '',
      cacheWidth: resolveWorkCoverCacheWidth(coverContext, crossAxisCount: 2),
    );
    final key = await provider.obtainKey(
      createLocalImageConfiguration(coverContext),
    );
    expect(
      PaintingBinding.instance.imageCache.statusForKey(key).keepAlive,
      isTrue,
    );
  });

  group('calculateWorkCoverCacheWidth', () {
    test('matches a two-column portrait masonry card', () {
      expect(
        calculateWorkCoverCacheWidth(
          viewportWidth: 390,
          devicePixelRatio: 3,
          crossAxisCount: 2,
          horizontalPadding: 8,
          crossAxisSpacing: 8,
        ),
        549,
      );
    });

    test('matches a five-column landscape masonry card', () {
      expect(
        calculateWorkCoverCacheWidth(
          viewportWidth: 844,
          devicePixelRatio: 3,
          crossAxisCount: 5,
          horizontalPadding: 24,
          crossAxisSpacing: 24,
        ),
        420,
      );
    });

    test('uses the fixed 80dp cover width for list cards', () {
      expect(
        calculateWorkCoverCacheWidth(
          viewportWidth: 390,
          devicePixelRatio: 3,
          crossAxisCount: 1,
          horizontalPadding: 8,
          crossAxisSpacing: 8,
        ),
        240,
      );
    });

    test('uses the full cell width for a single-column grid card', () {
      expect(
        calculateWorkCoverCacheWidth(
          viewportWidth: 390,
          devicePixelRatio: 3,
          crossAxisCount: 1,
          horizontalPadding: 8,
          crossAxisSpacing: 8,
          isListCard: false,
        ),
        1024,
      );
    });
  });

  test('creates the same cached decode used by a work card', () {
    const work = Work(id: 123456, title: 'Work');
    final provider = createWorkCoverImageProvider(
      work: work,
      host: 'https://example.com',
      token: 'token',
      cacheWidth: 549,
      headers: const {},
    );

    expect(provider, isA<ResizeImage>());
    final resized = provider as ResizeImage;
    expect(resized.width, 549);
    expect(
      resized.imageProvider,
      const CachedNetworkImageProvider(
        'https://example.com/api/cover/123456?token=token',
        cacheKey: 'work_cover_123456',
      ),
    );
  });

  testWidgets('bounds concurrency, queue size, and duplicate work', (
    tester,
  ) async {
    final completions = <Completer<void>>[];
    var active = 0;
    var maxActive = 0;
    var starts = 0;
    final controller = WorkCoverPrefetchController(
      precache: (provider, context) {
        starts++;
        active++;
        maxActive = active > maxActive ? active : maxActive;
        final completion = Completer<void>();
        completions.add(completion);
        return completion.future.whenComplete(() => active--);
      },
    );
    addTearDown(controller.dispose);
    final works = List.generate(
      30,
      (index) => Work(id: index, title: 'Work $index'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            controller.prefetch(
              context,
              works,
              host: 'https://example.com',
              token: 'token',
              crossAxisCount: 2,
              headers: const {},
            );
            controller.prefetch(
              context,
              works.take(12),
              host: 'https://example.com',
              token: 'token',
              crossAxisCount: 2,
              headers: const {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();

    expect(starts, 2);
    expect(maxActive, 2);
    expect(controller.pendingCount, lessThanOrEqualTo(12));

    while (completions.any((completion) => !completion.isCompleted)) {
      completions
          .firstWhere((completion) => !completion.isCompleted)
          .complete();
      await tester.pump();
    }
    await controller.whenIdle();
    expect(starts, 12);
    expect(maxActive, 2);
  });

  testWidgets('cancels queued work when the page source changes', (
    tester,
  ) async {
    final first = Completer<void>();
    var starts = 0;
    final controller = WorkCoverPrefetchController(
      maxConcurrent: 1,
      precache: (provider, context) {
        starts++;
        return first.future;
      },
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            controller.prefetch(
              context,
              List.generate(5, (index) => Work(id: index, title: '$index')),
              host: 'https://old.example.com',
              token: 'token',
              crossAxisCount: 2,
              headers: const {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();
    expect(starts, 1);

    controller.cancelPending();
    first.complete();
    await tester.pump();
    await controller.whenIdle();

    expect(starts, 1);
    expect(controller.pendingCount, 0);
  });

  testWidgets('cancels an obsolete active cover transfer', (tester) async {
    var cancellations = 0;
    final controller = WorkCoverPrefetchController(
      maxConcurrent: 1,
      precacheOperation: (provider, context) {
        final completion = Completer<void>();
        return WorkCoverPrecacheOperation(
          future: completion.future,
          cancel: () {
            cancellations++;
            if (!completion.isCompleted) completion.complete();
          },
        );
      },
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            controller.prefetch(
              context,
              const [Work(id: 1, title: 'obsolete')],
              host: 'https://old.example.com',
              token: 'token',
              crossAxisCount: 2,
              headers: const {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();

    controller.cancelPending();
    await tester.pump();
    await controller.whenIdle();

    expect(cancellations, 1);
    expect(controller.activeCount, 0);
  });

  testWidgets('pausing cancels and requeues an active cover transfer', (
    tester,
  ) async {
    var starts = 0;
    var cancellations = 0;
    final completions = <Completer<void>>[];
    final controller = WorkCoverPrefetchController(
      maxConcurrent: 1,
      precacheOperation: (provider, context) {
        starts++;
        final completion = Completer<void>();
        completions.add(completion);
        return WorkCoverPrecacheOperation(
          future: completion.future,
          cancel: () {
            cancellations++;
            if (!completion.isCompleted) completion.complete();
          },
        );
      },
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            controller.prefetch(
              context,
              const [Work(id: 1, title: 'paused')],
              host: 'https://example.com',
              token: 'token',
              crossAxisCount: 2,
              headers: const {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();
    expect(starts, 1);

    controller.setPaused(true);
    await tester.pump();
    expect(cancellations, 1);
    expect(controller.activeCount, 0);
    expect(controller.pendingCount, 1);

    controller.setPaused(false);
    await tester.pump();
    expect(starts, 2);
    completions.last.complete();
    await tester.pump();
    await controller.whenIdle();

    expect(controller.activeCount, 0);
    expect(controller.pendingCount, 0);
  });
}

import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show BaseCacheManager, FileResponse;
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/providers/recommendation_provider.dart';
import 'package:kikoeru_flutter/src/services/downloaded_file_state_scanner.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/recommendation_section.dart';
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';
import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/screens/work_detail_screen.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/file_explorer_widget.dart';

class _Api extends KikoeruApiService {
  final metadata = Completer<Map<String, dynamic>>();
  final tracks = Completer<List<dynamic>>();
  @override
  Future<Map<String, dynamic>> getWork(
    int id, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) => metadata.future;
  @override
  Future<List<dynamic>> getWorkTracks(int id, {bool forceRefresh = false}) =>
      tracks.future;
}

class _Auth extends AuthNotifier {
  _Auth() : super(_Api()) {
    state = const AuthState(host: 'https://detail.invalid');
  }
}

class _EmptyAuth extends AuthNotifier {
  _EmptyAuth() : super(_Api()) {
    state = const AuthState();
  }
}

class _LateFile extends Fake implements File {
  int pathReads = 0;
  @override
  String get path {
    pathReads++;
    return '/not-decoded.png';
  }
}

class _Lease extends Fake implements RemoteAssetLease {
  final completed = Completer<File>();
  bool released = false;
  @override
  Future<File> get file => completed.future;
  @override
  Future<void> release() async {
    released = true;
  }
}

class _CoverCache extends Fake implements RemoteAssetImageCacheManager {
  final leases = <_Lease>[];
  _Lease get lease => leases.last;
  int requests = 0;
  @override
  RemoteAssetLease acquireFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool speculative = false,
    bool forceRevalidate = false,
  }) {
    requests++;
    leases.add(_Lease());
    return lease;
  }
}

class _Recommendations extends RecommendationNotifier {
  _Recommendations(super.ref, super.workId);
  int requests = 0;
  @override
  Future<void> loadRecommendations(Work work) async {
    requests++;
  }
}

class _NoImageCache extends Fake implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => const Stream.empty();
}

void main() {
  setUp(() {
    CachedNetworkImageProvider.defaultCacheManager = _NoImageCache();
    addTearDown(() {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
  });
  for (final transferFails in [false, true]) {
    testWidgets(
      'cancelled manual cover refresh never reports success ($transferFails)',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync('cover-refresh-');
        final cover = File('${directory.path}/cover.png')
          ..writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 8)));
        addTearDown(() => directory.deleteSync(recursive: true));
        SharedPreferences.setMockInitialValues({
          'custom_download_path': directory.path,
        });
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        final api = _Api();
        final cache = _CoverCache();
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith((ref) => _Auth()),
              kikoeruApiServiceProvider.overrideWithValue(api),
              currentTrackProvider.overrideWith((ref) => Stream.value(null)),
              workDetailCoverCacheProvider.overrideWithValue(cache),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              theme: AppTheme.lightTheme(
                null,
              ).copyWith(platform: TargetPlatform.iOS),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: const Scaffold(body: Text('Home')),
            ),
          ),
        );
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const WorkDetailScreen(work: Work(id: 99, title: 'Work')),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        cache.lease.completed.complete(cover);
        bool hdVisible() => tester
            .widgetList<Image>(find.byType(Image))
            .any(
              (image) =>
                  image.image is ResizeImage &&
                  (image.image as ResizeImage).imageProvider is FileImage,
            );
        for (var i = 0; i < 100 && !hdVisible(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(hdVisible(), isTrue);
        final refresh = tester
            .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
            .show();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(cache.requests, 2);
        final refreshLease = cache.lease;
        final gesture = await tester.startGesture(const Offset(1, 300));
        await gesture.moveBy(const Offset(30, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(100, 0));
        await tester.pump();
        expect(refreshLease.released, isTrue);
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(WorkDetailScreen), findsOneWidget);
        expect(cache.requests, 2);
        api.metadata.complete({'id': 99, 'title': 'Work'});
        api.tracks.complete([]);
        if (transferFails) {
          refreshLease.completed.completeError(
            const HttpException('Remote asset transfer cancelled'),
          );
        } else {
          refreshLease.completed.complete(cover);
        }
        await tester.pump();
        var refreshCompleted = false;
        unawaited(refresh.then((_) => refreshCompleted = true));
        for (var i = 0; i < 100 && !refreshCompleted; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(refreshCompleted, isTrue);
        await tester.pump();
        final l10n = S.of(tester.element(find.byType(WorkDetailScreen)));
        expect(find.text(l10n.refreshComplete), findsNothing);
        expect(find.byIcon(Icons.error_outline), findsWidgets);
        expect(hdVisible(), isTrue);
        await tester.pump(const Duration(milliseconds: 500));
        final retry = tester
            .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
            .show();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(cache.requests, 3);
        cache.lease.completed.complete(cover);
        var retryCompleted = false;
        unawaited(retry.then((_) => retryCompleted = true));
        for (var i = 0; i < 100 && !retryCompleted; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(retryCompleted, isTrue);
        expect(find.text(l10n.refreshComplete), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('interactive back cancels HD work and cancellation restarts it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final cache = _CoverCache();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _Auth()),
          kikoeruApiServiceProvider.overrideWithValue(_Api()),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          workDetailCoverCacheProvider.overrideWithValue(cache),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.lightTheme(
            null,
          ).copyWith(platform: TargetPlatform.iOS),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const WorkDetailScreen(work: Work(id: 99, title: 'Work')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(cache.requests, 1);
    final first = cache.lease;
    final gesture = await tester.startGesture(const Offset(1, 300));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(first.released, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byType(WorkDetailScreen), findsOneWidget);
    expect(cache.requests, 2);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(cache.lease.released, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'recommendations wait for the loaded file tree and its viewport',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'detail-recommendation-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => directory.path,
      );
      addTearDown(() async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        await directory.delete(recursive: true);
      });
      SharedPreferences.setMockInitialValues({
        'custom_download_path': directory.path,
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final api = _Api();
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith((ref) => _EmptyAuth()),
          kikoeruApiServiceProvider.overrideWithValue(api),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          recommendationProvider.overrideWith(
            (ref, id) => _Recommendations(ref, id),
          ),
          downloadedFileStateScannerProvider.overrideWithValue(
            DownloadedFileStateScanner(
              resolveDownloadedPath: (_, __) async => null,
              downloadRootPath: () async => directory.path,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: WorkDetailScreen(work: Work(id: 555, title: 'Work')),
          ),
        ),
      );
      await tester.pump();
      final recommendations =
          container.read(recommendationProvider(555).notifier)
              as _Recommendations;
      expect(recommendations.requests, 0);
      expect(
        find.byType(RecommendationSection, skipOffstage: false),
        findsNothing,
      );
      api.tracks.complete(
        List.generate(1000, (i) => {'type': 'text', 'title': 'file-$i.txt'}),
      );
      for (
        var i = 0;
        i < 100 &&
            find
                .byType(RecommendationSection, skipOffstage: false)
                .evaluate()
                .isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        find.byType(RecommendationSection, skipOffstage: false),
        findsOneWidget,
      );
      expect(recommendations.requests, 0);
      await tester.scrollUntilVisible(
        find.text('file-999.txt'),
        3000,
        maxScrolls: 60,
      );
      await tester.pump();
      expect(recommendations.requests, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final finishEntering in [false, true]) {
    testWidgets(
      'return cancels HD work while route remains mounted ($finishEntering)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        final cache = _CoverCache();
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith((ref) => _Auth()),
              kikoeruApiServiceProvider.overrideWithValue(_Api()),
              currentTrackProvider.overrideWith((ref) => Stream.value(null)),
              workDetailCoverCacheProvider.overrideWithValue(cache),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: const Scaffold(body: Text('Home')),
            ),
          ),
        );
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const WorkDetailScreen(work: Work(id: 99, title: 'Work')),
          ),
        );
        await tester.pump();
        await tester.pump(Duration(milliseconds: finishEntering ? 1000 : 50));
        await tester.pump();
        expect(cache.requests, finishEntering ? 1 : 0);
        navigator.currentState!.pop();
        await tester.pump();
        if (finishEntering) {
          expect(cache.lease.released, isTrue);
          final lateFile = _LateFile();
          cache.lease.completed.complete(lateFile);
          await tester.pump();
          expect(lateFile.pathReads, 0);
        }
        await tester.pumpAndSettle();
        expect(cache.requests, finishEntering ? 1 : 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('metadata completion leaves the page and explorer intact', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final api = _Api();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _EmptyAuth()),
          kikoeruApiServiceProvider.overrideWithValue(api),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: WorkDetailScreen(work: Work(id: 321, title: 'Initial title')),
        ),
      ),
    );
    await tester.pump();
    var pageBuilds = 0;
    var explorerBuilds = 0;
    debugOnRebuildDirtyWidget = (element, built) {
      if (element.widget is WorkDetailScreen) pageBuilds++;
      if (element.widget is FileExplorerWidget) explorerBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    api.metadata.complete({'id': 321, 'title': 'Updated title'});
    await tester.pump();
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains('Updated title'),
      ),
      findsWidgets,
    );
    expect(pageBuilds, 0);
    expect(explorerBuilds, 0);
    expect(
      tester
          .widget<FileExplorerWidget>(find.byType(FileExplorerWidget))
          .currentWork!()
          .title,
      'Updated title',
    );
    debugOnRebuildDirtyWidget = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('HD cover completion does not rebuild the file explorer', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('detail-update-');
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
    addTearDown(() async {
      debugOnRebuildDirtyWidget = null;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      CachedNetworkImageProvider.defaultCacheManager = previousCache;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      await directory.delete(recursive: true);
    });
    const work = Work(id: 123, title: 'Work');
    await tester.runAsync(() async {
      await CacheService.imageCacheManager.putFile(
        work.getCoverImageUrl('https://detail.invalid', token: ''),
        img.encodePng(img.Image(width: 2400, height: 1800)),
        key: 'work_cover_123',
        fileExtension: 'image',
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _Auth()),
          kikoeruApiServiceProvider.overrideWithValue(_Api()),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: WorkDetailScreen(work: work),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    var explorerBuilds = 0;
    debugOnRebuildDirtyWidget = (element, built) {
      if (element.widget is FileExplorerWidget) explorerBuilds++;
    };
    await tester.pump(const Duration(milliseconds: 400));
    bool hdVisible() => tester
        .widgetList<Image>(find.byType(Image))
        .any(
          (image) =>
              image.image is ResizeImage &&
              (image.image as ResizeImage).imageProvider is FileImage,
        );
    for (var i = 0; i < 100 && !hdVisible(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(hdVisible(), isTrue);
    final sizedImages = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .whereType<ResizeImage>()
        .toList();
    expect(sizedImages.length, 2);
    expect(sizedImages.every((p) => p.policy == ResizeImagePolicy.fit), isTrue);
    final hd = sizedImages.firstWhere((p) => p.imageProvider is FileImage);
    final media = MediaQuery.of(tester.element(find.byType(WorkDetailScreen)));
    expect(
      hd.width,
      lessThanOrEqualTo((media.size.width * media.devicePixelRatio).ceil()),
    );
    expect(hd.height, lessThanOrEqualTo((500 * media.devicePixelRatio).ceil()));
    final image = await tester.runAsync(() async {
      final completed = Completer<ImageInfo>();
      final stream = hd.resolve(ImageConfiguration.empty);
      late final ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        stream.removeListener(listener);
        completed.complete(info);
      });
      stream.addListener(listener);
      return completed.future;
    });
    expect(image!.image.width / image.image.height, closeTo(4 / 3, .01));
    expect(image.image.width, lessThanOrEqualTo(hd.width!));
    expect(image.image.height, lessThanOrEqualTo(hd.height!));
    image.dispose();
    expect(explorerBuilds, 0);
    debugOnRebuildDirtyWidget = null;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

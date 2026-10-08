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
import 'package:kikoeru_flutter/src/widgets/tab_page_motion.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_stats_section.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_title_header.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_progress_action_button.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_metadata_sections.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_extra_sections.dart';

class _Api extends KikoeruApiService {
  _Api({this.events});

  final List<String>? events;
  final metadata = Completer<Map<String, dynamic>>();
  final refreshedMetadata = Completer<Map<String, dynamic>>();
  final tracks = Completer<List<dynamic>>();
  int workRequests = 0;
  int forceWorkRequests = 0;
  int trackRequests = 0;
  @override
  Future<Map<String, dynamic>> getWork(
    int id, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) {
    events?.add('work');
    workRequests++;
    if (forceRefresh) {
      forceWorkRequests++;
      return refreshedMetadata.future;
    }
    return metadata.future;
  }

  @override
  Future<List<dynamic>> getWorkTracks(int id, {bool forceRefresh = false}) {
    events?.add('tracks');
    trackRequests++;
    return tracks.future;
  }
}

class _RefreshApi extends KikoeruApiService {
  final initialMetadata = Completer<Map<String, dynamic>>();
  final refreshedMetadata = Completer<Map<String, dynamic>>();
  final initialTracks = Completer<List<dynamic>>();
  final refreshedTracks = Completer<List<dynamic>>();
  int workRequests = 0;
  int forceWorkRequests = 0;
  int trackRequests = 0;

  @override
  Future<Map<String, dynamic>> getWork(
    int id, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) {
    workRequests++;
    if (forceRefresh) {
      forceWorkRequests++;
      return refreshedMetadata.future;
    }
    return initialMetadata.future;
  }

  @override
  Future<List<dynamic>> getWorkTracks(int id, {bool forceRefresh = false}) {
    trackRequests++;
    return forceRefresh ? refreshedTracks.future : initialTracks.future;
  }
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
  _CoverCache({this.events});

  final List<String>? events;
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
    events?.add('hd');
    requests++;
    leases.add(_Lease());
    return lease;
  }
}

class _Recommendations extends RecommendationNotifier {
  _Recommendations(super.ref, super.accessId);
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

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxFrames = 20,
}) async {
  for (var i = 0; i < maxFrames && !condition(); i++) {
    await tester.pump();
    await tester.pump(Duration.zero);
  }
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 4}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump();
    await tester.pump(Duration.zero);
  }
}

void main() {
  setUp(() {
    CachedNetworkImageProvider.defaultCacheManager = _NoImageCache();
    addTearDown(() {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
  });
  testWidgets('detail keeps the list cover until its entrance finishes', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('detail-cover-swap-');
    final hdFile = File('${directory.path}/cover.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 240, height: 180)));
    addTearDown(() async {
      debugOnRebuildDirtyWidget = null;
      await directory.delete(recursive: true);
    });
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final cache = _CoverCache();
    final initialCover = MemoryImage(
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
    );
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
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    final route = MaterialPageRoute<void>(
      builder: (_) => WorkDetailScreen(
        work: const Work(id: 99, title: 'Work'),
        initialCoverImageProvider: initialCover,
      ),
    );
    navigator.currentState!.push(route);
    ImageProvider displayedCover() => tester
        .widget<Image>(
          find
              .descendant(
                of: find.byType(WorkCoverFrame),
                matching: find.byType(Image),
              )
              .first,
        )
        .image;

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(route.animation!.status, AnimationStatus.forward);
    expect(displayedCover(), same(initialCover));
    var detailBuilds = 0;
    debugOnRebuildDirtyWidget = (element, built) {
      if (element.widget is WorkDetailScreen) detailBuilds++;
    };
    await tester.pump(
      route.transitionDuration - const Duration(milliseconds: 149),
    );
    expect(displayedCover(), same(initialCover));
    await tester.pump();
    expect(route.animation!.status, AnimationStatus.completed);
    expect(displayedCover(), same(initialCover));
    expect(detailBuilds, 0);
    await _pumpUntil(tester, () => cache.requests > 0);
    expect(cache.requests, 1);

    cache.lease.completed.complete(hdFile);
    bool hdVisible() =>
        displayedCover() is ResizeImage &&
        (displayedCover() as ResizeImage).imageProvider is FileImage;
    for (var i = 0; i < 100 && !hdVisible(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(hdVisible(), isTrue);
    expect(
      tester
          .widgetList<Image>(
            find.descendant(
              of: find.byType(WorkCoverFrame),
              matching: find.byType(Image),
            ),
          )
          .length,
      1,
    );
    expect(detailBuilds, 0);
    expect(tester.takeException(), isNull);
    await _pumpFrames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'cold detail cover waits for entrance and falls back after failure',
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
            theme: AppTheme.lightTheme(null),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );
      final route = MaterialPageRoute<void>(
        builder: (_) =>
            const WorkDetailScreen(work: Work(id: 99, title: 'Work')),
      );
      unawaited(navigator.currentState!.push(route));
      final coverImages = find.descendant(
        of: find.byType(WorkCoverFrame),
        matching: find.byType(Image),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(route.animation!.status, AnimationStatus.forward);
      expect(coverImages, findsNothing);
      expect(cache.requests, 0);
      await tester.pump(route.transitionDuration);
      await _pumpUntil(tester, () => cache.requests > 0);
      expect(cache.requests, 1);
      expect(coverImages, findsNothing);
      cache.lease.completed.completeError(
        const HttpException('HD unavailable'),
      );
      await _pumpUntil(tester, () => coverImages.evaluate().isNotEmpty);
      expect(coverImages, findsOneWidget);
      final provider = tester.widget<Image>(coverImages).image as ResizeImage;
      expect(provider.imageProvider, isA<CachedNetworkImageProvider>());
      expect(tester.takeException(), isNull);
      await _pumpFrames(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('initial cover falls back to detail image after HD failure', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final cache = _CoverCache();
    final initialCover = MemoryImage(
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
    );
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
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => WorkDetailScreen(
          work: const Work(id: 99, title: 'Work'),
          initialCoverImageProvider: initialCover,
        ),
      ),
    );
    ImageProvider displayedCover() => tester
        .widget<Image>(
          find
              .descendant(
                of: find.byType(WorkCoverFrame),
                matching: find.byType(Image),
              )
              .first,
        )
        .image;

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await _pumpUntil(tester, () => cache.requests > 0);
    expect(cache.requests, 1);
    expect(displayedCover(), same(initialCover));
    cache.lease.completed.completeError(const HttpException('HD unavailable'));
    for (var i = 0; i < 10 && identical(displayedCover(), initialCover); i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(displayedCover(), isA<ResizeImage>());
    expect(
      (displayedCover() as ResizeImage).imageProvider,
      isA<CachedNetworkImageProvider>(),
    );
    final coverImages = tester
        .widgetList<Image>(
          find.descendant(
            of: find.byType(WorkCoverFrame),
            matching: find.byType(Image),
          ),
        )
        .toList();
    expect(coverImages.where((image) => image.image is ResizeImage).length, 1);
    expect(
      coverImages.any((image) => identical(image.image, initialCover)),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await _pumpFrames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty host keeps the initial cover', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final initialCover = MemoryImage(
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _EmptyAuth()),
          kikoeruApiServiceProvider.overrideWithValue(_Api()),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => WorkDetailScreen(
          work: const Work(id: 99, title: 'Work'),
          initialCoverImageProvider: initialCover,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await _pumpFrames(tester);
    expect(
      tester
          .widget<Image>(
            find
                .descendant(
                  of: find.byType(WorkCoverFrame),
                  matching: find.byType(Image),
                )
                .first,
          )
          .image,
      same(initialCover),
    );
    expect(tester.takeException(), isNull);
    await _pumpFrames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
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
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        await _pumpUntil(tester, () => cache.requests > 0);
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
        await tester.pump(const Duration(milliseconds: 600));
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
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(WorkDetailScreen), findsOneWidget);
        expect(cache.requests, 2);
        api.metadata.complete({'id': 99, 'title': 'Work'});
        api.refreshedMetadata.complete({'id': 99, 'title': 'Work'});
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
        await tester.pump(const Duration(milliseconds: 600));
        final retry = tester
            .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
            .show();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
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
    final initialCover = MemoryImage(
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
    );
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
        builder: (_) => WorkDetailScreen(
          work: const Work(id: 99, title: 'Work'),
          initialCoverImageProvider: initialCover,
        ),
      ),
    );
    ImageProvider displayedCover() => tester
        .widget<Image>(
          find
              .descendant(
                of: find.byType(WorkCoverFrame),
                matching: find.byType(Image),
              )
              .first,
        )
        .image;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await _pumpUntil(tester, () => cache.requests > 0);
    expect(cache.requests, 1);
    expect(displayedCover(), same(initialCover));
    final first = cache.lease;
    final gesture = await tester.startGesture(const Offset(1, 300));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(first.released, isTrue);
    first.completed.completeError(
      const HttpException('cancelled preload completed late'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await _pumpUntil(tester, () => cache.requests > 1);
    expect(find.byType(WorkDetailScreen), findsOneWidget);
    expect(cache.requests, 2);
    expect(displayedCover(), same(initialCover));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(cache.lease.released, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'recommendations load after resource readiness before scrolling to them',
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
      _Recommendations? recommendations;
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith((ref) => _EmptyAuth()),
          kikoeruApiServiceProvider.overrideWithValue(api),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          recommendationProvider.overrideWith(
            (ref, id) => recommendations = _Recommendations(ref, id),
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
            home: WorkDetailScreen(
              work: Work(id: 555, title: 'Work', lang: 'JPN'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(recommendations, isNull);
      expect(
        find.byType(RecommendationSection, skipOffstage: false),
        findsNothing,
      );
      api.tracks.complete(
        List.generate(1000, (i) => {'type': 'audio', 'title': 'file-$i.wav'}),
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
      expect(recommendations!.requests, 1);
      await tester.scrollUntilVisible(
        find.text('file-999.wav'),
        3000,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
      await tester.pump();
      expect(recommendations!.requests, 1);
      api.metadata.complete({'id': 555, 'title': 'Work'});
      await _pumpFrames(tester);
      expect(
        tester
            .widget<RecommendationSection>(
              find.byType(RecommendationSection, skipOffstage: false),
            )
            .work
            .lang,
        'JPN',
      );
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
        if (finishEntering) {
          await _pumpUntil(tester, () => cache.requests > 0);
        }
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
    await _pumpUntil(
      tester,
      () => find
          .byType(FileExplorerWidget, skipOffstage: false)
          .evaluate()
          .isNotEmpty,
    );
    await _pumpUntil(tester, () => api.trackRequests > 0);
    await _pumpFrames(tester);
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
    await _pumpFrames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final failDownloadedFileScan in [false, true]) {
    testWidgets(
      'file tree completes while downloaded-file scan is pending or fails ($failDownloadedFileScan)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        final api = _Api();
        final pendingDownloadRoot = Completer<String>();
        var scanStarted = false;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith((ref) => _EmptyAuth()),
              kikoeruApiServiceProvider.overrideWithValue(api),
              currentTrackProvider.overrideWith((ref) => Stream.value(null)),
              downloadedFileStateScannerProvider.overrideWithValue(
                DownloadedFileStateScanner(
                  resolveDownloadedPath: (_, __) async => null,
                  downloadRootPath: () async {
                    scanStarted = true;
                    if (failDownloadedFileScan) {
                      throw StateError('download directory unavailable');
                    }
                    return pendingDownloadRoot.future;
                  },
                ),
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: WorkDetailScreen(work: Work(id: 657, title: 'Work')),
            ),
          ),
        );
        await _pumpUntil(tester, () => api.trackRequests > 0);
        expect(api.trackRequests, 1);
        api.tracks.complete([
          {'type': 'text', 'title': 'loaded-while-scan-pending.txt'},
        ]);
        for (
          var i = 0;
          i < 12 &&
              find.text('loaded-while-scan-pending.txt').evaluate().isEmpty;
          i++
        ) {
          await tester.pump();
          await tester.pump(Duration.zero);
        }

        expect(scanStarted, isTrue);
        await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
        await tester.pump();
        await tester.pump(tabPageDuration);
        expect(find.text('loaded-while-scan-pending.txt'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (!pendingDownloadRoot.isCompleted) pendingDownloadRoot.complete('');
        await _pumpFrames(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('pending downloaded scan follows the refreshed file tree', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final api = _RefreshApi();
    final firstScanStarted = Completer<void>();
    final firstScanGate = Completer<void>();
    final scannedHashes = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _EmptyAuth()),
          kikoeruApiServiceProvider.overrideWithValue(api),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          downloadedFileStateScannerProvider.overrideWithValue(
            DownloadedFileStateScanner(
              resolveDownloadedPath: (_, hash) async {
                if (hash == 'old-hash' && !firstScanStarted.isCompleted) {
                  firstScanStarted.complete();
                  await firstScanGate.future;
                }
                scannedHashes.add(hash);
                return null;
              },
              downloadRootPath: () async => '',
              fileExists: (_) async => false,
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: WorkDetailScreen(work: Work(id: 659, title: 'Work')),
        ),
      ),
    );
    await _pumpUntil(tester, () => api.trackRequests > 0);
    expect(api.trackRequests, 1);
    api.initialTracks.complete([
      {'type': 'audio', 'title': 'old-track.mp3', 'hash': 'old-hash'},
    ]);
    for (var i = 0; i < 12 && !firstScanStarted.isCompleted; i++) {
      await tester.pump();
      await tester.pump(Duration.zero);
    }
    expect(firstScanStarted.isCompleted, isTrue);

    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    for (var i = 0; i < 8 && api.forceWorkRequests == 0; i++) {
      await tester.pump();
    }
    expect(api.forceWorkRequests, 1);
    expect(api.trackRequests, 2);
    api.refreshedMetadata.complete({'id': 659, 'title': 'Fresh title'});
    api.refreshedTracks.complete([
      {'type': 'audio', 'title': 'new-track.mp3', 'hash': 'new-hash'},
    ]);
    var refreshCompleted = false;
    unawaited(refresh.then((_) => refreshCompleted = true));
    for (var i = 0; i < 12 && !refreshCompleted; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      await tester.pump(Duration.zero);
    }
    expect(refreshCompleted, isTrue);
    expect(find.text('new-track.mp3'), findsOneWidget);
    expect(find.text('old-track.mp3'), findsNothing);

    firstScanGate.complete();
    for (var i = 0; i < 12 && !scannedHashes.contains('new-hash'); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      await tester.pump(Duration.zero);
    }
    expect(scannedHashes, ['old-hash', 'new-hash']);
    api.initialMetadata.complete({'id': 659, 'title': 'Stale title'});
    await tester.pump();
    expect(
      tester.widget<WorkTitleHeader>(find.byType(WorkTitleHeader)).title,
      'Fresh title',
    );
    expect(tester.takeException(), isNull);
    await _pumpFrames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('offscreen metadata sections build as scrolling reaches them', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(390, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final api = _Api()..tracks.complete([]);
    final initialCover = MemoryImage(
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
    );
    final work = Work(
      id: 789,
      title: List.filled(220, 'metadata').join(' '),
      name: 'Lazy metadata circle',
      vas: const [Va(id: 'lazy-va', name: 'Lazy VA sentinel')],
      tags: const [Tag(id: 987654, name: 'Lazy tag sentinel')],
      otherLanguageEditions: const [
        OtherLanguageEdition(
          id: 790,
          lang: 'Japanese',
          title: 'Japanese edition',
          sourceId: 'RJ000790',
          isOriginal: false,
          sourceType: 'RJ',
        ),
      ],
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
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
              downloadRootPath: () async => '',
            ),
          ),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    final route = MaterialPageRoute<void>(
      builder: (_) =>
          WorkDetailScreen(work: work, initialCoverImageProvider: initialCover),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(route.animation!.status, AnimationStatus.forward);
    expect(
      tester
          .widgetList<Image>(
            find.descendant(
              of: find.byType(WorkCoverFrame),
              matching: find.byType(Image),
            ),
          )
          .any((image) => identical(image.image, initialCover)),
      isTrue,
    );
    await tester.pump(
      route.transitionDuration - const Duration(milliseconds: 149),
    );
    await tester.pump();
    expect(route.animation!.status, AnimationStatus.completed);
    final metadataSliver = tester.widget<SliverList>(
      find.byType(SliverList).first,
    );
    expect(
      (metadataSliver.delegate as SliverChildListDelegate).addSemanticIndexes,
      isFalse,
    );

    expect(find.text('Lazy VA sentinel'), findsNothing);
    expect(find.text('Lazy tag sentinel'), findsNothing);
    expect(find.text('「Japanese」'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Lazy VA sentinel'),
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    expect(find.text('Lazy VA sentinel'), findsOneWidget);
    expect(find.semantics.byLabel('Lazy VA sentinel'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Lazy tag sentinel'),
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    expect(find.text('Lazy tag sentinel'), findsOneWidget);
    expect(find.semantics.byLabel('Lazy tag sentinel'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('「Japanese」'),
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 30,
    );
    expect(find.text('「Japanese」'), findsOneWidget);
    expect(find.semantics.byLabel('「Japanese」'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  for (final failResponses in [false, true]) {
    testWidgets(
      'initial metadata and file tree publish after route entry ($failResponses)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        final events = <String>[];
        final api = _Api(events: events);
        final cache = _CoverCache(events: events);
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith((ref) => _Auth()),
              kikoeruApiServiceProvider.overrideWithValue(api),
              recommendationProvider.overrideWith(
                (ref, id) => _Recommendations(ref, id),
              ),
              currentTrackProvider.overrideWith((ref) => Stream.value(null)),
              workDetailCoverCacheProvider.overrideWithValue(cache),
              downloadedFileStateScannerProvider.overrideWithValue(
                DownloadedFileStateScanner(
                  resolveDownloadedPath: (_, __) async => null,
                  downloadRootPath: () async => '',
                ),
              ),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              theme: AppTheme.lightTheme(null),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: const Scaffold(body: Text('Home')),
            ),
          ),
        );
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => WorkDetailScreen(
              work: Work(
                id: 654,
                title: 'Initial title',
                progress: 'listening',
                userRating: 1,
                circleId: 1,
                name: 'Initial circle',
                vas: const [Va(id: 'initial-va', name: 'Initial VA')],
                tags: const [Tag(id: 987654, name: 'Initial tag')],
                release: failResponses ? '2026-09-30' : null,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(api.workRequests, 0);
        expect(api.trackRequests, 0);
        expect(cache.requests, 0);
        expect(events, isEmpty);
        expect(find.text('Initial circle'), findsOneWidget);
        expect(find.text('Initial VA'), findsOneWidget);
        expect(find.text('Initial tag'), findsOneWidget);
        if (failResponses) {
          expect(find.text('2026-09-30'), findsOneWidget);
        }
        final initialCircleElement = tester.element(
          find.text('Initial circle'),
        );
        expect(find.byType(FileExplorerWidget), findsNothing);
        expect(
          tester
              .widget<WorkTitleHeader>(
                find.byType(WorkTitleHeader, skipOffstage: false),
              )
              .title,
          'Initial title',
        );
        expect(
          tester
              .widget<WorkProgressActionButton>(
                find.byType(WorkProgressActionButton, skipOffstage: false),
              )
              .progress,
          'listening',
        );
        expect(
          tester
              .widget<WorkStatsSection>(
                find.byType(WorkStatsSection, skipOffstage: false),
              )
              .currentRating,
          1,
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(api.workRequests, 0);
        expect(api.trackRequests, 0);
        if (failResponses) {
          expect(tester.takeException(), isNull);
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(api.workRequests, 0);
        expect(api.trackRequests, 0);
        expect(cache.requests, 0);
        expect(
          tester.element(find.text('Initial circle')),
          same(initialCircleElement),
        );
        final l10n = S.of(tester.element(find.byType(WorkDetailScreen)));
        if (failResponses) {
          expect(
            find.text(l10n.loadFailedWithError('Exception: metadata failed')),
            findsNothing,
          );
          expect(
            find.text(l10n.loadFilesFailed('Exception: file tree failed')),
            findsNothing,
          );
        } else {
          expect(
            find.byWidgetPredicate(
              (w) =>
                  w is RichText &&
                  w.text.toPlainText().contains('Updated title'),
            ),
            findsNothing,
          );
          expect(find.text('loaded-file.txt'), findsNothing);
        }

        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await _pumpUntil(tester, () => api.trackRequests > 0);
        expect(api.workRequests, 1);
        expect(api.trackRequests, 1);
        await _pumpUntil(tester, () => cache.requests > 0);
        expect(cache.requests, 1);
        expect(events.indexOf('work'), greaterThanOrEqualTo(0));
        expect(events.indexOf('tracks'), greaterThanOrEqualTo(0));
        expect(events.indexOf('hd'), greaterThan(events.indexOf('work')));
        expect(events.indexOf('hd'), greaterThan(events.indexOf('tracks')));

        if (failResponses) {
          api.metadata.completeError(Exception('metadata failed'));
          api.tracks.completeError(Exception('file tree failed'));
        } else {
          api.metadata.complete({
            'id': 654,
            'title': 'Updated title',
            'release': '2026-10-02',
          });
          api.tracks.complete([
            {'type': 'text', 'title': 'loaded-file.txt'},
          ]);
        }
        await tester.pump();
        await tester.pump();
        expect(find.text('Initial circle'), findsOneWidget);
        expect(find.text('Initial VA'), findsOneWidget);
        expect(find.text('Initial tag'), findsOneWidget);
        expect(
          tester.element(find.text('Initial circle')),
          same(initialCircleElement),
        );
        expect(api.workRequests, 1);
        expect(api.trackRequests, 1);
        if (!failResponses) {
          expect(find.text('2026-10-02'), findsOneWidget);
        }
        if (failResponses) {
          expect(
            find.text(l10n.loadFailedWithError('Exception: metadata failed')),
            findsOneWidget,
          );
          expect(
            find.text(l10n.loadFilesFailed('Exception: file tree failed')),
            findsOneWidget,
          );
        } else {
          expect(
            find.byWidgetPredicate(
              (w) =>
                  w is RichText &&
                  w.text.toPlainText().contains('Updated title'),
            ),
            findsWidgets,
          );
          await tester.tap(
            find.byKey(const ValueKey('work-resource-files-tab')),
          );
          await tester.pump();
          await tester.pump(tabPageDuration);
          expect(find.text('loaded-file.txt'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('explicit empty metadata replaces known first-screen values', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final api = _Api()..tracks.complete([]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _EmptyAuth()),
          kikoeruApiServiceProvider.overrideWithValue(api),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          downloadedFileStateScannerProvider.overrideWithValue(
            DownloadedFileStateScanner(
              resolveDownloadedPath: (_, __) async => null,
              downloadRootPath: () async => '',
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const WorkDetailScreen(
            work: Work(
              id: 660,
              title: 'Known metadata',
              name: 'Known circle',
              vas: [Va(id: 'known-va', name: 'Known VA')],
              tags: [Tag(id: 987654, name: 'Known tag')],
              release: '2026-09-30',
            ),
          ),
        ),
      ),
    );
    expect(find.text('Known circle'), findsOneWidget);
    expect(find.text('Known VA'), findsOneWidget);
    expect(find.text('Known tag'), findsOneWidget);
    await _pumpUntil(tester, () => api.workRequests == 1);
    api.metadata.complete({
      'id': 660,
      'title': 'Known metadata',
      'name': null,
      'vas': [],
      'tags': [],
      'release': null,
    });
    await _pumpFrames(tester);
    expect(find.text('Known circle'), findsNothing);
    expect(find.text('Known VA'), findsNothing);
    expect(find.text('Known tag'), findsNothing);
    expect(
      tester
          .widget<WorkCreatorChipsSection>(find.byType(WorkCreatorChipsSection))
          .work
          .name,
      isNull,
    );
    expect(
      tester
          .widget<WorkReleaseDateSection>(find.byType(WorkReleaseDateSection))
          .release,
      isNull,
    );
    expect(api.workRequests, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('popping during entry starts no detail requests or HD preload', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final events = <String>[];
    final api = _Api(events: events);
    final cache = _CoverCache(events: events);
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
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );

    navigator.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const WorkDetailScreen(
          work: Work(id: 660, title: 'Leaves immediately'),
        ),
      ),
    );
    await tester.pump();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(api.workRequests, 0);
    expect(api.trackRequests, 0);
    expect(cache.requests, 0);
    expect(events, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('landscape reduced-motion details preserve stage order', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final events = <String>[];
    final api = _Api(events: events);
    final cache = _CoverCache(events: events);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _Auth()),
          kikoeruApiServiceProvider.overrideWithValue(api),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          workDetailCoverCacheProvider.overrideWithValue(cache),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const WorkDetailScreen(
            work: Work(id: 661, title: 'Reduced-motion landscape'),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => cache.requests > 0);

    final context = tester.element(find.byType(WorkDetailScreen));
    expect(MediaQuery.orientationOf(context), Orientation.landscape);
    expect(MediaQuery.disableAnimationsOf(context), isTrue);
    expect(api.workRequests, 1);
    expect(api.trackRequests, 1);
    expect(events.indexOf('hd'), greaterThan(events.indexOf('work')));
    expect(events.indexOf('hd'), greaterThan(events.indexOf('tracks')));
    expect(
      find.byType(FileExplorerWidget, skipOffstage: false),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _pumpFrames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('metadata and file-tree responses wait for a covering route', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final api = _Api();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _EmptyAuth()),
          kikoeruApiServiceProvider.overrideWithValue(api),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          downloadedFileStateScannerProvider.overrideWithValue(
            DownloadedFileStateScanner(
              resolveDownloadedPath: (_, __) async => null,
              downloadRootPath: () async => '',
            ),
          ),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    navigator.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            const WorkDetailScreen(work: Work(id: 658, title: 'Initial title')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 550));
    for (var i = 0; i < 4 && api.trackRequests == 0; i++) {
      await tester.pump();
    }
    expect(api.workRequests, 1);
    expect(api.trackRequests, 1);

    final detailContext = tester.element(find.byType(WorkDetailScreen));
    navigator.currentState!.push<void>(
      DialogRoute<void>(
        context: detailContext,
        builder: (_) => const AlertDialog(content: Text('Covering route')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    api.metadata.complete({'id': 658, 'title': 'Updated title'});
    api.tracks.complete([
      {'type': 'text', 'title': 'covered-file.txt'},
    ]);
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<WorkTitleHeader>(find.byType(WorkTitleHeader)).title,
      'Initial title',
    );
    expect(find.text('covered-file.txt'), findsNothing);

    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<WorkTitleHeader>(find.byType(WorkTitleHeader)).title,
      'Updated title',
    );
    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pump();
    await tester.pump(tabPageDuration);
    expect(find.text('covered-file.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final failInitialResponse in [false, true]) {
    testWidgets(
      'manual refresh supersedes gated initial metadata ($failInitialResponse)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        final api = _Api();
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith((ref) => _EmptyAuth()),
              kikoeruApiServiceProvider.overrideWithValue(api),
              currentTrackProvider.overrideWith((ref) => Stream.value(null)),
              downloadedFileStateScannerProvider.overrideWithValue(
                DownloadedFileStateScanner(
                  resolveDownloadedPath: (_, __) async => null,
                  downloadRootPath: () async => '',
                ),
              ),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              theme: AppTheme.lightTheme(null),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: const Scaffold(body: Text('Home')),
            ),
          ),
        );
        final route = MaterialPageRoute<void>(
          builder: (_) => const WorkDetailScreen(
            work: Work(
              id: 656,
              title: 'Initial title',
              progress: 'listening',
              userRating: 1,
            ),
          ),
        );
        navigator.currentState!.push(route);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 550));
        for (var i = 0; i < 3 && api.trackRequests == 0; i++) {
          await tester.pump();
        }
        expect(route.animation!.status, AnimationStatus.completed);
        expect(api.workRequests, 1);
        expect(api.trackRequests, 1);

        final refresh = tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
        for (var i = 0; i < 3 && api.forceWorkRequests == 0; i++) {
          await tester.pump();
        }
        expect(api.forceWorkRequests, 1);
        expect(api.trackRequests, 2);

        api.tracks.complete([]);
        api.refreshedMetadata.complete({
          'id': 656,
          'title': 'Fresh title',
          'progress': 'listened',
          'userRating': 5,
        });
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
        expect(
          tester.widget<WorkTitleHeader>(find.byType(WorkTitleHeader)).title,
          'Fresh title',
        );
        expect(
          tester
              .widget<WorkProgressActionButton>(
                find.byType(WorkProgressActionButton),
              )
              .progress,
          'listened',
        );
        expect(
          tester
              .widget<WorkStatsSection>(find.byType(WorkStatsSection))
              .currentRating,
          5,
        );
        expect(route.animation!.status, AnimationStatus.completed);

        if (failInitialResponse) {
          api.metadata.completeError(Exception('stale initial failure'));
        } else {
          api.metadata.complete({
            'id': 656,
            'title': 'Stale title',
            'progress': 'postponed',
            'userRating': 2,
          });
        }
        await tester.pump();
        await tester.pump();

        await tester.pumpAndSettle();
        expect(route.animation!.status, AnimationStatus.completed);
        final l10n = S.of(tester.element(find.byType(WorkDetailScreen)));
        expect(
          tester.widget<WorkTitleHeader>(find.byType(WorkTitleHeader)).title,
          'Fresh title',
        );
        expect(
          tester
              .widget<WorkProgressActionButton>(
                find.byType(WorkProgressActionButton),
              )
              .progress,
          'listened',
        );
        expect(
          tester
              .widget<WorkStatsSection>(find.byType(WorkStatsSection))
              .currentRating,
          5,
        );
        expect(
          find.text(
            l10n.loadFailedWithError('Exception: stale initial failure'),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('late initial responses are ignored after leaving the route', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final api = _Api();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _EmptyAuth()),
          kikoeruApiServiceProvider.overrideWithValue(api),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.lightTheme(null),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const WorkDetailScreen(work: Work(id: 655, title: 'Initial title')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 550));
    for (var i = 0; i < 3 && api.trackRequests == 0; i++) {
      await tester.pump();
    }
    expect(api.workRequests, 1);
    expect(api.trackRequests, 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    api.metadata.complete({'id': 655, 'title': 'Late title'});
    api.tracks.complete([
      {'type': 'text', 'title': 'late-file.txt'},
    ]);
    await tester.pump();
    expect(find.byType(WorkDetailScreen), findsNothing);
    expect(tester.takeException(), isNull);
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
    await tester.pump(const Duration(milliseconds: 600));
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
    expect(sizedImages.length, 1);
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

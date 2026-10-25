import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show BaseCacheManager, FileResponse;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/user.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/history_provider.dart';
import 'package:kikoeru_flutter/src/screens/history_screen.dart';
import 'package:kikoeru_flutter/src/services/history_database.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/playback_history_service.dart';
import 'package:kikoeru_flutter/src/services/playback_history_store.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/tab_page_motion.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Store implements PlaybackHistoryStore {
  @override
  Future<void> addOrUpdate(HistoryRecord record) async {}

  @override
  Future<HistoryRecord?> getByWorkId(int workId) async => null;
}

class _UpdateObserver extends ProviderObserver {
  int updates = 0;
  final List<HistoryState> states = [];

  void reset() {
    updates = 0;
    states.clear();
  }

  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    if (provider != historyProvider) return;
    updates++;
    states.add(newValue! as HistoryState);
  }
}

class _TestAuth extends AuthNotifier {
  _TestAuth() : super(KikoeruApiService()) {
    state = const AuthState(
      currentUser: User(name: 'listener'),
      host: '',
      isLoggedIn: true,
    );
  }

  @override
  Future<void> enterAnonymous({String? host}) async {}
}

class _HistoryTabs extends StatelessWidget {
  const _HistoryTabs({
    required this.mainPages,
    required this.mainTarget,
    required this.audioPages,
    required this.audioTarget,
  });

  final PageController mainPages;
  final ValueNotifier<int?> mainTarget;
  final PageController audioPages;
  final ValueNotifier<int?> audioTarget;

  @override
  Widget build(BuildContext context) => PageView(
    controller: mainPages,
    children: [
      LazyTabPage(
        index: 0,
        pages: mainPages,
        target: mainTarget,
        child: PageView(
          controller: audioPages,
          children: [
            LazyTabPage(
              index: 0,
              pages: audioPages,
              target: audioTarget,
              child: const SizedBox.expand(),
            ),
            LazyTabPage(
              index: 1,
              pages: audioPages,
              target: audioTarget,
              child: const HistoryScreen(),
            ),
          ],
        ),
      ),
      LazyTabPage(
        index: 1,
        pages: mainPages,
        target: mainTarget,
        child: const SizedBox.expand(),
      ),
    ],
  );
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

Future<void> _jumpToPage(
  WidgetTester tester,
  PageController pages,
  ValueNotifier<int?> target,
  int index,
) async {
  target.value = index;
  pages.jumpToPage(index);
  await tester.pump();
  target.value = null;
  await tester.pump();
}

Future<void> _pumpUntilUpdates(
  WidgetTester tester,
  _UpdateObserver observer,
  int target, {
  required String stage,
}) async {
  for (var attempt = 0; attempt < 20 && observer.updates < target; attempt++) {
    await tester.pump(const Duration(milliseconds: 1));
    if (observer.updates >= target) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(
    observer.updates,
    greaterThanOrEqualTo(target),
    reason:
        '$stage: expected at least $target history updates, got ${observer.updates}',
  );
}

Future<void> _expectDeferredRefresh(
  WidgetTester tester,
  _UpdateObserver observer,
  int previousUpdates,
  int oldRecordId,
  int recordId,
  Future<void> Function() showHistory,
) async {
  await showHistory();
  await tester.pump();
  await _pumpUntilUpdates(
    tester,
    observer,
    previousUpdates + 2,
    stage: 'history became visible',
  );
  expect(observer.updates, previousUpdates + 2);
  final refreshStates = observer.states.skip(previousUpdates).toList();
  expect(refreshStates, hasLength(2));
  expect(refreshStates.first.isLoading, isTrue);
  expect(refreshStates.first.records.map((record) => record.work.id), [
    oldRecordId,
  ]);
  expect(refreshStates.last.records.map((record) => record.work.id), [
    recordId,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory databaseDirectory;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    databaseDirectory = await Directory.systemTemp.createTemp(
      'history-visibility-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProvider,
          (_) async => databaseDirectory.path,
        );
  });

  tearDownAll(() async {
    await (await HistoryDatabase.instance.database).close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await databaseDirectory.delete(recursive: true);
  });

  test(
    'hidden addOrUpdate preserves the latest database playback progress',
    () async {
      var now = DateTime.utc(2026, 10, 25);
      final observer = _UpdateObserver();
      PlaybackHistoryService.resetForTest(store: _Store());
      final historyService = PlaybackHistoryService.instance;
      final container = ProviderContainer(
        observers: [observer],
        overrides: [
          historyProvider.overrideWith(
            (ref) => HistoryNotifier(ref, now: () => now),
          ),
        ],
      );

      try {
        await HistoryDatabase.instance.clear();
        await HistoryDatabase.instance.addOrUpdate(
          HistoryRecord(
            work: const Work(id: 901, title: 'History fixture'),
            lastPlayedTime: now,
            lastTrack: const AudioTrack(
              id: 'cached-track',
              title: 'Cached track',
              url: 'https://example.test/cached.mp3',
              workId: 901,
            ),
            lastPositionMs: 1000,
            playlistIndex: 2,
            playlistTotal: 8,
          ),
        );
        await container.read(historyProvider.notifier).refresh();
        expect(
          container.read(historyProvider).records.single.lastPositionMs,
          1000,
        );

        now = now.add(const Duration(seconds: 11));
        await HistoryDatabase.instance.addOrUpdate(
          HistoryRecord(
            work: const Work(id: 901, title: 'History fixture'),
            lastPlayedTime: now,
            lastTrack: const AudioTrack(
              id: 'latest-track',
              title: 'Latest track',
              url: 'https://example.test/latest.mp3',
              workId: 901,
            ),
            lastPositionMs: 9000,
            playlistIndex: 3,
            playlistTotal: 10,
          ),
        );
        observer.reset();
        await container
            .read(historyProvider.notifier)
            .addOrUpdate(const Work(id: 901, title: 'History fixture'));

        final persisted = await HistoryDatabase.instance.getHistoryByWorkId(
          901,
        );
        expect(persisted?.lastTrack?.id, 'latest-track');
        expect(persisted?.lastPositionMs, 9000);
        expect(persisted?.playlistIndex, 3);
        expect(persisted?.playlistTotal, 10);
        expect(observer.updates, 0);

        final notifier = container.read(historyProvider.notifier);
        await notifier.remove(901);
        expect(container.read(historyProvider).records, isEmpty);
        expect(container.read(historyProvider).totalCount, 0);

        observer.reset();
        await notifier.addOrUpdate(
          const Work(id: 902, title: 'Cleared while hidden'),
        );
        expect(observer.updates, 0);
        await notifier.clear();
        expect(container.read(historyProvider).records, isEmpty);
        expect(await HistoryDatabase.instance.getHistoryCount(), 0);
        observer.reset();
        notifier.setVisible(true);
        expect(observer.updates, 0);
      } finally {
        container.dispose();
        await historyService.dispose();
      }
    },
  );

  testWidgets(
    'history defers updates while audio, main, route, or app is hidden',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final previousImageCache = CachedNetworkImageProvider.defaultCacheManager;
      CachedNetworkImageProvider.defaultCacheManager = _NoImageCache();

      var now = DateTime.utc(2026, 10, 25);
      final observer = _UpdateObserver();
      final container = ProviderContainer(
        observers: [observer],
        overrides: [
          authProvider.overrideWith((ref) => _TestAuth()),
          historyProvider.overrideWith(
            (ref) => HistoryNotifier(ref, now: () => now),
          ),
        ],
      );
      final mainPages = PageController();
      final mainTarget = ValueNotifier<int?>(null);
      final audioPages = PageController(initialPage: 1);
      final audioTarget = ValueNotifier<int?>(null);
      final navigatorKey = GlobalKey<NavigatorState>();
      PlaybackHistoryService.resetForTest(store: _Store());
      final historyService = PlaybackHistoryService.instance;

      try {
        await tester.runAsync(() async {
          await HistoryDatabase.instance.clear();
          await HistoryDatabase.instance.addOrUpdate(
            HistoryRecord(
              work: const Work(id: 901, title: 'History fixture'),
              lastPlayedTime: now,
            ),
          );
        });
        historyService.setSessionForTest(
          workId: 901,
          work: const Work(id: 901, title: 'History fixture'),
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              navigatorKey: navigatorKey,
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: Scaffold(
                body: _HistoryTabs(
                  mainPages: mainPages,
                  mainTarget: mainTarget,
                  audioPages: audioPages,
                  audioTarget: audioTarget,
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => container.read(historyProvider.notifier).refresh(),
        );
        await tester.pump();
        expect(container.read(historyProvider).records, hasLength(1));
        observer.reset();

        await _jumpToPage(tester, audioPages, audioTarget, 0);
        now = now.add(const Duration(seconds: 11));
        await tester.runAsync(
          () => container
              .read(historyProvider.notifier)
              .addOrUpdate(
                const Work(id: 903, title: 'Played while history is hidden'),
              ),
        );
        expect(
          await tester.runAsync(
            () => HistoryDatabase.instance.getHistoryByWorkId(903),
          ),
          isNotNull,
        );
        expect(observer.updates, 0);
        await historyService.onSeekCommitted(const Duration(seconds: 5));
        await tester.pump();
        expect(observer.updates, 0);
        await tester.runAsync(() async {
          await HistoryDatabase.instance.clear();
          await HistoryDatabase.instance.addOrUpdate(
            HistoryRecord(
              work: const Work(id: 902, title: 'Updated history fixture'),
              lastPlayedTime: now,
            ),
          );
        });
        await _expectDeferredRefresh(
          tester,
          observer,
          0,
          901,
          902,
          () => _jumpToPage(tester, audioPages, audioTarget, 1),
        );
        observer.reset();

        await _jumpToPage(tester, mainPages, mainTarget, 1);
        now = now.add(const Duration(seconds: 11));
        await historyService.onSeekCommitted(const Duration(seconds: 10));
        await tester.pump();
        expect(observer.updates, 0);
        await _expectDeferredRefresh(
          tester,
          observer,
          0,
          902,
          902,
          () => _jumpToPage(tester, mainPages, mainTarget, 0),
        );
        observer.reset();

        final coveredRoute = navigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Cover route')),
          ),
        );
        await tester.pumpAndSettle();
        now = now.add(const Duration(seconds: 11));
        await historyService.onSeekCommitted(const Duration(seconds: 15));
        await tester.pump();
        expect(observer.updates, 0);
        await _expectDeferredRefresh(tester, observer, 0, 902, 902, () async {
          navigatorKey.currentState!.pop();
          await tester.pumpAndSettle();
          await coveredRoute;
        });
        observer.reset();

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        now = now.add(const Duration(seconds: 11));
        await historyService.onSeekCommitted(const Duration(seconds: 20));
        await tester.pump();
        expect(observer.updates, 0);
        await _expectDeferredRefresh(tester, observer, 0, 902, 902, () async {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
        });

        await tester.pumpWidget(const SizedBox.shrink());
        observer.reset();
        now = now.add(const Duration(seconds: 11));
        await tester.runAsync(
          () => container
              .read(historyProvider.notifier)
              .addOrUpdate(
                const Work(id: 904, title: 'Played after history unmounted'),
              ),
        );
        expect(
          await tester.runAsync(
            () => HistoryDatabase.instance.getHistoryByWorkId(904),
          ),
          isNotNull,
        );
        expect(observer.updates, 0);
        await historyService.onSeekCommitted(const Duration(seconds: 25));
        await tester.pump();
        expect(observer.updates, 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await historyService.dispose();
        CachedNetworkImageProvider.defaultCacheManager = previousImageCache;
        mainPages.dispose();
        mainTarget.dispose();
        audioPages.dispose();
        audioTarget.dispose();
      }
    },
  );
}

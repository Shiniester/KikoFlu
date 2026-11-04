import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show BaseCacheManager, FileResponse;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/user.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/collection_layout_provider.dart';
import 'package:kikoeru_flutter/src/providers/history_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart'
    show LayoutType;
import 'package:kikoeru_flutter/src/screens/history_screen.dart';
import 'package:kikoeru_flutter/src/services/history_database.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/playback_history_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/history_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/tab_page_motion.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _TestAuth extends AuthNotifier {
  _TestAuth() : super(KikoeruApiService()) {
    state = const AuthState(
      currentUser: User(name: 'history test'),
      host: '',
      isLoggedIn: true,
    );
  }

  @override
  Future<void> enterAnonymous({String? host}) async {}
}

class _ObservedHistoryNotifier extends HistoryNotifier {
  _ObservedHistoryNotifier(super.ref);

  bool isVisible = false;

  @override
  void setVisible(bool visible) {
    isVisible = visible;
    super.setVisible(visible);
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
              child: const Scaffold(
                body: Center(child: Text('Audio home fixture')),
              ),
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
        child: const Scaffold(
          body: Center(child: Text('Other app tab fixture')),
        ),
      ),
    ],
  );
}

class _HistoryHarness {
  const _HistoryHarness({
    required this.container,
    required this.history,
    required this.playbackHistoryService,
    required this.mainPages,
    required this.mainTarget,
    required this.audioPages,
    required this.audioTarget,
  });

  final ProviderContainer container;
  final _ObservedHistoryNotifier history;
  final PlaybackHistoryService playbackHistoryService;
  final PageController mainPages;
  final ValueNotifier<int?> mainTarget;
  final PageController audioPages;
  final ValueNotifier<int?> audioTarget;

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await playbackHistoryService.dispose();
    mainPages.dispose();
    mainTarget.dispose();
    audioPages.dispose();
    audioTarget.dispose();
  }
}

Future<_HistoryHarness> _pumpHistoryTabs(
  WidgetTester tester, {
  required int recordCount,
  LayoutType layout = LayoutType.list,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    AudioLayoutNotifier.preferenceKey: layout.name,
  });
  await StorageService.initCritical(
    preferences: await SharedPreferences.getInstance(),
  );

  final previousImageCache = CachedNetworkImageProvider.defaultCacheManager;
  CachedNetworkImageProvider.defaultCacheManager = _NoImageCache();
  addTearDown(() {
    CachedNetworkImageProvider.defaultCacheManager = previousImageCache;
  });

  final records = _historyFixture(recordCount);
  await tester.runAsync(() async {
    await HistoryDatabase.instance.clear();
    for (final record in records) {
      await HistoryDatabase.instance.addOrUpdate(record);
    }
  });

  PlaybackHistoryService.resetForTest();
  final playbackHistoryService = PlaybackHistoryService.instance;
  late _ObservedHistoryNotifier history;
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) => _TestAuth()),
      historyProvider.overrideWith((ref) {
        history = _ObservedHistoryNotifier(ref);
        return history;
      }),
    ],
  );
  final mainPages = PageController();
  final mainTarget = ValueNotifier<int?>(null);
  final audioPages = PageController(initialPage: 1);
  final audioTarget = ValueNotifier<int?>(null);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: _HistoryTabs(
          mainPages: mainPages,
          mainTarget: mainTarget,
          audioPages: audioPages,
          audioTarget: audioTarget,
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => container.read(historyProvider.notifier).refresh(),
  );
  await tester.pumpAndSettle();

  return _HistoryHarness(
    container: container,
    history: history,
    playbackHistoryService: playbackHistoryService,
    mainPages: mainPages,
    mainTarget: mainTarget,
    audioPages: audioPages,
    audioTarget: audioTarget,
  );
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

List<int> _pageIds(ProviderContainer container) => container
    .read(historyProvider)
    .records
    .map((record) => record.work.id)
    .toList();

Future<HistoryRecord> _persistPlaybackProgress(
  WidgetTester tester,
  _HistoryHarness harness, {
  required int workId,
  required int positionMs,
}) async {
  final current = await tester.runAsync(
    () => HistoryDatabase.instance.getHistoryByWorkId(workId),
  );
  final updated = current!.copyWith(
    lastPlayedTime: DateTime.now(),
    lastPositionMs: positionMs,
  );
  await tester.runAsync(() => HistoryDatabase.instance.addOrUpdate(updated));
  await tester.runAsync(
    () => harness.container
        .read(historyProvider.notifier)
        .addOrUpdate(updated.work),
  );
  return updated;
}

Future<void> _waitForHistoryState(
  _HistoryHarness harness,
  bool Function(HistoryState state) matches,
) async {
  if (matches(harness.container.read(historyProvider))) return;
  final completed = Completer<void>();
  final removeListener = harness.history.addListener((state) {
    if (!completed.isCompleted && matches(state)) completed.complete();
  });
  try {
    if (!matches(harness.container.read(historyProvider))) {
      await completed.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
          'History state did not reach the expected value within 5 seconds.',
          const Duration(seconds: 5),
        ),
      );
    }
  } finally {
    removeListener();
  }
}

List<HistoryRecord> _historyFixture(int count) {
  final now = DateTime.now();
  return List.generate(count, (index) {
    final id = index + 1;
    final work = Work(id: id, title: 'History work $id');
    return HistoryRecord(
      work: work,
      lastPlayedTime: now.subtract(Duration(minutes: id)),
      lastTrack: AudioTrack(
        id: 'track-$id',
        title: 'Track $id',
        url: 'https://example.invalid/$id.mp3',
        duration: const Duration(minutes: 1),
        workId: id,
      ),
      lastPositionMs: 1000,
    );
  });
}

List<int> _firstRowIds(WidgetTester tester, int count, int recordCount) {
  final positions = <(int, Offset)>[];
  for (var id = 1; id <= recordCount; id++) {
    final title = find.text('History work $id');
    if (title.evaluate().isEmpty) continue;
    positions.add((id, tester.getTopLeft(title)));
  }

  final firstTop = positions.map((entry) => entry.$2.dy).reduce(math.min);
  final row =
      positions.where((entry) => (entry.$2.dy - firstTop).abs() < 1).toList()
        ..sort((left, right) => left.$2.dx.compareTo(right.$2.dx));
  return row.take(count).map((entry) => entry.$1).toList();
}

double _progressValue(WidgetTester tester, int workId) {
  final card = find.byWidgetPredicate(
    (widget) => widget is HistoryWorkCard && widget.record.work.id == workId,
  );
  final progress = find.descendant(
    of: card,
    matching: find.byType(LinearProgressIndicator),
  );
  return tester.widget<LinearProgressIndicator>(progress).value!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory databaseDirectory;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    databaseDirectory = await Directory.systemTemp.createTemp(
      'audio-history-browsing-',
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

  for (final layout in [LayoutType.bigGrid, LayoutType.smallGrid]) {
    testWidgets(
      'history visit keeps first-row order and progress after local playback update ($layout)',
      (tester) async {
        final recordCount = layout == LayoutType.bigGrid ? 4 : 5;
        final harness = await _pumpHistoryTabs(
          tester,
          recordCount: recordCount,
          layout: layout,
        );
        try {
          expect(harness.history.isVisible, isTrue);
          expect(harness.container.read(audioLayoutProvider), layout);
          final columns = layout == LayoutType.bigGrid ? 2 : 3;
          final initialRow = _firstRowIds(tester, columns, recordCount);
          expect(initialRow, List.generate(columns, (index) => index + 1));
          final initialProgress = _progressValue(tester, 2);
          expect(initialProgress, closeTo(1000 / 60000, 0.0001));

          await _persistPlaybackProgress(
            tester,
            harness,
            workId: 2,
            positionMs: 9000,
          );
          expect(
            (await tester.runAsync(
              () => HistoryDatabase.instance.getHistoryByWorkId(2),
            ))?.lastPositionMs,
            9000,
          );
          await tester.pumpAndSettle();

          final updatedRow = _firstRowIds(tester, columns, recordCount);
          expect(
            updatedRow,
            hasLength(columns),
            reason:
                'The visible first row must not contain an empty grid slot.',
          );
          expect(
            updatedRow,
            initialRow,
            reason: 'Playback must not reorder history during this visit.',
          );
          expect(
            _progressValue(tester, 2),
            closeTo(initialProgress, 0.0001),
            reason:
                'Playback progress is saved locally but stays visually frozen during this visit.',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await harness.dispose(tester);
        }
      },
    );
  }

  testWidgets(
    'history keeps page order and progress stable while visiting two pages',
    (tester) async {
      final harness = await _pumpHistoryTabs(
        tester,
        recordCount: 25,
        layout: LayoutType.list,
      );
      try {
        final firstPage = List.generate(20, (index) => index + 1);
        final secondPage = List.generate(5, (index) => index + 21);
        expect(_pageIds(harness.container), firstPage);

        await tester.runAsync(
          () => harness.container.read(historyProvider.notifier).goToPage(2),
        );
        await tester.pumpAndSettle();
        expect(_pageIds(harness.container), secondPage);
        expect(find.text('History work 21'), findsOneWidget);
        final initialProgress = _progressValue(tester, 23);

        final updated = await _persistPlaybackProgress(
          tester,
          harness,
          workId: 23,
          positionMs: 9000,
        );
        expect(
          (await tester.runAsync(
            () => HistoryDatabase.instance.getHistoryByWorkId(23),
          ))?.lastPositionMs,
          9000,
        );
        await tester.pumpAndSettle();
        expect(
          _pageIds(harness.container),
          secondPage,
          reason:
              'Playback must not replace the current page during this visit.',
        );
        expect(
          _progressValue(tester, 23),
          closeTo(initialProgress, 0.0001),
          reason:
              'Saved progress must remain visually frozen during this visit.',
        );

        await tester.runAsync(
          () => harness.container.read(historyProvider.notifier).goToPage(1),
        );
        await tester.pumpAndSettle();
        final returnedFirstPage = _pageIds(harness.container);
        expect(returnedFirstPage, firstPage);
        await tester.runAsync(
          () => harness.container.read(historyProvider.notifier).goToPage(2),
        );
        await tester.pumpAndSettle();
        final returnedSecondPage = _pageIds(harness.container);
        expect(returnedSecondPage, secondPage);
        expect(
          [...returnedFirstPage, ...returnedSecondPage],
          List.generate(25, (index) => index + 1),
          reason: 'Paging must not duplicate or skip a work during this visit.',
        );
        expect(_progressValue(tester, 23), closeTo(initialProgress, 0.0001));
        expect(updated.lastPositionMs, 9000);
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  for (final destination in ['Audio page', 'main tab']) {
    testWidgets('history refreshes after leaving for another $destination', (
      tester,
    ) async {
      final harness = await _pumpHistoryTabs(tester, recordCount: 6);
      try {
        expect(harness.history.isVisible, isTrue);
        if (destination == 'Audio page') {
          await _jumpToPage(tester, harness.audioPages, harness.audioTarget, 0);
          expect(find.text('Audio home fixture'), findsOneWidget);
        } else {
          await _jumpToPage(tester, harness.mainPages, harness.mainTarget, 1);
          expect(find.text('Other app tab fixture'), findsOneWidget);
        }

        await _persistPlaybackProgress(
          tester,
          harness,
          workId: 2,
          positionMs: 9000,
        );
        if (destination == 'Audio page') {
          await _jumpToPage(tester, harness.audioPages, harness.audioTarget, 1);
        } else {
          await _jumpToPage(tester, harness.mainPages, harness.mainTarget, 0);
        }
        await tester.runAsync(
          () => _waitForHistoryState(
            harness,
            (state) =>
                !state.isLoading &&
                state.records.first.work.id == 2 &&
                state.records.first.lastPositionMs == 9000,
          ),
        );
        await tester.pumpAndSettle();

        expect(_pageIds(harness.container).first, 2);
        expect(_progressValue(tester, 2), closeTo(9000 / 60000, 0.0001));
        expect(find.text('History work 2'), findsOneWidget);
      } finally {
        await harness.dispose(tester);
      }
    });
  }
}

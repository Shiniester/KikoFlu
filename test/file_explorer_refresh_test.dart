import 'dart:async';
import 'dart:io';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/downloaded_file_state_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/widgets/file_explorer_widget.dart';
import 'package:kikoeru_flutter/src/widgets/offline_file_explorer_widget.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _FailingApiService extends KikoeruApiService {
  final List<bool> forceRefreshCalls = [];

  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async {
    forceRefreshCalls.add(forceRefresh);
    throw StateError('network unavailable');
  }
}

class _TreeApi extends KikoeruApiService {
  int calls = 0;
  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async => [
    {'type': 'audio', 'title': 'track.mp3', 'hash': 'hash-${calls++}'},
  ];
}

class _DeferredTreeApi extends KikoeruApiService {
  final tracks = Completer<List<dynamic>>();

  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) => tracks.future;
}

class _EmptyTreeApi extends KikoeruApiService {
  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async => [];
}

class _PreferredTreeApi extends KikoeruApiService {
  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async => _preferredAudioTree();
}

List<dynamic> _preferredAudioTree() => [
  {'type': 'audio', 'title': 'root.mp3', 'hash': 'root'},
  {
    'type': 'folder',
    'title': 'Preferred',
    'children': [
      {'type': 'audio', 'title': 'preferred.wav', 'hash': 'preferred'},
      {'type': 'audio', 'title': 'same-folder.mp3', 'hash': 'same-folder'},
    ],
  },
  {
    'type': 'folder',
    'title': 'Outer',
    'children': [
      {
        'type': 'folder',
        'title': 'Inner',
        'children': [
          {'type': 'audio', 'title': 'nested.wav', 'hash': 'nested'},
        ],
      },
    ],
  },
  {
    'type': 'folder',
    'title': 'Crowded',
    'children': [
      {'type': 'audio', 'title': 'crowded-1.mp3', 'hash': 'crowded-1'},
      {'type': 'audio', 'title': 'crowded-2.mp3', 'hash': 'crowded-2'},
      {'type': 'audio', 'title': 'crowded-3.mp3', 'hash': 'crowded-3'},
    ],
  },
  {
    'type': 'folder',
    'title': 'Manual',
    'children': [
      {'type': 'audio', 'title': 'manual.flac', 'hash': 'manual'},
    ],
  },
];

class _Downloads extends Fake implements DownloadTaskRepository {
  final changes = StreamController<DownloadTaskChange>.broadcast();
  @override
  Stream<DownloadTaskChange> get taskChangesStream => changes.stream;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('download bursts coalesce scans and refresh replaces path data', (
    tester,
  ) async {
    final downloads = _Downloads();
    addTearDown(downloads.changes.close);
    final controller = FileExplorerController();
    final first = Completer<String?>();
    var resolves = 0;
    final hashes = <String>[];
    var scans = 0;
    final scanner = DownloadedFileStateScanner(
      downloadRootPath: () async {
        scans++;
        return '/downloads';
      },
      resolveDownloadedPath: (_, hash) {
        hashes.add(hash);
        resolves++;
        return resolves == 1 ? first.future : Future.value('/downloads/$hash');
      },
      fileExists: (_) async => false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          kikoeruApiServiceProvider.overrideWithValue(_TreeApi()),
          downloadServiceProvider.overrideWithValue(downloads),
          downloadedFileStateScannerProvider.overrideWithValue(scanner),
        ],
        child: MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                FileExplorerWidget(
                  work: const Work(id: 39, title: 'Work'),
                  controller: controller,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(scans, 1);
    for (var i = 0; i < 20; i++) {
      downloads.changes.add(const DownloadTaskChange.reset([]));
    }
    await tester.pump();
    expect(scans, 1);
    first.complete(null);
    await tester.pump();
    await tester.pump();
    expect(scans, 2);
    expect(find.byIcon(Icons.download_done), findsOneWidget);
    await controller.refresh(forceRefresh: true);
    await tester.pump();
    expect(scans, 3);
    expect(resolves, 3);
    expect(hashes, ['hash-0', 'hash-0', 'hash-1']);
    expect(find.byIcon(Icons.download_done), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    downloads.changes.add(const DownloadTaskChange.reset([]));
    await tester.pump();
    expect(scans, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('controller reloads mounted file tree with cache bypass', (
    tester,
  ) async {
    final apiService = _FailingApiService();
    final controller = FileExplorerController();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [kikoeruApiServiceProvider.overrideWithValue(apiService)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                FileExplorerWidget(
                  work: const Work(id: 39, title: 'Work'),
                  controller: controller,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(apiService.forceRefreshCalls, [false]);

    await expectLater(
      controller.refresh(forceRefresh: true),
      throwsA(isA<StateError>()),
    );
    await tester.pump();

    expect(apiService.forceRefreshCalls, [false, true]);
  });

  testWidgets('initial content readiness follows prepared audio resources', (
    tester,
  ) async {
    final apiService = _DeferredTreeApi();
    final downloads = _Downloads();
    addTearDown(downloads.changes.close);
    final loaded = Completer<void>();
    var initialContentReady = false;
    final scanner = DownloadedFileStateScanner(
      downloadRootPath: () async => '/downloads',
      resolveDownloadedPath: (_, __) async => null,
      fileExists: (_) async => false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          kikoeruApiServiceProvider.overrideWithValue(apiService),
          downloadServiceProvider.overrideWithValue(downloads),
          downloadedFileStateScannerProvider.overrideWithValue(scanner),
        ],
        child: MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                FileExplorerWidget(
                  work: const Work(id: 39, title: 'Work'),
                  onLoadCompleted: () {
                    if (!loaded.isCompleted) loaded.complete();
                  },
                  onInitialContentReady: () => initialContentReady = true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(initialContentReady, isFalse);

    apiService.tracks.complete(_preferredAudioTree());
    await tester.runAsync(() => loaded.future);
    expect(initialContentReady, isFalse);

    await tester.pump();
    expect(initialContentReady, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('initial content readiness releases for empty and failed trees', (
    tester,
  ) async {
    final downloads = _Downloads();
    addTearDown(downloads.changes.close);
    final scanner = DownloadedFileStateScanner(
      downloadRootPath: () async => '/downloads',
      resolveDownloadedPath: (_, __) async => null,
      fileExists: (_) async => false,
    );
    var readyCalls = 0;
    var errorWasVisibleAtReady = false;
    var loaded = Completer<void>();

    Future<void> pumpExplorer(KikoeruApiService apiService) async {
      loaded = Completer<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            kikoeruApiServiceProvider.overrideWithValue(apiService),
            downloadServiceProvider.overrideWithValue(downloads),
            downloadedFileStateScannerProvider.overrideWithValue(scanner),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  FileExplorerWidget(
                    work: const Work(id: 39, title: 'Work'),
                    onLoadCompleted: () {
                      if (!loaded.isCompleted) loaded.complete();
                    },
                    onInitialContentReady: () {
                      readyCalls++;
                      errorWasVisibleAtReady = find
                          .textContaining('network unavailable')
                          .evaluate()
                          .isNotEmpty;
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    await pumpExplorer(_EmptyTreeApi());
    await tester.runAsync(() => loaded.future);
    await tester.pump();
    expect(readyCalls, 1);
    expect(errorWasVisibleAtReady, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    readyCalls = 0;
    await pumpExplorer(_FailingApiService());
    await tester.runAsync(() => loaded.future);
    await tester.pump();
    expect(readyCalls, 1);
    expect(errorWasVisibleAtReady, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'preferred audio folders update without overriding manual state',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'audio_format_preference': [
          'wav',
          'mp3',
          'flac',
          'opus',
          'm4a',
          'aac',
          'other',
        ],
      });
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final downloads = _Downloads();
      addTearDown(downloads.changes.close);
      final loadCompleted = Completer<void>();
      final scanner = DownloadedFileStateScanner(
        downloadRootPath: () async => '/downloads',
        resolveDownloadedPath: (_, __) async => null,
        fileExists: (_) async => false,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            kikoeruApiServiceProvider.overrideWithValue(_PreferredTreeApi()),
            downloadServiceProvider.overrideWithValue(downloads),
            downloadedFileStateScannerProvider.overrideWithValue(scanner),
          ],
          child: MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  FileExplorerWidget(
                    work: const Work(id: 39, title: 'Work'),
                    onLoadCompleted: () {
                      if (!loadCompleted.isCompleted) loadCompleted.complete();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => loadCompleted.future);
      await tester.pump();

      expect(find.text('preferred.wav'), findsOneWidget);
      expect(find.text('nested.wav'), findsOneWidget);
      expect(find.text('crowded-1.mp3'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preferred'));
      await tester.pump();
      await tester.tap(find.text('Manual'));
      await tester.pump();
      expect(find.text('preferred.wav'), findsNothing);
      expect(find.text('manual.flac'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
      await tester.pumpAndSettle();
      expect(find.text('preferred.wav'), findsNothing);
      expect(find.text('manual.flac'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(FileExplorerWidget)),
      );
      await container
          .read(audioFormatPreferenceProvider.notifier)
          .updatePreference(
            const AudioFormatPreference(
              priority: [
                AudioFormat.mp3,
                AudioFormat.wav,
                AudioFormat.flac,
                AudioFormat.opus,
                AudioFormat.m4a,
                AudioFormat.aac,
                AudioFormat.other,
              ],
            ),
          );
      await tester.pump();
      await tester.pump();

      expect(find.text('crowded-1.mp3'), findsOneWidget);
      expect(find.text('same-folder.mp3'), findsNothing);
      expect(find.text('manual.flac'), findsOneWidget);
    },
  );

  testWidgets('offline explorer follows the same preferred folder selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync(
      'preferred-audio-folders-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    for (final parts in const [
      ['root.mp3'],
      ['Preferred', 'preferred.wav'],
      ['Preferred', 'same-folder.mp3'],
      ['Outer', 'Inner', 'nested.wav'],
      ['Crowded', 'crowded-1.mp3'],
      ['Crowded', 'crowded-2.mp3'],
      ['Crowded', 'crowded-3.mp3'],
      ['Manual', 'manual.flac'],
    ]) {
      final file = File(p.joinAll([directory.path, ...parts]));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(const []);
    }

    SharedPreferences.setMockInitialValues({
      'custom_download_path': directory.path,
      'audio_format_preference': [
        'wav',
        'mp3',
        'flac',
        'opus',
        'm4a',
        'aac',
        'other',
      ],
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                OfflineFileExplorerWidget(
                  work: const Work(id: 39, title: 'Work'),
                  fileTree: _preferredAudioTree(),
                  localWorkDirPath: directory.path,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    for (
      var i = 0;
      i < 200 && find.text('preferred.wav').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    expect(
      find.text('preferred.wav'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .toList()
          .toString(),
    );
    expect(find.text('nested.wav'), findsOneWidget);
    expect(find.text('crowded-1.mp3'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preferred'));
    await tester.pump();
    await tester.tap(find.text('Manual'));
    await tester.pump();
    expect(find.text('preferred.wav'), findsNothing);
    expect(find.text('manual.flac'), findsOneWidget);

    await container
        .read(audioFormatPreferenceProvider.notifier)
        .updatePreference(
          const AudioFormatPreference(
            priority: [
              AudioFormat.mp3,
              AudioFormat.wav,
              AudioFormat.flac,
              AudioFormat.opus,
              AudioFormat.m4a,
              AudioFormat.aac,
              AudioFormat.other,
            ],
          ),
        );
    await tester.pump();
    await tester.pump();

    expect(find.text('crowded-1.mp3'), findsOneWidget);
    expect(find.text('same-folder.mp3'), findsNothing);
    expect(find.text('manual.flac'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

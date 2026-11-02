import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/services/account_database.dart';
import 'package:kikoeru_flutter/src/services/downloaded_file_state_scanner.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:kikoeru_flutter/src/widgets/file_explorer_widget.dart';
import 'package:kikoeru_flutter/src/widgets/offline_file_explorer_widget.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _SingleTrackApi extends KikoeruApiService {
  final workIds = <int>[];

  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async {
    workIds.add(workId);
    return [
      {'type': 'audio', 'title': 'track.mp3', 'hash': 'audio-track'},
    ];
  }
}

class _Downloads extends Fake implements DownloadTaskRepository {
  final changes = StreamController<DownloadTaskChange>.broadcast();

  @override
  Stream<DownloadTaskChange> get taskChangesStream => changes.stream;
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 60 && finder.evaluate().isEmpty; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

Future<void> _pumpUntilAbsent(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 60 && finder.evaluate().isNotEmpty; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

Future<void> _pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var frame = 0; frame < 60 && !condition(); frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'online and offline markers refresh and stale scans wait for the current work',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'file-explorer-subtitle-refresh-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      final workDir = Directory(p.join(directory.path, 'work-42'));
      workDir.createSync(recursive: true);
      File(p.join(workDir.path, 'track.mp3')).writeAsBytesSync(const []);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('custom_download_path', directory.path);
      await StorageService.initCritical(preferences: preferences);
      final libraryDir = await tester.runAsync(
        SubtitleLibraryService.getSubtitleLibraryDirectory,
      );
      final savedDir = Directory(
        p.join(libraryDir!.path, SubtitleLibraryService.savedFolderName),
      );
      await tester.runAsync(() => savedDir.create(recursive: true));
      final subtitleFile = File(p.join(savedDir.path, 'track.ass'));
      final fileTree = [
        {'type': 'audio', 'title': 'track.mp3', 'hash': 'audio-track'},
      ];
      final scanner = DownloadedFileStateScanner(
        downloadRootPath: () async => directory.path,
        resolveDownloadedPath: (_, __) async => null,
        fileExists: (_) async => false,
      );
      final activeResources =
          <({ProviderContainer container, _Downloads downloads})>[];

      try {
        for (final offline in [false, true]) {
          final loadTailReached = Completer<void>();
          final loadTailReady = Completer<bool>();
          var readinessCalls = 0;
          final downloads = _Downloads();
          final container = ProviderContainer(
            overrides: [
              kikoeruApiServiceProvider.overrideWithValue(_SingleTrackApi()),
              downloadServiceProvider.overrideWithValue(downloads),
              downloadedFileStateScannerProvider.overrideWithValue(scanner),
            ],
          );
          activeResources.add((container: container, downloads: downloads));
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                localizationsDelegates: S.localizationsDelegates,
                supportedLocales: S.supportedLocales,
                home: Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      if (offline)
                        OfflineFileExplorerWidget(
                          work: const Work(id: 42, title: 'Work'),
                          fileTree: fileTree,
                          localWorkDirPath: workDir.path,
                          initialLoadReady: () {
                            // Pause after subtitle scanning, before loading completes.
                            if (++readinessCalls >= 8) {
                              if (!loadTailReached.isCompleted) {
                                loadTailReached.complete();
                              }
                              return loadTailReady.future;
                            }
                            return Future.value(true);
                          },
                        )
                      else
                        FileExplorerWidget(
                          work: const Work(id: 42, title: 'Work'),
                          onLoadCompleted: () {},
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );

          final audioRow = find.byKey(const ValueKey('work-audio-track.mp3'));
          if (offline) {
            await _pumpUntilCondition(
              tester,
              () => loadTailReached.isCompleted,
            );
            expect(loadTailReached.isCompleted, isTrue);
          } else {
            await _pumpUntil(tester, audioRow);
            expect(audioRow, findsOneWidget);
          }
          expect(
            find.byKey(const ValueKey('work-audio-subtitle-track.mp3')),
            findsNothing,
          );

          await tester.runAsync(() async {
            await subtitleFile.writeAsString('[Script Info]\n');
            await SubtitleLibraryService.refreshDirectoryCache(savedDir.path);
          });
          if (offline) {
            await tester.pump();
            loadTailReady.complete(true);
            await _pumpUntil(tester, audioRow);
            expect(audioRow, findsOneWidget);
          }
          final preview = find.byKey(
            const ValueKey('work-audio-subtitle-track.mp3'),
          );
          await _pumpUntil(tester, preview);
          expect(preview, findsOneWidget);

          await tester.tap(
            find.byKey(const ValueKey('work-resource-files-tab')),
          );
          await tester.pumpAndSettle();
          expect(find.byIcon(Icons.subtitles), findsOneWidget);

          await tester.runAsync(
            () => SubtitleLibraryService.delete(subtitleFile.path),
          );
          await _pumpUntilAbsent(tester, find.byIcon(Icons.subtitles));
          expect(find.byIcon(Icons.subtitles), findsNothing);
          await tester.tap(
            find.byKey(const ValueKey('work-resource-audio-tab')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('work-audio-subtitle-track.mp3')),
            findsNothing,
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          container.dispose();
          await downloads.changes.close();
          activeResources.removeLast();
        }

        final parsedWorkDir = Directory(
          p.join(
            libraryDir.path,
            SubtitleLibraryService.parsedFolderName,
            'RJ42',
          ),
        );
        await tester.runAsync(() async {
          await parsedWorkDir.create(recursive: true);
          await File(p.join(parsedWorkDir.path, 'track.ass')).writeAsString('');
        });

        final oldScanPostReady = Completer<bool>();
        final newScanPostReady = Completer<bool>();
        final oldScanReachedGate = Completer<void>();
        final newScanReachedGate = Completer<void>();
        final downloadedPath = Completer<String?>();
        final readyCallsByWork = <int, int>{};
        final work = ValueNotifier(const Work(id: 42, title: 'Work A'));
        final controller = FileExplorerController();
        final api = _SingleTrackApi();
        var loadCompletedCount = 0;
        var refreshCompleted = false;
        final downloads = _Downloads();
        final container = ProviderContainer(
          overrides: [
            kikoeruApiServiceProvider.overrideWithValue(api),
            downloadServiceProvider.overrideWithValue(downloads),
            downloadedFileStateScannerProvider.overrideWithValue(
              DownloadedFileStateScanner(
                downloadRootPath: () async => directory.path,
                resolveDownloadedPath: (_, __) => downloadedPath.future,
                fileExists: (_) async => false,
              ),
            ),
          ],
        );
        Future<bool> initialLoadReady() {
          final calls = (readyCallsByWork[work.value.id] ?? 0) + 1;
          readyCallsByWork[work.value.id] = calls;
          if (work.value.id == 42 && calls == 5) {
            oldScanReachedGate.complete();
            return oldScanPostReady.future;
          }
          if (work.value.id == 43 && calls == 4) {
            newScanReachedGate.complete();
            return newScanPostReady.future;
          }
          return Future.value(true);
        }

        Future<void>? refresh;
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                localizationsDelegates: S.localizationsDelegates,
                supportedLocales: S.supportedLocales,
                home: Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      ValueListenableBuilder<Work>(
                        valueListenable: work,
                        builder: (context, currentWork, _) =>
                            FileExplorerWidget(
                              work: currentWork,
                              controller: controller,
                              initialLoadReady: initialLoadReady,
                              onLoadCompleted: () => loadCompletedCount++,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await _pumpUntilCondition(
            tester,
            () => oldScanReachedGate.isCompleted,
          );
          expect(oldScanReachedGate.isCompleted, isTrue);
          expect(
            find.byKey(const ValueKey('work-audio-subtitle-track.mp3')),
            findsNothing,
            reason: 'A scan waits at the load gate before publishing its match',
          );

          work.value = const Work(id: 43, title: 'Work B');
          await tester.pump();
          refresh = controller.refresh(forceRefresh: true);
          unawaited(
            refresh.then(
              (_) {
                refreshCompleted = true;
              },
              onError: (_) {
                refreshCompleted = true;
              },
            ),
          );
          oldScanPostReady.complete(true);
          await _pumpUntilCondition(
            tester,
            () => newScanReachedGate.isCompleted,
          );

          expect(api.workIds, [42, 43]);
          expect(newScanReachedGate.isCompleted, isTrue);
          expect(
            find.byKey(const ValueKey('work-audio-subtitle-track.mp3')),
            findsNothing,
            reason: 'Work A’s pending result cannot publish into Work B',
          );
          expect(
            refreshCompleted,
            isFalse,
            reason: 'Work B remains behind its subtitle readiness gate',
          );

          newScanPostReady.complete(false);
          await tester.runAsync(() => refresh!);
          await tester.pumpAndSettle();
          expect(refreshCompleted, isTrue);
          expect(loadCompletedCount, 0);
          expect(
            find.byKey(const ValueKey('work-audio-subtitle-track.mp3')),
            findsNothing,
          );
        } finally {
          if (!oldScanPostReady.isCompleted) oldScanPostReady.complete(true);
          if (!newScanPostReady.isCompleted) newScanPostReady.complete(true);
          if (!downloadedPath.isCompleted) downloadedPath.complete(null);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          if (refresh != null) {
            await tester.runAsync(() async {
              try {
                await refresh;
              } catch (_) {}
            });
          }
          container.dispose();
          await downloads.changes.close();
          work.dispose();
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        for (final resource in activeResources) {
          resource.container.dispose();
          await resource.downloads.changes.close();
        }
        await tester.runAsync(() async {
          await (await SubtitleDatabase.instance.database).close();
          await AccountDatabase.instance.close();
          await directory.delete(recursive: true);
        });
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );
}

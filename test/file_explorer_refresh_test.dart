import 'dart:async';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/services/downloaded_file_state_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/widgets/file_explorer_widget.dart';

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

class _Downloads extends Fake implements DownloadTaskRepository {
  final changes = StreamController<DownloadTaskChange>.broadcast();
  @override
  Stream<DownloadTaskChange> get taskChangesStream => changes.stream;
}

void main() {
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
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await controller.refresh(forceRefresh: true);
    await tester.pump();
    expect(scans, 3);
    expect(resolves, 3);
    expect(hashes, ['hash-0', 'hash-0', 'hash-1']);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
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
}

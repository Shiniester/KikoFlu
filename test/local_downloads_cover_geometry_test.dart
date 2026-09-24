import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart'
    show LayoutType;
import 'package:kikoeru_flutter/src/screens/local_downloads_screen.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/collection_grid_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CompletedDownload implements DownloadTaskRepository {
  _CompletedDownload()
    : _task = DownloadTask(
        id: 'downloaded-work',
        workId: 12345,
        workTitle: 'Downloaded Work',
        fileName: 'track.mp3',
        downloadUrl: '',
        totalBytes: 2048,
        downloadedBytes: 2048,
        status: DownloadStatus.completed,
        createdAt: DateTime(2026),
        completedAt: DateTime(2026),
        workMetadata: const {
          'id': 12345,
          'title': 'Downloaded Work',
          'children': [],
        },
      );

  final DownloadTask _task;

  @override
  List<DownloadTask> get tasks => [_task];

  @override
  List<String> get taskIds => [_task.id];

  @override
  DownloadTaskSummary get summary => DownloadTaskSummary.fromTasks(tasks);

  @override
  Stream<DownloadTaskChange> get taskChangesStream => const Stream.empty();

  @override
  DownloadTask? taskById(String taskId) => taskId == _task.id ? _task : null;
}

Widget _testApp(DownloadTaskRepository repository) => ProviderScope(
  overrides: [
    downloadServiceProvider.overrideWithValue(repository),
    downloadTaskIdsProvider.overrideWith(
      (ref) => Stream.value(repository.taskIds),
    ),
  ],
  child: const MaterialApp(
    locale: Locale('en'),
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(size: Size(800, 700), disableAnimations: true),
        child: LocalDownloadsScreen(),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('completed download covers use shared geometry in all layouts', (
    tester,
  ) async {
    for (final layout in LayoutType.values) {
      SharedPreferences.setMockInitialValues({
        'collection_downloads_layout_type': layout.name,
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(_testApp(_CompletedDownload()));
      await tester.pumpAndSettle();

      final card = find.byKey(const ValueKey(12345));
      expect(card, findsOneWidget);
      final coverClip = find
          .descendant(of: card, matching: find.byType(ClipRRect))
          .first;
      final coverSize = tester.getSize(coverClip);
      if (layout == LayoutType.list) {
        expect(coverSize, collectionListCoverSize);
        expect(
          tester.widget<ClipRRect>(coverClip).borderRadius,
          BorderRadius.circular(collectionListCoverSize.width / 15),
        );
      } else {
        expect(coverSize.width / coverSize.height, 4 / 3);
        expect(
          tester.widget<ClipRRect>(coverClip).borderRadius,
          BorderRadius.circular(coverSize.width / 15),
        );
      }
      expect(tester.takeException(), isNull, reason: '$layout download card');
      await tester.pumpWidget(const SizedBox());
    }
  });
}

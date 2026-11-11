import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show BaseCacheManager, FileResponse;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/download_service.dart';
import 'package:kikoeru_flutter/src/services/history_database.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/history_work_card.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _OfflineApi extends KikoeruApiService {
  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async => throw const SocketException('Offline');
}

class _OfflineAuth extends AuthNotifier {
  _OfflineAuth() : super(KikoeruApiService());

  @override
  Future<void> enterAnonymous({String? host}) async {}
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
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets('resumes the selected offline chapter in a mixed-format queue', (
    tester,
  ) async {
    late Directory root;
    late Directory workDir;
    late DownloadService downloads;
    late AudioPlayerService player;
    late BaseCacheManager previousImageCache;
    final history = HistoryDatabase.instance;
    const work = Work(id: -7, title: 'Work');
    final now = DateTime.utc(2026);
    final tasks = <DownloadTask>[
      for (final entry in [('chapter-1', 'one.aac'), ('chapter-2', 'two.opus')])
        DownloadTask(
          id: DownloadTask.createId(
            workId: work.id,
            hash: entry.$1,
            fileName: entry.$2,
          ),
          workId: work.id,
          workTitle: work.title,
          fileName: entry.$2,
          downloadUrl: '',
          hash: entry.$1,
          status: DownloadStatus.completed,
          createdAt: now,
        ),
    ];
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    late HistoryRecord record;

    try {
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('history-resume-');
        workDir = Directory(p.join(root.path, '-7'));
        await workDir.create();
        for (final task in tasks) {
          await File(p.join(workDir.path, task.fileName)).writeAsBytes([0]);
        }
        await File(
          p.join(workDir.path, 'work_metadata.json'),
        ).writeAsString(jsonEncode({'id': work.id, 'title': work.title}));
        SharedPreferences.setMockInitialValues({
          'custom_download_path': root.path,
          'download_tasks': jsonEncode(
            tasks.map((task) => task.toJson()).toList(),
          ),
        });
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, (_) async => root.path);
        previousImageCache = CachedNetworkImageProvider.defaultCacheManager;
        CachedNetworkImageProvider.defaultCacheManager = _NoImageCache();
        downloads = DownloadService.instance;
        player = AudioPlayerService.instance;
        record = HistoryRecord(
          work: work,
          lastPlayedTime: now,
          lastPositionMs: 1000,
          lastTrack: AudioTrack(
            id: 'chapter-2',
            hash: 'chapter-2',
            title: 'two.opus',
            url: Uri.file(p.join(workDir.path, 'two.opus')).toString(),
            workId: work.id,
          ),
        );
        await downloads.initialize();
        await history.addOrUpdate(record);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            kikoeruApiServiceProvider.overrideWithValue(_OfflineApi()),
            authProvider.overrideWith((ref) => _OfflineAuth()),
          ],
          child: MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 220,
                  child: HistoryWorkCard(record: record),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final requestedTrack = player.requestedTrackStream.firstWhere(
        (track) => track != null,
      );
      final requestedQueue = player.queueStream.firstWhere(
        (queue) => queue.isNotEmpty,
      );
      final requested = await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.play_arrow));
        return requestedTrack.timeout(const Duration(seconds: 10));
      });
      final queue = await requestedQueue;
      expect(queue.map((track) => track.hash), ['chapter-1', 'chapter-2']);
      expect(requested?.hash, 'chapter-2');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await player.dispose();
        await downloads.flushPendingWrites();
        downloads.dispose();
        await (await history.database).close();
        CachedNetworkImageProvider.defaultCacheManager = previousImageCache;
        await previousImageCache.dispose();
        await root.delete(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null);
    }
  });
}

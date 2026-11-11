import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';
import 'package:kikoeru_flutter/src/services/download_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'original chapter conversions sync metadata, roll back cancellation, and preserve case aliases',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final root = await Directory.systemTemp.createTemp('original_chapter_');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final audio = [0x66, 0x4c, 0x61, 0x43, ...List.filled(128, 0)];
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('audio', 'flac');
        request.response.contentLength = audio.length;
        request.response.add(audio);
        await request.response.close();
      });
      final workDir = Directory('${root.path}/-7')..createSync();
      final metadataFile = File('${workDir.path}/work_metadata.json');
      await metadataFile.writeAsString(
        jsonEncode({
          'id': -7,
          'title': 'ASMR',
          'children': [
            {
              'type': 'audio',
              'hash': 'chapter-1',
              'startTimeMs': 0,
              'endTimeMs': 1000,
              'title': '01_intro.aac',
              'localRelativePath': 'disc/01_intro.aac',
            },
            {
              'type': 'audio',
              'hash': 'chapter-2',
              'startTimeMs': 1000,
              'endTimeMs': 2000,
              'title': '02_outro.aac',
              'localRelativePath': 'disc/02_outro.aac',
            },
            {
              'type': 'audio',
              'hash': 'chapter-3',
              'startTimeMs': 2000,
              'endTimeMs': 3000,
              'title': '03_case.FLAC',
              'localRelativePath': 'disc/03_case.FLAC',
            },
            {
              'type': 'audio',
              'hash': 'chapter-4',
              'startTimeMs': 3000,
              'endTimeMs': 4000,
              'title': '04_cancel.aac',
              'localRelativePath': 'disc/04_cancel.aac',
            },
          ],
        }),
      );
      final task = DownloadTask(
        id: '-7:hash:chapter-1',
        workId: -7,
        workTitle: 'ASMR',
        fileName: 'disc/01_intro.aac',
        hash: 'chapter-1',
        downloadUrl: 'https://example.invalid/work.m3u8',
        originalDownloadUrl: 'http://127.0.0.1:${server.port}/original',
        startTimeMs: 0,
        endTimeMs: 1000,
        status: DownloadStatus.paused,
        createdAt: DateTime.utc(2026),
      );
      final secondTask = DownloadTask(
        id: '-7:hash:chapter-2',
        workId: -7,
        workTitle: 'ASMR',
        fileName: 'disc/02_outro.aac',
        hash: 'chapter-2',
        downloadUrl: 'https://example.invalid/work.m3u8',
        originalDownloadUrl: 'http://127.0.0.1:${server.port}/original',
        startTimeMs: 1000,
        endTimeMs: 2000,
        status: DownloadStatus.paused,
        createdAt: DateTime.utc(2026),
      );
      final caseAliasTask = DownloadTask(
        id: '-7:hash:chapter-3',
        workId: -7,
        workTitle: 'ASMR',
        fileName: 'disc/03_case.FLAC',
        hash: 'chapter-3',
        downloadUrl: 'https://example.invalid/work.m3u8',
        originalDownloadUrl: 'http://127.0.0.1:${server.port}/original',
        startTimeMs: 2000,
        endTimeMs: 3000,
        status: DownloadStatus.paused,
        createdAt: DateTime.utc(2026),
      );
      final cancelledTask = DownloadTask(
        id: '-7:hash:chapter-4',
        workId: -7,
        workTitle: 'ASMR',
        fileName: 'disc/04_cancel.aac',
        hash: 'chapter-4',
        downloadUrl: 'https://example.invalid/work.m3u8',
        originalDownloadUrl: 'http://127.0.0.1:${server.port}/original',
        startTimeMs: 3000,
        endTimeMs: 4000,
        status: DownloadStatus.paused,
        createdAt: DateTime.utc(2026),
      );
      SharedPreferences.setMockInitialValues({
        'custom_download_path': root.path,
        'download_tasks': jsonEncode([
          task.toJson(),
          secondTask.toJson(),
          caseAliasTask.toJson(),
          cancelledTask.toJson(),
        ]),
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final service = DownloadService.instance;
      addTearDown(() async {
        await service.flushPendingWrites();
        service.dispose();
        await server.close(force: true);
        HttpOverrides.global = previousOverrides;
        if (await root.exists()) await root.delete(recursive: true);
      });
      await service.initialize();
      final oldFile = File('${workDir.path}/disc/01_intro.aac');
      final secondOldFile = File('${workDir.path}/disc/02_outro.aac');
      final cancelledOldFile = File('${workDir.path}/disc/04_cancel.aac');
      await oldFile.parent.create(recursive: true);
      await oldFile.writeAsBytes([1, 2, 3]);
      await secondOldFile.writeAsBytes([1, 2, 3]);
      await cancelledOldFile.writeAsBytes([1, 2, 3]);
      final completed = service.taskChangesStream.firstWhere(
        (change) =>
            change.task?.id == task.id &&
            change.task?.status == DownloadStatus.completed,
      );
      await service.resumeTask(task.id);
      final result = await completed.timeout(const Duration(seconds: 15));
      expect(result.task!.fileName, 'disc/01_intro.flac');
      expect(result.task!.id, task.id);
      expect(requests, 1);
      expect(await oldFile.exists(), isFalse);
      expect(service.taskById(secondTask.id)?.status, DownloadStatus.paused);
      expect(
        await File('${workDir.path}/disc/01_intro.flac').readAsBytes(),
        audio,
      );
      final saved = jsonDecode(await metadataFile.readAsString()) as Map;
      final chapter = (saved['children'] as List).singleWhere(
        (child) => child['hash'] == 'chapter-1',
      );
      expect(chapter['localRelativePath'], 'disc/01_intro.flac');
      expect(
        (saved['children'] as List).singleWhere(
          (child) => child['hash'] == 'chapter-2',
        )['localRelativePath'],
        'disc/02_outro.aac',
      );
      final secondCompleted = service.taskChangesStream.firstWhere(
        (change) =>
            change.task?.id == secondTask.id &&
            change.task?.status == DownloadStatus.completed,
      );
      await service.resumeTask(secondTask.id);
      final secondResult = await secondCompleted.timeout(
        const Duration(seconds: 15),
      );
      expect(secondResult.task!.fileName, 'disc/02_outro.flac');
      expect(await secondOldFile.exists(), isFalse);
      expect(
        await File('${workDir.path}/disc/02_outro.flac').readAsBytes(),
        audio,
      );
      final savedAfterSecond =
          jsonDecode(await metadataFile.readAsString()) as Map;
      final savedChildrenAfterSecond = savedAfterSecond['children'] as List;
      expect(
        (savedChildrenAfterSecond.singleWhere(
          (child) => child['hash'] == 'chapter-1',
        ) as Map)['localRelativePath'],
        'disc/01_intro.flac',
      );
      expect(
        (savedChildrenAfterSecond.singleWhere(
          (child) => child['hash'] == 'chapter-2',
        ) as Map)['localRelativePath'],
        'disc/02_outro.flac',
      );
      expect(service.taskById(task.id)?.status, DownloadStatus.completed);
      expect(service.taskById(secondTask.id)?.status, DownloadStatus.completed);
      final inMemoryMetadata = await service.getWorkMetadata(-7);
      final inMemoryChildren = inMemoryMetadata!['children'] as List;
      expect(
        (inMemoryChildren.singleWhere(
          (child) => child['hash'] == 'chapter-1',
        ) as Map)['localRelativePath'],
        'disc/01_intro.flac',
      );
      expect(
        (inMemoryChildren.singleWhere(
          (child) => child['hash'] == 'chapter-2',
        ) as Map)['localRelativePath'],
        'disc/02_outro.flac',
      );
      final oldCaseAlias = File('${workDir.path}/disc/03_case.FLAC');
      await oldCaseAlias.writeAsBytes([1, 2, 3]);
      final aliasCompleted = service.taskChangesStream.firstWhere(
        (change) =>
            change.task?.id == caseAliasTask.id &&
            change.task?.status == DownloadStatus.completed,
      );
      await service.resumeTask(caseAliasTask.id);
      final aliasResult = await aliasCompleted.timeout(
        const Duration(seconds: 15),
      );
      expect(aliasResult.task!.fileName, 'disc/03_case.flac');
      expect(aliasResult.task!.id, caseAliasTask.id);
      expect(
        await File('${workDir.path}/disc/03_case.flac').readAsBytes(),
        audio,
      );
      final cancelledOutput = File('${workDir.path}/disc/04_cancel.flac');
      final cancellationApplied = Completer<void>();
      var siblingSawCancelledPath = false;
      final cancellationSubscription = service.taskChangesStream.listen((
        change,
      ) {
        final changedTask = change.task;
        final children = changedTask?.workMetadata?['children'];
        if (changedTask?.id != cancelledTask.id && children is List) {
          for (final child in children) {
            if (child is Map &&
                child['hash'] == 'chapter-4' &&
                child['localRelativePath'] == 'disc/04_cancel.flac') {
              siblingSawCancelledPath = true;
              break;
            }
          }
        }
        if (changedTask?.id == cancelledTask.id &&
            changedTask?.status == DownloadStatus.downloading &&
            changedTask?.fileName == 'disc/04_cancel.flac') {
          unawaited(
            service.pauseTask(cancelledTask.id).then((_) {
              if (!cancellationApplied.isCompleted) {
                cancellationApplied.complete();
              }
            }),
          );
        }
      });
      addTearDown(cancellationSubscription.cancel);
      final targetDeleted = Completer<void>();
      final targetWatch = workDir
          .watch(events: FileSystemEvent.delete, recursive: true)
          .listen((event) {
            if (event.path.endsWith('04_cancel.flac') &&
                !targetDeleted.isCompleted) {
              targetDeleted.complete();
            }
          });
      addTearDown(targetWatch.cancel);
      await service.resumeTask(cancelledTask.id);
      await cancellationApplied.future.timeout(const Duration(seconds: 15));
      await targetDeleted.future.timeout(const Duration(seconds: 15));
      expect(service.taskById(cancelledTask.id)?.status, DownloadStatus.paused);
      expect(
        service.taskById(cancelledTask.id)?.fileName,
        'disc/04_cancel.aac',
      );
      expect(await cancelledOldFile.exists(), isTrue);
      expect(await cancelledOutput.exists(), isFalse);
      expect(siblingSawCancelledPath, isFalse);
      final savedAfterCancel = jsonDecode(await metadataFile.readAsString()) as Map;
      expect(
        (savedAfterCancel['children'] as List).singleWhere(
          (child) => child['hash'] == 'chapter-4',
        )['localRelativePath'],
        'disc/04_cancel.aac',
      );
      final inMemoryAfterCancel = await service.getWorkMetadata(-7);
      expect(
        (inMemoryAfterCancel!['children'] as List).singleWhere(
          (child) => child['hash'] == 'chapter-4',
        )['localRelativePath'],
        'disc/04_cancel.aac',
      );
      expect(requests, 4);
    },
  );
}

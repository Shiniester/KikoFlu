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
    'original chapters replace earlier attempts without deleting case aliases',
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
              'title': '02_outro.FLAC',
              'localRelativePath': 'disc/02_outro.FLAC',
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
      final caseAliasTask = DownloadTask(
        id: '-7:hash:chapter-2',
        workId: -7,
        workTitle: 'ASMR',
        fileName: 'disc/02_outro.FLAC',
        hash: 'chapter-2',
        downloadUrl: 'https://example.invalid/work.m3u8',
        originalDownloadUrl: 'http://127.0.0.1:${server.port}/original',
        startTimeMs: 1000,
        endTimeMs: 2000,
        status: DownloadStatus.paused,
        createdAt: DateTime.utc(2026),
      );
      SharedPreferences.setMockInitialValues({
        'custom_download_path': root.path,
        'download_tasks': jsonEncode([task.toJson(), caseAliasTask.toJson()]),
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
      await oldFile.parent.create(recursive: true);
      await oldFile.writeAsBytes([1, 2, 3]);
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
      expect(
        await File('${workDir.path}/disc/01_intro.flac').readAsBytes(),
        audio,
      );
      final saved = jsonDecode(await metadataFile.readAsString()) as Map;
      final chapter = (saved['children'] as List).singleWhere(
        (child) => child['hash'] == 'chapter-1',
      );
      expect(chapter['localRelativePath'], 'disc/01_intro.flac');
      final oldCaseAlias = File('${workDir.path}/disc/02_outro.FLAC');
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
      expect(aliasResult.task!.fileName, 'disc/02_outro.flac');
      expect(aliasResult.task!.id, caseAliasTask.id);
      expect(
        await File('${workDir.path}/disc/02_outro.flac').readAsBytes(),
        audio,
      );
      expect(requests, 2);
    },
  );
}

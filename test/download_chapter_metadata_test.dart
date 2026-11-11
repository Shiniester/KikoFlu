import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';
import 'package:kikoeru_flutter/src/services/download_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('metadata uses the current chapter file path by hash and interval', () {
    final metadata = <String, dynamic>{
      'children': [
        {'hash': 'chapter-1', 'startTimeMs': 1000, 'title': '01_intro.aac'},
        {'hash': 'chapter-2', 'startTimeMs': 2000, 'title': '02_outro.aac'},
      ],
    };
    final currentTask = DownloadTask(
      id: '-7:hash:chapter-1',
      workId: -7,
      workTitle: 'ASMR',
      fileName: 'disc/01_intro.flac',
      downloadUrl: 'https://example.invalid/work.m3u8',
      hash: 'chapter-1',
      startTimeMs: 1000,
      status: DownloadStatus.downloading,
      createdAt: DateTime.utc(2026),
    );

    DownloadService.mergeChapterMetadataPaths(
      metadata: metadata,
      workId: -7,
      tasks: [currentTask],
    );

    final children = metadata['children']! as List<dynamic>;
    expect(children[0]['title'], '01_intro.flac');
    expect(children[0]['localRelativePath'], 'disc/01_intro.flac');
    expect(children[1]['title'], '02_outro.aac');
    expect(children[1].containsKey('localRelativePath'), isFalse);
  });

  test(
    'disk refresh does not add a renamed chapter as a second file',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chapter_metadata_refresh_',
      );
      final workDirectory = Directory('${root.path}/-7');
      final audioDirectory = Directory('${workDirectory.path}/disc')
        ..createSync(recursive: true);
      await File(
        '${audioDirectory.path}/01_intro.flac',
      ).writeAsBytes([1, 2, 3]);
      final metadataFile = File('${workDirectory.path}/work_metadata.json');
      await metadataFile.writeAsString(
        jsonEncode({
          'id': -7,
          'title': 'ASMR',
          'localWorkDirName': '-7',
          'children': [
            {
              'type': 'audio',
              'hash': 'chapter-1',
              'startTimeMs': 1000,
              'title': '01_intro.aac',
            },
          ],
        }),
      );
      final task = DownloadTask(
        id: '-7:hash:chapter-1',
        workId: -7,
        workTitle: 'ASMR',
        fileName: 'disc/01_intro.flac',
        downloadUrl: 'https://example.invalid/work.m3u8',
        hash: 'chapter-1',
        startTimeMs: 1000,
        status: DownloadStatus.downloading,
        createdAt: DateTime.utc(2026),
      );
      SharedPreferences.setMockInitialValues({
        'custom_download_path': root.path,
        'download_tasks': jsonEncode([task.toJson()]),
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      addTearDown(() async {
        await DownloadService.instance.flushPendingWrites();
        DownloadService.instance.dispose();
        if (await root.exists()) await root.delete(recursive: true);
      });

      await DownloadService.instance.initialize();

      final refreshed =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      final children = refreshed['children']! as List<dynamic>;
      expect(children, hasLength(1));
      expect(children.single['hash'], 'chapter-1');
      expect(children.single['title'], '01_intro.flac');
      expect(children.single['localRelativePath'], 'disc/01_intro.flac');
      expect(
        children.where((child) => child['hash'] == 'local:disc/01_intro.flac'),
        isEmpty,
      );
    },
  );
}

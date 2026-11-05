import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('subtitle_import_result_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> writeArchive(Map<String, List<int>> files) async {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    final source = File(p.join(root.path, 'RJ123456.zip'));
    await source.writeAsBytes(ZipEncoder().encode(archive)!);
    return source;
  }

  test(
    'reports extraction and classification failures with partial success',
    () async {
      final source = await writeArchive({
        'good.lrc': [1, 2, 3],
        'blocked.lrc': [4, 5, 6],
        'broken.zip': [1, 2, 3, 4],
        'cover.jpg': [7],
      });
      final target = Directory(p.join(root.path, 'library'));
      await Directory(
        p.join(target.path, '已解析', 'RJ123456', 'blocked.lrc'),
      ).create(recursive: true);

      final result = await SubtitleLibraryService.importArchiveFromPath(
        source.path,
        targetLibraryPath: target.path,
        refreshIndex: false,
      );

      expect(result.success, isTrue);
      expect(result.importedCount, 1);
      expect(result.errorCount, 2);
      expect(result.indexRefreshFailed, isFalse);
      expect(result.message, contains('部分导入成功'));
      expect(result.message, contains('失败 2 项'));
      expect(result.message, contains('跳过 1 个文件'));
      expect(
        await File(
          p.join(target.path, '已解析', 'RJ123456', 'good.lrc'),
        ).readAsBytes(),
        [1, 2, 3],
      );
    },
  );

  test(
    'reports failures and skipped files when no subtitle is imported',
    () async {
      final source = await writeArchive({
        'broken.zip': [1, 2, 3, 4],
        'cover.jpg': [7],
      });

      final result = await SubtitleLibraryService.importArchiveFromPath(
        source.path,
        targetLibraryPath: p.join(root.path, 'library'),
        refreshIndex: false,
      );

      expect(result.success, isFalse);
      expect(result.importedCount, 0);
      expect(result.errorCount, 1);
      expect(result.message, contains('1 个文件解压失败'));
      expect(result.message, contains('跳过 1 个文件'));
    },
  );

  test('does not count an unsupported file as a failure', () async {
    final source = await writeArchive({
      'cover.jpg': [7],
    });

    final result = await SubtitleLibraryService.importArchiveFromPath(
      source.path,
      targetLibraryPath: p.join(root.path, 'library'),
      refreshIndex: false,
    );

    expect(result.success, isFalse);
    expect(result.errorCount, 0);
    expect(result.message, contains('没有找到字幕文件'));
    expect(result.message, contains('跳过 1 个文件'));
  });

  test('counts a root ZIP decoding failure', () async {
    final source = File(p.join(root.path, 'invalid.zip'));
    await source.writeAsBytes([1, 2, 3, 4]);

    final result = await SubtitleLibraryService.importArchiveFromPath(
      source.path,
      targetLibraryPath: p.join(root.path, 'library'),
      refreshIndex: false,
    );

    expect(result.success, isFalse);
    expect(result.importedCount, 0);
    expect(result.errorCount, 1);
    expect(result.message, contains('解压失败'));
  });

  test(
    'imports and re-imports long ZIP paths under their work folder',
    () async {
      const workFolder = 'RJ123456';
      const fileName = 'track.lrc';
      const extractionPathLength = 245;
      final target = Directory(p.join(root.path, 'long_archive_library'));
      final tempRootName = '.temp_${DateTime.now().millisecondsSinceEpoch}';
      final tempRootLength = p.join(target.path, tempRootName).length;
      final relativePathLength =
          p.separator.length +
          workFolder.length +
          p.separator.length +
          1 +
          fileName.length;
      final nestedFolderLength =
          extractionPathLength - tempRootLength - relativePathLength;
      expect(nestedFolderLength, greaterThan(0));
      expect(nestedFolderLength, lessThan(255));
      final nestedFolder = 'x' * nestedFolderLength;
      final archivePath = p.join(root.path, '$workFolder.zip');

      Future<void> writeArchiveWithContents(List<int> contents) async {
        final archive = Archive()
          ..addFile(
            ArchiveFile(
              '$workFolder/$nestedFolder/$fileName',
              contents.length,
              contents,
            ),
          );
        await File(archivePath).writeAsBytes(ZipEncoder().encode(archive)!);
      }

      await writeArchiveWithContents([1]);
      final firstResult = await SubtitleLibraryService.importArchiveFromPath(
        archivePath,
        targetLibraryPath: target.path,
        refreshIndex: false,
      );
      final workDirectory = Directory(
        p.join(
          target.path,
          SubtitleLibraryService.parsedFolderName,
          workFolder,
        ),
      );
      final firstImportedFiles = await workDirectory
          .list(recursive: true)
          .where(
            (entity) => entity is File && p.extension(entity.path) == '.lrc',
          )
          .cast<File>()
          .toList();
      final firstRecords = await SubtitleLibraryService.scanDirectoryFromPath(
        target.path,
      );

      expect(firstResult.success, isTrue);
      expect(firstResult.importedCount, 1);
      expect(firstResult.errorCount, 0);
      expect(firstImportedFiles, hasLength(firstResult.importedCount));
      expect(firstImportedFiles.single.path.length, lessThanOrEqualTo(240));
      expect(await firstImportedFiles.single.readAsBytes(), [1]);
      expect(firstRecords, hasLength(1));
      expect(firstRecords.single.workId, 123456);
      expect(
        firstRecords.single.category,
        SubtitleLibraryService.parsedFolderName,
      );

      await writeArchiveWithContents([2]);
      final secondResult = await SubtitleLibraryService.importArchiveFromPath(
        archivePath,
        targetLibraryPath: target.path,
        refreshIndex: false,
      );
      final secondImportedFiles = await workDirectory
          .list(recursive: true)
          .where(
            (entity) => entity is File && p.extension(entity.path) == '.lrc',
          )
          .cast<File>()
          .toList();
      final secondRecords = await SubtitleLibraryService.scanDirectoryFromPath(
        target.path,
      );

      expect(secondResult.success, isTrue);
      expect(secondResult.importedCount, 1);
      expect(secondResult.errorCount, 0);
      expect(secondImportedFiles, hasLength(secondResult.importedCount));
      expect(secondImportedFiles.single.path, firstImportedFiles.single.path);
      expect(await secondImportedFiles.single.readAsBytes(), [2]);
      expect(secondRecords, hasLength(1));
      expect(secondRecords.single.workId, 123456);
    },
  );

  test('reports an index failure after saving subtitles', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    var pathRequests = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      pathRequests++;
      throw PlatformException(code: 'index-unavailable');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final source = await writeArchive({
      'track.lrc': [1, 2, 3],
    });
    final target = Directory(p.join(root.path, 'library'));

    final result = await SubtitleLibraryService.importArchiveFromPath(
      source.path,
      targetLibraryPath: target.path,
    );

    expect(result.success, isTrue);
    expect(result.importedCount, 1);
    expect(result.errorCount, 0);
    expect(pathRequests, greaterThan(0));
    expect(result.indexRefreshFailed, isTrue);
    expect(result.message, contains('索引刷新失败'));
    expect(
      await File(
        p.join(target.path, '已解析', 'RJ123456', 'track.lrc'),
      ).readAsBytes(),
      [1, 2, 3],
    );
  });

  test('indexes imported subtitles without reporting a failure', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (call) async => root.path);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final source = await writeArchive({
      'track.lrc': [1, 2, 3],
    });
    final target = Directory(
      p.join(root.path, 'downloads', 'subtitle_library'),
    );

    try {
      final result = await SubtitleLibraryService.importArchiveFromPath(
        source.path,
        targetLibraryPath: target.path,
      );

      expect(result.success, isTrue);
      expect(result.importedCount, 1);
      expect(result.errorCount, 0);
      expect(result.indexRefreshFailed, isFalse);
      expect(result.message, isNot(contains('索引刷新失败')));
      final records = await SubtitleDatabase.instance.getAllFiles();
      expect(
        records.map((record) => record['file_name']),
        contains('track.lrc'),
      );
    } finally {
      await (await SubtitleDatabase.instance.database).close();
    }
  });
}

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

  late Directory appDocuments;
  late Directory libraryDirectory;
  late Database database;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical();

    appDocuments = await Directory.systemTemp.createTemp(
      'subtitle_index_atomicity_',
    );
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => appDocuments.path);

    await SubtitleLibraryService.ensureInitialized();
    libraryDirectory =
        await SubtitleLibraryService.getSubtitleLibraryDirectory();
    database = await SubtitleDatabase.instance.database;
  });

  setUp(() async {
    await database.execute('DROP TRIGGER IF EXISTS fail_subtitle_index_insert');
    if (await libraryDirectory.exists()) {
      await libraryDirectory.delete(recursive: true);
    }
    await libraryDirectory.create(recursive: true);
    await SubtitleLibraryService.clearCache();
  });

  tearDown(() async {
    await database.execute('DROP TRIGGER IF EXISTS fail_subtitle_index_insert');
  });

  tearDownAll(() async {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await database.close();
    if (await appDocuments.exists()) {
      await appDocuments.delete(recursive: true);
    }
  });

  Future<File> writeSubtitle(String relativePath) async {
    final file = File(
      p.joinAll([libraryDirectory.path, ...relativePath.split('/')]),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString('subtitle');
    return file;
  }

  Future<File> writeArchive(Map<String, List<int>> files) async {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    final file = File(p.join(appDocuments.path, 'index_failure.zip'));
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
    return file;
  }

  Future<void> rejectInserting(String fileName) async {
    await database.execute('''
      CREATE TRIGGER fail_subtitle_index_insert
      BEFORE INSERT ON subtitle_files
      WHEN NEW.file_name = '$fileName'
      BEGIN
        SELECT RAISE(ABORT, 'forced subtitle index write failure');
      END
    ''');
  }

  test(
    'keeps every existing record when a full rebuild insert fails',
    () async {
      await writeSubtitle('${SubtitleLibraryService.savedFolderName}/old.srt');
      await SubtitleLibraryService.clearCache();
      final before = await SubtitleDatabase.instance.getAllFiles();
      await writeSubtitle(
        '${SubtitleLibraryService.savedFolderName}/reject_full_rebuild.srt',
      );
      await rejectInserting('reject_full_rebuild.srt');

      await SubtitleLibraryService.clearCache();

      expect(await SubtitleDatabase.instance.getAllFiles(), equals(before));
    },
  );

  test(
    'clears old records when a full rebuild finds no subtitle files',
    () async {
      const relativePath = '${SubtitleLibraryService.savedFolderName}/old.srt';
      final file = await writeSubtitle(relativePath);
      await SubtitleLibraryService.clearCache();
      expect(await SubtitleDatabase.instance.getAllFiles(), hasLength(1));
      await file.delete();

      await SubtitleLibraryService.clearCache();

      expect(await SubtitleDatabase.instance.getAllFiles(), isEmpty);
    },
  );

  test(
    'keeps target and unrelated records when a directory insert fails',
    () async {
      final targetDirectory = Directory(
        p.join(
          libraryDirectory.path,
          SubtitleLibraryService.savedFolderName,
          'target',
        ),
      );
      await writeSubtitle(
        '${SubtitleLibraryService.savedFolderName}/target/old.srt',
      );
      await writeSubtitle(
        '${SubtitleLibraryService.savedFolderName}/other/keep.srt',
      );
      await SubtitleLibraryService.clearCache();
      final before = await SubtitleDatabase.instance.getAllFiles();
      await File(p.join(targetDirectory.path, 'old.srt')).delete();
      await writeSubtitle(
        '${SubtitleLibraryService.savedFolderName}/target/reject_directory_refresh.srt',
      );
      await rejectInserting('reject_directory_refresh.srt');

      await SubtitleLibraryService.refreshDirectoryCache(targetDirectory.path);

      expect(await SubtitleDatabase.instance.getAllFiles(), equals(before));
    },
  );

  test(
    'keeps all old directories when a later imported directory insert fails',
    () async {
      const parsed = SubtitleLibraryService.parsedFolderName;
      await writeSubtitle('$parsed/RJ123456/old_first.srt');
      await writeSubtitle('$parsed/RJ654321/old_second.srt');
      await SubtitleLibraryService.clearCache();
      final before = await SubtitleDatabase.instance.getAllFiles();
      final archive = await writeArchive({
        'RJ123456/new_first.srt': [1],
        'RJ654321/new_second.srt': [2],
      });
      await database.execute('''
      CREATE TRIGGER fail_subtitle_index_insert
      BEFORE INSERT ON subtitle_files
      WHEN NEW.file_name LIKE 'new_%'
        AND EXISTS (
          SELECT 1 FROM subtitle_files WHERE file_name LIKE 'new_%'
        )
      BEGIN
        SELECT RAISE(ABORT, 'forced second directory index failure');
      END
    ''');

      final result = await SubtitleLibraryService.importArchiveFromPath(
        archive.path,
      );

      expect(result.success, isTrue);
      expect(result.indexRefreshFailed, isTrue);
      expect(await SubtitleDatabase.instance.getAllFiles(), equals(before));
    },
  );

  test(
    'refreshes literal wildcard paths and removes stale rows for empty directories',
    () async {
      const saved = SubtitleLibraryService.savedFolderName;
      await writeSubtitle('$saved/foo_bar/old_underscore.srt');
      await writeSubtitle('$saved/fooXbar/keep_underscore.srt');
      await writeSubtitle('$saved/percentage%path/old_percent.srt');
      await writeSubtitle('$saved/percentageXpath/keep_percent.srt');
      await writeSubtitle('$saved/CaseFolder/old_case.srt');
      await writeSubtitle('$saved/empty_dir/stale.srt');
      await SubtitleLibraryService.clearCache();
      await SubtitleDatabase.instance.insertFiles([
        SubtitleFileRecord(
          fileName: 'keep_case.srt',
          relativePath: '$saved/casefolder/keep_case.srt',
          category: saved,
        ),
      ]);

      final underscoreTarget = Directory(
        p.join(libraryDirectory.path, saved, 'foo_bar'),
      );
      await File(p.join(underscoreTarget.path, 'old_underscore.srt')).delete();
      await writeSubtitle('$saved/foo_bar/new_underscore.srt');
      await SubtitleLibraryService.refreshDirectoryCache(underscoreTarget.path);

      final percentTarget = Directory(
        p.join(libraryDirectory.path, saved, 'percentage%path'),
      );
      await File(p.join(percentTarget.path, 'old_percent.srt')).delete();
      await writeSubtitle('$saved/percentage%path/new_percent.srt');
      await SubtitleLibraryService.refreshDirectoryCache(percentTarget.path);

      final caseTarget = Directory(
        p.join(libraryDirectory.path, saved, 'CaseFolder'),
      );
      await File(p.join(caseTarget.path, 'old_case.srt')).delete();
      await writeSubtitle('$saved/CaseFolder/new_case.srt');
      await SubtitleLibraryService.refreshDirectoryCache(caseTarget.path);

      final emptyTarget = Directory(
        p.join(libraryDirectory.path, saved, 'empty_dir'),
      );
      await File(p.join(emptyTarget.path, 'stale.srt')).delete();
      await SubtitleLibraryService.refreshDirectoryCache(emptyTarget.path);

      final relativePaths = (await SubtitleDatabase.instance.getAllFiles()).map(
        (record) => record['relative_path'] as String,
      );
      expect(
        relativePaths,
        unorderedEquals([
          '$saved/foo_bar/new_underscore.srt',
          '$saved/fooXbar/keep_underscore.srt',
          '$saved/percentage%path/new_percent.srt',
          '$saved/percentageXpath/keep_percent.srt',
          '$saved/CaseFolder/new_case.srt',
          '$saved/casefolder/keep_case.srt',
        ]),
      );
    },
  );
}

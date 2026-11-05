import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ArchivePicker extends FilePicker {
  String? archivePath;
  String? directoryPath;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final path = archivePath;
    if (path == null) return null;
    return FilePickerResult([
      PlatformFile(name: p.basename(path), path: path, size: 0),
    ]);
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => directoryPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory libraryDirectory;
  late FilePicker originalPicker;
  late _ArchivePicker picker;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical();
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('subtitle_directory_copy_');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => root.path);
    FilePickerIO.registerWith();
    originalPicker = FilePicker.platform;
    picker = _ArchivePicker();
    FilePicker.platform = picker;

    await SubtitleLibraryService.ensureInitialized();
    libraryDirectory =
        await SubtitleLibraryService.getSubtitleLibraryDirectory();
  });

  tearDown(() {
    FilePicker.platform = originalPicker;
  });

  tearDownAll(() async {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await (await SubtitleDatabase.instance.database).close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> writeArchive(Map<String, List<int>> files, String name) async {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    final file = File(p.join(root.path, name));
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
    return file;
  }

  test(
    'imports nested subtitles, replaces matches, and keeps failures',
    () async {
      final firstArchive = await writeArchive({
        'RJ123456/nested/track.srt': [1, 2, 3],
        'RJ123456/nested/cover.jpg': [4],
      }, 'RJ123456.zip');
      picker.archivePath = firstArchive.path;

      final firstResult = await SubtitleLibraryService.importArchive();
      final targetDirectory = Directory(
        p.join(
          libraryDirectory.path,
          SubtitleLibraryService.parsedFolderName,
          'RJ123456',
        ),
      );
      final track = File(p.join(targetDirectory.path, 'nested', 'track.srt'));

      expect(firstResult.success, isTrue);
      expect(firstResult.importedCount, 1);
      expect(await track.readAsBytes(), [1, 2, 3]);
      expect(
        await File(
          p.join(targetDirectory.path, 'nested', 'cover.jpg'),
        ).exists(),
        isFalse,
      );
      expect(await firstArchive.exists(), isTrue);

      final retained = File(p.join(targetDirectory.path, 'nested', 'keep.lrc'));
      await retained.writeAsBytes([5]);
      final blockedTarget = Directory(
        p.join(targetDirectory.path, 'nested', 'blocked.srt'),
      );
      await blockedTarget.create();

      final secondArchive = await writeArchive({
        'RJ123456/nested/track.srt': [7, 8],
        'RJ123456/nested/new.lrc': [9],
        'RJ123456/nested/blocked.srt': [10],
        'RJ123456/nested/readme.md': [11],
      }, 'RJ123456_update.zip');
      picker.archivePath = secondArchive.path;

      final result = await SubtitleLibraryService.importArchive();

      expect(result.success, isTrue);
      expect(result.importedCount, 2);
      expect(result.errorCount, 1);
      expect(result.message, contains('失败 1 项'));
      expect(await track.readAsBytes(), [7, 8]);
      expect(await retained.readAsBytes(), [5]);
      expect(
        await File(
          p.join(targetDirectory.path, 'nested', 'new.lrc'),
        ).readAsBytes(),
        [9],
      );
      expect(await blockedTarget.exists(), isTrue);
      expect(
        await File(
          p.join(targetDirectory.path, 'nested', 'readme.md'),
        ).exists(),
        isFalse,
      );
      expect(await secondArchive.exists(), isTrue);

      final firstFolder = Directory(p.join(root.path, 'folder_import_first'));
      final firstFolderSource = Directory(p.join(firstFolder.path, 'RJ654321'));
      final firstFolderTrack = File(
        p.join(firstFolderSource.path, 'nested', 'track.srt'),
      );
      await firstFolderTrack.parent.create(recursive: true);
      await firstFolderTrack.writeAsBytes([12]);
      await File(
        p.join(firstFolderSource.path, 'nested', 'cover.jpg'),
      ).writeAsBytes([13]);
      picker.directoryPath = firstFolderSource.path;

      final firstFolderResult = await SubtitleLibraryService.importFolder();
      final folderTarget = Directory(
        p.join(
          libraryDirectory.path,
          SubtitleLibraryService.parsedFolderName,
          'RJ654321',
        ),
      );
      final folderTrack = File(
        p.join(folderTarget.path, 'nested', 'track.srt'),
      );

      expect(firstFolderResult.success, isTrue);
      expect(firstFolderResult.importedCount, 1);
      expect(firstFolderResult.errorCount, 0);
      expect(firstFolderResult.message, contains('跳过 1 个非字幕文件'));
      expect(await folderTrack.readAsBytes(), [12]);
      expect(await firstFolderTrack.exists(), isTrue);
      expect(
        await File(p.join(folderTarget.path, 'nested', 'cover.jpg')).exists(),
        isFalse,
      );

      final folderKeep = File(p.join(folderTarget.path, 'keep.lrc'));
      await folderKeep.writeAsBytes([14]);
      final secondFolder = Directory(p.join(root.path, 'folder_import_second'));
      final secondFolderSource = Directory(
        p.join(secondFolder.path, 'RJ654321'),
      );
      final replacementTrack = File(
        p.join(secondFolderSource.path, 'nested', 'track.srt'),
      );
      await replacementTrack.parent.create(recursive: true);
      await replacementTrack.writeAsBytes([15]);
      final newFolderTrack = File(
        p.join(secondFolderSource.path, 'nested', 'new.lrc'),
      );
      await newFolderTrack.writeAsBytes([16]);
      await File(
        p.join(secondFolderSource.path, 'nested', 'readme.md'),
      ).writeAsBytes([17]);
      picker.directoryPath = secondFolderSource.path;

      final secondFolderResult = await SubtitleLibraryService.importFolder();

      expect(secondFolderResult.success, isTrue);
      expect(secondFolderResult.importedCount, 2);
      expect(secondFolderResult.errorCount, 0);
      expect(secondFolderResult.message, contains('跳过 1 个非字幕文件'));
      expect(await folderTrack.readAsBytes(), [15]);
      expect(await folderKeep.readAsBytes(), [14]);
      expect(
        await File(
          p.join(folderTarget.path, 'nested', 'new.lrc'),
        ).readAsBytes(),
        [16],
      );
      expect(
        await File(p.join(folderTarget.path, 'nested', 'readme.md')).exists(),
        isFalse,
      );
      expect(await firstFolderSource.exists(), isTrue);
      expect(await secondFolderSource.exists(), isTrue);
    },
  );
}

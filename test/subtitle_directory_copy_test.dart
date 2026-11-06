import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_rules.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_long_path.dart';
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

  for (final folderName in ['RJ234569', 'collection']) {
    test(
      'preserves mapped subtitle parent paths on import ($folderName)',
      () async {
        final sourceDirectory = Directory(
          p.join(root.path, 'source', folderName),
        );
        final targetDirectory = Directory(
          folderName == 'RJ234569'
              ? p.join(libraryDirectory.path, '已解析', folderName)
              : p.join(libraryDirectory.path, '未知作品'),
        );
        final fileName = '${'t' * 180}.srt';
        final sourceFiles = <File>[];
        final expectedContents = <String, int>{};
        for (final parent in ['', 'A', 'B/nested']) {
          final path = SubtitleLongPath.resolve(
            p.joinAll([sourceDirectory.path, ...p.posix.split(parent)]),
            fileName,
          )!;
          final file = File(path);
          final content = sourceFiles.length + 1;
          await file.writeAsBytes([content]);
          sourceFiles.add(file);
          expectedContents[p.posix.join(parent, fileName)] = content;
        }
        picker.directoryPath = sourceDirectory.path;

        Set<String>? importedPaths;
        for (final update in [0, 10]) {
          for (var index = 0; index < sourceFiles.length; index++) {
            await sourceFiles[index].writeAsBytes([index + 1 + update]);
          }
          final result = await SubtitleLibraryService.importFolder();
          final files = await targetDirectory
              .list(recursive: true)
              .where(
                (entity) =>
                    entity is File && p.extension(entity.path) == '.srt',
              )
              .cast<File>()
              .toList();

          expect(result.success, isTrue);
          expect(result.importedCount, 3);
          expect(result.errorCount, 0);
          expect(files, hasLength(3));
          final contents = <String, int>{};
          for (final file in files) {
            final originalPath =
                SubtitleLongPath.readFileSync(file.path)?.originalPath ??
                p
                    .relative(file.path, from: targetDirectory.path)
                    .replaceAll('\\', '/');
            contents[originalPath] = (await file.readAsBytes()).single;
          }
          expect(
            contents,
            expectedContents.map(
              (path, value) => MapEntry(path, value + update),
            ),
          );
          final paths = files.map((file) => file.path).toSet();
          if (importedPaths != null) expect(paths, importedPaths);
          importedPaths = paths;
        }
        for (var index = 0; index < sourceFiles.length; index++) {
          expect(await sourceFiles[index].readAsBytes(), [index + 11]);
        }
      },
    );
  }

  test('protects mapped paths during folder import', () async {
    final sourceDirectory = Directory(p.join(root.path, 'source', 'RJ234568'));
    final targetDirectory = Directory(
      p.join(libraryDirectory.path, '已解析', 'RJ234568'),
    );
    const fileName = 'track.srt';
    final folderLength =
        SubtitleLibraryRules.maxPathLength -
        sourceDirectory.path.length -
        fileName.length -
        2;
    final original = File(
      p.join(sourceDirectory.path, 'x' * folderLength, fileName),
    );
    await original.parent.create(recursive: true);
    await original.writeAsBytes([1]);
    picker.directoryPath = sourceDirectory.path;

    final firstResult = await SubtitleLibraryService.importFolder();
    expect(firstResult.errorCount, 0);
    expect(firstResult.importedCount, 1);
    final firstFile = (await targetDirectory.list(recursive: true).toList())
        .whereType<File>()
        .singleWhere((file) => p.extension(file.path) == '.srt');
    final mappedPath = p.relative(firstFile.path, from: targetDirectory.path);
    expect(p.split(mappedPath).first, startsWith('long_'));
    final colliding = File(p.join(sourceDirectory.path, mappedPath));
    await colliding.parent.create(recursive: true);
    await colliding.writeAsBytes([2]);

    Set<String>? paths;
    for (final content in [2, 3]) {
      await colliding.writeAsBytes([content]);
      final result = await SubtitleLibraryService.importFolder();
      final files = (await targetDirectory.list(recursive: true).toList())
          .whereType<File>()
          .where((file) => p.extension(file.path) == '.srt')
          .toList();
      expect(result.errorCount, 0);
      expect(result.importedCount, 2);
      expect(files, hasLength(2));
      expect(
        files.map((file) => file.readAsBytesSync().single),
        unorderedEquals([1, content]),
      );
      final currentPaths = files.map((file) => file.path).toSet();
      if (paths != null) expect(currentPaths, paths);
      paths = currentPaths;
      expect(await original.readAsBytes(), [1]);
      expect(await colliding.readAsBytes(), [content]);
    }
  });

  test('keeps colliding long paths distinct and re-importable', () async {
    final sourceDirectory = Directory(
      p.join(root.path, 'long_path_source', 'RJ234567'),
    );
    final targetDirectory = Directory(
      p.join(
        libraryDirectory.path,
        SubtitleLibraryService.parsedFolderName,
        'RJ234567',
      ),
    );
    const fileName = 'track.srt';
    final segmentLength =
        SubtitleLibraryRules.maxPathLength -
        sourceDirectory.path.length -
        2 -
        fileName.length;
    expect(segmentLength, greaterThan(10));
    expect(segmentLength, lessThan(255));

    final suffix = 'a' * (segmentLength - 10);
    final firstNestedDirectory = 'sameprefix$suffix';
    final secondNestedDirectory = 'sameprefix${'b' * (segmentLength - 10)}';
    expect(
      firstNestedDirectory.substring(0, 10),
      secondNestedDirectory.substring(0, 10),
    );
    final firstSourceFile = File(
      p.join(sourceDirectory.path, firstNestedDirectory, fileName),
    );
    final secondSourceFile = File(
      p.join(sourceDirectory.path, secondNestedDirectory, fileName),
    );
    final firstExpectedTargetPath = p.join(
      targetDirectory.path,
      firstNestedDirectory,
      fileName,
    );
    final secondExpectedTargetPath = p.join(
      targetDirectory.path,
      secondNestedDirectory,
      fileName,
    );
    expect(firstSourceFile.path.length, SubtitleLibraryRules.maxPathLength);
    expect(secondSourceFile.path.length, SubtitleLibraryRules.maxPathLength);
    expect(
      firstExpectedTargetPath.length,
      greaterThan(SubtitleLibraryRules.maxPathLength),
    );
    expect(
      secondExpectedTargetPath.length,
      greaterThan(SubtitleLibraryRules.maxPathLength),
    );

    await targetDirectory.create(recursive: true);
    final retainedFile = File(p.join(targetDirectory.path, 'keep.lrc'));
    await retainedFile.writeAsBytes([8]);
    await firstSourceFile.parent.create(recursive: true);
    await firstSourceFile.writeAsBytes([19]);
    await secondSourceFile.parent.create(recursive: true);
    await secondSourceFile.writeAsBytes([20]);
    picker.directoryPath = sourceDirectory.path;

    final firstResult = await SubtitleLibraryService.importFolder();
    final firstImportedFiles = await targetDirectory
        .list(recursive: true)
        .where((entity) => entity is File)
        .cast<File>()
        .where((file) => p.basename(file.path) == fileName)
        .toList();
    final firstImportedA = firstImportedFiles.singleWhere(
      (file) => file.readAsBytesSync().single == 19,
    );
    final firstImportedB = firstImportedFiles.singleWhere(
      (file) => file.readAsBytesSync().single == 20,
    );

    expect(firstResult.success, isTrue);
    expect(firstResult.importedCount, 2);
    expect(firstResult.errorCount, 0);
    expect(firstImportedFiles, hasLength(2));
    expect(firstImportedA.path, isNot(firstImportedB.path));
    expect(
      p
          .split(p.relative(firstImportedA.path, from: targetDirectory.path))
          .first,
      startsWith('long_'),
    );
    expect(
      p
          .split(p.relative(firstImportedB.path, from: targetDirectory.path))
          .first,
      startsWith('long_'),
    );
    expect(
      firstImportedA.path.length,
      lessThanOrEqualTo(SubtitleLibraryRules.maxPathLength),
    );
    expect(
      firstImportedB.path.length,
      lessThanOrEqualTo(SubtitleLibraryRules.maxPathLength),
    );

    await firstSourceFile.writeAsBytes([21]);
    final secondResult = await SubtitleLibraryService.importFolder();
    final secondImportedFiles = await targetDirectory
        .list(recursive: true)
        .where((entity) => entity is File)
        .cast<File>()
        .where((file) => p.basename(file.path) == fileName)
        .toList();
    final secondImportedA = secondImportedFiles.singleWhere(
      (file) => file.readAsBytesSync().single == 21,
    );
    final secondImportedB = secondImportedFiles.singleWhere(
      (file) => file.readAsBytesSync().single == 20,
    );
    final records = await SubtitleLibraryService.scanDirectoryFromPath(
      libraryDirectory.path,
    );
    final indexedTracks = records
        .where(
          (record) => record.fileName == fileName && record.workId == 234567,
        )
        .toList();

    expect(secondResult.success, isTrue);
    expect(secondResult.importedCount, 2);
    expect(secondResult.errorCount, 0);
    expect(await firstSourceFile.exists(), isTrue);
    expect(await secondSourceFile.exists(), isTrue);
    expect(await firstSourceFile.readAsBytes(), [21]);
    expect(await secondSourceFile.readAsBytes(), [20]);
    expect(secondImportedA.path, firstImportedA.path);
    expect(secondImportedB.path, firstImportedB.path);
    expect(await retainedFile.readAsBytes(), [8]);
    expect(
      indexedTracks.map((record) => record.relativePath).toSet(),
      hasLength(2),
    );
    expect(records.any((record) => record.fileName == 'keep.lrc'), isTrue);
  });

  test(
    'indexes root-level long paths with parsed folders in one import',
    () async {
      final sourceDirectory = Directory(p.join(root.path, 'mixed_source'));
      final sourceWorkDirectory = Directory(
        p.join(sourceDirectory.path, 'RJ765432'),
      );
      final targetDirectory = Directory(
        p.join(libraryDirectory.path, SubtitleLibraryService.unknownFolderName),
      );
      const extension = '.srt';
      final fileNameLength =
          SubtitleLibraryRules.maxPathLength -
          sourceDirectory.path.length -
          p.separator.length;
      expect(fileNameLength, greaterThan(extension.length));
      expect(fileNameLength, lessThan(255));
      final fileName = '${'r' * (fileNameLength - extension.length)}$extension';
      final sourceFile = File(p.join(sourceDirectory.path, fileName));
      final sourceWorkFile = File(p.join(sourceWorkDirectory.path, 'work.srt'));
      expect(sourceFile.path.length, SubtitleLibraryRules.maxPathLength);
      expect(
        p.join(targetDirectory.path, fileName).length,
        greaterThan(SubtitleLibraryRules.maxPathLength),
      );

      await targetDirectory.create(recursive: true);
      final retainedFile = File(p.join(targetDirectory.path, 'keep.lrc'));
      await retainedFile.writeAsBytes([8]);
      await sourceFile.parent.create(recursive: true);
      await sourceFile.writeAsBytes([27]);
      await sourceWorkFile.parent.create(recursive: true);
      await sourceWorkFile.writeAsBytes([28]);
      picker.directoryPath = sourceDirectory.path;

      final result = await SubtitleLibraryService.importFolder();
      final importedFiles = await targetDirectory
          .list(recursive: true)
          .where(
            (entity) =>
                entity is File &&
                {'.lrc', '.srt'}.contains(p.extension(entity.path)),
          )
          .cast<File>()
          .toList();
      final indexedRecords = await SubtitleDatabase.instance.getAllFiles();
      final indexedPaths = indexedRecords
          .map((record) => record['relative_path'] as String)
          .toSet();

      expect(result.success, isTrue);
      expect(result.importedCount, 2);
      expect(result.errorCount, 0);
      expect(await sourceFile.exists(), isTrue);
      expect(await sourceWorkFile.exists(), isTrue);
      expect(await sourceWorkFile.readAsBytes(), [28]);
      expect(await retainedFile.readAsBytes(), [8]);
      expect(importedFiles, hasLength(2));
      final longFile = importedFiles.singleWhere(
        (file) => p.basename(file.path) != 'keep.lrc',
      );
      expect(
        longFile.path.length,
        lessThanOrEqualTo(SubtitleLibraryRules.maxPathLength),
      );
      expect(await longFile.readAsBytes(), [27]);
      expect(
        p.split(p.relative(longFile.path, from: targetDirectory.path)).first,
        startsWith('long_'),
      );
      expect(
        indexedPaths,
        contains(
          '${SubtitleLibraryService.parsedFolderName}/RJ765432/work.srt',
        ),
      );
      expect(
        indexedPaths,
        contains('${SubtitleLibraryService.unknownFolderName}/keep.lrc'),
      );
      expect(
        indexedPaths.where(
          (path) => path.startsWith(
            '${SubtitleLibraryService.unknownFolderName}/long_',
          ),
        ),
        hasLength(1),
      );
    },
  );
}

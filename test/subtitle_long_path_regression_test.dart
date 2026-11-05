import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/player_subtitle_candidates_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/streaming_zip_extractor.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_rules.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_long_path.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('subtitle_long_regression_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> archive(String name, Map<String, List<int>> files) async {
    final value = Archive();
    for (final entry in files.entries) {
      value.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    return File(
      p.join(root.path, name),
    ).writeAsBytes(ZipEncoder().encode(value)!);
  }

  Future<List<File>> subtitles(Directory directory) async => directory
      .list(recursive: true)
      .where((entry) => entry is File && p.extension(entry.path) == '.srt')
      .cast<File>()
      .toList();

  Directory libraryWithWorkRootLength(int length) {
    final remaining =
        length - root.path.length - 1 - p.join('已解析', 'RJ123456').length - 1;
    expect(remaining, greaterThan(0));
    expect(remaining, lessThan(255));
    return Directory(p.join(root.path, 'd' * remaining));
  }

  for (final originalPath in [
    r'folder\name/track.srt',
    r'folder/track\name.srt',
  ]) {
    test(
      're-imports a POSIX path containing a backslash ($originalPath)',
      () async {
        final firstPath = SubtitleLongPath.resolve(root.path, originalPath)!;
        await File(firstPath).writeAsBytes([1]);
        expect(
          SubtitleLongPath.readFileSync(firstPath)!.originalPath,
          originalPath,
        );
        final existing = await SubtitleLongPath.existingPaths(root.path);
        expect(existing[originalPath], firstPath);

        final secondPath = SubtitleLongPath.resolve(root.path, originalPath)!;
        expect(secondPath, firstPath);
        await File(secondPath).writeAsBytes([2]);
        final files = await subtitles(root);
        expect(files, hasLength(1));
        expect(await files.single.readAsBytes(), [2]);
      },
      skip: Platform.isWindows,
    );
  }

  test('rejects mapping metadata that escapes its directory', () async {
    final directory = Directory(p.join(root.path, 'long_12345678'));
    await directory.create();
    final marker = File(p.join(directory.path, SubtitleLongPath.markerName));
    for (final (originalPath, storedName) in [
      ('/absolute/track.srt', 'track.srt'),
      ('../track.srt', 'track.srt'),
      ('folder/../track.srt', 'track.srt'),
      ('track.srt', '../track.srt'),
      ('track.srt', 'folder/track.srt'),
      if (Platform.isWindows) ...[
        (r'folder\..\track.srt', 'track.srt'),
        ('track.srt', r'..\track.srt'),
        (r'C:\track.srt', 'track.srt'),
      ],
    ]) {
      await marker.writeAsString(
        jsonEncode({'path': originalPath, 'file': storedName}),
      );
      expect(SubtitleLongPath.readDirectorySync(directory.path), isNull);
    }
  });

  test('keeps both subtitles when long-path hashes collide', () async {
    final folder = 'folder_${'x' * 150}';
    final source = await archive('collision.zip', {
      'RJ123456/$folder/1cc0eu6/track.srt': [1],
      'RJ123456/$folder/1dwa4i1/track.srt': [2],
      'RJ123456/$folder/1upc3zi/track.srt': [3],
      'RJ123456/$folder/0gcnhz5/track.srt': [4],
    });
    final target = Directory(p.join(root.path, 'collision_target'));
    final result = StreamingZipExtractor.extractSynchronously(
      StreamingZipExtractionRequest(
        sourcePath: source.path,
        targetPath: target.path,
        archiveName: 'collision',
      ),
    );
    final files = await subtitles(target);
    expect(result.errorCount, 0);
    expect(result.extractedCount, 4);
    expect(files, hasLength(4));
    expect(
      files.map((file) => file.readAsBytesSync().single),
      unorderedEquals([1, 2, 3, 4]),
    );

    final library = libraryWithWorkRootLength(180);
    final imported = await SubtitleLibraryService.importArchiveFromPath(
      source.path,
      targetLibraryPath: library.path,
      refreshIndex: false,
    );
    final reimported = await SubtitleLibraryService.importArchiveFromPath(
      source.path,
      targetLibraryPath: library.path,
      refreshIndex: false,
    );
    final importedFiles = await subtitles(library);
    expect(imported.errorCount, 0);
    expect(imported.importedCount, 4);
    expect(reimported.errorCount, 0);
    expect(reimported.importedCount, 4);
    expect(importedFiles, hasLength(4));
    expect(
      importedFiles.map((file) => file.readAsBytesSync().single),
      unorderedEquals([1, 2, 3, 4]),
    );
  });

  for (final workFolder in ['RJ123456', '']) {
    test(
      'protects mapped paths across archive imports ($workFolder)',
      () async {
        final library = libraryWithWorkRootLength(180);
        final prefix = workFolder.isEmpty ? '' : '$workFolder/';
        final first = await archive('first.zip', {
          '$prefix${'x' * 220}/track.srt': [1],
        });
        final firstResult = await SubtitleLibraryService.importArchiveFromPath(
          first.path,
          targetLibraryPath: library.path,
          refreshIndex: false,
        );
        expect(firstResult.errorCount, 0);
        expect(firstResult.importedCount, 1);
        final firstFile = (await subtitles(library)).single;
        final categoryRoot = workFolder.isEmpty
            ? p.join(library.path, '未知作品')
            : p.join(library.path, '已解析', workFolder);
        final mappedPath = p
            .relative(firstFile.path, from: categoryRoot)
            .replaceAll('\\', '/');
        expect(mappedPath, startsWith('long_'));

        Set<String>? paths;
        for (final content in [2, 3]) {
          final source = await archive('next.zip', {
            '$prefix$mappedPath': [content],
          });
          final result = await SubtitleLibraryService.importArchiveFromPath(
            source.path,
            targetLibraryPath: library.path,
            refreshIndex: false,
          );
          final files = await subtitles(library);
          expect(result.errorCount, 0);
          expect(result.importedCount, 1);
          expect(files, hasLength(2));
          expect(
            files.map((file) => file.readAsBytesSync().single),
            unorderedEquals([1, content]),
          );
          final currentPaths = files.map((file) => file.path).toSet();
          if (paths != null) expect(currentPaths, paths);
          paths = currentPaths;
        }
      },
    );
  }

  test('re-imports a work when an archive wrapper changes', () async {
    final target = Directory(p.join(root.path, 'wrapper_library'));
    final nested = 'x' * 160;
    final first = await archive('first.zip', {
      'old_pack/RJ123456/$nested/track.srt': [1],
    });
    final second = await archive('second.zip', {
      'new_pack/RJ123456/$nested/track.srt': [2],
    });
    await SubtitleLibraryService.importArchiveFromPath(
      first.path,
      targetLibraryPath: target.path,
      refreshIndex: false,
    );
    final result = await SubtitleLibraryService.importArchiveFromPath(
      second.path,
      targetLibraryPath: target.path,
      refreshIndex: false,
    );
    final files = await subtitles(target);
    expect(result.errorCount, 0);
    expect(files, hasLength(1));
    expect(await files.single.readAsBytes(), [2]);
  });

  test('does not split an emoji when shortening a filename', () async {
    final source = await archive('emoji.zip', {
      '${'x' * 60}/a😀b.srt': [1],
    });
    final target = Directory(p.join(root.path, 'emoji'));
    final maxPathLength =
        target.path.length + 1 + 'long_12345678'.length + 1 + '.srt'.length + 2;
    final result = StreamingZipExtractor.extractSynchronously(
      StreamingZipExtractionRequest(
        sourcePath: source.path,
        targetPath: target.path,
        archiveName: 'emoji',
        maxPathLength: maxPathLength,
      ),
    );
    final files = await subtitles(target);
    expect(result.errorCount, 0);
    expect(files, hasLength(1));
    expect(p.basename(files.single.path), 'a.srt');
    expect(await files.single.readAsBytes(), [1]);
  });

  test('re-imports a long filename after the library is moved', () async {
    final firstLibrary = libraryWithWorkRootLength(180);
    final secondLibrary = Directory('${firstLibrary.path}${'d' * 10}');
    final name = '${'t' * 130}.srt';
    final first = await archive('first.zip', {
      'RJ123456/folder/$name': [1],
    });
    await SubtitleLibraryService.importArchiveFromPath(
      first.path,
      targetLibraryPath: firstLibrary.path,
      refreshIndex: false,
    );
    await for (final entry in firstLibrary.list(recursive: true)) {
      final destination = p.join(
        secondLibrary.path,
        p.relative(entry.path, from: firstLibrary.path),
      );
      if (entry is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entry is File) {
        await File(destination).parent.create(recursive: true);
        await entry.copy(destination);
      }
    }
    final second = await archive('second.zip', {
      'RJ123456/folder/$name': [2],
    });
    final result = await SubtitleLibraryService.importArchiveFromPath(
      second.path,
      targetLibraryPath: secondLibrary.path,
      refreshIndex: false,
    );
    final files = await subtitles(secondLibrary);
    expect(result.errorCount, 0);
    expect(files, hasLength(1));
    expect(await files.single.readAsBytes(), [2]);
  });

  test(
    'reuses a shortened path after moving the library to a shorter root',
    () async {
      final firstLibrary = libraryWithWorkRootLength(180);
      final secondLibrary = Directory(p.join(root.path, 'short'));
      final name = '${'t' * 80}.srt';
      final first = await archive('first.zip', {
        'RJ123456/folder/$name': [1],
      });
      await SubtitleLibraryService.importArchiveFromPath(
        first.path,
        targetLibraryPath: firstLibrary.path,
        refreshIndex: false,
      );
      await for (final entry in firstLibrary.list(recursive: true)) {
        final destination = p.join(
          secondLibrary.path,
          p.relative(entry.path, from: firstLibrary.path),
        );
        if (entry is Directory) {
          await Directory(destination).create(recursive: true);
        } else if (entry is File) {
          await File(destination).parent.create(recursive: true);
          await entry.copy(destination);
        }
      }
      final second = await archive('second.zip', {
        'RJ123456/folder/$name': [2],
      });
      final result = await SubtitleLibraryService.importArchiveFromPath(
        second.path,
        targetLibraryPath: secondLibrary.path,
        refreshIndex: false,
      );
      final files = await subtitles(secondLibrary);
      expect(result.errorCount, 0);
      expect(files, hasLength(1));
      expect(await files.single.readAsBytes(), [2]);
    },
  );

  test('retains a pre-existing directory when its hash is reused', () async {
    final target = libraryWithWorkRootLength(180);
    final relative = '${'x' * 100}/track.srt';
    final hash = SubtitleLibraryRules.stablePathHash(
      relative,
    ).toRadixString(16).padLeft(8, '0');
    final occupied = File(
      p.join(target.path, '已解析', 'RJ123456', 'long_$hash', 'track.srt'),
    );
    await occupied.parent.create(recursive: true);
    await occupied.writeAsBytes([9]);
    final source = await archive('occupied.zip', {
      'RJ123456/$relative': [1],
    });
    final result = await SubtitleLibraryService.importArchiveFromPath(
      source.path,
      targetLibraryPath: target.path,
      refreshIndex: false,
    );
    final files = await subtitles(target);
    expect(result.errorCount, 0);
    expect(files, hasLength(2));
    expect(await occupied.readAsBytes(), [9]);
    expect(
      files.map((file) => file.readAsBytesSync().single),
      unorderedEquals([1, 9]),
    );
  });

  test('re-imports a shortened subtitle without a work folder', () async {
    final target = libraryWithWorkRootLength(180);
    final relative = 'collection/${'x' * 120}/track.srt';
    final first = await archive('first.zip', {
      relative: [1],
    });
    final second = await archive('second.zip', {
      relative: [2],
    });
    await SubtitleLibraryService.importArchiveFromPath(
      first.path,
      targetLibraryPath: target.path,
      refreshIndex: false,
    );
    final result = await SubtitleLibraryService.importArchiveFromPath(
      second.path,
      targetLibraryPath: target.path,
      refreshIndex: false,
    );
    final files = await subtitles(target);
    final records = await SubtitleLibraryService.scanDirectoryFromPath(
      target.path,
    );
    expect(result.errorCount, 0);
    expect(result.importedCount, 1);
    expect(files, hasLength(1));
    expect(await files.single.readAsBytes(), [2]);
    expect(records.single.category, SubtitleLibraryService.unknownFolderName);
    expect(records.single.fileName, 'track.srt');
  });

  test('reuses an unknown shortened path after moving the library', () async {
    final firstLibrary = libraryWithWorkRootLength(180);
    final secondLibrary = Directory(p.join(root.path, 'short'));
    final relative = 'collection/${'x' * 60}/track.srt';
    final first = await archive('first_unknown.zip', {
      relative: [1],
    });
    final second = await archive('second_unknown.zip', {
      relative: [2],
    });
    await SubtitleLibraryService.importArchiveFromPath(
      first.path,
      targetLibraryPath: firstLibrary.path,
      refreshIndex: false,
    );
    final firstFiles = await subtitles(firstLibrary);
    expect(firstFiles, hasLength(1));
    expect(p.basename(p.dirname(firstFiles.single.path)), startsWith('long_'));

    await firstLibrary.rename(secondLibrary.path);
    final result = await SubtitleLibraryService.importArchiveFromPath(
      second.path,
      targetLibraryPath: secondLibrary.path,
      refreshIndex: false,
    );

    final files = await subtitles(secondLibrary);
    expect(result.errorCount, 0);
    expect(result.importedCount, 1);
    expect(files, hasLength(1));
    expect(await files.single.readAsBytes(), [2]);
    expect(
      p.relative(files.single.path, from: secondLibrary.path),
      p.relative(firstFiles.single.path, from: firstLibrary.path),
    );
  });

  test(
    'matches the original name and language of shortened subtitles',
    () async {
      databaseFactory = databaseFactoryFfi;
      final fixedSuffix = p.join('subtitle_library', '已解析', 'RJ123456');
      final downloadLength = 180 - root.path.length - fixedSuffix.length - 2;
      expect(downloadLength, greaterThan(0));
      final actualDownload = Directory(p.join(root.path, 'p' * downloadLength));
      await actualDownload.create(recursive: true);
      SharedPreferences.setMockInitialValues({
        'custom_download_path': actualDownload.path,
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => root.path);
      final name = '${'n' * 130}.srt';
      final source = await archive('languages.zip', {
        'RJ123456/简体中文/${'a' * 80}/$name': [1],
        'RJ123456/繁体中文/${'a' * 80}/$name': [2],
      });
      try {
        await SubtitleLibraryService.ensureInitialized();
        final result = await SubtitleLibraryService.importArchiveFromPath(
          source.path,
        );
        expect(result.errorCount, 0);
        expect(result.importedCount, 2);
        final track = AudioTrack(
          id: 'track',
          title: '${'n' * 130}.wav',
          url: 'file:///track.wav',
          workId: 123456,
        );
        final candidates = await const PlayerSubtitleCandidateRepository().load(
          track: track,
          fileTree: const [],
          libraryPriority: SubtitleLibraryPriority.highest,
          targetLocale: const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hans',
          ),
        );
        final matching = candidates
            .where((candidate) => candidate.matchesCurrentAudio)
            .toList();
        expect(matching, hasLength(2));
        expect(matching.first.title, name);
        expect(
          await File(
            matching.first.source['localPath'] as String,
          ).readAsBytes(),
          [1],
        );
        final library =
            await SubtitleLibraryService.getSubtitleLibraryDirectory();
        final destination = Directory(
          p.join(library.path, '已解析', 'RJ123456', '简体中文'),
        );
        await destination.create(recursive: true);
        expect(
          await SubtitleLibraryService.move(
            matching.first.source['localPath'] as String,
            destination.path,
          ),
          isTrue,
        );
        final records = await SubtitleDatabase.instance.getFilesByWorkId(
          123456,
        );
        expect(
          records.where((record) => record.fileName == name),
          hasLength(2),
        );
        final moved = records.singleWhere(
          (record) => record.relativePath.contains('简体中文/'),
        );
        final movedFolder = p.dirname(moved.absolutePath(library.path));
        expect(
          await SubtitleLibraryService.rename(movedFolder, 'renamed'),
          isTrue,
        );
        final renamedRecords = await SubtitleDatabase.instance.getFilesByWorkId(
          123456,
        );
        expect(
          renamedRecords.where((record) => record.fileName == name),
          hasLength(2),
        );
        final renamedCandidates =
            await const PlayerSubtitleCandidateRepository().load(
              track: track,
              fileTree: const [],
              libraryPriority: SubtitleLibraryPriority.highest,
              targetLocale: const Locale.fromSubtags(
                languageCode: 'zh',
                scriptCode: 'Hans',
              ),
            );
        expect(
          renamedCandidates.where((candidate) => candidate.matchesCurrentAudio),
          hasLength(2),
        );

        final work = p.join(library.path, '已解析', 'RJ123456');
        final sourceFolder = Directory(p.join(work, 'move_source', 'merge'));
        final targetParent = Directory(p.join(work, 'move_target'));
        final targetFolder = Directory(p.join(targetParent.path, 'merge'));
        final longFolder = 'folder_${'x' * 150}';
        final sourcePath = SubtitleLongPath.resolve(
          sourceFolder.path,
          '$longFolder/1upc3zi/track.srt',
        )!;
        final targetPath = SubtitleLongPath.resolve(
          targetFolder.path,
          '$longFolder/0gcnhz5/track.srt',
        )!;
        expect(
          p.basename(p.dirname(sourcePath)),
          p.basename(p.dirname(targetPath)),
        );
        await File(sourcePath).writeAsBytes([3]);
        await File(targetPath).writeAsBytes([4]);
        expect(
          await SubtitleLibraryService.move(
            sourceFolder.path,
            targetParent.path,
          ),
          isTrue,
        );
        final merged = await subtitles(targetFolder);
        expect(merged, hasLength(2));
        expect(
          merged.map((file) => file.readAsBytesSync().single),
          unorderedEquals([3, 4]),
        );
        final sameSource = Directory(p.join(work, 'long_move_source', 'same'));
        final sameTargetParent = Directory(p.join(work, 'dest'));
        final sameTarget = Directory(p.join(sameTargetParent.path, 'same'));
        final sameOriginal = 'folder/${'z' * 130}.srt';
        final sameSourcePath = SubtitleLongPath.resolve(
          sameSource.path,
          sameOriginal,
        )!;
        final sameTargetPath = SubtitleLongPath.resolve(
          sameTarget.path,
          sameOriginal,
        )!;
        expect(p.basename(sameSourcePath), isNot(p.basename(sameTargetPath)));
        await File(sameSourcePath).writeAsBytes([5]);
        await File(sameTargetPath).writeAsBytes([6]);
        expect(
          await SubtitleLibraryService.move(
            sameSource.path,
            sameTargetParent.path,
          ),
          isTrue,
        );
        final sameFiles = await subtitles(sameTarget);
        expect(sameFiles, hasLength(1));
        expect(await sameFiles.single.readAsBytes(), [5]);

        final directSourceRoot = Directory(p.join(work, 'direct_move_source'));
        final directTargetRoot = Directory(p.join(work, 'direct_move_target'));
        final collisionFolder = 'folder_${'x' * 150}';
        final directSourcePath = SubtitleLongPath.resolve(
          directSourceRoot.path,
          '$collisionFolder/1upc3zi/track.srt',
        )!;
        final directTargetPath = SubtitleLongPath.resolve(
          directTargetRoot.path,
          '$collisionFolder/0gcnhz5/track.srt',
        )!;
        expect(
          p.basename(p.dirname(directSourcePath)),
          p.basename(p.dirname(directTargetPath)),
        );
        await File(directSourcePath).writeAsBytes([1]);
        await File(directTargetPath).writeAsBytes([2]);
        final directSourceDirectory = p.dirname(directSourcePath);
        expect(
          await SubtitleLibraryService.move(
            directSourceDirectory,
            directTargetRoot.path,
          ),
          isTrue,
        );
        final directFiles = await subtitles(directTargetRoot);
        expect(directFiles, hasLength(2));
        expect(
          directFiles.map((file) => file.readAsBytesSync().single),
          unorderedEquals([1, 2]),
        );
        expect(await Directory(directSourceDirectory).exists(), isFalse);
        expect(
          directFiles
              .map(
                (file) => SubtitleLongPath.readFileSync(
                  file.path,
                  allowRenamed: true,
                )!.originalPath,
              )
              .toList(),
          unorderedEquals([
            '$collisionFolder/1upc3zi/track.srt',
            '$collisionFolder/0gcnhz5/track.srt',
          ]),
        );
      } finally {
        await (await SubtitleDatabase.instance.database).close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
}

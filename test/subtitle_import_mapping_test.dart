import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_long_path.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _MappingFileAccessCounter extends IOOverrides {
  _MappingFileAccessCounter(this.rootPath);

  final String rootPath;
  int accesses = 0;

  @override
  File createFile(String path) {
    if (p.basename(path) == SubtitleLongPath.markerName &&
        p.equals(p.dirname(p.dirname(path)), rootPath)) {
      accesses++;
    }
    return super.createFile(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('subtitle_import_mapping_');
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => root.path);
    await SubtitleLibraryService.ensureInitialized();
  });

  tearDownAll(() async {
    await (await SubtitleDatabase.instance.database).close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await root.delete(recursive: true);
  });

  test('reads unknown subtitle mappings once per import', () async {
    const count = 30;
    final archive = Archive();
    for (var index = 0; index < count; index++) {
      archive.addFile(ArchiveFile('${'x' * 220}/track_$index.srt', 1, [index]));
    }
    final source = File(p.join(root.path, 'unknown.zip'));
    await source.writeAsBytes(ZipEncoder().encode(archive)!);
    final target = p.join(root.path, 'unknown_library');
    final first = await SubtitleLibraryService.importArchiveFromPath(
      source.path,
      targetLibraryPath: target,
      refreshIndex: false,
    );
    expect(first.errorCount, 0);
    expect(first.importedCount, count);

    final counter = _MappingFileAccessCounter(p.join(target, '未知作品'));
    final second = await IOOverrides.runWithIOOverrides(
      () => SubtitleLibraryService.importArchiveFromPath(
        source.path,
        targetLibraryPath: target,
        refreshIndex: false,
      ),
      counter,
    );
    expect(second.errorCount, 0);
    expect(second.importedCount, count);
    expect(counter.accesses, count);
    final files = await Directory(target)
        .list(recursive: true)
        .where((entry) => entry is File && p.extension(entry.path) == '.srt')
        .cast<File>()
        .toList();
    expect(files, hasLength(count));
    expect(
      files.map((file) => file.readAsBytesSync().single),
      unorderedEquals(List.generate(count, (index) => index)),
    );
  });

  for (final removeFirstTarget in [false, true]) {
    for (final moveMappedDirectories in [false, true]) {
      test(
        '${removeFirstTarget ? 'merges a collision mapping after the first target is deleted' : 'merges collision mappings created in opposite order'} '
        '(move mapped directories: $moveMappedDirectories)',
        () async {
          final library =
              await SubtitleLibraryService.getSubtitleLibraryDirectory();
          final work = p.join(library.path, '已解析', 'RJ123456');
          final scenario = '${removeFirstTarget}_$moveMappedDirectories';
          final source = p.join(work, 'source_$scenario', 'merge');
          final destinationParent = p.join(work, 'target_$scenario');
          final destination = p.join(destinationParent, 'merge');
          final prefix = 'folder_${'x' * 150}';
          final a = '$prefix/1upc3zi/track.srt';
          final b = '$prefix/0gcnhz5/track.srt';
          final sourceA = SubtitleLongPath.resolve(source, a)!;
          final targetB = SubtitleLongPath.resolve(destination, b)!;
          final targetA = SubtitleLongPath.resolve(destination, a)!;
          expect(
            p.basename(p.dirname(sourceA)),
            p.basename(p.dirname(targetB)),
          );
          await File(sourceA).writeAsBytes([1]);
          if (!removeFirstTarget) {
            await File(SubtitleLongPath.resolve(source, b)!).writeAsBytes([2]);
          }
          await File(targetA).writeAsBytes([3]);
          await File(targetB).writeAsBytes([4]);
          if (removeFirstTarget) {
            await File(targetB).parent.delete(recursive: true);
          }

          if (moveMappedDirectories) {
            final directories = await Directory(source).list().toList();
            for (final directory in directories) {
              expect(
                await SubtitleLibraryService.move(directory.path, destination),
                isTrue,
              );
            }
            expect(await Directory(source).list().toList(), isEmpty);
          } else {
            expect(
              await SubtitleLibraryService.move(source, destinationParent),
              isTrue,
            );
            expect(await Directory(source).exists(), isFalse);
          }

          final files = await Directory(destination)
              .list(recursive: true)
              .where(
                (entry) => entry is File && p.extension(entry.path) == '.srt',
              )
              .toList();
          expect(
            files.map((file) => file.path),
            unorderedEquals([targetA, if (!removeFirstTarget) targetB]),
          );
          expect(await File(targetA).readAsBytes(), [1]);
          if (!removeFirstTarget) {
            expect(await File(targetB).readAsBytes(), [2]);
            expect(SubtitleLongPath.readFileSync(targetB)!.originalPath, b);
          }
          expect(SubtitleLongPath.readFileSync(targetA)!.originalPath, a);
        },
      );
    }
  }
}

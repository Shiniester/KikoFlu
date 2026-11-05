import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/download_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kikoflu_perf_entrypoint_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('production build rejects performance task injection', () {
    expect(
      () => DownloadService.instance.debugInjectPerformanceTasks(const []),
      throwsStateError,
    );
  });

  test('subtitle scan accepts an injected source directory', () async {
    final source = Directory(p.join(root.path, 'subtitles'));
    await File(
      p.join(source.path, '已解析', 'RJ123456', 'track.srt'),
    ).create(recursive: true);

    final records = await SubtitleLibraryService.scanDirectoryFromPath(
      source.path,
    );

    expect(records, hasLength(1));
    expect(records.single.workId, 123456);
  });

  test('archive import accepts isolated source and target paths', () async {
    final payload = File(p.join(root.path, 'RJ123456', 'track.srt'));
    await payload.create(recursive: true);
    await payload.writeAsString('1\n00:00:00,000 --> 00:00:01,000\nfixture\n');
    final archiveFile = File(p.join(root.path, 'RJ123456.zip'));
    final encoder = ZipFileEncoder()..create(archiveFile.path);
    await encoder.addFile(payload, 'track.srt');
    encoder.closeSync();
    final target = Directory(p.join(root.path, 'target'));

    final result = await SubtitleLibraryService.importArchiveFromPath(
      archiveFile.path,
      targetLibraryPath: target.path,
      refreshIndex: false,
    );

    expect(result.success, isTrue);
    expect(result.importedCount, 1);
  });

  test('archive import reports progress before classification', () async {
    final archive = Archive();
    final contents = [1, 2, 3];
    for (var index = 0; index < 250; index++) {
      archive.addFile(
        ArchiveFile('track$index.lrc', contents.length, contents),
      );
    }
    final source = File(p.join(root.path, 'RJ123456.zip'));
    await source.writeAsBytes(ZipEncoder().encode(archive)!);
    final progress = <String>[];

    final result = await SubtitleLibraryService.importArchiveFromPath(
      source.path,
      targetLibraryPath: p.join(root.path, 'target'),
      refreshIndex: false,
      onProgress: progress.add,
    );

    final extraction = progress.indexWhere(
      (message) => message.startsWith('正在解压压缩包... 已解压 250 个字幕文件'),
    );
    final classification = progress.indexOf('正在分类和移动文件...');
    expect(result.importedCount, 250);
    expect(extraction, greaterThanOrEqualTo(0));
    expect(classification, greaterThan(extraction));
  });
}

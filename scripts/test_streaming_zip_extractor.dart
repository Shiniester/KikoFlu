import 'dart:io';

import 'package:archive/archive.dart';
import 'package:kikoeru_flutter/src/services/streaming_zip_extractor.dart';

Future<void> main() async {
  await _test(
    'streams root and nested ZIP entries while containing traversal',
    (sandbox) async {
      final nestedBytes = _encodeZip({
        'track.srt': '1\n00:00:00,000 --> 00:00:01,000\nnested\n',
      });
      final outer = Archive()
        ..addFile(ArchiveFile('../../escape.srt', 6, 'inside'))
        ..addFile(ArchiveFile('RJ123456.zip', nestedBytes.length, nestedBytes))
        ..addFile(ArchiveFile('ignored.bin', 3, <int>[1, 2, 3]));
      final source = File('${sandbox.path}${Platform.pathSeparator}source.zip');
      await source.writeAsBytes(ZipEncoder().encode(outer)!);
      final target = Directory(
        '${sandbox.path}${Platform.pathSeparator}output',
      );
      await target.create();

      final result = await StreamingZipExtractor.extract(
        StreamingZipExtractionRequest(
          sourcePath: source.path,
          targetPath: target.path,
          archiveName: 'collection',
        ),
      );

      assert(result.decodedRootArchive);
      assert(result.extractedCount == 2);
      assert(result.nestedArchiveCount == 1);
      assert(result.skippedCount == 1);
      assert(
        File(
              '${target.path}${Platform.pathSeparator}escape.srt',
            ).readAsStringSync() ==
            'inside',
      );
      assert(
        File(
          '${target.path}${Platform.pathSeparator}RJ123456'
          '${Platform.pathSeparator}track.srt',
        ).existsSync(),
      );
      assert(
        !File(
          '${sandbox.parent.path}${Platform.pathSeparator}escape.srt',
        ).existsSync(),
      );
      assert(
        !Directory(
          '${target.path}${Platform.pathSeparator}.nested_archives',
        ).existsSync(),
      );
    },
  );

  await _test('rejects oversized entries before decompressing them', (
    sandbox,
  ) async {
    final source = File('${sandbox.path}${Platform.pathSeparator}source.zip');
    await source.writeAsBytes(_encodeZip({'large.srt': '123456'}));
    final target = Directory('${sandbox.path}${Platform.pathSeparator}output');
    await target.create();

    final result = StreamingZipExtractor.extractSynchronously(
      StreamingZipExtractionRequest(
        sourcePath: source.path,
        targetPath: target.path,
        archiveName: 'collection',
        maxEntrySize: 5,
      ),
    );

    assert(result.extractedCount == 0);
    assert(result.sizeErrorCount == 1);
    assert(result.skippedCount == 1);
    assert(
      !File('${target.path}${Platform.pathSeparator}large.srt').existsSync(),
    );
  });

  await _test(
    'reports a damaged root archive without leaving temporary files',
    (sandbox) async {
      final source = File('${sandbox.path}${Platform.pathSeparator}source.zip');
      await source.writeAsBytes(<int>[1, 2, 3, 4]);
      final target = Directory(
        '${sandbox.path}${Platform.pathSeparator}output',
      );
      await target.create();

      final result = await StreamingZipExtractor.extract(
        StreamingZipExtractionRequest(
          sourcePath: source.path,
          targetPath: target.path,
          archiveName: 'broken',
        ),
      );

      assert(!result.decodedRootArchive);
      assert(result.decodeErrorCount == 1);
      assert(
        !Directory(
          '${target.path}${Platform.pathSeparator}.nested_archives',
        ).existsSync(),
      );
    },
  );
}

Future<void> _test(String name, Future<void> Function(Directory) run) async {
  final sandbox = await Directory.systemTemp.createTemp('kikoflu_zip_test_');
  try {
    await run(sandbox);
    stdout.writeln('PASS: $name');
  } finally {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  }
}

List<int> _encodeZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive)!;
}

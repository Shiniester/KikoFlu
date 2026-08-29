import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/streaming_zip_extractor.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('kikoflu_zip_test_');
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test(
    'streams root and nested ZIP entries while containing traversal',
    () async {
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

      expect(result.decodedRootArchive, isTrue);
      expect(result.extractedCount, 2);
      expect(result.nestedArchiveCount, 1);
      expect(result.skippedCount, 1);
      expect(
        File(
          '${target.path}${Platform.pathSeparator}escape.srt',
        ).readAsStringSync(),
        'inside',
      );
      expect(
        File(
          '${target.path}${Platform.pathSeparator}RJ123456'
          '${Platform.pathSeparator}track.srt',
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          '${sandbox.parent.path}${Platform.pathSeparator}escape.srt',
        ).existsSync(),
        isFalse,
      );
      expect(
        Directory(
          '${target.path}${Platform.pathSeparator}.nested_archives',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('rejects oversized entries before decompressing them', () async {
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

    expect(result.extractedCount, 0);
    expect(result.sizeErrorCount, 1);
    expect(result.skippedCount, 1);
    expect(
      File('${target.path}${Platform.pathSeparator}large.srt').existsSync(),
      isFalse,
    );
  });

  test(
    'reports a damaged root archive without leaving temporary files',
    () async {
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

      expect(result.decodedRootArchive, isFalse);
      expect(result.decodeErrorCount, 1);
      expect(
        Directory(
          '${target.path}${Platform.pathSeparator}.nested_archives',
        ).existsSync(),
        isFalse,
      );
    },
  );
}

List<int> _encodeZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive)!;
}

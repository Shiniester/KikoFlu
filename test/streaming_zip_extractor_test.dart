import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:kikoeru_flutter/src/services/streaming_zip_extractor.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_rules.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDirectory;
  late String targetPath;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync(
      'streaming-zip-extractor-',
    );
    targetPath = p.join(tempDirectory.path, 'output');
  });

  tearDown(() {
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  StreamingZipExtractionResult extract(List<int> zipBytes, String workId) {
    final archivePath = p.join(tempDirectory.path, '$workId.zip');
    File(archivePath).writeAsBytesSync(zipBytes);
    return StreamingZipExtractor.extractSynchronously(
      StreamingZipExtractionRequest(
        sourcePath: archivePath,
        targetPath: targetPath,
        archiveName: workId,
      ),
    );
  }

  test(
    'extracts GBK names with Japanese and Chinese without changing LRC bytes',
    () {
      const workId = 'RJ01015800';
      const entryName = '日本字幕.lrc';
      final lrcBytes = utf8.encode('[00:00.00]駅で再会：你好\n');
      final zipBytes = _patchZipFilename(
        _zipWithFile('ABCDEFGH.lrc', lrcBytes),
        expectedName: ascii.encode('ABCDEFGH.lrc'),
        replacementName: gbk_bytes.encode(entryName),
        utf8Flag: false,
      );

      final result = extract(zipBytes, workId);

      expect(result.decodedRootArchive, isTrue);
      expect(result.extractedCount, 1);
      expect(result.errorCount, 0);
      expect(result.decodeErrorCount, 0);
      expect(
        File(p.join(targetPath, workId, entryName)).readAsBytesSync(),
        lrcBytes,
      );
    },
  );

  test('preserves UTF-8 names with Japanese, Chinese, and accented Latin', () {
    const workId = 'RJ01015801';
    const entryName = '日本語字幕-é.lrc';
    final lrcBytes = utf8.encode('[00:00.00]UTF-8の歌詞：中文\n');

    final result = extract(_zipWithFile(entryName, lrcBytes), workId);

    expect(result.decodedRootArchive, isTrue);
    expect(result.extractedCount, 1);
    expect(result.errorCount, 0);
    expect(
      File(p.join(targetPath, workId, entryName)).readAsBytesSync(),
      lrcBytes,
    );
  });

  test('preserves valid UTF-8 names when the UTF-8 flag is clear', () {
    const workId = 'RJ01015802';
    const entryName = '字幕-日本-é.lrc';
    final lrcBytes = utf8.encode('[00:00.00]本来のUTF-8本文\n');
    final zipBytes = _patchZipFilename(
      _zipWithFile(entryName, lrcBytes),
      expectedName: utf8.encode(entryName),
      replacementName: utf8.encode(entryName),
      utf8Flag: false,
    );

    final result = extract(zipBytes, workId);

    expect(result.decodedRootArchive, isTrue);
    expect(result.extractedCount, 1);
    expect(result.errorCount, 0);
    expect(
      File(p.join(targetPath, workId, entryName)).readAsBytesSync(),
      lrcBytes,
    );
  });

  test('preserves flag-off UTF-8 names made only of Latin-1 characters', () {
    const workId = 'RJ01015805';
    const entryName = 'éñ.lrc';
    final lrcBytes = utf8.encode('[00:00.00]Latin-1 name, UTF-8 bytes\n');
    final zipBytes = _patchZipFilename(
      _zipWithFile(entryName, lrcBytes),
      expectedName: utf8.encode(entryName),
      replacementName: utf8.encode(entryName),
      utf8Flag: false,
    );

    final result = extract(zipBytes, workId);

    expect(result.decodedRootArchive, isTrue);
    expect(result.extractedCount, 1);
    expect(result.errorCount, 0);
    expect(
      File(p.join(targetPath, workId, entryName)).readAsBytesSync(),
      lrcBytes,
    );
  });

  test('decodes GBK names at both nested ZIP levels into the work folder', () {
    const workId = 'RJ01015803';
    const nestedArchiveName = '日本字幕.zip';
    const entryName = '日本字幕.lrc';
    final lrcBytes = utf8.encode('[00:00.00]nested content：内容\n');
    final nestedZip = _patchZipFilename(
      _zipWithFile('INNER123.lrc', lrcBytes),
      expectedName: ascii.encode('INNER123.lrc'),
      replacementName: gbk_bytes.encode(entryName),
      utf8Flag: false,
    );
    final outerZip = _patchZipFilename(
      _zipWithFile('OUTER123.zip', nestedZip),
      expectedName: ascii.encode('OUTER123.zip'),
      replacementName: gbk_bytes.encode(nestedArchiveName),
      utf8Flag: false,
    );

    final result = extract(outerZip, workId);

    expect(result.decodedRootArchive, isTrue);
    expect(result.nestedArchiveCount, 1);
    expect(result.extractedCount, 1);
    expect(result.errorCount, 0);
    expect(result.decodeErrorCount, 0);
    expect(
      File(p.join(targetPath, workId, '日本字幕', entryName)).readAsBytesSync(),
      lrcBytes,
    );
  });

  test(
    'uses the last matching ZIP header after duplicate names are replaced',
    () {
      const workId = 'RJ01015806';
      const entryName = '日本字幕.lrc';
      final lrcBytes = utf8.encode('[00:00.00]after duplicate entries\n');
      var zipBytes = _zipWithFiles({
        'FIRST123.lrc': utf8.encode('[00:00.00]old duplicate\n'),
        'SECOND12.lrc': utf8.encode('[00:00.00]current duplicate\n'),
        'GBKFILE1.lrc': lrcBytes,
      });
      zipBytes = _patchZipFilename(
        zipBytes,
        expectedName: ascii.encode('FIRST123.lrc'),
        replacementName: ascii.encode('DUPENAME.lrc'),
        utf8Flag: false,
      );
      zipBytes = _patchZipFilename(
        zipBytes,
        expectedName: ascii.encode('SECOND12.lrc'),
        replacementName: ascii.encode('DUPENAME.lrc'),
        utf8Flag: false,
      );
      zipBytes = _patchZipFilename(
        zipBytes,
        expectedName: ascii.encode('GBKFILE1.lrc'),
        replacementName: gbk_bytes.encode(entryName),
        utf8Flag: false,
      );

      final result = extract(zipBytes, workId);

      expect(result.extractedCount, 2);
      expect(
        File(p.join(targetPath, workId, entryName)).readAsBytesSync(),
        lrcBytes,
      );
    },
  );

  test('decodes GBK trail bytes before normalizing backslash paths', () {
    const workId = 'RJ01015807';
    const rawEntryName = r'字幕\乗.lrc';
    final lrcBytes = utf8.encode('[00:00.00]backslash path\n');
    final zipBytes = _patchZipFilename(
      _zipWithFile('ABCD/DE.lrc', lrcBytes),
      expectedName: ascii.encode('ABCD/DE.lrc'),
      replacementName: gbk_bytes.encode(rawEntryName),
      utf8Flag: false,
    );

    final result = extract(zipBytes, workId);

    expect(result.extractedCount, 1);
    expect(
      File(p.join(targetPath, workId, '字幕', '乗.lrc')).readAsBytesSync(),
      lrcBytes,
    );
  });

  test('extracts consecutive and alternating subtitle directories', () {
    const workId = 'RJ01015810';
    final result = extract(
      _zipWithFiles({
        'first/one.lrc': [1],
        'first/two.lrc': [2],
        'second/three.lrc': [3],
        'first/four.lrc': [4],
      }),
      workId,
    );

    expect(result.extractedCount, 4);
    expect(result.errorCount, 0);
    expect(
      File(p.join(targetPath, workId, 'first', 'one.lrc')).readAsBytesSync(),
      [1],
    );
    expect(
      File(p.join(targetPath, workId, 'first', 'two.lrc')).readAsBytesSync(),
      [2],
    );
    expect(
      File(p.join(targetPath, workId, 'second', 'three.lrc')).readAsBytesSync(),
      [3],
    );
    expect(
      File(p.join(targetPath, workId, 'first', 'four.lrc')).readAsBytesSync(),
      [4],
    );
  });

  test('later nested ZIP entries overwrite the same subtitle path', () {
    const workId = 'RJ01015811';
    final nestedZip = _zipWithFile('$workId/track.lrc', [4, 5]);
    final result = extract(
      _zipWithFiles({
        '$workId/track.lrc': [1, 2, 3],
        '$workId.zip': nestedZip,
      }),
      'collection',
    );

    expect(result.extractedCount, 2);
    expect(result.errorCount, 0);
    expect(File(p.join(targetPath, workId, 'track.lrc')).readAsBytesSync(), [
      4,
      5,
    ]);
  });

  for (final workFolder in ['RJ123456', '']) {
    test('protects mapped paths during extraction ($workFolder)', () {
      final prefix = workFolder.isEmpty ? '' : '$workFolder/';
      final originalPath = '${'x' * 220}/track.srt';
      final hash = SubtitleLibraryRules.stablePathHash(
        originalPath,
      ).toRadixString(16).padLeft(8, '0');
      final collidingPath = 'long_$hash/track.srt';
      final result = extract(
        _zipWithFiles({
          '$prefix$originalPath': [1],
          '$prefix$collidingPath': [2],
        }),
        'collection',
      );

      List<File> subtitles() => Directory(targetPath)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => p.extension(file.path) == '.srt')
          .toList();

      expect(result.errorCount, 0);
      expect(result.extractedCount, 2);
      final files = subtitles();
      expect(files, hasLength(2));
      expect(
        files.map((file) => file.readAsBytesSync().single),
        unorderedEquals([1, 2]),
      );
      final paths = files.map((file) => file.path).toSet();

      final reimported = extract(
        _zipWithFile('$prefix$collidingPath', [3]),
        'collection',
      );
      final updatedFiles = subtitles();
      expect(reimported.errorCount, 0);
      expect(reimported.extractedCount, 1);
      expect(updatedFiles.map((file) => file.path).toSet(), paths);
      expect(
        updatedFiles.map((file) => file.readAsBytesSync().single),
        unorderedEquals([1, 3]),
      );
    });
  }

  test('keeps extracting when a subtitle path is an existing directory', () {
    const workId = 'RJ01015812';
    final result = extract(
      _zipWithFiles({
        'blocked.lrc/inside.srt': [1],
        'blocked.lrc': Uint8List(2 * 1024 * 1024),
        'later.lrc': [2],
      }),
      workId,
    );

    expect(result.extractedCount, 2);
    expect(result.errorCount, 1);
    expect(
      File(
        p.join(targetPath, workId, 'blocked.lrc', 'inside.srt'),
      ).readAsBytesSync(),
      [1],
    );
    expect(File(p.join(targetPath, workId, 'later.lrc')).readAsBytesSync(), [
      2,
    ]);
  });

  test('extracts small nested ZIPs without temporary archive files', () {
    const workId = 'RJ01015808';
    final lrcBytes = utf8.encode('[00:00.00]nested subtitle\n');
    Directory(targetPath).createSync(recursive: true);
    File(p.join(targetPath, '.nested_archives')).writeAsStringSync('occupied');

    final result = extract(
      _zipWithFile('$workId.zip', _zipWithFile('track.lrc', lrcBytes)),
      'collection',
    );

    expect(result.decodedRootArchive, isTrue);
    expect(result.nestedArchiveCount, 1);
    expect(result.extractedCount, 1);
    expect(result.errorCount, 0);
    expect(
      File(p.join(targetPath, workId, 'track.lrc')).readAsBytesSync(),
      lrcBytes,
    );
  });

  test('extracts large nested ZIPs and removes their temporary files', () {
    const workId = 'RJ01015809';
    final lrcBytes = Uint8List(4 * 1024 * 1024)..last = 1;
    final nested = Archive()
      ..addFile(ArchiveFile.noCompress('track.lrc', lrcBytes.length, lrcBytes));
    final nestedBytes = ZipEncoder().encode(nested)!;
    expect(nestedBytes.length, greaterThan(4 * 1024 * 1024));

    final result = extract(
      _zipWithFile('$workId.zip', nestedBytes),
      'collection',
    );

    expect(result.extractedCount, 1);
    expect(result.errorCount, 0);
    expect(
      File(p.join(targetPath, workId, 'track.lrc')).readAsBytesSync(),
      lrcBytes,
    );
    expect(
      Directory(p.join(targetPath, '.nested_archives')).existsSync(),
      isFalse,
    );
  });

  for (final nested in [false, true]) {
    for (final stored in [false, true]) {
      test('streams ${stored ? 'stored' : 'deflated'} '
          '${nested ? 'large nested ZIPs' : 'subtitle entries'}', () {
        const workId = 'RJ01015810';
        final random = Random(0);
        final contents = Uint8List(4 * 1024 * 1024 + 1);
        for (var index = 0; index < contents.length; index++) {
          contents[index] = random.nextInt(256);
        }
        final payload = nested
            ? ZipEncoder().encode(
                Archive()..addFile(
                  ArchiveFile.noCompress(
                    'track.lrc',
                    contents.length,
                    contents,
                  ),
                ),
              )!
            : contents;
        final name = nested ? '$workId.zip' : '$workId/track.lrc';
        final archive = Archive()
          ..addFile(
            stored
                ? ArchiveFile.noCompress(name, payload.length, payload)
                : ArchiveFile(name, payload.length, payload),
          );
        final source = File(p.join(tempDirectory.path, 'streaming.zip'));
        source.writeAsBytesSync(ZipEncoder().encode(archive)!);
        final reads = _ArchiveReadCounter();

        final result = IOOverrides.runWithIOOverrides(
          () => StreamingZipExtractor.extractSynchronously(
            StreamingZipExtractionRequest(
              sourcePath: source.path,
              targetPath: targetPath,
              archiveName: 'collection',
            ),
          ),
          reads,
        );

        expect(result.extractedCount, 1);
        expect(result.errorCount, 0);
        expect(reads.largestRead, lessThanOrEqualTo(1024 * 1024));
        expect(
          File(p.join(targetPath, workId, 'track.lrc')).readAsBytesSync(),
          contents,
        );
        expect(
          Directory(p.join(targetPath, '.nested_archives')).existsSync(),
          isFalse,
        );
      });
    }
  }

  test('extracts BZip2-compressed subtitle entries', () {
    const workId = 'RJ01015811';
    final contents = utf8.encode('[00:00.00]BZip2 subtitle\n');
    final compressed = BZip2Encoder().encode(contents);
    final archive = Archive()
      ..addFile(
        ArchiveFile.noCompress(
          '$workId/track.lrc',
          compressed.length,
          compressed,
        ),
      );
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final data = ByteData.sublistView(bytes);
    for (var offset = 0; offset <= bytes.length - 4; offset++) {
      final local = _hasSignature(bytes, offset, 0x04034b50);
      final central = _hasSignature(bytes, offset, 0x02014b50);
      if (!local && !central) continue;
      data.setUint16(offset + (local ? 8 : 10), 12, Endian.little);
      data.setUint32(
        offset + (local ? 14 : 16),
        getCrc32(contents),
        Endian.little,
      );
      data.setUint32(
        offset + (local ? 22 : 24),
        contents.length,
        Endian.little,
      );
    }

    final result = extract(bytes, 'collection');

    expect(result.extractedCount, 1);
    expect(result.errorCount, 0);
    expect(
      File(p.join(targetPath, workId, 'track.lrc')).readAsBytesSync(),
      contents,
    );
  });

  test('reports encrypted entries without writing their raw bytes', () {
    final archive = Archive()..addFile(ArchiveFile('track.lrc', 3, [1, 2, 3]));
    final result = extract(
      ZipEncoder(password: 'secret').encode(archive)!,
      'collection',
    );

    expect(result.decodedRootArchive, isTrue);
    expect(result.extractedCount, 0);
    expect(result.errorCount, 1);
    expect(File(p.join(targetPath, 'track.lrc')).existsSync(), isFalse);
  });

  test('continues extracting after an invalid DEFLATE block', () {
    final bytes = _zipWithFiles({
      'broken.lrc': utf8.encode('[00:00.00]broken subtitle\n'),
      'valid.lrc': [7],
    });
    final offset = 30 + _readUint16(bytes, 26) + _readUint16(bytes, 28);
    bytes[offset] = 0x07; // BFINAL=1, reserved BTYPE=3.

    final result = extract(bytes, 'collection');

    expect(result.extractedCount, 1);
    expect(result.errorCount, 1);
    expect(File(p.join(targetPath, 'broken.lrc')).existsSync(), isFalse);
    expect(File(p.join(targetPath, 'valid.lrc')).readAsBytesSync(), [7]);
  });

  test('extracts a subtitle when the shortened path fits the path limit', () {
    const maxPathLength = 240;
    const rootPathLength = 211;
    const fileName = 'abcdefghijk.lrc';
    String longTargetPath(String directoryName) {
      final prefix = p.join(tempDirectory.path, directoryName);
      final segmentLength = rootPathLength - prefix.length - p.separator.length;
      expect(segmentLength, greaterThan(0));
      expect(segmentLength, lessThan(255));
      return p.join(prefix, 'x' * segmentLength);
    }

    final firstTargetPath = longTargetPath('outputA');
    final secondTargetPath = longTargetPath('outputB');
    expect(firstTargetPath.length, rootPathLength);
    expect(secondTargetPath.length, rootPathLength);
    final zipBytes = _zipWithFile(
      'a-very-long-relative-directory-name/deeper/$fileName',
      [7],
    );

    targetPath = firstTargetPath;
    final firstResult = extract(zipBytes, 'collection');
    final firstFiles = Directory(firstTargetPath)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => p.extension(file.path) == '.lrc')
        .toList();

    targetPath = secondTargetPath;
    final secondResult = extract(zipBytes, 'collection');
    final secondFiles = Directory(secondTargetPath)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => p.extension(file.path) == '.lrc')
        .toList();
    final firstRelativePath = p.relative(
      firstFiles.single.path,
      from: firstTargetPath,
    );

    expect(firstResult.extractedCount, 1);
    expect(firstResult.errorCount, 0);
    expect(firstResult.skippedCount, 0);
    expect(secondResult.extractedCount, 1);
    expect(secondResult.errorCount, 0);
    expect(secondResult.skippedCount, 0);
    expect(firstFiles, hasLength(1));
    expect(secondFiles, hasLength(1));
    expect(p.basename(firstFiles.single.path), 'abcdefghij.lrc');
    expect(firstFiles.single.path.length, lessThanOrEqualTo(maxPathLength));
    expect(firstFiles.single.readAsBytesSync(), [7]);
    expect(p.split(firstRelativePath).first, startsWith('long_'));
    expect(
      firstRelativePath,
      p.relative(secondFiles.single.path, from: secondTargetPath),
    );
    expect(secondFiles.single.readAsBytesSync(), [7]);
  });

  test('reports extraction progress before the job completes', () async {
    final files = <String, List<int>>{
      for (var index = 0; index < 250; index++)
        'track$index.lrc': utf8.encode('subtitle $index'),
    };
    final archivePath = p.join(tempDirectory.path, 'collection.zip');
    File(archivePath).writeAsBytesSync(_zipWithFiles(files));
    final progress = <(int, int)>[];

    final result = await StreamingZipExtractor.extract(
      StreamingZipExtractionRequest(
        sourcePath: archivePath,
        targetPath: targetPath,
        archiveName: 'collection',
      ),
      onProgress: (files, archives) => progress.add((files, archives)),
    );

    expect(result.extractedCount, 250);
    expect(progress, contains((250, 0)));
  });

  test(
    'continues extracting other entries when one nested ZIP cannot decode',
    () {
      const workId = 'RJ01015804';
      final lrcBytes = utf8.encode('[00:00.00]kept\n');
      final archive = Archive()
        ..addFile(ArchiveFile('bad.zip', 4, <int>[1, 2, 3, 4]))
        ..addFile(ArchiveFile('track.lrc', lrcBytes.length, lrcBytes));

      final result = extract(
        Uint8List.fromList(ZipEncoder().encode(archive)!),
        workId,
      );

      expect(result.extractedCount, 1);
      expect(result.errorCount, 1);
      expect(result.decodeErrorCount, 1);
      expect(
        File(p.join(targetPath, workId, 'track.lrc')).readAsBytesSync(),
        lrcBytes,
      );
    },
  );
}

final class _ArchiveReadCounter extends IOOverrides {
  int largestRead = 0;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return p.extension(path) == '.zip' ? _CountingFile(file, this) : file;
  }
}

class _CountingFile implements File {
  _CountingFile(this.file, this.counter);

  final File file;
  final _ArchiveReadCounter counter;

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    final handle = file.openSync(mode: mode);
    return mode == FileMode.read ? _CountingHandle(handle, counter) : handle;
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      file.createSync(recursive: recursive, exclusive: exclusive);

  @override
  bool existsSync() => file.existsSync();

  @override
  void deleteSync({bool recursive = false}) =>
      file.deleteSync(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingHandle implements RandomAccessFile {
  _CountingHandle(this.handle, this.counter);

  final RandomAccessFile handle;
  final _ArchiveReadCounter counter;

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    final size = (end ?? buffer.length) - start;
    counter.largestRead = max(counter.largestRead, size);
    return handle.readIntoSync(buffer, start, end);
  }

  @override
  void setPositionSync(int position) => handle.setPositionSync(position);

  @override
  int lengthSync() => handle.lengthSync();

  @override
  void closeSync() => handle.closeSync();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List _zipWithFile(String fileName, List<int> contents) {
  return _zipWithFiles({fileName: contents});
}

Uint8List _zipWithFiles(Map<String, List<int>> files) {
  final archive = Archive();
  for (final file in files.entries) {
    archive.addFile(ArchiveFile(file.key, file.value.length, file.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Uint8List _patchZipFilename(
  List<int> zipBytes, {
  required List<int> expectedName,
  required List<int> replacementName,
  required bool utf8Flag,
}) {
  if (expectedName.length != replacementName.length) {
    throw ArgumentError('ZIP fixture names must have equal byte lengths');
  }

  final bytes = Uint8List.fromList(zipBytes);
  var patchedHeaders = 0;
  for (var offset = 0; offset <= bytes.length - 4; offset++) {
    final isLocalHeader = _hasSignature(bytes, offset, 0x04034b50);
    final isCentralHeader = _hasSignature(bytes, offset, 0x02014b50);
    if (!isLocalHeader && !isCentralHeader) continue;

    final flagsOffset = offset + (isLocalHeader ? 6 : 8);
    final nameLengthOffset = offset + (isLocalHeader ? 26 : 28);
    final extraLengthOffset = offset + (isLocalHeader ? 28 : 30);
    final nameOffset = offset + (isLocalHeader ? 30 : 46);
    final nameLength = _readUint16(bytes, nameLengthOffset);
    if (nameLength != expectedName.length ||
        !_matchesAt(bytes, nameOffset, expectedName)) {
      continue;
    }

    bytes.setRange(nameOffset, nameOffset + nameLength, replacementName);
    var flags = _readUint16(bytes, flagsOffset);
    flags = utf8Flag ? flags | 0x800 : flags & ~0x800;
    _writeUint16(bytes, flagsOffset, flags);
    patchedHeaders++;
    offset =
        nameOffset + nameLength + _readUint16(bytes, extraLengthOffset) - 1;
  }

  if (patchedHeaders != 2) {
    throw StateError(
      'Expected both ZIP filename headers, found $patchedHeaders',
    );
  }
  return bytes;
}

bool _hasSignature(List<int> bytes, int offset, int signature) {
  return _readUint32(bytes, offset) == signature;
}

bool _matchesAt(List<int> bytes, int offset, List<int> expected) {
  for (var index = 0; index < expected.length; index++) {
    if (bytes[offset + index] != expected[index]) return false;
  }
  return true;
}

int _readUint16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _readUint32(List<int> bytes, int offset) =>
    _readUint16(bytes, offset) | (_readUint16(bytes, offset + 2) << 16);

void _writeUint16(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
}

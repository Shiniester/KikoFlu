import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help')) {
    stdout.writeln(
      'Usage: dart run tool/performance/generate_fixtures.dart '
      '[--output <directory>] [--with-zip] '
      '[--zip-uncompressed-mb 512] [--force]',
    );
    return;
  }

  final outputPath =
      _option(arguments, '--output') ?? p.join('build', 'performance_fixtures');
  final zipSizeMb =
      int.tryParse(_option(arguments, '--zip-uncompressed-mb') ?? '512') ?? 512;
  if (zipSizeMb < 2) {
    throw const FormatException('--zip-uncompressed-mb must be at least 2');
  }
  final includeZip = arguments.contains('--with-zip');
  if (!includeZip) {
    throw const FormatException(
      '--with-zip is required for a schema-2 comparable fixture',
    );
  }

  final output = Directory(outputPath);
  final manifestFile = File(p.join(output.path, 'manifest.json'));
  if (await manifestFile.exists() && !arguments.contains('--force')) {
    stdout.writeln(
      'Reusing ${p.absolute(manifestFile.path)}. Pass --force to regenerate.',
    );
    return;
  }
  if (await output.exists()) await output.delete(recursive: true);
  await output.create(recursive: true);

  final worksFile = File(p.join(output.path, 'works_500.json'));
  final tasksFile = File(p.join(output.path, 'download_tasks_1000.json'));
  final recordsFile = File(p.join(output.path, 'local_records_10000.json'));
  final works = _generateWorks();
  final tasks = _generateDownloadTasks();
  final records = _generateLocalRecords();
  final worksHash = await _writeJsonAndHash(worksFile, works);
  final tasksHash = await _writeJsonAndHash(tasksFile, tasks);
  final recordsHash = await _writeJsonAndHash(recordsFile, records);

  final subtitleRoot = Directory(p.join(output.path, 'subtitles'));
  final subtitleHash = await _generateSubtitleTree(subtitleRoot, records);

  final zipFile = File(p.join(output.path, 'nested_${zipSizeMb}mb.zip'));
  await _generateNestedZip(zipFile, uncompressedBytes: zipSizeMb * 1024 * 1024);
  final zipHash = await _hashFile(zipFile);

  final artifactHashes = <String, String>{
    'works': worksHash,
    'downloadTasks': tasksHash,
    'localRecords': recordsHash,
    'subtitleTree': subtitleHash,
    'zip': zipHash,
  };
  final contentHash = sha256
      .convert(
        utf8.encode(
          artifactHashes.entries
              .map((entry) => '${entry.key}:${entry.value}')
              .join('\n'),
        ),
      )
      .toString();

  await _writeJson(manifestFile, {
    'fixtureVersion': 2,
    'seed': 20260829,
    'contentHash': contentHash,
    'artifactHashes': artifactHashes,
    'works': 500,
    'downloadTasks': 1000,
    'activeDownloads': 3,
    'localRecords': 10000,
    'zipUncompressedBytes': zipSizeMb * 1024 * 1024,
    'zipContainsNestedArchive': true,
    'trackSwitches': 50,
    'worksPath': 'works_500.json',
    'downloadTasksPath': 'download_tasks_1000.json',
    'subtitleRootPath': 'subtitles',
    'zipPath': p.basename(zipFile.path),
  });

  stdout.writeln('Performance fixtures written to ${p.absolute(output.path)}');
  stdout.writeln('Fixture SHA-256: $contentHash');
}

List<Map<String, Object?>> _generateWorks() {
  return List.generate(500, (index) {
    final id = 100000 + index;
    return {
      'id': id,
      'source_id': 'RJ$id',
      'title': 'Performance Work ${index.toString().padLeft(3, '0')}',
      'circle': {'id': index % 50, 'name': 'Circle ${index % 50}'},
      'mainCoverUrl': 'https://fixture.invalid/covers/$id.webp',
      'rating': (index % 50) / 10,
    };
  }, growable: false);
}

List<Map<String, Object?>> _generateDownloadTasks() {
  final createdAt = DateTime.utc(2026, 8, 29).toIso8601String();
  return List.generate(1000, (index) {
    final workId = 200000 + (index ~/ 10);
    final fileName = 'disc${(index % 3) + 1}/track_$index.mp3';
    final active = index < 3;
    return {
      'id': '$workId:path:$fileName',
      'workId': workId,
      'workTitle': 'Download Work $workId',
      'fileName': fileName,
      'downloadUrl': 'https://fixture.invalid/audio/$index',
      'hash': null,
      'totalBytes': 20 * 1024 * 1024,
      'downloadedBytes': active ? 0 : 10 * 1024 * 1024,
      'status': active ? 'downloading' : 'paused',
      'error': null,
      'createdAt': createdAt,
      'completedAt': null,
    };
  }, growable: false);
}

List<Map<String, Object?>> _generateLocalRecords() {
  return List.generate(10000, (index) {
    final workId = 300000 + (index ~/ 100);
    final fileName = 'track_${index.toString().padLeft(5, '0')}.srt';
    return {
      'fileName': fileName,
      'relativePath': '已解析/RJ$workId/disc${(index % 4) + 1}/$fileName',
      'category': '已解析',
      'workId': workId,
      'fileSize': 0,
      'modifiedAt': DateTime.utc(2026, 8, 29).toIso8601String(),
      'normalizedName': 'track${index.toString().padLeft(5, '0')}',
    };
  }, growable: false);
}

Future<String> _generateSubtitleTree(
  Directory root,
  List<Map<String, Object?>> records,
) async {
  final canonical = StringBuffer();
  for (var index = 0; index < records.length; index++) {
    final relativePath = records[index]['relativePath']! as String;
    final content = '1\n00:00:00,000 --> 00:00:01,000\nfixture $index\n';
    final file = File(p.joinAll([root.path, ...relativePath.split('/')]));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    canonical
      ..write(relativePath)
      ..write('\u0000')
      ..write(content)
      ..write('\u0000');
  }
  return sha256.convert(utf8.encode(canonical.toString())).toString();
}

Future<void> _generateNestedZip(
  File target, {
  required int uncompressedBytes,
}) async {
  final sourceDirectory = Directory('${target.path}.source');
  await sourceDirectory.create(recursive: true);

  const nestedBytes = 1024 * 1024;
  var remaining = uncompressedBytes - nestedBytes;
  const directEntryBytes = 32 * 1024 * 1024;
  final directFiles = <File>[];
  var index = 0;
  while (remaining > 0) {
    final size = remaining > directEntryBytes ? directEntryBytes : remaining;
    final file = File(p.join(sourceDirectory.path, 'track_$index.srt'));
    await _writeRepeatedBytes(file, size);
    directFiles.add(file);
    remaining -= size;
    index++;
  }

  final nestedPayload = File(p.join(sourceDirectory.path, 'nested_track.srt'));
  await _writeRepeatedBytes(nestedPayload, nestedBytes);
  final nestedZip = File(p.join(sourceDirectory.path, 'RJ399999.zip'));
  final nestedEncoder = ZipFileEncoder()
    ..create(nestedZip.path, level: ZipFileEncoder.STORE);
  await nestedEncoder.addFile(
    nestedPayload,
    'nested_track.srt',
    ZipFileEncoder.STORE,
  );
  nestedEncoder.closeSync();

  final encoder = ZipFileEncoder()
    ..create(target.path, level: ZipFileEncoder.STORE);
  for (final file in directFiles) {
    await encoder.addFile(file, p.basename(file.path), ZipFileEncoder.STORE);
  }
  await encoder.addFile(nestedZip, 'RJ399999.zip', ZipFileEncoder.STORE);
  encoder.closeSync();

  await sourceDirectory.delete(recursive: true);
}

Future<void> _writeRepeatedBytes(File file, int byteCount) async {
  final handle = await file.open(mode: FileMode.write);
  final chunk = Uint8List.fromList(
    utf8.encode('1\n00:00:00,000 --> 00:00:01,000\nfixture subtitle\n'),
  );
  try {
    var remaining = byteCount;
    while (remaining > 0) {
      final length = remaining < chunk.length ? remaining : chunk.length;
      await handle.writeFrom(chunk, 0, length);
      remaining -= length;
    }
  } finally {
    await handle.close();
  }
}

Future<String> _writeJsonAndHash(File file, Object value) async {
  final encoded = const JsonEncoder.withIndent('  ').convert(value);
  await file.writeAsString(encoded);
  return sha256.convert(utf8.encode(encoded)).toString();
}

Future<void> _writeJson(File file, Object value) {
  return file.writeAsString(const JsonEncoder.withIndent('  ').convert(value));
}

Future<String> _hashFile(File file) async {
  return (await sha256.bind(file.openRead()).first).toString();
}

String? _option(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0) return null;
  if (index + 1 >= arguments.length) {
    throw FormatException('$name requires a value');
  }
  return arguments[index + 1];
}

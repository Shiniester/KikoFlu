import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/scan_models.dart';
import 'package:kikoeru_flutter/src/services/subtitle_directory_scanner.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kikoflu_subtitle_scan_');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('collects subtitle metadata in a worker isolate', () async {
    final workDirectory = Directory(
      '${root.path}${Platform.pathSeparator}已解析'
      '${Platform.pathSeparator}RJ00123456',
    )..createSync(recursive: true);
    File(
      '${workDirectory.path}${Platform.pathSeparator}Track 01.mp3.srt',
    ).writeAsStringSync('subtitle');
    File(
      '${workDirectory.path}${Platform.pathSeparator}cover.jpg',
    ).writeAsBytesSync(<int>[1, 2, 3]);
    final hidden = Directory('${root.path}${Platform.pathSeparator}.cache')
      ..createSync();
    File(
      '${hidden.path}${Platform.pathSeparator}hidden.srt',
    ).writeAsStringSync('hidden');

    final result = await const SubtitleDirectoryScanner().scan(
      request: ScanRequest(
        rootPath: root.path,
        operation: 'test-subtitle-scan',
      ),
    );

    expect(result.value, hasLength(1));
    final entry = result.value.single;
    expect(entry.fileName, 'Track 01.mp3.srt');
    expect(entry.relativePath, '已解析/RJ00123456/Track 01.mp3.srt');
    expect(entry.category, '已解析');
    expect(entry.workId, 123456);
    expect(entry.fileSize, greaterThan(0));
    expect(entry.normalizedName, isNotEmpty);
    expect(result.scannedEntries, greaterThanOrEqualTo(4));
  });

  test('cancels an in-flight directory scan', () async {
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}已解析'
      '${Platform.pathSeparator}RJ123456',
    )..createSync(recursive: true);
    for (var index = 0; index < 512; index++) {
      File(
        '${directory.path}${Platform.pathSeparator}$index.srt',
      ).writeAsStringSync('$index');
    }
    final token = ScanCancellationToken();

    final future = const SubtitleDirectoryScanner().scan(
      request: ScanRequest(rootPath: root.path, operation: 'test-cancellation'),
      cancellationToken: token,
      onProgress: (_) => token.cancel(),
    );

    await expectLater(future, throwsA(isA<ScanCancelledException>()));
  });

  test('collects results spanning multiple isolate batches', () async {
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}已解析'
      '${Platform.pathSeparator}RJ7654321',
    )..createSync(recursive: true);
    for (var index = 0; index < 300; index++) {
      File(
        '${directory.path}${Platform.pathSeparator}track_$index.srt',
      ).writeAsStringSync('$index');
    }

    final result = await const SubtitleDirectoryScanner().scan(
      request: ScanRequest(rootPath: root.path, operation: 'test-batches'),
    );

    expect(result.value, hasLength(300));
    expect(result.value.map((entry) => entry.fileName).toSet(), hasLength(300));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/scan_models.dart';
import 'package:kikoeru_flutter/src/services/download_disk_inventory_scanner.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kikoflu_download_scan_');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('creates one reusable inventory for user files and metadata', () async {
    final work = Directory('${root.path}${Platform.pathSeparator}RJ123456')
      ..createSync();
    final nested = Directory('${work.path}${Platform.pathSeparator}disc1')
      ..createSync();
    File(
      '${nested.path}${Platform.pathSeparator}track.mp3',
    ).writeAsStringSync('audio');
    File(
      '${work.path}${Platform.pathSeparator}cover.jpg',
    ).writeAsStringSync('cover');
    File(
      '${work.path}${Platform.pathSeparator}work_metadata.json',
    ).writeAsStringSync('{}');
    File(
      '${work.path}${Platform.pathSeparator}partial.mp3.downloading',
    ).writeAsStringSync('partial');

    final result = await const DownloadDiskInventoryScanner().scan(
      request: ScanRequest(
        rootPath: root.path,
        operation: 'test-download-inventory',
      ),
      workDirectoryPaths: {123456: work.path},
    );

    final files = result.value.filesFor(123456);
    expect(files.map((file) => file.relativePath), contains('disc1/track.mp3'));
    expect(files.map((file) => file.relativePath), contains('cover.jpg'));
    expect(
      files.map((file) => file.relativePath),
      contains('work_metadata.json'),
    );
    expect(
      files.map((file) => file.relativePath),
      isNot(contains('partial.mp3.downloading')),
    );
    expect(result.value.userFilesByRelativePath(123456).keys, [
      'disc1/track.mp3',
    ]);
  });

  test('supports cancellation during a large inventory', () async {
    final work = Directory('${root.path}${Platform.pathSeparator}RJ123456')
      ..createSync();
    for (var index = 0; index < 512; index++) {
      File(
        '${work.path}${Platform.pathSeparator}$index.mp3',
      ).writeAsStringSync('$index');
    }
    final token = ScanCancellationToken();

    final future = const DownloadDiskInventoryScanner().scan(
      request: ScanRequest(
        rootPath: root.path,
        operation: 'test-download-cancellation',
      ),
      workDirectoryPaths: {123456: work.path},
      cancellationToken: token,
      onProgress: (_) => token.cancel(),
    );

    await expectLater(future, throwsA(isA<ScanCancelledException>()));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/cache_file_transaction.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kikoflu_cache_file_transaction_test_',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('replacement never deletes the previous file before the swap', () async {
    final destination = File('${tempDirectory.path}/entry.json');
    final source = File('${destination.path}.tmp');
    await destination.writeAsString('old');
    await source.writeAsString('new');

    final replaced = await replaceCacheFile(source, destination);

    expect(replaced.path, destination.path);
    expect(await destination.readAsString(), 'new');
    expect(await source.exists(), isFalse);
    expect(await cacheFileBackup(destination).exists(), isFalse);
  });

  test(
    'recovery restores a preserved file after an interrupted swap',
    () async {
      final destination = File('${tempDirectory.path}/entry.json');
      final backup = cacheFileBackup(destination);
      await backup.writeAsString('old');

      await recoverCacheFileReplacement(destination);

      expect(await destination.readAsString(), 'old');
      expect(await backup.exists(), isFalse);
    },
  );

  test('concurrent replacements of one destination are serialized', () async {
    final destination = File('${tempDirectory.path}/entry.json');
    final firstSource = File('${destination.path}.first.tmp');
    final secondSource = File('${destination.path}.second.tmp');
    await destination.writeAsString('old');
    await firstSource.writeAsString('first');
    await secondSource.writeAsString('second');

    await Future.wait([
      replaceCacheFile(firstSource, destination),
      replaceCacheFile(secondSource, destination),
    ]);

    expect(await destination.readAsString(), 'second');
    expect(await firstSource.exists(), isFalse);
    expect(await secondSource.exists(), isFalse);
    expect(await cacheFileBackup(destination).exists(), isFalse);
  });

  test('recovery waits for an active replacement', () async {
    final destination = File('${tempDirectory.path}/entry.json');
    final source = File('${destination.path}.tmp');
    await destination.writeAsString('old');
    await source.writeAsString('new');

    final replacement = replaceCacheFile(source, destination);
    final recovery = recoverCacheFileReplacement(destination);
    await Future.wait([replacement, recovery]);

    expect(await destination.readAsString(), 'new');
    expect(await cacheFileBackup(destination).exists(), isFalse);
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/cache_inventory.dart';
import 'package:kikoeru_flutter/src/models/scan_models.dart';
import 'package:kikoeru_flutter/src/services/cache_inventory_scanner.dart';

void main() {
  test('deduplicates simultaneous scans for the same cache roots', () async {
    final completion = Completer<List<CacheInventoryEntry>>();
    var calls = 0;
    final scanner = CacheInventoryScanner(
      scanRoots: (roots) {
        calls++;
        return completion.future;
      },
    );
    const roots = {CacheEntryKind.general: '/cache'};

    final first = scanner.scan(roots: roots);
    final second = scanner.scan(roots: roots);
    expect(calls, 1);

    completion.complete([
      CacheInventoryEntry(
        path: '/cache/a.bin',
        size: 128,
        lastModified: DateTime(2026),
        kind: CacheEntryKind.general,
      ),
    ]);
    final results = await Future.wait([first, second]);

    expect(results[0].value.totalBytes, 128);
    expect(identical(results[0], results[1]), isTrue);
  });

  test(
    'supports cancellation while an isolate-style scan is pending',
    () async {
      final completion = Completer<List<CacheInventoryEntry>>();
      var calls = 0;
      final scanner = CacheInventoryScanner(
        scanRoots: (_) {
          calls++;
          return completion.future;
        },
      );
      final cancellationToken = ScanCancellationToken();

      final scan = scanner.scan(
        roots: const {CacheEntryKind.audio: '/audio-cache'},
        cancellationToken: cancellationToken,
      );
      cancellationToken.cancel();

      await expectLater(scan, throwsA(isA<ScanCancelledException>()));
      final replacement = scanner.scan(
        roots: const {CacheEntryKind.audio: '/audio-cache'},
      );
      expect(
        calls,
        1,
        reason: 'the physical same-root scan must remain shared',
      );
      completion.complete(const []);
      await replacement;
    },
  );
}

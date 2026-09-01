import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../models/cache_inventory.dart';
import '../models/scan_models.dart';

typedef CacheRootScanner =
    Future<List<CacheInventoryEntry>> Function(
      Map<CacheEntryKind, String> roots,
    );

class CacheInventoryScanner {
  CacheInventoryScanner({
    CacheRootScanner? scanRoots,
    this.cacheTtl = const Duration(seconds: 5),
  }) : _scanRoots = scanRoots ?? _scanRootsInIsolate;

  final CacheRootScanner _scanRoots;
  final Duration cacheTtl;
  final Map<String, Future<ScanResult<CacheInventory>>> _inFlight = {};
  final Map<String, ScanResult<CacheInventory>> _cached = {};

  Future<ScanResult<CacheInventory>> scan({
    required Map<CacheEntryKind, String> roots,
    int preferencesBytes = 0,
    bool force = false,
    ScanCancellationToken? cancellationToken,
    void Function(ScanProgress progress)? onProgress,
  }) {
    if (cancellationToken?.isCancelled ?? false) {
      return Future.error(const ScanCancelledException());
    }
    final key = _keyFor(roots);
    final cached = _cached[key];
    if (!force &&
        cached != null &&
        DateTime.now().difference(cached.value.scannedAt) < cacheTtl) {
      return Future.value(cached);
    }
    final sharedScan = _inFlight.putIfAbsent(
      key,
      () => _runScan(
        key: key,
        roots: roots,
        preferencesBytes: preferencesBytes,
        onProgress: onProgress,
      ),
    );
    if (cancellationToken == null) return sharedScan;

    // Cancelling one waiter must not release the same-root single-flight lock:
    // Isolate.run cannot be interrupted, so the physical scan remains shared
    // until it really completes while this caller returns promptly.
    return Future.any([
      sharedScan,
      cancellationToken.whenCancelled.then<ScanResult<CacheInventory>>(
        (_) => throw const ScanCancelledException(),
      ),
    ]);
  }

  void invalidate() => _cached.clear();

  Future<ScanResult<CacheInventory>> _runScan({
    required String key,
    required Map<CacheEntryKind, String> roots,
    required int preferencesBytes,
    required void Function(ScanProgress progress)? onProgress,
  }) async {
    final request = ScanRequest(
      rootPath: roots.values.join('|'),
      operation: 'cache-inventory',
    );
    final stopwatch = Stopwatch()..start();
    onProgress?.call(ScanProgress(request: request, scannedEntries: 0));
    try {
      final entries = await _scanRoots(Map.unmodifiable(roots));
      stopwatch.stop();
      final result = ScanResult(
        request: request,
        value: CacheInventory(
          entries: entries,
          preferencesBytes: preferencesBytes,
          scannedAt: DateTime.now(),
        ),
        scannedEntries: entries.length,
        duration: stopwatch.elapsed,
      );
      _cached[key] = result;
      onProgress?.call(
        ScanProgress(request: request, scannedEntries: entries.length),
      );
      return result;
    } finally {
      _inFlight.remove(key);
    }
  }

  String _keyFor(Map<CacheEntryKind, String> roots) {
    final entries = roots.entries.toList()
      ..sort((a, b) => a.key.index.compareTo(b.key.index));
    return entries
        .map((entry) => '${entry.key.name}:${p.normalize(entry.value)}')
        .join('|');
  }

  static Future<List<CacheInventoryEntry>> _scanRootsInIsolate(
    Map<CacheEntryKind, String> roots,
  ) {
    final input = roots.map((kind, path) => MapEntry(kind.name, path));
    return Isolate.run(() {
      final entries = <CacheInventoryEntry>[];
      final visited = <String>{};
      for (final root in input.entries) {
        final directory = Directory(root.value);
        if (!directory.existsSync()) continue;
        final kind = CacheEntryKind.values.byName(root.key);
        try {
          for (final entity in directory.listSync(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is! File) continue;
            final normalizedPath = p.normalize(entity.path);
            if (!visited.add(normalizedPath)) continue;
            try {
              final stat = entity.statSync();
              entries.add(
                CacheInventoryEntry(
                  path: entity.path,
                  size: stat.size,
                  lastModified: stat.modified,
                  kind: kind,
                ),
              );
            } on FileSystemException {
              // A cache file may disappear while inventory is running.
            }
          }
        } on FileSystemException {
          // Treat an unreadable cache root as empty.
        }
      }
      return entries;
    });
  }
}

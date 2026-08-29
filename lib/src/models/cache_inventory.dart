import 'package:flutter/foundation.dart';

enum CacheEntryKind { general, audio, legacyAudio, image }

@immutable
class CacheInventoryEntry {
  const CacheInventoryEntry({
    required this.path,
    required this.size,
    required this.lastModified,
    required this.kind,
  });

  final String path;
  final int size;
  final DateTime lastModified;
  final CacheEntryKind kind;
}

@immutable
class CacheInventory {
  CacheInventory({
    required Iterable<CacheInventoryEntry> entries,
    required this.preferencesBytes,
    required this.scannedAt,
  }) : entries = List.unmodifiable(entries);

  final List<CacheInventoryEntry> entries;
  final int preferencesBytes;
  final DateTime scannedAt;

  int get fileBytes =>
      entries.fold(0, (total, entry) => total + entry.size);
  int get totalBytes => fileBytes + preferencesBytes;
  int get fileCount => entries.length;

  int bytesFor(CacheEntryKind kind) => entries
      .where((entry) => entry.kind == kind)
      .fold(0, (total, entry) => total + entry.size);

  CacheInventory withoutPaths(Set<String> paths) {
    if (paths.isEmpty) return this;
    return CacheInventory(
      entries: entries.where((entry) => !paths.contains(entry.path)),
      preferencesBytes: preferencesBytes,
      scannedAt: scannedAt,
    );
  }
}

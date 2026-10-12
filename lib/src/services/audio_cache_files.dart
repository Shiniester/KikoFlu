import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cache_file_transaction.dart';
import 'storage_service.dart';

/// Keeps a cache file out of eviction while playback or a transfer owns it.
final class AudioCacheFileLease {
  AudioCacheFileLease._(this.path);

  final String path;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    AudioCacheFiles.unmarkCachePathActive(path);
  }
}

/// Owns the on-disk representation and leases of complete and partial audio.
class AudioCacheFiles {
  AudioCacheFiles({
    Future<Directory> Function()? directoryProvider,
    Future<SharedPreferences> Function()? preferencesProvider,
    this.cacheDuration = const Duration(days: 30),
    this.onChanged,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _preferencesProvider = preferencesProvider ?? StorageService.getPrefs;

  final Future<Directory> Function() _directoryProvider;
  final Future<SharedPreferences> Function() _preferencesProvider;
  final void Function()? onChanged;
  final Duration cacheDuration;
  static final Map<String, int> _activePathCounts = {};

  static bool isCachePathActive(String path) =>
      _activePathCounts.containsKey(p.normalize(path)) ||
      isCacheFileTransactionActive(path);

  static AudioCacheFileLease holdCacheFile(String path) {
    markCachePathActive(path);
    return AudioCacheFileLease._(path);
  }

  static void markCachePathActive(String path) {
    _activePathCounts.update(
      p.normalize(path),
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  static void unmarkCachePathActive(String path) {
    final normalized = p.normalize(path);
    final count = _activePathCounts[normalized];
    if (count == null || count <= 1) {
      _activePathCounts.remove(normalized);
    } else {
      _activePathCounts[normalized] = count - 1;
    }
  }

  static String safeHash(String hash) => hash.replaceAll('/', '_');

  static String completeMetadataKey(String hash) =>
      'audio_cache_meta_${safeHash(hash)}';

  static String partialMetadataKey(String hash) =>
      'audio_partial_meta_${safeHash(hash)}';

  static Future<Directory> _defaultDirectory() async {
    final appCacheDirectory = await getApplicationCacheDirectory();
    final directory = Directory(
      p.join(appCacheDirectory.path, 'kikoeru_audio_cache'),
    );
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<Directory> directory() async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<File> finalFile(String hash) async {
    final cacheDirectory = await directory();
    final file = File(p.join(cacheDirectory.path, '${safeHash(hash)}.audio'));
    await recoverCacheFileReplacement(file);
    return file;
  }

  Future<File> partialFile(String hash, {bool create = false}) async {
    final cacheDirectory = await directory();
    final file = File(
      p.join(cacheDirectory.path, '${safeHash(hash)}.audio.part'),
    );
    if (create && !await file.exists()) {
      await file.create(recursive: true);
    }
    return file;
  }

  Future<String?> completedPath(String hash) async {
    final file = await finalFile(hash);
    if (!await file.exists()) {
      await removeExpiredPartial(hash);
      return null;
    }

    final preferences = await _preferencesProvider();
    final cacheTime = preferences.getInt(completeMetadataKey(hash));
    if (cacheTime != null) {
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(cacheTime);
      if (DateTime.now().difference(cachedAt) < cacheDuration) {
        return file.path;
      }
    }

    if (isCachePathActive(file.path)) return file.path;
    await file.delete();
    await preferences.remove(completeMetadataKey(hash));
    await resetPartial(hash);
    onChanged?.call();
    return null;
  }

  Future<void> removeExpiredPartial(String hash) async {
    final file = await partialFile(hash);
    if (isCachePathActive(file.path) || !await file.exists()) return;
    final modifiedAt = await file.lastModified();
    if (DateTime.now().difference(modifiedAt) <= cacheDuration) return;
    await resetPartial(hash);
  }

  Future<bool> finalize(String hash, {required int expectedSize}) async {
    final partial = await partialFile(hash);
    if (!await partial.exists() || await partial.length() != expectedSize) {
      return false;
    }

    final completed = await finalFile(hash);
    await replaceCacheFile(partial, completed);

    final preferences = await _preferencesProvider();
    await preferences.setInt(
      completeMetadataKey(hash),
      DateTime.now().millisecondsSinceEpoch,
    );
    await preferences.remove(partialMetadataKey(hash));
    onChanged?.call();
    return true;
  }

  Future<void> resetPartial(String hash) async {
    final partial = await partialFile(hash);
    if (await partial.exists()) await partial.delete();
    final preferences = await _preferencesProvider();
    await preferences.remove(partialMetadataKey(hash));
    onChanged?.call();
  }

  Future<void> invalidate(String hash) async {
    final completed = await finalFile(hash);
    final partial = await partialFile(hash);
    if (await completed.exists()) await completed.delete();
    final completedBackup = cacheFileBackup(completed);
    if (await completedBackup.exists()) await completedBackup.delete();
    if (await partial.exists()) await partial.delete();

    final preferences = await _preferencesProvider();
    await preferences.remove(completeMetadataKey(hash));
    await preferences.remove(partialMetadataKey(hash));
    onChanged?.call();
  }

  Future<void> removeMetadataForPath(String path) async {
    final fileName = p.basename(path);
    final preferences = await _preferencesProvider();
    if (fileName.endsWith('.audio.part')) {
      final safe = fileName.substring(
        0,
        fileName.length - '.audio.part'.length,
      );
      await preferences.remove('audio_partial_meta_$safe');
    } else if (fileName.endsWith('.audio')) {
      final safe = fileName.substring(0, fileName.length - '.audio'.length);
      await preferences.remove('audio_cache_meta_$safe');
    }
  }
}

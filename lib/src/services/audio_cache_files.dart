import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cache_file_transaction.dart';
import 'storage_service.dart';

class AudioPartialCacheMetadata {
  const AudioPartialCacheMetadata({this.sourceLength, this.contentType});

  final int? sourceLength;
  final String? contentType;
}

/// Owns the on-disk representation of streaming audio cache entries.
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

    await file.delete();
    await preferences.remove(completeMetadataKey(hash));
    await resetPartial(hash);
    onChanged?.call();
    return null;
  }

  Future<void> removeExpiredPartial(String hash) async {
    final file = await partialFile(hash);
    if (!await file.exists()) return;
    final modifiedAt = await file.lastModified();
    if (DateTime.now().difference(modifiedAt) <= cacheDuration) return;
    await resetPartial(hash);
  }

  Future<AudioPartialCacheMetadata?> readPartialMetadata(String hash) async {
    final preferences = await _preferencesProvider();
    final encoded = preferences.getString(partialMetadataKey(hash));
    if (encoded == null) return null;

    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return null;
      final rawLength = decoded['sourceLength'];
      final rawContentType = decoded['contentType'];
      return AudioPartialCacheMetadata(
        sourceLength: rawLength is int && rawLength >= 0 ? rawLength : null,
        contentType: rawContentType is String && rawContentType.isNotEmpty
            ? rawContentType
            : null,
      );
    } on FormatException {
      await preferences.remove(partialMetadataKey(hash));
      return null;
    }
  }

  Future<void> writePartialMetadata(
    String hash, {
    int? sourceLength,
    String? contentType,
  }) async {
    final previous = await readPartialMetadata(hash);
    final resolvedLength = sourceLength ?? previous?.sourceLength;
    final resolvedContentType = contentType ?? previous?.contentType;
    if (resolvedLength == null && resolvedContentType == null) return;

    final preferences = await _preferencesProvider();
    await preferences.setString(
      partialMetadataKey(hash),
      jsonEncode({
        if (resolvedLength != null) 'sourceLength': resolvedLength,
        if (resolvedContentType != null) 'contentType': resolvedContentType,
      }),
    );
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

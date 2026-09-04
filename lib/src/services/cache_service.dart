import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'storage_service.dart';
import 'download_service.dart';
import 'log_service.dart';
import '../models/download_task.dart';
import '../models/cache_inventory.dart';
import '../models/scan_models.dart';
import 'cache_inventory_scanner.dart';
import 'audio_cache_files.dart';
import 'audio_stream_cache.dart';
import 'conditional_get_cache.dart';
import 'remote_asset_cache.dart';
import 'remote_text_loader.dart';
import '../utils/encoding_utils.dart';

class CacheService {
  static final _log = LogService.instance;
  static final CacheInventoryScanner _inventoryScanner =
      CacheInventoryScanner();
  static final AudioCacheFiles audioCacheFiles = AudioCacheFiles(
    onChanged: invalidateCacheInventory,
  );
  static final FileRemoteAssetCache remoteAssetCache = FileRemoteAssetCache(
    directoryProvider: _getRemoteAssetCacheDirectory,
    onChanged: invalidateCacheInventory,
  );
  static final RemoteAssetImageCacheManager imageCacheManager =
      RemoteAssetImageCacheManager(
        cache: remoteAssetCache,
        accountScopeProvider: _currentAccountScope,
        legacyCacheManager: DefaultCacheManager(),
      );
  static final RemoteTextLoader remoteTextLoader = RemoteTextLoader(
    remoteAssetCache,
  );
  static Future<void>? _cacheMaintenance;
  // 缓存时长（过期后自动删除）
  static const Duration workDetailCacheDuration = Duration(
    hours: 24,
  ); // 作品详情缓存24小时（SharedPreferences）
  static const Duration workTracksCacheDuration = Duration(
    hours: 24,
  ); // 作品文件列表缓存24小时（包含URL，避免token过期）
  static const Duration fileCacheDuration = Duration(
    days: 30,
  ); // 文件资源（PDF等）缓存30天（基于hash，不受URL变化影响）
  static const Duration audioCacheDuration = Duration(
    days: 30,
  ); // 音频文件缓存30天（基于hash，不受URL变化影响）
  // 注意：图片缓存由 cached_network_image 包自己管理过期时间（默认7天）

  static Future<File> _audioFinalFile(String hash) async {
    return audioCacheFiles.finalFile(hash);
  }

  static Future<File> _audioTempFile(String hash) async {
    return audioCacheFiles.partialFile(hash);
  }

  static Future<void> resetAudioCachePartial(String hash) async {
    await audioCacheFiles.resetPartial(hash);
  }

  static Future<File> prepareAudioCacheTempFile(String hash) async {
    return audioCacheFiles.partialFile(hash, create: true);
  }

  static Future<String> audioCacheTempPath(String hash) async {
    return (await _audioTempFile(hash)).path;
  }

  static Future<String> audioCacheFinalPath(String hash) async {
    return (await _audioFinalFile(hash)).path;
  }

  static Future<bool> isAudioCachePath(String path, String hash) async {
    final finalPath = (await _audioFinalFile(hash)).path;
    return p.equals(p.normalize(path), p.normalize(finalPath));
  }

  static Future<bool> finalizeAudioCacheFile(
    String hash, {
    required int expectedSize,
  }) async {
    return audioCacheFiles.finalize(hash, expectedSize: expectedSize);
  }

  /// Removes only the streaming/preload cache for [hash]. Completed downloads
  /// are stored separately and are intentionally left untouched.
  static Future<void> invalidateAudioCache(String hash) async {
    await audioCacheFiles.invalidate(hash);
  }

  static void installImageCacheManager() {
    CachedNetworkImageProvider.defaultCacheManager = imageCacheManager;
  }

  static String? imageCacheKey({required String imageUrl, String? hash}) {
    final stableHash = hash?.trim() ?? '';
    if (stableHash.isNotEmpty) return 'content_image_$stableHash';
    final uri = Uri.tryParse(imageUrl);
    if (uri == null || !uri.hasScheme) return null;
    final identity = RemoteAssetKey.canonicalUri(uri);
    return 'content_image_uri_$identity';
  }

  static RemoteAssetKey remoteAssetKey({
    required RemoteAssetKind kind,
    required String identity,
    String? revision,
  }) {
    return RemoteAssetKey(
      serverScope: _currentServerScope(),
      kind: kind,
      identity: identity,
      revision: revision,
    );
  }

  static Future<File> getRemoteAsset({
    required String url,
    required RemoteAssetKind kind,
    required String identity,
    String? revision,
    String fileExtension = 'asset',
    bool allowRange = true,
    Duration maxAge = fileCacheDuration,
    bool forceRevalidate = false,
    Map<String, String> headers = const {},
  }) async {
    final request = RemoteAssetRequest(
      uri: Uri.parse(url),
      key: remoteAssetKey(kind: kind, identity: identity, revision: revision),
      fileExtension: fileExtension,
      allowRange: allowRange,
      maxAge: maxAge,
      forceRevalidate: forceRevalidate,
      headers: {...StorageService.serverCookieHeaders, ...headers},
    );
    final lease = remoteAssetCache.acquire(request);
    try {
      final file = await lease.file;
      unawaited(checkAndCleanCache());
      return file;
    } finally {
      await lease.release();
    }
  }

  // 缓存大小上限配置键
  static const String cacheSizeLimitKey = 'cache_size_limit_mb';
  static const int defaultCacheSizeLimitMB = 1000; // 默认1GB (1000MB)

  // 自动清理检查间隔（避免过于频繁检查）
  static const Duration autoCleanCheckInterval = Duration(minutes: 5);
  static const String lastCleanCheckTimeKey = 'last_clean_check_time';

  // 缓存作品详情
  static Future<void> cacheWorkDetail(
    int workId,
    Map<String, dynamic> workData, {
    required String scope,
  }) async {
    final prefs = await StorageService.getPrefs();
    final cacheKey = _scopedPreferenceKey('work_detail', scope, workId);
    final cacheTimeKey = _scopedPreferenceKey(
      'work_detail_time',
      scope,
      workId,
    );

    // 使用 JSON 编码保存完整数据
    await prefs.setString(cacheKey, jsonEncode(workData));
    await prefs.setInt(cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  // 获取缓存的作品详情
  static Future<Map<String, dynamic>?> getCachedWorkDetail(
    int workId, {
    required String scope,
  }) async {
    final prefs = await StorageService.getPrefs();
    final cacheKey = _scopedPreferenceKey('work_detail', scope, workId);
    final cacheTimeKey = _scopedPreferenceKey(
      'work_detail_time',
      scope,
      workId,
    );

    final cachedData = prefs.getString(cacheKey);
    final cacheTime = prefs.getInt(cacheTimeKey);

    if (cachedData == null || cacheTime == null) {
      return null;
    }

    // 检查是否过期
    final cacheDateTime = DateTime.fromMillisecondsSinceEpoch(cacheTime);
    if (DateTime.now().difference(cacheDateTime) > workDetailCacheDuration) {
      // 过期，删除缓存
      await prefs.remove(cacheKey);
      await prefs.remove(cacheTimeKey);
      return null;
    }

    // 返回解码后的完整数据
    try {
      return jsonDecode(cachedData) as Map<String, dynamic>;
    } catch (e) {
      _log.captureOutput('[Cache] 解码作品详情缓存失败: $e');
      // 数据损坏，删除缓存
      await prefs.remove(cacheKey);
      await prefs.remove(cacheTimeKey);
      return null;
    }
  }

  // 清除指定作品的详情缓存（用于收藏状态更新后强制刷新）
  static Future<void> invalidateWorkDetailCache(
    int workId, {
    required String scope,
  }) async {
    final prefs = await StorageService.getPrefs();
    final cacheKey = _scopedPreferenceKey('work_detail', scope, workId);
    final cacheTimeKey = _scopedPreferenceKey(
      'work_detail_time',
      scope,
      workId,
    );

    await prefs.remove(cacheKey);
    await prefs.remove(cacheTimeKey);
    _log.captureOutput('[Cache] 已清除作品详情缓存: $workId');
  }

  // 缓存作品文件列表
  static Future<void> cacheWorkTracks(
    int workId,
    String tracksJson, {
    required String scope,
  }) async {
    final prefs = await StorageService.getPrefs();
    final cacheKey = _scopedPreferenceKey('work_tracks', scope, workId);
    final cacheTimeKey = _scopedPreferenceKey(
      'work_tracks_time',
      scope,
      workId,
    );

    await prefs.setString(cacheKey, tracksJson);
    await prefs.setInt(cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  // 获取缓存的作品文件列表
  static Future<String?> getCachedWorkTracks(
    int workId, {
    required String scope,
  }) async {
    final prefs = await StorageService.getPrefs();
    final cacheKey = _scopedPreferenceKey('work_tracks', scope, workId);
    final cacheTimeKey = _scopedPreferenceKey(
      'work_tracks_time',
      scope,
      workId,
    );

    final cachedData = prefs.getString(cacheKey);
    final cacheTime = prefs.getInt(cacheTimeKey);

    if (cachedData == null || cacheTime == null) {
      return null;
    }

    // 检查是否过期
    final cacheDateTime = DateTime.fromMillisecondsSinceEpoch(cacheTime);
    if (DateTime.now().difference(cacheDateTime) > workTracksCacheDuration) {
      // 过期，删除缓存
      await prefs.remove(cacheKey);
      await prefs.remove(cacheTimeKey);
      return null;
    }

    return cachedData;
  }

  static String _scopedPreferenceKey(String prefix, String scope, int workId) {
    return '${prefix}_${Uri.encodeComponent(scope)}_$workId';
  }

  // 获取缓存的音频文件（基于 hash）
  static Future<String?> getCachedAudioFile(String hash) async {
    try {
      // 1. 先检查下载文件（优先级最高，因为是用户主动下载的）
      final downloadedFile = await _getDownloadedAudioFile(hash);
      if (downloadedFile != null) {
        _log.captureOutput('[Cache] 使用已下载的音频文件: $hash');
        return downloadedFile;
      }

      // 2. 检查流式播放缓存
      final cachedPath = await audioCacheFiles.completedPath(hash);
      if (cachedPath != null) {
        _log.captureOutput('[Cache] 使用缓存的音频文件: $hash');
      }
      return cachedPath;
    } catch (e) {
      _log.captureOutput('[Cache] 获取缓存音频文件失败: $e');
      return null;
    }
  }

  // 缓存文件资源（PDF等）
  static Future<String?> cacheFileResource({
    required int workId,
    required String hash,
    required String fileType,
    required String url,
    required Dio dio,
  }) async {
    try {
      final downloadedFile = await _getDownloadedFile(workId, hash, null);
      if (downloadedFile != null) {
        _log.captureOutput('[Cache] 使用已下载的文件: $hash');
        return downloadedFile;
      }
      final cached = await getCachedFileResource(
        workId: workId,
        hash: hash,
        fileType: fileType,
      );
      if (cached != null) return cached;

      final uri = Uri.parse(url);
      final extension = p.extension(uri.path).replaceFirst('.', '');
      final kind = fileType == 'image'
          ? RemoteAssetKind.contentImage
          : RemoteAssetKind.document;
      final requestHeaders = <String, String>{};
      for (final entry in dio.options.headers.entries) {
        if (entry.value != null) {
          requestHeaders[entry.key] = entry.value.toString();
        }
      }
      final file = await getRemoteAsset(
        url: url,
        kind: kind,
        identity: hash,
        fileExtension: extension.isEmpty ? fileType : extension,
        headers: requestHeaders,
      );
      return file.path;
    } catch (e) {
      _log.captureOutput('[Cache] 缓存文件失败: $e');
      return null;
    }
  }

  // 获取缓存的文件资源
  static Future<String?> getCachedFileResource({
    required int workId,
    required String hash,
    required String fileType,
  }) async {
    try {
      final downloadedFile = await _getDownloadedFile(workId, hash, null);
      if (downloadedFile != null) return downloadedFile;

      final kind = fileType == 'image'
          ? RemoteAssetKind.contentImage
          : RemoteAssetKind.document;
      final remote = await remoteAssetCache.find(
        remoteAssetKey(kind: kind, identity: hash),
      );
      if (remote != null) return remote.path;

      // Adopt the previous cache layout without forcing an upgrade download.
      final cacheDir = await _getCacheDirectory();
      final safeHash = hash.replaceAll('/', '_');
      final fileName = '${workId}_${safeHash}_$fileType';
      final filePath = p.join(cacheDir.path, fileName);

      final file = File(filePath);
      if (await file.exists()) {
        // 检查是否过期
        final prefs = await StorageService.getPrefs();
        final metaKey = 'file_cache_meta_${workId}_$safeHash';
        final cacheTime = prefs.getInt(metaKey);

        if (cacheTime != null) {
          final cacheDateTime = DateTime.fromMillisecondsSinceEpoch(cacheTime);
          if (DateTime.now().difference(cacheDateTime) < fileCacheDuration) {
            return filePath; // 未过期
          }
        }

        // 过期，删除
        await file.delete();
        await prefs.remove(metaKey);
      }

      return null;
    } catch (e) {
      _log.captureOutput('[Cache] 获取缓存文件失败: $e');
      return null;
    }
  }

  // 缓存文本内容
  static Future<void> cacheTextContent({
    required int workId,
    required String hash,
    required String content,
  }) async {
    try {
      final cacheDir = await _getCacheDirectory();
      final safeHash = hash.replaceAll('/', '_');
      final fileName = '${workId}_${safeHash}_text.txt';
      final filePath = p.join(cacheDir.path, fileName);

      final file = File(filePath);
      await file.writeAsString(content);
      invalidateCacheInventory();

      // 保存缓存元数据
      final prefs = await StorageService.getPrefs();
      final metaKey = 'text_cache_meta_${workId}_$safeHash';
      await prefs.setInt(metaKey, DateTime.now().millisecondsSinceEpoch);

      // 检查并自动清理缓存
      await checkAndCleanCache();
    } catch (e) {
      _log.captureOutput('[Cache] 缓存文本失败: $e');
    }
  }

  // 获取缓存的文本内容
  static Future<String?> getCachedTextContent({
    required int workId,
    required String hash,
    String? fileName, // 添加可选的文件名参数，用于查找手动复制的文件
  }) async {
    try {
      // 1. 先检查下载文件
      final downloadedFile = await _getDownloadedFile(workId, hash, fileName);
      if (downloadedFile != null) {
        final file = File(downloadedFile);
        if (await file.exists()) {
          _log.captureOutput('[Cache] 从已下载的文件读取文本内容: $hash');
          // 使用智能编码检测读取文件
          return await EncodingUtils.readFileAsString(file);
        }
      }

      // 2. 检查缓存文件
      final cacheDir = await _getCacheDirectory();
      final safeHash = hash.replaceAll('/', '_');
      final cacheFileName = '${workId}_${safeHash}_text.txt';
      final filePath = p.join(cacheDir.path, cacheFileName);

      final file = File(filePath);
      if (await file.exists()) {
        // 检查是否过期
        final prefs = await StorageService.getPrefs();
        final metaKey = 'text_cache_meta_${workId}_$safeHash';
        final cacheTime = prefs.getInt(metaKey);

        if (cacheTime != null) {
          final cacheDateTime = DateTime.fromMillisecondsSinceEpoch(cacheTime);
          if (DateTime.now().difference(cacheDateTime) < fileCacheDuration) {
            // 使用智能编码检测读取缓存文件
            return await EncodingUtils.readFileAsString(file); // 未过期
          }
        }

        // 过期，删除
        await file.delete();
        await prefs.remove(metaKey);
      }

      return null;
    } catch (e) {
      _log.captureOutput('[Cache] 获取缓存文本失败: $e');
      return null;
    }
  }

  // 清除所有缓存
  static Future<void> clearAllCache() async {
    try {
      await ConditionalGetCache.invalidateProcessMemory();
      await remoteAssetCache.clearInactive();

      // 1. 清除没有活动读取或写入的文件缓存（PDF、文本、图片等）
      final cacheDir = await _getCacheDirectory();
      if (await cacheDir.exists()) {
        await _deleteInactiveCacheTree(cacheDir);
      }

      // 2. 清除音频缓存
      await clearAudioCache();

      // 3. 清除图片缓存
      await clearImageCache();

      // 4. 清除 SharedPreferences 中的缓存元数据
      final prefs = await StorageService.getPrefs();
      final keys = prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith('work_detail_') ||
            key.startsWith('work_tracks_') ||
            key.startsWith('file_cache_meta_') ||
            key.startsWith('text_cache_meta_')) {
          await prefs.remove(key);
        }
      }

      _log.captureOutput('[Cache] 所有缓存已清除');
      invalidateCacheInventory();
    } catch (e) {
      _log.captureOutput('[Cache] 清除缓存失败: $e');
      rethrow;
    }
  }

  // 清除音频缓存
  static Future<void> clearAudioCache() async {
    try {
      // Stop speculative writers first. Playback writers remain available so
      // clearing the cache cannot interrupt the track the user is hearing.
      await AudioStreamCache.cancelAllPreloads();

      // 1. 清除自定义音频缓存（基于 hash）
      final customAudioCacheDir = await _getAudioCacheDirectory();
      final retainedSafeHashes = <String>{};
      if (await customAudioCacheDir.exists()) {
        await for (final entity in customAudioCacheDir.list(recursive: true)) {
          if (entity is! File) continue;
          if (AudioStreamCache.isCachePathActive(entity.path)) {
            final fileName = p.basename(entity.path);
            retainedSafeHashes.add(
              fileName
                  .replaceFirst(RegExp(r'\.audio\.part$'), '')
                  .replaceFirst(RegExp(r'\.audio$'), ''),
            );
            continue;
          }
          await entity.delete();
        }
        _log.captureOutput('[Cache] 自定义音频缓存已清除');
      }

      // 2. 清除 SharedPreferences 中的音频缓存元数据
      final prefs = await StorageService.getPrefs();
      final keys = prefs.getKeys();
      for (final key in keys) {
        final prefix = key.startsWith('audio_cache_meta_')
            ? 'audio_cache_meta_'
            : key.startsWith('audio_partial_meta_')
            ? 'audio_partial_meta_'
            : null;
        if (prefix == null) continue;
        final safeHash = key.substring(prefix.length);
        if (!retainedSafeHashes.contains(safeHash)) await prefs.remove(key);
      }

      // 3. 清除 just_audio 的旧缓存（如果存在）
      final appCacheDir = await getApplicationCacheDirectory();
      final justAudioCacheDir = Directory(
        p.join(appCacheDir.path, 'just_audio_cache'),
      );
      if (await justAudioCacheDir.exists()) {
        await justAudioCacheDir.delete(recursive: true);
        _log.captureOutput('[Cache] just_audio 缓存已清除');
      }
      invalidateCacheInventory();
    } catch (e) {
      _log.captureOutput('[Cache] 清除音频缓存失败: $e');
    }
  }

  // 清除图片缓存
  static Future<void> clearImageCache() async {
    try {
      final appCacheDir = await getApplicationCacheDirectory();
      final imageCacheDir = Directory(
        p.join(appCacheDir.path, 'libCachedImageData'),
      );

      if (await imageCacheDir.exists()) {
        await imageCacheDir.delete(recursive: true);
        _log.captureOutput('[Cache] 图片缓存已清除');
      }
      invalidateCacheInventory();
    } catch (e) {
      _log.captureOutput('[Cache] 清除图片缓存失败: $e');
    }
  }

  // 获取缓存大小
  static Future<int> getCacheSize() async {
    try {
      _log.captureOutput('[Cache] 获取缓存大小');
      return (await getCacheInventory()).totalBytes;
    } catch (e) {
      _log.captureOutput('[Cache] 获取缓存大小失败: $e');
      return 0;
    }
  }

  static Future<CacheInventory> getCacheInventory({
    bool force = false,
    ScanCancellationToken? cancellationToken,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    final appCacheDir = await getApplicationCacheDirectory();
    final roots = <CacheEntryKind, String>{
      CacheEntryKind.general: (await _getCacheDirectory()).path,
      CacheEntryKind.audio: (await _getAudioCacheDirectory()).path,
      CacheEntryKind.legacyAudio: p.join(appCacheDir.path, 'just_audio_cache'),
      CacheEntryKind.image: p.join(appCacheDir.path, 'libCachedImageData'),
    };
    final preferencesBytes = await _getSharedPreferencesCacheSize();
    final result = await _inventoryScanner.scan(
      roots: roots,
      preferencesBytes: preferencesBytes,
      force: force,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
    return result.value;
  }

  static void invalidateCacheInventory() => _inventoryScanner.invalidate();

  // 获取 SharedPreferences 缓存大小（估算）
  static Future<int> _getSharedPreferencesCacheSize() async {
    try {
      final prefs = await StorageService.getPrefs();
      final keys = prefs.getKeys();
      int estimatedSize = 0;

      for (final key in keys) {
        // 只统计缓存相关的键
        if (key.startsWith('work_detail_') ||
            key.startsWith('work_tracks_') ||
            key.startsWith('file_cache_meta_') ||
            key.startsWith('text_cache_meta_') ||
            key.startsWith('audio_cache_meta_') ||
            key.startsWith('audio_partial_meta_')) {
          // 估算：键名长度 + 值长度
          estimatedSize += key.length;

          final value = prefs.get(key);
          if (value is String) {
            estimatedSize += value.length;
          } else if (value is int) {
            estimatedSize += 8; // int 通常 8 字节
          }
        }
      }

      return estimatedSize;
    } catch (e) {
      _log.captureOutput('[Cache] 获取 SharedPreferences 缓存大小失败: $e');
      return 0;
    }
  }

  // 获取缓存目录
  static Future<Directory> _getCacheDirectory() async {
    final appCacheDir = await getApplicationCacheDirectory();
    final cacheDir = Directory(p.join(appCacheDir.path, 'kikoeru_cache'));

    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    return cacheDir;
  }

  static Future<void> _deleteInactiveCacheTree(Directory root) async {
    final directories = <Directory>[];
    await for (final entity in root.list(recursive: true)) {
      if (entity is Directory) {
        directories.add(entity);
      } else if (entity is File &&
          !FileRemoteAssetCache.isCachePathActive(entity.path)) {
        try {
          await entity.delete();
        } on FileSystemException {
          // A visible consumer may have acquired the file during cleanup.
        }
      }
    }
    directories.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final directory in directories) {
      try {
        if (await directory.list().isEmpty) await directory.delete();
      } on FileSystemException {
        // The directory is still in use or gained a new entry.
      }
    }
  }

  static Future<Directory> _getRemoteAssetCacheDirectory() async {
    final root = await _getCacheDirectory();
    final directory = Directory(p.join(root.path, 'remote_assets'));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  static Future<Directory> getDerivedImageCacheDirectory() async {
    final root = await _getCacheDirectory();
    final directory = Directory(p.join(root.path, 'derived_images'));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  /// Persistent validator/body storage used by [ConditionalGetCache].
  ///
  /// Keeping it below the general cache root means the existing 1 GB budget,
  /// inventory, and clear-cache behavior apply without another cache policy.
  static Future<Directory> getApiResponseCacheDirectory() async {
    final root = await _getCacheDirectory();
    final directory = Directory(p.join(root.path, 'api_responses'));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  static String? _currentAccountScope() {
    try {
      final user = StorageService.getMap('current_user');
      final name = user?['name'];
      return name is String && name.isNotEmpty ? name : null;
    } catch (_) {
      return null;
    }
  }

  static String _currentServerScope() {
    String rawHost;
    try {
      rawHost = StorageService.getString('server_host') ?? 'local';
    } catch (_) {
      rawHost = 'local';
    }
    final uri = Uri.tryParse(
      rawHost.contains('://') ? rawHost : 'https://$rawHost',
    );
    final account = _currentAccountScope();
    if (uri == null || uri.host.isEmpty) {
      return account == null ? rawHost : '$rawHost|$account';
    }
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    final port = uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';
    final basePath = uri.path == '/'
        ? ''
        : uri.path.replaceFirst(RegExp(r'/$'), '');
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}$port'
        '$basePath'
        '${account == null ? '' : '|$account'}';
  }

  // 获取音频缓存目录
  static Future<Directory> _getAudioCacheDirectory() async {
    return audioCacheFiles.directory();
  }

  // 设置缓存大小上限（MB）
  static Future<void> setCacheSizeLimit(int limitMB) async {
    final prefs = await StorageService.getPrefs();
    await prefs.setInt(cacheSizeLimitKey, limitMB);
  }

  // 获取缓存大小上限（MB）
  static Future<int> getCacheSizeLimit() async {
    final prefs = await StorageService.getPrefs();
    return prefs.getInt(cacheSizeLimitKey) ?? defaultCacheSizeLimitMB;
  }

  // 检查并自动清理缓存（如果超过上限）
  // 使用时间间隔控制，避免过于频繁检查
  static Future<void> checkAndCleanCache({bool force = false}) {
    final existing = _cacheMaintenance;
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = _checkAndCleanCache(force: force).whenComplete(() {
      if (identical(_cacheMaintenance, operation)) _cacheMaintenance = null;
    });
    _cacheMaintenance = operation;
    return operation;
  }

  static Future<void> _checkAndCleanCache({required bool force}) async {
    try {
      // 如果不是强制检查，先判断是否需要检查
      if (!force) {
        final prefs = await StorageService.getPrefs();
        final lastCheckTime = prefs.getInt(lastCleanCheckTimeKey);

        if (lastCheckTime != null) {
          final lastCheck = DateTime.fromMillisecondsSinceEpoch(lastCheckTime);
          final timeSinceLastCheck = DateTime.now().difference(lastCheck);

          // 如果距离上次检查不到5分钟，跳过检查
          if (timeSinceLastCheck < autoCleanCheckInterval) {
            return;
          }
        }

        // 更新最后检查时间
        await prefs.setInt(
          lastCleanCheckTimeKey,
          DateTime.now().millisecondsSinceEpoch,
        );
      }

      // A single inventory feeds expiration, size display and LRU eviction.
      var inventory = await getCacheInventory(force: true);
      final expiredPaths = await _cleanExpiredCacheFiles(inventory);
      inventory = inventory.withoutPaths(expiredPaths);

      // 2. 再检查大小，如果超过上限则清理旧文件（基于大小）
      final currentSize = inventory.totalBytes;
      final limitMB = await getCacheSizeLimit();
      final limitBytes = limitMB * 1024 * 1024;

      if (currentSize > limitBytes) {
        _log.captureOutput(
          '[Cache] 缓存大小 ${_formatBytes(currentSize)} 超过上限 ${limitMB}MB，开始清理...',
        );
        await _cleanOldCacheFiles(limitBytes, inventory);
      }
      if (expiredPaths.isNotEmpty || currentSize > limitBytes) {
        invalidateCacheInventory();
      }
    } catch (e) {
      _log.captureOutput('[Cache] 自动清理缓存失败: $e');
    }
  }

  // 清理过期的缓存文件（基于时间）
  static Future<Set<String>> _cleanExpiredCacheFiles(
    CacheInventory inventory,
  ) async {
    final deletedPaths = <String>{};
    try {
      final now = DateTime.now();
      int deletedCount = 0;
      for (final entry in inventory.entries) {
        if (AudioStreamCache.isCachePathActive(entry.path) ||
            FileRemoteAssetCache.isCachePathActive(entry.path)) {
          continue;
        }
        final maxAge = switch (entry.kind) {
          CacheEntryKind.general => fileCacheDuration,
          CacheEntryKind.audio ||
          CacheEntryKind.legacyAudio => audioCacheDuration,
          CacheEntryKind.image => null,
        };
        if (maxAge == null || now.difference(entry.lastModified) <= maxAge) {
          continue;
        }
        final file = File(entry.path);
        try {
          if (await file.exists()) await file.delete();
          deletedPaths.add(entry.path);
          deletedCount++;
          final fileName = p.basename(entry.path);
          if (entry.kind == CacheEntryKind.general) {
            await _removeMetadataForFile(fileName);
          } else if (entry.kind == CacheEntryKind.audio) {
            await audioCacheFiles.removeMetadataForPath(entry.path);
          }
        } on FileSystemException {
          // The file may have been concurrently evicted by its cache manager.
        }
      }

      // 3. 清理过期的 SharedPreferences 作品详情缓存
      final prefsDeletedCount = await _cleanExpiredSharedPreferences();
      deletedCount += prefsDeletedCount;

      // 4. 图片缓存由 cached_network_image 自己管理过期时间，不需要手动清理

      if (deletedCount > 0) {
        _log.captureOutput('[Cache] 已清理 $deletedCount 个过期缓存项');
      }
    } catch (e) {
      _log.captureOutput('[Cache] 清理过期缓存文件失败: $e');
    }
    return deletedPaths;
  }

  // 清理过期的 SharedPreferences 缓存
  static Future<int> _cleanExpiredSharedPreferences() async {
    try {
      final prefs = await StorageService.getPrefs();
      final keys = prefs.getKeys();
      final now = DateTime.now();
      int deletedCount = 0;

      for (final key in keys) {
        // 检查作品详情缓存是否过期
        if (key.startsWith('work_detail_time_')) {
          final cacheTime = prefs.getInt(key);
          if (cacheTime != null) {
            final cacheDateTime = DateTime.fromMillisecondsSinceEpoch(
              cacheTime,
            );
            if (now.difference(cacheDateTime) > workDetailCacheDuration) {
              // 过期，删除缓存数据和时间戳
              final workId = key.replaceFirst('work_detail_time_', '');
              await prefs.remove('work_detail_$workId');
              await prefs.remove(key);
              deletedCount += 2;
            }
          }
        }
        // 检查作品文件列表缓存是否过期
        else if (key.startsWith('work_tracks_time_')) {
          final cacheTime = prefs.getInt(key);
          if (cacheTime != null) {
            final cacheDateTime = DateTime.fromMillisecondsSinceEpoch(
              cacheTime,
            );
            if (now.difference(cacheDateTime) > workTracksCacheDuration) {
              // 过期，删除缓存数据和时间戳
              final workId = key.replaceFirst('work_tracks_time_', '');
              await prefs.remove('work_tracks_$workId');
              await prefs.remove(key);
              deletedCount += 2;
            }
          }
        }
        // 文件和文本的元数据会在清理文件时一起删除，这里不需要单独处理
      }

      return deletedCount;
    } catch (e) {
      _log.captureOutput('[Cache] 清理过期 SharedPreferences 失败: $e');
      return 0;
    }
  }

  // 清理旧缓存文件，直到降低到上限的80%
  static Future<void> _cleanOldCacheFiles(
    int limitBytes,
    CacheInventory inventory,
  ) async {
    try {
      final targetSize = (limitBytes * 0.8).toInt();
      final fileList = List<CacheInventoryEntry>.of(inventory.entries)
        ..sort((a, b) => a.lastModified.compareTo(b.lastModified));
      var currentSize = inventory.totalBytes;

      // 删除旧文件直到降低到目标大小
      int deletedCount = 0;
      for (final entry in fileList) {
        if (currentSize <= targetSize) {
          break;
        }
        if (AudioStreamCache.isCachePathActive(entry.path) ||
            FileRemoteAssetCache.isCachePathActive(entry.path)) {
          continue;
        }

        final file = File(entry.path);
        if (!await file.exists()) continue;
        await file.delete();
        currentSize -= entry.size;
        deletedCount++;

        final fileName = p.basename(entry.path);
        if (entry.kind == CacheEntryKind.general) {
          await _removeMetadataForFile(fileName);
        } else if (entry.kind == CacheEntryKind.audio) {
          await audioCacheFiles.removeMetadataForPath(entry.path);
        }
      }

      _log.captureOutput(
        '[Cache] 已删除 $deletedCount 个旧缓存文件，当前大小: ${_formatBytes(currentSize)}',
      );
    } catch (e) {
      _log.captureOutput('[Cache] 清理旧缓存文件失败: $e');
    }
  }

  // 删除文件对应的元数据
  static Future<void> _removeMetadataForFile(String fileName) async {
    try {
      final prefs = await StorageService.getPrefs();

      // 从文件名解析出 workId 和 hash
      // 文件名格式: {workId}_{safeHash}_{fileType}
      final parts = fileName.split('_');
      if (parts.length >= 2) {
        final workId = parts[0];
        final safeHash = parts[1];

        // 删除可能的元数据键
        await prefs.remove('file_cache_meta_${workId}_$safeHash');
        await prefs.remove('text_cache_meta_${workId}_$safeHash');
      }
    } catch (e) {
      _log.captureOutput('[Cache] 删除元数据失败: $e');
    }
  }

  // 从下载服务中获取已下载的音频文件
  static Future<String?> _getDownloadedAudioFile(String hash) async {
    try {
      final downloadService = DownloadService.instance;
      final tasks = downloadService.tasks;

      // 查找已完成的下载任务
      for (final task in tasks) {
        if (task.hash == hash && task.status == DownloadStatus.completed) {
          final filePath = await downloadService.getDownloadedFilePath(
            task.workId,
            hash,
          );
          if (filePath != null) {
            final file = File(filePath);
            if (await file.exists()) {
              return filePath;
            }
          }
        }
      }

      return null;
    } catch (e) {
      _log.captureOutput('[Cache] 获取下载文件失败: $e');
      return null;
    }
  }

  // 从下载服务中获取已下载的文件（通用）
  static Future<String?> _getDownloadedFile(
    int workId,
    String hash,
    String? fileName,
  ) async {
    try {
      final downloadService = DownloadService.instance;

      // 处理可能的 workId/hash 格式
      String actualHash = hash;
      if (hash.contains('/')) {
        final parts = hash.split('/');
        if (parts.length == 2) {
          actualHash = parts[1]; // 使用文件hash部分
        }
      }

      // 1. 先检查 DownloadService 管理的下载任务
      final filePath = await downloadService.getDownloadedFilePath(
        workId,
        actualHash,
      );
      if (filePath != null) {
        final file = File(filePath);
        if (await file.exists()) {
          return filePath;
        }
      }

      // 2. 如果提供了文件名，检查手动复制的文件
      if (fileName != null && fileName.isNotEmpty) {
        try {
          final downloadDir = await downloadService.getDownloadDirectory();
          final workDir = Directory(
            p.join(downloadDir.path, workId.toString()),
          );

          if (await workDir.exists()) {
            // 递归查找匹配文件名的文件
            await for (final entity in workDir.list(recursive: true)) {
              if (entity is File) {
                final entityFileName = entity.path
                    .split(Platform.pathSeparator)
                    .last;
                // 精确匹配文件名
                if (entityFileName == fileName) {
                  _log.captureOutput('[Cache] 找到手动复制的文件: ${entity.path}');
                  return entity.path;
                }
              }
            }
          }
        } catch (e) {
          _log.captureOutput('[Cache] 检查手动复制文件失败: $e');
        }
      }

      return null;
    } catch (e) {
      _log.captureOutput('[Cache] 获取下载文件失败: $e');
      return null;
    }
  }

  // 格式化字节大小为可读字符串
  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  // 获取格式化的缓存大小字符串
  static Future<String> getFormattedCacheSize() async {
    final size = await getCacheSize();
    return _formatBytes(size);
  }
}

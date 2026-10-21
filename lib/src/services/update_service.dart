import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef FileOpener = Future<OpenResult> Function(
  String filePath, {
  String? type,
});

typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  ProcessStartMode mode,
  bool runInShell,
});

/// Service to check for app updates from GitHub releases and install them.
class UpdateService {
  static const String _githubApiUrl =
      'https://api.github.com/repos/Shiniester/KikoFlu/releases/latest';
  static const String _releasePageUrl =
      'https://github.com/Shiniester/KikoFlu/releases/latest';

  static const String _keyLastCheckedVersion = 'last_checked_version';
  static const String _keyLastNotifiedVersion = 'last_notified_version';
  static const String _keyLastCheckTime = 'last_check_time';
  static const String _keyLastReleaseNotes = 'last_release_notes';
  static const String _keyLastDownloadUrl = 'last_download_url';
  static const String _keyLastAssetName = 'last_asset_name';
  static const String _keyLastAssetSize = 'last_asset_size';

  final Dio _dio;
  final FileOpener _openFile;
  final ProcessStarter _processStarter;
  final Future<Directory> Function() _getTempDirectory;

  UpdateService({
    Dio? dio,
    FileOpener? openFile,
    ProcessStarter? processStarter,
    Future<Directory> Function()? getTempDirectory,
  })  : _dio = dio ?? Dio(),
        _openFile = openFile ?? OpenFilex.open,
        _processStarter = processStarter ?? Process.start,
        _getTempDirectory = getTempDirectory ?? getTemporaryDirectory;

  /// Check for updates silently (no user feedback on failure)
  /// Returns update info if a new version is available, null otherwise
  Future<UpdateInfo?> checkForUpdates({bool force = false}) async {
    try {
      // Get current version
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // Check if we should skip the check (recently checked)
      if (!force) {
        final prefs = await SharedPreferences.getInstance();
        final lastCheckTime = prefs.getInt(_keyLastCheckTime) ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        // Skip if checked within last hour
        if (now - lastCheckTime < 3600000) {
          final lastCheckedVersion = prefs.getString(_keyLastCheckedVersion);
          if (lastCheckedVersion != null &&
              lastCheckedVersion != currentVersion) {
            return UpdateInfo(
              latestVersion: lastCheckedVersion,
              currentVersion: currentVersion,
              releaseUrl: _releasePageUrl,
              hasNewVersion: _compareVersions(currentVersion, lastCheckedVersion) < 0,
              releaseNotes: prefs.getString(_keyLastReleaseNotes),
              downloadUrl: prefs.getString(_keyLastDownloadUrl),
              assetName: prefs.getString(_keyLastAssetName),
              assetSize: prefs.getInt(_keyLastAssetSize),
            );
          }
          return null;
        }
      }

      // Make API request with timeout
      final response = await _dio.get(
        _githubApiUrl,
        options: Options(
          headers: {
            'Accept': 'application/vnd.github.v3+json',
          },
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data;
        if (data is! Map<String, dynamic>) {
          return null;
        }

        // Only track official releases (not draft and not prerelease)
        final isDraft = data['draft'] as bool? ?? false;
        final isPrerelease = data['prerelease'] as bool? ?? false;
        if (isDraft || isPrerelease) {
          return null;
        }

        final tagName = data['tag_name'] as String? ?? '';

        // Extract version from tag_name (remove 'v' prefix and anything after '(')
        // Examples: 'v1.0.6' -> '1.0.6', 'v1.0.6(1024)' -> '1.0.6', '1.0.6' -> '1.0.6'
        String latestVersion = tagName
            .replaceFirst('v', '')
            .replaceFirst(RegExp(r'\(.*\)'), '')
            .trim();

        if (latestVersion.isEmpty) {
          return null;
        }

        final releaseNotes = data['body'] as String?;
        final releaseUrl = data['html_url'] as String? ?? _releasePageUrl;
        final assets = data['assets'] as List<dynamic>? ?? [];
        final matchedAsset = findPlatformAsset(assets);

        String? downloadUrl;
        String? assetName;
        int? assetSize;

        if (matchedAsset != null) {
          downloadUrl = matchedAsset['browser_download_url'] as String?;
          assetName = matchedAsset['name'] as String?;
          assetSize = matchedAsset['size'] as int?;
        }

        // Save check time and version
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_keyLastCheckedVersion, latestVersion);
        await prefs.setInt(
            _keyLastCheckTime, DateTime.now().millisecondsSinceEpoch);
        if (releaseNotes != null) {
          await prefs.setString(_keyLastReleaseNotes, releaseNotes);
        }
        if (downloadUrl != null) {
          await prefs.setString(_keyLastDownloadUrl, downloadUrl);
        }
        if (assetName != null) {
          await prefs.setString(_keyLastAssetName, assetName);
        }
        if (assetSize != null) {
          await prefs.setInt(_keyLastAssetSize, assetSize);
        }

        // Compare versions
        final hasNewVersion =
            _compareVersions(currentVersion, latestVersion) < 0;

        return UpdateInfo(
          latestVersion: latestVersion,
          currentVersion: currentVersion,
          releaseUrl: releaseUrl,
          hasNewVersion: hasNewVersion,
          releaseNotes: releaseNotes,
          downloadUrl: downloadUrl,
          assetName: assetName,
          assetSize: assetSize,
        );
      }
    } catch (e) {
      // Silent failure - no user notification
    }
    return null;
  }

  /// Match the corresponding release asset for the current operating system.
  Map<String, dynamic>? findPlatformAsset(
    List<dynamic> assets, {
    String? targetPlatform,
  }) {
    final os = targetPlatform ?? (kIsWeb ? 'web' : Platform.operatingSystem);
    final assetList = assets.whereType<Map<String, dynamic>>().toList();
    if (assetList.isEmpty) return null;

    Map<String, dynamic>? result;
    switch (os) {
      case 'android':
        result = assetList.firstWhere(
          (a) {
            final name = (a['name'] as String? ?? '').toLowerCase();
            return name.endsWith('.apk') && name.contains('arm64-v8a');
          },
          orElse: () => assetList.firstWhere(
            (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.apk'),
            orElse: () => <String, dynamic>{},
          ),
        );
        break;
      case 'windows':
        result = assetList.firstWhere(
          (a) {
            final name = (a['name'] as String? ?? '').toLowerCase();
            return name.contains('setup') && name.endsWith('.exe');
          },
          orElse: () => assetList.firstWhere(
            (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.exe'),
            orElse: () => <String, dynamic>{},
          ),
        );
        break;
      case 'macos':
        result = assetList.firstWhere(
          (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.dmg'),
          orElse: () => <String, dynamic>{},
        );
        break;
      case 'linux':
        result = assetList.firstWhere(
          (a) =>
              (a['name'] as String? ?? '').toLowerCase().endsWith('.tar.gz'),
          orElse: () => <String, dynamic>{},
        );
        break;
      case 'ios':
        result = assetList.firstWhere(
          (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.ipa'),
          orElse: () => <String, dynamic>{},
        );
        break;
      default:
        return null;
    }

    return result.isNotEmpty ? result : null;
  }

  /// Download the update package to the local updates directory.
  Future<File> downloadUpdate({
    required String downloadUrl,
    required String fileName,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    Directory? targetDirectory,
  }) async {
    final saveDir = targetDirectory ??
        Directory(p.join((await _getTempDirectory()).path, 'updates'));
    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }

    final savePath = p.join(saveDir.path, fileName);
    final tempPath = '$savePath.part';
    final tempFile = File(tempPath);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    await _dio.download(
      downloadUrl,
      tempPath,
      cancelToken: cancelToken,
      onReceiveProgress: onProgress,
    );

    final downloadedPart = File(tempPath);
    if (!await downloadedPart.exists() || await downloadedPart.length() == 0) {
      throw FileSystemException('Downloaded file is empty or missing', tempPath);
    }

    final targetFile = File(savePath);
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    return downloadedPart.rename(savePath);
  }

  /// Launch or install the downloaded update package.
  Future<bool> installUpdate(
    String filePath, {
    String? targetPlatform,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return false;
    }

    final os = targetPlatform ?? (kIsWeb ? 'web' : Platform.operatingSystem);

    if (os == 'windows' && filePath.endsWith('.exe')) {
      try {
        await _processStarter(
          filePath,
          [],
          runInShell: true,
          mode: ProcessStartMode.detached,
        );
        return true;
      } catch (_) {
        final result = await _openFile(filePath);
        return result.type == ResultType.done;
      }
    }

    if (os == 'android') {
      final result = await _openFile(
        filePath,
        type: 'application/vnd.android.package-archive',
      );
      return result.type == ResultType.done;
    }

    final result = await _openFile(filePath);
    return result.type == ResultType.done;
  }

  /// Check if the red dot should be shown for the current latest version
  /// Returns true if a new version exists and hasn't been notified yet
  Future<bool> shouldShowRedDot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastCheckedVersion = prefs.getString(_keyLastCheckedVersion);
      final lastNotifiedVersion = prefs.getString(_keyLastNotifiedVersion);

      if (lastCheckedVersion == null || lastCheckedVersion.isEmpty) {
        return false;
      }

      // Get current version
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // Show red dot if there's a new version and it hasn't been notified
      return _compareVersions(currentVersion, lastCheckedVersion) < 0 &&
          lastCheckedVersion != lastNotifiedVersion;
    } catch (e) {
      return false;
    }
  }

  /// Mark the current new version as notified (hide red dot)
  Future<void> markAsNotified() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastCheckedVersion = prefs.getString(_keyLastCheckedVersion);
      if (lastCheckedVersion != null) {
        await prefs.setString(_keyLastNotifiedVersion, lastCheckedVersion);
      }
    } catch (e) {
      // Silent failure
    }
  }

  /// Compare two version strings
  /// Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
  int _compareVersions(String v1, String v2) {
    final parts1 = v1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final parts2 = v2.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    final maxLength =
        parts1.length > parts2.length ? parts1.length : parts2.length;

    for (int i = 0; i < maxLength; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;

      if (p1 < p2) return -1;
      if (p1 > p2) return 1;
    }

    return 0;
  }

  /// Clear all update check data
  Future<void> clearUpdateData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyLastCheckedVersion);
      await prefs.remove(_keyLastNotifiedVersion);
      await prefs.remove(_keyLastCheckTime);
      await prefs.remove(_keyLastReleaseNotes);
      await prefs.remove(_keyLastDownloadUrl);
      await prefs.remove(_keyLastAssetName);
      await prefs.remove(_keyLastAssetSize);
    } catch (e) {
      // Silent failure
    }
  }
}

/// Information about available updates
class UpdateInfo {
  final String latestVersion;
  final String currentVersion;
  final String releaseUrl;
  final bool hasNewVersion;
  final String? releaseNotes;
  final String? downloadUrl;
  final String? assetName;
  final int? assetSize;

  const UpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.releaseUrl,
    required this.hasNewVersion,
    this.releaseNotes,
    this.downloadUrl,
    this.assetName,
    this.assetSize,
  });

  @override
  String toString() {
    return 'UpdateInfo(latest: $latestVersion, current: $currentVersion, hasNew: $hasNewVersion, downloadUrl: $downloadUrl, assetName: $assetName, size: $assetSize)';
  }
}

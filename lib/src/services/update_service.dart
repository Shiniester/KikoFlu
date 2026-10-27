import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum UpdateChannel { stable, beta }

typedef FileOpener =
    Future<OpenResult> Function(String filePath, {String? type});

typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      ProcessStartMode mode,
      bool runInShell,
    });

/// Service to check for app updates from GitHub releases and install them.
class UpdateService {
  static const String _stableGithubApiUrl =
      'https://api.github.com/repos/Shiniester/KikoFlu/releases/latest';
  static const String _betaGithubApiUrl =
      'https://api.github.com/repos/Shiniester/KikoFlu/releases';
  static const String _releasePageUrl =
      'https://github.com/Shiniester/KikoFlu/releases/latest';
  static const String _betaPackageName = 'com.meteor.kikoeruflutter.beta';

  static const String _keyUpdateChannel = 'update_channel';
  static const String _keyLastCheckedVersion = 'last_checked_version';
  static const String _keyLastNotifiedVersion = 'last_notified_version';
  static const String _keyLastCheckTime = 'last_check_time';
  static const String _keyLastReleaseNotes = 'last_release_notes';
  static const String _keyLastDownloadUrl = 'last_download_url';
  static const String _keyLastAssetName = 'last_asset_name';
  static const String _keyLastAssetSize = 'last_asset_size';
  static const String _keyLastReleaseUrl = 'last_release_url';

  int _channelRevision = 0;

  int get channelRevision => _channelRevision;

  final Dio _dio;
  final FileOpener _openFile;
  final ProcessStarter _processStarter;
  final Future<Directory> Function() _getTempDirectory;

  UpdateService({
    Dio? dio,
    FileOpener? openFile,
    ProcessStarter? processStarter,
    Future<Directory> Function()? getTempDirectory,
  }) : _dio = dio ?? Dio(),
       _openFile = openFile ?? OpenFilex.open,
       _processStarter = processStarter ?? Process.start,
       _getTempDirectory = getTempDirectory ?? getTemporaryDirectory;

  Future<UpdateChannel> getUpdateChannel({String? packageName}) async {
    final prefs = await SharedPreferences.getInstance();
    final savedChannel = prefs.getString(_keyUpdateChannel);
    for (final channel in UpdateChannel.values) {
      if (savedChannel == channel.name) return channel;
    }

    packageName ??= (await PackageInfo.fromPlatform()).packageName;
    return _installedChannel(packageName);
  }

  Future<void> setUpdateChannel(UpdateChannel channel) async {
    _channelRevision++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUpdateChannel, channel.name);
  }

  /// Returns the selected channel's release when one is available.
  /// Request failures are propagated to the caller.
  Future<UpdateInfo?> checkForUpdates({
    bool force = false,
    UpdateChannel? channel,
  }) async {
    final requestRevision = _channelRevision;
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version;
    final installedChannel = _installedChannel(packageInfo.packageName);
    final prefs = await SharedPreferences.getInstance();
    final selectedChannel =
        channel ?? await getUpdateChannel(packageName: packageInfo.packageName);
    final isCrossChannel = selectedChannel != installedChannel;
    final versionKey = _cacheKey(_keyLastCheckedVersion, selectedChannel);
    final checkedAtKey = _cacheKey(_keyLastCheckTime, selectedChannel);
    final now = DateTime.now().millisecondsSinceEpoch;

    if (!force && now - (prefs.getInt(checkedAtKey) ?? 0) < 3600000) {
      final lastCheckedVersion = prefs.getString(versionKey);
      if (lastCheckedVersion == null || lastCheckedVersion.isEmpty) return null;
      if (lastCheckedVersion == currentVersion && !isCrossChannel) return null;

      return UpdateInfo(
        latestVersion: lastCheckedVersion,
        currentVersion: currentVersion,
        releaseUrl:
            prefs.getString(_cacheKey(_keyLastReleaseUrl, selectedChannel)) ??
            _releasePageUrl,
        hasNewVersion:
            isCrossChannel ||
            _compareVersions(currentVersion, lastCheckedVersion) < 0,
        releaseNotes: prefs.getString(
          _cacheKey(_keyLastReleaseNotes, selectedChannel),
        ),
        downloadUrl: prefs.getString(
          _cacheKey(_keyLastDownloadUrl, selectedChannel),
        ),
        assetName: prefs.getString(
          _cacheKey(_keyLastAssetName, selectedChannel),
        ),
        assetSize: prefs.getInt(_cacheKey(_keyLastAssetSize, selectedChannel)),
        isCrossChannel: isCrossChannel,
      );
    }

    final data = await _fetchRelease(selectedChannel);
    if (requestRevision != _channelRevision) return null;
    if (data == null) {
      await _cacheNoRelease(prefs, selectedChannel);
      return null;
    }

    final latestVersion = _normalizeVersion(data['tag_name'] as String? ?? '');
    if (latestVersion.isEmpty) {
      throw const FormatException('Release tag has no version');
    }

    final releaseNotes = data['body'] as String?;
    final releaseUrl = data['html_url'] as String? ?? _releasePageUrl;
    final assets = data['assets'] as List<dynamic>? ?? [];
    final matchedAsset = findPlatformAsset(assets);
    final downloadUrl = matchedAsset?['browser_download_url'] as String?;
    final assetName = matchedAsset?['name'] as String?;
    final assetSize = matchedAsset?['size'] as int?;

    await _cacheRelease(
      prefs,
      selectedChannel,
      latestVersion: latestVersion,
      releaseUrl: releaseUrl,
      releaseNotes: releaseNotes,
      downloadUrl: downloadUrl,
      assetName: assetName,
      assetSize: assetSize,
    );

    return UpdateInfo(
      latestVersion: latestVersion,
      currentVersion: currentVersion,
      releaseUrl: releaseUrl,
      hasNewVersion:
          isCrossChannel || _compareVersions(currentVersion, latestVersion) < 0,
      releaseNotes: releaseNotes,
      downloadUrl: downloadUrl,
      assetName: assetName,
      assetSize: assetSize,
      isCrossChannel: isCrossChannel,
    );
  }

  Future<Map<String, dynamic>?> _fetchRelease(UpdateChannel channel) async {
    final options = Options(
      headers: {'Accept': 'application/vnd.github.v3+json'},
      receiveTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
    );

    if (channel == UpdateChannel.stable) {
      final response = await _dio.get(_stableGithubApiUrl, options: options);
      if (response.data is! Map<String, dynamic>) {
        throw const FormatException('Invalid stable release response');
      }
      final data = response.data as Map<String, dynamic>;
      if (data['draft'] == true || data['prerelease'] == true) return null;
      return data;
    }

    var page = 1;
    while (true) {
      final response = await _dio.get(
        _betaGithubApiUrl,
        queryParameters: {'per_page': 100, 'page': page},
        options: options,
      );
      if (response.data is! List<dynamic>) {
        throw const FormatException('Invalid beta releases response');
      }
      final releases = response.data as List<dynamic>;
      for (final release in releases.whereType<Map<String, dynamic>>()) {
        if (release['draft'] == true || release['prerelease'] != true) continue;
        final tag = _normalizeVersion(release['tag_name'] as String? ?? '');
        if (RegExp(r'^\d+\.\d+\.\d+-beta\.\d+$').hasMatch(tag)) {
          return release;
        }
      }
      if (releases.length < 100) return null;
      page++;
    }
  }

  String _normalizeVersion(String version) => version
      .replaceFirst(RegExp(r'^v'), '')
      .replaceFirst(RegExp(r'\(.*\)'), '')
      .trim();

  UpdateChannel _installedChannel(String packageName) =>
      packageName == _betaPackageName
      ? UpdateChannel.beta
      : UpdateChannel.stable;

  String _cacheKey(String key, UpdateChannel channel) =>
      '${key}_${channel.name}';

  Future<void> _cacheRelease(
    SharedPreferences prefs,
    UpdateChannel channel, {
    required String latestVersion,
    required String releaseUrl,
    required String? releaseNotes,
    required String? downloadUrl,
    required String? assetName,
    required int? assetSize,
  }) async {
    final assetSizeKey = _cacheKey(_keyLastAssetSize, channel);
    // Update all in-memory fields before yielding to a channel change.
    await Future.wait([
      prefs.setString(
        _cacheKey(_keyLastCheckedVersion, channel),
        latestVersion,
      ),
      prefs.setInt(
        _cacheKey(_keyLastCheckTime, channel),
        DateTime.now().millisecondsSinceEpoch,
      ),
      _setOptionalString(
        prefs,
        _cacheKey(_keyLastReleaseUrl, channel),
        releaseUrl,
      ),
      _setOptionalString(
        prefs,
        _cacheKey(_keyLastReleaseNotes, channel),
        releaseNotes,
      ),
      _setOptionalString(
        prefs,
        _cacheKey(_keyLastDownloadUrl, channel),
        downloadUrl,
      ),
      _setOptionalString(
        prefs,
        _cacheKey(_keyLastAssetName, channel),
        assetName,
      ),
      assetSize == null
          ? prefs.remove(assetSizeKey)
          : prefs.setInt(assetSizeKey, assetSize),
    ]);
  }

  Future<void> _cacheNoRelease(
    SharedPreferences prefs,
    UpdateChannel channel,
  ) async {
    await Future.wait([
      prefs.setString(_cacheKey(_keyLastCheckedVersion, channel), ''),
      prefs.setInt(
        _cacheKey(_keyLastCheckTime, channel),
        DateTime.now().millisecondsSinceEpoch,
      ),
      for (final key in [
        _keyLastReleaseUrl,
        _keyLastReleaseNotes,
        _keyLastDownloadUrl,
        _keyLastAssetName,
        _keyLastAssetSize,
      ])
        prefs.remove(_cacheKey(key, channel)),
    ]);
  }

  Future<bool> _setOptionalString(
    SharedPreferences prefs,
    String key,
    String? value,
  ) => value == null || value.isEmpty
      ? prefs.remove(key)
      : prefs.setString(key, value);

  /// Match the corresponding release asset for the current operating system.
  Map<String, dynamic>? findPlatformAsset(
    List<dynamic> assets, {
    String? targetPlatform,
    Abi? targetAbi,
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
        final architecture = switch (targetAbi ?? Abi.current()) {
          Abi.linuxX64 => 'x64',
          Abi.linuxArm64 => 'arm64',
          _ => null,
        };
        if (architecture == null) return null;
        result = assetList.firstWhere((a) {
          final name = (a['name'] as String? ?? '').toLowerCase();
          return name.contains('linux-$architecture') &&
              name.endsWith('.tar.gz');
        }, orElse: () => <String, dynamic>{});
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
    final saveDir =
        targetDirectory ??
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
      throw FileSystemException(
        'Downloaded file is empty or missing',
        tempPath,
      );
    }

    final targetFile = File(savePath);
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    return downloadedPart.rename(savePath);
  }

  /// Launch or install the downloaded update package.
  Future<bool> installUpdate(String filePath, {String? targetPlatform}) async {
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
  Future<bool> shouldShowRedDot({UpdateChannel? channel}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final packageInfo = await PackageInfo.fromPlatform();
      final selectedChannel =
          channel ??
          await getUpdateChannel(packageName: packageInfo.packageName);
      final lastCheckedVersion = prefs.getString(
        _cacheKey(_keyLastCheckedVersion, selectedChannel),
      );
      final lastNotifiedVersion = prefs.getString(
        _cacheKey(_keyLastNotifiedVersion, selectedChannel),
      );

      if (lastCheckedVersion == null || lastCheckedVersion.isEmpty) {
        return false;
      }

      final currentVersion = packageInfo.version;
      final isCrossChannel =
          selectedChannel != _installedChannel(packageInfo.packageName);

      // Show red dot if there's a new version and it hasn't been notified
      return (isCrossChannel ||
              _compareVersions(currentVersion, lastCheckedVersion) < 0) &&
          lastCheckedVersion != lastNotifiedVersion;
    } catch (e) {
      return false;
    }
  }

  /// Mark the current new version as notified (hide red dot)
  Future<void> markAsNotified({UpdateChannel? channel}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final packageInfo = await PackageInfo.fromPlatform();
      final selectedChannel =
          channel ??
          await getUpdateChannel(packageName: packageInfo.packageName);
      final lastCheckedVersion = prefs.getString(
        _cacheKey(_keyLastCheckedVersion, selectedChannel),
      );
      if (lastCheckedVersion != null) {
        await prefs.setString(
          _cacheKey(_keyLastNotifiedVersion, selectedChannel),
          lastCheckedVersion,
        );
      }
    } catch (e) {
      // Silent failure
    }
  }

  /// Compare two version strings
  /// Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
  int _compareVersions(String v1, String v2) {
    final pattern = RegExp(
      r'^(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
    );
    final match1 = pattern.firstMatch(v1);
    final match2 = pattern.firstMatch(v2);
    if (match1 == null || match2 == null) {
      return _compareNumericVersions(v1, v2);
    }

    final core1 = match1.group(1)!.split('.').map(int.parse).toList();
    final core2 = match2.group(1)!.split('.').map(int.parse).toList();
    for (
      var i = 0;
      i < (core1.length > core2.length ? core1.length : core2.length);
      i++
    ) {
      final part1 = i < core1.length ? core1[i] : 0;
      final part2 = i < core2.length ? core2[i] : 0;
      if (part1 != part2) return part1.compareTo(part2);
    }

    final prerelease1 = match1.group(2)?.split('.');
    final prerelease2 = match2.group(2)?.split('.');
    if (prerelease1 == null) return prerelease2 == null ? 0 : 1;
    if (prerelease2 == null) return -1;
    for (var i = 0; i < prerelease1.length && i < prerelease2.length; i++) {
      final part1 = prerelease1[i];
      final part2 = prerelease2[i];
      final number1 = int.tryParse(part1);
      final number2 = int.tryParse(part2);
      if (number1 != null && number2 != null) {
        if (number1 != number2) return number1.compareTo(number2);
      } else if (number1 != null) {
        return -1;
      } else if (number2 != null) {
        return 1;
      } else if (part1 != part2) {
        return part1.compareTo(part2);
      }
    }
    return prerelease1.length.compareTo(prerelease2.length);
  }

  int _compareNumericVersions(String v1, String v2) {
    final parts1 = v1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final parts2 = v2.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (
      var i = 0;
      i < (parts1.length > parts2.length ? parts1.length : parts2.length);
      i++
    ) {
      final part1 = i < parts1.length ? parts1[i] : 0;
      final part2 = i < parts2.length ? parts2[i] : 0;
      if (part1 != part2) return part1.compareTo(part2);
    }
    return 0;
  }

  /// Clear all update check data
  Future<void> clearUpdateData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final channel in UpdateChannel.values) {
        for (final key in [
          _keyLastCheckedVersion,
          _keyLastNotifiedVersion,
          _keyLastCheckTime,
          _keyLastReleaseNotes,
          _keyLastDownloadUrl,
          _keyLastAssetName,
          _keyLastAssetSize,
          _keyLastReleaseUrl,
        ]) {
          await prefs.remove(_cacheKey(key, channel));
        }
      }
      for (final key in [
        _keyLastCheckedVersion,
        _keyLastNotifiedVersion,
        _keyLastCheckTime,
        _keyLastReleaseNotes,
        _keyLastDownloadUrl,
        _keyLastAssetName,
        _keyLastAssetSize,
      ]) {
        await prefs.remove(key);
      }
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
  final bool isCrossChannel;

  const UpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.releaseUrl,
    required this.hasNewVersion,
    this.releaseNotes,
    this.downloadUrl,
    this.assetName,
    this.assetSize,
    this.isCrossChannel = false,
  });

  @override
  String toString() {
    return 'UpdateInfo(latest: $latestVersion, current: $currentVersion, hasNew: $hasNewVersion, downloadUrl: $downloadUrl, assetName: $assetName, size: $assetSize)';
  }
}

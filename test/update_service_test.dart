import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/update_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryDirectory;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'KikoFlu',
      packageName: 'com.example.kikoflu',
      version: '4.4.0',
      buildNumber: '1',
      buildSignature: '',
    );
    temporaryDirectory = Directory.systemTemp.createTempSync('kikoflu_update_test_');
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  group('UpdateService Platform Asset Matching', () {
    final assets = [
      {
        'name': 'KikoFlu-android-universe_4192.apk',
        'browser_download_url': 'https://example.com/universe.apk',
        'size': 190000000,
      },
      {
        'name': 'KikoFlu-android-arm64-v8a_4192.apk',
        'browser_download_url': 'https://example.com/arm64.apk',
        'size': 68000000,
      },
      {
        'name': 'KikoFlu-windows-setup_4192.exe',
        'browser_download_url': 'https://example.com/setup.exe',
        'size': 26000000,
      },
      {
        'name': 'KikoFlu-windows_4192.zip',
        'browser_download_url': 'https://example.com/windows.zip',
        'size': 34000000,
      },
      {
        'name': 'KikoFlu-macos_4192.dmg',
        'browser_download_url': 'https://example.com/macos.dmg',
        'size': 56000000,
      },
      {
        'name': 'KikoFlu-linux-arm64_4192.tar.gz',
        'browser_download_url': 'https://example.com/linux-arm64.tar.gz',
        'size': 38000000,
      },
      {
        'name': 'KikoFlu-linux-x64_4192.tar.gz',
        'browser_download_url': 'https://example.com/linux.tar.gz',
        'size': 38000000,
      },
      {
        'name': 'KikoFlu-ios-unsigned_4192.ipa',
        'browser_download_url': 'https://example.com/ios.ipa',
        'size': 53000000,
      },
    ];

    test('matches Android arm64-v8a APK preferentially', () {
      final service = UpdateService();
      final matched = service.findPlatformAsset(assets, targetPlatform: 'android');
      expect(matched, isNotNull);
      expect(matched!['name'], 'KikoFlu-android-arm64-v8a_4192.apk');
      expect(matched['browser_download_url'], 'https://example.com/arm64.apk');
    });

    test('matches Windows setup EXE preferentially', () {
      final service = UpdateService();
      final matched = service.findPlatformAsset(assets, targetPlatform: 'windows');
      expect(matched, isNotNull);
      expect(matched!['name'], 'KikoFlu-windows-setup_4192.exe');
      expect(matched['browser_download_url'], 'https://example.com/setup.exe');
    });

    test('matches macOS DMG', () {
      final service = UpdateService();
      final matched = service.findPlatformAsset(assets, targetPlatform: 'macos');
      expect(matched, isNotNull);
      expect(matched!['name'], 'KikoFlu-macos_4192.dmg');
    });

    test('matches Linux x64 even when ARM64 is listed first', () {
      final service = UpdateService();
      final matched = service.findPlatformAsset(
        assets,
        targetPlatform: 'linux',
        targetAbi: Abi.linuxX64,
      );
      expect(matched, isNotNull);
      expect(matched!['name'], 'KikoFlu-linux-x64_4192.tar.gz');
    });

    test('matches Linux ARM64 even when x64 is listed first', () {
      final service = UpdateService();
      final matched = service.findPlatformAsset(
        assets.reversed.toList(),
        targetPlatform: 'linux',
        targetAbi: Abi.linuxArm64,
      );
      expect(matched?['name'], 'KikoFlu-linux-arm64_4192.tar.gz');
    });

    test('does not fall back to a different Linux architecture', () {
      final service = UpdateService();
      final matched = service.findPlatformAsset(
        assets
            .where((asset) => asset['name']!.toString().contains('arm64'))
            .toList(),
        targetPlatform: 'linux',
        targetAbi: Abi.linuxX64,
      );
      expect(matched, isNull);
    });

    test('does not offer a package for unsupported Linux architectures', () {
      final service = UpdateService();
      expect(
        service.findPlatformAsset(
          assets,
          targetPlatform: 'linux',
          targetAbi: Abi.linuxRiscv64,
        ),
        isNull,
      );
    });

    test('matches iOS IPA', () {
      final service = UpdateService();
      final matched = service.findPlatformAsset(assets, targetPlatform: 'ios');
      expect(matched, isNotNull);
      expect(matched!['name'], 'KikoFlu-ios-unsigned_4192.ipa');
    });
  });

  group('UpdateService Checking and Installation', () {
    test('checkForUpdates queries origin repo and ignores prerelease', () async {
      final requests = <RequestOptions>[];
      final adapter = _MockHttpClientAdapter((options) {
        requests.add(options);
        return ResponseBody.fromString(
          jsonEncode({
            'tag_name': 'v4.19.2',
            'prerelease': true,
            'draft': false,
            'body': 'Test prerelease notes',
            'html_url': 'https://github.com/Shiniester/KikoFlu/releases/tag/v4.19.2',
            'assets': [],
          }),
          HttpStatus.ok,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final dio = Dio()..httpClientAdapter = adapter;
      final service = UpdateService(dio: dio);

      final updateInfo = await service.checkForUpdates(force: true);
      expect(updateInfo, isNull);
      expect(requests, hasLength(1));
      expect(
        requests.first.path,
        'https://api.github.com/repos/Shiniester/KikoFlu/releases/latest',
      );
    });

    test('checkForUpdates returns UpdateInfo for official stable release', () async {
      final adapter = _MockHttpClientAdapter((options) {
        return ResponseBody.fromString(
          jsonEncode({
            'tag_name': 'v4.19.2',
            'prerelease': false,
            'draft': false,
            'body': 'Official release improvements',
            'html_url': 'https://github.com/Shiniester/KikoFlu/releases/tag/v4.19.2',
            'assets': [
              {
                'name': 'KikoFlu-windows-setup_4192.exe',
                'browser_download_url': 'https://example.com/windows-setup.exe',
                'size': 25000000,
              }
            ],
          }),
          HttpStatus.ok,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final dio = Dio()..httpClientAdapter = adapter;
      final service = UpdateService(dio: dio);

      final updateInfo = await service.checkForUpdates(force: true);
      expect(updateInfo, isNotNull);
      expect(updateInfo!.latestVersion, '4.19.2');
      expect(updateInfo.currentVersion, '4.4.0');
      expect(updateInfo.hasNewVersion, isTrue);
      expect(updateInfo.releaseNotes, 'Official release improvements');
      expect(updateInfo.releaseUrl, 'https://github.com/Shiniester/KikoFlu/releases/tag/v4.19.2');
    });

    test('downloadUpdate downloads file with progress and cleans temporary .part', () async {
      final adapter = _MockHttpClientAdapter((options) {
        return ResponseBody.fromString(
          'installer binary data',
          HttpStatus.ok,
        );
      });

      final dio = Dio()..httpClientAdapter = adapter;
      final service = UpdateService(dio: dio);

      final progressValues = <double>[];
      final downloadedFile = await service.downloadUpdate(
        downloadUrl: 'https://example.com/app.exe',
        fileName: 'app.exe',
        targetDirectory: temporaryDirectory,
        onProgress: (received, total) {
          if (total > 0) progressValues.add(received / total);
        },
      );

      expect(downloadedFile.existsSync(), isTrue);
      expect(downloadedFile.readAsStringSync(), 'installer binary data');
      expect(File('${downloadedFile.path}.part').existsSync(), isFalse);
    });

    test('installUpdate calls openFile with application/vnd.android.package-archive on Android', () async {
      final fakeApk = File(p.join(temporaryDirectory.path, 'update.apk'))..writeAsStringSync('apk');
      String? openedPath;
      String? openedType;

      final service = UpdateService(
        openFile: (filePath, {type}) async {
          openedPath = filePath;
          openedType = type;
          return OpenResult(type: ResultType.done, message: 'done');
        },
      );

      final success = await service.installUpdate(
        fakeApk.path,
        targetPlatform: 'android',
      );

      expect(success, isTrue);
      expect(openedPath, fakeApk.path);
      expect(openedType, 'application/vnd.android.package-archive');
    });
  });

  group('UpdateController Flow', () {
    for (final success in [true, false]) {
      test(
        'returns to readyToInstall and reuses the installer (launch success: $success)',
        () async {
          var downloadRequests = 0;
          final adapter = _MockHttpClientAdapter((options) {
            downloadRequests++;
            return ResponseBody.fromString('exe data', HttpStatus.ok);
          });
          final dio = Dio()..httpClientAdapter = adapter;
          final openedPaths = <String>[];
          final installerStarted = Completer<void>();
          final installerResult = Completer<OpenResult>();

          final service = UpdateService(
            dio: dio,
            openFile: (filePath, {type}) {
              openedPaths.add(filePath);
              if (!installerStarted.isCompleted) installerStarted.complete();
              return installerResult.future;
            },
            processStarter:
                (
                  executable,
                  arguments, {
                  ProcessStartMode mode = ProcessStartMode.normal,
                  bool runInShell = false,
                }) async {
                  throw Exception('Fallback to openFile in test');
                },
            getTempDirectory: () async => temporaryDirectory,
          );

          final container = ProviderContainer(
            overrides: [updateServiceProvider.overrideWithValue(service)],
          );
          addTearDown(container.dispose);

          final controller = container.read(updateControllerProvider.notifier);

          const updateInfo = UpdateInfo(
            latestVersion: '4.19.2',
            currentVersion: '4.4.0',
            releaseUrl:
                'https://github.com/Shiniester/KikoFlu/releases/tag/v4.19.2',
            hasNewVersion: true,
            downloadUrl: 'https://example.com/setup.exe',
            assetName: 'setup.exe',
            assetSize: 1024,
          );

          final download = controller.startDownload(updateInfo);
          await installerStarted.future;
          expect(
            container.read(updateControllerProvider).status,
            UpdateStatus.installing,
          );
          installerResult.complete(
            OpenResult(
              type: success ? ResultType.done : ResultType.error,
              message: success ? 'done' : 'failed',
            ),
          );
          await download;

          final state = container.read(updateControllerProvider);
          expect(state.status, UpdateStatus.readyToInstall);
          expect(state.progress, 1.0);
          expect(state.downloadedFilePath, openedPaths.single);
          if (!success) expect(state.errorMessage, '打开安装程序失败');
          expect(await controller.install(), success);
          expect(
            container.read(updateControllerProvider).status,
            UpdateStatus.readyToInstall,
          );
          expect(openedPaths, [
            state.downloadedFilePath,
            state.downloadedFilePath,
          ]);
          expect(downloadRequests, 1);
        },
      );
    }
  });
}

class _MockHttpClientAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions options) handler;

  _MockHttpClientAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

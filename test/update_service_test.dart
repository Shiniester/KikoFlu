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
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'kikoflu_update_test_',
    );
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
      final matched = service.findPlatformAsset(
        assets,
        targetPlatform: 'android',
      );
      expect(matched, isNotNull);
      expect(matched!['name'], 'KikoFlu-android-arm64-v8a_4192.apk');
      expect(matched['browser_download_url'], 'https://example.com/arm64.apk');
    });

    test('matches Windows setup EXE preferentially', () {
      final service = UpdateService();
      final matched = service.findPlatformAsset(
        assets,
        targetPlatform: 'windows',
      );
      expect(matched, isNotNull);
      expect(matched!['name'], 'KikoFlu-windows-setup_4192.exe');
      expect(matched['browser_download_url'], 'https://example.com/setup.exe');
    });

    test('matches macOS DMG', () {
      final service = UpdateService();
      final matched = service.findPlatformAsset(
        assets,
        targetPlatform: 'macos',
      );
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
    test(
      'checkForUpdates queries origin repo and ignores prerelease',
      () async {
        final requests = <RequestOptions>[];
        final adapter = _MockHttpClientAdapter((options) {
          requests.add(options);
          return ResponseBody.fromString(
            jsonEncode({
              'tag_name': 'v4.19.2',
              'prerelease': true,
              'draft': false,
              'body': 'Test prerelease notes',
              'html_url':
                  'https://github.com/Shiniester/KikoFlu/releases/tag/v4.19.2',
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
      },
    );

    test(
      'checkForUpdates returns UpdateInfo for official stable release',
      () async {
        final adapter = _MockHttpClientAdapter((options) {
          return ResponseBody.fromString(
            jsonEncode({
              'tag_name': 'v4.19.2',
              'prerelease': false,
              'draft': false,
              'body': 'Official release improvements',
              'html_url':
                  'https://github.com/Shiniester/KikoFlu/releases/tag/v4.19.2',
              'assets': [
                {
                  'name': 'KikoFlu-windows-setup_4192.exe',
                  'browser_download_url':
                      'https://example.com/windows-setup.exe',
                  'size': 25000000,
                },
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
        expect(
          updateInfo.releaseUrl,
          'https://github.com/Shiniester/KikoFlu/releases/tag/v4.19.2',
        );
      },
    );

    test(
      'default channel follows installed edition until overridden',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'KikoFlu Beta',
          packageName: 'com.meteor.kikoeruflutter.beta',
          version: '4.5.3-beta.1',
          buildNumber: '1',
          buildSignature: '',
        );
        final service = UpdateService();

        expect(await service.getUpdateChannel(), UpdateChannel.beta);
        await service.setUpdateChannel(UpdateChannel.stable);
        expect(await UpdateService().getUpdateChannel(), UpdateChannel.stable);
      },
    );

    test(
      'beta check paginates and accepts only published beta prereleases',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'KikoFlu Beta',
          packageName: 'com.meteor.kikoeruflutter.beta',
          version: '4.5.3-beta.9',
          buildNumber: '1',
          buildSignature: '',
        );
        final requests = <RequestOptions>[];
        final firstPage = [
          for (var i = 0; i < 98; i++)
            {'tag_name': 'v4.5.3-beta.$i', 'draft': true, 'prerelease': true},
          {'tag_name': 'v4.5.3-rc.1', 'draft': false, 'prerelease': true},
          {'tag_name': 'v4.5.3-alpha.1', 'draft': false, 'prerelease': true},
        ];
        final adapter = _MockHttpClientAdapter((options) {
          requests.add(options);
          final page = options.queryParameters['page'];
          return ResponseBody.fromString(
            jsonEncode(
              page == 1
                  ? firstPage
                  : [
                      {
                        'tag_name': 'v4.5.3-beta.10',
                        'draft': false,
                        'prerelease': true,
                        'body': 'Beta improvements',
                        'html_url':
                            'https://github.com/Shiniester/KikoFlu/releases/tag/v4.5.3-beta.10',
                        'assets': [],
                      },
                    ],
            ),
            HttpStatus.ok,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        });
        final service = UpdateService(dio: Dio()..httpClientAdapter = adapter);

        final updateInfo = await service.checkForUpdates(force: true);

        expect(updateInfo?.latestVersion, '4.5.3-beta.10');
        expect(updateInfo?.hasNewVersion, isTrue);
        expect(updateInfo?.releaseNotes, 'Beta improvements');
        expect(requests, hasLength(2));
        expect(requests.map((request) => request.queryParameters['page']), [
          1,
          2,
        ]);
        expect(requests.first.queryParameters['per_page'], 100);
        expect(
          requests.every((request) => request.path.endsWith('/releases')),
          isTrue,
        );
      },
    );

    test(
      'beta channel reports no published beta and never falls back to stable',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'KikoFlu Beta',
          packageName: 'com.meteor.kikoeruflutter.beta',
          version: '4.5.3-beta.1',
          buildNumber: '1',
          buildSignature: '',
        );
        final requests = <RequestOptions>[];
        final adapter = _MockHttpClientAdapter((options) {
          requests.add(options);
          return ResponseBody.fromString(
            jsonEncode([
              {'tag_name': 'v4.5.3-beta.2', 'draft': true, 'prerelease': true},
              {
                'tag_name': 'v4.5.3-alpha.1',
                'draft': false,
                'prerelease': true,
              },
              {'tag_name': 'v4.5.3-rc.1', 'draft': false, 'prerelease': true},
              {'tag_name': 'v4.5.3', 'draft': false, 'prerelease': false},
            ]),
            HttpStatus.ok,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        });
        final service = UpdateService(dio: Dio()..httpClientAdapter = adapter);

        expect(await service.checkForUpdates(force: true), isNull);
        expect(requests, hasLength(1));
        expect(requests.single.path.endsWith('/releases'), isTrue);
        expect(requests.single.queryParameters['page'], 1);
      },
    );

    test(
      'beta request failures propagate instead of reporting no beta release',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'KikoFlu Beta',
          packageName: 'com.meteor.kikoeruflutter.beta',
          version: '4.5.3-beta.1',
          buildNumber: '1',
          buildSignature: '',
        );
        final adapter = _MockHttpClientAdapter((_) {
          return ResponseBody.fromString('rate limited', HttpStatus.forbidden);
        });
        final service = UpdateService(dio: Dio()..httpClientAdapter = adapter);

        await expectLater(
          service.checkForUpdates(force: true),
          throwsA(isA<DioException>()),
        );
      },
    );

    test(
      'channel caches stay separate and missing release fields are cleared',
      () async {
        final requests = <RequestOptions>[];
        var betaCheck = 0;
        final adapter = _MockHttpClientAdapter((options) {
          requests.add(options);
          if (options.path.endsWith('/latest')) {
            return _jsonResponse({
              'tag_name': 'v4.5.0',
              'draft': false,
              'prerelease': false,
              'body': 'Stable notes',
              'html_url': 'https://example.com/stable',
              'assets': [],
            });
          }
          betaCheck++;
          return _jsonResponse([
            {
              'tag_name': betaCheck == 1 ? 'v4.4.0-beta.1' : 'v4.4.0-beta.2',
              'draft': false,
              'prerelease': true,
              'body': betaCheck == 1 ? 'Old beta notes' : null,
              'html_url': 'https://example.com/beta-$betaCheck',
              'assets': [],
            },
          ]);
        });
        final service = UpdateService(dio: Dio()..httpClientAdapter = adapter);
        final prefs = await SharedPreferences.getInstance();

        final stable = await service.checkForUpdates(
          force: true,
          channel: UpdateChannel.stable,
        );
        final beta = await service.checkForUpdates(
          force: true,
          channel: UpdateChannel.beta,
        );
        await prefs.setString('last_release_notes_beta', 'Old beta notes');
        await prefs.setString(
          'last_download_url_beta',
          'https://old.example/app.apk',
        );
        await prefs.setString('last_asset_name_beta', 'old.apk');
        await prefs.setInt('last_asset_size_beta', 100);
        await service.checkForUpdates(force: true, channel: UpdateChannel.beta);
        final cachedBeta = await service.checkForUpdates(
          channel: UpdateChannel.beta,
        );
        final cachedStable = await service.checkForUpdates(
          channel: UpdateChannel.stable,
        );

        expect(stable?.latestVersion, '4.5.0');
        expect(beta?.latestVersion, '4.4.0-beta.1');
        expect(beta?.hasNewVersion, isTrue);
        expect(beta?.isCrossChannel, isTrue);
        expect(cachedBeta?.latestVersion, '4.4.0-beta.2');
        expect(cachedBeta?.releaseNotes, isNull);
        expect(cachedBeta?.downloadUrl, isNull);
        expect(cachedBeta?.assetName, isNull);
        expect(cachedBeta?.assetSize, isNull);
        expect(cachedBeta?.releaseUrl, 'https://example.com/beta-2');
        expect(cachedStable?.latestVersion, '4.5.0');
        expect(cachedStable?.releaseNotes, 'Stable notes');
        expect(cachedStable?.releaseUrl, 'https://example.com/stable');
        expect(requests, hasLength(3));
      },
    );

    for (final oldHasRelease in [true, false]) {
      test(
        'late beta ${oldHasRelease ? 'release' : 'empty'} response cannot replace the selected channel cache',
        () async {
          final oldResponse = Completer<ResponseBody>();
          final oldRequestStarted = Completer<void>();
          var requests = 0;
          final adapter = _MockHttpClientAdapter((options) {
            requests++;
            if (requests == 1) {
              oldRequestStarted.complete();
              return oldResponse.future;
            }
            return _jsonResponse([
              {
                'tag_name': 'v4.5.3-beta.2',
                'draft': false,
                'prerelease': true,
                'body': 'Current beta notes',
                'html_url': 'https://example.com/beta-2',
                'assets': [],
              },
            ]);
          });
          final service = UpdateService(
            dio: Dio()..httpClientAdapter = adapter,
          );
          final oldCheck = service.checkForUpdates(
            force: true,
            channel: UpdateChannel.beta,
          );
          await oldRequestStarted.future;
          await service.setUpdateChannel(UpdateChannel.stable);
          await service.setUpdateChannel(UpdateChannel.beta);
          final current = await service.checkForUpdates(force: true);

          oldResponse.complete(
            _jsonResponse(
              oldHasRelease
                  ? [
                      {
                        'tag_name': 'v4.5.3-beta.1',
                        'draft': false,
                        'prerelease': true,
                        'body': 'Old beta notes',
                        'html_url': 'https://example.com/beta-1',
                        'assets': [],
                      },
                    ]
                  : [],
            ),
          );
          final obsolete = await oldCheck;
          final cached = await service.checkForUpdates();

          expect(current?.latestVersion, '4.5.3-beta.2');
          expect(cached?.latestVersion, '4.5.3-beta.2');
          expect(cached?.releaseNotes, 'Current beta notes');
          expect(cached?.releaseUrl, 'https://example.com/beta-2');
          expect(obsolete, isNull);
          expect(requests, 2);
        },
      );
    }

    test('notifications and red dots are isolated by channel', () async {
      final adapter = _MockHttpClientAdapter((options) {
        return _jsonResponse(
          options.path.endsWith('/latest')
              ? {
                  'tag_name': 'v4.5.0',
                  'draft': false,
                  'prerelease': false,
                  'assets': [],
                }
              : [
                  {
                    'tag_name': 'v4.3.0-beta.1',
                    'draft': false,
                    'prerelease': true,
                    'assets': [],
                  },
                ],
        );
      });
      final service = UpdateService(dio: Dio()..httpClientAdapter = adapter);

      await service.checkForUpdates(force: true, channel: UpdateChannel.stable);
      expect(
        await service.shouldShowRedDot(channel: UpdateChannel.stable),
        isTrue,
      );
      await service.markAsNotified(channel: UpdateChannel.stable);
      expect(
        await service.shouldShowRedDot(channel: UpdateChannel.stable),
        isFalse,
      );

      await service.checkForUpdates(force: true, channel: UpdateChannel.beta);
      expect(
        await service.shouldShowRedDot(channel: UpdateChannel.beta),
        isTrue,
      );
    });

    test(
      'version comparison orders beta numbers and stable releases',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'KikoFlu Beta',
          packageName: 'com.meteor.kikoeruflutter.beta',
          version: '4.5.3-beta.9',
          buildNumber: '1',
          buildSignature: '',
        );
        final betaAdapter = _MockHttpClientAdapter((_) {
          return _jsonResponse([
            {
              'tag_name': 'v4.5.3-beta.10',
              'draft': false,
              'prerelease': true,
              'assets': [],
            },
          ]);
        });
        final betaInfo = await UpdateService(
          dio: Dio()..httpClientAdapter = betaAdapter,
        ).checkForUpdates(force: true);
        expect(betaInfo?.hasNewVersion, isTrue);

        PackageInfo.setMockInitialValues(
          appName: 'KikoFlu',
          packageName: 'com.example.kikoflu',
          version: '4.5.3-beta.10',
          buildNumber: '1',
          buildSignature: '',
        );
        final stableAdapter = _MockHttpClientAdapter((_) {
          return _jsonResponse({
            'tag_name': 'v4.5.3',
            'draft': false,
            'prerelease': false,
            'assets': [],
          });
        });
        final stableInfo = await UpdateService(
          dio: Dio()..httpClientAdapter = stableAdapter,
        ).checkForUpdates(force: true);
        expect(stableInfo?.hasNewVersion, isTrue);
      },
    );

    test(
      'cross-channel lower stable stays visible but older same-channel beta does not',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'KikoFlu Beta',
          packageName: 'com.meteor.kikoeruflutter.beta',
          version: '4.5.3-beta.2',
          buildNumber: '1',
          buildSignature: '',
        );
        final stableAdapter = _MockHttpClientAdapter((_) {
          return _jsonResponse({
            'tag_name': 'v4.5.2',
            'draft': false,
            'prerelease': false,
            'assets': [],
          });
        });
        final stableInfo = await UpdateService(
          dio: Dio()..httpClientAdapter = stableAdapter,
        ).checkForUpdates(force: true, channel: UpdateChannel.stable);

        expect(stableInfo?.latestVersion, '4.5.2');
        expect(stableInfo?.isCrossChannel, isTrue);
        expect(stableInfo?.hasNewVersion, isTrue);

        PackageInfo.setMockInitialValues(
          appName: 'KikoFlu Beta',
          packageName: 'com.meteor.kikoeruflutter.beta',
          version: '4.5.3-beta.10',
          buildNumber: '1',
          buildSignature: '',
        );
        final betaAdapter = _MockHttpClientAdapter((_) {
          return _jsonResponse([
            {
              'tag_name': 'v4.5.3-beta.9',
              'draft': false,
              'prerelease': true,
              'assets': [],
            },
          ]);
        });
        final betaInfo = await UpdateService(
          dio: Dio()..httpClientAdapter = betaAdapter,
        ).checkForUpdates(force: true, channel: UpdateChannel.beta);

        expect(betaInfo?.latestVersion, '4.5.3-beta.9');
        expect(betaInfo?.isCrossChannel, isFalse);
        expect(betaInfo?.hasNewVersion, isFalse);
      },
    );

    test(
      'downloadUpdate downloads file with progress and cleans temporary .part',
      () async {
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
      },
    );

    test(
      'installUpdate calls openFile with application/vnd.android.package-archive on Android',
      () async {
        final fakeApk = File(p.join(temporaryDirectory.path, 'update.apk'))
          ..writeAsStringSync('apk');
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
      },
    );
  });

  group('UpdateController Flow', () {
    test(
      'reset ignores a late completed download and skips auto install',
      () async {
        final service = _DeferredDownloadService();
        final container = ProviderContainer(
          overrides: [updateServiceProvider.overrideWithValue(service)],
        );
        addTearDown(container.dispose);
        final controller = container.read(updateControllerProvider.notifier);
        const updateInfo = UpdateInfo(
          latestVersion: '4.5.0-beta.1',
          currentVersion: '4.4.0',
          releaseUrl: 'https://example.com/beta',
          hasNewVersion: true,
          downloadUrl: 'https://example.com/beta.apk',
          assetName: 'beta.apk',
        );

        final download = controller.startDownload(updateInfo);
        controller.reset();
        service.downloads.single.complete(File('late-beta.apk'));
        await download;

        expect(
          container.read(updateControllerProvider).status,
          UpdateStatus.idle,
        );
        expect(
          container.read(updateControllerProvider).downloadedFilePath,
          isNull,
        );
        expect(service.installCalls, 0);
      },
    );

    test(
      'a cancelled old download cannot overwrite a newer download',
      () async {
        final service = _DeferredDownloadService();
        final container = ProviderContainer(
          overrides: [updateServiceProvider.overrideWithValue(service)],
        );
        addTearDown(container.dispose);
        final controller = container.read(updateControllerProvider.notifier);
        const oldInfo = UpdateInfo(
          latestVersion: '4.5.0',
          currentVersion: '4.4.0',
          releaseUrl: 'https://example.com/stable',
          hasNewVersion: true,
          downloadUrl: 'https://example.com/stable.exe',
          assetName: 'stable.exe',
        );
        const newInfo = UpdateInfo(
          latestVersion: '4.5.0-beta.1',
          currentVersion: '4.4.0',
          releaseUrl: 'https://example.com/beta',
          hasNewVersion: true,
          downloadUrl: 'https://example.com/beta.apk',
          assetName: 'beta.apk',
        );

        final oldDownload = controller.startDownload(oldInfo);
        controller.reset();
        final newDownload = controller.startDownload(newInfo);
        service.downloads.first.completeError(StateError('cancelled'));
        await oldDownload;

        expect(
          container.read(updateControllerProvider).status,
          UpdateStatus.downloading,
        );
        expect(
          container.read(updateControllerProvider).downloadedFilePath,
          isNull,
        );
        expect(service.installCalls, 0);

        service.downloads.last.complete(File('beta.apk'));
        await newDownload;
        expect(
          container.read(updateControllerProvider).status,
          UpdateStatus.readyToInstall,
        );
        expect(
          container.read(updateControllerProvider).downloadedFilePath,
          'beta.apk',
        );
        expect(service.installCalls, 1);
      },
    );

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

ResponseBody _jsonResponse(Object? data) {
  return ResponseBody.fromString(
    jsonEncode(data),
    HttpStatus.ok,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

class _DeferredDownloadService extends UpdateService {
  final downloads = <Completer<File>>[];
  int installCalls = 0;

  @override
  Future<File> downloadUpdate({
    required String downloadUrl,
    required String fileName,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    Directory? targetDirectory,
  }) {
    final download = Completer<File>();
    downloads.add(download);
    return download.future;
  }

  @override
  Future<bool> installUpdate(String filePath, {String? targetPlatform}) async {
    installCalls++;
    return true;
  }
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

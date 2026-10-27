import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/update_provider.dart';
import 'package:kikoeru_flutter/src/screens/about_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    rootBundle.evict('LICENSE');
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'KikoFlu',
      packageName: 'com.example.kikoflu',
      version: '3.8.2',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('about page identifies the fork and its upstream repository', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: AboutScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('作者'), findsOneWidget);
    expect(find.text('Shiniester'), findsOneWidget);
    expect(find.text('https://github.com/Shiniester/KikoFlu'), findsOneWidget);
    expect(find.text('上游作者'), findsOneWidget);
    expect(find.text('pa-jesusf'), findsOneWidget);
    expect(find.text('上游仓库'), findsOneWidget);
    expect(find.text('https://github.com/pa-jesusf/KikoFlu'), findsOneWidget);
  });

  testWidgets(
    'selecting beta persists it, checks immediately, and clears the old installer',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _FakeUpdateService(betaAvailable: true);
      final controller = _FakeUpdateController(
        const UpdateState(
          status: UpdateStatus.readyToInstall,
          downloadedFilePath: '/tmp/stable.apk',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            updateServiceProvider.overrideWithValue(service),
            updateControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            theme: ThemeData(platform: TargetPlatform.android),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: const AboutScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('update-channel-setting')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试版'));
      await tester.pumpAndSettle();

      expect(await service.getUpdateChannel(), UpdateChannel.beta);
      expect(service.checks, 1);
      expect(controller.state.status, UpdateStatus.idle);
      expect(controller.state.downloadedFilePath, isNull);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('所选渠道版本'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Android 正式版与测试版是独立应用，数据分别保存。安装后不会替换当前应用。'),
        ),
        findsOneWidget,
      );
      expect(find.text('发现新版本'), findsNothing);
    },
  );

  testWidgets(
    'channel selection cancels the old download before saving finishes',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _PendingChannelSaveService();
      final controller = UpdateController(service);
      final oldDownload = controller.startDownload(
        const UpdateInfo(
          latestVersion: '4.5.0',
          currentVersion: '4.4.0',
          releaseUrl: 'https://example.com/stable',
          hasNewVersion: true,
          downloadUrl: 'https://example.com/stable.apk',
          assetName: 'stable.apk',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            updateServiceProvider.overrideWithValue(service),
            updateControllerProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            theme: ThemeData(platform: TargetPlatform.android),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: const AboutScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('update-channel-setting')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试版'));
      await tester.pumpAndSettle();

      service.download.complete(File('stable.apk'));
      await oldDownload;
      final installsWhileSaving = service.installCalls;
      final checksWhileSaving = service.checks;
      service.save.complete();
      await tester.pumpAndSettle();

      expect(installsWhileSaving, 0);
      expect(checksWhileSaving, 0);
      expect(service.checks, 1);
      expect(controller.state.status, UpdateStatus.idle);
      expect(controller.state.downloadedFilePath, isNull);
    },
  );

  testWidgets('beta is disabled outside Android with an explanation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _FakeUpdateService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [updateServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          locale: const Locale('zh'),
          theme: ThemeData(platform: TargetPlatform.windows),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const AboutScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-channel-setting')));
    await tester.pumpAndSettle();

    final betaOption = tester.widget<RadioListTile<UpdateChannel>>(
      find.byKey(const ValueKey('beta-update-channel')),
    );
    expect(betaOption.enabled, isFalse);
    expect(find.text('测试版仅支持 Android'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('beta-update-channel')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(await service.getUpdateChannel(), UpdateChannel.stable);
  });

  testWidgets('a failed beta check shows a network error instead of no beta', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _FakeUpdateService(channel: UpdateChannel.beta, fail: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [updateServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: AboutScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('检查更新失败，请检查网络连接'), findsOneWidget);
    expect(find.text('暂无测试版'), findsNothing);
  });

  testWidgets('a successful beta check with no release shows the empty state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _FakeUpdateService(channel: UpdateChannel.beta);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [updateServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: AboutScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('暂无测试版'), findsOneWidget);
    expect(find.text('检查更新失败，请检查网络连接'), findsNothing);
  });

  testWidgets('leaving About during a check clears state before reentering', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pendingCheck = Completer<UpdateInfo?>();
    final service = _FakeUpdateService(pendingCheck: pendingCheck);
    final container = ProviderContainer(
      overrides: [updateServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: AboutScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    unawaited(
      Navigator.of(tester.element(find.byType(AboutScreen))).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Other screen')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    unawaited(
      Navigator.of(tester.element(find.text('Other screen'))).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(service.checks, 2);

    pendingCheck.complete(null);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

class _FakeUpdateService extends UpdateService {
  _FakeUpdateService({
    this.channel = UpdateChannel.stable,
    this.betaAvailable = false,
    this.fail = false,
    this.pendingCheck,
  });

  UpdateChannel channel;
  final bool betaAvailable;
  final bool fail;
  final Completer<UpdateInfo?>? pendingCheck;
  int checks = 0;
  int _revision = 0;

  @override
  int get channelRevision => _revision;

  @override
  Future<UpdateChannel> getUpdateChannel({String? packageName}) async =>
      channel;

  @override
  Future<void> setUpdateChannel(UpdateChannel channel) async {
    this.channel = channel;
    _revision++;
  }

  @override
  Future<UpdateInfo?> checkForUpdates({
    bool force = false,
    UpdateChannel? channel,
  }) async {
    checks++;
    if (fail) throw StateError('rate limited');
    if (pendingCheck != null) return pendingCheck!.future;
    final selected = channel ?? this.channel;
    if (selected == UpdateChannel.beta && !betaAvailable) return null;
    return UpdateInfo(
      latestVersion: selected == UpdateChannel.beta ? '4.3.0-beta.1' : '4.5.0',
      currentVersion: '4.4.0',
      releaseUrl: 'https://example.com/${selected.name}',
      hasNewVersion: true,
      isCrossChannel: selected != UpdateChannel.stable,
    );
  }

  @override
  Future<void> markAsNotified({UpdateChannel? channel}) async {}
}

class _PendingChannelSaveService extends _FakeUpdateService {
  final save = Completer<void>();
  final download = Completer<File>();
  int installCalls = 0;

  @override
  Future<void> setUpdateChannel(UpdateChannel channel) async {
    await super.setUpdateChannel(channel);
    await save.future;
  }

  @override
  Future<File> downloadUpdate({
    required String downloadUrl,
    required String fileName,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    Directory? targetDirectory,
  }) => download.future;

  @override
  Future<bool> installUpdate(String filePath, {String? targetPlatform}) async {
    installCalls++;
    return true;
  }
}

class _FakeUpdateController extends StateNotifier<UpdateState>
    implements UpdateController {
  _FakeUpdateController(super.state);

  @override
  Future<void> startDownload(UpdateInfo info) async {}

  @override
  void cancelDownload() {}

  @override
  Future<bool> install() async => true;

  @override
  void reset() => state = const UpdateState();
}

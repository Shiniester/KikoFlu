import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/update_provider.dart';
import 'package:kikoeru_flutter/src/widgets/update_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  const sampleUpdateInfo = UpdateInfo(
    latestVersion: '4.19.2',
    currentVersion: '4.4.0',
    releaseUrl: 'https://github.com/Shiniester/KikoFlu/releases/tag/v4.19.2',
    hasNewVersion: true,
    releaseNotes: '1. 支持应用内直接更新\n2. 修复已知问题',
    downloadUrl: 'https://example.com/KikoFlu-windows-setup_4192.exe',
    assetName: 'KikoFlu-windows-setup_4192.exe',
    assetSize: 26611270,
  );

  testWidgets(
    'UpdateDialog displays version info, release notes, and update action',
    (tester) async {
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
            home: Scaffold(body: UpdateDialog(updateInfo: sampleUpdateInfo)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('v4.19.2'), findsOneWidget);
      expect(find.textContaining('4.19.2'), findsWidgets);
      expect(find.textContaining('1. 支持应用内直接更新'), findsOneWidget);
      expect(find.text('立即更新'), findsOneWidget);
      expect(find.text('稍后提醒'), findsOneWidget);
    },
  );

  testWidgets(
    'cross-channel release explains the separate Android installation',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const crossChannelInfo = UpdateInfo(
        latestVersion: '4.3.0-beta.2',
        currentVersion: '4.4.0',
        releaseUrl:
            'https://github.com/Shiniester/KikoFlu/releases/tag/v4.3.0-beta.2',
        hasNewVersion: true,
        isCrossChannel: true,
      );
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(body: UpdateDialog(updateInfo: crossChannelInfo)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('所选渠道版本'), findsOneWidget);
      expect(
        find.text('Android 正式版与测试版是独立应用，数据分别保存。安装后不会替换当前应用。'),
        findsOneWidget,
      );
      expect(find.text('发现新版本'), findsNothing);
      expect(find.text('v4.3.0-beta.2'), findsOneWidget);
    },
  );

  testWidgets('UpdateDialog displays progress when downloading', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          updateControllerProvider.overrideWith(
            (ref) => _FakeUpdateController(
              const UpdateState(
                status: UpdateStatus.downloading,
                progress: 0.5,
                receivedBytes: 13305635,
                totalBytes: 26611270,
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(body: UpdateDialog(updateInfo: sampleUpdateInfo)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('取消下载'), findsOneWidget);
  });

  testWidgets('UpdateDialog displays install button when download completed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          updateControllerProvider.overrideWith(
            (ref) => _FakeUpdateController(
              const UpdateState(
                status: UpdateStatus.readyToInstall,
                progress: 1.0,
                downloadedFilePath: '/path/to/installer.exe',
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(body: UpdateDialog(updateInfo: sampleUpdateInfo)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('下载完成'), findsOneWidget);
    expect(find.text('立即安装'), findsOneWidget);
  });
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
  void reset() {}
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/screens/about_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
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
}

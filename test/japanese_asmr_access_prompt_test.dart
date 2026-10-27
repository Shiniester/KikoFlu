import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/japanese_asmr_access_prompt.dart';

const _channel = MethodChannel('com.meteor.kikoeruflutter/japanese_asmr');

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: S.localizationsDelegates,
  supportedLocales: S.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(_channel, null);
  });

  testWidgets('cancelled verification can be retried and success refreshes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final pending = Completer<Object?>();
    var calls = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls++;
      if (calls == 1) return pending.future;
      return {
        'cookie': 'cf_clearance=verified',
        'userAgent': 'Browser UA',
        'url': call.arguments['url'],
        'data': '<main class="site-main"></main>',
        'statusCode': 200,
        'headers': <String, String>{},
      };
    });
    var verified = 0;
    await tester.pumpWidget(
      _app(
        JapaneseAsmrAccessPrompt(onVerified: () => verified++, onRetry: () {}),
      ),
    );

    final button = find.widgetWithText(ElevatedButton, 'Verify website access');
    await tester.tap(button);
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<ElevatedButton>(button).onPressed, isNull);

    pending.complete(null);
    await tester.pumpAndSettle();
    expect(tester.widget<ElevatedButton>(button).onPressed, isNotNull);
    expect(verified, 0);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(verified, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('unsupported platforms show retry without invoking native UI', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var retries = 0;
    var calls = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls++;
      return null;
    });
    await tester.pumpWidget(
      _app(
        JapaneseAsmrAccessPrompt(onVerified: () {}, onRetry: () => retries++),
      ),
    );

    expect(
      find.text(
        'In-app verification is unavailable on this platform. Change your network or proxy, then retry.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Retry'));
    expect(retries, 1);
    expect(calls, 0);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('platform errors show localized failure and re-enable verify', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(
      _channel,
      (call) async => throw PlatformException(code: 'verification-failed'),
    );
    await tester.pumpWidget(
      _app(JapaneseAsmrAccessPrompt(onVerified: () {}, onRetry: () {})),
    );

    final button = find.widgetWithText(ElevatedButton, 'Verify website access');
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Verification did not complete. Retry using the same network and proxy.',
      ),
      findsOneWidget,
    );
    expect(tester.widget<ElevatedButton>(button).onPressed, isNotNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

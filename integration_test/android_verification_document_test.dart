import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:kikoeru_flutter/src/videos/missav_verification.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'Android reads a verified document through the real WebView bridge',
    (tester) async {
      final browser = WebViewController();
      await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
      final loaded = Completer<void>();
      await browser.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!loaded.isCompleted) loaded.complete();
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WebViewWidget(controller: browser)),
        ),
      );

      try {
        final uri = Uri.parse('https://missav.ai/cn');
        final document = await navigateMissavDocument(
          uri,
          Completer<void>().future,
          navigate: (_) async {
            await browser.loadHtmlString(
              '<!doctype html><html><head><title>Verified fixture</title>'
              '</head><body><a href="/logout">退出登录</a>'
              '<main>Verified account fixture</main></body></html>',
              baseUrl: uri.toString(),
            );
            await loaded.future.timeout(const Duration(seconds: 15));
          },
          read: browser.runJavaScriptReturningResult,
          stop: () => browser.runJavaScript('window.stop();'),
        );

        expect(document, contains('Verified account fixture'));
        expect(document, contains('退出登录'));
      } finally {
        await browser.runJavaScript('window.stop();');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

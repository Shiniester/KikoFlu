import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:kikoeru_flutter/src/services/proxy_config.dart';
import 'package:kikoeru_flutter/src/utils/global_keys.dart';
import 'package:kikoeru_flutter/src/videos/missav_browser_media.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_media_server.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

const _browserChannel = MethodChannel(
  'com.meteor.kikoeruflutter/missav_browser',
);
const _fixtureUrl =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'Android browser media relay decodes the public butterfly fixture',
    (tester) async {
      await ProxyConfig.init();
      await _browserChannel.invokeMethod<void>('configureProxy', {
        'mode': ProxyConfig.mode.name,
        'proxyUrl': ProxyConfig.httpsProxyUrl,
      });
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = KikoFluHttpOverrides();
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});

      WebViewController? browser;
      OverlayEntry? entry;
      MissavBrowserMediaTransport? transport;
      MissavMediaServer? server;
      final player = Player();
      final session = MediaKitVideoPlaybackSession(player: player);

      try {
        final proxy = ProxyConfig.httpsProxyUrl;
        debugPrint(
          'ANDROID_RELAY_FIXTURE proxyMode=${ProxyConfig.mode.name} proxyConfigured=${proxy != null}',
        );
        final cors = await _probeFixtureCors();
        debugPrint(
          'ANDROID_RELAY_FIXTURE sourceStatus=${cors.statusCode} corsAllowed=${cors.allowed} firstByte=${cors.firstByte}',
        );
        expect(cors.allowed, isTrue);
        expect(cors.firstByte, isNotEmpty);

        browser = WebViewController();
        await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
        final pageLoaded = Completer<void>();
        await browser.setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (url) {
              if (!pageLoaded.isCompleted) pageLoaded.complete();
            },
          ),
        );
        transport = MissavBrowserMediaTransport(
          runJavaScript: browser.runJavaScript,
          currentUrl: () async {
            final current = await browser!.currentUrl();
            if (Uri.tryParse(current ?? '')?.scheme == 'about') {
              // Android reports about:blank for loadHtmlString despite its base URL.
              return '${MissavClient.origin}/';
            }
            return current;
          },
          disposeBrowser: () => browser!.removeJavaScriptChannel(
            MissavBrowserMediaTransport.channelName,
          ),
        );
        await browser.addJavaScriptChannel(
          MissavBrowserMediaTransport.channelName,
          onMessageReceived: (message) =>
              transport!.receiveMessage(message.message),
        );

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            home: Scaffold(body: session.buildSurface(aspectRatio: 16 / 9)),
          ),
        );
        final overlay = rootNavigatorKey.currentState?.overlay;
        if (overlay == null) {
          throw StateError('Application overlay unavailable');
        }
        entry = OverlayEntry(
          builder: (_) => Offstage(
            child: SizedBox(
              width: 1,
              height: 1,
              child: WebViewWidget(controller: browser!),
            ),
          ),
        );
        overlay.insert(entry);
        await WidgetsBinding.instance.endOfFrame;
        await browser.loadHtmlString(
          '<!doctype html><html><head><title>Media relay fixture</title></head>'
          '<body>Android media relay fixture</body></html>',
          baseUrl: '${MissavClient.origin}/',
        );
        await pageLoaded.future.timeout(const Duration(seconds: 20));
        final currentUrl = Uri.tryParse(await browser.currentUrl() ?? '');
        final browserOrigin = currentUrl?.scheme == 'about'
            ? 'about:blank'
            : currentUrl == null
            ? null
            : '${currentUrl.scheme}://${currentUrl.host}'
                  '${currentUrl.hasPort ? ':${currentUrl.port}' : ''}';
        final sourceOriginResult = await browser.runJavaScriptReturningResult(
          'location.origin',
        );
        final sourceOrigin = sourceOriginResult is String
            ? jsonDecode(sourceOriginResult)
            : sourceOriginResult;
        debugPrint(
          'ANDROID_RELAY_FIXTURE webViewOrigin=${browserOrigin ?? 'none'} jsOrigin=$sourceOrigin',
        );
        expect(browserOrigin, 'about:blank');
        expect(sourceOrigin, MissavClient.origin);
        expect(
          cors.statusCode,
          anyOf(HttpStatus.ok, HttpStatus.partialContent),
        );
        debugPrint('ANDROID_RELAY_FIXTURE offstageBrowserReady=true');

        server = await MissavMediaServer.start(transport);
        final localUri = server.register(Uri.parse(_fixtureUrl));
        await session
            .loadStream(
              VideoStream(label: 'Butterfly fixture', url: localUri.toString()),
              position: Duration.zero,
              volume: 0,
            )
            .timeout(const Duration(seconds: 30));
        await session.play();
        await _waitForDecoded(tester, player);
        debugPrint(
          'ANDROID_RELAY_FIXTURE decoded=true width=${player.state.width} height=${player.state.height}',
        );
      } catch (error) {
        debugPrint(
          'ANDROID_RELAY_FIXTURE failed=${_safeError(error)} playerError=${_safeError(session.snapshot.value.error ?? 'none')}',
        );
        rethrow;
      } finally {
        entry?.remove();
        entry?.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
        await server?.close();
        transport?.close();
        if (transport != null) await transport.whenClosed;
        try {
          await _browserChannel.invokeMethod<void>('resetProxy');
        } finally {
          HttpOverrides.global = previousHttpOverrides;
        }
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<({int statusCode, bool allowed, List<int> firstByte})>
_probeFixtureCors() async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await http.getUrl(Uri.parse(_fixtureUrl));
    request.headers
      ..set('origin', MissavClient.origin)
      ..set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final response = await request.close().timeout(const Duration(seconds: 20));
    final allowOrigin = response.headers.value('access-control-allow-origin');
    final allowed = allowOrigin == '*' || allowOrigin == MissavClient.origin;
    final firstByte = await response.first.timeout(const Duration(seconds: 15));
    return (
      statusCode: response.statusCode,
      allowed: allowed,
      firstByte: firstByte,
    );
  } finally {
    http.close(force: true);
  }
}

Future<void> _waitForDecoded(WidgetTester tester, Player player) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    if (player.state.position > const Duration(seconds: 1) &&
        (player.state.width ?? 0) > 0 &&
        (player.state.height ?? 0) > 0) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('Android did not decode the relayed fixture.');
}

String _safeError(Object error) => error
    .toString()
    .replaceAll(RegExp(r'https?://\S+'), '[URL]')
    .replaceAll(
      RegExp(r'(token|auth|key|signature)=([^&\s]+)', caseSensitive: false),
      r'$1=[redacted]',
    );

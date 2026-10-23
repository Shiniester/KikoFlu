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
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_verification.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const enabled = bool.fromEnvironment('KIKOFLU_LIVE_MISSAV');

  testWidgets(
    'Android MissAV browser relay fetches and decodes an online stream',
    (tester) async {
      await ProxyConfig.init();
      await const MethodChannel(
        'com.meteor.kikoeruflutter/missav_browser',
      ).invokeMethod<void>('configureProxy', {
        'mode': ProxyConfig.mode.name,
        'proxyUrl': ProxyConfig.httpsProxyUrl,
      });
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = KikoFluHttpOverrides();
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});

      final client = MissavClient();
      await client.initialize();
      final browser = WebViewController();
      await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
      final pageFinished = Completer<void>();
      WebResourceError? sourceLoadError;
      await browser.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              !request.isMainFrame || isMissavVerificationUrl(request.url)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (url) {
            if (isMissavVerificationUrl(url) && !pageFinished.isCompleted) {
              pageFinished.complete();
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != false && !pageFinished.isCompleted) {
              sourceLoadError = error;
              pageFinished.complete();
            }
          },
        ),
      );

      final player = Player();
      final session = MediaKitVideoPlaybackSession(player: player);
      final playerErrors = <String>[];
      final errorSubscription = player.stream.error.listen((error) {
        final safeError = _safeError(error);
        playerErrors.add(safeError);
        debugPrint('ANDROID_MISSAV playerError=$safeError');
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                WebViewWidget(controller: browser),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: 640,
                    height: 360,
                    child: session.buildSurface(aspectRatio: 16 / 9),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      try {
        await browser.loadRequest(Uri.parse(client.homeUrl));
        await _waitFor(
          tester,
          () => pageFinished.isCompleted,
          const Duration(seconds: 30),
          'Android source WebView did not finish loading.',
        );
        await pageFinished.future;
        if (sourceLoadError case final error?) {
          debugPrint(
            'ANDROID_MISSAV sourceLoadError=true code=${error.errorCode} type=${error.errorType?.name ?? 'unknown'}',
          );
          fail(
            'Android source WebView failed to load '
            '(code=${error.errorCode}, type=${error.errorType?.name ?? 'unknown'}).',
          );
        }

        final sourceReady = await _waitForSourceReady(tester, browser);
        if (!sourceReady) {
          final challenged = await _isChallengePage(browser);
          debugPrint('ANDROID_MISSAV sourceReady=false challenge=$challenged');
          fail(
            challenged
                ? 'MissAV source remained behind a verification challenge.'
                : 'MissAV source page did not become ready.',
          );
        }
        debugPrint('ANDROID_MISSAV sourceReady=true');

        try {
          await connectMissavBrowserSession(client, mobile: browser);
        } on MissavVerificationRequiredException {
          debugPrint(
            'ANDROID_MISSAV browserSessionConnected=false challenge=true',
          );
          fail('MissAV browser session still requires verification.');
        } on StateError catch (error) {
          if (error.message == 'Source browser session unavailable') {
            debugPrint(
              'ANDROID_MISSAV browserSessionConnected=false cookiesAvailable=false',
            );
            fail('MissAV browser session has no usable cookies.');
          }
          rethrow;
        }
        debugPrint('ANDROID_MISSAV browserSessionConnected=true');

        final video = await _selectVideo(client);
        final details = await client.details(video);
        if (details.streams.isEmpty) {
          debugPrint('ANDROID_MISSAV streamCount=0');
          fail('MissAV video details returned no playable streams.');
        }
        final stream = details.streams.first;
        final mediaUri = Uri.parse(stream.url);
        debugPrint(
          'ANDROID_MISSAV streamCount=${details.streams.length} relayHost=${mediaUri.host} hls=${stream.isHls}',
        );
        expect(mediaUri.host, '127.0.0.1');

        final relayResult = await _probeRelay(mediaUri, stream);
        debugPrint(
          'ANDROID_MISSAV relayFetch=true status=${relayResult.statusCode} bytes=${relayResult.bytes} manifest=${relayResult.manifest}',
        );

        await session.loadStream(stream, position: Duration.zero, volume: 0);
        await session.play();
        try {
          await _waitFor(
            tester,
            () =>
                player.state.position > const Duration(seconds: 1) &&
                (player.state.width ?? 0) > 0 &&
                (player.state.height ?? 0) > 0,
            const Duration(seconds: 60),
            'Android online stream did not decode.',
          );
        } catch (_) {
          debugPrint(
            'ANDROID_MISSAV decoded=false playerError=${playerErrors.isEmpty ? 'none' : playerErrors.first}',
          );
          rethrow;
        }
        debugPrint(
          'ANDROID_MISSAV decoded=true width=${player.state.width} height=${player.state.height}',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await clearMissavBrowserSession();
        await errorSubscription.cancel();
        await session.dispose();
        client.dispose();
        HttpOverrides.global = previousHttpOverrides;
      }
    },
    skip: !enabled || !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<VideoItem> _selectVideo(MissavClient client) async {
  const selectedPage = String.fromEnvironment('KIKOFLU_LIVE_MISSAV_PAGE');
  if (selectedPage.isNotEmpty) {
    final page = Uri.parse(selectedPage);
    return VideoItem(
      id: page.pathSegments.last,
      title: 'Android relay verification',
      pageUrl: selectedPage,
    );
  }
  final catalog = await client.browse(client.homeUrl);
  if (catalog.videos.isEmpty) {
    throw StateError('The live source catalog has no videos.');
  }
  final candidates = [...catalog.videos]
    ..sort(
      (left, right) => (left.durationSeconds ?? 999999).compareTo(
        right.durationSeconds ?? 999999,
      ),
    );
  return candidates.first;
}

Future<({int statusCode, int bytes, bool manifest})> _probeRelay(
  Uri uri,
  VideoStream stream,
) async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await http.getUrl(uri).timeout(const Duration(seconds: 20));
    stream.headers.forEach(request.headers.set);
    if (!stream.isHls) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-65535');
    }
    final response = await request.close().timeout(const Duration(seconds: 45));
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw HttpException(
        'Android relay returned HTTP ${response.statusCode}.',
      );
    }
    if (stream.isHls) {
      final manifest = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 45));
      if (!manifest.startsWith('#EXTM3U')) {
        throw const FormatException(
          'Android relay returned an invalid HLS manifest.',
        );
      }
      return (
        statusCode: response.statusCode,
        bytes: utf8.encode(manifest).length,
        manifest: true,
      );
    }
    final firstChunk = await response.first.timeout(
      const Duration(seconds: 45),
    );
    if (firstChunk.isEmpty) {
      throw const FormatException(
        'Android relay returned an empty media body.',
      );
    }
    return (
      statusCode: response.statusCode,
      bytes: firstChunk.length,
      manifest: false,
    );
  } catch (error) {
    debugPrint('ANDROID_MISSAV relayFetch=false error=${_safeError(error)}');
    rethrow;
  } finally {
    http.close(force: true);
  }
}

Future<bool> _waitForSourceReady(
  WidgetTester tester,
  WebViewController browser,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final ready = await browser.runJavaScriptReturningResult('''
document.readyState === 'complete' && typeof window._cf_chl_opt === 'undefined' &&
!/^Just a moment|Attention Required.*Cloudflare/i.test(document.title)
''');
      if (ready == true || ready == 'true') return true;
    } catch (_) {}
    await tester.pump(const Duration(milliseconds: 250));
  }
  return false;
}

Future<bool> _isChallengePage(WebViewController browser) async {
  try {
    final result = await browser.runJavaScriptReturningResult('''
!!window._cf_chl_opt || /^Just a moment|Attention Required.*Cloudflare/i.test(document.title)
''');
    return result == true || result == 'true';
  } catch (_) {
    return false;
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition,
  Duration timeout,
  String failure,
) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(failure);
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _safeError(Object error) => error
    .toString()
    .replaceAll(RegExp(r'https?://\S+'), '[URL]')
    .replaceAll(
      RegExp(r'(token|auth|key|signature)=([^&\s]+)', caseSensitive: false),
      r'$1=[redacted]',
    );

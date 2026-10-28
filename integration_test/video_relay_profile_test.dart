import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:kikoeru_flutter/src/services/proxy_config.dart';
import 'package:kikoeru_flutter/src/utils/global_keys.dart';
import 'package:kikoeru_flutter/src/videos/missav_browser_media.dart';
import 'package:kikoeru_flutter/src/videos/missav_media_server.dart';
import 'package:kikoeru_flutter/src/videos/missav_verification.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

const _browserChannel = MethodChannel(
  'com.meteor.kikoeruflutter/missav_browser',
);
const _fixtureUrl =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4';
const _chunkSizeBytes = 64 * 1024;
const _base64PartLength = 48 * 1024;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const fixturePath = String.fromEnvironment('KIKOFLU_TEST_VIDEO');

  testWidgets(
    'Android browser relay ACK delay profile',
    (tester) async {
      final file = File(fixturePath);
      expect(
        await file.exists(),
        isTrue,
        reason: 'Install the local video fixture at $fixturePath',
      );
      final fixtureBytes = await file.readAsBytes();
      expect(fixtureBytes, isNotEmpty);

      SharedPreferences.setMockInitialValues({});
      await ProxyConfig.init();
      await _browserChannel.invokeMethod<void>('configureProxy', {
        'mode': ProxyConfig.mode.name,
        'proxyUrl': ProxyConfig.httpsProxyUrl,
      });
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = KikoFluHttpOverrides();
      MediaKit.ensureInitialized();

      WebViewController? browser;
      MissavBrowserMediaTransport? transport;
      OverlayEntry? browserEntry;
      MissavMediaServer? activeServer;
      VideoPlaybackAdvancedSession? visibleSession;
      final surfaceKey = GlobalKey();
      _RelayMetrics? activeMetrics;
      var ackDelay = Duration.zero;
      late StateSetter updateSurface;

      Future<void> runJavaScript(String script) async {
        final ack = RegExp(
          r'__kikoMissavMediaRequests\?\.get\((\d+)\)\?\.acks\.get\((\d+)\)',
        ).firstMatch(script);
        final metrics = activeMetrics;
        final timer = ack == null || metrics == null
            ? null
            : metrics.acknowledge(ack[1]!, ack[2]!);
        if (ack != null && ackDelay > Duration.zero) {
          await Future<void>.delayed(ackDelay);
        }
        try {
          await browser!.runJavaScript(script);
        } finally {
          metrics?.recordAckWait(timer);
        }
      }

      try {
        browser = WebViewController();
        await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
        transport = MissavBrowserMediaTransport(
          runJavaScript: runJavaScript,
          currentUrl: () => missavMobileSourceUrl(browser!),
          disposeBrowser: () => browser!.removeJavaScriptChannel(
            MissavBrowserMediaTransport.channelName,
          ),
        );
        await browser.addJavaScriptChannel(
          MissavBrowserMediaTransport.channelName,
          onMessageReceived: (message) {
            final decoded = jsonDecode(message.message);
            if (decoded is Map) activeMetrics?.receive(decoded);
            transport!.receiveMessage(message.message);
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            home: StatefulBuilder(
              builder: (context, setState) {
                updateSurface = setState;
                return Scaffold(
                  body: RepaintBoundary(
                    key: surfaceKey,
                    child: ColoredBox(
                      color: Colors.black,
                      child:
                          visibleSession?.buildSurface(aspectRatio: 16 / 9) ??
                          const SizedBox.expand(),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        final overlay = rootNavigatorKey.currentState?.overlay;
        if (overlay == null) {
          throw StateError('Application overlay unavailable');
        }
        browserEntry = OverlayEntry(
          builder: (_) => Offstage(
            child: SizedBox(
              width: 1,
              height: 1,
              child: WebViewWidget(controller: browser!),
            ),
          ),
        );
        overlay.insert(browserEntry);
        await WidgetsBinding.instance.endOfFrame;
        await parkMissavMobileBrowser(browser);
        await _installFixtureFetch(browser, fixtureBytes);

        Future<void> showSession(VideoPlaybackAdvancedSession session) async {
          visibleSession = session;
          updateSurface(() {});
          await tester.pump();
          await WidgetsBinding.instance.endOfFrame;
        }

        Future<void> hideSession() async {
          visibleSession = null;
          updateSurface(() {});
          await tester.pump();
        }

        Future<({int statusCode, Uint8List bytes, double elapsedMs})> readRelay(
          Uri localUri,
          _RelayMetrics metrics,
        ) async {
          final client = HttpClient()..findProxy = (_) => 'DIRECT';
          final watch = Stopwatch()..start();
          try {
            final request = await client
                .getUrl(localUri)
                .timeout(const Duration(seconds: 30));
            final response = await request.close().timeout(
              const Duration(seconds: 30),
            );
            final received = BytesBuilder(copy: false);
            await response.forEach(received.add);
            watch.stop();
            await _waitFor(
              tester,
              () => metrics.completedAckCount == metrics.chunkCount,
              timeout: const Duration(seconds: 5),
            );
            return (
              statusCode: response.statusCode,
              bytes: received.takeBytes(),
              elapsedMs: watch.elapsedMicroseconds / 1000,
            );
          } finally {
            client.close(force: true);
          }
        }

        Future<
          ({
            double firstVisibleFrameMs,
            double surfaceReadyMs,
            int rebufferCount,
            double rebufferMs,
            int positionMs,
            int durationMs,
            _RelayMetrics metrics,
          })?
        >
        playFixture(Uri localUri, {required bool collectMetrics}) async {
          final player = Player();
          final session = MediaKitVideoPlaybackSession(player: player);
          await showSession(session);
          final native = player.platform as NativePlayer;
          final playbackMetrics = collectMetrics ? _RelayMetrics() : null;
          final caseWatch = Stopwatch();
          var firstVisibleFrameMs = 0.0;
          var surfaceReadyMs = 0.0;
          var firstFrameSeen = false;
          var playbackRequested = false;
          var rebufferCount = 0;
          var rebufferMicros = 0;
          Stopwatch? currentRebuffer;
          Future<void> observeCachePause(String value) async {
            if (value == 'yes' &&
                firstFrameSeen &&
                playbackRequested &&
                !session.snapshot.value.completed) {
              rebufferCount++;
              currentRebuffer = Stopwatch()..start();
            } else if (value != 'yes' && currentRebuffer != null) {
              rebufferMicros += currentRebuffer?.elapsedMicroseconds ?? 0;
              currentRebuffer = null;
            }
          }

          await native.observeProperty('paused-for-cache', observeCachePause);
          try {
            expect(await _hasVisibleVideoFrame(surfaceKey), isFalse);
            activeMetrics = playbackMetrics;
            final surfaceReady = session
                .videoController
                .waitUntilFirstFrameRendered
                .then((_) {
                  surfaceReadyMs = caseWatch.elapsedMicroseconds / 1000;
                });
            Future<void> observeFirstFrame() async {
              while (!await _hasVisibleVideoFrame(surfaceKey)) {
                if (caseWatch.elapsed > const Duration(seconds: 45)) {
                  final snapshot = session.snapshot.value;
                  fail(
                    'The video surface stayed black for 45 seconds. '
                    'positionMs=${snapshot.position.inMilliseconds}, '
                    'durationMs=${snapshot.duration.inMilliseconds}, '
                    'playing=${snapshot.playing}, '
                    'completed=${snapshot.completed}, '
                    'hasError=${snapshot.error != null}',
                  );
                }
                await tester.pump(const Duration(milliseconds: 25));
              }
              firstVisibleFrameMs = caseWatch.elapsedMicroseconds / 1000;
              firstFrameSeen = true;
            }

            Future<void> loadAndPlay() async {
              await session.loadStream(
                VideoStream(label: 'Relay fixture', url: localUri.toString()),
                position: Duration.zero,
                volume: 0,
              );
              playbackRequested = true;
              await session.play();
            }

            caseWatch.start();
            await Future.wait([
              loadAndPlay(),
              observeFirstFrame(),
              surfaceReady.timeout(const Duration(seconds: 45)),
            ]);
            await _waitFor(
              tester,
              () => session.snapshot.value.completed,
              timeout: const Duration(seconds: 45),
            );
            rebufferMicros += currentRebuffer?.elapsedMicroseconds ?? 0;
            expect(session.snapshot.value.error, isNull);
            if (collectMetrics) {
              final metrics = playbackMetrics!;
              expect(metrics.bytes, greaterThan(0));
              expect(metrics.ackCount, greaterThan(0));
              final snapshot = session.snapshot.value;
              return (
                firstVisibleFrameMs: firstVisibleFrameMs,
                surfaceReadyMs: surfaceReadyMs,
                rebufferCount: rebufferCount,
                rebufferMs: rebufferMicros / 1000,
                positionMs: snapshot.position.inMilliseconds,
                durationMs: snapshot.duration.inMilliseconds,
                metrics: metrics,
              );
            }
            return null;
          } finally {
            await native.unobserveProperty('paused-for-cache');
            await session.pause();
            await hideSession();
            await session.dispose();
          }
        }

        // Keep valid transfer samples even if the device cannot render video.
        final samples = <Map<String, Object?>>[];
        final profile = <String, Object?>{
          'cases': samples,
          'transferStatus': 'running',
          'videoStatus': 'notStarted',
          'limitations': [
            'The WebView fetch stand-in supplies local fixture bytes, not live source media.',
            'firstVisibleFrameMs starts before loadStream and ends at the first sampled non-black RGB pixel; 25ms polling and image readback make it an observation upper bound.',
            'surfaceReadyMs confirms Android surface setup rather than frame presentation.',
            'transferMs measures a complete GET; byte and ACK fields for playback are separate.',
            'Rebuffering counts native paused-for-cache events after a visible frame and a play request, until completion.',
            'Null playback fields mean the video measurement did not complete.',
            'The local four-second fixture does not characterize network or source variability.',
          ],
        };
        binding.reportData = {'videoRelayProfile': profile};

        ackDelay = Duration.zero;
        final warmupServer = await MissavMediaServer.start(transport);
        activeServer = warmupServer;
        final warmupUri = warmupServer.register(Uri.parse(_fixtureUrl));
        final warmupMetrics = _RelayMetrics();
        activeMetrics = warmupMetrics;
        final warmupTransfer = await readRelay(warmupUri, warmupMetrics);
        expect(warmupTransfer.bytes, fixtureBytes);
        await warmupServer.close();
        activeServer = null;
        activeMetrics = null;

        final delaysByRound = <List<int>>[
          [0, 10, 30],
          [10, 30, 0],
          [30, 0, 10],
        ];
        for (
          var roundIndex = 0;
          roundIndex < delaysByRound.length;
          roundIndex++
        ) {
          for (final delayMs in delaysByRound[roundIndex]) {
            ackDelay = Duration(milliseconds: delayMs);
            final server = await MissavMediaServer.start(transport);
            activeServer = server;
            final localUri = server.register(Uri.parse(_fixtureUrl));
            final transferMetrics = _RelayMetrics();
            activeMetrics = transferMetrics;
            final transfer = await readRelay(localUri, transferMetrics);
            activeMetrics = null;
            expect(transfer.statusCode, HttpStatus.ok);
            expect(transfer.bytes, fixtureBytes);
            expect(transferMetrics.bytes, fixtureBytes.length);
            expect(transferMetrics.ackCount, transferMetrics.chunkCount);
            expect(
              transferMetrics.maxChunkBytes,
              lessThanOrEqualTo(_chunkSizeBytes),
            );

            await server.close();
            activeServer = null;
            activeMetrics = null;
            samples.add({
              'round': roundIndex + 1,
              'route': 'browserRelay',
              'ackDelayMs': delayMs,
              'firstVisibleFrameMs': null,
              'surfaceReadyMs': null,
              'transferMs': transfer.elapsedMs,
              'transferBytes': transfer.bytes.length,
              'chunkSizeBytes': transferMetrics.maxChunkBytes,
              'chunkCount': transferMetrics.chunkCount,
              'ackCount': transferMetrics.ackCount,
              'ackWaitTotalMs': transferMetrics.ackWaitTotalMs,
              'playbackBytes': null,
              'playbackChunkSizeBytes': null,
              'playbackChunkCount': null,
              'playbackAckCount': null,
              'playbackAckWaitTotalMs': null,
              'rebufferCount': null,
              'rebufferMs': null,
              'positionMs': null,
              'durationMs': null,
              'fixtureByteLength': fixtureBytes.length,
            });
          }
        }
        profile['transferStatus'] = 'complete';
        profile['videoStatus'] = 'running';
        try {
          ackDelay = Duration.zero;
          final videoWarmupServer = await MissavMediaServer.start(transport);
          activeServer = videoWarmupServer;
          await playFixture(
            videoWarmupServer.register(Uri.parse(_fixtureUrl)),
            collectMetrics: false,
          );
          await videoWarmupServer.close();
          activeServer = null;

          for (final sample in samples) {
            ackDelay = Duration(milliseconds: sample['ackDelayMs']! as int);
            final server = await MissavMediaServer.start(transport);
            activeServer = server;
            final playback = (await playFixture(
              server.register(Uri.parse(_fixtureUrl)),
              collectMetrics: true,
            ))!;
            await server.close();
            await _waitFor(
              tester,
              () =>
                  playback.metrics.completedAckCount ==
                  playback.metrics.ackCount,
              timeout: const Duration(seconds: 5),
            );
            activeServer = null;
            activeMetrics = null;
            final metrics = playback.metrics;
            sample.addAll({
              'firstVisibleFrameMs': playback.firstVisibleFrameMs,
              'surfaceReadyMs': playback.surfaceReadyMs,
              'playbackBytes': metrics.bytes,
              'playbackChunkSizeBytes': metrics.maxChunkBytes,
              'playbackChunkCount': metrics.chunkCount,
              'playbackAckCount': metrics.ackCount,
              'playbackAckWaitTotalMs': metrics.ackWaitTotalMs,
              'rebufferCount': playback.rebufferCount,
              'rebufferMs': playback.rebufferMs,
              'positionMs': playback.positionMs,
              'durationMs': playback.durationMs,
            });
          }
          profile['videoStatus'] = 'complete';
        } catch (error) {
          profile['videoStatus'] = 'failed';
          profile['videoFailure'] = error.toString();
          rethrow;
        }
      } finally {
        activeMetrics = null;
        await activeServer?.close();
        browserEntry?.remove();
        browserEntry?.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        transport?.close();
        if (transport != null) await transport.whenClosed;
        try {
          await _browserChannel.invokeMethod<void>('resetProxy');
        } finally {
          HttpOverrides.global = previousHttpOverrides;
        }
      }
    },
    skip: fixturePath.isEmpty || !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Future<void> _installFixtureFetch(
  WebViewController browser,
  Uint8List fixtureBytes,
) async {
  await browser.runJavaScript('window.__kikoRelayFixtureParts = [];');
  final encoded = base64Encode(fixtureBytes);
  for (var offset = 0; offset < encoded.length; offset += _base64PartLength) {
    final nextOffset = offset + _base64PartLength;
    final end = nextOffset < encoded.length ? nextOffset : encoded.length;
    await browser.runJavaScript(
      'window.__kikoRelayFixtureParts.push(${jsonEncode(encoded.substring(offset, end))});',
    );
  }
  await browser.runJavaScript('''
(() => {
  const fixtureUrl = ${jsonEncode(_fixtureUrl)};
  const fixtureBytes = Uint8Array.from(
    atob(window.__kikoRelayFixtureParts.join('')),
    value => value.charCodeAt(0),
  );
  delete window.__kikoRelayFixtureParts;
  const originalFetch = window.fetch.bind(window);
  window.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url !== fixtureUrl) return originalFetch(input, init);
    const requestHeaders = new Headers(
      init.headers ?? (input instanceof Request ? input.headers : undefined),
    );
    const range = requestHeaders.get('range');
    let start = 0;
    let end = fixtureBytes.length - 1;
    let status = 200;
    const headers = new Headers({
      'accept-ranges': 'bytes',
      'content-type': 'video/mp4',
    });
    if (range !== null) {
      const match = /^bytes=(\\d*)-(\\d*)\$/i.exec(range.trim());
      if (match === null) throw new Error('Unsupported fixture range');
      if (match[1] === '') {
        start = Math.max(0, fixtureBytes.length - Number(match[2]));
      } else {
        start = Number(match[1]);
        if (match[2] !== '') end = Math.min(Number(match[2]), end);
      }
      if (start >= fixtureBytes.length || end < start) {
        headers.set('content-range', 'bytes */' + fixtureBytes.length);
        return new Response(null, {status: 416, headers});
      }
      status = 206;
      headers.set(
        'content-range',
        'bytes ' + start + '-' + end + '/' + fixtureBytes.length,
      );
    }
    const bytes = fixtureBytes.subarray(start, end + 1);
    headers.set('content-length', String(bytes.length));
    const body = new ReadableStream({
      start(controller) {
        controller.enqueue(bytes);
        controller.close();
      },
    });
    const response = new Response(body, {status, headers});
    Object.defineProperty(response, 'url', {value: url});
    return response;
  };
})();
''');
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready, {
  required Duration timeout,
}) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > timeout) fail('MediaKit playback state timed out');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<bool> _hasVisibleVideoFrame(GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 0.1);
  try {
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = pixels!.buffer.asUint8List();
    for (var offset = 0; offset < bytes.length; offset += 4) {
      if (bytes[offset] != 0 ||
          bytes[offset + 1] != 0 ||
          bytes[offset + 2] != 0) {
        return true;
      }
    }
    return false;
  } finally {
    image.dispose();
  }
}

class _RelayMetrics {
  final Map<String, Stopwatch> _chunks = {};
  var bytes = 0;
  var chunkCount = 0;
  var ackCount = 0;
  var completedAckCount = 0;
  var maxChunkBytes = 0;
  var _ackWaitMicros = 0;

  double get ackWaitTotalMs => _ackWaitMicros / 1000;

  void receive(Map message) {
    if (message['type'] != 'chunk' ||
        message['id'] is! int ||
        message['index'] is! int ||
        message['data'] is! String) {
      return;
    }
    final decodedLength = base64Decode(message['data'] as String).length;
    bytes += decodedLength;
    chunkCount++;
    if (decodedLength > maxChunkBytes) maxChunkBytes = decodedLength;
    _chunks['${message['id']}:${message['index']}'] = Stopwatch()..start();
  }

  Stopwatch? acknowledge(String id, String index) {
    final watch = _chunks.remove('$id:$index');
    if (watch == null) return null;
    ackCount++;
    return watch;
  }

  void recordAckWait(Stopwatch? watch) {
    if (watch != null) {
      watch.stop();
      _ackWaitMicros += watch.elapsedMicroseconds;
      completedAckCount++;
    }
  }
}

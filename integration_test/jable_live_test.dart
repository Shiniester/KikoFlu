import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/services/proxy_config.dart';
import 'package:kikoeru_flutter/src/utils/global_keys.dart';
import 'package:kikoeru_flutter/src/videos/jable_client.dart';
import 'package:kikoeru_flutter/src/videos/jable_verification.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_download_task.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  binding.shouldPropagateDevicePointerEvents = true;
  const enabled = bool.fromEnvironment('KIKOFLU_LIVE_JABLE');
  const downloadOnly = bool.fromEnvironment('KIKOFLU_LIVE_JABLE_DOWNLOAD_ONLY');
  const selectedPage = String.fromEnvironment('KIKOFLU_LIVE_JABLE_PAGE');
  const sourceProxy = String.fromEnvironment('KIKOFLU_LIVE_JABLE_PROXY');
  const resumeDirectory = String.fromEnvironment(
    'KIKOFLU_LIVE_JABLE_RESUME_DIRECTORY',
  );

  testWidgets(
    'Jable browser verification, playback, download and offline playback',
    (tester) async {
      await ProxyConfig.init();
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = KikoFluHttpOverrides();
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      if (sourceProxy.isNotEmpty) {
        await ProxyConfig.saveMode(ProxyMode.manual, sourceProxy);
      }
      final library = VideoLibrary(preferences: preferences);
      final client = JableClient(
        restoreSavedSession: restoreJableBrowserSession,
      );
      final missav = MissavClient();
      final Directory root;
      if (resumeDirectory.isEmpty) {
        root = await Directory.systemTemp.createTemp('kikoflu-jable-live-');
      } else {
        expect(p.basename(resumeDirectory), resumeDirectory);
        expect(resumeDirectory.startsWith('kikoflu-jable-live-'), isTrue);
        root = Directory(p.join(Directory.systemTemp.path, resumeDirectory));
        expect(await root.exists(), isTrue);
      }
      debugPrint('JABLE_LIVE tempDirectory=${p.basename(root.path)}');
      final downloads = VideoDownloads(
        client: missav,
        sourceClientFor: (sourceKey) => sourceKey == 'jable' ? client : missav,
        library: library,
        preferences: preferences,
        rootDirectory: Directory(p.join(root.path, 'downloads')),
      );
      final session = MediaKitVideoPlaybackSession();
      final player = session.videoController.player;
      final phase = ValueNotifier<String>('验证 Jable 访问');
      final measurements = <String, dynamic>{
        'source': 'jable',
        'downloadOnly': downloadOnly,
      };
      binding.reportData = measurements;
      var verifiedAll = false;
      final errors = player.stream.error.listen((error) {
        debugPrint('JABLE_LIVE playerError=${_safe(error)}');
      });
      final logs = player.stream.log.listen((log) {
        if (log.prefix.contains('ffmpeg') ||
            const ['error', 'warn', 'fatal'].contains(log.level)) {
          debugPrint('JABLE_LIVE mpv=${log.prefix} ${_safe(log.text)}');
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          locale: const Locale('zh'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                const SafeArea(child: Text('Jable 实测')),
                ValueListenableBuilder<String>(
                  valueListenable: phase,
                  builder: (_, value, _) => Text(value),
                ),
                Offstage(
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
        await client.initialize();
        await _verify(tester, client);
        measurements['browserVerified'] = true;
        debugPrint('JABLE_LIVE browserVerified=true');
        phase.value = '读取目录和详情';
        final catalog = await client.browse(client.homeUrl);
        expect(catalog.videos, isNotEmpty);
        measurements['catalogCount'] = catalog.videos.length;
        debugPrint('JABLE_LIVE catalogCount=${catalog.videos.length}');
        final candidates = [...catalog.videos]
          ..sort(
            (left, right) => (left.durationSeconds ?? 999999).compareTo(
              right.durationSeconds ?? 999999,
            ),
          );
        final video = selectedPage.isEmpty
            ? candidates.first
            : VideoItem(
                id: Uri.parse(
                  selectedPage,
                ).pathSegments.where((s) => s.isNotEmpty).last,
                sourceKey: 'jable',
                title: 'Live verification',
                pageUrl: selectedPage,
              );
        final search = await client.search(video.id);
        expect(search.videos.any((item) => item.id == video.id), isTrue);
        measurements['searchMatched'] = true;
        debugPrint(
          'JABLE_LIVE searchMatched=true resultCount=${search.videos.length}',
        );
        final details = await client.details(video);
        expect(details.streams, isNotEmpty);
        final stream = details.streams.first;
        expect(
          stream.headers.keys.any(
            (key) =>
                const ['cookie', 'authorization'].contains(key.toLowerCase()),
          ),
          isFalse,
        );
        debugPrint(
          'JABLE_LIVE streamCount=${details.streams.length} hls=${stream.isHls}',
        );
        await _probeMedia(stream);

        if (!downloadOnly) {
          phase.value = '检查在线播放与跳转';
          await session.loadStream(stream, position: Duration.zero, volume: 0);
          await session.play();
          await _wait(
            tester,
            () =>
                player.state.position > const Duration(seconds: 1) &&
                (player.state.width ?? 0) > 0 &&
                (player.state.height ?? 0) > 0,
            const Duration(seconds: 60),
            'Jable video did not decode',
          );
          final duration = player.state.duration;
          expect(duration, greaterThan(const Duration(seconds: 8)));
          final middle = Duration(milliseconds: duration.inMilliseconds ~/ 2);
          await session.seek(middle);
          await _wait(
            tester,
            () => player.state.position > middle + const Duration(seconds: 1),
            const Duration(seconds: 45),
            'Jable video did not decode after seeking',
          );
          await session.pause();
          measurements.addAll({
            'onlinePlayback': true,
            'onlineSeek': true,
            'width': player.state.width,
            'height': player.state.height,
            'durationSeconds': duration.inSeconds,
          });
          debugPrint(
            'JABLE_LIVE onlinePlayback=true onlineSeek=true width=${player.state.width} height=${player.state.height} durationSeconds=${duration.inSeconds}',
          );
        }

        phase.value = '检查浏览器会话恢复';
        client.restoreNativeTransport();
        final restoredClient = JableClient(
          restoreSavedSession: restoreJableBrowserSession,
        );
        try {
          await restoredClient.initialize();
          expect(
            (await restoredClient.browse(restoredClient.homeUrl)).videos,
            isNotEmpty,
          );
        } finally {
          restoredClient.dispose();
        }
        debugPrint('JABLE_LIVE sessionRestored=true');
        measurements['sessionRestored'] = true;

        phase.value = '检查下载、暂停和继续';
        await downloads.add(video, stream);
        VideoDownloadTask task() => downloads.forVideo(video.storageKey)!;
        var retryCount = 0;
        Future<bool> completed() async {
          if (task().status == VideoDownloadStatus.failed) {
            if (retryCount == 20) {
              fail('Jable download failed: ${_safe(task().error ?? '')}');
            }
            debugPrint(
              'JABLE_LIVE downloadRetry=${++retryCount} failedProgress=${task().progress} error=${_safe(task().error ?? '')}',
            );
            await downloads.retry(video.storageKey);
          }
          return task().status == VideoDownloadStatus.completed;
        }

        await _wait(
          tester,
          () async => await completed() || task().progress > 0,
          const Duration(minutes: 2),
          'Jable download did not start',
        );
        expect(
          await completed(),
          isFalse,
          reason:
              'The sample completed before pause and resume could be tested',
        );
        await downloads.pause(video.storageKey);
        expect(task().status, VideoDownloadStatus.paused);
        await downloads.resume(video.storageKey);
        var previousPercent = -5;
        await _wait(
          tester,
          () async {
            final done = await completed();
            final percent = (task().progress * 100).floor();
            if (percent ~/ 5 != previousPercent ~/ 5) {
              debugPrint('JABLE_LIVE downloadPercent=$percent');
              phase.value = '下载 Jable 视频 $percent%';
              previousPercent = percent;
            }
            return done;
          },
          const Duration(hours: 4),
          'Jable download did not complete',
        );
        final local = File(task().localPath!);
        expect(await local.exists(), isTrue);
        if (task().isHls) {
          final manifest = await local.readAsString();
          expect(manifest, isNot(contains('https://')));
          expect(manifest, isNot(contains('http://')));
        }
        var bytes = 0;
        await for (final file in root.list(recursive: true)) {
          if (file is File) bytes += await file.length();
        }
        debugPrint(
          'JABLE_LIVE downloadCompleted=true pauseResume=true bytes=$bytes',
        );
        measurements.addAll({
          'downloadCompleted': true,
          'downloadPauseResume': true,
          'downloadRetries': retryCount,
          'downloadBytes': bytes,
        });

        phase.value = '检查离线播放与跳转';
        final native = player.platform;
        if (native is NativePlayer) {
          await native.setProperty('http-proxy', 'http://127.0.0.1:1');
        }
        await session.loadFile(local.path, position: Duration.zero, volume: 0);
        await session.play();
        await _wait(
          tester,
          () =>
              player.state.position > const Duration(seconds: 1) &&
              (player.state.width ?? 0) > 0 &&
              (player.state.height ?? 0) > 0,
          const Duration(seconds: 30),
          'Downloaded Jable video did not decode offline',
        );
        final offlineDuration = player.state.duration;
        expect(offlineDuration, greaterThan(const Duration(seconds: 8)));
        final offlineMiddle = Duration(
          milliseconds: offlineDuration.inMilliseconds ~/ 2,
        );
        await session.seek(offlineMiddle);
        await _wait(
          tester,
          () =>
              player.state.position >
              offlineMiddle + const Duration(seconds: 1),
          const Duration(seconds: 30),
          'Downloaded Jable video did not seek offline',
        );
        await session.pause();
        debugPrint(
          'JABLE_LIVE offlinePlayback=true offlineSeek=true offlineWidth=${player.state.width} offlineHeight=${player.state.height} offlineDurationSeconds=${offlineDuration.inSeconds}',
        );
        measurements.addAll({
          'offlinePlayback': true,
          'offlineSeek': true,
          'offlineWidth': player.state.width,
          'offlineHeight': player.state.height,
          'offlineDurationSeconds': offlineDuration.inSeconds,
        });
        verifiedAll = true;
        phase.value = 'Jable 实测通过';
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await errors.cancel();
        await logs.cancel();
        await session.dispose();
        downloads.dispose();
        library.dispose();
        client.dispose();
        missav.dispose();
        phase.dispose();
        HttpOverrides.global = previousOverrides;
        expect(
          p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
          isTrue,
        );
        expect(p.basename(root.path).startsWith('kikoflu-jable-live-'), isTrue);
        if (verifiedAll) {
          await root.delete(recursive: true);
        } else {
          debugPrint(
            'JABLE_LIVE retainedTempDirectory=${p.basename(root.path)}',
          );
        }
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 270)),
  );
}

Future<void> _probeMedia(VideoStream stream) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    var uri = Uri.parse(stream.url);
    for (var depth = 0; depth < 4; depth++) {
      final request = await client.getUrl(uri);
      stream.headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await utf8.decodeStream(response);
      final playlist = body.trimLeft().startsWith('#EXTM3U');
      debugPrint(
        'JABLE_LIVE mediaStatus=${response.statusCode} contentType=${response.headers.contentType?.mimeType} playlist=$playlist challenge=${response.headers.value('cf-mitigated') == 'challenge'}',
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(playlist, isTrue, reason: 'Jable did not return an HLS playlist');
      final key = RegExp(r'#EXT-X-KEY:[^\r\n]*URI="([^"]+)"').firstMatch(body);
      if (key != null) {
        final request = await client.getUrl(uri.resolve(key.group(1)!));
        stream.headers.forEach(request.headers.set);
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        final bytes = await response.fold<int>(
          0,
          (all, chunk) => all + chunk.length,
        );
        debugPrint(
          'JABLE_LIVE keyStatus=${response.statusCode} keyBytes=$bytes',
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(bytes, 16);
      }
      final resource = const LineSplitter()
          .convert(body)
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
      uri = uri.resolve(resource);
      if (uri.path.endsWith('.m3u8')) continue;
      final segment = await client.getUrl(uri);
      stream.headers.forEach(segment.headers.set);
      segment.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final media = await segment.close().timeout(const Duration(seconds: 30));
      final bytes = await media.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      debugPrint(
        'JABLE_LIVE segmentStatus=${media.statusCode} contentType=${media.headers.contentType?.mimeType} bytes=${bytes.length} prefix=${bytes.take(12).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}',
      );
      expect(media.statusCode, anyOf(HttpStatus.ok, HttpStatus.partialContent));
      expect(bytes, isNotEmpty);
      return;
    }
    fail('Jable playlist nesting exceeded the verification limit');
  } finally {
    client.close(force: true);
  }
}

Future<void> _verify(WidgetTester tester, JableClient client) async {
  bool? verified;
  final result =
      verifyJableAccess(
        tester.element(find.byType(Scaffold).first),
        client,
        sourceUrl: client.homeUrl,
      ).then((value) {
        verified = value;
      });
  await _wait(
    tester,
    () => verified != null || find.byType(WebViewWidget).evaluate().isNotEmpty,
    const Duration(minutes: 1),
    'Jable verification browser did not open',
  );
  if (verified == null) {
    final controller = tester
        .widget<WebViewWidget>(find.byType(WebViewWidget).first)
        .platform
        .params
        .controller;
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    final promptAfter = DateTime.now().add(const Duration(seconds: 30));
    var prompted = false;
    while (verified == null) {
      await tester.pump(const Duration(milliseconds: 500));
      final ready = await controller.runJavaScriptReturningResult('''
location.origin === 'https://jable.tv' && document.readyState === 'complete' &&
!document.title.toLowerCase().startsWith('just a moment') &&
!document.title.toLowerCase().startsWith('attention required') &&
!document.querySelector('#challenge-form')
''');
      if (ready == true) {
        final s = S.of(tester.element(find.byType(Scaffold).first));
        final button = find.widgetWithText(
          FilledButton,
          s.videoVerificationContinue,
        );
        await tester.tap(button);
        break;
      }
      if (!prompted && DateTime.now().isAfter(promptAfter)) {
        final challenge = await controller.runJavaScriptReturningResult('''
document.title.toLowerCase().startsWith('just a moment') ||
document.title.toLowerCase().startsWith('attention required') ||
!!document.querySelector('#challenge-form')
''');
        final atSource = await controller.runJavaScriptReturningResult(
          "location.origin === 'https://jable.tv'",
        );
        debugPrint(
          'JABLE_LIVE awaitingManualVerification=true challenge=$challenge sourceOrigin=$atSource',
        );
        prompted = true;
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('Jable browser verification was not completed');
      }
    }
  }
  await _wait(
    tester,
    () => verified != null,
    const Duration(minutes: 2),
    'Jable browser access check did not finish',
  );
  await result;
  expect(verified, isTrue);
}

Future<void> _wait(
  WidgetTester tester,
  FutureOr<bool> Function() condition,
  Duration timeout,
  String failure,
) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail(failure);
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _safe(String value) =>
    value.replaceAll(RegExp(r'https?://\S+'), '[source URL]');

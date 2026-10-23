import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/utils/global_keys.dart';
import 'package:kikoeru_flutter/src/services/proxy_config.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_verification.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_download_task.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  binding.shouldPropagateDevicePointerEvents = true;
  const enabled = bool.fromEnvironment('KIKOFLU_LIVE_MISSAV');
  const selectedPage = String.fromEnvironment('KIKOFLU_LIVE_MISSAV_PAGE');

  testWidgets(
    'verified source account streams and downloads a real video',
    (tester) async {
      await ProxyConfig.init();
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = KikoFluHttpOverrides();
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final library = VideoLibrary(preferences: preferences);
      final sourceHttp = Dio();
      sourceHttp.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            final path = response.requestOptions.uri.path;
            final route = path.contains('/api/') ? 'api' : 'page';
            debugPrint(
              'MISSAV_LIVE route=$route status=${response.statusCode} challenge=${response.headers.value('cf-mitigated') == 'challenge'}',
            );
            if (route == 'api') {
              final body = response.data is String
                  ? jsonDecode(response.data as String)
                  : response.data;
              debugPrint(
                'MISSAV_LIVE sourceUserField=${body is Map && body.containsKey('user')} sourceUserMap=${body is Map && body['user'] is Map}',
              );
            }
            handler.next(response);
          },
        ),
      );
      final client = MissavClient(dio: sourceHttp);
      final root = await Directory.systemTemp.createTemp(
        'kikoflu-missav-live-',
      );
      final downloads = VideoDownloads(
        client: client,
        library: library,
        preferences: preferences,
        rootDirectory: Directory(p.join(root.path, 'downloads')),
      );
      final player = Player();
      final session = MediaKitVideoPlaybackSession(player: player);
      Future<void> seekAndDecode(Duration position) async {
        await session.seek(position);
        await _wait(
          tester,
          () => player.state.position > position + const Duration(seconds: 1),
          const Duration(seconds: 30),
          'Source video did not decode after seeking',
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                const Text('MissAV live verification'),
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
        await connectMissavBrowserSession(client);
        debugPrint(
          'MISSAV_LIVE browserConnected=true homePath=${Uri.parse(client.homeUrl).path}',
        );
        final catalog = await client.browse(client.homeUrl);
        debugPrint('MISSAV_LIVE catalogCount=${catalog.videos.length}');
        expect(catalog.videos.isNotEmpty, isTrue);
        final candidates = [...catalog.videos]
          ..sort(
            (left, right) => (left.durationSeconds ?? 999999).compareTo(
              right.durationSeconds ?? 999999,
            ),
          );
        final video = selectedPage.isEmpty
            ? candidates.first
            : VideoItem(
                id: Uri.parse(selectedPage).pathSegments.last,
                title: 'Live verification',
                pageUrl: selectedPage,
              );
        final details = await client.details(video);
        debugPrint(
          'MISSAV_LIVE authenticated=${client.isLoggedIn} streamCount=${details.streams.length}',
        );
        expect(details.streams.isNotEmpty, isTrue);
        final streams = [...details.streams]
          ..sort(
            (left, right) =>
                (_quality(left.label)).compareTo(_quality(right.label)),
          );
        final stream = streams.first;
        debugPrint(
          'MISSAV_LIVE mediaHost=${Uri.parse(stream.url).host} hls=${stream.isHls} durationSeconds=${video.durationSeconds}',
        );
        expect(
          stream.headers.keys.any(
            (name) =>
                const ['cookie', 'authorization'].contains(name.toLowerCase()),
          ),
          isFalse,
        );

        final mediaHttp = HttpClient()
          ..connectionTimeout = const Duration(seconds: 20);
        try {
          final request = await mediaHttp.getUrl(Uri.parse(stream.url));
          stream.headers.forEach(request.headers.set);
          if (!stream.isHls) request.headers.set('Range', 'bytes=0-1023');
          final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
          debugPrint(
            'MISSAV_LIVE mediaStatus=${response.statusCode} challenge=${response.headers.value('cf-mitigated') == 'challenge'}',
          );
          if (stream.isHls && response.statusCode == 200) {
            final manifest = await utf8.decodeStream(response);
            debugPrint(
              'MISSAV_LIVE mediaPlaylist=${manifest.startsWith('#EXTM3U')} playlistLines=${manifest.split('\n').length}',
            );
            await _probeMediaRange(mediaHttp, manifest);
          } else {
            await response.drain<void>();
          }
        } finally {
          mediaHttp.close(force: true);
        }
        final playbackErrors = player.stream.error.listen((message) {
          final safe = message.replaceAll(
            RegExp(r'https?://\S+'),
            '[media URL]',
          );
          debugPrint('MISSAV_LIVE playerError=$safe');
        });
        addTearDown(playbackErrors.cancel);

        await session.loadStream(stream, position: Duration.zero, volume: 0);
        await session.play();
        await _wait(
          tester,
          () =>
              player.state.position > const Duration(seconds: 1) &&
              (player.state.width ?? 0) > 0 &&
              (player.state.height ?? 0) > 0,
          const Duration(seconds: 60),
          'Source playback did not decode',
        );
        expect(player.state.duration, greaterThan(const Duration(seconds: 8)));
        await seekAndDecode(
          Duration(milliseconds: player.state.duration.inMilliseconds ~/ 2),
        );
        await session.pause();
        debugPrint(
          'MISSAV_LIVE onlinePlayback=true onlineSeek=true width=${player.state.width} height=${player.state.height}',
        );

        await downloads.add(video, stream);
        await _wait(
          tester,
          () {
            final task = downloads.forVideo(video.id)!;
            if (task.status == VideoDownloadStatus.failed) {
              fail('Source download failed: ${task.error}');
            }
            return task.progress > 0 ||
                task.status == VideoDownloadStatus.completed;
          },
          const Duration(minutes: 2),
          'Source download did not start',
        );
        var resumed = false;
        if (downloads.forVideo(video.id)!.status !=
            VideoDownloadStatus.completed) {
          await downloads.pause(video.id);
          expect(
            downloads.forVideo(video.id)!.status,
            VideoDownloadStatus.paused,
          );
          await downloads.resume(video.id);
          resumed = true;
        }
        var lastProgress = -1;
        await _wait(
          tester,
          () {
            final task = downloads.forVideo(video.id)!;
            if (task.status == VideoDownloadStatus.failed) {
              fail('Source download failed: ${task.error}');
            }
            final progress = (task.progress * 100).floor();
            if (progress ~/ 5 != lastProgress ~/ 5) {
              debugPrint('MISSAV_LIVE downloadPercent=$progress');
              lastProgress = progress;
            }
            return task.status == VideoDownloadStatus.completed;
          },
          const Duration(minutes: 25),
          'Source download did not complete',
        );
        final task = downloads.forVideo(video.id)!;
        final local = File(task.localPath!);
        expect(await local.exists(), isTrue);
        if (task.isHls) {
          expect(await local.readAsString(), isNot(contains('https://')));
          expect(await local.readAsString(), isNot(contains('http://')));
        }
        var bytes = 0;
        await for (final entry in root.list(recursive: true)) {
          if (entry is File) bytes += await entry.length();
        }
        debugPrint(
          'MISSAV_LIVE downloadCompleted=true pauseResume=$resumed bytes=$bytes',
        );
        client.restoreNativeTransport();
        final native = player.platform;
        if (native is NativePlayer) {
          await native.setProperty('http-proxy', 'http://127.0.0.1:1');
        }
        await session.loadFile(local.path, position: Duration.zero, volume: 0);
        expect(
          player.state.position,
          lessThan(const Duration(milliseconds: 250)),
        );
        await session.play();
        await _wait(
          tester,
          () => player.state.position > const Duration(seconds: 1),
          const Duration(seconds: 30),
          'Downloaded source video did not play offline',
        );
        final offlineDuration = player.state.duration;
        expect(offlineDuration, greaterThan(const Duration(seconds: 8)));
        await seekAndDecode(
          Duration(milliseconds: offlineDuration.inMilliseconds ~/ 2),
        );
        await seekAndDecode(offlineDuration - const Duration(seconds: 4));
        await session.pause();
        debugPrint(
          'MISSAV_LIVE offlinePlayback=true offlineSeekMiddle=true offlineSeekEnd=true',
        );
        if (!client.isLoggedIn) {
          debugPrint('MISSAV_LIVE awaitingManualLogin=true');
          final verified = await verifyMissavAccess(
            tester.element(find.byType(Scaffold).first),
            client,
            sourceUrl: client.homeUrl,
          );
          expect(verified, isTrue);
          await client.details(video);
          expect(client.isLoggedIn, isTrue);
          debugPrint('MISSAV_LIVE manualLoginConfirmed=true');
        }
        await connectMissavBrowserSession(client);
        await client.details(video);
        expect(client.isLoggedIn, isTrue);
        debugPrint('MISSAV_LIVE sessionRestored=true');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
        downloads.dispose();
        library.dispose();
        client.dispose();
        HttpOverrides.global = previousHttpOverrides;
        expect(
          p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
          isTrue,
        );
        expect(
          p.basename(root.path).startsWith('kikoflu-missav-live-'),
          isTrue,
        );
        await root.delete(recursive: true);
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

Future<void> _probeMediaRange(HttpClient client, String manifest) async {
  for (var depth = 0; depth < 4; depth++) {
    final resource = const LineSplitter()
        .convert(manifest)
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
    final uri = Uri.parse(resource);
    final request = await client.getUrl(uri);
    final isPlaylist = uri.path.endsWith('.m3u8');
    if (!isPlaylist) request.headers.set('Range', 'bytes=1-1023');
    final response = await request.close();
    if (isPlaylist) {
      manifest = await utf8.decodeStream(response);
      continue;
    }
    final count = await response.fold<int>(
      0,
      (total, bytes) => total + bytes.length,
    );
    debugPrint(
      'MISSAV_LIVE rangeStatus=${response.statusCode} contentRange=${response.headers.value('content-range') != null} rangeBytes=$count',
    );
    return;
  }
  fail('Media playlist nesting exceeded the verification limit');
}

int _quality(String label) =>
    int.tryParse(RegExp(r'\d+').firstMatch(label)?.group(0) ?? '') ?? 99999;

Future<void> _wait(
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

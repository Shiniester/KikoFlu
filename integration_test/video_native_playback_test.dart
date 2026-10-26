import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart' as audio;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_media_server.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/video_download_task.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const fixturePath = String.fromEnvironment('KIKOFLU_TEST_VIDEO');

  testWidgets(
    'downloaded video decodes offline alongside independent audio',
    (tester) async {
      MediaKit.ensureInitialized();
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        JustAudioMediaKit.ensureInitialized();
      }
      const storage = FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      );
      const storageKey = 'kikoflu_video_native_test_session';
      try {
        await storage.write(key: storageKey, value: 'sample-session');
        expect(await storage.read(key: storageKey), 'sample-session');
      } finally {
        await storage.delete(key: storageKey);
      }
      expect(await storage.read(key: storageKey), isNull);
      final fixture = File(fixturePath);
      expect(await fixture.exists(), isTrue);
      final extension = fixturePath.endsWith('.m3u8') ? 'm3u8' : 'mp4';
      final root = await Directory.systemTemp.createTemp('kikoflu native 视频-');
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final library = VideoLibrary(preferences: preferences);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final file = request.uri.path == '/video.$extension'
            ? fixture
            : File.fromUri(
                fixture.parent.uri.resolve(request.uri.pathSegments.last),
              );
        request.response.headers.contentType = file.path.endsWith('.m3u8')
            ? ContentType('application', 'vnd.apple.mpegurl')
            : ContentType.binary;
        request.response.contentLength = await file.length();
        await request.response.addStream(file.openRead());
        await request.response.close();
      });
      final page = 'http://127.0.0.1:${server.port}/video';
      final video = VideoItem(
        id: 'native-fixture',
        title: 'Video',
        pageUrl: page,
      );
      final stream = VideoStream(label: 'Source', url: '$page.$extension');
      final client = _FixtureClient(video, stream);
      final downloads = VideoDownloads(
        client: client,
        library: library,
        rootDirectory: Directory('${root.path}/downloads'),
        preferences: preferences,
      );
      final player = Player();
      final session = MediaKitVideoPlaybackSession(player: player);
      final sound = audio.AudioPlayer();
      try {
        await downloads.add(video, stream);
        await _wait(
          tester,
          () =>
              downloads.forVideo(video.id)?.status ==
              VideoDownloadStatus.completed,
        );
        await server.close(force: true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 640,
                  child: session.buildSurface(aspectRatio: 16 / 9),
                ),
              ),
            ),
          ),
        );
        await session.loadFile(
          downloads.forVideo(video.id)!.localPath!,
          position: const Duration(seconds: 1),
          volume: 0,
        );
        final wav = File('${root.path}/silence.wav');
        await wav.writeAsBytes(_silenceWav());
        await sound.setFilePath(wav.path);
        await sound.setVolume(0.2);
        await session.setVolume(60);
        await _wait(tester, () => player.state.volume == 60);
        expect(sound.volume, 0.2);
        expect(player.state.volume, 60);
        await session.setVolume(0);
        await _wait(tester, () => player.state.volume == 0);
        unawaited(sound.play());
        await session.play();
        await _wait(
          tester,
          () =>
              player.state.position > const Duration(milliseconds: 1300) &&
              sound.position > const Duration(milliseconds: 200),
        );
        expect(player.state.width, greaterThan(0));
        expect(player.state.height, greaterThan(0));
        await sound.setVolume(0.4);
        expect(player.state.volume, 0);
        await session.pause();
        final audioPosition = sound.position;
        await _wait(
          tester,
          () =>
              sound.position >
              audioPosition + const Duration(milliseconds: 200),
        );
        expect(player.state.playing, isFalse);
        expect(sound.playing, isTrue);
        expect(client.detailsCalls, 1);
        final native = player.platform;
        if (Platform.isWindows && native is NativePlayer) {
          expect(
            await native.getProperty('load-unsafe-playlists'),
            extension == 'm3u8' ? 'yes' : 'no',
          );
          await session.loadFile(wav.path, position: Duration.zero, volume: 0);
          expect(await native.getProperty('load-unsafe-playlists'), 'no');
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await sound.dispose();
        await session.dispose();
        downloads.dispose();
        library.dispose();
        client.dispose();
        await server.close(force: true);
        expect(
          await root.parent.resolveSymbolicLinks(),
          await Directory.systemTemp.resolveSymbolicLinks(),
        );
        await root.delete(recursive: true);
      }
    },
    skip: fixturePath.isEmpty,
  );

  testWidgets(
    'Android relay open errors terminate the native player load',
    (tester) async {
      MediaKit.ensureInitialized();
      final transport = _FailingTransport();
      final server = await MissavMediaServer.start(transport);
      final player = Player();
      final session = MediaKitVideoPlaybackSession(player: player);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: session.buildSurface(aspectRatio: 16 / 9)),
        ),
      );
      final stream = VideoStream(
        label: 'Rejected relay response',
        url: server
            .register(Uri.parse('https://surrit.com/fixture.mp4'))
            .toString(),
      );

      try {
        final opening = session.loadStream(
          stream,
          position: Duration.zero,
          volume: 0,
        );
        await _wait(tester, () => session.snapshot.value.error != null);
        expect(session.snapshot.value.error, isNotEmpty);
        expect(session.snapshot.value.buffering, isTrue);
        expect(transport.openCount, 1);
        await opening.timeout(const Duration(seconds: 2));
        debugPrint(
          'ANDROID_RELAY requestCount=${transport.openCount} errorReported=true openCompleted=true buffering=true',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
        await server.close();
      }
    },
    skip: !Platform.isAndroid,
  );
}

Future<void> _wait(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Native playback did not advance');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Uint8List _silenceWav() {
  const dataLength = 16000 * 8;
  final bytes = Uint8List(44 + dataLength);
  final header = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  header.setUint32(4, 36 + dataLength, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 8000, Endian.little);
  header.setUint32(28, 16000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  header.setUint32(40, dataLength, Endian.little);
  return bytes;
}

class _FixtureClient extends MissavClient {
  _FixtureClient(this.video, this.stream);
  final VideoItem video;
  final VideoStream stream;
  int detailsCalls = 0;

  @override
  Future<VideoDetails> details(
    VideoItem item, {
    FutureOr<void> Function(VideoDetails)? onReady,
  }) async {
    detailsCalls++;
    return VideoDetails(video: video, streams: [stream]);
  }
}

class _FailingTransport implements RemoteAssetTransport {
  int openCount = 0;

  @override
  Future<RemoteAssetResponse> open(RemoteAssetTransportRequest request) async {
    openCount++;
    return const RemoteAssetResponse(
      statusCode: HttpStatus.badGateway,
      headers: {'content-type': 'text/plain'},
      stream: Stream<List<int>>.empty(),
    );
  }
}

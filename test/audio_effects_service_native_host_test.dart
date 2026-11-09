import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as audio;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart' as model;
import 'package:kikoeru_flutter/src/models/audio_effects_settings.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/native_audio_effects.dart';
import '../integration_test/audio_effects_native_helpers.dart';
import '../integration_test/audio_backend_native_fixture.dart';
import 'audio_player_latest_request_test.dart' show MemorySessionStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['KIKOFLU_AUDIO_LIBMPV'];
  setUpAll(() {
    if (library != null) {
      JustAudioMediaKit.pitch = false;
      JustAudioMediaKit.ensureInitialized(windows: true, libmpv: library);
    }
  });
  for (final clipped in [true, false]) {
    test(
      'native adapter restores ${clipped ? 'chapter' : 'whole source'} initial positions',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'kiko-initial-position-',
        );
        final source = File('${directory.path}/source.wav');
        await source.writeAsBytes(
          gzip.decode(base64Decode(audioBackendWavGzipBase64)),
        );
        final player = audio.AudioPlayer(
          androidApplyAudioAttributes: false,
          useProxyForRequestHeaders: false,
          handleInterruptions: false,
          handleAudioSessionActivation: false,
        );
        late NativePlayer native;
        late Future<Duration> restored;
        await JustAudioMediaKit.configurePlayer(player.platformId, (
          value,
        ) async {
          native = value;
          await native.setProperty('ao', 'null');
          restored = native.stream.position.firstWhere(
            (position) => position >= const Duration(seconds: 6),
          );
        });
        final child = audio.AudioSource.uri(source.uri);
        try {
          final duration = await player
              .setAudioSource(
                clipped
                    ? audio.ClippingAudioSource(
                        child: child,
                        start: const Duration(seconds: 4),
                        end: const Duration(seconds: 20),
                      )
                    : child,
                initialPosition: const Duration(seconds: 6),
              )
              .timeout(const Duration(seconds: 10));
          await restored.timeout(const Duration(seconds: 10));
          expect(duration, Duration(seconds: clipped ? 16 : 24));
          expect(
            double.parse(await native.getProperty('time-pos')),
            closeTo(clipped ? 10 : 6, .05),
            reason:
                'A six-second chapter position starts ten seconds into a source clipped from four seconds.',
          );
          expect(
            player.playbackEvent.updatePosition.inMilliseconds,
            closeTo(6000, 50),
          );
          final ordinarySeek = native.stream.position.firstWhere(
            (position) => position == Duration(seconds: clipped ? 7 : 3),
          );
          await player.seek(const Duration(seconds: 3));
          await ordinarySeek.timeout(const Duration(seconds: 10));
          expect(
            double.parse(await native.getProperty('time-pos')),
            closeTo(clipped ? 7 : 3, .05),
          );
          expect(
            player.playbackEvent.updatePosition.inMilliseconds,
            closeTo(3000, 50),
          );
        } finally {
          await player.dispose();
          JustAudioMediaKit.forgetPlayerConfiguration(player.platformId);
          await directory.delete(recursive: true);
        }
      },
      skip: library == null
          ? 'Set KIKOFLU_AUDIO_LIBMPV to run real adapter/native positions.'
          : false,
    );
  }

  test(
    'native prepared chapter retains sixteen-second duration after promotion',
    () async {
      final wav = gzip.decode(base64Decode(audioBackendWavGzipBase64));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final prepared = Completer<String>();
      late NativePlayer native;
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final start = range == null
            ? 0
            : int.parse(range.split('=')[1].split('-')[0]);
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.statusCode = range == null
            ? HttpStatus.ok
            : HttpStatus.partialContent;
        if (range != null) {
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${wav.length - 1}/${wav.length}',
          );
        }
        request.response.contentLength = wav.length - start;
        request.response.add(wav.sublist(start));
        await request.response.close();
        if (request.uri.path == '/B.wav' && !prepared.isCompleted) {
          prepared.complete(await native.getProperty('playlist-pos'));
        }
      });
      final player = audio.AudioPlayer(
        androidApplyAudioAttributes: false,
        useProxyForRequestHeaders: false,
        handleInterruptions: false,
        handleAudioSessionActivation: false,
      );
      await JustAudioMediaKit.configurePlayer(player.platformId, (value) async {
        native = value;
        await native.setProperty('ao', 'null');
        await native.setProperty('prefetch-playlist', 'yes');
      });
      try {
        final origin = 'http://127.0.0.1:${server.port}';
        await player
            .setAudioSource(
              audio.ConcatenatingAudioSource(
                children: [
                  audio.AudioSource.uri(Uri.parse('$origin/A.wav')),
                  audio.ClippingAudioSource(
                    child: audio.AudioSource.uri(Uri.parse('$origin/B.wav')),
                    start: const Duration(seconds: 4),
                    end: const Duration(seconds: 20),
                  ),
                ],
              ),
            )
            .timeout(const Duration(seconds: 10));
        await player.seek(const Duration(seconds: 20));
        unawaited(player.play());
        expect(
          await prepared.future.timeout(const Duration(seconds: 10)),
          '0',
          reason: 'B must be requested while native playback still owns A.',
        );
        await player.pause();
        final promoted = player.playbackEventStream.firstWhere(
          (event) =>
              event.currentIndex == 1 &&
              event.duration == const Duration(seconds: 16) &&
              event.updatePosition >= const Duration(milliseconds: 500),
        );
        await player.seek(null, index: 1);
        unawaited(player.play());
        await promoted.timeout(const Duration(seconds: 10));
        await player.pause();
        expect(player.duration, const Duration(seconds: 16));
        expect(
          double.parse(await native.getProperty('time-pos')),
          inInclusiveRange(4, 7),
        );
        expect(
          player.playbackEvent.updatePosition,
          lessThan(const Duration(seconds: 3)),
        );
      } finally {
        await player.dispose();
        JustAudioMediaKit.forgetPlayerConfiguration(player.platformId);
        await server.close(force: true);
      }
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIBMPV to run real adapter/native positions.'
        : false,
  );

  test(
    'service updates only its own native audio and survives stop recreation',
    () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final directory = await Directory.systemTemp.createTemp(
        'kiko-effects-service-',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path,
          );
      final source = File('${directory.path}/source.wav');
      final frames = List.generate(
        48017,
        (n) => (1000 + n % 997, -3000 - n % 991),
      );
      await source.writeAsBytes(audioEffectsWav(frames, 48000));
      final player = audio.AudioPlayer(
        androidApplyAudioAttributes: false,
        useProxyForRequestHeaders: false,
        handleInterruptions: false,
        handleAudioSessionActivation: false,
      );
      late NativePlayer native;
      final output = File('${directory.path}/capture.pcm');
      var initializations = 0;
      final service = AudioPlayerService.forTesting(
        player,
        nativePlayerId: player.platformId,
        sessionStore: MemorySessionStore(),
        nativePlayerInitializer: (value) async {
          native = value;
          initializations++;
          for (final entry in {
            'ao': 'pcm',
            'ao-pcm-waveheader': 'no',
            'ao-pcm-file': output.path,
            'audio-format': 'float',
            'audio-samplerate': '48000',
            'audio-channels': 'stereo',
          }.entries) {
            await native.setProperty(entry.key, entry.value);
          }
        },
      );
      final videoReady = Completer<void>();
      final video = Player(
        configuration: PlayerConfiguration(ready: videoReady.complete),
      );
      await videoReady.future;
      final videoNative = video.platform as NativePlayer;
      final track = model.AudioTrack(
        id: 'source',
        title: 'source.wav',
        url: source.uri.toString(),
      );
      try {
        await service.updateAudioEffects(
          AudioEffectsSettings(
            channelMode: AudioChannelMode.cloneRight,
            binauralMode: BinauralMode.stereo,
            stereoAmount: 100,
          ),
        );
        await service.updateQueue([track]);
        expect(service.currentTrack?.id, 'source');
        final initialNative = native;
        final path = await native.getProperty('path');
        final position = player.position;
        final settings = AudioEffectsSettings(
          channelMode: AudioChannelMode.cloneRight,
          binauralMode: BinauralMode.stereo,
          stereoAmount: 100,
        );
        expect(await native.getProperty('ao'), 'pcm');
        expect(await native.getProperty('path'), path);
        expect(player.position, position);
        expect(service.queue.map((track) => track.id), ['source']);
        expect(await videoNative.getProperty('af'), '');
        await service.play();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while ((double.tryParse(await native.getProperty('time-pos')) ?? 0) <
                frames.length / 48000 - .00001 ||
            await native.getProperty('eof-reached') != 'yes') {
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('Native source did not reach its end');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await player.stop();
        final actual = audioEffectsPcm(await output.readAsBytes());
        expect(actual.length, frames.length);
        for (var n = 4096; n < frames.length; n++) {
          expect(actual[n], (frames[n].$2 / 32768, frames[n].$2 / 32768));
        }
        expect(service.audioEffectsStatus, AudioEffectsStatus.ready);
        await service.updateAudioEffects(
          settings.copyWith(
            channelMode: AudioChannelMode.cloneLeft,
            binauralMode: BinauralMode.mono,
            monoAmount: 100,
          ),
        );
        await player.setFilePath(source.path);
        expect(initializations, 2);
        expect(identical(initialNative, native), false);
        // Retained service configuration initializes the recreated instance.
        await service.updateAudioEffects(
          settings.copyWith(
            channelMode: AudioChannelMode.cloneLeft,
            binauralMode: BinauralMode.mono,
            monoAmount: 100,
          ),
        );
        expect(
          await native.getProperty('af'),
          contains('volume@channel_mode=2'),
        );
        expect(
          await native.getProperty('af'),
          contains('volume@mono_amount=1.0'),
        );
        await service.play();
        final monoDeadline = DateTime.now().add(const Duration(seconds: 10));
        while (await native.getProperty('eof-reached') != 'yes') {
          if (DateTime.now().isAfter(monoDeadline)) {
            throw TimeoutException('Recreated mono source did not drain');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await player.stop();
        final mono = audioEffectsPcm(await output.readAsBytes());
        expect(mono.length, frames.length);
        for (var n = 0; n < mono.length; n++) {
          expect(
            (mono[n].$1 + mono[n].$2) / 2,
            closeTo(frames[n].$1 / 32768, 1e-7),
          );
        }
        expect(mono.any((row) => (row.$1 - row.$2).abs() > 1e-5), true);
        expect(await videoNative.getProperty('af'), '');
      } finally {
        await service.dispose();
        await video.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await directory.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIBMPV to run real service/native output.'
        : false,
  );

  test(
    'service speed preserves pitch, resident effects, and neutral pitch loading',
    () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final directory = await Directory.systemTemp.createTemp(
        'kiko-effects-speed-',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path,
          );
      final source = File('${directory.path}/tone.wav');
      final frames = List.generate(
        192017,
        (n) => (
          (6000 * math.sin(2 * math.pi * 1000 * n / 48000)).round(),
          (5000 * math.sin(2 * math.pi * 1700 * n / 48000)).round(),
        ),
      );
      await source.writeAsBytes(audioEffectsWav(frames, 48000));
      final output = File('${directory.path}/capture.pcm');
      final player = audio.AudioPlayer(
        androidApplyAudioAttributes: false,
        useProxyForRequestHeaders: false,
        handleInterruptions: false,
        handleAudioSessionActivation: false,
      );
      late NativePlayer native;
      final service = AudioPlayerService.forTesting(
        player,
        nativePlayerId: player.platformId,
        sessionStore: MemorySessionStore(),
        nativePlayerInitializer: (value) async {
          native = value;
          for (final entry in {
            'ao': 'pcm',
            'ao-pcm-waveheader': 'no',
            'ao-pcm-file': output.path,
            'audio-format': 'float',
            'audio-samplerate': '48000',
            'audio-channels': 'stereo',
          }.entries) {
            await native.setProperty(entry.key, entry.value);
          }
        },
      );
      try {
        await service.updateAudioEffects(
          AudioEffectsSettings(channelMode: AudioChannelMode.cloneLeft),
        );
        await service.setSpeed(1.5);
        await service.updateQueue([
          model.AudioTrack(
            id: 'tone',
            title: 'tone.wav',
            url: source.uri.toString(),
          ),
        ], autoplay: true);
        final graph = await native.getProperty('af');
        expect(graph, contains('@kiko_channel'));
        expect(await native.getProperty('audio-pitch-correction'), 'yes');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while ((double.tryParse(await native.getProperty('time-pos')) ?? 0) <
            frames.length / 48000 - .00001) {
          if (player.processingState == audio.ProcessingState.completed ||
              await native.getProperty('eof-reached') == 'yes' ||
              await native.getProperty('idle-active') == 'yes') {
            break;
          }
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException(
              'Native speed source did not reach its end: ${await native.getProperty('time-pos')} / ${await native.getProperty('eof-reached')}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await service.setSpeed(1.25);
        expect(await native.getProperty('af'), graph);
        await service.setSpeed(1.5);
        expect(await native.getProperty('af'), graph);
        expect(double.parse(await native.getProperty('speed')), 1.5);
        await expectLater(player.setPitch(1.1), throwsArgumentError);
        await player.setPitch(1);
        await player.stop();
        final actual = audioEffectsPcm(await output.readAsBytes());
        expect(frames.length / actual.length, closeTo(1.5, .03));
        final section = actual
            .skip(actual.length ~/ 4)
            .take(actual.length ~/ 2)
            .toList();
        final crossings = List.generate(
          section.length - 1,
          (n) => section[n].$1 <= 0 && section[n + 1].$1 > 0,
        ).where((crossed) => crossed).length;
        expect(crossings * 48000 / section.length, closeTo(1000, 3));
        expect(actual.every((row) => row.$1 == row.$2), true);
      } finally {
        await service.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await directory.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIBMPV to run real service/native output.'
        : false,
  );
}

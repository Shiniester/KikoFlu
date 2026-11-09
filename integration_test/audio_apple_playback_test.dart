import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart'
    show AudioPlayer, PlayerState, ProcessingState;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:kikoeru_flutter/src/models/audio_effects_settings.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/playback_diagnostic_event.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/native_audio_effects.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_effects_native_helpers.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const library = String.fromEnvironment('KIKOFLU_AUDIO_LIBMPV');
  final supported =
      Platform.isIOS ||
      Platform.isMacOS ||
      (Platform.isWindows && library.isNotEmpty);

  setUpAll(() {
    if (supported) {
      JustAudioMediaKit.ensureInitialized(
        iOS: Platform.isIOS,
        macOS: Platform.isMacOS,
        windows: Platform.isWindows,
        libmpv: library.isEmpty ? null : library,
      );
    }
  });

  testWidgets(
    'native player loads loopback audio, advances, and applies an effect',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );

      final directory = await Directory.systemTemp.createTemp(
        'kikoflu-apple-audio-',
      );
      final bytes = audioEffectsWav(
        List.generate(240017, (n) => (1000 + n % 997, -3000 - n % 991)),
        48000,
      );
      final output = File('${directory.path}/playback.pcm');
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        if (request.uri.path != '/audio.wav') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        await _sendWav(request, bytes);
      });

      final player = AudioPlayer(
        useProxyForRequestHeaders: false,
        handleInterruptions: false,
        handleAudioSessionActivation: false,
        androidApplyAudioAttributes: false,
      );
      late NativePlayer native;
      final service = AudioPlayerService.forTesting(
        player,
        nativePlayerId: player.platformId,
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
      final states = <PlayerState>[];
      final diagnostics = <PlaybackDiagnosticEvent>[];
      final streamErrors = <Object>[];
      final stateSubscription = service.playerStateStream.listen(
        states.add,
        onError: streamErrors.add,
      );
      final diagnosticSubscription = service.playbackDiagnosticEventStream
          .listen(diagnostics.add, onError: streamErrors.add);

      try {
        final settings = AudioEffectsSettings();
        await service.updateAudioEffects(settings);
        await service.updateQueue([
          AudioTrack(
            id: 'apple-native-smoke',
            title: 'fixture.wav',
            url: 'http://127.0.0.1:${server.port}/audio.wav',
          ),
        ]);
        expect(service.currentTrack?.id, 'apple-native-smoke');
        expect(service.playerState.processingState, ProcessingState.ready);
        expect(service.duration, greaterThan(Duration.zero));

        final effectReady = service.audioEffectsStatusStream
            .firstWhere((status) => status == AudioEffectsStatus.ready)
            .timeout(const Duration(seconds: 10));
        final advancedPosition = service.positionStream
            .firstWhere((position) => position > Duration.zero)
            .timeout(const Duration(seconds: 10));
        await service.updateAudioEffects(
          settings.copyWith(channelMode: AudioChannelMode.cloneLeft),
        );
        await service.play();
        final position = await advancedPosition;
        await effectReady;
        final cloned = await _waitForClonedPcm(output);

        expect(requests, contains('GET /audio.wav'));
        expect(position, greaterThan(Duration.zero));
        expect(cloned.$1, greaterThan(0.02));
        expect(cloned.$2, closeTo(cloned.$1, 0.000001));
        expect(states.any((state) => state.playing), isTrue);
        expect(await native.getProperty('ao'), 'pcm');
        expect(await native.getProperty('af'), contains('@kiko_channel'));
        expect(service.audioEffectsStatus, AudioEffectsStatus.ready);
        expect(
          diagnostics.where(
            (event) =>
                event.type == PlaybackDiagnosticEventType.trackLoadFailed ||
                event.type == PlaybackDiagnosticEventType.playbackError,
          ),
          isEmpty,
        );
        expect(streamErrors, isEmpty);

        await service.stop();
        expect(await output.exists(), isTrue);
        expect(await output.length(), greaterThan(0));
      } finally {
        await stateSubscription.cancel();
        await diagnosticSubscription.cancel();
        try {
          await service.dispose();
        } finally {
          try {
            await server.close(force: true);
          } finally {
            await directory.delete(recursive: true);
          }
        }
      }
    },
    skip: !supported,
  );
}

Future<(double, double)> _waitForClonedPcm(File output) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (await output.exists()) {
      final bytes = await output.readAsBytes();
      final end = bytes.length - bytes.length % 8;
      final start = end > 8192 ? end - 8192 : 0;
      var matching = 0;
      for (final sample in audioEffectsPcm(bytes.sublist(start, end))) {
        if (sample.$1 > 0.02 && (sample.$1 - sample.$2).abs() < 0.000001) {
          if (++matching >= 64) return sample;
        } else {
          matching = 0;
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException(
    'Native player did not output the cloned left channel',
  );
}

Future<void> _sendWav(HttpRequest request, List<int> bytes) async {
  final response = request.response;
  final range = request.headers.value(HttpHeaders.rangeHeader) ?? '';
  response.headers.contentType = ContentType('audio', 'wav');
  response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  var start = 0;
  var end = bytes.length - 1;
  if (range.isNotEmpty) {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
    start = int.parse(match.group(1)!);
    if (match.group(2)!.isNotEmpty) end = int.parse(match.group(2)!);
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${bytes.length}',
    );
  }
  response.contentLength = end - start + 1;
  if (request.method != 'HEAD') response.add(bytes.sublist(start, end + 1));
  await response.close();
}

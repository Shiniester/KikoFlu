import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kikoeru_flutter/src/models/audio_effects_settings.dart';
import 'package:kikoeru_flutter/src/services/native_audio_effects.dart';
import '../integration_test/audio_effects_native_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['KIKOFLU_AUDIO_LIMITED_LIBMPV'];
  setUpAll(() {
    if (library != null) MediaKit.ensureInitialized(libmpv: library);
  });
  test(
    'limited-library preflight preserves the first HTTP track when filters are missing',
    () async {
      debugDefaultTargetPlatformOverride = Platform.isWindows
          ? TargetPlatform.windows
          : TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final ready = Completer<void>();
      final player = Player(
        configuration: PlayerConfiguration(ready: ready.complete),
      );
      await ready.future.timeout(const Duration(seconds: 10));
      final native = player.platform as NativePlayer;
      final statuses = <AudioEffectsStatus>[];
      final controller = NativeAudioEffects(statuses.add);
      final directory = await Directory.systemTemp.createTemp(
        'kiko-effects-missing-',
      );
      final output = File('${directory.path}/capture.pcm');
      final frames = List.generate(
        24017,
        (n) => (1000 + n % 997, -3000 - n % 991),
      );
      final wav = audioEffectsWav(frames, 48000);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) {
        requests++;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('audio', 'wav')
          ..contentLength = wav.length;
        if (request.method != 'HEAD') request.response.add(wav);
        unawaited(request.response.close());
      });
      try {
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
        await controller.configure(native, AudioEffectsSettings(), false);
        final initialStatus = statuses.last;
        final initialAf = await native.getProperty('af');
        final completed = player.stream.completed.firstWhere((done) => done);
        await player.open(Media('http://127.0.0.1:${server.port}/source.wav'));
        await completed.timeout(const Duration(seconds: 10));
        await player.stop();
        expect(requests, greaterThan(0));
        final actual = audioEffectsPcm(await output.readAsBytes());
        expect(actual.length, frames.length);
        for (var n = 0; n < frames.length; n++) {
          expect(actual[n], (frames[n].$1 / 32768, frames[n].$2 / 32768));
        }
        expect(initialStatus, AudioEffectsStatus.unavailable);
        expect(initialAf, '');
        expect(statuses, contains(AudioEffectsStatus.unavailable));
        await controller.configure(
          native,
          AudioEffectsSettings(channelMode: AudioChannelMode.swap),
          false,
        );
        expect(statuses, contains(AudioEffectsStatus.unavailable));
        expect(await native.getProperty('af'), '');
      } finally {
        await controller.dispose();
        await player.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIMITED_LIBMPV to check a limited libmpv.'
        : false,
  );
}

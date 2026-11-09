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
    'system-library preflight preserves dry playback when filters are missing',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
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
      final source = File('${directory.path}/source.wav');
      final output = File('${directory.path}/capture.pcm');
      final frames = List.generate(
        24017,
        (n) => (1000 + n % 997, -3000 - n % 991),
      );
      await source.writeAsBytes(audioEffectsWav(frames, 48000));
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
        await controller.configure(
          native,
          AudioEffectsSettings(
            equalizerEnabled: true,
            gains: AudioEffectsSettings.curves[EqualizerPreset.vocal],
          ),
          false,
        );
        final completed = player.stream.completed.firstWhere((done) => done);
        await player.open(Media(source.path));
        await completed.timeout(const Duration(seconds: 10));
        await player.stop();
        final actual = audioEffectsPcm(await output.readAsBytes());
        expect(actual.length, frames.length);
        for (var n = 0; n < frames.length; n++) {
          expect(actual[n], (frames[n].$1 / 32768, frames[n].$2 / 32768));
        }
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
        await directory.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIMITED_LIBMPV to check missing filters.'
        : false,
  );
}

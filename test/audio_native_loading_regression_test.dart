import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import '../integration_test/audio_effects_native_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['KIKOFLU_AUDIO_LIBMPV'];
  const timeout = Duration(seconds: 10);
  const duration = Duration(milliseconds: 500);
  late AudioPlayer player;
  late NativePlayer native;
  late File source;

  setUpAll(() {
    if (library != null) {
      JustAudioMediaKit.pitch = false;
      JustAudioMediaKit.ensureInitialized(macOS: true, libmpv: library);
    }
  });

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('kiko-audio-load-');
    addTearDown(() async {
      await directory.delete(recursive: true);
    });
    source = File.fromUri(directory.uri.resolve('short.wav'));
    await source.writeAsBytes(
      audioEffectsWav(List.filled(24000, (1000, -1000)), 48000),
    );
    player = AudioPlayer(
      handleInterruptions: false,
      handleAudioSessionActivation: false,
      androidApplyAudioAttributes: false,
    );
    addTearDown(() async {
      try {
        await player.dispose().timeout(timeout);
      } finally {
        JustAudioMediaKit.forgetPlayerConfiguration(player.platformId);
      }
    });
    await JustAudioMediaKit.configurePlayer(player.platformId, (value) async {
      native = value;
      await native.setProperty('ao', 'null');
    });
  });

  group(
    'native audio loading',
    () {
      for (final initiallyActive in [false, true]) {
        test(
          'open error survives ${initiallyActive ? 'an active' : 'the first'} load and permits retry',
          () async {
            if (initiallyActive) {
              expect(
                await player.setFilePath(source.path).timeout(timeout),
                duration,
              );
            }
            final missing = File.fromUri(
              source.parent.uri.resolve('missing.wav'),
            );
            await expectLater(
              player.setFilePath(missing.path).timeout(timeout),
              throwsA(
                isA<PlayerException>().having(
                  (error) => error.message,
                  'message',
                  contains('missing.wav'),
                ),
              ),
            );
            expect(player.processingState, ProcessingState.idle);
            if (initiallyActive) await player.stop().timeout(timeout);
            expect(
              await player.setFilePath(source.path).timeout(timeout),
              duration,
            );
          },
        );
      }

      test('seeks a paused subsecond source in mpv', () async {
        expect(
          await player.setFilePath(source.path).timeout(timeout),
          duration,
        );
        const target = Duration(milliseconds: 250);
        final position = native.stream.position.firstWhere(
          (position) => position >= const Duration(milliseconds: 200),
        );

        await player.seek(target).timeout(timeout);

        expect(
          (await position.timeout(timeout)).inMilliseconds,
          closeTo(target.inMilliseconds, 50),
        );
      });
    },
    skip: library == null
        ? 'Set KIKOFLU_AUDIO_LIBMPV to run the native loading regressions.'
        : false,
  );
}

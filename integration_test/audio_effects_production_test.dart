import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kikoeru_flutter/src/models/audio_effects_settings.dart';
import 'package:kikoeru_flutter/src/services/native_audio_effects.dart';

import 'audio_effects_native_helpers.dart';

const _butterflyUrl =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const library = String.fromEnvironment('KIKOFLU_AUDIO_LIBMPV');

  setUpAll(() {
    MediaKit.ensureInitialized(libmpv: library.isEmpty ? null : library);
  });

  testWidgets(
    'production audio graph preserves dry output at 44.1, 48, and 96 kHz',
    (tester) async {
      for (final rate in [44100, 48000, 96000]) {
        final frames = _productionFixture(rate, rate ~/ 10 + 17);
        final output = await _captureProduction(
          frames,
          rate,
          AudioEffectsSettings(),
        );
        _expectIdenticalPcm(frames, output, reason: 'dry output at $rate Hz');
      }

      final frames = _productionFixture(48000, 4817);
      final zeroStrength = AudioEffectsSettings(
        equalizerEnabled: true,
        gains: List.filled(10, 0),
        binauralMode: BinauralMode.stereo,
        stereoAmount: 0,
        monoAmount: 0,
        sceneEnabled: true,
        sceneAmount: 0,
      );
      final output = await _captureProduction(frames, 48000, zeroStrength);
      _expectIdenticalPcm(
        frames,
        output,
        reason: 'zero-strength production graph',
      );
    },
  );

  testWidgets('production scene outputs match the 48 kHz recurrence oracle', (
    tester,
  ) async {
    final frames = bathroomFixture();
    final input = frames
        .map((pair) => (pair.$1 / 32768, pair.$2 / 32768))
        .toList(growable: false);
    for (final (scene, oracle) in [
      (AudioScene.bathroom, 'bathroom'),
      (AudioScene.muffled, 'through_wall'),
      (AudioScene.telephone, 'telephone'),
    ]) {
      final settings = AudioEffectsSettings(
        sceneEnabled: true,
        scene: scene,
        sceneAmount: 100,
      );
      final output = await _captureProduction(frames, 48000, settings);
      final ramp = List.generate(
        frames.length,
        (n) => math.min(1.0, (n + 1) / 960),
        growable: false,
      );
      final expected = sceneOraclePcm(input, oracle, 0, intensities: ramp);
      var maxError = 0.0;
      for (var n = 0; n < output.length; n++) {
        maxError = math.max(maxError, (output[n].$1 - expected[n].$1).abs());
        maxError = math.max(maxError, (output[n].$2 - expected[n].$2).abs());
      }
      expect(
        maxError,
        lessThan(1e-6),
        reason: '$oracle scene output must follow the shared 48 kHz oracle',
      );
    }
  });

  testWidgets('production binaural modes preserve mid and generate side', (
    tester,
  ) async {
    for (final mode in [BinauralMode.stereo, BinauralMode.mono]) {
      final frames = mode == BinauralMode.stereo
          ? _productionFixture(48000, 48000)
          : _binauralFixture(48000);
      final settings = AudioEffectsSettings(
        binauralMode: mode,
        stereoAmount: 100,
        monoAmount: 100,
      );
      final output = await _captureProduction(frames, 48000, settings);
      var midError = 0.0;
      var maxSide = 0.0;
      var stereoError = 0.0;
      for (var n = 0; n < output.length; n++) {
        final left = frames[n].$1 / 32768;
        final right = frames[n].$2 / 32768;
        final inputMid = (left + right) / 2;
        midError = math.max(
          midError,
          (((output[n].$1 + output[n].$2) / 2) - inputMid).abs(),
        );
        maxSide = math.max(maxSide, (output[n].$1 - output[n].$2).abs());
        if (mode == BinauralMode.stereo) {
          final side = (left - right) / 2 * math.min(1.0, (n + 1) / 960);
          stereoError = math.max(
            stereoError,
            (output[n].$1 - left - side).abs(),
          );
          stereoError = math.max(
            stereoError,
            (output[n].$2 - right + side).abs(),
          );
        }
      }
      expect(midError, lessThan(1e-7), reason: '${mode.name} mid channel');
      expect(maxSide, greaterThan(1e-5), reason: '${mode.name} side channel');
      if (mode == BinauralMode.stereo) {
        expect(stereoError, lessThan(1e-6), reason: 'stereo side expansion');
      }
    }
  });

  testWidgets('production equalizer applies its selected band gain', (
    tester,
  ) async {
    const rate = 48000;
    final frames = List.generate(96000, (n) {
      final sample = (700 * math.sin(2 * math.pi * 1000 * n / rate)).round();
      return (sample, sample);
    });
    final settings = AudioEffectsSettings(
      equalizerEnabled: true,
      gains: const [0, 0, 0, 0, 0, 9, 0, 0, 0, 0],
    );
    final output = await _captureProduction(frames, rate, settings);
    final inputSamples = frames
        .skip(rate ~/ 2)
        .map((pair) => pair.$1 / 32768)
        .toList();
    final outputSamples = output
        .skip(rate ~/ 2)
        .map((pair) => pair.$1)
        .toList();
    final gainDb =
        20 *
        math.log(
          audioEffectsToneAmplitude(outputSamples, 1000, rate) /
              audioEffectsToneAmplitude(inputSamples, 1000, rate),
        ) /
        math.ln10;
    expect(gainDb, closeTo(9, 0.01));
  });

  testWidgets('production guard limits active binaural output', (tester) async {
    const rate = 48000;
    final frames = List.generate(rate ~/ 10, (n) {
      final sample = (.99 * math.sin(2 * math.pi * 1000 * n / rate) * 32767)
          .round();
      return (sample, sample);
    });
    final output = await _captureProduction(
      frames,
      rate,
      AudioEffectsSettings(
        binauralMode: BinauralMode.stereo,
        stereoAmount: 100,
      ),
    );
    final peak = output.fold<double>(
      0,
      (value, pair) => math.max(value, math.max(pair.$1.abs(), pair.$2.abs())),
    );
    expect(peak, greaterThan(.9));
    expect(peak, lessThanOrEqualTo(.97 + 1e-7));
  });

  testWidgets(
    'live production update keeps the same source and maps channels',
    (tester) async {
      const rate = 48000;
      final frames = _productionFixture(rate, rate * 3);
      final settings = AudioEffectsSettings(
        channelMode: AudioChannelMode.cloneLeft,
      );
      var updatePosition = Duration.zero;
      final output = await _captureProduction(
        frames,
        rate,
        AudioEffectsSettings(),
        realtime: true,
        duringPlayback: (player, native, effects) async {
          updatePosition = await player.stream.position
              .firstWhere(
                (position) => position >= const Duration(milliseconds: 200),
              )
              .timeout(const Duration(seconds: 5));
          final source = await native.getProperty('path');
          expect(source, isNotEmpty);
          await effects.configure(native, settings, false);
          expect(await native.getProperty('path'), source);
          final advanced = await player.stream.position
              .firstWhere((position) => position > updatePosition)
              .timeout(const Duration(seconds: 5));
          expect(advanced, greaterThan(updatePosition));
        },
      );
      final start = updatePosition.inMilliseconds * rate ~/ 1000 + rate ~/ 10;
      final settled = output.skip(start).take(rate ~/ 20).toList();
      expect(settled, hasLength(rate ~/ 20));
      expect(settled.any((pair) => pair.$1.abs() > .01), isTrue);
      expect(
        settled.every((pair) => (pair.$1 - pair.$2).abs() < 1e-6),
        isTrue,
        reason:
            'the live clone-left update must reach PCM without reopening media',
      );
    },
  );

  testWidgets(
    'video output remains independent from the production audio graph',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'kikoflu-production-video-',
      );
      final videoFile = File('${directory.path}/butterfly.mp4');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      Player? audioPlayer;
      Player? videoPlayer;
      NativeAudioEffects? audioEffects;

      try {
        final request = await client
            .getUrl(Uri.parse(_butterflyUrl))
            .timeout(const Duration(seconds: 20));
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        expect(response.statusCode, HttpStatus.ok);
        await response
            .pipe(videoFile.openWrite())
            .timeout(const Duration(seconds: 30));
        expect(await videoFile.length(), greaterThan(1024));

        audioPlayer = _newPlayer();
        final audioNative = audioPlayer.platform as NativePlayer;
        await audioNative.setProperty('ao', 'null');
        audioEffects = NativeAudioEffects((_) {});
        await audioEffects.configure(
          audioNative,
          AudioEffectsSettings(sceneEnabled: true, sceneAmount: 50),
          false,
        );
        expect(await audioNative.getProperty('af'), contains('@kiko_eq'));

        videoPlayer = _newPlayer();
        final nativeVideo = videoPlayer.platform as NativePlayer;
        await nativeVideo.setProperty('ao', 'null');
        final controller = VideoController(videoPlayer);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  height: 180,
                  child: Video(controller: controller),
                ),
              ),
            ),
          ),
        );
        await controller.platform.future.timeout(const Duration(seconds: 20));
        final progressed = videoPlayer.stream.position.firstWhere(
          (position) => position > Duration.zero,
        );
        await videoPlayer
            .open(Media(videoFile.path), play: false)
            .timeout(const Duration(seconds: 20));
        await videoPlayer.play();
        await controller.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 30),
        );
        final position = await progressed.timeout(const Duration(seconds: 30));
        expect(position, greaterThan(Duration.zero));
        expect(videoPlayer.state.width, greaterThan(0));
        expect(videoPlayer.state.height, greaterThan(0));
        expect(await nativeVideo.getProperty('af'), isNot(contains('kiko')));
        expect(
          await nativeVideo.getProperty('mpv-version'),
          contains('0.42.0'),
        );
        expect(
          await nativeVideo.getProperty('ffmpeg-version'),
          contains('9.0.2'),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await audioEffects?.dispose();
        await videoPlayer?.dispose();
        await audioPlayer?.dispose();
        client.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Player _newPlayer() => Player(
  configuration: const PlayerConfiguration(
    osc: true,
    logLevel: MPVLogLevel.warn,
  ),
);

Future<List<(double, double)>> _captureProduction(
  List<(int, int)> frames,
  int rate,
  AudioEffectsSettings settings, {
  bool realtime = false,
  Future<void> Function(Player, NativePlayer, NativeAudioEffects)?
  duringPlayback,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'kikoflu-production-audio-',
  );
  final source = File('${directory.path}/input.wav');
  final pcm = File('${directory.path}/output.pcm');
  await source.writeAsBytes(audioEffectsWav(frames, rate));

  final player = _newPlayer();
  final native = player.platform as NativePlayer;
  final statuses = <AudioEffectsStatus>[];
  final effects = NativeAudioEffects(statuses.add);
  final errors = <String>[];
  final completed = Completer<void>();
  final logs = player.stream.log.listen((log) {
    if (log.level == 'error' || log.level == 'fatal') errors.add(log.text);
  });
  final errorEvents = player.stream.error.listen((error) {
    errors.add(error.toString());
  });
  final completion = player.stream.completed.listen((value) {
    if (value && !completed.isCompleted) completed.complete();
  });

  try {
    for (final (key, value) in [
      ('cache-on-disk', 'no'),
      ('ao', 'pcm'),
      ('ao-pcm-waveheader', 'no'),
      ('ao-pcm-file', pcm.path),
      ('audio-format', 'float'),
      ('audio-samplerate', '$rate'),
      ('audio-channels', 'stereo'),
    ]) {
      await native.setProperty(key, value);
    }
    expect(await native.getProperty('options/ao'), 'pcm');
    expect(await native.getProperty('mpv-version'), contains('0.42.0'));
    expect(await native.getProperty('ffmpeg-version'), contains('9.0.2'));

    final graph = AudioEffectsGraph.render(settings, systemLibrary: false);
    expect(graph, isNot(contains('__')));
    await effects.configure(native, settings, false);
    if (realtime) {
      native.onLoadHooks.add(() async {
        final chain = await native.getProperty('af');
        const clock = 'asetnsamples=n=128:p=0,arealtime';
        await native.setProperty(
          'af',
          '@test_clock:lavfi=o=[threads=1]:graph=%${clock.length}%$clock,$chain',
        );
      });
    }

    await player.open(Media(source.path)).timeout(const Duration(seconds: 10));
    if (duringPlayback != null) {
      await duringPlayback(player, native, effects);
    }
    await completed.future.timeout(const Duration(seconds: 10));
    await player.stop();
    expect(_commandStatus(native, ['set', 'ao', 'null']), 0);
    expect(await native.getProperty('current-ao'), isNot('pcm'));
    expect(
      statuses,
      contains(AudioEffectsStatus.ready),
      reason:
          'NativeAudioEffects must apply the production graph on this library',
    );
    expect(
      errors,
      isEmpty,
      reason: 'native output errors cannot count as bypass',
    );

    final installedGraph = await native.getProperty('af');
    for (final target in [
      '@kiko_eq',
      '@kiko_channel',
      '@kiko_binaural',
      '@kiko_guard',
      '@kiko_bathroom',
      '@kiko_through_wall',
      '@kiko_telephone',
    ]) {
      expect(graph, contains(target));
      expect(installedGraph, contains(target));
    }

    final output = audioEffectsPcm(await pcm.readAsBytes());
    expect(output, hasLength(frames.length));
    expect(
      output.every((pair) => pair.$1.isFinite && pair.$2.isFinite),
      isTrue,
    );
    return output;
  } finally {
    await effects.dispose();
    await player.dispose();
    await logs.cancel();
    await errorEvents.cancel();
    await completion.cancel();
    await directory.delete(recursive: true);
  }
}

List<(int, int)> _productionFixture(int rate, int length) => List.generate(
  length,
  (n) => (
    (5000 * math.sin(2 * math.pi * 440 * n / rate)).round(),
    (3000 * math.sin(2 * math.pi * 733 * n / rate + .2)).round(),
  ),
);

List<(int, int)> _binauralFixture(int rate) => List.generate(rate, (n) {
  final value =
      .12 * math.sin(2 * math.pi * 440 * n / rate) +
      (n >= rate ~/ 10 && n < rate ~/ 10 + 8 ? .18 : 0);
  final sample = (value * 32767).round();
  return (sample, sample);
});

void _expectIdenticalPcm(
  List<(int, int)> input,
  List<(double, double)> output, {
  required String reason,
}) {
  expect(output, hasLength(input.length), reason: reason);
  for (var n = 0; n < input.length; n++) {
    expect(output[n], (
      input[n].$1 / 32768,
      input[n].$2 / 32768,
    ), reason: '$reason at frame $n');
  }
}

int _commandStatus(NativePlayer player, List<String> arguments) {
  final strings = arguments.map((value) => value.toNativeUtf8()).toList();
  final pointers = calloc<Pointer<Utf8>>(strings.length + 1);
  for (var n = 0; n < strings.length; n++) {
    pointers[n] = strings[n];
  }
  try {
    return player.mpv.mpv_command(player.ctx, pointers.cast());
  } finally {
    calloc.free(pointers);
    for (final value in strings) {
      calloc.free(value);
    }
  }
}

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
    if (Platform.isAndroid) {
      try {
        DynamicLibrary.open('libmpv.so');
      } catch (error, stackTrace) {
        debugPrint('ANDROID_LIBMPV_OPEN_ERROR $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
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

  testWidgets('live production update keeps the same source and maps channels', (
    tester,
  ) async {
    const rate = 48000;
    final frames = _productionFixture(rate, rate * 3);
    final settings = AudioEffectsSettings(
      channelMode: AudioChannelMode.cloneLeft,
    );
    var framesBeforeUpdate = 0;
    var framesAfterUpdate = 0;
    final output = await _captureProduction(
      frames,
      rate,
      AudioEffectsSettings(),
      realtime: true,
      duringPlayback: (player, native, effects, pcm) async {
        framesBeforeUpdate = await _waitForPcmFrames(pcm, rate ~/ 4);
        expect(await native.getProperty('eof-reached'), 'no');
        final source = await native.getProperty('path');
        expect(source, isNotEmpty);
        await effects.configure(native, settings, false);
        expect(await native.getProperty('path'), source);
        expect(await native.getProperty('eof-reached'), 'no');
        framesAfterUpdate = await _waitForPcmFrames(pcm, rate ~/ 2);
      },
    );
    var maxLeftError = 0.0;
    var maxLeftErrorFrame = 0;
    for (var n = 0; n < output.length; n++) {
      final error = (output[n].$1 - frames[n].$1 / 32768).abs();
      if (error > maxLeftError) {
        maxLeftError = error;
        maxLeftErrorFrame = n;
      }
    }
    expect(
      maxLeftError,
      lessThan(1e-6),
      reason:
          'clone-left must preserve left PCM continuously at frame $maxLeftErrorFrame',
    );

    var maxBeforeUpdateRightError = 0.0;
    for (var n = 0; n < framesBeforeUpdate; n++) {
      maxBeforeUpdateRightError = math.max(
        maxBeforeUpdateRightError,
        (output[n].$2 - frames[n].$2 / 32768).abs(),
      );
    }
    expect(
      maxBeforeUpdateRightError,
      lessThan(1e-6),
      reason: 'the right channel must retain its source before the update',
    );

    final settledStart = framesAfterUpdate + rate ~/ 10;
    final settledEnd = settledStart + rate ~/ 20;
    expect(settledEnd, lessThanOrEqualTo(output.length));
    var maxAfterUpdateRightError = 0.0;
    for (var n = settledStart; n < settledEnd; n++) {
      maxAfterUpdateRightError = math.max(
        maxAfterUpdateRightError,
        (output[n].$2 - frames[n].$1 / 32768).abs(),
      );
    }
    expect(
      maxAfterUpdateRightError,
      lessThan(1e-6),
      reason: 'the right channel must settle to the source left after update',
    );
  });

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
        final videoParams = videoPlayer.stream.videoParams.firstWhere(
          (params) =>
              params.dw != null &&
              params.dw! > 0 &&
              params.dh != null &&
              params.dh! > 0,
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

        // Linux sends a 1x1 placeholder resize when it creates the texture.
        // The first-frame future can complete for that placeholder, so wait
        // for libmpv's decoded video parameters and the real texture resize.
        final decodedVideoParams = await videoParams.timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException(
            'libmpv did not report positive video dimensions',
          ),
        );
        expect(videoPlayer.state.width, greaterThan(0));
        expect(videoPlayer.state.height, greaterThan(0));
        final renderedFrame = Completer<Rect>();
        void observeRenderedFrame() {
          final rect = controller.rect.value;
          if (!renderedFrame.isCompleted &&
              rect != null &&
              rect.width > 1 &&
              rect.height > 1) {
            renderedFrame.complete(rect);
          }
        }

        controller.rect.addListener(observeRenderedFrame);
        late final Rect renderedRect;
        try {
          observeRenderedFrame();
          renderedRect = await renderedFrame.future.timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'the video texture did not resize beyond its 1x1 placeholder '
              'after libmpv reported ${decodedVideoParams.dw}x'
              '${decodedVideoParams.dh}',
            ),
          );
        } finally {
          controller.rect.removeListener(observeRenderedFrame);
        }
        expect(renderedRect.width, greaterThan(1));
        expect(renderedRect.height, greaterThan(1));
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
  Future<void> Function(Player, NativePlayer, NativeAudioEffects, File)?
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
  final eofReached = Completer<void>();
  final nativeFailure = Completer<String>();
  var observedEof = false;
  var sourceLoads = 0;
  void recordError(String error) {
    errors.add(error);
    if (!nativeFailure.isCompleted) nativeFailure.complete(error);
  }

  final logs = player.stream.log.listen((log) {
    if (log.level == 'error' || log.level == 'fatal') recordError(log.text);
  });
  final errorEvents = player.stream.error.listen((error) {
    recordError(error.toString());
  });
  final completionSubscription = player.stream.completed.listen((value) {
    if (value && !completed.isCompleted) completed.complete();
  });

  try {
    for (final (key, value) in [
      ('cache-on-disk', 'no'),
      // Periodic synthetic WAV can otherwise be misdetected as MPEG-TS.
      ('demuxer-lavf-format', 'wav'),
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
    await native.observeProperty('eof-reached', (value) async {
      if (value == 'yes' && !eofReached.isCompleted) eofReached.complete();
    });
    observedEof = true;

    final graph = AudioEffectsGraph.render(settings, systemLibrary: false);
    expect(graph, isNot(contains('__')));
    await effects.configure(native, settings, false);
    if (realtime) {
      native.onLoadHooks.add(() async {
        sourceLoads++;
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
      await duringPlayback(player, native, effects, pcm);
      expect(
        statuses.last,
        AudioEffectsStatus.ready,
        reason: 'the live native parameter update must be accepted',
      );
    }
    final completionResult =
        await Future.any<String>([
          completed.future.then((_) => 'stream-completed'),
          eofReached.future.then((_) => 'native-eof'),
          nativeFailure.future.then((error) => 'native-error: $error'),
        ]).timeout(
          const Duration(seconds: 10),
          onTimeout: () async {
            final eof = await native.getProperty('eof-reached');
            final position = await native.getProperty('time-pos');
            final duration = await native.getProperty('duration');
            final pcmBytes = await pcm.exists() ? await pcm.length() : 0;
            throw TimeoutException(
              'Native playback did not reach EOF: eof-reached=$eof, '
              'time-pos=$position, duration=$duration, pcm-bytes=$pcmBytes, '
              'errors=${errors.join(' | ')}',
            );
          },
        );
    if (completionResult.startsWith('native-error:')) {
      fail(
        'Native playback failed before EOF: ${completionResult.substring(13)}',
      );
    }
    expect(
      await native.getProperty('eof-reached'),
      'yes',
      reason: 'the source must reach native EOF before PCM can pass',
    );
    if (realtime) {
      expect(
        sourceLoads,
        1,
        reason: 'a live setting update must not reload the source',
      );
    }
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
    if (observedEof) await native.unobserveProperty('eof-reached');
    await effects.dispose();
    await player.dispose();
    await logs.cancel();
    await errorEvents.cancel();
    await completionSubscription.cancel();
    await directory.delete(recursive: true);
  }
}

Future<int> _waitForPcmFrames(File pcm, int minimumFrames) async {
  final reached = Completer<int>();
  final timer = Timer.periodic(const Duration(milliseconds: 10), (timer) {
    final frames = pcm.existsSync() ? pcm.lengthSync() ~/ 8 : 0;
    if (frames >= minimumFrames && !reached.isCompleted) {
      reached.complete(frames);
      timer.cancel();
    }
  });
  try {
    return await reached.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        final frames = pcm.existsSync() ? pcm.lengthSync() ~/ 8 : 0;
        throw TimeoutException(
          'PCM output reached $frames frames; expected at least $minimumFrames',
        );
      },
    );
  } finally {
    timer.cancel();
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

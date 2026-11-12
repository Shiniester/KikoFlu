import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'audio_effects_native_graphs.dart';
import 'audio_effects_native_helpers.dart';
import 'audio_effects_native_hls.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const library = String.fromEnvironment('KIKOFLU_AUDIO_LIBMPV');
  final supported = Platform.isAndroid || Platform.isWindows;

  setUpAll(() {
    if (supported) {
      MediaKit.ensureInitialized(libmpv: library.isEmpty ? null : library);
    }
  });

  testWidgets('packaged native scene modes switch through neutral', (
    tester,
  ) async {
    final frames = modeFixture();
    final controls = List.generate(3, (_) => <double>[]);
    final results = <Map<String, Object>>[];
    final output = await _capture(
      frames,
      48000,
      '[in]anull[out]',
      afChain: audioEffectsNativeGraphs['scene_modes_af']!,
      modeIntensities: controls,
      actions: [
        for (final (milliseconds, scene, amount) in [
          (300, 'bathroom', 1.0),
          (700, 'bathroom', 0.0),
          (900, 'through_wall', .5),
          (1300, 'through_wall', 0.0),
          (1500, 'telephone', .75),
          (1900, 'telephone', 0.0),
          (2100, 'bathroom', 1.0),
        ])
          (
            Duration(milliseconds: milliseconds),
            ['af-command', scene, 'volume', '$amount', 'volume@scene_amount'],
          ),
      ],
      actionResults: results,
    );
    expect(results.length, 7);
    var expected = frames
        .map((pair) => (pair.$1 / 32768, pair.$2 / 32768))
        .toList();
    final steps = <double>[];
    final scenes = ['bathroom', 'through_wall', 'telephone'];
    for (var channel = 0; channel < 3; channel++) {
      final intensity = controls[channel];
      expect(intensity.length, frames.length);
      expect(intensity.reduce(math.min), 0);
      expect(intensity.reduce(math.max), [1.0, .5, .75][channel]);
      var step = 0.0;
      for (var n = 1; n < intensity.length; n++) {
        step = math.max(step, (intensity[n] - intensity[n - 1]).abs());
      }
      expect(step, lessThanOrEqualTo(1 / 960 + 1e-7));
      steps.add(step);
      expected = sceneOraclePcm(
        expected,
        scenes[channel],
        0,
        intensities: intensity,
      );
    }
    expect(controls.map((lane) => lane.last), [1, 0, 0]);
    var error = 0.0;
    var neutralError = 0.0;
    var neutralFrames = 0;
    for (var n = 0; n < output.length; n++) {
      expect(
        controls.where((lane) => lane[n] > 0).length,
        lessThanOrEqualTo(1),
      );
      error = math.max(
        error,
        math.max(
          (output[n].$1 - expected[n].$1).abs(),
          (output[n].$2 - expected[n].$2).abs(),
        ),
      );
      if (controls.every((lane) => lane[n] == 0)) {
        neutralFrames++;
        neutralError = math.max(
          neutralError,
          math.max(
            (output[n].$1 - frames[n].$1 / 32768).abs(),
            (output[n].$2 - frames[n].$2 / 32768).abs(),
          ),
        );
      }
    }
    expect(error, lessThan(1e-6));
    expect(neutralError, 0);
    expect(neutralFrames, greaterThan(0));
    binding.reportData = {
      ...?binding.reportData,
      'scene_modes': {
        'max_error': error,
        'neutral_max_error': neutralError,
        'maximum_amount_steps': steps,
        'neutral_frames': neutralFrames,
      },
      'gate_status': 'incomplete',
    };
  }, skip: !supported);

  testWidgets(
    'packaged native playback boundaries preserve and reset history',
    (tester) async {
      final frames = boundaryFixture();
      final mono = audioEffectsNativeGraphs['mono48000']!.replaceFirst(
        'volume@mono_amount=0:',
        'volume@mono_amount=1:',
      );
      final scene = audioEffectsNativeGraphs['boundary_scene']!;
      final full = await _capture(frames, 48000, mono);
      final startReferences = <String, List<(double, double)>>{};
      for (final (name, graph) in [('mono', mono), ('scene', scene)]) {
        final output = await _capture(
          frames,
          48000,
          graph,
          startPosition: const Duration(seconds: 2),
          expectFullInput: false,
        );
        expect(output, isNotEmpty);
        expect(output.length, lessThan(frames.length));
        startReferences[name] = output;
      }
      final pauseResults = <Map<String, Object>>[];
      final paused = await _capture(
        frames,
        48000,
        mono,
        actions: [
          (const Duration(milliseconds: 250), ['set', 'pause', 'yes']),
          (const Duration(milliseconds: 500), ['set', 'pause', 'no']),
        ],
        actionResults: pauseResults,
        actionsAfterOutput: true,
      );
      expect(
        paused,
        full,
        reason: 'Pause must not discard samples or reset DSP state',
      );
      expect(pauseResults.map((result) => result['pause_after_reply']), [
        'yes',
        'no',
      ]);
      final metrics = <String, Object>{
        'pause_frames': paused.length,
        'pause_anchor_pcm_bytes':
            pauseResults.first['action_anchor_pcm_bytes']!,
      };
      final sceneFull = sceneOracle(
        frames,
        'bathroom',
        0,
        intensities: List.generate(
          frames.length,
          (n) => math.min(1.0, (n + 1) / 960),
        ),
      );
      for (final (name, graph) in [('mono', mono), ('scene', scene)]) {
        final seekResults = <Map<String, Object>>[];
        final output = await _capture(
          frames,
          48000,
          graph,
          actions: [
            (
              const Duration(milliseconds: 250),
              ['seek', '2', 'absolute+exact'],
            ),
          ],
          expectFullInput: false,
          actionsAfterOutput: true,
          actionResults: seekResults,
        );
        final fresh = startReferences[name]!;
        final prefix = output.length - fresh.length;
        expect(prefix, inInclusiveRange(1, 95999));
        final before = name == 'mono' ? full : sceneFull;
        var prefixError = 0.0;
        for (var n = 0; n < prefix; n++) {
          prefixError = math.max(
            prefixError,
            math.max(
              (output[n].$1 - before[n].$1).abs(),
              (output[n].$2 - before[n].$2).abs(),
            ),
          );
        }
        expect(prefixError, lessThan(1e-6));
        expect(
          output.sublist(prefix),
          fresh,
          reason:
              'Seek history must match a fresh context with the same decoder preroll',
        );
        metrics['seek_$name'] = {
          'post_seek_frames': fresh.length,
          'captured_prefix_frames': prefix,
          'prefix_max_error': prefixError,
          'action_anchor_pcm_bytes':
              seekResults.first['action_anchor_pcm_bytes']!,
        };
      }
      final silence = List<(int, int)>.filled(9617, (0, 0));
      final staticScene = audioEffectsNativeGraphs['scene_bathroom_100']!;
      final stopResults = <Map<String, Object>>[];
      final reloaded = await _capture(
        frames,
        48000,
        staticScene,
        actions: [
          (const Duration(milliseconds: 250), ['stop']),
          (
            const Duration(milliseconds: 500),
            ['loadfile', r'$followup', 'replace'],
          ),
        ],
        followupFrames: silence,
        expectFullInput: false,
        actionsAfterOutput: true,
        actionResults: stopResults,
      );
      final prefix = reloaded.length - silence.length;
      expect(prefix, inInclusiveRange(1, frames.length - 1));
      final beforeStop = sceneOracle(frames, 'bathroom', 100);
      var stopPrefixError = 0.0;
      for (var n = 0; n < prefix; n++) {
        stopPrefixError = math.max(
          stopPrefixError,
          math.max(
            (reloaded[n].$1 - beforeStop[n].$1).abs(),
            (reloaded[n].$2 - beforeStop[n].$2).abs(),
          ),
        );
      }
      expect(stopPrefixError, lessThan(1e-6));
      expect(
        reloaded.sublist(prefix).every((pair) => pair == (0.0, 0.0)),
        isTrue,
        reason: 'Stop/reload must not carry the previous reflection history',
      );
      await _capture(frames, 48000, staticScene);
      final recreated = await _capture(silence, 48000, staticScene);
      expect(
        recreated.every((pair) => pair == (0.0, 0.0)),
        isTrue,
        reason: 'A newly created Player must not carry previous DSP history',
      );
      metrics['stop_reload_silence_frames'] = silence.length;
      metrics['stop_reload_prefix_frames'] = prefix;
      metrics['stop_reload_prefix_max_error'] = stopPrefixError;
      metrics['stop_anchor_pcm_bytes'] =
          stopResults.first['action_anchor_pcm_bytes']!;
      metrics['recreated_silence_frames'] = recreated.length;
      binding.reportData = {
        ...?binding.reportData,
        'boundaries': metrics,
        'gate_status': 'incomplete',
      };
    },
    skip: !supported,
  );

  testWidgets(
    'packaged native limiter preserves timing and bounds linked peaks',
    (tester) async {
      final metrics = <String, Object>{};
      for (final rate in [44100, 48000, 96000]) {
        final low = List<(int, int)>.filled(rate ~/ 10 + 17, (0, 0));
        for (final n in [0, 1, low.length ~/ 2, low.length - 1]) {
          low[n] = (12000, -6000);
        }
        final short = List<(int, int)>.filled((rate * .002).toInt() + 1, (
          0,
          0,
        ));
        short[0] = (12000, -6000);
        short[short.length - 1] = (-6000, 3000);
        for (final frames in [low, short]) {
          final output = await _capture(
            frames,
            rate,
            audioEffectsNativeGraphs['limiter']!,
          );
          for (var n = 0; n < output.length; n++) {
            expect(
              output[n],
              (frames[n].$1 / 32768, frames[n].$2 / 32768),
              reason: 'Low-level impulses and EOF timing must be unchanged',
            );
          }
        }
        final hot = List.generate(rate ~/ 5 + 17, (n) {
          final left =
              2 * (14000 * math.sin(2 * math.pi * 1000 * n / rate)).round();
          return (left, left ~/ 2);
        });
        final output = await _capture(
          hot,
          rate,
          audioEffectsNativeGraphs['limiter_hot']!,
        );
        final peak = output
            .map((pair) => math.max(pair.$1.abs(), pair.$2.abs()))
            .reduce(math.max);
        final ratioError = output
            .map((pair) => (pair.$2 - .5 * pair.$1).abs())
            .reduce(math.max);
        expect(peak, greaterThan(.9));
        expect(peak, lessThanOrEqualTo(.97 + 1e-7));
        expect(ratioError, lessThan(1e-7));
        metrics['$rate'] = {'peak': peak, 'linked_channel_error': ratioError};
      }
      final frames = combinationFixture();
      for (final (key, bound) in [
        ('limited_prefix_af', .97 + 1e-7),
        ('limited_combination_af', 1.0),
      ]) {
        final output = await _capture(
          frames,
          96000,
          '[in]anull[out]',
          afChain: audioEffectsNativeGraphs[key]!,
        );
        final peak = output
            .map((pair) => math.max(pair.$1.abs(), pair.$2.abs()))
            .reduce(math.max);
        expect(peak, greaterThan(.01));
        expect(peak, lessThanOrEqualTo(bound));
        metrics[key] = {
          'peak': peak,
          'placement': 'after EQ/mono, before scene',
        };
      }
      binding.reportData = {
        ...?binding.reportData,
        'limiter': metrics,
        'gate_status': 'incomplete',
      };
    },
    skip: !supported,
  );

  testWidgets('packaged native HTTP and HLS use the same PCM effects', (
    tester,
  ) async {
    final frames = networkFixture();
    final files = <String, List<int>>{
      '/input.wav': audioEffectsWav(frames, 48000),
      for (final entry in audioEffectsHlsFiles.entries)
        entry.key: base64Decode(entry.value),
    };
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      requests.add(path);
      final bytes = files[path];
      if (bytes == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.contentLength = bytes.length;
        request.response.headers.contentType = ContentType.parse(
          path.endsWith('.m3u8')
              ? 'application/vnd.apple.mpegurl'
              : path.endsWith('.ts')
              ? 'video/mp2t'
              : 'audio/wav',
        );
        request.response.add(bytes);
      }
      await request.response.close();
    });
    final metrics = <String, Object>{};
    try {
      for (final hls in [false, true]) {
        final source =
            'http://127.0.0.1:${server.port}${hls ? "/hls/index.m3u8" : "/input.wav"}';
        final fixture = hls
            ? List<(int, int)>.filled(audioEffectsHlsDecodedFrames, (0, 0))
            : frames;
        final baseline = await _capture(
          fixture,
          48000,
          '[in]anull[out]',
          sourceUrl: source,
          demuxerFormat: hls ? '' : 'wav',
        );
        expect(baseline.any((pair) => pair.$1.abs() > .01), isTrue);
        final output = await _capture(
          fixture,
          48000,
          audioEffectsNativeGraphs['scene_bathroom_100']!,
          sourceUrl: source,
          demuxerFormat: hls ? '' : 'wav',
        );
        final expected = sceneOraclePcm(baseline, 'bathroom', 100);
        var error = 0.0;
        for (var n = 0; n < output.length; n++) {
          error = math.max(error, (output[n].$1 - expected[n].$1).abs());
          error = math.max(error, (output[n].$2 - expected[n].$2).abs());
        }
        expect(error, lessThan(1e-6));
        metrics[hls ? 'hls' : 'http'] = {
          'frames': output.length,
          'max_error': error,
        };
      }
      expect(requests, contains('/input.wav'));
      expect(requests, contains('/hls/index.m3u8'));
      for (final name in ['segment00.ts', 'segment01.ts', 'segment02.ts']) {
        expect(requests, contains('/hls/$name'));
      }
      binding.reportData = {
        ...?binding.reportData,
        'network': metrics,
        'gate_status': 'incomplete',
      };
    } finally {
      await server.close(force: true);
    }
  }, skip: !supported);

  testWidgets('packaged native full modular chain survives hot PCM', (
    tester,
  ) async {
    final frames = combinationFixture();
    final output = await _capture(
      frames,
      96000,
      '[in]anull[out]',
      afChain: audioEffectsNativeGraphs['full_combination_af']!,
    );
    final peak = output
        .map((pair) => math.max(pair.$1.abs(), pair.$2.abs()))
        .reduce(math.max);
    final clipped = output.fold<int>(
      0,
      (sum, pair) =>
          sum + (pair.$1.abs() == 1 ? 1 : 0) + (pair.$2.abs() == 1 ? 1 : 0),
    );
    expect(peak, 1);
    expect(clipped, greaterThan(0));
    binding.reportData = {
      ...?binding.reportData,
      'full_combination': {
        'frames': output.length,
        'peak': peak,
        'scene_clipped_samples': clipped,
        'scope': 'buffer/crash regression; headroom remains unverified',
      },
      'gate_status': 'incomplete',
    };
  }, skip: !supported);

  testWidgets('packaged native channel mappings and stereo width', (
    tester,
  ) async {
    final frames = List.generate(
      9600,
      (n) => (
        (6000 * math.sin(2 * math.pi * 440 * n / 48000)).round(),
        (4000 * math.sin(2 * math.pi * 880 * n / 48000 + .3)).round(),
      ),
    );
    for (final (expression, leftIndex, rightIndex) in [
      ('val(0)|val(1)', 0, 1),
      ('val(1)|val(0)', 1, 0),
      ('val(0)|val(0)', 0, 0),
      ('val(1)|val(1)', 1, 1),
    ]) {
      final output = await _capture(
        frames,
        48000,
        "[in]aeval='$expression':c=stereo,aformat=channel_layouts=stereo[out]",
      );
      for (var n = 0; n < frames.length; n++) {
        final original = [frames[n].$1 / 32768, frames[n].$2 / 32768];
        expect(output[n], (original[leftIndex], original[rightIndex]));
      }
    }
    for (final width in [0, .5, 1, 2]) {
      final graph =
          "[in]aeval='(val(0)+val(1))/2+$width*(val(0)-val(1))/2|"
          "(val(0)+val(1))/2-$width*(val(0)-val(1))/2':c=stereo,aformat=channel_layouts=stereo[out]";
      final output = await _capture(frames, 48000, graph);
      for (var n = 0; n < frames.length; n++) {
        final mid = (frames[n].$1 + frames[n].$2) / 65536;
        final side = width * (frames[n].$1 - frames[n].$2) / 65536;
        expect((output[n].$1 + output[n].$2) / 2, closeTo(mid, 1e-7));
        expect((output[n].$1 - output[n].$2) / 2, closeTo(side, 1e-7));
        if (width == 1) {
          expect(output[n], (frames[n].$1 / 32768, frames[n].$2 / 32768));
        }
      }
      if (width == 2) {
        final identical = frames.map((pair) => (pair.$1, pair.$1)).toList();
        final sameOutput = await _capture(identical, 48000, graph);
        for (var n = 0; n < identical.length; n++) {
          expect(sameOutput[n], (
            identical[n].$1 / 32768,
            identical[n].$1 / 32768,
          ));
        }
      }
    }
  }, skip: !supported);

  testWidgets('packaged native 10-band EQ center gains and neutral', (
    tester,
  ) async {
    for (final frequency in [
      31,
      62,
      125,
      250,
      500,
      1000,
      2000,
      4000,
      8000,
      16000,
    ]) {
      final offFrequency = frequency < 16000 ? frequency * 2 : frequency ~/ 2;
      final frames = List.generate(72000, (n) {
        final sample =
            (1200 *
                    (math.sin(2 * math.pi * frequency * n / 48000) +
                        math.sin(2 * math.pi * offFrequency * n / 48000)))
                .round();
        return (sample, sample);
      });
      final reference = frames
          .skip(24000)
          .map((pair) => pair.$1 / 32768)
          .toList();
      for (final gain in [-15, 15]) {
        final output = await _capture(
          frames,
          48000,
          audioEffectsNativeGraphs['eq${frequency}_$gain']!,
        );
        final samples = output.skip(24000).map((pair) => pair.$1).toList();
        double measuredDb(int hz) =>
            20 *
            math.log(
              audioEffectsToneAmplitude(samples, hz, 48000) /
                  audioEffectsToneAmplitude(reference, hz, 48000),
            ) /
            math.ln10;
        final center = measuredDb(frequency);
        final off = measuredDb(offFrequency);
        expect(center, closeTo(gain.toDouble(), .03));
        expect(off.abs(), lessThan(center.abs() - 1));
        expect(output.every((pair) => pair.$1 == pair.$2), isTrue);
      }
    }
    final frames = monoFixture(48000);
    final output = await _capture(
      frames,
      48000,
      audioEffectsNativeGraphs['eq_neutral']!,
    );
    for (var n = 0; n < frames.length; n++) {
      expect(output[n], (frames[n].$1 / 32768, frames[n].$2 / 32768));
    }
  }, skip: !supported);

  testWidgets('packaged native static Eara scenes match recurrence', (
    tester,
  ) async {
    final frames = bathroomFixture();
    final metrics = <String, Object>{};
    for (final scene in ['bathroom', 'through_wall', 'telephone']) {
      for (final amount in [0, 50, 100]) {
        final expected = sceneOracle(frames, scene, amount);
        final key = 'scene_${scene}_$amount';
        final output = await _capture(
          frames,
          48000,
          audioEffectsNativeGraphs[key]!,
        );
        var maxError = 0.0;
        for (var n = 0; n < frames.length; n++) {
          maxError = math.max(maxError, (output[n].$1 - expected[n].$1).abs());
          maxError = math.max(maxError, (output[n].$2 - expected[n].$2).abs());
        }
        if (amount == 0) {
          expect(maxError, 0);
        } else {
          expect(maxError, lessThan(1e-6));
        }
        metrics[key] = {'frames': output.length, 'max_error': maxError};
      }
    }
    binding.reportData = {
      ...?binding.reportData,
      'scenes': metrics,
      'gate_status': 'incomplete',
    };
  }, skip: !supported);

  for (final rate in [44100, 48000, 96000]) {
    testWidgets('packaged native mono protection at $rate Hz', (tester) async {
      final frames = monoFixture(rate);
      final graph = audioEffectsNativeGraphs['mono$rate']!;
      final monoBypass = await _capture(
        frames,
        rate,
        '[in]anull[out]',
        mono: true,
      );
      final monoNeutral = await _capture(frames, rate, graph, mono: true);
      expect(
        monoNeutral,
        monoBypass,
        reason: 'Neutral must preserve the native mono conversion matrix',
      );
      final neutral = await _capture(frames, rate, graph);
      for (var n = 0; n < frames.length; n++) {
        expect(neutral[n].$1, frames[n].$1 / 32768);
        expect(neutral[n].$2, frames[n].$2 / 32768);
      }
      final enabled = graph.replaceFirst(
        'volume@mono_amount=0:',
        'volume@mono_amount=1:',
      );
      final output = await _capture(frames, rate, enabled);
      final unprotected = await _capture(
        frames,
        rate,
        enabled.replaceFirst('*(1-ld(4))*min(1,ld(1)/(ld(5)+1e-12))', ''),
      );
      final chunked = await _capture(
        frames,
        rate,
        enabled.replaceFirst(
          'asplit=3[dry]',
          'asetnsamples=n=127:p=0,asplit=3[dry]',
        ),
      );
      var midError = 0.0;
      var blockError = 0.0;
      for (var n = 0; n < frames.length; n++) {
        midError = math.max(
          midError,
          ((output[n].$1 + output[n].$2) / 2 - frames[n].$1 / 32768).abs(),
        );
        blockError = math.max(blockError, (output[n].$1 - chunked[n].$1).abs());
        blockError = math.max(blockError, (output[n].$2 - chunked[n].$2).abs());
      }
      double onsetPeak(List<(double, double)> pcm) => pcm
          .sublist((rate * .1).toInt(), (rate * .1002).toInt())
          .map((pair) => ((pair.$1 - pair.$2) / 2).abs())
          .reduce(math.max);
      final protectedPeak = onsetPeak(output);
      final rawPeak = onsetPeak(unprotected);
      final tail = output
          .skip((rate * .23).toInt())
          .map((pair) => math.max(pair.$1.abs(), pair.$2.abs()))
          .reduce(math.max);
      expect(midError, lessThan(1e-7));
      expect(blockError, lessThan(1e-7));
      expect(rawPeak, greaterThan(.01));
      expect(protectedPeak, lessThan(rawPeak * .1));
      expect(tail, lessThan(1e-5));
      binding.reportData = {
        ...?binding.reportData,
        'mono_$rate': {
          'frames': output.length,
          'midside_max_error': midError,
          'block_max_error': blockError,
          'protected_onset_peak': protectedPeak,
          'unprotected_onset_peak': rawPeak,
          'tail_after_30ms_peak': tail,
        },
        'gate_status': 'incomplete',
      };
    }, skip: !supported);
  }

  testWidgets(
    'packaged native scene amount updates change actual parameters',
    (tester) async {
      final frames = List.generate(
        105617,
        (n) => (
          (.95 * math.sin(2 * math.pi * 1000 * n / 48000) * 32767).round(),
          (.8 * math.sin(2 * math.pi * 700 * n / 48000 + .2) * 32767).round(),
        ),
      );
      final metrics = <String, Object>{};
      for (final scene in ['bathroom', 'through_wall', 'telephone']) {
        final intensity = <double>[];
        final output = await _capture(
          frames,
          48000,
          audioEffectsNativeGraphs['dynamic_$scene']!,
          intensities: intensity,
          updates: [
            (const Duration(milliseconds: 300), 1),
            (const Duration(milliseconds: 800), .5),
            (const Duration(milliseconds: 1300), 0),
            (const Duration(milliseconds: 1600), .75),
          ],
        );
        expect(intensity.length, frames.length);
        expect(intensity.reduce(math.min), 0);
        expect(intensity.reduce(math.max), 1);
        expect(intensity.last, .75);
        final expected = sceneOracle(frames, scene, 0, intensities: intensity);
        final full = sceneOracle(frames, scene, 100);
        var maxError = 0.0;
        var maxStep = 0.0;
        var fadeError = 0.0;
        var zeroError = 0.0;
        for (var n = 0; n < frames.length; n++) {
          final actual = [output[n].$1, output[n].$2];
          final wanted = [expected[n].$1, expected[n].$2];
          final original = [frames[n].$1 / 32768, frames[n].$2 / 32768];
          final staticFull = [full[n].$1, full[n].$2];
          for (var c = 0; c < 2; c++) {
            maxError = math.max(maxError, (actual[c] - wanted[c]).abs());
            if (intensity[n] == 0) {
              zeroError = math.max(zeroError, (actual[c] - original[c]).abs());
            }
            final faded =
                (1 - intensity[n]) * original[c] + intensity[n] * staticFull[c];
            fadeError = math.max(fadeError, (actual[c] - faded).abs());
          }
          if (n > 0) {
            maxStep = math.max(
              maxStep,
              (intensity[n] - intensity[n - 1]).abs(),
            );
          }
        }
        expect(maxError, lessThan(1e-6));
        expect(zeroError, 0);
        expect(maxStep, lessThanOrEqualTo(1 / 960 + 1e-7));
        expect(fadeError, greaterThan(1e-3));
        metrics[scene] = {
          'max_error': maxError,
          'zero_amount_error': zeroError,
          'maximum_amount_step': maxStep,
          'fade_only_max_error': fadeError,
        };
      }
      binding.reportData = {
        ...?binding.reportData,
        'dynamic_scenes': metrics,
        'gate_status': 'incomplete',
      };
    },
    skip: !supported,
  );
}

Future<List<(double, double)>> _capture(
  List<(int, int)> frames,
  int rate,
  String graph, {
  bool mono = false,
  List<double>? intensities,
  List<List<double>>? modeIntensities,
  List<(Duration, double)> updates = const [],
  String? afChain,
  String? sourceUrl,
  String demuxerFormat = 'wav',
  List<(Duration, List<String>)> actions = const [],
  List<(int, int)>? followupFrames,
  Duration? startPosition,
  bool expectFullInput = true,
  List<Map<String, Object>>? actionResults,
  bool actionsAfterOutput = false,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'kikoflu-audio-effects-',
  );
  final source = File('${directory.path}/input.wav');
  final pcm = File('${directory.path}/output.pcm');
  if (sourceUrl == null) {
    await source.writeAsBytes(audioEffectsWav(frames, rate, mono: mono));
  }
  final followup = File('${directory.path}/followup.wav');
  if (followupFrames != null) {
    await followup.writeAsBytes(audioEffectsWav(followupFrames, rate));
  }
  final player = Player(
    // osc=false makes media_kit write an absent property on builds without Lua.
    configuration: const PlayerConfiguration(
      osc: true,
      logLevel: MPVLogLevel.warn,
    ),
  );
  final errors = <String>[];
  final completed = Completer<void>();
  final logs = player.stream.log.listen((log) {
    if (log.level == 'error' || log.level == 'fatal') errors.add(log.text);
  });
  final errorEvents = player.stream.error.listen(errors.add);
  final completion = player.stream.completed.listen((value) {
    if (value && !completed.isCompleted) completed.complete();
  });
  try {
    final native = player.platform;
    expect(native, isA<NativePlayer>());
    final backend = native as NativePlayer;
    if (updates.isNotEmpty || actions.isNotEmpty) {
      graph = graph.replaceFirst('[in]', '[in]arealtime,');
      afChain = afChain?.replaceFirst(
        'format=channels=stereo,',
        'format=channels=stereo,@clock:lavfi=o=[threads=1]:graph=arealtime,',
      );
    }
    for (final (key, value) in [
      ('cache-on-disk', 'no'),
      ('ao', 'pcm'),
      ('ao-pcm-waveheader', 'no'),
      ('ao-pcm-file', pcm.path),
      if (actions.isNotEmpty) ('ao-pcm-append', 'yes'),
      ('audio-format', 'float'),
      ('audio-samplerate', '$rate'),
      (
        'audio-channels',
        modeIntensities != null
            ? '5.0'
            : intensities == null
            ? 'stereo'
            : '3.0',
      ),
      if (demuxerFormat.isNotEmpty) ('demuxer-lavf-format', demuxerFormat),
      (
        'af',
        afChain ??
            'format=channels=stereo,@effects:lavfi=o=[threads=1]:graph=%${utf8.encode(graph).length}%$graph',
      ),
    ]) {
      await backend.setProperty(key, value);
    }
    expect(await backend.getProperty('options/ao'), 'pcm');
    final versions = {
      'mpv': await backend.getProperty('mpv-version'),
      'ffmpeg': await backend.getProperty('ffmpeg-version'),
    };
    debugPrint('AUDIO_EFFECTS_NATIVE ${jsonEncode(versions)}');
    await player
        .open(Media(sourceUrl ?? source.path, start: startPosition))
        .timeout(const Duration(seconds: 10));
    var commandTarget = 'volume@scene_amount';
    final commands = updates
        .map(
          (update) => Future<void>.delayed(update.$1, () {
            int send(String target) => _commandStatus(backend, [
              'af-command',
              'effects',
              'volume',
              '${update.$2}',
              target,
            ]);
            var code = send(commandTarget);
            debugPrint(
              'AUDIO_EFFECTS_COMMAND target=$commandTarget status=$code',
            );
            if (code == -12 && commandTarget.contains('@')) {
              commandTarget = commandTarget.split('@').last;
              code = send(commandTarget);
              debugPrint(
                'AUDIO_EFFECTS_COMMAND target=$commandTarget status=$code',
              );
            }
            expect(
              code,
              0,
              reason: 'Explicit scene instance must accept the command',
            );
          }),
        )
        .toList();
    final anchorBytes = actionsAfterOutput ? await _waitForPcmOutput(pcm) : 0;
    final boundaryCommands = actions
        .map(
          (action) => Future<void>.delayed(action.$1, () async {
            final command = action.$2
                .map((value) => value == r'$followup' ? followup.path : value)
                .toList();
            var code = _commandStatus(backend, command);
            if (code == -12 &&
                command.first == 'af-command' &&
                command.last.contains('@')) {
              command[command.length - 1] = command.last.split('@').last;
              code = _commandStatus(backend, command);
            }
            expect(code, 0, reason: 'Native boundary command must succeed');
            if (command.length == 3 &&
                command[0] == 'set' &&
                command[1] == 'pause' &&
                command[2] == 'yes') {
              expect(
                completed.isCompleted,
                isFalse,
                reason: 'Pause must occur before EOF',
              );
              expect(await backend.getProperty('eof-reached'), 'no');
            }
            actionResults?.add({
              if (actionsAfterOutput) 'action_anchor_pcm_bytes': anchorBytes,
              'command': command,
              'return_code': code,
              'pause_after_reply': await backend.getProperty('pause'),
            });
          }),
        )
        .toList();
    await completed.future.timeout(const Duration(seconds: 10));
    await Future.wait(commands).timeout(const Duration(seconds: 10));
    await Future.wait(boundaryCommands).timeout(const Duration(seconds: 10));
    await player.stop();
    // keep-open leaves PCM stdio buffered; changing AO synchronously closes it.
    expect(_commandStatus(backend, ['set', 'ao', 'null']), 0);
    expect(await backend.getProperty('current-ao'), isNot('pcm'));
    expect(
      errors,
      isEmpty,
      reason: 'Native filter errors cannot count as bypass',
    );
    expect(await pcm.exists(), isTrue);
    final output = audioEffectsPcm(
      await pcm.readAsBytes(),
      intensities: intensities,
      modeIntensities: modeIntensities,
    );
    if (expectFullInput) {
      expect(output.length, frames.length);
    }
    expect(
      output.every((pair) => pair.$1.isFinite && pair.$2.isFinite),
      isTrue,
    );
    return output;
  } finally {
    await player.dispose();
    await logs.cancel();
    await errorEvents.cancel();
    await completion.cancel();
    await directory.delete(recursive: true);
  }
}

Future<int> _waitForPcmOutput(File pcm) async {
  final started = Completer<int>();
  final timer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
    if (pcm.existsSync()) {
      final bytes = pcm.lengthSync();
      if (bytes > 0 && !started.isCompleted) started.complete(bytes);
    }
  });
  try {
    return await started.future.timeout(const Duration(seconds: 10));
  } finally {
    timer.cancel();
  }
}

// NativePlayer.command discards status; capability fallback needs the actual code.
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

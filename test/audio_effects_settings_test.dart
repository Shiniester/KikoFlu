import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_effects_settings.dart';
import 'package:kikoeru_flutter/src/providers/audio_effects_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'defaults bypass; disabling retains parameters; module reset is local',
    () async {
      final settings = AudioEffectsSettings();
      expect(settings.isActive, false);
      final notifier = AudioEffectsSettingsNotifier();
      addTearDown(notifier.dispose);
      await notifier.setPreset(EqualizerPreset.vocal);
      await notifier.setEqualizerEnabled(true);
      await notifier.setScene(AudioScene.telephone);
      await notifier.setSceneAmount(72);
      await notifier.setSceneEnabled(true);
      await notifier.setEqualizerEnabled(false);
      expect(notifier.state.gains[6], 6.5);
      await notifier.resetEqualizer();
      expect(notifier.state.gains, List.filled(10, 0));
      expect(notifier.state.sceneAmount, 72);
      expect(notifier.state.sceneEnabled, true);
      await notifier.resetAll();
      expect(notifier.state.isActive, false);
      expect(notifier.state.sceneAmount, 35);
    },
  );

  test(
    'latest local update wins over async load and survives restart',
    () async {
      SharedPreferences.setMockInitialValues({
        AudioEffectsSettingsNotifier.preferenceKey: jsonEncode(
          AudioEffectsSettings(equalizerEnabled: true).toJson(),
        ),
      });
      final notifier = AudioEffectsSettingsNotifier();
      await Future.wait(List.generate(40, (i) => notifier.setBand(2, i - 20)));
      expect(notifier.state.equalizerEnabled, false);
      expect(notifier.state.gains[2], 15);
      notifier.dispose();
      final restored = AudioEffectsSettingsNotifier();
      addTearDown(restored.dispose);
      await restored.loaded;
      expect(restored.state.gains[2], 15);
      expect(restored.state.preset, null);
    },
  );

  test('stored invalid values normalize at the persistence boundary', () {
    final settings = AudioEffectsSettings.fromJson(const {
      'gains': [100, -100, 'bad'],
      'sceneAmount': 200,
      'scene': 'future',
      'channelMode': 'future',
      'equalizerEnabled': true,
    });
    expect(settings.gains, [15, -15, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect(settings.sceneAmount, 100);
    expect(settings.channelMode, AudioChannelMode.normal);
    expect(settings.scene, AudioScene.bathroom);
  });

  test('all six fixed curves are dB and manual edits select custom', () async {
    final notifier = AudioEffectsSettingsNotifier();
    addTearDown(notifier.dispose);
    await notifier.setPreset(EqualizerPreset.bassBoost);
    expect(notifier.state.gains, [
      4.5,
      4.5,
      3,
      2.5,
      1.5,
      0,
      0,
      -2.5,
      -3.5,
      -5.5,
    ]);
    expect(notifier.state.equalizerEnabled, true);
    expect(EqualizerPreset.values.length, 6);
    await notifier.setBand(0, 1.5);
    expect(notifier.state.preset, null);
    await notifier.setBand(0, 4.5);
    expect(
      notifier.state.gains,
      AudioEffectsSettings.curves[EqualizerPreset.bassBoost],
    );
    expect(notifier.state.preset, null);
    await notifier.setPreset(EqualizerPreset.bassBoost);
    expect(notifier.state.preset, EqualizerPreset.bassBoost);
    await notifier.setBand(0, 1.5);
    await notifier.setEqualizerEnabled(true);
    await notifier.setEqualizerEnabled(false);
    expect(notifier.state.gains[0], 1.5);
  });

  test('Dart preset curves match the Python and docs sources', () async {
    final source = await File(
      'tool/audio_effects/adaptive_eq.py',
    ).readAsString();
    final block = RegExp(
      r'EQ_PRESETS = \{(.*?)\n\}',
      dotAll: true,
    ).firstMatch(source)!.group(1)!;
    final python = <String, List<double>>{};
    for (final line in block.split('\n')) {
      final match = RegExp(r"'(\w+)': \(([^)]*)\)").firstMatch(line);
      if (match == null) continue;
      python[match.group(1)!] = match
          .group(2)!
          .split(',')
          .map((value) => double.parse(value.trim()))
          .toList();
    }
    for (final preset in EqualizerPreset.values) {
      expect(
        python[preset.name],
        AudioEffectsSettings.curves[preset],
        reason: '${preset.name} python',
      );
    }

    const labels = {
      '默认': 'flat',
      '清亮': 'bright',
      '低音增强': 'bassBoost',
      '清脆拍打': 'tappingCrisp',
      '沉闷拍打': 'tappingDull',
      '人声增强': 'vocal',
    };
    final docs = <String, List<double>>{};
    final markdown = await File(
      'docs/development/audio-playback-effects.md',
    ).readAsString();
    for (final line in markdown.split('\n')) {
      final cells = line.trim().split('|');
      if (cells.length < 13) continue;
      final name = labels[cells[1].trim()];
      if (name == null) continue;
      docs[name] = cells
          .sublist(2, 12)
          .map((value) => double.parse(value.trim()))
          .toList();
    }
    for (final preset in EqualizerPreset.values) {
      expect(
        docs[preset.name],
        AudioEffectsSettings.curves[preset],
        reason: '${preset.name} docs',
      );
    }
  });

  test('retuned curves stay within the ASMR boost and level budget', () {
    double sinh(double value) => (math.exp(value) - math.exp(-value)) / 2;

    // Peaking biquad formula: https://www.w3.org/TR/audio-eq-cookbook/
    // Same formula as tool/audio_effects/eq_contracts.py.
    double response(double frequency, double center, double gain) {
      if (gain == 0) return 1;
      center = center.clamp(10.0, 48000 * .45).toDouble();
      final omega = 2 * math.pi * center / 48000;
      final a = math.pow(10, gain / 40);
      final alpha =
          math.sin(omega) * sinh(math.ln2 / 2 * omega / math.sin(omega));
      final b0 = 1 + alpha * a;
      final b1 = -2 * math.cos(omega);
      final b2 = 1 - alpha * a;
      final a0 = 1 + alpha / a;
      final a1 = -2 * math.cos(omega);
      final a2 = 1 - alpha / a;
      final zr = math.cos(-2 * math.pi * frequency / 48000);
      final zi = math.sin(-2 * math.pi * frequency / 48000);
      final z2r = math.cos(-4 * math.pi * frequency / 48000);
      final z2i = math.sin(-4 * math.pi * frequency / 48000);
      final nr = b0 + b1 * zr + b2 * z2r;
      final ni = b1 * zi + b2 * z2i;
      final dr = a0 + a1 * zr + a2 * z2r;
      final di = a1 * zi + a2 * z2i;
      return math.sqrt(nr * nr + ni * ni) / math.sqrt(dr * dr + di * di);
    }

    for (final preset in EqualizerPreset.values.where(
      (preset) => preset != EqualizerPreset.flat,
    )) {
      final gains = AudioEffectsSettings.curves[preset]!;
      var maximum = -double.infinity;
      var average = 0.0;
      var count = 0;
      // 1/24-octave log-spaced grid; see ADR 0011.
      final step = math.pow(2, 1 / 24).toDouble();
      for (var frequency = 20.0; frequency <= 20000; frequency *= step) {
        var magnitude = 0.0;
        for (var band = 0; band < 10; band++) {
          magnitude +=
              20 *
              math.log(
                response(
                  frequency,
                  AudioEffectsSettings.frequencies[band].toDouble(),
                  gains[band],
                ),
              ) /
              math.ln10;
        }
        maximum = math.max(maximum, magnitude);
        if (frequency >= 100 && frequency <= 10000) {
          average += magnitude;
          count++;
        }
      }
      expect(maximum, lessThanOrEqualTo(8), reason: preset.name);
      expect(average / count, inInclusiveRange(-2.5, 2.5), reason: preset.name);
    }
  });

  test(
    'ignores saved binaural effects while retaining other settings',
    () async {
      expect(
        AudioEffectsSettings.fromJson(const {
          'binauralMode': 'stereo',
        }).isActive,
        false,
      );
      SharedPreferences.setMockInitialValues({
        AudioEffectsSettingsNotifier.preferenceKey: jsonEncode({
          'equalizerEnabled': true,
          'gains': [2, 0, 0, 0, 0, 0, 0, 0, 0, 0],
          'channelMode': 'swap',
          'sceneEnabled': true,
          'scene': 'telephone',
          'sceneAmount': 72,
          'binauralMode': 'mono',
          'stereoAmount': 80,
          'monoAmount': 90,
        }),
      });
      final notifier = AudioEffectsSettingsNotifier();
      addTearDown(notifier.dispose);
      await notifier.loaded;
      expect(notifier.state.binauralMode, BinauralMode.off);
      expect(notifier.state.effectiveStereoAmount, 0);
      expect(notifier.state.effectiveMonoAmount, 0);
      expect(notifier.state.gains.first, 2);
      expect(notifier.state.channelMode, AudioChannelMode.swap);
      expect(notifier.state.scene, AudioScene.telephone);
      expect(notifier.state.sceneAmount, 72);
      await notifier.setSceneAmount(73);
      final prefs = await SharedPreferences.getInstance();
      final saved =
          jsonDecode(
                prefs.getString(AudioEffectsSettingsNotifier.preferenceKey)!,
              )
              as Map<String, dynamic>;
      expect(saved.containsKey('binauralMode'), false);
      expect(saved.containsKey('stereoAmount'), false);
      expect(saved.containsKey('monoAmount'), false);
      final restored = AudioEffectsSettingsNotifier();
      addTearDown(restored.dispose);
      await restored.loaded;
      expect(restored.state.binauralMode, BinauralMode.off);
      expect(restored.state.gains.first, 2);
      expect(restored.state.sceneAmount, 73);
    },
  );
}

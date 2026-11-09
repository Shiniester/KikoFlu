import 'dart:convert';
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
      expect(notifier.state.gains[6], 9);
      await notifier.resetEqualizer();
      expect(notifier.state.gains, List.filled(10, 0));
      expect(notifier.state.sceneAmount, 72);
      expect(notifier.state.sceneEnabled, true);
      await notifier.resetAll();
      expect(notifier.state.isActive, false);
      expect(notifier.state.sceneAmount, 50);
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
    expect(notifier.state.gains, [3, 2.5, 2, 1.5, 1, 0, -1, -2.5, -4, -5]);
    expect(EqualizerPreset.values.length, 6);
    await notifier.setBand(0, 1.5);
    expect(notifier.state.preset, null);
    await notifier.setBand(0, 3);
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
  test(
    'binaural modes retain independent strengths and reset only their module',
    () async {
      final notifier = AudioEffectsSettingsNotifier();
      addTearDown(notifier.dispose);
      expect(notifier.state.binauralMode, BinauralMode.off);
      expect(notifier.state.stereoAmount, 50);
      expect(notifier.state.monoAmount, 50);
      await notifier.setPreset(EqualizerPreset.vocal);
      await notifier.setStereoAmount(80);
      await notifier.setMonoAmount(25);
      await notifier.setBinauralMode(BinauralMode.stereo);
      expect(notifier.state.effectiveStereoAmount, .8);
      expect(notifier.state.needsGuard, true);
      await notifier.setBinauralMode(BinauralMode.mono);
      expect(notifier.state.effectiveStereoAmount, 0);
      expect(notifier.state.effectiveMonoAmount, .25);
      await notifier.setBinauralMode(BinauralMode.off);
      expect(notifier.state.stereoAmount, 80);
      expect(notifier.state.monoAmount, 25);
      expect(notifier.state.needsGuard, false);
      await notifier.resetBinaural();
      expect(notifier.state.stereoAmount, 50);
      expect(notifier.state.monoAmount, 50);
      expect(notifier.state.gains[6], 9);
      await notifier.setBinauralMode(BinauralMode.mono);
      await notifier.setMonoAmount(90);
      final restored = AudioEffectsSettingsNotifier();
      addTearDown(restored.dispose);
      await restored.loaded;
      expect(restored.state.binauralMode, BinauralMode.mono);
      expect(restored.state.monoAmount, 90);
      await notifier.resetAll();
      expect(notifier.state.binauralMode, BinauralMode.off);
    },
  );
  test('binaural persistence normalizes legacy and invalid settings', () {
    final legacy = AudioEffectsSettings.fromJson(const {});
    expect(legacy.binauralMode, BinauralMode.off);
    expect(legacy.stereoAmount, 50);
    final invalid = AudioEffectsSettings.fromJson(const {
      'binauralMode': 'future',
      'stereoAmount': 200,
      'monoAmount': -10,
    });
    expect(invalid.binauralMode, BinauralMode.off);
    expect(invalid.stereoAmount, 100);
    expect(invalid.monoAmount, 0);
    expect(invalid.copyWith(binauralMode: BinauralMode.mono).needsGuard, false);
  });
}

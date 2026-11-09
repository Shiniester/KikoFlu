import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/audio_effects_settings.dart';

final audioEffectsSettingsProvider =
    StateNotifierProvider<AudioEffectsSettingsNotifier, AudioEffectsSettings>(
      (ref) => AudioEffectsSettingsNotifier(),
    );

class AudioEffectsSettingsNotifier extends StateNotifier<AudioEffectsSettings> {
  static const preferenceKey = 'playback_audio_effects';
  bool _changedLocally = false;
  Future<void> _writes = Future.value();
  late final Future<void> loaded = _load();

  AudioEffectsSettingsNotifier() : super(AudioEffectsSettings()) {
    loaded;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _changedLocally) return;
      final raw = prefs.getString(preferenceKey);
      if (raw != null) {
        state = AudioEffectsSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      // Keep defaults when the local preference is unavailable or malformed.
    }
  }

  Future<void> _set(AudioEffectsSettings settings) {
    _changedLocally = true;
    state = settings;
    _writes = _writes.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(preferenceKey, jsonEncode(settings.toJson()));
      } catch (_) {
        // Keep the live setting when local persistence is unavailable.
      }
    });
    return _writes;
  }

  Future<void> setEqualizerEnabled(bool value) =>
      _set(state.copyWith(equalizerEnabled: value));
  Future<void> setPreset(EqualizerPreset value) => _set(
    state.copyWith(
      gains: AudioEffectsSettings.curves[value],
      equalizerCustom: false,
    ),
  );
  Future<void> setBand(int index, double value) {
    final gains = List<double>.of(state.gains)..[index] = value;
    return _set(state.copyWith(gains: gains, equalizerCustom: true));
  }

  Future<void> setChannelMode(AudioChannelMode value) =>
      _set(state.copyWith(channelMode: value));
  Future<void> setSceneEnabled(bool value) =>
      _set(state.copyWith(sceneEnabled: value));
  Future<void> setScene(AudioScene value) => _set(state.copyWith(scene: value));
  Future<void> setSceneAmount(double value) =>
      _set(state.copyWith(sceneAmount: value));
  Future<void> resetEqualizer() => _set(
    state.copyWith(
      equalizerEnabled: false,
      equalizerCustom: false,
      gains: AudioEffectsSettings.curves[EqualizerPreset.flat],
    ),
  );
  Future<void> resetChannel() => setChannelMode(AudioChannelMode.normal);
  Future<void> resetScene() => _set(
    state.copyWith(
      sceneEnabled: false,
      scene: AudioScene.bathroom,
      sceneAmount: 50,
    ),
  );
  Future<void> setBinauralMode(BinauralMode value) =>
      _set(state.copyWith(binauralMode: value));
  Future<void> setStereoAmount(double value) =>
      _set(state.copyWith(stereoAmount: value));
  Future<void> setMonoAmount(double value) =>
      _set(state.copyWith(monoAmount: value));
  Future<void> resetBinaural() => _set(
    state.copyWith(
      binauralMode: BinauralMode.off,
      stereoAmount: 50,
      monoAmount: 50,
    ),
  );
  Future<void> resetAll() => _set(AudioEffectsSettings());
}

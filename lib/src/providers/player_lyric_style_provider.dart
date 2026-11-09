import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PlayerLyricSpringPreset {
  defaultPreset('default', 0.9, 15, 90),
  smooth('smooth', 1.2, 22, 80),
  responsive('responsive', 0.5, 18, 150),
  jello('jello', 0.6, 8, 120),
  heavy('heavy', 2, 25, 60),
  noBounce('noBounce', 1, 30, 100);

  const PlayerLyricSpringPreset(
    this.id,
    this.mass,
    this.damping,
    this.stiffness,
  );

  final String id;
  final double mass;
  final double damping;
  final double stiffness;

  static PlayerLyricSpringPreset fromId(String? id) => values.firstWhere(
    (preset) => preset.id == id,
    orElse: () => PlayerLyricSpringPreset.defaultPreset,
  );
}

class PlayerLyricSettings {
  // Mini Player
  final double miniFontSize;
  final double miniLineHeight;

  // Small Player (Portrait below cover)
  final double smallFontSize;
  final double smallLineHeight;

  // Full Player (Portrait full / Landscape)
  final double fullActiveFontSize;
  final double fullInactiveFontSize;
  final double fullLineHeight;
  final int fullFontWeight;
  final PlayerLyricSpringPreset springPreset;

  const PlayerLyricSettings({
    this.miniFontSize = 11.0,
    this.miniLineHeight = 1.0,
    this.smallFontSize = 14.0,
    this.smallLineHeight = 1.2,
    this.fullActiveFontSize = 18.0,
    this.fullInactiveFontSize = 16.0,
    this.fullLineHeight = 1.5,
    this.fullFontWeight = 700,
    this.springPreset = PlayerLyricSpringPreset.defaultPreset,
  });

  PlayerLyricSettings copyWith({
    double? miniFontSize,
    double? miniLineHeight,
    double? smallFontSize,
    double? smallLineHeight,
    double? fullActiveFontSize,
    double? fullInactiveFontSize,
    double? fullLineHeight,
    int? fullFontWeight,
    PlayerLyricSpringPreset? springPreset,
  }) {
    return PlayerLyricSettings(
      miniFontSize: miniFontSize ?? this.miniFontSize,
      miniLineHeight: miniLineHeight ?? this.miniLineHeight,
      smallFontSize: smallFontSize ?? this.smallFontSize,
      smallLineHeight: smallLineHeight ?? this.smallLineHeight,
      fullActiveFontSize: fullActiveFontSize ?? this.fullActiveFontSize,
      fullInactiveFontSize: fullInactiveFontSize ?? this.fullInactiveFontSize,
      fullLineHeight: fullLineHeight ?? this.fullLineHeight,
      fullFontWeight: fullFontWeight ?? this.fullFontWeight,
      springPreset: springPreset ?? this.springPreset,
    );
  }
}

class PlayerLyricSettingsNotifier extends StateNotifier<PlayerLyricSettings> {
  static const _keyPrefix = 'player_lyric_';
  static const _springPresetKey = 'player_lyric_spring_preset';
  bool _springPresetChangedLocally = false;

  PlayerLyricSettingsNotifier() : super(const PlayerLyricSettings()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();

    state = PlayerLyricSettings(
      miniFontSize: prefs.getDouble('${_keyPrefix}miniFontSize') ?? 11.0,
      miniLineHeight: prefs.getDouble('${_keyPrefix}miniLineHeight') ?? 1.0,
      smallFontSize: prefs.getDouble('${_keyPrefix}smallFontSize') ?? 14.0,
      smallLineHeight: prefs.getDouble('${_keyPrefix}smallLineHeight') ?? 1.2,
      fullActiveFontSize:
          prefs.getDouble('${_keyPrefix}fullActiveFontSize') ?? 18.0,
      fullInactiveFontSize:
          prefs.getDouble('${_keyPrefix}fullInactiveFontSize') ?? 16.0,
      fullLineHeight: prefs.getDouble('${_keyPrefix}fullLineHeight') ?? 1.5,
      fullFontWeight: prefs.getInt('${_keyPrefix}fullFontWeight') ?? 700,
      springPreset: _springPresetChangedLocally
          ? state.springPreset
          : PlayerLyricSpringPreset.fromId(prefs.getString(_springPresetKey)),
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('${_keyPrefix}miniFontSize', state.miniFontSize);
    await prefs.setDouble('${_keyPrefix}miniLineHeight', state.miniLineHeight);
    await prefs.setDouble('${_keyPrefix}smallFontSize', state.smallFontSize);
    await prefs.setDouble(
      '${_keyPrefix}smallLineHeight',
      state.smallLineHeight,
    );
    await prefs.setDouble(
      '${_keyPrefix}fullActiveFontSize',
      state.fullActiveFontSize,
    );
    await prefs.setDouble(
      '${_keyPrefix}fullInactiveFontSize',
      state.fullInactiveFontSize,
    );
    await prefs.setDouble('${_keyPrefix}fullLineHeight', state.fullLineHeight);
    await prefs.setInt('${_keyPrefix}fullFontWeight', state.fullFontWeight);
    await prefs.setString(_springPresetKey, state.springPreset.id);
  }

  Future<void> updateMiniFontSize(double value) async {
    state = state.copyWith(miniFontSize: value);
    await _save();
  }

  Future<void> updateMiniLineHeight(double value) async {
    state = state.copyWith(miniLineHeight: value);
    await _save();
  }

  Future<void> updateSmallFontSize(double value) async {
    state = state.copyWith(smallFontSize: value);
    await _save();
  }

  Future<void> updateSmallLineHeight(double value) async {
    state = state.copyWith(smallLineHeight: value);
    await _save();
  }

  Future<void> updateFullActiveFontSize(double value) async {
    state = state.copyWith(fullActiveFontSize: value);
    await _save();
  }

  Future<void> updateFullInactiveFontSize(double value) async {
    state = state.copyWith(fullInactiveFontSize: value);
    await _save();
  }

  Future<void> updateFullLineHeight(double value) async {
    state = state.copyWith(fullLineHeight: value);
    await _save();
  }

  Future<void> updateFullFontWeight(int value) async {
    final normalized = (value.clamp(100, 900) ~/ 100) * 100;
    state = state.copyWith(fullFontWeight: normalized);
    await _save();
  }

  Future<void> updateFullFontSize(double value) async {
    state = state.copyWith(
      fullActiveFontSize: value,
      fullInactiveFontSize: value,
    );
    await _save();
  }

  Future<void> updateSpringPreset(PlayerLyricSpringPreset value) async {
    _springPresetChangedLocally = true;
    state = state.copyWith(springPreset: value);
    await _save();
  }

  Future<void> reset() async {
    _springPresetChangedLocally = true;
    state = const PlayerLyricSettings();
    await _save();
  }
}

final playerLyricSettingsProvider =
    StateNotifierProvider<PlayerLyricSettingsNotifier, PlayerLyricSettings>((
      ref,
    ) {
      return PlayerLyricSettingsNotifier();
    });

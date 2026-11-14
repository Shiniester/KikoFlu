import 'package:flutter/foundation.dart';

enum AudioChannelMode { normal, swap, cloneLeft, cloneRight }

enum BinauralMode { off, stereo, mono }

enum AudioScene { bathroom, muffled, telephone }

enum EqualizerPreset {
  flat,
  bright,
  bassBoost,
  tappingCrisp,
  tappingDull,
  vocal,
}

@immutable
class AudioEffectsSettings {
  static const frequencies = [
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
  ];
  static const curves = <EqualizerPreset, List<double>>{
    EqualizerPreset.flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    EqualizerPreset.bright: [-3.5, -2.5, -2, -1, -1, 0, 1, 2.5, 4.5, 3.5],
    EqualizerPreset.bassBoost: [4.5, 4.5, 3, 2.5, 1.5, 0, 0, -2.5, -3.5, -5.5],
    EqualizerPreset.tappingCrisp: [
      -4.5,
      -2.5,
      -2.5,
      -2,
      -1,
      1,
      2.5,
      5.5,
      4.5,
      1,
    ],
    EqualizerPreset.tappingDull: [
      2.5,
      3.5,
      4.5,
      3.5,
      2,
      -2,
      -2.5,
      -4.5,
      -6.5,
      -10,
    ],
    EqualizerPreset.vocal: [-3.5, -2, -2, 0, 1, 4.5, 6.5, 2.5, 0, -4.5],
  };

  AudioEffectsSettings({
    this.equalizerEnabled = false,
    this.equalizerCustom = false,
    List<double>? gains,
    this.channelMode = AudioChannelMode.normal,
    this.binauralMode = BinauralMode.off,
    double stereoAmount = 50,
    double monoAmount = 50,
    this.sceneEnabled = false,
    this.scene = AudioScene.bathroom,
    double sceneAmount = 35,
  }) : gains = List.unmodifiable(
         List.generate(
           10,
           (i) => normalize(
             gains != null && i < gains.length ? gains[i] : 0,
             -15,
             15,
           ),
         ),
       ),
       stereoAmount = normalize(stereoAmount, 0, 100),
       monoAmount = normalize(monoAmount, 0, 100),
       sceneAmount = normalize(sceneAmount, 0, 100);

  final bool equalizerEnabled;
  final bool equalizerCustom;
  final List<double> gains;
  final AudioChannelMode channelMode;
  final BinauralMode binauralMode;
  final double stereoAmount;
  final double monoAmount;
  final bool sceneEnabled;
  final AudioScene scene;
  final double sceneAmount;

  static double normalize(double value, double min, double max) =>
      value.isFinite ? value.clamp(min, max).toDouble() : 0;
  List<double> get effectiveGains =>
      equalizerEnabled ? gains : curves[EqualizerPreset.flat]!;
  double get effectiveStereoAmount =>
      binauralMode == BinauralMode.stereo ? stereoAmount / 100 : 0;
  double get effectiveMonoAmount =>
      binauralMode == BinauralMode.mono ? monoAmount / 100 : 0;
  bool get equalizerActive => equalizerEnabled && gains.any((g) => g != 0);
  bool get channelActive => channelMode != AudioChannelMode.normal;
  bool get binauralActive =>
      effectiveStereoAmount > 0 || effectiveMonoAmount > 0;
  bool get sceneActive => sceneEnabled && sceneAmount > 0;
  bool get needsGuard => equalizerActive || binauralActive;
  bool get isActive =>
      equalizerActive || channelActive || binauralActive || sceneActive;
  EqualizerPreset? get preset {
    if (equalizerCustom) return null;
    for (final entry in curves.entries) {
      if (listEquals(entry.value, gains)) return entry.key;
    }
    return null;
  }

  AudioEffectsSettings copyWith({
    bool? equalizerEnabled,
    bool? equalizerCustom,
    List<double>? gains,
    AudioChannelMode? channelMode,
    BinauralMode? binauralMode,
    double? stereoAmount,
    double? monoAmount,
    bool? sceneEnabled,
    AudioScene? scene,
    double? sceneAmount,
  }) => AudioEffectsSettings(
    equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
    equalizerCustom: equalizerCustom ?? this.equalizerCustom,
    gains: gains ?? this.gains,
    channelMode: channelMode ?? this.channelMode,
    binauralMode: binauralMode ?? this.binauralMode,
    stereoAmount: stereoAmount ?? this.stereoAmount,
    monoAmount: monoAmount ?? this.monoAmount,
    sceneEnabled: sceneEnabled ?? this.sceneEnabled,
    scene: scene ?? this.scene,
    sceneAmount: sceneAmount ?? this.sceneAmount,
  );

  Map<String, Object> toJson() => {
    'equalizerEnabled': equalizerEnabled,
    'equalizerCustom': equalizerCustom,
    'gains': gains,
    'channelMode': channelMode.name,
    'sceneEnabled': sceneEnabled,
    'scene': scene.name,
    'sceneAmount': sceneAmount,
  };

  factory AudioEffectsSettings.fromJson(Map<String, dynamic> json) {
    final stored = json['gains'];
    return AudioEffectsSettings(
      equalizerEnabled: json['equalizerEnabled'] == true,
      equalizerCustom: json['equalizerCustom'] == true,
      gains: stored is List
          ? stored.map((v) => v is num ? v.toDouble() : 0.0).toList()
          : null,
      channelMode:
          AudioChannelMode.values
              .where((v) => v.name == json['channelMode'])
              .firstOrNull ??
          AudioChannelMode.normal,
      sceneEnabled: json['sceneEnabled'] == true,
      scene:
          AudioScene.values.where((v) => v.name == json['scene']).firstOrNull ??
          AudioScene.bathroom,
      sceneAmount: json['sceneAmount'] is num
          ? (json['sceneAmount'] as num).toDouble()
          : 35,
    );
  }
}

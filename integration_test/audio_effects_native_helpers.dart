import 'dart:math' as math;
import 'dart:typed_data';

List<(int, int)> modeFixture() => List.generate(
  163217,
  (n) => (
    (.7 * math.sin(2 * math.pi * 440 * n / 48000) * 32767).round(),
    (.6 * math.sin(2 * math.pi * 700 * n / 48000 + .2) * 32767).round(),
  ),
);

List<(int, int)> boundaryFixture() => List.generate(
  144017,
  (n) => (
    ((.2 * math.sin(2 * math.pi * 440 * n / 48000) +
                .1 * math.sin(2 * math.pi * 1733 * n / 48000)) *
            32767)
        .round(),
    ((.15 * math.sin(2 * math.pi * 700 * n / 48000) +
                .05 * math.sin(2 * math.pi * 1000 * n / 48000 + .2)) *
            32767)
        .round(),
  ),
);

List<(int, int)> combinationFixture() => List.generate(
  384000,
  (n) => (
    ((.7 * math.sin(2 * math.pi * 440 * n / 96000) +
                .1 * math.sin(2 * math.pi * 1733 * n / 96000)) *
            32767)
        .round(),
    ((.6 * math.sin(2 * math.pi * 880 * n / 96000) +
                .15 * math.sin(2 * math.pi * 2199 * n / 96000)) *
            32767)
        .round(),
  ),
);

const _sceneProfiles = <String, Map<String, num>>{
  'bathroom': {
    'dry': .58,
    'direct': .30,
    'reflection': .72,
    'feedback': .52,
    'mono': .20,
    'width': .88,
    'hp': 180,
    'hpStages': 1,
    'lp': 6400,
    'lpStages': 1,
    'gain': .90,
    'drive': 0,
  },
  'through_wall': {
    'dry': .03,
    'direct': 1.02,
    'reflection': .16,
    'feedback': .20,
    'mono': .68,
    'width': .18,
    'hp': 120,
    'hpStages': 1,
    'lp': 1200,
    'lpStages': 3,
    'gain': 1,
    'drive': 0,
  },
  'telephone': {
    'dry': 0,
    'direct': 1.08,
    'reflection': 0,
    'feedback': 0,
    'mono': 1,
    'width': 0,
    'hp': 430,
    'hpStages': 3,
    'lp': 2850,
    'lpStages': 3,
    'gain': 1.06,
    'drive': .34,
  },
};
const _sceneTaps = <String, List<(int, double)>>{
  'bathroom': [(16, .32), (27, .28), (41, .23), (63, .18), (96, .12)],
  'through_wall': [(14, .10), (24, .07), (39, .05)],
  'telephone': [],
};

// Independent Eara recurrence for comparing actual native PCM.
List<(double, double)> sceneOracle(
  List<(int, int)> input,
  String scene,
  int amount, {
  List<double>? intensities,
}) => sceneOraclePcm(
  input.map((pair) => (pair.$1 / 32768, pair.$2 / 32768)).toList(),
  scene,
  amount,
  intensities: intensities,
);

List<(double, double)> sceneOraclePcm(
  List<(double, double)> input,
  String scene,
  int amount, {
  List<double>? intensities,
}) {
  if (amount == 0 && intensities == null) {
    return input;
  }
  final profile = _sceneProfiles[scene]!;
  final taps = _sceneTaps[scene]!;
  const rate = 48000;
  double tanh(double x) {
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }

  final hp = 1 / (1 + 2 * math.pi * profile['hp']! / rate);
  final lp = 1 / (1 + rate / (2 * math.pi * profile['lp']!));
  final hpCount = profile['hpStages']!.toInt();
  final lpCount = profile['lpStages']!.toInt();
  final previousInput = List.generate(hpCount, (_) => [0.0, 0.0]);
  final previousHp = List.generate(hpCount, (_) => [0.0, 0.0]);
  final previousLp = List.generate(lpCount, (_) => [0.0, 0.0]);
  final history = <List<double>>[];
  final result = <(double, double)>[];
  final delay = taps.isEmpty ? 0 : taps.last.$1 * 48;
  for (var n = 0; n < input.length; n++) {
    final intensity = intensities?[n] ?? amount / 100;
    final wet = intensity * (1 + .45 * intensity * intensity);
    final blend = math.min(1, intensity + .2 * intensity * intensity);
    final dry = (1 - (1 - profile['dry']!) * blend).clamp(0.0, 1.0);
    final direct = profile['direct']! * wet;
    final reflectionMix = profile['reflection']! * wet;
    final feedback = math.min(.88, profile['feedback']! * wet);
    final width =
        (1 + (profile['width']! - 1) * blend).clamp(0.0, 1.25) *
        (1 - math.min(1, profile['mono']! * wet));
    final gain = 1 + (profile['gain']! - 1) * intensity;
    final drive = profile['drive']! * wet;
    final scale = 1 + 4 * drive;

    final original = [input[n].$1, input[n].$2];
    final mid = (original[0] + original[1]) / 2;
    final written = <double>[];
    final output = <double>[];
    for (var channel = 0; channel < 2; channel++) {
      var filtered = mid + (original[channel] - mid) * width;
      for (var stage = 0; stage < hpCount; stage++) {
        final high =
            hp *
            (previousHp[stage][channel] +
                filtered -
                previousInput[stage][channel]);
        previousInput[stage][channel] = filtered;
        previousHp[stage][channel] = high;
        filtered = high;
      }
      for (var stage = 0; stage < lpCount; stage++) {
        filtered =
            previousLp[stage][channel] +
            lp * (filtered - previousLp[stage][channel]);
        previousLp[stage][channel] = filtered;
      }
      final delayed = delay > 0 && n >= delay
          ? history[n - delay][channel]
          : 0.0;
      written.add((filtered + feedback * delayed).clamp(-1.25, 1.25));
      var reflection = 0.0;
      for (final (ms, tapGain) in taps) {
        if (n >= ms * 48) reflection += tapGain * history[n - ms * 48][channel];
      }
      var value =
          gain *
          (dry * original[channel] +
              direct * filtered +
              reflectionMix * reflection);
      if (drive > 0) {
        value = tanh((value * scale).clamp(-8.0, 8.0)) / tanh(scale);
      }
      output.add(value.clamp(-1.0, 1.0));
    }
    history.add(written);
    result.add((output[0], output[1]));
  }
  return result;
}

List<(int, int)> networkFixture() => List.generate(48000, (n) {
  if (n >= 7200 && n < 7208) {
    return ((.75 * 32767).round(), (-.5 * 32767).round());
  }
  if (n >= 38400) return (0, 0);
  return (
    (.18 * math.sin(2 * math.pi * 440 * n / 48000) * 32767).round(),
    (.12 * math.sin(2 * math.pi * 880 * n / 48000 + .3) * 32767).round(),
  );
});

double audioEffectsToneAmplitude(
  List<double> samples,
  int frequency,
  int rate,
) {
  var real = 0.0;
  var imaginary = 0.0;
  for (var n = 0; n < samples.length; n++) {
    final phase = 2 * math.pi * frequency * n / rate;
    real += samples[n] * math.cos(phase);
    imaginary += samples[n] * math.sin(phase);
  }
  return 2 * math.sqrt(real * real + imaginary * imaginary) / samples.length;
}

List<(int, int)> monoFixture(int rate) {
  return List.generate((rate * .3).toInt(), (n) {
    final t = n / rate;
    final value = .1 <= t && t < .1002
        ? .75
        : .11 < t && t < .2
        ? .17 * math.sin(2 * math.pi * 440 * t) +
              .11 * math.sin(2 * math.pi * 1733 * t)
        : 0.0;
    final sample = (value * 32767).round();
    return (sample, sample);
  });
}

List<(int, int)> bathroomFixture() => List.generate(33600, (n) {
  if (n >= 24000) return (0, 0);
  return (
    (.97 * math.sin(2 * math.pi * 1000 * n / 48000) * 32767).round(),
    (.94 * math.sin(2 * math.pi * 1000 * n / 48000 + .15) * 32767).round(),
  );
});

Uint8List audioEffectsWav(
  List<(int, int)> frames,
  int rate, {
  bool mono = false,
}) {
  final channels = mono ? 1 : 2;
  final frameBytes = channels * 2;
  final bytes = Uint8List(44 + frames.length * frameBytes);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) {
    bytes.setRange(offset, offset + value.length, value.codeUnits);
  }

  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * frameBytes, Endian.little);
  data.setUint16(32, frameBytes, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, frames.length * frameBytes, Endian.little);
  for (var n = 0; n < frames.length; n++) {
    data.setInt16(44 + n * frameBytes, frames[n].$1, Endian.little);
    if (!mono) {
      data.setInt16(46 + n * frameBytes, frames[n].$2, Endian.little);
    }
  }
  return bytes;
}

List<(double, double)> audioEffectsPcm(
  Uint8List bytes, {
  List<double>? intensities,
  List<List<double>>? modeIntensities,
}) {
  final frameBytes = modeIntensities != null
      ? 20
      : intensities == null
      ? 8
      : 12;
  if (bytes.length % frameBytes != 0) {
    throw StateError('Expected interleaved float32 PCM');
  }
  final data = ByteData.sublistView(bytes);
  return List.generate(bytes.length ~/ frameBytes, (n) {
    if (intensities != null) {
      intensities.add(data.getFloat32(n * frameBytes + 8, Endian.little));
    }
    if (modeIntensities != null) {
      for (var channel = 0; channel < 3; channel++) {
        modeIntensities[channel].add(
          data.getFloat32(n * frameBytes + 8 + channel * 4, Endian.little),
        );
      }
    }
    return (
      data.getFloat32(n * frameBytes, Endian.little),
      data.getFloat32(n * frameBytes + 4, Endian.little),
    );
  });
}

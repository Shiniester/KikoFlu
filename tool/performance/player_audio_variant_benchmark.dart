import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';

void main() {
  test('player audio variant scan and filtering benchmark', () {
    const classifier = PlayerAudioVariantClassifier();
    for (final count in [40, 160]) {
      final tree = <dynamic>[
        for (var index = 0; index < count; index++) ...[
          {
            'type': 'audio',
            'title': 't${index.toString().padLeft(4, '0')}.wav',
            'hash': 'audio-$index',
          },
          {
            'type': 'text',
            'title': 't${index.toString().padLeft(4, '0')}_简中.lrc',
            'hash': 'subtitle-$index',
          },
        ],
      ];
      _measure('scan $count audio + $count subtitles', () {
        final variants = classifier.scan(tree);
        expect(variants, hasLength(count));
        expect(
          variants.every(
            (variant) =>
                variant.subtitleLanguage ==
                    PlayerSubtitleLanguage.simplifiedChinese &&
                variant.subtitleSources.length == 1,
          ),
          isTrue,
        );
      });
    }

    final variants = classifier.scan([
      for (var index = 0; index < 5000; index++)
        {
          'type': 'audio',
          'title': 't${index.toString().padLeft(4, '0')}.wav',
          'hash': 'audio-$index',
        },
    ]);
    for (final (label, filter) in [
      ('default', const PlayerAudioVariantFilter()),
      (
        'manual',
        const PlayerAudioVariantFilter(formats: {PlayerAudioFormat.wav}),
      ),
      (
        'keyword',
        const PlayerAudioVariantFilter(showAll: true, keyword: 't00'),
      ),
    ]) {
      _measure('filter 5000 $label', () {
        final result = classifier.applyFilter(variants, filter);
        expect(result, hasLength(label == 'keyword' ? 100 : 5000));
      });
    }
  });
}

void _measure(String label, void Function() operation) {
  for (var index = 0; index < 2; index++) {
    operation();
  }
  final samples = <int>[];
  for (var index = 0; index < 5; index++) {
    final stopwatch = Stopwatch()..start();
    operation();
    samples.add(stopwatch.elapsedMicroseconds);
  }
  samples.sort();
  // ignore: avoid_print
  print('$label: ${samples[samples.length ~/ 2] / 1000} ms (median of 5)');
}

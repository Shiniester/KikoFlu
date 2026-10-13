import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/lyric/lyric_parser.dart';
import 'package:kikoeru_flutter/src/services/local_audio_transcriber.dart';

void main() {
  test(
    'Silero input windows preserve samples across decoder read boundaries',
    () {
      final firstRead = Float32List.fromList(
        List<double>.generate(700, (index) => index.toDouble()),
      );
      final secondRead = Float32List.fromList(
        List<double>.generate(325, (index) => (index + 700).toDouble()),
      );

      final windows = LocalAudioTranscriber.vadWindowsForTesting([
        firstRead,
        secondRead,
      ]);

      expect(windows, hasLength(3));
      expect(windows.every((window) => window.length == 512), isTrue);
      final samples = windows.expand((window) => window).toList();
      expect(
        samples.take(1025),
        orderedEquals(List<double>.generate(1025, (index) => index.toDouble())),
      );
      expect(samples.skip(1025).every((sample) => sample == 0), isTrue);
    },
  );

  test('generated SRT keeps sample-offset timeline and parses as subtitles', () {
    final srt = LocalAudioTranscriber.formatSrtForTesting([
      (startSample: 88000, endSample: 131200, text: '後半'),
      (startSample: 16000, endSample: 64000, text: 'こんにちは'),
    ]);

    expect(
      srt,
      '1\n00:00:01,000 --> 00:00:04,000\nこんにちは\n\n'
      '2\n00:00:05,500 --> 00:00:08,200\n後半\n',
    );

    final subtitles = LyricParser.parse(srt);
    expect(subtitles, hasLength(2));
    expect(subtitles[0].text, 'こんにちは');
    expect(subtitles[0].startTime, const Duration(seconds: 1));
    // The app's shared parser treats each cue as ending at the next cue start.
    expect(subtitles[0].endTime, const Duration(seconds: 5, milliseconds: 500));
    expect(
      subtitles[1].startTime,
      const Duration(seconds: 5, milliseconds: 500),
    );
    expect(subtitles[1].endTime, const Duration(seconds: 8, milliseconds: 200));
  });
}

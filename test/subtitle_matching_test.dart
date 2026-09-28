import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_matching.dart';

void main() {
  group('SubtitleMatcher', () {
    test('exact base name match returns perfect score', () {
      final result = SubtitleMatcher.check('track01.lrc', 'track01.mp3');

      expect(result.isMatch, true);
      expect(result.score, 1.0);
    });

    test('subtitle names can include audio extensions before subtitle suffix',
        () {
      final result = SubtitleMatcher.check('track01.mp3.srt', 'track01.mp3');

      expect(result.isMatch, true);
      expect(result.score, 1.0);
    });

    test('normalizes bracket suffixes and punctuation for fuzzy match', () {
      final result = SubtitleMatcher.check('第01話(SEなし).vtt', '第01話.mp3');

      expect(result.isMatch, true);
      expect(result.score, 1.0);
    });

    test('keeps full-width track numbers distinct', () {
      const fullWidthDigits = '１２３４５６７';

      for (var audioIndex = 0; audioIndex < fullWidthDigits.length; audioIndex++) {
        final audioName = 'トラック${fullWidthDigits[audioIndex]}.wav';

        for (var subtitleIndex = 0;
            subtitleIndex < fullWidthDigits.length;
            subtitleIndex++) {
          final subtitleName = 'トラック${fullWidthDigits[subtitleIndex]}.lrc';
          final result = SubtitleMatcher.check(subtitleName, audioName);

          expect(
            result.isMatch,
            subtitleIndex == audioIndex,
            reason: '$subtitleName should match only $audioName',
          );
        }
      }
    });

    test('matches mixed-width track numbers and ignores SE suffixes', () {
      final result = SubtitleMatcher.check(
        'トラック2.lrc',
        'トラック２SEなし.wav',
      );

      expect(result.isMatch, true);
      expect(result.score, 1.0);
    });

    test('rejects unsupported subtitle extensions', () {
      final result = SubtitleMatcher.check('track01.json', 'track01.mp3');

      expect(result.isMatch, false);
      expect(result.score, 0.0);
    });

    test('prepared matcher preserves results and scores', () {
      const pairs = [
        ('track01.lrc', 'track01.mp3'),
        ('track01.mp3.srt', 'track01.mp3'),
        ('第01話(SEなし).vtt', '第01話.mp3'),
        ('トラック2.lrc', 'トラック２SEなし.wav'),
        ('different-name.json', 'track01.mp3'),
      ];

      for (final (subtitle, audio) in pairs) {
        final prepared = SubtitleMatcher.checkPrepared(
          SubtitleMatcher.prepareSubtitle(subtitle),
          SubtitleMatcher.prepareAudio(audio),
        );
        final direct = SubtitleMatcher.check(subtitle, audio);

        expect(prepared.toRecord(), direct.toRecord());
      }
    });

    test('keeps exact fuzzy scores on both sides of the threshold', () {
      for (final (subtitle, score, matches) in [
        ('abcdefghijklmnopqxyz.srt', 0.85, true),
        ('abcdefghijklmnopwxyz.srt', 0.8, false),
      ]) {
        const audio = 'abcdefghijklmnopqrst.mp3';
        final direct = SubtitleMatcher.check(subtitle, audio);
        final prepared = SubtitleMatcher.checkPrepared(
          SubtitleMatcher.prepareSubtitle(subtitle),
          SubtitleMatcher.prepareAudio(audio),
        );
        expect(direct.score, closeTo(score, 1e-12));
        expect(direct.isMatch, matches);
        expect(prepared.toRecord(), direct.toRecord());
      }
    });

    test('removeAudioExtension keeps non-audio names unchanged', () {
      expect(SubtitleMatcher.removeAudioExtension('track01.mp3'), 'track01');
      expect(
          SubtitleMatcher.removeAudioExtension('track01.txt'), 'track01.txt');
    });

    test('SubtitleLibraryService keeps compatible matching facade', () {
      final result = SubtitleLibraryService.checkMatch(
        'track01.lrc',
        'track01.wav',
      );

      expect(result.$1, true);
      expect(result.$2, 1.0);
      expect(
        SubtitleLibraryService.isSubtitleForAudio('track01.srt', 'track01.wav'),
        true,
      );
    });
  });
}

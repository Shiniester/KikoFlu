import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/subtitle_language.dart';
import 'package:kikoeru_flutter/src/services/subtitle_matching.dart';
import 'package:kikoeru_flutter/src/services/work_subtitle_candidate_selector.dart';

void main() {
  for (final (locale, tags) in [
    (
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      ['zh-Hans', 'zh_CN', '简体', 'chs'],
    ),
    (
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ['zh-Hant', 'zh_TW', '繁體', 'cht'],
    ),
    (const Locale('en'), ['en', 'eng', 'English', '英文']),
    (const Locale('ja'), ['ja', 'jp', 'Japanese', '日本語']),
  ]) {
    for (final tag in tags) {
      test('recognizes $tag in filenames and directories', () {
        expect(
          SubtitleLanguage.matchesTarget('scene01.$tag.srt', locale),
          isTrue,
        );
        expect(
          SubtitleLanguage.matchesTarget('$tag/scene01.srt', locale),
          isTrue,
        );
        expect(
          SubtitleLanguage.match(
            'scene01.$tag.srt',
            SubtitleMatcher.prepareAudio('scene01.wav'),
          ).isMatch,
          isTrue,
        );
        expect(
          SubtitleLanguage.match(
            'scene02.$tag.srt',
            SubtitleMatcher.prepareAudio('scene01.wav'),
          ).isMatch,
          isFalse,
        );
      });
    }
  }

  test(
    'filename tags override directories and the nearest marked directory wins',
    () {
      expect(
        SubtitleLanguage.matchesTarget(
          '英文/日文/scene01.zh-Hans.srt',
          const Locale('en'),
        ),
        isFalse,
      );
      expect(
        SubtitleLanguage.matchesTarget(
          '英文/日文/scene01.zh-Hans.srt',
          const Locale('zh'),
        ),
        isTrue,
      );
      expect(
        SubtitleLanguage.matchesTarget('英文/日文/scene01.srt', const Locale('ja')),
        isTrue,
      );
      expect(
        SubtitleLanguage.matchesTarget('英文/日文/scene01.srt', const Locale('en')),
        isFalse,
      );
      expect(
        SubtitleLanguage.matchesTarget(
          'Englishman/scene01.srt',
          const Locale('en'),
        ),
        isFalse,
      );
      expect(
        SubtitleLanguage.matchesTarget(
          'unknown/scene01.srt',
          const Locale('en'),
        ),
        isFalse,
      );
    },
  );

  test(
    'target language precedes score only among matching audio candidates',
    () {
      final candidates = const WorkSubtitleCandidateSelector()
          .collectWorkCandidates(
            fileTree: const [
              {'type': 'text', 'title': 'abcdefghijklmnopqrst.srt'},
              {'type': 'text', 'title': 'abcdefghijklmnopqrsx.en.srt'},
              {'type': 'text', 'title': 'another-track.en.srt'},
            ],
            audioTitle: 'abcdefghijklmnopqrst.wav',
            targetLocale: const Locale('en'),
          );
      expect(candidates.first.title, 'abcdefghijklmnopqrsx.en.srt');
      expect(candidates.first.matchScore, lessThan(candidates[1].matchScore));
      expect(candidates.last.matchesCurrentAudio, isFalse);
    },
  );

  test('unknown languages keep the original score and directory fallback', () {
    final candidates = const WorkSubtitleCandidateSelector()
        .collectWorkCandidates(
          fileTree: const [
            {
              'type': 'folder',
              'title': 'Disc',
              'children': [
                {'type': 'audio', 'title': 'scene01.wav', 'hash': 'audio'},
                {'type': 'text', 'title': 'scene01.srt'},
              ],
            },
            {'type': 'text', 'title': 'scene01.lrc'},
          ],
          audioTitle: 'scene01.wav',
          audioHash: 'audio',
          targetLocale: const Locale('en'),
        );
    expect(candidates.first.pathLabel, 'Disc/scene01.srt');
  });
}

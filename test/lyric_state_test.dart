import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';

void main() {
  group('LyricState.displayLyrics', () {
    test('reuses the list through unrelated state copies', () {
      final lyrics = _lyrics('original');
      final translatedLyrics = _lyrics('translated');
      final state = LyricState(
        lyrics: lyrics,
        translatedLyrics: translatedLyrics,
        timelineOffset: const Duration(seconds: 2),
      );
      final displayLyrics = state.displayLyrics;

      expect(state.displayLyrics, same(displayLyrics));

      final progressUpdate = state.copyWith(
        isLoading: true,
        error: 'temporary error',
        lyricUrl: 'file://lyrics.lrc',
        isTranslating: true,
        translatedCount: 2,
        translationTotal: 3,
        translatedSubtitlePath: 'translated.lrc',
        source: const LyricSourceDescriptor(
          title: 'lyrics.lrc',
          type: LyricSourceType.localFile,
        ),
      );
      expect(progressUpdate.displayLyrics, same(displayLyrics));

      final explicitSameInputs = progressUpdate.copyWith(
        lyrics: lyrics,
        translatedLyrics: translatedLyrics,
        showTranslated: false,
        timelineOffset: const Duration(seconds: 2),
      );
      expect(explicitSameInputs.displayLyrics, same(displayLyrics));

      final unselectedTranslationUpdate = state.copyWith(
        translatedLyrics: _lyrics('new translation'),
      );
      expect(unselectedTranslationUpdate.displayLyrics, same(displayLyrics));
    });

    test(
      'invalidates when the selected subtitle content or selection changes',
      () {
        final lyrics = _lyrics('original');
        final translatedLyrics = _lyrics('translated');
        final state = LyricState(
          lyrics: lyrics,
          translatedLyrics: translatedLyrics,
          timelineOffset: const Duration(seconds: 2),
        );
        final originalDisplay = state.displayLyrics;

        final replacedLyrics = state.copyWith(
          lyrics: _lyrics('updated original'),
        );
        expect(replacedLyrics.displayLyrics, isNot(same(originalDisplay)));
        expect(replacedLyrics.displayLyrics.single.text, 'updated original');

        final selectedTranslation = state.copyWith(showTranslated: true);
        final translatedDisplay = selectedTranslation.displayLyrics;
        expect(translatedDisplay, isNot(same(originalDisplay)));
        expect(translatedDisplay.single.text, 'translated');

        final replacedTranslation = selectedTranslation.copyWith(
          translatedLyrics: _lyrics('updated translation'),
        );
        expect(
          replacedTranslation.displayLyrics,
          isNot(same(translatedDisplay)),
        );
        expect(
          replacedTranslation.displayLyrics.single.text,
          'updated translation',
        );

        final unselectedOriginalUpdate = selectedTranslation.copyWith(
          lyrics: _lyrics('new unselected original'),
        );
        expect(unselectedOriginalUpdate.displayLyrics, same(translatedDisplay));

        final switchedBack = selectedTranslation.copyWith(
          showTranslated: false,
        );
        expect(switchedBack.displayLyrics, isNot(same(translatedDisplay)));
        expect(switchedBack.displayLyrics.single.text, 'original');
      },
    );

    test(
      'applies positive, negative, and zero offsets with one current cache',
      () {
        final lyrics = _lyrics('original');
        final zeroOffsetState = LyricState(lyrics: lyrics);
        expect(zeroOffsetState.displayLyrics, same(lyrics));

        final positiveOffsetState = zeroOffsetState.copyWith(
          timelineOffset: const Duration(seconds: 2),
        );
        final positiveDisplay = positiveOffsetState.displayLyrics;
        expect(positiveDisplay, isNot(same(lyrics)));
        expect(positiveDisplay.single.startTime, const Duration(seconds: 3));
        expect(positiveDisplay.single.endTime, const Duration(seconds: 4));

        final negativeOffsetState = positiveOffsetState.copyWith(
          timelineOffset: const Duration(seconds: -1),
        );
        final negativeDisplay = negativeOffsetState.displayLyrics;
        expect(negativeDisplay, isNot(same(positiveDisplay)));
        expect(negativeDisplay.single.startTime, Duration.zero);
        expect(negativeDisplay.single.endTime, const Duration(seconds: 1));

        final returnedToPositiveOffset = negativeOffsetState.copyWith(
          timelineOffset: const Duration(seconds: 2),
        );
        final returnedDisplay = returnedToPositiveOffset.displayLyrics;
        expect(returnedDisplay, isNot(same(positiveDisplay)));
        expect(returnedDisplay.single.startTime, const Duration(seconds: 3));
        expect(returnedDisplay.single.endTime, const Duration(seconds: 4));

        final returnedToZeroOffset = returnedToPositiveOffset.copyWith(
          timelineOffset: Duration.zero,
        );
        expect(returnedToZeroOffset.displayLyrics, same(lyrics));
      },
    );

    test(
      'translation selection falls back to original when no translation exists',
      () {
        final state = LyricState(
          lyrics: _lyrics('original'),
          timelineOffset: const Duration(seconds: 2),
        );
        final originalDisplay = state.displayLyrics;

        final selectedWithoutTranslation = state.copyWith(showTranslated: true);
        final fallbackDisplay = selectedWithoutTranslation.displayLyrics;
        expect(fallbackDisplay, isNot(same(originalDisplay)));
        expect(fallbackDisplay.single.text, 'original');
        expect(fallbackDisplay.single.startTime, const Duration(seconds: 3));

        final switchedBack = selectedWithoutTranslation.copyWith(
          showTranslated: false,
        );
        expect(switchedBack.displayLyrics, isNot(same(fallbackDisplay)));
        expect(switchedBack.displayLyrics.single.text, 'original');
      },
    );

    test(
      'an uncomputed state copy and a new or cleared state stay independent',
      () {
        final uncomputed = LyricState(
          lyrics: _lyrics('before replacement'),
          timelineOffset: const Duration(seconds: 2),
        );
        final copiedBeforeRead = uncomputed.copyWith(
          lyrics: _lyrics('after replacement'),
        );
        final copiedDisplay = copiedBeforeRead.displayLyrics;
        expect(copiedDisplay.single.text, 'after replacement');
        expect(copiedDisplay.single.startTime, const Duration(seconds: 3));
        expect(copiedBeforeRead.displayLyrics, same(copiedDisplay));

        final cleared = copiedBeforeRead.copyWith(lyrics: const []);
        expect(cleared.displayLyrics, isEmpty);
        expect(cleared.displayLyrics, same(cleared.displayLyrics));

        final newState = LyricState(
          lyrics: _lyrics('new source'),
          timelineOffset: const Duration(seconds: 2),
        );
        final newDisplay = newState.displayLyrics;
        expect(newDisplay, isNot(same(copiedDisplay)));
        expect(newDisplay.single.text, 'new source');
      },
    );
  });
}

List<LyricLine> _lyrics(String text) => [
  LyricLine(
    startTime: const Duration(seconds: 1),
    endTime: const Duration(seconds: 2),
    text: text,
  ),
];

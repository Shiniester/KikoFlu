import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/audio_variant_selection.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/services/subtitle_matching.dart';

void main() {
  test('audio name comparison reuses subtitle normalization', () {
    final result = SubtitleMatcher.checkAudioNames(
      '０１　Narration（SEあり）.WAV',
      '01 Narration (SEなし).mp3',
    );

    expect(result.isMatch, isTrue);
    expect(
      SubtitleMatcher.checkAudioNames(
        'unrelated voice track.mp3',
        'outdoor ambience.mp3',
      ).isMatch,
      isFalse,
    );
  });

  test('generation recommendation follows format, traits, size, and path', () {
    final target = _variant(
      title: '01 narration track.wav',
      path: '01/narration track.wav',
      format: AudioFormat.wav,
      se: PlayerBinaryTrait.present,
      ejaculation: PlayerBinaryTrait.present,
      size: 10,
    );
    final wavWithoutEffects = _variant(
      title: '01 narration track (no effects).wav',
      path: '02/narration track.wav',
      format: AudioFormat.wav,
      se: PlayerBinaryTrait.absent,
      ejaculation: PlayerBinaryTrait.absent,
      size: 1,
    );
    final mp3WithEffects = _variant(
      title: '01 narration track (mix one).mp3',
      path: '03/narration track.mp3',
      se: PlayerBinaryTrait.present,
      ejaculation: PlayerBinaryTrait.present,
      size: 1,
    );
    final mp3WithoutSe = _variant(
      title: '01 narration track (mix two).mp3',
      path: '04/narration track.mp3',
      se: PlayerBinaryTrait.absent,
      ejaculation: PlayerBinaryTrait.present,
      size: 1,
    );
    final large = _variant(
      title: '01 narration track (mix three).mp3',
      path: 'a/narration track.mp3',
      se: PlayerBinaryTrait.absent,
      ejaculation: PlayerBinaryTrait.absent,
      size: 200,
    );
    final smallerZ = _variant(
      title: '01 narration track (mix four).mp3',
      path: 'z/narration track.mp3',
      se: PlayerBinaryTrait.absent,
      ejaculation: PlayerBinaryTrait.absent,
      size: 100,
    );
    final smallerM = _variant(
      title: '01 narration track (mix five).mp3',
      path: 'm/narration track.mp3',
      se: PlayerBinaryTrait.absent,
      ejaculation: PlayerBinaryTrait.absent,
      size: 100,
    );
    final unknownSize = _variant(
      title: '01 narration track (mix six).mp3',
      path: '0/narration track.mp3',
      se: PlayerBinaryTrait.absent,
      ejaculation: PlayerBinaryTrait.absent,
    );
    final variants = [
      target,
      wavWithoutEffects,
      mp3WithEffects,
      mp3WithoutSe,
      large,
      smallerZ,
      smallerM,
      unknownSize,
    ];

    final recommendation = AudioVariantSelectionService.recommendFor(
      target: target,
      allVariants: variants,
      purpose: AudioVariantSelectionPurpose.subtitleGeneration,
    );

    expect(recommendation, same(smallerM));
  });

  test('different leading track numbers are listed but not recommended', () {
    final target = _variant(
      title: '01 long narration sample track.wav',
      path: '01/track.wav',
      format: AudioFormat.wav,
      se: PlayerBinaryTrait.present,
    );
    final otherTrack = _variant(
      title: '02 long narration sample track.mp3',
      path: '02/track.mp3',
      se: PlayerBinaryTrait.absent,
      ejaculation: PlayerBinaryTrait.absent,
    );

    expect(
      AudioVariantSelectionService.candidatesFor(
        target: target,
        allVariants: [otherTrack],
        purpose: AudioVariantSelectionPurpose.subtitleGeneration,
      ),
      contains(otherTrack),
    );
    expect(
      AudioVariantSelectionService.recommendFor(
        target: target,
        allVariants: [otherTrack],
        purpose: AudioVariantSelectionPurpose.subtitleGeneration,
      ),
      same(target),
    );
    expect(
      AudioVariantSelectionService.recommendFor(
        target: target,
        allVariants: [otherTrack],
        purpose: AudioVariantSelectionPurpose.download,
      ),
      same(target),
    );
  });

  test('download recommendation follows the saved audio preference', () {
    final target = _variant(
      title: '01 long narration sample track.wav',
      path: '01/track.wav',
      format: AudioFormat.wav,
      subtitleLanguage: PlayerSubtitleLanguage.traditionalChinese,
      se: PlayerBinaryTrait.present,
      ejaculation: PlayerBinaryTrait.present,
    );
    final preferred = _variant(
      title: '01 long narration sample track (preferred).mp3',
      path: '02/track.mp3',
      subtitleLanguage: PlayerSubtitleLanguage.simplifiedChinese,
      se: PlayerBinaryTrait.absent,
      ejaculation: PlayerBinaryTrait.absent,
    );
    const preference = AudioFormatPreference(
      priority: [AudioFormat.mp3, AudioFormat.wav],
      subtitleLanguage: PlayerSubtitleLanguage.simplifiedChinese,
      se: PlayerBinaryTrait.absent,
      ejaculation: PlayerBinaryTrait.absent,
    );

    expect(
      AudioVariantSelectionService.recommendFor(
        target: target,
        allVariants: [target, preferred],
        purpose: AudioVariantSelectionPurpose.download,
        preference: preference,
      ),
      same(preferred),
    );
  });

  test(
    'similar candidates keep the target and show-all includes other tracks',
    () {
      final target = _variant(
        title: '01 narration sample.mp3',
        path: '01/narration.mp3',
      );
      final other = _variant(
        title: 'field recording of rain.wav',
        path: 'other/rain.wav',
        format: AudioFormat.wav,
      );

      final similar = AudioVariantSelectionService.candidatesFor(
        target: target,
        allVariants: [other],
        purpose: AudioVariantSelectionPurpose.download,
      );
      final all = AudioVariantSelectionService.candidatesFor(
        target: target,
        allVariants: [other],
        purpose: AudioVariantSelectionPurpose.download,
        showAll: true,
      );

      expect(similar, [target]);
      expect(all, containsAll([target, other]));
    },
  );
}

PlayerAudioVariant _variant({
  required String title,
  required String path,
  AudioFormat format = AudioFormat.mp3,
  PlayerSubtitleLanguage subtitleLanguage = PlayerSubtitleLanguage.other,
  PlayerBinaryTrait se = PlayerBinaryTrait.unknown,
  PlayerBinaryTrait ejaculation = PlayerBinaryTrait.unknown,
  int? size,
}) => PlayerAudioVariant(
  source: {'size': size},
  title: title,
  parentPath: path,
  fullPath: path,
  format: format,
  subtitleLanguage: subtitleLanguage,
  se: se,
  ejaculation: ejaculation,
);

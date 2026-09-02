import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';

void main() {
  const classifier = PlayerAudioVariantClassifier();

  test(
    'default selection follows language, format, SE and ejaculation order',
    () {
      final variants = classifier.scan([
        _folder('繁中_wav_有SE_射精音', [
          _audio('track.wav', 'traditional-wav'),
          _subtitle('track_繁中.vtt'),
        ]),
        _folder('简中_mp3_无SE_无射精', [
          _audio('track.mp3', 'simplified-mp3'),
          _subtitle('track_简中.vtt'),
        ]),
      ]);

      final best = classifier.selectBest(variants);

      expect(best, hasLength(1));
      expect(best.single.title, 'track.mp3');
      expect(
        best.single.subtitleLanguage,
        PlayerSubtitleLanguage.simplifiedChinese,
      );
    },
  );

  test('negative words win before positive keyword fragments', () {
    final variant = classifier.scan([
      _folder('无SE_射精なし', [_audio('track.flac', 'negative')]),
    ]).single;

    expect(variant.se, PlayerBinaryTrait.absent);
    expect(variant.ejaculation, PlayerBinaryTrait.absent);
  });

  test('unmarked regular files default to effects and ejaculation present', () {
    final variants = classifier.scan([
      _folder('简中_有SE_射精音', [
        _audio('01.wav', 'known'),
        _subtitle('01_简中.lrc'),
      ]),
      _folder('简中', [_audio('02.wav', 'unknown'), _subtitle('02_简中.lrc')]),
    ]);

    final best = classifier.selectBest(variants);

    expect(variants.last.se, PlayerBinaryTrait.present);
    expect(variants.last.ejaculation, PlayerBinaryTrait.present);
    expect(
      best.map((variant) => variant.title),
      containsAll(['01.wav', '02.wav']),
    );
  });

  test('work title language is inherited by audio files without markers', () {
    final simplified = classifier.scan([
      _folder('audio', [_audio('01.wav', 'simplified')]),
    ], workTitle: 'RJ100 简体中文版本');
    final traditional = classifier.scan([
      _folder('audio', [_audio('01.flac', 'traditional')]),
    ], workTitle: 'RJ200 繁體中文版本');

    expect(
      simplified.single.subtitleLanguage,
      PlayerSubtitleLanguage.simplifiedChinese,
    );
    expect(
      traditional.single.subtitleLanguage,
      PlayerSubtitleLanguage.traditionalChinese,
    );
  });

  test('manual filters keep unknown values when requested', () {
    final variants = <PlayerAudioVariant>[
      const PlayerAudioVariant(
        source: <String, dynamic>{'type': 'audio'},
        title: '01.flac',
        parentPath: '简中',
        fullPath: '简中/01.flac',
        format: PlayerAudioFormat.flac,
        subtitleLanguage: PlayerSubtitleLanguage.simplifiedChinese,
        se: PlayerBinaryTrait.unknown,
        ejaculation: PlayerBinaryTrait.unknown,
      ),
      const PlayerAudioVariant(
        source: <String, dynamic>{'type': 'audio'},
        title: '02.flac',
        parentPath: '简中_无SE',
        fullPath: '简中_无SE/02.flac',
        format: PlayerAudioFormat.flac,
        subtitleLanguage: PlayerSubtitleLanguage.simplifiedChinese,
        se: PlayerBinaryTrait.absent,
        ejaculation: PlayerBinaryTrait.present,
      ),
    ];

    final withUnknown = classifier.applyFilter(
      variants,
      const PlayerAudioVariantFilter(
        formats: {PlayerAudioFormat.flac},
        seValues: {PlayerBinaryTrait.absent},
      ),
    );
    final withoutUnknown = classifier.applyFilter(
      variants,
      const PlayerAudioVariantFilter(
        formats: {PlayerAudioFormat.flac},
        seValues: {PlayerBinaryTrait.absent},
        includeUnknown: false,
      ),
    );

    expect(withUnknown, hasLength(2));
    expect(withoutUnknown.map((variant) => variant.title), ['02.flac']);
  });

  test('keyword and show-all filtering do not rescan the tree', () {
    final variants = classifier.scan([
      _folder('disc_a', [_audio('alpha.wav', 'a')]),
      _folder('disc_b', [_audio('beta.mp3', 'b')]),
    ]);

    final result = classifier.applyFilter(
      variants,
      const PlayerAudioVariantFilter(showAll: true, keyword: 'disc_b'),
    );

    expect(result.single.title, 'beta.mp3');
  });
}

Map<String, dynamic> _folder(
  String title,
  List<Map<String, dynamic>> children,
) {
  return {'type': 'folder', 'title': title, 'children': children};
}

Map<String, dynamic> _audio(String title, String hash) {
  return {'type': 'audio', 'title': title, 'hash': hash};
}

Map<String, dynamic> _subtitle(String title) {
  return {'type': 'text', 'title': title, 'hash': 'subtitle-$title'};
}

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

  test(
    'saved language, format and trait preferences select one real combination',
    () {
      final variants = classifier.scan([
        _folder('简中_有SE_射精音', [
          _audio('track.wav', 'simplified-wav'),
          _subtitle('track_简中.lrc'),
        ]),
        _folder('繁中_无SE_无射精', [
          _audio('track.wav', 'traditional-wav'),
          _audio('track.mp3', 'traditional-mp3'),
          _subtitle('track_繁中.lrc'),
        ]),
      ]);
      const preference = AudioFormatPreference(
        priority: [AudioFormat.mp3, AudioFormat.wav],
        subtitleLanguage: PlayerSubtitleLanguage.traditionalChinese,
        se: PlayerBinaryTrait.absent,
        ejaculation: PlayerBinaryTrait.absent,
      );

      final best = classifier.selectBest(variants, preference: preference);
      final defaults = classifier.defaultFilter(
        variants,
        preference: preference,
      );
      expect(best.single.source['hash'], 'traditional-mp3');
      expect(defaults.subtitleLanguages, {
        PlayerSubtitleLanguage.traditionalChinese,
      });
      expect(defaults.formats, {AudioFormat.mp3});
      expect(defaults.seValues, {PlayerBinaryTrait.absent});
      expect(defaults.ejaculationValues, {PlayerBinaryTrait.absent});
      expect(
        classifier.applyFilter(variants, defaults, preference: preference),
        best,
      );
    },
  );

  test('default filter highlights the actual fallback combination', () {
    final variants = classifier.scan([
      _folder('繁中', [_audio('track.wav', 'wav'), _subtitle('track_繁中.lrc')]),
      _folder('简中', [_audio('track.mp3', 'mp3'), _subtitle('track_简中.lrc')]),
    ]);

    final defaults = classifier.defaultFilter(variants);
    expect(defaults.subtitleLanguages, {
      PlayerSubtitleLanguage.simplifiedChinese,
    });
    expect(defaults.formats, {AudioFormat.mp3});
    expect(
      classifier.applyFilter(variants, defaults).single.source['hash'],
      'mp3',
    );
  });

  test('all saved audio formats are classified and can be preferred', () {
    final variants = classifier.scan([
      for (final format in AudioFormat.values.where(
        (value) => value != AudioFormat.other,
      ))
        _audio('track.${format.extension}', format.extension),
    ]);
    expect(
      variants.map((variant) => variant.format).toSet(),
      AudioFormat.values.toSet()..remove(AudioFormat.other),
    );

    for (final format in AudioFormat.values.where(
      (value) => value != AudioFormat.other,
    )) {
      final defaults = classifier.defaultFilter(
        variants,
        preference: AudioFormatPreference(priority: [format]),
      );
      expect(defaults.formats, {format});
      expect(classifier.applyFilter(variants, defaults).single.format, format);
    }
  });

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

  test('work title language only fills in matched subtitle language', () {
    final simplified = classifier.scan([
      _folder('audio', [
        _audio('01.wav', 'simplified'),
        _subtitle('01.lrc'),
        _audio('02.wav', 'no-subtitle'),
      ]),
    ], workTitle: 'RJ100 简体中文版本');
    final traditional = classifier.scan([
      _folder('audio', [_audio('01.flac', 'traditional'), _subtitle('01.lrc')]),
    ], workTitle: 'RJ200 繁體中文版本');

    expect(
      simplified.first.subtitleLanguage,
      PlayerSubtitleLanguage.simplifiedChinese,
    );
    expect(simplified.last.title, '02.wav');
    expect(simplified.last.subtitleLanguage, PlayerSubtitleLanguage.none);
    expect(
      classifier
          .applyFilter(
            simplified,
            const PlayerAudioVariantFilter(
              subtitleLanguages: {PlayerSubtitleLanguage.simplifiedChinese},
            ),
          )
          .map((variant) => variant.title),
      ['01.wav'],
    );
    expect(
      traditional.single.subtitleLanguage,
      PlayerSubtitleLanguage.traditionalChinese,
    );
  });

  test('subtitle language markers take precedence over the work title', () {
    final variants = classifier.scan([
      _audio('01.wav', 'traditional'),
      _subtitle('01_繁中.lrc'),
      _audio('02.wav', 'mixed'),
      _subtitle('02_简中.lrc'),
      _subtitle('02_繁中.lrc'),
    ], workTitle: 'RJ100 简体中文版本');

    expect(
      variants.first.subtitleLanguage,
      PlayerSubtitleLanguage.traditionalChinese,
    );
    expect(variants.last.subtitleLanguage, PlayerSubtitleLanguage.unknown);
  });

  test(
    'traditional-script simplified markers override a traditional title',
    () {
      final variants = classifier.scan([
        _audio('01.wav', 'long-marker'),
        _subtitle('01_簡體中文.lrc'),
        _audio('02.wav', 'short-marker'),
        _subtitle('02_簡體.lrc'),
      ], workTitle: 'RJ100 繁體中文版本');

      expect(variants, hasLength(2));
      for (final variant in variants) {
        expect(
          variant.subtitleLanguage,
          PlayerSubtitleLanguage.simplifiedChinese,
        );
        expect(variant.subtitleSources, hasLength(1));
      }
    },
  );

  test('long language markers match short audio names', () {
    final variants = classifier.scan([
      _audio('01.wav', 'traditional'),
      _subtitle('01_繁体中文.lrc'),
      _audio('02.wav', 'simplified'),
      _subtitle('02_簡体中文.lrc'),
    ]);

    expect(variants.first.title, '02.wav');
    expect(
      variants.first.subtitleLanguage,
      PlayerSubtitleLanguage.simplifiedChinese,
    );
    expect(
      variants.last.subtitleLanguage,
      PlayerSubtitleLanguage.traditionalChinese,
    );
    expect(
      variants.every((variant) => variant.subtitleSources.length == 1),
      isTrue,
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
    for (final filter in const [
      PlayerAudioVariantFilter(includeUnknown: false),
      PlayerAudioVariantFilter(
        formats: {PlayerAudioFormat.flac},
        includeUnknown: false,
      ),
    ]) {
      expect(
        classifier
            .applyFilter(variants, filter)
            .map((variant) => variant.title),
        ['02.flac'],
      );
    }
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

  test('filtering sorts unsorted input without modifying it', () {
    final variants = classifier
        .scan([
          _audio('z.wav', 'z'),
          _audio('a.wav', 'a'),
          _audio('b.mp3', 'b'),
        ])
        .reversed
        .toList();
    final original = variants.toList();

    for (final filter in const [
      PlayerAudioVariantFilter(),
      PlayerAudioVariantFilter(formats: {PlayerAudioFormat.wav}),
      PlayerAudioVariantFilter(showAll: true),
    ]) {
      expect(
        classifier
            .applyFilter(variants, filter)
            .map((variant) => variant.title),
        filter.showAll ? ['a.wav', 'z.wav', 'b.mp3'] : ['a.wav', 'z.wav'],
      );
      expect(variants, orderedEquals(original));
    }
  });

  test('prepared matching keeps fuzzy names and directory boundaries', () {
    final variants = classifier.scan([
      _folder('简中', [
        _audio('a_long_track_title.wav', 'fuzzy'),
        _subtitle('a_long_track_titl.lrc'),
        _audio('02.wav', 'full-width'),
        _subtitle('０２_CHS.lrc'),
        _audio('03.wav', 'no-subtitle'),
      ]),
      _folder('other', [_subtitle('03_简中.lrc')]),
    ]);

    final fuzzy = variants.singleWhere(
      (variant) => variant.source['hash'] == 'fuzzy',
    );
    final fullWidth = variants.singleWhere(
      (variant) => variant.source['hash'] == 'full-width',
    );
    final withoutSubtitle = variants.singleWhere(
      (variant) => variant.source['hash'] == 'no-subtitle',
    );
    expect(fuzzy.subtitleSources, hasLength(1));
    expect(fullWidth.subtitleSources, hasLength(1));
    expect(withoutSubtitle.subtitleLanguage, PlayerSubtitleLanguage.none);
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

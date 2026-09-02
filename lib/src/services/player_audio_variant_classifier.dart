import '../services/subtitle_matching.dart';
import '../utils/file_tree_utils.dart';

/// Subtitle language inferred from the existing file tree only.
enum PlayerSubtitleLanguage {
  simplifiedChinese,
  traditionalChinese,
  other,
  none,
  unknown,
}

enum PlayerAudioFormat { wav, flac, mp3, other }

enum PlayerBinaryTrait { present, absent, unknown }

class PlayerAudioVariant {
  const PlayerAudioVariant({
    required this.source,
    required this.title,
    required this.parentPath,
    required this.fullPath,
    required this.format,
    required this.subtitleLanguage,
    required this.se,
    required this.ejaculation,
    this.subtitleSources = const [],
  });

  final dynamic source;
  final String title;
  final String parentPath;
  final String fullPath;
  final PlayerAudioFormat format;
  final PlayerSubtitleLanguage subtitleLanguage;
  final PlayerBinaryTrait se;
  final PlayerBinaryTrait ejaculation;
  final List<dynamic> subtitleSources;
}

class PlayerAudioVariantFilter {
  const PlayerAudioVariantFilter({
    this.subtitleLanguages = const {},
    this.formats = const {},
    this.seValues = const {},
    this.ejaculationValues = const {},
    this.includeUnknown = true,
    this.showAll = false,
    this.keyword = '',
  });

  final Set<PlayerSubtitleLanguage> subtitleLanguages;
  final Set<PlayerAudioFormat> formats;
  final Set<PlayerBinaryTrait> seValues;
  final Set<PlayerBinaryTrait> ejaculationValues;
  final bool includeUnknown;
  final bool showAll;
  final String keyword;

  PlayerAudioVariantFilter copyWith({
    Set<PlayerSubtitleLanguage>? subtitleLanguages,
    Set<PlayerAudioFormat>? formats,
    Set<PlayerBinaryTrait>? seValues,
    Set<PlayerBinaryTrait>? ejaculationValues,
    bool? includeUnknown,
    bool? showAll,
    String? keyword,
  }) {
    return PlayerAudioVariantFilter(
      subtitleLanguages: subtitleLanguages ?? this.subtitleLanguages,
      formats: formats ?? this.formats,
      seValues: seValues ?? this.seValues,
      ejaculationValues: ejaculationValues ?? this.ejaculationValues,
      includeUnknown: includeUnknown ?? this.includeUnknown,
      showAll: showAll ?? this.showAll,
      keyword: keyword ?? this.keyword,
    );
  }
}

class PlayerAudioVariantClassifier {
  const PlayerAudioVariantClassifier();

  List<PlayerAudioVariant> scan(
    List<dynamic> fileTree, {
    String workTitle = '',
  }) {
    final entries = <_TreeEntry>[];
    _flatten(fileTree, '', entries);
    final inheritedLanguage = inferWorkTitleLanguage(workTitle);
    final subtitlesByParent = <String, List<_TreeEntry>>{};
    for (final entry in entries.where(
      (entry) => FileTreeUtils.isText(entry.source),
    )) {
      subtitlesByParent.putIfAbsent(entry.parentPath, () => []).add(entry);
    }

    final variants = <PlayerAudioVariant>[];
    for (final entry in entries.where(
      (entry) => FileTreeUtils.isAudio(entry.source),
    )) {
      final subtitles =
          (subtitlesByParent[entry.parentPath] ?? const <_TreeEntry>[])
              .where(
                (subtitle) => _subtitleMatches(subtitle.title, entry.title),
              )
              .toList(growable: false);
      final traitText = _normalize('${entry.parentPath}/${entry.title}');
      variants.add(
        PlayerAudioVariant(
          source: entry.source,
          title: entry.title,
          parentPath: entry.parentPath,
          fullPath: entry.fullPath,
          format: _formatOf(entry.title),
          subtitleLanguage: switch (inheritedLanguage) {
            PlayerSubtitleLanguage.simplifiedChinese =>
              PlayerSubtitleLanguage.simplifiedChinese,
            PlayerSubtitleLanguage.traditionalChinese =>
              PlayerSubtitleLanguage.traditionalChinese,
            _ => _subtitleLanguageOf(subtitles),
          },
          se: _seOf(traitText),
          ejaculation: _ejaculationOf(traitText),
          subtitleSources: subtitles
              .map<dynamic>((subtitle) => subtitle.source)
              .toList(growable: false),
        ),
      );
    }
    variants.sort(_compare);
    return List.unmodifiable(variants);
  }

  /// A language marker on the work title applies to every audio file in the
  /// work, even when the individual path and file name omit that marker.
  PlayerSubtitleLanguage inferWorkTitleLanguage(String title) {
    final text = _normalize(title);
    final simplified = _containsAny(text, const [
      '简体中文',
      '簡體中文',
      '简体',
      '簡体',
      '简中',
      '簡中',
      'chs',
      'zh-cn',
      'zh_hans',
      'zhs',
    ]);
    final traditional = _containsAny(text, const [
      '繁体中文',
      '繁體中文',
      '繁体',
      '繁體',
      '繁中',
      'cht',
      'zh-tw',
      'zh_hant',
      'zht',
    ]);
    if (simplified && traditional) return PlayerSubtitleLanguage.unknown;
    if (simplified) return PlayerSubtitleLanguage.simplifiedChinese;
    if (traditional) return PlayerSubtitleLanguage.traditionalChinese;
    return PlayerSubtitleLanguage.unknown;
  }

  /// Returns the best real combination, while allowing unknown values to act
  /// as wildcards. This guarantees that a sparse/crossed directory layout
  /// still yields at least one playable result.
  List<PlayerAudioVariant> selectBest(List<PlayerAudioVariant> variants) {
    if (variants.isEmpty) return const [];
    final sorted = List<PlayerAudioVariant>.of(variants)..sort(_compare);
    final best = sorted.first;

    final hasKnownLanguage = variants.any(
      (variant) => variant.subtitleLanguage != PlayerSubtitleLanguage.unknown,
    );
    final hasKnownSe = variants.any(
      (variant) => variant.se != PlayerBinaryTrait.unknown,
    );
    final hasKnownEjaculation = variants.any(
      (variant) => variant.ejaculation != PlayerBinaryTrait.unknown,
    );

    final result = sorted
        .where((variant) {
          final languageMatches =
              !hasKnownLanguage ||
              best.subtitleLanguage == PlayerSubtitleLanguage.unknown ||
              variant.subtitleLanguage == PlayerSubtitleLanguage.unknown ||
              variant.subtitleLanguage == best.subtitleLanguage;
          final seMatches =
              !hasKnownSe ||
              best.se == PlayerBinaryTrait.unknown ||
              variant.se == PlayerBinaryTrait.unknown ||
              variant.se == best.se;
          final ejaculationMatches =
              !hasKnownEjaculation ||
              best.ejaculation == PlayerBinaryTrait.unknown ||
              variant.ejaculation == PlayerBinaryTrait.unknown ||
              variant.ejaculation == best.ejaculation;
          return languageMatches &&
              variant.format == best.format &&
              seMatches &&
              ejaculationMatches;
        })
        .toList(growable: false);
    return result.isEmpty ? <PlayerAudioVariant>[best] : result;
  }

  List<PlayerAudioVariant> applyFilter(
    List<PlayerAudioVariant> variants,
    PlayerAudioVariantFilter filter,
  ) {
    final keyword = _normalize(filter.keyword).trim();
    final source = filter.showAll
        ? variants
        : _filterByDimensions(variants, filter);
    final result =
        source
            .where((variant) {
              return keyword.isEmpty ||
                  _normalize(variant.fullPath).contains(keyword);
            })
            .toList(growable: false)
          ..sort(_compare);
    return result;
  }

  Iterable<PlayerAudioVariant> _filterByDimensions(
    List<PlayerAudioVariant> variants,
    PlayerAudioVariantFilter filter,
  ) {
    if (filter.subtitleLanguages.isEmpty &&
        filter.formats.isEmpty &&
        filter.seValues.isEmpty &&
        filter.ejaculationValues.isEmpty) {
      return selectBest(variants);
    }
    return variants.where((variant) {
      return _matchesLanguage(variant.subtitleLanguage, filter) &&
          (filter.formats.isEmpty || filter.formats.contains(variant.format)) &&
          _matchesTrait(variant.se, filter.seValues, filter.includeUnknown) &&
          _matchesTrait(
            variant.ejaculation,
            filter.ejaculationValues,
            filter.includeUnknown,
          );
    });
  }

  bool _matchesLanguage(
    PlayerSubtitleLanguage value,
    PlayerAudioVariantFilter filter,
  ) {
    if (filter.subtitleLanguages.isEmpty) return true;
    if (value == PlayerSubtitleLanguage.unknown) return filter.includeUnknown;
    return filter.subtitleLanguages.contains(value);
  }

  bool _matchesTrait(
    PlayerBinaryTrait value,
    Set<PlayerBinaryTrait> selected,
    bool includeUnknown,
  ) {
    if (selected.isEmpty) return true;
    if (value == PlayerBinaryTrait.unknown) return includeUnknown;
    return selected.contains(value);
  }

  bool _subtitleMatches(String subtitleTitle, String audioTitle) {
    if (SubtitleMatcher.isSubtitleForAudio(subtitleTitle, audioTitle)) {
      return true;
    }
    var cleaned = subtitleTitle;
    for (final marker in const [
      '简体中文',
      '簡體中文',
      '繁體中文',
      '简体',
      '簡体',
      '繁体',
      '繁體',
      '简中',
      '簡中',
      '繁中',
      'chs',
      'cht',
      'zhs',
      'zht',
      'zh-cn',
      'zh-tw',
      'zh_hans',
      'zh_hant',
    ]) {
      cleaned = cleaned.replaceAll(RegExp(marker, caseSensitive: false), '');
    }
    cleaned = cleaned.replaceAll(RegExp(r'[_\-\s]+(?=\.[^.]+$)'), '');
    return SubtitleMatcher.isSubtitleForAudio(cleaned, audioTitle);
  }

  void _flatten(
    List<dynamic> items,
    String parentPath,
    List<_TreeEntry> output,
  ) {
    for (final item in items) {
      final title = FileTreeUtils.titleOf(item, defaultValue: 'unknown');
      final fullPath = parentPath.isEmpty ? title : '$parentPath/$title';
      if (FileTreeUtils.isFolder(item)) {
        final children = FileTreeUtils.childrenOf(item);
        if (children != null) _flatten(children, fullPath, output);
      } else {
        output.add(
          _TreeEntry(
            source: item,
            title: title,
            parentPath: parentPath,
            fullPath: fullPath,
          ),
        );
      }
    }
  }

  PlayerAudioFormat _formatOf(String title) {
    final lower = title.toLowerCase();
    if (lower.endsWith('.wav')) return PlayerAudioFormat.wav;
    if (lower.endsWith('.flac')) return PlayerAudioFormat.flac;
    if (lower.endsWith('.mp3')) return PlayerAudioFormat.mp3;
    return PlayerAudioFormat.other;
  }

  PlayerSubtitleLanguage _subtitleLanguageOf(List<_TreeEntry> subtitles) {
    if (subtitles.isEmpty) return PlayerSubtitleLanguage.none;
    final text = _normalize(subtitles.map((entry) => entry.fullPath).join(' '));
    final simplified = _containsAny(text, const [
      '简体',
      '簡体',
      '简中',
      '簡中',
      '简体中文',
      'chs',
      'zh-cn',
      'zh_hans',
      'zhs',
    ]);
    final traditional = _containsAny(text, const [
      '繁体',
      '繁體',
      '繁中',
      '繁體中文',
      'cht',
      'zh-tw',
      'zh_hant',
      'zht',
    ]);
    if (simplified && traditional) return PlayerSubtitleLanguage.unknown;
    if (simplified) return PlayerSubtitleLanguage.simplifiedChinese;
    if (traditional) return PlayerSubtitleLanguage.traditionalChinese;
    return PlayerSubtitleLanguage.other;
  }

  PlayerBinaryTrait _seOf(String text) {
    if (_containsAny(text, const [
      '无se',
      '無se',
      'seなし',
      'se無し',
      'no se',
      'nose',
      'se_off',
      'without se',
      '无音效',
      '無音效',
      '无效果音',
      '無效果音',
      'no sound effect',
    ])) {
      return PlayerBinaryTrait.absent;
    }
    if (_containsAny(text, const [
      '有se',
      'seあり',
      'se有り',
      'with se',
      '音效',
      '効果音',
    ])) {
      return PlayerBinaryTrait.present;
    }
    // Most releases only mark the exceptional "no effects" variant. An
    // unmarked path therefore belongs to the regular, effects-present mix.
    return PlayerBinaryTrait.present;
  }

  PlayerBinaryTrait _ejaculationOf(String text) {
    if (_containsAny(text, const [
      '无射精',
      '無射精',
      '射精なし',
      'no ejaculation',
      'without orgasm',
      '无绝顶',
      '無絶頂',
    ])) {
      return PlayerBinaryTrait.absent;
    }
    if (_containsAny(text, const [
      '射精音',
      '射精',
      '絶頂',
      '绝顶',
      'orgasm',
      'ejaculation',
      '中出し',
      '中出',
    ])) {
      return PlayerBinaryTrait.present;
    }
    // The same convention is used for climax/ejaculation variants: an
    // explicit negative marker opts out, while an unmarked file is regular.
    return PlayerBinaryTrait.present;
  }

  bool _containsAny(String text, List<String> needles) {
    return needles.any((needle) => text.contains(needle));
  }

  String _normalize(String value) {
    return String.fromCharCodes(
      value.toLowerCase().runes.map((codePoint) {
        if (codePoint == 0x3000) return 0x20;
        if (codePoint >= 0xFF01 && codePoint <= 0xFF5E) {
          return codePoint - 0xFEE0;
        }
        return codePoint;
      }),
    ).replaceAll('\\', '/');
  }

  int _compare(PlayerAudioVariant a, PlayerAudioVariant b) {
    final ranksA = <int>[
      _languageRank(a.subtitleLanguage),
      _formatRank(a.format),
      _traitRank(a.se),
      _traitRank(a.ejaculation),
    ];
    final ranksB = <int>[
      _languageRank(b.subtitleLanguage),
      _formatRank(b.format),
      _traitRank(b.se),
      _traitRank(b.ejaculation),
    ];
    for (var index = 0; index < ranksA.length; index++) {
      final compared = ranksA[index].compareTo(ranksB[index]);
      if (compared != 0) return compared;
    }
    return a.fullPath.toLowerCase().compareTo(b.fullPath.toLowerCase());
  }

  int _languageRank(PlayerSubtitleLanguage value) => switch (value) {
    PlayerSubtitleLanguage.simplifiedChinese => 0,
    PlayerSubtitleLanguage.traditionalChinese => 1,
    PlayerSubtitleLanguage.other => 2,
    PlayerSubtitleLanguage.none => 3,
    PlayerSubtitleLanguage.unknown => 4,
  };

  int _formatRank(PlayerAudioFormat value) => switch (value) {
    PlayerAudioFormat.wav => 0,
    PlayerAudioFormat.flac => 1,
    PlayerAudioFormat.mp3 => 2,
    PlayerAudioFormat.other => 3,
  };

  int _traitRank(PlayerBinaryTrait value) => switch (value) {
    PlayerBinaryTrait.present => 0,
    PlayerBinaryTrait.absent => 1,
    PlayerBinaryTrait.unknown => 2,
  };
}

class _TreeEntry {
  const _TreeEntry({
    required this.source,
    required this.title,
    required this.parentPath,
    required this.fullPath,
  });

  final dynamic source;
  final String title;
  final String parentPath;
  final String fullPath;
}

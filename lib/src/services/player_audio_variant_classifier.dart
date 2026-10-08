import '../models/audio_preference.dart';
import '../services/subtitle_matching.dart';
import '../utils/file_tree_utils.dart';

export '../models/audio_preference.dart';

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
    final subtitlesByParent = <String, List<_PreparedSubtitle>>{};
    for (final entry in entries.where(
      (entry) => FileTreeUtils.isText(entry.source),
    )) {
      subtitlesByParent.putIfAbsent(entry.parentPath, () => []).add((
        entry: entry,
        original: SubtitleMatcher.prepareSubtitle(entry.title),
        cleaned: _prepareSubtitleWithoutLanguage(entry.title),
      ));
    }

    final variants = <PlayerAudioVariant>[];
    for (final entry in entries.where(
      (entry) => FileTreeUtils.isAudio(entry.source),
    )) {
      final audioName = SubtitleMatcher.prepareAudio(entry.title);
      // ponytail: matching is quadratic per folder; index names if large folders dominate.
      final subtitles =
          (subtitlesByParent[entry.parentPath] ?? const <_PreparedSubtitle>[])
              .where(
                (subtitle) =>
                    SubtitleMatcher.checkPrepared(
                      subtitle.original,
                      audioName,
                    ).isMatch ||
                    SubtitleMatcher.checkPrepared(
                      subtitle.cleaned,
                      audioName,
                    ).isMatch,
              )
              .map((subtitle) => subtitle.entry)
              .toList(growable: false);
      final traitText = _normalize('${entry.parentPath}/${entry.title}');
      final subtitleLanguage = _subtitleLanguageOf(subtitles);
      variants.add(
        PlayerAudioVariant(
          source: entry.source,
          title: entry.title,
          parentPath: entry.parentPath,
          fullPath: entry.fullPath,
          format: _formatOf(entry.title),
          subtitleLanguage:
              subtitleLanguage == PlayerSubtitleLanguage.other &&
                  inheritedLanguage != PlayerSubtitleLanguage.unknown
              ? inheritedLanguage
              : subtitleLanguage,
          se: _seOf(traitText),
          ejaculation: _ejaculationOf(traitText),
          subtitleSources: subtitles
              .map<dynamic>((subtitle) => subtitle.source)
              .toList(growable: false),
        ),
      );
    }
    _sort(variants);
    return List.unmodifiable(variants);
  }

  /// A work title can supply the language of a matched, unmarked subtitle.
  PlayerSubtitleLanguage inferWorkTitleLanguage(String title) {
    final text = _normalize(title);
    final simplified = _containsAny(text, const [
      '简体中文',
      '簡體中文',
      '简体',
      '簡体',
      '簡體',
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
  /// as wildcards. A sparse/crossed directory layout still yields a result
  /// when at least one variant satisfies the unknown-attribute preference.
  List<PlayerAudioVariant> selectBest(
    List<PlayerAudioVariant> variants, {
    AudioFormatPreference preference = const AudioFormatPreference(),
  }) {
    final sorted = variants
        .where((variant) {
          return preference.includeUnknown ||
              (variant.subtitleLanguage != PlayerSubtitleLanguage.unknown &&
                  variant.se != PlayerBinaryTrait.unknown &&
                  variant.ejaculation != PlayerBinaryTrait.unknown);
        })
        .toList(growable: false);
    if (sorted.isEmpty) return const [];
    _sort(sorted, preference: preference);
    final best = sorted.first;

    final result = sorted
        .where((variant) {
          final languageMatches =
              best.subtitleLanguage == PlayerSubtitleLanguage.unknown ||
              variant.subtitleLanguage == PlayerSubtitleLanguage.unknown ||
              variant.subtitleLanguage == best.subtitleLanguage;
          final seMatches =
              best.se == PlayerBinaryTrait.unknown ||
              variant.se == PlayerBinaryTrait.unknown ||
              variant.se == best.se;
          final ejaculationMatches =
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

  PlayerAudioVariantFilter defaultFilter(
    List<PlayerAudioVariant> variants, {
    AudioFormatPreference preference = const AudioFormatPreference(),
  }) {
    final best = selectBest(variants, preference: preference).firstOrNull;
    final language = best?.subtitleLanguage ?? preference.subtitleLanguage;
    final se = best?.se ?? preference.se;
    final ejaculation = best?.ejaculation ?? preference.ejaculation;
    return PlayerAudioVariantFilter(
      subtitleLanguages: language == PlayerSubtitleLanguage.unknown
          ? const {}
          : {language},
      formats: {best?.format ?? preference.priority.first},
      seValues: se == PlayerBinaryTrait.unknown ? const {} : {se},
      ejaculationValues: ejaculation == PlayerBinaryTrait.unknown
          ? const {}
          : {ejaculation},
      includeUnknown: preference.includeUnknown,
    );
  }

  Set<String> preferredExpandedPaths(
    List<PlayerAudioVariant> variants, {
    AudioFormatPreference preference = const AudioFormatPreference(),
  }) => {
    for (final variant in selectBest(variants, preference: preference))
      ...FileTreeUtils.expandedPathsFor(variant.parentPath),
  };

  List<PlayerAudioVariant> applyFilter(
    List<PlayerAudioVariant> variants,
    PlayerAudioVariantFilter filter, {
    AudioFormatPreference preference = const AudioFormatPreference(),
  }) {
    final keyword = _normalize(filter.keyword).trim();
    final source = filter.showAll
        ? variants
        : _filterByDimensions(variants, filter, preference);
    final result = source
        .where((variant) {
          return keyword.isEmpty ||
              _normalize(variant.fullPath).contains(keyword);
        })
        .toList(growable: false);
    _sort(result, preference: preference);
    return result;
  }

  Iterable<PlayerAudioVariant> _filterByDimensions(
    List<PlayerAudioVariant> variants,
    PlayerAudioVariantFilter filter,
    AudioFormatPreference preference,
  ) {
    if (filter.subtitleLanguages.isEmpty &&
        filter.formats.isEmpty &&
        filter.seValues.isEmpty &&
        filter.ejaculationValues.isEmpty) {
      return selectBest(
        variants,
        preference: preference.copyWith(includeUnknown: filter.includeUnknown),
      );
    }
    return variants.where((variant) {
      if (!filter.includeUnknown &&
          (variant.subtitleLanguage == PlayerSubtitleLanguage.unknown ||
              variant.se == PlayerBinaryTrait.unknown ||
              variant.ejaculation == PlayerBinaryTrait.unknown)) {
        return false;
      }
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

  PreparedSubtitleName? _prepareSubtitleWithoutLanguage(String subtitleTitle) {
    var cleaned = subtitleTitle;
    for (final marker in const [
      '简体中文',
      '簡體中文',
      '簡体中文',
      '繁体中文',
      '繁體中文',
      '简体',
      '簡体',
      '簡體',
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
    return SubtitleMatcher.prepareSubtitle(cleaned);
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
    for (final format in AudioFormat.values) {
      if (format != AudioFormat.other &&
          lower.endsWith('.${format.extension}')) {
        return format;
      }
    }
    return PlayerAudioFormat.other;
  }

  PlayerSubtitleLanguage _subtitleLanguageOf(List<_TreeEntry> subtitles) {
    if (subtitles.isEmpty) return PlayerSubtitleLanguage.none;
    final text = _normalize(subtitles.map((entry) => entry.fullPath).join(' '));
    final simplified = _containsAny(text, const [
      '简体',
      '簡体',
      '簡體',
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
      'secut',
      'se cut',
      'se-cut',
      'se_cut',
      'seカット',
      'seオフ',
      'no se',
      'nose',
      'se_off',
      'se off',
      'se-off',
      'seoff',
      'without se',
      '无音效',
      '無音效',
      '无效果音',
      '無效果音',
      '效果音剪辑',
      '效果音剪輯',
      '音效剪辑',
      '音效剪輯',
      '効果音なし',
      '効果音無し',
      '効果音カット',
      'no sound effect',
      'without sound effect',
      'no sfx',
      'without sfx',
    ])) {
      return PlayerBinaryTrait.absent;
    }
    if (_containsAny(text, const [
      '有se',
      'seあり',
      'se有り',
      'se on',
      'se付き',
      'with se',
      '音效',
      '効果音',
      'sound effect',
      'sfx',
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
      '射精無し',
      '射精音なし',
      '射精音無し',
      '射精カット',
      '射精音カット',
      '射精音剪辑',
      '射精音剪輯',
      'no ejaculation',
      'without ejaculation',
      'no orgasm',
      'without orgasm',
      '无绝顶',
      '無絶頂',
      '無絕頂',
      '絶頂なし',
      '絶頂無し',
      '无高潮',
      '無高潮',
    ])) {
      return PlayerBinaryTrait.absent;
    }
    if (_containsAny(text, const [
      '射精音',
      '射精',
      '絶頂',
      '绝顶',
      '絕頂',
      '高潮',
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

  int _compare(
    PlayerAudioVariant a,
    PlayerAudioVariant b, {
    AudioFormatPreference? preference,
  }) {
    int languageRank(PlayerSubtitleLanguage language) =>
        language == preference?.subtitleLanguage ? -1 : language.index;
    int formatRank(AudioFormat format) {
      if (preference == null) return format.index;
      final index = preference.priority.indexOf(format);
      return index < 0 ? preference.priority.length + format.index : index;
    }

    int traitRank(PlayerBinaryTrait trait, PlayerBinaryTrait? preferred) =>
        trait == preferred ? -1 : trait.index;

    var compared = languageRank(
      a.subtitleLanguage,
    ).compareTo(languageRank(b.subtitleLanguage));
    if (compared != 0) return compared;
    compared = formatRank(a.format).compareTo(formatRank(b.format));
    if (compared != 0) return compared;
    compared = traitRank(
      a.se,
      preference?.se,
    ).compareTo(traitRank(b.se, preference?.se));
    if (compared != 0) return compared;
    compared = traitRank(
      a.ejaculation,
      preference?.ejaculation,
    ).compareTo(traitRank(b.ejaculation, preference?.ejaculation));
    if (compared != 0) return compared;
    return a.fullPath.toLowerCase().compareTo(b.fullPath.toLowerCase());
  }

  void _sort(
    List<PlayerAudioVariant> variants, {
    AudioFormatPreference? preference,
  }) {
    int compare(PlayerAudioVariant a, PlayerAudioVariant b) =>
        _compare(a, b, preference: preference);
    for (var index = 1; index < variants.length; index++) {
      if (compare(variants[index - 1], variants[index]) > 0) {
        variants.sort(compare);
        return;
      }
    }
  }
}

typedef _PreparedSubtitle = ({
  _TreeEntry entry,
  PreparedSubtitleName? original,
  PreparedSubtitleName? cleaned,
});

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

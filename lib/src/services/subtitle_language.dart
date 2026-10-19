import 'dart:ui';

import 'subtitle_matching.dart';

class SubtitleLanguage {
  const SubtitleLanguage._();

  static final _markers = <String, RegExp>{
    'zh-Hans': RegExp(
      r'简体(?:中文)?|簡[体體](?:中文)?|简中|簡中|(?<![a-z0-9])(?:zh[-_](?:hans|cn|sg)|chs|zhs)(?![a-z0-9])',
      caseSensitive: false,
    ),
    'zh-Hant': RegExp(
      r'繁[体體](?:中文)?|繁中|(?<![a-z0-9])(?:zh[-_](?:hant|tw|hk|mo)|cht|zht)(?![a-z0-9])',
      caseSensitive: false,
    ),
    'en': RegExp(
      r'英[语語文]|(?<![a-z0-9])(?:en(?:[-_](?:us|gb))?|eng|english)(?![a-z0-9])',
      caseSensitive: false,
    ),
    'ja': RegExp(
      r'日[语語文]|日本語|(?<![a-z0-9])(?:ja(?:[-_]jp)?|jp|jpn|japanese)(?![a-z0-9])',
      caseSensitive: false,
    ),
  };

  static bool matchesTarget(String path, Locale? targetLocale) {
    if (targetLocale == null) return false;
    final target = targetLocale.languageCode == 'zh'
        ? (targetLocale.scriptCode == 'Hant' ||
                  const ['TW', 'HK', 'MO'].contains(targetLocale.countryCode)
              ? 'zh-Hant'
              : 'zh-Hans')
        : targetLocale.languageCode;
    for (final part in path.replaceAll('\\', '/').split('/').reversed) {
      final languages = _markers.entries.where(
        (entry) => entry.value.hasMatch(part),
      );
      if (languages.isNotEmpty) {
        return languages.any((entry) => entry.key == target);
      }
    }
    return false;
  }

  static SubtitleMatchResult match(String title, PreparedAudioName audio) {
    final original = SubtitleMatcher.checkPrepared(
      SubtitleMatcher.prepareSubtitle(title),
      audio,
    );
    var cleaned = title;
    for (final marker in _markers.values) {
      cleaned = cleaned.replaceAll(marker, '');
    }
    cleaned = cleaned.replaceAll(RegExp(r'[\s_.-]+(?=\.[^.]+$)'), '');
    final withoutLanguage = SubtitleMatcher.checkPrepared(
      SubtitleMatcher.prepareSubtitle(cleaned),
      audio,
    );
    return withoutLanguage.score > original.score ? withoutLanguage : original;
  }
}

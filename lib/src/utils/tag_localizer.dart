import 'dart:ui';
import 'tag_translations.dart';

/// Utility for getting localized tag names.
///
/// Uses the static translation map generated from asmr.one API.
/// Falls back to the original name if no translation is available.
class TagLocalizer {
  TagLocalizer._();

  /// Get the localized name for a tag given its ID and the current locale.
  /// [tagId] - the tag's numeric ID
  /// [defaultName] - the original name to fall back to
  /// [locale] - the current app locale
  static String localize(
    int tagId,
    String defaultName,
    Locale locale, {
    Map<String, String> names = const {},
  }) {
    if (names.isNotEmpty || tagId < 0) {
      final language = _tagLanguage(locale.toLanguageTag());
      final matches = names.entries
          .where((entry) => _tagLanguage(entry.key) == language)
          .map((entry) => entry.value.trim())
          .where((name) => name.isNotEmpty)
          .toSet();
      return matches.length == 1 ? matches.single : defaultName;
    }
    final translations = tagTranslations[tagId];
    if (translations == null) return defaultName;

    final key = _localeKey(locale);
    return translations[key] ?? translations['zh'] ?? defaultName;
  }

  static String _tagLanguage(String locale) {
    final tag = locale.replaceAll('_', '-').toLowerCase();
    if (tag.startsWith('zh')) {
      return tag.contains('hant') ||
              tag.startsWith('zh-tw') ||
              tag.startsWith('zh-hk') ||
              tag.startsWith('zh-mo')
          ? 'zh-Hant'
          : 'zh-Hans';
    }
    return tag.split('-').first;
  }

  /// Get the localized name for a tag, looking up by original name if ID is unknown.
  static String localizeByName(String name, Locale locale) {
    final key = _localeKey(locale);
    if (key == 'zh') {
      return name; // Already in Simplified Chinese, no lookup needed
    }

    // Find tag ID by name
    final id = tagNameToId[name.toLowerCase()];
    if (id == null) return name;

    final translations = tagTranslations[id];
    if (translations == null) return name;

    return translations[key] ?? name;
  }

  static String _localeKey(Locale locale) {
    switch (locale.languageCode) {
      case 'en':
        return 'en';
      case 'ja':
        return 'ja';
      case 'ru':
        return 'ru';
      case 'zh':
        if (locale.scriptCode == 'Hant' ||
            locale.countryCode == 'TW' ||
            locale.countryCode == 'HK' ||
            locale.countryCode == 'MO') {
          return 'zh_Hant';
        }
        return 'zh';
      default:
        // Other languages: prefer English, fall back to zh
        return 'en';
    }
  }
}

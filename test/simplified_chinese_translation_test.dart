import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/translation_service.dart';
import 'package:kikoeru_flutter/src/utils/string_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'recognizes clear simplified text without treating kanji as Chinese',
    () {
      for (final text in ['简体中文标题', '轻声耳语.wav', '听我说话', '缓存']) {
        expect(isClearlySimplifiedChinese(text), isTrue, reason: text);
      }
      for (final text in [
        '',
        '少女',
        '催眠',
      '双子.wav',
      '注意事項.txt',
      '保存.wav',
      '写真.jpg',
      '没収.wav',
      '与',
      '却',
      '号',
        'Hello',
        '日本語',
        'こんにちは',
        'ｶﾀｶﾅ',
        '简体と日本語',
        '听聲音',
        '輕聲耳語.wav',
      ]) {
        expect(isClearlySimplifiedChinese(text), isFalse, reason: text);
      }
    },
  );

  for (final target in ['zh_hans', 'zh_hant', 'en', 'ja']) {
    test('skips Chinese work automatic translation only for $target', () async {
      SharedPreferences.setMockInitialValues({
        'locale_language': 'en',
        TranslationLanguagePreferencesNotifier.keyTargetLanguage: target,
      });
      final service = TranslationService();
      expect(
        await service.shouldSkipAutomaticWorkDetailsTranslation('CHI_HANS'),
        target == 'zh_hans',
      );
      for (final language in [null, 'JPN', 'CHI_HANT', 'ENG']) {
        expect(
          await service.shouldSkipAutomaticWorkDetailsTranslation(language),
          isFalse,
        );
      }
    });
  }

  test('follows app language when deciding whether to skip a work', () async {
    for (final script in [null, 'Hant']) {
      SharedPreferences.setMockInitialValues({
        'locale_language': 'zh',
        if (script != null) 'locale_script': script,
      });
      expect(
        await TranslationService().shouldSkipAutomaticWorkDetailsTranslation(
          ' chi_hans ',
        ),
        script != 'Hant',
      );
    }
  });

  test(
    'preserves simplified text before reading an old translation cache',
    () async {
      const text = '简体中文标题';
      SharedPreferences.setMockInitialValues({
        'locale_language': 'zh',
        'translation_cache_ja_zh_${text.hashCode}': jsonEncode({
          'translation': 'An unwanted cached translation',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      });
      expect(
        await TranslationService().translate(text, sourceLang: 'ja'),
        text,
      );
    },
  );

  test('keeps translating unknown, Japanese and traditional text', () async {
    for (final text in ['少女', '催眠', '日本語', '輕聲耳語']) {
      SharedPreferences.setMockInitialValues({
        'locale_language': 'zh',
        'translation_cache_ja_zh_${text.hashCode}': jsonEncode({
          'translation': '翻译结果',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      });
      expect(
        await TranslationService().translate(text, sourceLang: 'ja'),
        '翻译结果',
      );
    }
  });

  test(
    'keeps simplified text translatable to other target languages',
    () async {
      const text = '简体中文标题';
      for (final target in ['en', 'zh_hant']) {
        final cacheTarget = target == 'zh_hant' ? 'zh_Hant' : 'en';
        SharedPreferences.setMockInitialValues({
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: target,
          'translation_cache_ja_${cacheTarget}_${text.hashCode}': jsonEncode({
            'translation': 'Expected translation',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }),
        });
        expect(
          await TranslationService().translate(text, sourceLang: 'ja'),
          'Expected translation',
        );
      }
    },
  );
}

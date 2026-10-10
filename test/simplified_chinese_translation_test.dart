import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/translation_service.dart';
import 'package:kikoeru_flutter/src/utils/string_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recognizes clear Chinese text without treating kanji as Chinese', () {
    for (final text in [
      '简体中文标题',
      '轻声耳语.wav',
      '听我说话',
      '缓存',
      '輕聲耳語',
      '听聲音',
      'ASMR 轻声耳语.wav',
      '3D ASMR轻声耳语.wav',
    ]) {
      expect(isClearlyChinese(text), isTrue, reason: text);
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
      '給付.wav',
      '劇場.txt',
      '準備.txt',
      '標題.txt',
      '嗚呼',
      '頻度',
      '轻声耳语\nClose your eyes.\nYou are safe now.',
      '輕聲耳語 Be a Hero',
    ]) {
      expect(isClearlyChinese(text), isFalse, reason: text);
    }
  });

  for (final target in ['zh_hans', 'zh_hant', 'en', 'ja']) {
    test(
      'skips automatic translation only for matching source $target',
      () async {
        SharedPreferences.setMockInitialValues({
          'locale_language': 'en',
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: target,
        });
        final service = TranslationService();
        expect(
          await service.shouldSkipAutomaticWorkDetailsTranslation('CHI_HANS'),
          target == 'zh_hans',
        );
        for (final (language, sourceTarget) in <(String, String)>[
          ('JPN', 'ja'),
          ('CHI_HANT', 'zh_hant'),
          ('ENG', 'en'),
        ]) {
          expect(
            await service.shouldSkipAutomaticWorkDetailsTranslation(language),
            sourceTarget == target,
          );
        }
        expect(
          await service.shouldSkipAutomaticWorkDetailsTranslation(null),
          isFalse,
        );
      },
    );
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
        'translation_cache_auto_zh_${text.hashCode}': jsonEncode({
          'translation': 'An unwanted cached translation',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      });
      expect(await TranslationService().translate(text), text);
    },
  );

  test('keeps translating unknown and Japanese text', () async {
    for (final text in ['少女', '催眠', '日本語', '少女の耳語', '給付', '劇場', '準備']) {
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
      for (final target in ['en', 'ja']) {
        final sourceLang = target == 'en' ? 'ja' : 'en';
        SharedPreferences.setMockInitialValues({
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: target,
          'translation_cache_${sourceLang}_${target}_${text.hashCode}':
              jsonEncode({
                'translation': 'Expected translation',
                'timestamp': DateTime.now().millisecondsSinceEpoch,
              }),
        });
        expect(
          await TranslationService().translate(text, sourceLang: sourceLang),
          'Expected translation',
        );
      }
    },
  );

  for (final target in ['zh_hans', 'zh_hant']) {
    test(
      'converts Chinese phrases locally for $target before cached results',
      () async {
        const simplified = '头发发展皇后后面里面';
        const traditional = '頭髮發展皇后後面裏面';
        final text = target == 'zh_hans' ? traditional : simplified;
        final expected = target == 'zh_hans' ? simplified : traditional;
        final sourceLang = target == 'zh_hans' ? 'zh-tw' : 'zh-cn';
        final cacheTarget = target == 'zh_hans' ? 'zh_Hans' : 'zh_Hant';
        SharedPreferences.setMockInitialValues({
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: target,
          'translation_cache_${sourceLang}_${cacheTarget}_${text.hashCode}':
              jsonEncode({
                'translation': 'An unwanted remote translation',
                'timestamp': DateTime.now().millisecondsSinceEpoch,
              }),
        });
        expect(
          await TranslationService().translate(text, sourceLang: sourceLang),
          expected,
        );
      },
    );
  }

  test(
    'explicit Chinese source allows local conversion of shared kanji',
    () async {
      SharedPreferences.setMockInitialValues({'locale_language': 'zh'});
      expect(
        await TranslationService().translate('環境音', sourceLang: 'zh-tw'),
        '环境音',
      );
      expect(isClearlyChinese('少女の耳語'), isFalse);
    },
  );

  test('converts common traditional variants to simplified locally', () async {
    SharedPreferences.setMockInitialValues({'locale_language': 'zh'});
    expect(
      await TranslationService().translate(
        '聽我唸故事，輕聲療癒，戀愛慾望，一週，裏面，檯燈',
        sourceLang: 'zh-tw',
      ),
      '听我念故事，轻声疗愈，恋爱欲望，一周，里面，台灯',
    );
  });

  test(
    'mixed Chinese and English long text keeps the translation path',
    () async {
      const text = '輕聲耳語\nClose your eyes.\nYou are safe now.';
      SharedPreferences.setMockInitialValues({
        'locale_language': 'zh',
        'translation_cache_auto_zh_${text.hashCode}': jsonEncode({
          'translation': '轻声耳语\n闭上眼睛。\n现在你很安全。',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      });
      expect(await TranslationService().convertChineseLocally(text), isNull);
      expect(
        await TranslationService().translateLongText(text),
        '轻声耳语\n闭上眼睛。\n现在你很安全。',
      );
    },
  );

  test(
    'long Chinese text converts locally without splitting phrases or lines',
    () async {
      SharedPreferences.setMockInitialValues({
        TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'zh_hant',
      });
      final text = List.filled(200, '头发发展皇后后面里面').join('\n');
      final expected = List.filled(200, '頭髮發展皇后後面裏面').join('\n');
      final progress = <String>[];
      expect(
        await TranslationService().translateLongText(
          text,
          onProgress: (current, total) => progress.add('$current/$total'),
        ),
        expected,
      );
      expect(progress, ['1/1']);
    },
  );
}

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/translation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'maps confirmed work language markers and leaves unknown markers alone',
    () {
      expect(TranslationService.sourceLanguageForWork(' CHI_HANS '), 'zh-cn');
      expect(TranslationService.sourceLanguageForWork('chi_hant'), 'zh-tw');
      expect(TranslationService.sourceLanguageForWork('JPN'), 'ja');
      expect(TranslationService.sourceLanguageForWork('ENG'), 'en');
      expect(TranslationService.sourceLanguageForWork('KOR'), 'ko');
      expect(TranslationService.sourceLanguageForWork('FRE'), 'fr');
      expect(TranslationService.sourceLanguageForWork('DEU'), 'de');
      expect(TranslationService.sourceLanguageForWork('SPA'), 'es');
      expect(TranslationService.sourceLanguageForWork('ITA'), 'it');
      expect(TranslationService.sourceLanguageForWork('POR'), 'pt');
      expect(TranslationService.sourceLanguageForWork('RUS'), 'ru');
      expect(TranslationService.sourceLanguageForWork(null), isNull);
      expect(TranslationService.sourceLanguageForWork('unknown'), isNull);
    },
  );

  test('resolves each text source from kana before the work source', () {
    expect(
      TranslationService.sourceLanguageForText(
        '少女の耳語.wav',
        sourceLang: 'CHI_HANS',
      ),
      'ja',
    );
    expect(
      TranslationService.sourceLanguageForText('こんにちは.wav', sourceLang: 'ENG'),
      'ja',
    );
    expect(
      TranslationService.sourceLanguageForText(
        'ｶﾀｶﾅ.wav',
        sourceLang: 'unrecognized_marker',
      ),
      'ja',
    );
    expect(
      TranslationService.sourceLanguageForText('ㇰ.wav', sourceLang: 'unknown'),
      'ja',
    );

    expect(
      TranslationService.sourceLanguageForText(
        '简体标题.txt',
        sourceLang: 'CHI_HANS',
      ),
      'zh-cn',
    );
    expect(
      TranslationService.sourceLanguageForText(
        'Hello there.wav',
        sourceLang: 'ENG',
      ),
      'en',
    );
    expect(TranslationService.sourceLanguageForText('普通文件.wav'), isNull);
    expect(
      TranslationService.sourceLanguageForText(
        '普通文件.wav',
        sourceLang: 'unknown',
      ),
      isNull,
    );
    expect(
      TranslationService.sourceLanguageForText(
        '普通文件.wav',
        sourceLang: 'zh-Hant',
      ),
      'zh-tw',
    );
  });

  test('maps Chinese source codes to translator-specific codes', () {
    expect(TranslationService.youdaoSourceLanguageCode('zh-cn'), 'zh-CHS');
    expect(TranslationService.youdaoSourceLanguageCode('zh-tw'), 'zh-CHT');
    expect(TranslationService.youdaoSourceLanguageCode('ja'), 'ja');
    expect(TranslationService.youdaoSourceLanguageCode(null), isNull);
    expect(TranslationService.microsoftSourceLanguageCode('zh-cn'), 'zh-Hans');
    expect(TranslationService.microsoftSourceLanguageCode('zh-tw'), 'zh-Hant');
    expect(TranslationService.microsoftSourceLanguageCode('ja'), 'ja');
    expect(TranslationService.microsoftSourceLanguageCode(null), isNull);
  });

  test('Chinese target reads the kana text Japanese cache', () async {
    const text = '少女の耳語.wav';
    final localCacheDigest = sha256.convert(
      utf8.encode('zh-cn\u0000zh-hans\u0000$text'),
    );
    SharedPreferences.setMockInitialValues({
      TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'zh_hans',
      'translation_cache_ja_zh_Hans_${text.hashCode}': jsonEncode({
        'translation': 'cached Japanese-source translation',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
      'translation_cache_zh-cn_zh_Hans_${text.hashCode}': jsonEncode({
        'translation': 'stale work-source translation',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
      'translation_cache_opencc_$localCacheDigest': 'stale local conversion',
    });

    final sourceLang = TranslationService.sourceLanguageForText(
      text,
      sourceLang: 'CHI_HANS',
    );
    expect(sourceLang, 'ja');
    expect(
      await TranslationService().translate(text, sourceLang: sourceLang),
      'cached Japanese-source translation',
    );
  });

  test(
    'manual translation returns text for a matching language and script',
    () async {
      final service = TranslationService();
      for (final (marker, target, text) in <(String, String, String)>[
        ('ENG', 'en', 'Hello there'),
        ('JPN', 'ja', 'こんにちは'),
        ('CHI_HANS', 'zh_hans', '頭髮發展'),
        ('CHI_HANT', 'zh_hant', '头发发展'),
      ]) {
        final sourceLang = TranslationService.sourceLanguageForWork(marker)!;
        final cacheTarget = switch (target) {
          'zh_hans' => 'zh_Hans',
          'zh_hant' => 'zh_Hant',
          _ => target,
        };
        SharedPreferences.setMockInitialValues({
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: target,
          'translation_cache_${sourceLang}_${cacheTarget}_${text.hashCode}':
              jsonEncode({
                'translation': 'cached remote translation',
                'timestamp': DateTime.now().millisecondsSinceEpoch,
              }),
        });
        expect(await service.translate(text, sourceLang: sourceLang), text);
      }
    },
  );

  test(
    'Chinese work source converts across scripts even with mixed text',
    () async {
      SharedPreferences.setMockInitialValues({
        TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'zh_hans',
      });
      expect(
        await TranslationService().translate(
          '頭髮發展\nこんにちは.wav\nClose your eyes.',
          sourceLang: TranslationService.sourceLanguageForWork('CHI_HANT'),
        ),
        '头发发展\nこんにちは.wav\nClose your eyes.',
      );
    },
  );

  test(
    'known non-Chinese sources keep Chinese text on the remote cache path',
    () async {
      const text = '轻声耳语.wav';
      for (final sourceLang in ['ja', 'fr']) {
        SharedPreferences.setMockInitialValues({
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'zh_hans',
          'translation_cache_${sourceLang}_zh_Hans_${text.hashCode}':
              jsonEncode({
                'translation': 'remote:$sourceLang',
                'timestamp': DateTime.now().millisecondsSinceEpoch,
              }),
        });
        expect(
          await TranslationService().translate(text, sourceLang: sourceLang),
          'remote:$sourceLang',
        );
      }
    },
  );

  test(
    'unknown source keeps clearly Chinese text local before remote cache',
    () async {
      const text = '头发发展皇后后面里面';
      for (final sourceLang in <String?>[null, 'unrecognized_marker']) {
        SharedPreferences.setMockInitialValues({
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'zh_hans',
          'translation_cache_auto_zh_Hans_${text.hashCode}': jsonEncode({
            'translation': 'unwanted remote result',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }),
        });
        expect(
          await TranslationService().translate(text, sourceLang: sourceLang),
          text,
        );
      }
    },
  );

  test(
    'whole subtitle local cache survives calls and clearCache removes it',
    () async {
      const line = '头发发展皇后后面里面';
      final text = List.filled(200, line).join('\n');
      final expected = List.filled(200, '頭髮發展皇后後面裏面').join('\n');
      SharedPreferences.setMockInitialValues({
        'locale_language': 'zh',
        'locale_script': 'Hant',
      });

      final service = TranslationService();
      expect(
        await service.translateLongText(text, sourceLang: 'zh-cn'),
        expected,
      );

      final prefs = await SharedPreferences.getInstance();
      final digest = sha256.convert(
        utf8.encode('zh-cn\u0000zh-hant\u0000$text'),
      );
      final cacheKey = 'translation_cache_opencc_$digest';
      expect(prefs.getString(cacheKey), expected);

      final savedValues = <String, Object>{
        for (final key in prefs.getKeys()) key: prefs.get(key)!,
      };
      savedValues[cacheKey] = 'persisted local result';
      SharedPreferences.setMockInitialValues(savedValues);
      final restartedPrefs = await SharedPreferences.getInstance();
      expect(
        await service.translateLongText(text, sourceLang: 'zh-cn'),
        'persisted local result',
      );

      await restartedPrefs.setString(
        'translation_cache_remote_test',
        'remote result',
      );
      await restartedPrefs.setString('unrelated_setting', 'keep');
      await service.clearCache();
      expect(restartedPrefs.getString(cacheKey), isNull);
      expect(restartedPrefs.getString('translation_cache_remote_test'), isNull);
      expect(restartedPrefs.getString('unrelated_setting'), 'keep');
    },
  );
}

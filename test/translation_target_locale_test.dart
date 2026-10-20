import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (target, appLanguage, appScript, expected) in [
    ('zh_hans', 'en', null, 'zh-Hans'),
    ('zh_hant', 'en', null, 'zh-Hant'),
    ('en', 'ja', null, 'en'),
    ('ja', 'en', null, 'ja'),
    ('follow_app', 'zh', null, 'zh'),
    ('follow_app', 'zh', 'Hant', 'zh-Hant'),
    ('follow_app', 'en', null, 'en'),
    ('follow_app', 'ja', null, 'ja'),
  ]) {
    test(
      'first target resolution uses saved $target with $appLanguage $appScript',
      () async {
        SharedPreferences.setMockInitialValues({
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: target,
          'locale_language': appLanguage,
          if (appScript != null) 'locale_script': appScript,
        });
        final container = ProviderContainer();
        addTearDown(container.dispose);
        expect(
          (await container.read(
            effectiveTranslationTargetLocaleProvider.future,
          )).toLanguageTag(),
          expected,
        );
      },
    );
  }

  test(
    'follow app resolves the supported system locale when no app locale is saved',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher;
      dispatcher.localesTestValue = [
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ];
      addTearDown(dispatcher.clearLocalesTestValue);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        (await container.read(
          effectiveTranslationTargetLocaleProvider.future,
        )).toLanguageTag(),
        'zh-Hant',
      );
    },
  );

  test(
    'follow app resolves a changed system locale on the next automatic load',
    () async {
      SharedPreferences.setMockInitialValues({});
      final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher;
      dispatcher.localesTestValue = [const Locale('en')];
      addTearDown(dispatcher.clearLocalesTestValue);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        (await container.read(
          effectiveTranslationTargetLocaleProvider.future,
        )).languageCode,
        'en',
      );
      dispatcher.localesTestValue = [
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ];
      expect(
        (await container.read(
          effectiveTranslationTargetLocaleProvider.future,
        )).toLanguageTag(),
        'zh-Hant',
      );
    },
  );
}

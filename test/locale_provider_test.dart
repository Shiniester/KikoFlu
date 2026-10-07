import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/locale_provider.dart';
import 'package:kikoeru_flutter/src/utils/tag_translations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('app and tag translations contain only the four supported locales', () {
    expect(S.supportedLocales.toSet(), {
      const Locale('en'),
      const Locale('ja'),
      const Locale('zh'),
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    });
    expect(tagTranslations, isNotEmpty);
    expect(
      tagTranslations.values
          .expand((translations) => translations.keys)
          .toSet(),
      everyElement(isIn(['en', 'ja', 'zh', 'zh_Hant'])),
    );
  });

  for (final locale in S.supportedLocales) {
    test('saved $locale remains available', () async {
      SharedPreferences.setMockInitialValues({
        'locale_language': locale.languageCode,
        if (locale.scriptCode != null) 'locale_script': locale.scriptCode!,
      });
      final notifier = LocaleNotifier();
      addTearDown(notifier.dispose);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(notifier.state, locale);
    });
  }

  test('a removed saved locale follows the system', () async {
    SharedPreferences.setMockInitialValues({'locale_language': 'ru'});
    final notifier = LocaleNotifier();
    addTearDown(notifier.dispose);
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(notifier.state, isNull);
  });
}

import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/translation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpAsyncPreferenceLoad() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('translation language preferences default to app language', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var preferences = container.read(translationLanguagePreferencesProvider);
    expect(preferences.targetLanguage, TranslationTargetLanguage.followApp);

    await _pumpAsyncPreferenceLoad();

    preferences = container.read(translationLanguagePreferencesProvider);
    expect(preferences.targetLanguage, TranslationTargetLanguage.followApp);
  });

  test(
    'translation target options and legacy values use supported targets',
    () {
      expect(TranslationTargetLanguage.values, [
        TranslationTargetLanguage.followApp,
        TranslationTargetLanguage.zhHans,
        TranslationTargetLanguage.zhHant,
        TranslationTargetLanguage.english,
        TranslationTargetLanguage.japanese,
      ]);
      expect(
        TranslationTargetLanguage.fromValue('ru'),
        TranslationTargetLanguage.followApp,
      );
      expect(
        TranslationTargetLanguage.fromValue('custom'),
        TranslationTargetLanguage.followApp,
      );
      expect(
        TranslationTargetLanguage.followApp.resolveLocale(const Locale('en')),
        const Locale('en'),
      );
      expect(
        TranslationTargetLanguage.zhHans.resolveLocale(const Locale('en')),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      );
      expect(
        TranslationTargetLanguage.zhHant.resolveLocale(const Locale('en')),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      );
      expect(
        TranslationTargetLanguage.english.resolveLocale(const Locale('ja')),
        const Locale('en'),
      );
      expect(
        TranslationTargetLanguage.japanese.resolveLocale(const Locale('en')),
        const Locale('ja'),
      );
    },
  );

  test(
    'removed saved translation targets fall back to app language',
    () async {
      for (final legacyTarget in ['ru', 'custom']) {
        SharedPreferences.setMockInitialValues({
          TranslationLanguagePreferencesNotifier.keyTargetLanguage:
              legacyTarget,
          'translation_custom_target_language': 'Portuguese (Brazil)',
        });
        final container = ProviderContainer();
        await _pumpAsyncPreferenceLoad();

        expect(
          container
              .read(translationLanguagePreferencesProvider)
              .targetLanguage,
          TranslationTargetLanguage.followApp,
        );
        container.dispose();
      }
    },
  );

  test('translated lyrics auto-save defaults to enabled and persists',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(autoSaveTranslatedLyricsProvider), isTrue);
    await _pumpAsyncPreferenceLoad();
    expect(container.read(autoSaveTranslatedLyricsProvider), isTrue);

    final notifier =
        container.read(autoSaveTranslatedLyricsProvider.notifier);
    await notifier.setEnabled(false);

    expect(container.read(autoSaveTranslatedLyricsProvider), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(AutoSaveTranslatedLyricsNotifier.preferenceKey),
      isFalse,
    );
  });

  test('translated lyrics auto-save loads a disabled preference', () async {
    SharedPreferences.setMockInitialValues({
      AutoSaveTranslatedLyricsNotifier.preferenceKey: false,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(autoSaveTranslatedLyricsProvider), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(autoSaveTranslatedLyricsProvider), isFalse);
  });

  test('work detail auto-translation defaults off and persists', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(autoTranslateWorkDetailsProvider), isFalse);
    await _pumpAsyncPreferenceLoad();
    expect(container.read(autoTranslateWorkDetailsProvider), isFalse);

    await container
        .read(autoTranslateWorkDetailsProvider.notifier)
        .setEnabled(true);

    expect(container.read(autoTranslateWorkDetailsProvider), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(AutoTranslateWorkDetailsNotifier.preferenceKey),
      isTrue,
    );

    final reloadedContainer = ProviderContainer();
    addTearDown(reloadedContainer.dispose);
    final reloaded = await reloadedContainer
        .read(autoTranslateWorkDetailsProvider.notifier)
        .resolvedEnabled();
    expect(reloaded, isTrue);
  });

  test('translated lyrics auto-save resolves persisted value before use',
      () async {
    SharedPreferences.setMockInitialValues({
      AutoSaveTranslatedLyricsNotifier.preferenceKey: false,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final enabled = await container
        .read(autoSaveTranslatedLyricsProvider.notifier)
        .resolvedEnabled();

    expect(enabled, isFalse);
  });

  test('local auto-save change wins over an unfinished preference load',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier =
        container.read(autoSaveTranslatedLyricsProvider.notifier);

    await notifier.setEnabled(false);
    await notifier.resolvedEnabled();

    expect(container.read(autoSaveTranslatedLyricsProvider), isFalse);
  });

  test('translation language preferences load and persist target values',
      () async {
    SharedPreferences.setMockInitialValues({
      TranslationLanguagePreferencesNotifier.keyTargetLanguage:
          TranslationTargetLanguage.english.value,
      'translation_custom_target_language': 'Portuguese (Brazil)',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
        container.read(translationLanguagePreferencesProvider).targetLanguage,
        TranslationTargetLanguage.followApp);
    await _pumpAsyncPreferenceLoad();

    var preferences = container.read(translationLanguagePreferencesProvider);
    expect(preferences.targetLanguage, TranslationTargetLanguage.english);

    final notifier =
        container.read(translationLanguagePreferencesProvider.notifier);
    await notifier.updateTargetLanguage(TranslationTargetLanguage.japanese);

    preferences = container.read(translationLanguagePreferencesProvider);
    final prefs = await SharedPreferences.getInstance();

    expect(preferences.targetLanguage, TranslationTargetLanguage.japanese);
    expect(
      prefs.getString(TranslationLanguagePreferencesNotifier.keyTargetLanguage),
      TranslationTargetLanguage.japanese.value,
    );
  });

  test('LLM settings normalize invalid concurrency values', () async {
    SharedPreferences.setMockInitialValues({
      'llm_settings_concurrency': 0,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(llmSettingsProvider).concurrency,
      LLMSettings.defaultConcurrency,
    );
    await _pumpAsyncPreferenceLoad();

    expect(
      container.read(llmSettingsProvider).concurrency,
      LLMSettings.minConcurrency,
    );
    expect(
      const LLMSettings().copyWith(concurrency: 99).concurrency,
      LLMSettings.maxConcurrency,
    );

    await container.read(llmSettingsProvider.notifier).updateSettings(
          const LLMSettings(concurrency: -5),
        );

    final prefs = await SharedPreferences.getInstance();
    expect(
      container.read(llmSettingsProvider).concurrency,
      LLMSettings.minConcurrency,
    );
    expect(
      prefs.getInt('llm_settings_concurrency'),
      LLMSettings.minConcurrency,
    );
  });

  test('LLM default prompt uses supported target and keeps source automatic',
      () async {
    SharedPreferences.setMockInitialValues({
      'translation_source': TranslationSource.llm.value,
      'translation_source_language': 'custom',
      TranslationLanguagePreferencesNotifier.keyTargetLanguage:
          TranslationTargetLanguage.japanese.value,
      'translation_custom_source_language': 'Korean',
    });

    final prompt =
        await TranslationService().getDefaultLLMPromptForCurrentLocale();

    expect(prompt, isNot(contains('from Korean')));
    expect(prompt, contains('into Japanese'));
  });

  test('identifies generated default LLM prompts', () {
    final prompt = TranslationService.getDefaultLLMPrompt(
      const Locale('en'),
      sourceLanguageName: 'Japanese',
      targetLanguageName: 'Korean',
    );

    expect(TranslationService.isGeneratedDefaultLLMPrompt(prompt), true);
    expect(
      TranslationService.isGeneratedDefaultLLMPrompt(
        'Translate casually and keep honorifics.',
      ),
      false,
    );
  });

  test('non-LLM prompt ignores legacy custom target and follows app language',
      () async {
    SharedPreferences.setMockInitialValues({
      'translation_source': TranslationSource.google.value,
      'locale_language': 'en',
      'translation_source_language': 'custom',
      TranslationLanguagePreferencesNotifier.keyTargetLanguage:
          'custom',
      'translation_custom_source_language': 'Korean',
      'translation_custom_target_language': 'Portuguese (Brazil)',
    });

    final prompt =
        await TranslationService().getDefaultLLMPromptForCurrentLocale();

    expect(prompt, isNot(contains('from Korean')));
    expect(prompt, isNot(contains('Portuguese (Brazil)')));
    expect(prompt, contains('into English'));
  });

  test('unsupported saved app locales resolve supported system preferences',
      () async {
    final platformDispatcher =
        TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
    platformDispatcher.localesTestValue = const [Locale('fr'), Locale('ja')];
    addTearDown(platformDispatcher.clearLocalesTestValue);

    for (final savedLocale in [
      {'locale_language': 'ru'},
      {'locale_language': 'zh', 'locale_script': 'Hans'},
    ]) {
      SharedPreferences.setMockInitialValues({
        ...savedLocale,
        TranslationLanguagePreferencesNotifier.keyTargetLanguage:
            TranslationTargetLanguage.followApp.value,
      });

      final prompt =
          await TranslationService().getDefaultLLMPromptForCurrentLocale();

      expect(prompt, contains('into Japanese'));
      expect(prompt, isNot(contains('into Russian')));
    }
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'new preferences use the player defaults and preserve a saved format order',
    () async {
      SharedPreferences.setMockInitialValues({});
      final defaultsContainer = ProviderContainer();
      addTearDown(defaultsContainer.dispose);
      final defaults = await defaultsContainer
          .read(audioFormatPreferenceProvider.notifier)
          .getPreference();
      expect(defaults.priority.first, AudioFormat.wav);
      expect(
        defaults.subtitleLanguage,
        PlayerSubtitleLanguage.simplifiedChinese,
      );
      expect(defaults.se, PlayerBinaryTrait.present);
      expect(defaults.ejaculation, PlayerBinaryTrait.present);

      SharedPreferences.setMockInitialValues({
        'audio_format_preference': ['mp3', 'flac', 'wav'],
      });
      final savedContainer = ProviderContainer();
      addTearDown(savedContainer.dispose);
      final saved = await savedContainer
          .read(audioFormatPreferenceProvider.notifier)
          .getPreference();
      expect(saved.priority.take(3), [
        AudioFormat.mp3,
        AudioFormat.flac,
        AudioFormat.wav,
      ]);
      expect(saved.priority.toSet(), AudioFormat.values.toSet());
    },
  );

  test(
    'all audio preferences survive reload, reordering and restoring defaults',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(audioFormatPreferenceProvider.notifier);
      await notifier.getPreference();
      await notifier.updatePreference(
        const AudioFormatPreference(
          subtitleLanguage: PlayerSubtitleLanguage.traditionalChinese,
          se: PlayerBinaryTrait.absent,
          ejaculation: PlayerBinaryTrait.absent,
          includeUnknown: false,
        ),
      );
      await notifier.updatePriority([
        AudioFormat.opus,
        ...AudioFormat.values.where((format) => format != AudioFormat.opus),
      ]);

      final reloadedContainer = ProviderContainer();
      addTearDown(reloadedContainer.dispose);
      final reloadedNotifier = reloadedContainer.read(
        audioFormatPreferenceProvider.notifier,
      );
      final reloaded = await reloadedNotifier.getPreference();
      expect(reloaded.priority.first, AudioFormat.opus);
      expect(
        reloaded.subtitleLanguage,
        PlayerSubtitleLanguage.traditionalChinese,
      );
      expect(reloaded.se, PlayerBinaryTrait.absent);
      expect(reloaded.ejaculation, PlayerBinaryTrait.absent);
      expect(reloaded.includeUnknown, isFalse);

      await reloadedNotifier.resetToDefault();
      final finalContainer = ProviderContainer();
      addTearDown(finalContainer.dispose);
      final restored = await finalContainer
          .read(audioFormatPreferenceProvider.notifier)
          .getPreference();
      expect(restored.priority, const AudioFormatPreference().priority);
      expect(
        restored.subtitleLanguage,
        PlayerSubtitleLanguage.simplifiedChinese,
      );
      expect(restored.se, PlayerBinaryTrait.present);
      expect(restored.ejaculation, PlayerBinaryTrait.present);
      expect(restored.includeUnknown, isTrue);
    },
  );
}

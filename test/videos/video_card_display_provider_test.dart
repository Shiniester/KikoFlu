import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/video_card_display_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _settlePreferenceLoad() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'field defaults, early changes, persistence, and reset stay independent',
    () async {
      SharedPreferences.setMockInitialValues({
        'video_card_display_duration': false,
        'video_card_display_releaseDate': false,
        'video_card_display_directors': true,
        'work_card_display_duration': true,
      });
      final settings = VideoCardDisplayNotifier();
      addTearDown(settings.dispose);

      expect(settings.state, {
        VideoCardField.duration,
        VideoCardField.releaseDate,
        VideoCardField.subtitleTag,
        VideoCardField.uncensoredTag,
      });

      await settings.setVisible(VideoCardField.duration, true);
      await settings.setVisible(VideoCardField.makers, true);
      await _settlePreferenceLoad();

      expect(settings.state, {
        VideoCardField.duration,
        VideoCardField.subtitleTag,
        VideoCardField.uncensoredTag,
        VideoCardField.makers,
        VideoCardField.directors,
      });

      var preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('video_card_display_duration'), isTrue);
      expect(preferences.getBool('video_card_display_releaseDate'), isFalse);
      expect(preferences.getBool('video_card_display_directors'), isTrue);
      expect(preferences.getBool('video_card_display_makers'), isTrue);
      expect(preferences.getBool('video_card_display_labels'), isNull);

      final restored = VideoCardDisplayNotifier();
      addTearDown(restored.dispose);
      await _settlePreferenceLoad();
      expect(restored.state, settings.state);

      final resetting = restored.resetToDefault();
      await restored.setVisible(VideoCardField.directors, true);
      await resetting;
      expect(restored.state.contains(VideoCardField.directors), isTrue);
      preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('video_card_display_directors'), isTrue);
      expect(preferences.getBool('work_card_display_duration'), isTrue);

      await restored.resetToDefault();
      expect(restored.state, {
        VideoCardField.duration,
        VideoCardField.releaseDate,
        VideoCardField.subtitleTag,
        VideoCardField.uncensoredTag,
      });
      preferences = await SharedPreferences.getInstance();
      for (final field in VideoCardField.values) {
        expect(
          preferences.getBool('video_card_display_${field.name}'),
          field.index < 4,
        );
      }
      expect(preferences.getBool('work_card_display_duration'), isTrue);
    },
  );
}

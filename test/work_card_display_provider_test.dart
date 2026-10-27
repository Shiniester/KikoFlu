import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/work_card_display_provider.dart';
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

  test('uses default card content settings', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(workCardDisplayProvider).showAgeRating, isFalse);
    expect(container.read(workCardDisplayProvider).showUserAddedTags, isFalse);
    await _pumpAsyncPreferenceLoad();

    final settings = container.read(workCardDisplayProvider);
    expect(settings.showRating, isTrue);
    expect(settings.showSubtitleTag, isTrue);
  });

  test('ignores saved retired card size and font scale values', () async {
    SharedPreferences.setMockInitialValues({
      'work_card_display_card_size': 'extra_large',
      'work_card_display_font_scale': 'extra_large',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await _pumpAsyncPreferenceLoad();

    final settings = container.read(workCardDisplayProvider);
    final prefs = await SharedPreferences.getInstance();

    expect(settings.showRating, isTrue);
    expect(settings.showPrice, isTrue);
    expect(settings.showDuration, isFalse);
    expect(settings.showUserAddedTags, isFalse);
    expect(prefs.getString('work_card_display_card_size'), 'extra_large');
    expect(prefs.getString('work_card_display_font_scale'), 'extra_large');
  });

  test('reset restores and persists all work card defaults', () async {
    SharedPreferences.setMockInitialValues({
      'work_card_display_card_size': 'extra_large',
      'work_card_display_font_scale': 'extra_large',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpAsyncPreferenceLoad();

    final notifier = container.read(workCardDisplayProvider.notifier);
    await notifier.toggleRating();
    await notifier.toggleDuration();
    await notifier.toggleAgeRating();
    await notifier.toggleUserAddedTags();
    await notifier.resetToDefault();

    final settings = container.read(workCardDisplayProvider);
    expect(settings.showRating, isTrue);
    expect(settings.showDuration, isFalse);
    expect(settings.showAgeRating, isFalse);
    expect(settings.showUserAddedTags, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('work_card_display_rating'), isTrue);
    expect(prefs.getBool('work_card_display_duration'), isFalse);
    expect(prefs.getBool(WorkCardDisplayNotifier.keyAgeRating), isFalse);
    expect(prefs.getBool(WorkCardDisplayNotifier.keyUserAddedTags), isFalse);
    expect(prefs.getString('work_card_display_card_size'), 'extra_large');
    expect(prefs.getString('work_card_display_font_scale'), 'extra_large');
  });

  test('user-added tag visibility persists and reloads', () async {
    final containers = <ProviderContainer>[];
    addTearDown(() {
      for (final container in containers) {
        container.dispose();
      }
    });

    final initial = ProviderContainer();
    containers.add(initial);
    expect(initial.read(workCardDisplayProvider).showUserAddedTags, isFalse);
    await _pumpAsyncPreferenceLoad();

    await initial.read(workCardDisplayProvider.notifier).toggleUserAddedTags();
    expect(initial.read(workCardDisplayProvider).showUserAddedTags, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(WorkCardDisplayNotifier.keyUserAddedTags), isTrue);

    final restored = ProviderContainer();
    containers.add(restored);
    expect(restored.read(workCardDisplayProvider).showUserAddedTags, isFalse);
    await _pumpAsyncPreferenceLoad();
    expect(restored.read(workCardDisplayProvider).showUserAddedTags, isTrue);

    await restored.read(workCardDisplayProvider.notifier).resetToDefault();
    expect(restored.read(workCardDisplayProvider).showUserAddedTags, isFalse);
    expect(prefs.getBool(WorkCardDisplayNotifier.keyUserAddedTags), isFalse);

    final reset = ProviderContainer();
    containers.add(reset);
    expect(reset.read(workCardDisplayProvider).showUserAddedTags, isFalse);
    await _pumpAsyncPreferenceLoad();
    expect(reset.read(workCardDisplayProvider).showUserAddedTags, isFalse);
  });

  test(
    'keeps a local tag setting change made before preference loading ends',
    () async {
      SharedPreferences.setMockInitialValues({
        WorkCardDisplayNotifier.keyUserAddedTags: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final update = container
          .read(workCardDisplayProvider.notifier)
          .toggleUserAddedTags();
      await update;
      await _pumpAsyncPreferenceLoad();

      expect(container.read(workCardDisplayProvider).showUserAddedTags, isTrue);
    },
  );
}

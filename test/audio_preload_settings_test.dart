import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('defaults to 60 seconds on Android when no mode is saved', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final settings = await _loadSettings({});

    expect(settings.mode, PreloadThresholdMode.custom);
    expect(settings.customSeconds, 60);
    expect(settings.effectiveSeconds, 60);
  });

  test('starts with the Android default while preferences load', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(preloadNextSettingsProvider.notifier);

    expect(notifier.state.effectiveSeconds, 60);

    final loaded = Completer<void>();
    notifier.addListener((_) {
      if (!loaded.isCompleted) loaded.complete();
    }, fireImmediately: false);
    await loaded.future.timeout(const Duration(seconds: 5));
  });

  test('keeps the 10-second default on other platforms', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final settings = await _loadSettings({});

    expect(settings.mode, PreloadThresholdMode.seconds10);
    expect(settings.effectiveSeconds, 10);
  });

  test('preserves saved preload modes and custom seconds on Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    for (final (mode, expectedSeconds) in [
      ('off', null),
      ('seconds10', 10),
      ('seconds20', 20),
      ('seconds30', 30),
    ]) {
      final settings = await _loadSettings({'preload_next_mode': mode});
      expect(settings.effectiveSeconds, expectedSeconds, reason: mode);
    }

    final custom = await _loadSettings({
      'preload_next_mode': 'custom',
      'preload_next_custom_seconds': 45,
    });
    expect(custom.mode, PreloadThresholdMode.custom);
    expect(custom.customSeconds, 45);
    expect(custom.effectiveSeconds, 45);
  });
}

Future<PreloadNextSettings> _loadSettings(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  final container = ProviderContainer();
  try {
    final notifier = container.read(preloadNextSettingsProvider.notifier);
    final loaded = Completer<PreloadNextSettings>();
    notifier.addListener((state) {
      if (!loaded.isCompleted) loaded.complete(state);
    }, fireImmediately: false);
    return await loaded.future.timeout(const Duration(seconds: 5));
  } finally {
    container.dispose();
  }
}

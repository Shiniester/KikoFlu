import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/collection_layout_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart'
    show LayoutType;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _flushPreferenceLoads() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audio layout ignores legacy values, cycles, and restores', () async {
    SharedPreferences.setMockInitialValues({
      'works_layout_type': 'list',
      'my_reviews_layout_type': 'smallGrid',
      'collection_history_layout_type': 'list',
      'collection_playlists_layout_type': 'smallGrid',
      'collection_downloads_layout_type': 'list',
    });
    final firstRun = ProviderContainer();

    expect(firstRun.read(audioLayoutProvider), LayoutType.bigGrid);
    await _flushPreferenceLoads();
    expect(firstRun.read(audioLayoutProvider), LayoutType.bigGrid);

    final notifier = firstRun.read(audioLayoutProvider.notifier);
    notifier.set(LayoutType.smallGrid);
    expect(firstRun.read(audioLayoutProvider), LayoutType.smallGrid);
    notifier.cycle();
    expect(firstRun.read(audioLayoutProvider), LayoutType.list);
    notifier.cycle();
    expect(firstRun.read(audioLayoutProvider), LayoutType.bigGrid);
    notifier.cycle();
    expect(firstRun.read(audioLayoutProvider), LayoutType.smallGrid);
    await _flushPreferenceLoads();

    final preferences = await SharedPreferences.getInstance();
    expect(AudioLayoutNotifier.preferenceKey, 'audio_collection_layout_type');
    expect(
      preferences.getString(AudioLayoutNotifier.preferenceKey),
      LayoutType.smallGrid.name,
    );
    expect(preferences.getString('works_layout_type'), 'list');
    expect(preferences.getString('my_reviews_layout_type'), 'smallGrid');
    expect(preferences.getString('collection_history_layout_type'), 'list');
    expect(
      preferences.getString('collection_playlists_layout_type'),
      'smallGrid',
    );
    expect(preferences.getString('collection_downloads_layout_type'), 'list');

    firstRun.dispose();
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(restored.read(audioLayoutProvider), LayoutType.bigGrid);
    await _flushPreferenceLoads();
    expect(restored.read(audioLayoutProvider), LayoutType.smallGrid);
  });
}

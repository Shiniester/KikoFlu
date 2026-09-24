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

  test('collection layout choices persist independently and restore', () async {
    SharedPreferences.setMockInitialValues({});
    final firstRun = ProviderContainer();

    for (final key in CollectionLayoutKey.values) {
      expect(firstRun.read(collectionLayoutProvider(key)), LayoutType.bigGrid);
    }
    await _flushPreferenceLoads();

    firstRun
        .read(collectionLayoutProvider(CollectionLayoutKey.history).notifier)
        .set(LayoutType.smallGrid);
    firstRun
        .read(collectionLayoutProvider(CollectionLayoutKey.playlists).notifier)
        .set(LayoutType.list);
    firstRun
        .read(collectionLayoutProvider(CollectionLayoutKey.downloads).notifier)
        .set(LayoutType.smallGrid);
    await _flushPreferenceLoads();

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('collection_history_layout_type'),
      'smallGrid',
    );
    expect(preferences.getString('collection_playlists_layout_type'), 'list');
    expect(
      preferences.getString('collection_downloads_layout_type'),
      'smallGrid',
    );

    firstRun.dispose();
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    for (final key in CollectionLayoutKey.values) {
      restored.read(collectionLayoutProvider(key));
    }
    await _flushPreferenceLoads();

    expect(
      restored.read(collectionLayoutProvider(CollectionLayoutKey.history)),
      LayoutType.smallGrid,
    );
    expect(
      restored.read(collectionLayoutProvider(CollectionLayoutKey.playlists)),
      LayoutType.list,
    );
    expect(
      restored.read(collectionLayoutProvider(CollectionLayoutKey.downloads)),
      LayoutType.smallGrid,
    );
  });
}

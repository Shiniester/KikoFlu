import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/comics/comic_providers.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _flushPreferenceWrites() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('comic collection page order persists and restores', () async {
    SharedPreferences.setMockInitialValues({
      ComicCollectionPageOrderNotifier.preferenceKey: '1,1,3',
    });
    final preferences = await SharedPreferences.getInstance();
    await StorageService.initCritical(preferences: preferences);

    final firstRun = ProviderContainer();
    addTearDown(firstRun.dispose);
    expect(firstRun.read(comicCollectionPageOrderProvider), [1, 2, 3]);

    firstRun
        .read(comicCollectionPageOrderProvider.notifier)
        .updateOrder([3, 1, 2]);
    await _flushPreferenceWrites();
    expect(
      preferences.getString(ComicCollectionPageOrderNotifier.preferenceKey),
      '3,1,2',
    );

    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(restored.read(comicCollectionPageOrderProvider), [3, 1, 2]);

    restored.read(comicCollectionPageOrderProvider.notifier).restoreDefaults();
    await _flushPreferenceWrites();
    expect(
      preferences.getString(ComicCollectionPageOrderNotifier.preferenceKey),
      '1,2,3',
    );
  });
}

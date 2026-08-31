import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('critical storage defers legacy settings and cache boxes', () async {
    final root = await Directory.systemTemp.createTemp(
      'kikoflu-storage-bootstrap-',
    );
    addTearDown(() async {
      await Hive.close();
      if (await root.exists()) await root.delete(recursive: true);
    });
    Hive.init(root.path);
    SharedPreferences.setMockInitialValues({'critical': 'ready'});
    final preferences = await SharedPreferences.getInstance();

    await StorageService.initCritical(preferences: preferences);

    expect(Hive.isBoxOpen('users'), isTrue);
    expect(Hive.isBoxOpen('settings'), isFalse);
    expect(Hive.isBoxOpen('cache'), isFalse);
    expect(StorageService.getString('critical'), 'ready');
    await StorageService.setUser('account', 'current');
    expect(StorageService.getUser<String>('account'), 'current');

    await StorageService.initSecondary();

    expect(Hive.isBoxOpen('settings'), isTrue);
    expect(Hive.isBoxOpen('cache'), isTrue);
    await StorageService.setSetting('theme', 'system');
    await StorageService.setCache('derived', 1);
    expect(StorageService.getSetting<String>('theme'), 'system');
    expect(StorageService.getCache<int>('derived'), 1);
  });
}

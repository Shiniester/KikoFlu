import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('storage opens only the users Hive box after the first frame', () async {
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

    expect(Hive.isBoxOpen('users'), isFalse);
    expect(Hive.isBoxOpen('settings'), isFalse);
    expect(Hive.isBoxOpen('cache'), isFalse);
    expect(StorageService.getString('critical'), 'ready');
    await StorageService.initSecondary();

    expect(Hive.isBoxOpen('users'), isTrue);
    expect(Hive.isBoxOpen('settings'), isFalse);
    expect(Hive.isBoxOpen('cache'), isFalse);
    await StorageService.setUser('account', 'current');
    expect(StorageService.getUser<String>('account'), 'current');
    expect(StorageService.getAllUserKeys(), contains('account'));
    await StorageService.removeUser('account');
    expect(StorageService.getUser<String>('account'), isNull);
    expect(StorageService.getAllUserKeys(), isNot(contains('account')));
  });
}

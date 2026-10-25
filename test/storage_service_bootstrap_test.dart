import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:kikoeru_flutter/src/performance/performance_recorder.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('secondary storage initializes Hive lazily and can retry', () async {
    final appDocuments = await Directory.systemTemp.createTemp(
      'kikoflu-storage-bootstrap-',
    );
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pathLookupStarted = Completer<void>();
    final allowPathLookup = Completer<void>();
    var pathLookupCount = 0;
    addTearDown(() async {
      if (!allowPathLookup.isCompleted) allowPathLookup.complete();
      messenger.setMockMethodCallHandler(pathProvider, null);
      await Hive.close();
      if (await appDocuments.exists()) {
        await appDocuments.delete(recursive: true);
      }
    });

    messenger.setMockMethodCallHandler(pathProvider, (_) async {
      pathLookupCount++;
      if (pathLookupCount == 1) {
        throw PlatformException(code: 'documents_unavailable');
      }
      if (!pathLookupStarted.isCompleted) pathLookupStarted.complete();
      await allowPathLookup.future;
      return appDocuments.path;
    });
    SharedPreferences.setMockInitialValues({'critical': 'ready'});
    final preferences = await SharedPreferences.getInstance();
    final recorder = PerformanceRecorder.instance
      ..start(force: true)
      ..resetRun();

    await StorageService.initCritical(preferences: preferences);

    expect(pathLookupCount, 0);
    expect(Hive.isBoxOpen('users'), isFalse);
    expect(Hive.isBoxOpen('settings'), isFalse);
    expect(Hive.isBoxOpen('cache'), isFalse);
    expect(StorageService.getString('critical'), 'ready');

    await expectLater(
      StorageService.initSecondary(),
      throwsA(isA<PlatformException>()),
    );
    expect(Hive.isBoxOpen('users'), isFalse);

    final firstInit = StorageService.initSecondary();
    await pathLookupStarted.future;
    final secondInit = StorageService.initSecondary();
    var writeCompleted = false;
    final write = StorageService.setUser('account', 'current').then((_) {
      writeCompleted = true;
    });

    expect(pathLookupCount, 2);
    expect(Hive.isBoxOpen('users'), isFalse);
    expect(writeCompleted, isFalse);

    allowPathLookup.complete();
    await Future.wait([firstInit, secondInit, write]);

    expect(pathLookupCount, 2);
    expect(Hive.isBoxOpen('users'), isTrue);
    expect(Hive.isBoxOpen('settings'), isFalse);
    expect(Hive.isBoxOpen('cache'), isFalse);
    expect(StorageService.getUser<String>('account'), 'current');
    expect(StorageService.getAllUserKeys(), contains('account'));
    expect(
      Hive.box('users').path,
      '${appDocuments.path}${Platform.pathSeparator}KikoFlu${Platform.pathSeparator}users.hive',
    );
    expect(recorder.metric('bootstrapHiveBackendMs'), isNotNull);

    await StorageService.removeUser('account');
    expect(StorageService.getUser<String>('account'), isNull);
    expect(StorageService.getAllUserKeys(), isNot(contains('account')));
  });
}

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'retries subtitle library initialization after a temporary failure',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical();
      final root = await Directory.systemTemp.createTemp(
        'subtitle_init_retry_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (++calls == 1) throw PlatformException(code: 'temporary-failure');
        return root.path;
      });

      try {
        await expectLater(
          SubtitleLibraryService.ensureInitialized(),
          throwsA(isA<PlatformException>()),
        );
        await expectLater(
          SubtitleLibraryService.ensureInitialized(),
          completes,
        );
        expect(calls, greaterThan(1));
        await (await SubtitleDatabase.instance.database).close();
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}

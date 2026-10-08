import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/history_database.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'batch heard lookup returns only candidate IDs present in history',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'recommendation-history-',
      );
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async => directory.path);
      final database = HistoryDatabase.instance;

      try {
        final now = DateTime.utc(2026, 10, 8);
        for (final id in [2, 5]) {
          await database.addOrUpdate(
            HistoryRecord(
              work: Work(id: id, title: 'Work $id'),
              lastPlayedTime: now,
            ),
          );
        }

        expect(await database.getPlayedWorkIds([1, 2, 3, 5]), {2, 5});
        expect(await database.getPlayedWorkIds(const []), isEmpty);
      } finally {
        await (await database.database).close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null);
        await directory.delete(recursive: true);
      }
    },
  );
}

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/history_database.dart';
import 'package:kikoeru_flutter/src/services/japanese_asmr_service.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

class _JapaneseAsmrService extends JapaneseAsmrService {
  Work? registeredWork;

  @override
  void registerWork(Work work) => registeredWork = work;

  @override
  bool hasRegisteredWork(int postId) => registeredWork?.id == -postId;

  @override
  Future<Map<String, dynamic>> getWork(
    int postId, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async => {'id': -postId, 'source_id': registeredWork?.sourceId};

  @override
  Future<List<dynamic>> getWorkTracks(
    int postId, {
    bool forceRefresh = false,
  }) async => [registeredWork?.sourceId];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'restores the source ID from an existing Japanese ASMR history record',
    () async {
      final directory = await Directory.systemTemp.createTemp('jp-history-');
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async => directory.path);
      final history = HistoryDatabase.instance;
      final japanese = _JapaneseAsmrService();
      final api = KikoeruApiService(japaneseAsmrService: japanese);

      try {
        await history.addOrUpdate(
          HistoryRecord(
            work: const Work(
              id: -150867,
              title: 'Saved work',
              sourceId: 'RJ01707048',
            ),
            lastPlayedTime: DateTime.utc(2026, 10, 20),
          ),
        );

        final work = await api.getWork(-150867);
        expect(work['source_id'], 'RJ01707048');
        expect(await api.getWorkTracks(-150867), ['RJ01707048']);
        expect(japanese.registeredWork?.id, -150867);
      } finally {
        await (await history.database).close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null);
        await directory.delete(recursive: true);
      }
    },
  );
}

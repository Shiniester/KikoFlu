import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_store.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'persists exact audio associations through index rebuild without overwriting',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'generated-subtitles-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => directory.path);
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical();
      const store = GeneratedSubtitleStore();
      const original = '1\n00:00:01,000 --> 00:00:02,500\nこんにちは\n\n';
      const other = '1\n00:00:04,000 --> 00:00:05,000\nありがとう\n\n';
      const a = AudioTrack(
        id: 'a',
        title: '同名音声.mp3',
        url: 'file:///disc1/voice.mp3',
        sourcePath: '/disc1/voice.mp3',
        workId: 123456,
        hash: 'local:voice.mp3',
      );
      const b = AudioTrack(
        id: 'b',
        title: '同名音声.mp3',
        url: 'file:///disc2/voice.mp3',
        sourcePath: '/disc2/voice.mp3',
        workId: 123456,
        hash: 'local:voice.mp3',
      );
      final c = a.copyWith(workId: 654321);
      try {
        final aPath = await store.save(a, original, cancelToken: CancelToken());
        final bPath = await store.save(b, other, cancelToken: CancelToken());
        final cPath = await store.save(c, other, cancelToken: CancelToken());
        expect({aPath, bPath, cPath}, hasLength(3));
        expect(await File(aPath).readAsString(), original);
        expect(await store.save(a, other, cancelToken: CancelToken()), aPath);
        expect(await File(aPath).readAsString(), original);

        await SubtitleLibraryService.clearCache();
        expect(await const GeneratedSubtitleStore().find(a), aPath);
        expect(await store.find(b), bPath);
        expect(await store.find(c), cPath);
        final association = await SubtitleDatabase.instance.getMeta(
          'generated_audio:${GeneratedSubtitleStore.audioIdentity(a)}',
        );
        expect(
          association,
          startsWith('${GeneratedSubtitleStore.relativeDirectory}/'),
        );
        expect(association, isNot(contains(directory.path)));

        final cancelled = CancelToken()..cancel();
        final d = a.copyWith(sourcePath: '/disc3/voice.mp3');
        await expectLater(
          store.save(d, original, cancelToken: cancelled),
          throwsA(isA<DioException>()),
        );
        expect(await store.find(d), isNull);
        await File(bPath).delete();
        expect(await store.find(b), isNull);
        await expectLater(
          store.save(d, 'invalid', cancelToken: CancelToken()),
          throwsFormatException,
        );
        expect(await store.find(d), isNull);
      } finally {
        await (await SubtitleDatabase.instance.database).close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'a real server hash keeps generated subtitles associated across downloads',
    () {
      const streamed = AudioTrack(
        id: 'remote',
        title: '音声.mp3',
        url: 'https://example.test/voice.mp3',
        workId: 123456,
        hash: 'server-audio-hash',
      );
      final downloaded = streamed.copyWith(sourcePath: '/download/音声.mp3');
      expect(
        GeneratedSubtitleStore.audioIdentity(downloaded),
        GeneratedSubtitleStore.audioIdentity(streamed),
      );
    },
  );
}

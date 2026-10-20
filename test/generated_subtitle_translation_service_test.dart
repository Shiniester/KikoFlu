import 'dart:ui';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_store.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_translation_service.dart';

void main() {
  const srt =
      '1\n00:00:01,000 --> 00:00:02,500\nこんにちは\n\n'
      '2\n00:00:03,000 --> 00:00:04,000\n物語\n\n';
  late Directory directory;
  late File original;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('subtitle-translation-');
    original = await File('${directory.path}/audio.srt').writeAsString(srt);
  });
  tearDown(() => directory.delete(recursive: true));

  for (final save in [false, true]) {
    test(
      'translates all cues with timestamps and save preference $save',
      () async {
        final store = _RecordingStore();
        final service = GeneratedSubtitleTranslationService(
          store: store,
          translate:
              (
                text, {
                sourceLang,
                required throwOnFailure,
                onProgress,
                targetLocale,
              }) async {
                expect(text, 'こんにちは\n物語');
                expect(sourceLang, 'ja');
                expect(throwOnFailure, isTrue);
                expect(targetLocale, const Locale('en'));
                onProgress?.call(1, 1);
                return 'Hello\nStory';
              },
        );
        final progress = <double>[];
        final result = await service.translate(
          original.path,
          saveTranslation: save,
          targetLocale: const Locale('en'),
          cancelToken: CancelToken(),
          onProgress: progress.add,
        );
        expect(result.translated.map((line) => line.text), ['Hello', 'Story']);
        expect(result.original.map((line) => line.text), ['こんにちは', '物語']);
        expect(result.targetLocale, const Locale('en'));
        expect(store.savedTarget, save ? const Locale('en') : isNull);
        final originalTimes = LyricParser.parse(
          srt,
        ).map((line) => (line.startTime, line.endTime)).toList();
        expect(
          result.translated.map((line) => (line.startTime, line.endTime)),
          originalTimes,
        );
        expect(await original.readAsString(), srt);
        expect(store.saved, save ? isNotNull : isNull);
        if (save) {
          expect(
            LyricParser.parse(
              store.saved!,
            ).map((line) => (line.startTime, line.endTime)),
            originalTimes,
          );
        }
        expect(result.savedPath, save ? '${original.path}.translated' : isNull);
        expect(progress, [1.0]);
      },
    );
  }

  test(
    'a missing translated cue fails without saving a mixed original result',
    () async {
      final store = _RecordingStore();
      final service = GeneratedSubtitleTranslationService(
        store: store,
        translate:
            (
              _, {
              sourceLang,
              required throwOnFailure,
              onProgress,
              targetLocale,
            }) async => 'Hello',
      );
      await expectLater(
        service.translate(
          original.path,
          saveTranslation: true,
          targetLocale: const Locale('en'),
          cancelToken: CancelToken(),
          onProgress: (_) {},
        ),
        throwsFormatException,
      );
      expect(store.saved, isNull);
      expect(await original.readAsString(), srt);
    },
  );

  test(
    'cancellation during the request prevents publishing and saving',
    () async {
      final store = _RecordingStore();
      final started = Completer<void>();
      final response = Completer<String>();
      final token = CancelToken();
      final service = GeneratedSubtitleTranslationService(
        store: store,
        translate:
            (
              _, {
              sourceLang,
              required throwOnFailure,
              onProgress,
              targetLocale,
            }) {
              started.complete();
              return response.future;
            },
      );
      final result = service.translate(
        original.path,
        saveTranslation: true,
        targetLocale: const Locale('en'),
        cancelToken: token,
        onProgress: (_) {},
      );
      await started.future;
      token.cancel();
      response.complete('Hello\nStory');
      await expectLater(result, throwsA(isA<DioException>()));
      expect(store.saved, isNull);
      expect(await original.readAsString(), srt);
    },
  );
}

class _RecordingStore extends GeneratedSubtitleStore {
  String? saved;
  Locale? savedTarget;

  @override
  Future<String> saveTranslation(
    String originalPath,
    String srt, {
    required CancelToken cancelToken,
    required Locale targetLocale,
  }) async {
    saved = srt;
    savedTarget = targetLocale;
    return '$originalPath.translated';
  }
}

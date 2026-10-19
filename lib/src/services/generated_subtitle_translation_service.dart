import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';

import '../models/lyric.dart';
import 'generated_subtitle_store.dart';
import 'translation_service.dart';

class GeneratedSubtitleTranslation {
  const GeneratedSubtitleTranslation({
    required this.original,
    required this.translated,
    required this.targetLocale,
    this.savedPath,
  });

  final List<LyricLine> original;
  final List<LyricLine> translated;
  final String? savedPath;
  final Locale targetLocale;
}

typedef GeneratedSubtitleTranslator =
    Future<String> Function(
      String text, {
      String? sourceLang,
      required bool throwOnFailure,
      Locale? targetLocale,
      Function(int current, int total)? onProgress,
    });

typedef GeneratedSubtitleTranslationRunner =
    Future<GeneratedSubtitleTranslation> Function(
      String originalPath,
      CancelToken token,
      void Function(double) progress,
    );

class GeneratedSubtitleTranslationService {
  GeneratedSubtitleTranslationService({
    GeneratedSubtitleTranslator? translate,
    GeneratedSubtitleStore? store,
  }) : _translate = translate ?? TranslationService().translateLongText,
       _store = store ?? const GeneratedSubtitleStore();

  final GeneratedSubtitleTranslator _translate;
  final GeneratedSubtitleStore _store;

  Future<GeneratedSubtitleTranslation> translate(
    String originalPath, {
    required bool saveTranslation,
    required Locale targetLocale,
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    void checkCancelled() {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    }

    checkCancelled();
    final original = LyricParser.parse(await File(originalPath).readAsString());
    final indexes = <int>[];
    final texts = <String>[];
    for (var i = 0; i < original.length; i++) {
      final text = original[i].text;
      if (text.trim().isEmpty || text == '♪ - ♪') continue;
      indexes.add(i);
      texts.add(text.replaceAll(RegExp(r'[\r\n]+'), ' '));
    }
    if (texts.isEmpty) throw const FormatException('No subtitle text.');
    final joined = texts.join('\n');
    checkCancelled();
    final text = await _translate(
      joined,
      // The generation model is Japanese, including cues containing only Kanji.
      sourceLang: 'ja',
      throwOnFailure: true,
      targetLocale: targetLocale,
      onProgress: (current, total) {
        if (!cancelToken.isCancelled) onProgress(current / total);
      },
    );
    checkCancelled();
    final lines = text.trim().split(RegExp(r'\r?\n'));
    if (lines.length != texts.length ||
        lines.any((line) => line.trim().isEmpty)) {
      throw const FormatException(
        'Translation changed the subtitle line count.',
      );
    }
    final translated = List<LyricLine>.of(original);
    for (var i = 0; i < indexes.length; i++) {
      translated[indexes[i]] = original[indexes[i]].copyWith(text: lines[i]);
    }
    final savedPath = saveTranslation
        ? await _store.saveTranslation(
            originalPath,
            toSrt(translated),
            cancelToken: cancelToken,
            targetLocale: targetLocale,
          )
        : null;
    checkCancelled();
    return GeneratedSubtitleTranslation(
      original: original,
      translated: translated,
      savedPath: savedPath,
      targetLocale: targetLocale,
    );
  }

  static String toSrt(List<LyricLine> lyrics) {
    String time(Duration value) {
      final hours = value.inHours.toString().padLeft(2, '0');
      final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
      final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
      final millis = (value.inMilliseconds % 1000).toString().padLeft(3, '0');
      return '$hours:$minutes:$seconds,$millis';
    }

    return [
      for (var i = 0; i < lyrics.length; i++)
        '${i + 1}\n${time(lyrics[i].startTime)} --> ${time(lyrics[i].endTime)}\n${lyrics[i].text}\n',
    ].join('\n');
  }
}

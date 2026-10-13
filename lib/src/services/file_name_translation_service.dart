import '../utils/file_tree_utils.dart';
import 'translation_service.dart';

typedef FileNameTranslator =
    Future<String> Function(String text, {String? sourceLang});
typedef LocalFileNameTranslator =
    Future<String?> Function(String text, {String? sourceLang});
typedef FileNameTranslationDelay = Future<void> Function(Duration duration);
typedef FileNameTranslationProgress = void Function(int current, int total);
typedef FileNameTranslationError = void Function(int index, Object error);

class FileNameTranslationResult {
  const FileNameTranslationResult({
    required this.names,
    required this.translations,
  });

  final List<String> names;
  final Map<String, String> translations;

  bool get isEmpty => names.isEmpty;
}

class FileNameTranslationService {
  const FileNameTranslationService({
    required this.translate,
    this.convertLocally,
    this.delay = _defaultDelay,
  });

  final FileNameTranslator translate;
  final LocalFileNameTranslator? convertLocally;
  final FileNameTranslationDelay delay;

  Future<FileNameTranslationResult> translateFileTree({
    required List<dynamic> fileTree,
    String? sourceLang,
    int maxChunkSize = 500,
    Duration throttleDelay = const Duration(milliseconds: 300),
    FileNameTranslationProgress? onProgress,
    FileNameTranslationError? onChunkError,
  }) {
    return translateNames(
      names: FileTreeUtils.collectNames(fileTree),
      sourceLang: sourceLang,
      maxChunkSize: maxChunkSize,
      throttleDelay: throttleDelay,
      onProgress: onProgress,
      onChunkError: onChunkError,
    );
  }

  Future<FileNameTranslationResult> translateNames({
    required List<String> names,
    String? sourceLang,
    int maxChunkSize = 500,
    Duration throttleDelay = const Duration(milliseconds: 300),
    FileNameTranslationProgress? onProgress,
    FileNameTranslationError? onChunkError,
  }) async {
    final uniqueNames = names
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniqueNames.isEmpty) {
      return const FileNameTranslationResult(names: [], translations: {});
    }

    final translations = {for (final name in uniqueNames) name: name};
    final namesBySource = <String?, List<String>>{};
    for (final name in uniqueNames) {
      final nameSourceLang = TranslationService.sourceLanguageForText(
        name,
        sourceLang: sourceLang,
      );
      final localConversion = await convertLocally?.call(
        name,
        sourceLang: nameSourceLang,
      );
      if (localConversion != null) {
        translations[name] = localConversion;
      } else {
        namesBySource.putIfAbsent(nameSourceLang, () => []).add(name);
      }
    }
    final chunks = <(String?, String)>[];
    for (final entry in namesBySource.entries) {
      chunks.addAll(
        splitNamesIntoChunks(
          entry.value,
          maxChunkSize: maxChunkSize,
        ).map((chunk) => (entry.key, chunk)),
      );
    }
    for (var i = 0; i < chunks.length; i++) {
      onProgress?.call(i + 1, chunks.length);

      try {
        final (chunkSourceLang, chunk) = chunks[i];
        final chunkNames = chunk.split('\n');
        final translated = await translate(chunk, sourceLang: chunkSourceLang);
        final translatedNames = translated.trim().split(RegExp(r'\r?\n'));
        if (translatedNames.length != chunkNames.length ||
            translatedNames.any((name) => name.trim().isEmpty)) {
          throw const FormatException(
            'Filename translation lines do not match',
          );
        }
        for (var j = 0; j < chunkNames.length; j++) {
          translations[chunkNames[j]] = translatedNames[j];
        }
      } catch (e) {
        onChunkError?.call(i, e);
      }

      if (i < chunks.length - 1) {
        await delay(throttleDelay);
      }
    }

    return FileNameTranslationResult(
      names: uniqueNames,
      translations: translations,
    );
  }

  static List<String> splitNamesIntoChunks(
    List<String> names, {
    required int maxChunkSize,
  }) {
    final chunks = <String>[];
    var currentChunk = '';

    for (final name in names) {
      final separator = currentChunk.isEmpty ? '' : '\n';
      final estimatedLength =
          currentChunk.length + separator.length + name.length;

      if (estimatedLength > maxChunkSize && currentChunk.isNotEmpty) {
        chunks.add(currentChunk);
        currentChunk = name;
      } else {
        currentChunk += separator + name;
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk);
    }

    return chunks;
  }

  static Future<void> _defaultDelay(Duration duration) {
    return Future.delayed(duration);
  }
}

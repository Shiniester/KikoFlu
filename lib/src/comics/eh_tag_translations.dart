import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/chinese_script_converter.dart';

const _databaseUrl =
    'https://raw.githubusercontent.com/EhTagTranslation/DatabaseReleases/master/db.text.json.gz';
const _cacheKey = 'eh-tag-translations-v1';

final ehTagTranslationsProvider = StreamProvider<Map<String, String>>((ref) {
  final cache = DefaultCacheManager();
  return ehTagTranslationsFromFileStream(
    getFileStream: () => cache.getFileStream(_databaseUrl, key: _cacheKey),
    removeCachedFile: () => cache.removeFile(_cacheKey),
  );
});

String ehTagLabel(String tag, Map<String, String> translations) {
  final separator = tag.indexOf(':');
  if (separator < 0) return tag;

  final originalNamespace = tag.substring(0, separator);
  if (originalNamespace.isEmpty) return tag;
  final namespace = switch (originalNamespace.toLowerCase()) {
    'category' => 'reclass',
    final value => value,
  };
  final originalName = tag.substring(separator + 1);
  final translatedName = translations[_translationKey(namespace, originalName)];
  if (translatedName == null) return tag;

  final translatedNamespace = translations['rows:$namespace'];
  return '${translatedNamespace ?? originalNamespace}:$translatedName';
}

final _traditionalEhTagLabelProvider = FutureProvider.autoDispose
    .family<String, String>(
      (ref, label) => convertChineseScript(label, toTraditional: true),
    );

Widget buildEhTagLabel({
  required BuildContext context,
  required String tag,
  required Map<String, String>? translations,
  required Widget Function(String label) builder,
}) {
  final translated = translations == null ? tag : ehTagLabel(tag, translations);
  if (translated == tag) return builder(tag);
  final locale = Localizations.localeOf(context);
  final traditional =
      locale.languageCode == 'zh' &&
      (locale.scriptCode == 'Hant' ||
          const ['TW', 'HK', 'MO'].contains(locale.countryCode));
  if (!traditional) return builder(translated);
  return Consumer(
    builder: (context, ref, _) => builder(
      ref.watch(_traditionalEhTagLabelProvider(translated)).valueOrNull ?? tag,
    ),
  );
}

void retryEhTagTranslations(WidgetRef ref) {
  if (!ref.exists(ehTagTranslationsProvider)) return;
  final state = ref.read(ehTagTranslationsProvider);
  if (!state.isLoading && state.valueOrNull?.isEmpty == true) {
    ref.invalidate(ehTagTranslationsProvider);
  }
}

@visibleForTesting
Stream<Map<String, String>> ehTagTranslationsFromFileStream({
  required Stream<FileResponse> Function() getFileStream,
  required Future<void> Function() removeCachedFile,
}) async* {
  var latest = const <String, String>{};

  var canRetryCorruptFile = true;
  while (true) {
    var corruptFile = false;
    try {
      await for (final response in getFileStream().timeout(
        const Duration(seconds: 30),
      )) {
        if (response is! FileInfo) continue;
        try {
          latest = await compute(
            _parseEhTagDatabase,
            await response.file.readAsBytes(),
          );
          yield latest;
        } catch (_) {
          corruptFile = true;
          await removeCachedFile();
          break;
        }
      }
    } catch (_) {
      // Keep the empty or last valid translations when offline or unavailable.
    }

    if (!corruptFile || !canRetryCorruptFile) {
      if (latest.isEmpty) yield latest;
      return;
    }
    canRetryCorruptFile = false;
  }
}

Map<String, String> _parseEhTagDatabase(List<int> compressedJson) {
  final json = jsonDecode(
    utf8.decode(GZipDecoder().decodeBytes(compressedJson, verify: true)),
  );
  if (json is! Map || json['data'] is! List) {
    throw const FormatException('Invalid EhTagTranslation database.');
  }

  final translations = <String, String>{};
  for (final block in json['data'] as List) {
    if (block is! Map ||
        block['namespace'] is! String ||
        block['data'] is! Map) {
      continue;
    }
    final namespace = (block['namespace'] as String).toLowerCase();
    for (final entry in (block['data'] as Map).entries) {
      final value = entry.value;
      if (value is Map &&
          value['name'] is String &&
          (value['name'] as String).isNotEmpty) {
        translations['$namespace:${entry.key.toString().toLowerCase()}'] =
            value['name'] as String;
      }
    }
  }
  if (translations.isEmpty) {
    throw const FormatException('EhTagTranslation database has no names.');
  }
  return translations;
}

String _translationKey(String namespace, String tag) =>
    '${namespace.toLowerCase()}:${tag.toLowerCase().replaceAll('_', ' ')}';

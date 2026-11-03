import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/comics/eh_tag_translations.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('eh-tags-test-');
  });

  tearDown(() async {
    await for (final entry in tempDirectory.list()) {
      await entry.delete();
    }
    await tempDirectory.delete();
  });

  Future<FileInfo> fileResponse(String name, List<int> bytes) async {
    final file = File('${tempDirectory.path}/$name');
    await file.writeAsBytes(bytes);
    return FileInfo(
      const LocalFileSystem().file(file.path),
      FileSource.Cache,
      DateTime.utc(2099),
      'https://example.test/$name',
    );
  }

  Future<Map<String, String>> loadTranslations(List<int> compressedJson) async {
    final response = await fileResponse('database.gz', compressedJson);
    return ehTagTranslationsFromFileStream(
      getFileStream: () => Stream.value(response),
      removeCachedFile: () async {},
    ).last;
  }

  test('parses gzip JSON and keeps namespace-specific translations', () async {
    final translations = await loadTranslations(_validDatabase());

    expect(translations['female:blue eyes'], '蓝眼');
    expect(translations['male:blue eyes'], '男性蓝眼');
    expect(translations['rows:language'], '语言');
    expect(ehTagLabel('female:blue_eyes', translations), '女性:蓝眼');
    expect(ehTagLabel('male:blue_eyes', translations), '男性:男性蓝眼');
    expect(ehTagLabel('category:artistic nudity', translations), '重新分类:艺术裸露');
  });

  test('preserves unclassified, bare, and unknown tags', () async {
    final translations = await loadTranslations(_validDatabase());

    expect(ehTagLabel(':bare_tag', translations), ':bare_tag');
    expect(ehTagLabel('bare_tag', translations), 'bare_tag');
    expect(ehTagLabel('unknown:blue_eyes', translations), 'unknown:blue_eyes');
    expect(
      ehTagLabel('female:missing_tag', translations),
      'female:missing_tag',
    );
  });

  test('keeps stale cached translations when refresh fails offline', () async {
    final cached = await fileResponse('cached.gz', _validDatabase());
    var removed = false;

    final events = await ehTagTranslationsFromFileStream(
      getFileStream: () async* {
        yield cached;
        throw const SocketException('offline');
      },
      removeCachedFile: () async {
        removed = true;
      },
    ).toList();

    expect(events.last['female:blue eyes'], '蓝眼');
    expect(removed, isFalse);
  });

  test('does not emit an empty result while a request is pending', () async {
    final responses = StreamController<FileResponse>();
    final events = <Map<String, String>>[];
    final subscription = ehTagTranslationsFromFileStream(
      getFileStream: () => responses.stream,
      removeCachedFile: () async {},
    ).listen(events.add);

    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    final completed = subscription.asFuture<void>();
    await responses.close();
    await completed;
    expect(events.single, isEmpty);
  });

  test('removes a corrupted cache and retries once', () async {
    final corrupted = await fileResponse('corrupt.gz', [0, 1, 2]);
    final valid = await fileResponse('valid.gz', _validDatabase());
    var requests = 0;
    var removals = 0;

    final translations = await ehTagTranslationsFromFileStream(
      getFileStream: () => Stream.value(++requests == 1 ? corrupted : valid),
      removeCachedFile: () async {
        removals++;
      },
    ).last;

    expect(requests, 2);
    expect(removals, 1);
    expect(translations['female:blue eyes'], '蓝眼');
  });

  test(
    'returns empty translations when the first offline request fails',
    () async {
      final translations = await ehTagTranslationsFromFileStream(
        getFileStream: () =>
            Stream<FileResponse>.error(const SocketException('offline')),
        removeCachedFile: () async {},
      ).last;

      expect(translations, isEmpty);
    },
  );
}

List<int> _validDatabase() => GZipEncoder().encode(
  utf8.encode(
    jsonEncode({
      'data': [
        {
          'namespace': 'female',
          'data': {
            'blue eyes': {'name': '蓝眼'},
          },
        },
        {
          'namespace': 'male',
          'data': {
            'blue eyes': {'name': '男性蓝眼'},
          },
        },
        {
          'namespace': 'reclass',
          'data': {
            'artistic nudity': {'name': '艺术裸露'},
          },
        },
        {
          'namespace': 'rows',
          'data': {
            'female': {'name': '女性'},
            'male': {'name': '男性'},
            'language': {'name': '语言'},
            'reclass': {'name': '重新分类'},
          },
        },
      ],
    }),
  ),
)!;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/comics/comic_http.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/sources/jm_source.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final String Function(RequestOptions request) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      respond(options),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  test(
    'replaces the retired default endpoint and preserves custom endpoints',
    () async {
      await StorageService.setString(
        'comic_jmcomic_endpoint',
        'https://www.cdntwice.org',
      );
      final http = ComicHttp('jmcomic', client: Dio());
      final source = JmSource(http);
      addTearDown(http.dispose);

      expect(source.website, 'https://www.cdnhjk.net');

      await StorageService.setString(
        'comic_jmcomic_endpoint',
        'https://jm.custom.example',
      );
      expect(source.website, 'https://jm.custom.example');
    },
  );

  test(
    'loads anonymous image settings once per endpoint and accepts latest lists',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.path == '/setting') {
          final host = request.uri.host == 'www.cdnhjk.net'
              ? 'https://images-first.example'
              : 'https://images-custom.example';
          return jsonEncode({
            'code': 200,
            'data': {'img_host': host, 'jm3_version': '2.1.9'},
          });
        }
        if (request.uri.path == '/latest') {
          final page = request.uri.queryParameters['page'];
          final items = page == '3'
              ? <Map<String, dynamic>>[]
              : [
                  {
                    'id': 'comic-$page',
                    'name': 'Comic $page',
                    'description': 'Synopsis',
                  },
                ];
          return jsonEncode({'code': 200, 'data': items});
        }
        if (request.uri.path == '/album') {
          return jsonEncode({
            'code': 200,
            'data': {
              'name': 'Comic detail',
              'description': 'Synopsis',
              'series': [],
            },
          });
        }
        if (request.uri.path == '/chapter') {
          return jsonEncode({
            'code': 200,
            'data': {
              'images': ['001.webp'],
            },
          });
        }
        return jsonEncode({'code': 200, 'data': {}});
      });
      final http = ComicHttp(
        'jmcomic',
        client: Dio()..httpClientAdapter = adapter,
      );
      final source = JmSource(http);
      addTearDown(http.dispose);

      final first = await source.explore();
      expect(
        first.items.single.cover,
        'https://images-first.example/media/albums/comic-1_3x4.jpg',
      );
      expect(first.next, '2');

      final second = await source.explore(cursor: first.next);
      expect(second.items.single.id, 'comic-2');
      expect(second.next, '3');

      final empty = await source.explore(cursor: second.next);
      expect(empty.items, isEmpty);
      expect(empty.next, isNull);

      final comic = await source.details('comic-1');
      final page = (await source.pages(comic, comic.chapters.single)).single;
      expect(
        page.url,
        'https://images-first.example/media/photos/comic-1/001.webp',
      );
      expect(page.scrambleId, 220980);
      expect(adapter.requests.where((r) => r.uri.path == '/setting').length, 1);

      await StorageService.setString(
        'comic_jmcomic_endpoint',
        'https://jm.custom.example',
      );
      final custom = await source.explore();
      expect(
        custom.items.single.cover,
        'https://images-custom.example/media/albums/comic-1_3x4.jpg',
      );
      expect(
        adapter.requests
            .where((r) => r.uri.path == '/setting')
            .map((r) => r.uri.host),
        ['www.cdnhjk.net', 'jm.custom.example'],
      );
    },
  );

  test('retries anonymous settings after an endpoint error', () async {
    var settingsRequests = 0;
    final adapter = _Adapter((request) {
      if (request.uri.path == '/setting') {
        settingsRequests++;
        if (settingsRequests == 1) {
          return jsonEncode({
            'code': 503,
            'errorMsg': 'temporarily unavailable',
          });
        }
        return jsonEncode({
          'code': 200,
          'data': {'img_host': 'https://images.example'},
        });
      }
      return jsonEncode({
        'code': 200,
        'data': {
          'content': [
            {'id': 'comic-1', 'name': 'Comic'},
          ],
          'total': 1,
        },
      });
    });
    final http = ComicHttp(
      'jmcomic',
      client: Dio()..httpClientAdapter = adapter,
    );
    final source = JmSource(http);
    addTearDown(http.dispose);

    await expectLater(source.explore(), throwsA(isA<ComicSourceException>()));
    final result = await source.explore();

    expect(
      result.items.single.cover,
      'https://images.example/media/albums/comic-1_3x4.jpg',
    );
    expect(settingsRequests, 2);
  });
}

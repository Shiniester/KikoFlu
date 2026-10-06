import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/comics/comic_http.dart';
import 'package:kikoeru_flutter/src/comics/sources/hitomi_source.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final body = switch (options.uri.path) {
      '/galleryblock/42.html' =>
        '''<picture><source data-srcset="//tn.gold-usergeneratedcontent.net/avifbigtn/4/12/hash.avif 1x"></picture>
        <h1 class="lillie"><a>Book</a></h1>''',
      '/galleries/42.js' =>
        'var galleryinfo = {"files": [{"hash": "0123456789abcdef"}], "tags": []};',
      '/gg.js' => "var o = 0; switch(g){case 123:} b: '123/'",
      _ => 'ok',
    };
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Object? _header(RequestOptions request, String name) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Hitomi covers inherit Referer and pages keep their own', () async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    final adapter = _Adapter();
    final source = HitomiSource(
      ComicHttp('hitomi', client: Dio()..httpClientAdapter = adapter),
    );
    addTearDown(source.http.dispose);

    final comic = await source.details('42');
    expect(
      comic.cover,
      'https://atn.gold-usergeneratedcontent.net/webpbigtn/4/12/hash.webp',
    );
    await source.http.bytes(comic.coverPage.url);
    expect(_header(adapter.requests.last, 'Referer'), 'https://hitomi.la/');

    final page = (await source.pages(comic, comic.chapters.single)).single;
    await source.http.bytes(page.url, headers: page.headers);
    expect(
      _header(adapter.requests.last, 'Referer'),
      'https://hitomi.la/reader/42.html',
    );
  });
}

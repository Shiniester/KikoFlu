import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/comics/comic_http.dart';
import 'package:kikoeru_flutter/src/comics/comic_images.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/sources/eh_source.dart';
import 'package:kikoeru_flutter/src/comics/sources/ht_source.dart';
import 'package:kikoeru_flutter/src/comics/sources/nh_source.dart';
import 'package:kikoeru_flutter/src/comics/sources/hitomi_source.dart';
import 'package:kikoeru_flutter/src/comics/sources/pica_source.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_search_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_reader_screen.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  String Function(RequestOptions)? respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      respond?.call(options) ?? '{}',
      status,
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
    SharedPreferences.setMockInitialValues({
      'server_cookie': 'audio=secret',
      'auth_token': 'audio-token',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });
  test(
    'source cookies stay on their site and never use audio credentials',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final http = ComicHttp('nhentai', client: dio);
      await http.saveSession(cookie: 'access_token=nh; refresh_token=refresh');
      await http.json('https://nhentai.net/api/v2/favorites');
      await http.bytes('https://i.nhentai.net/1.jpg');
      expect(
        adapter.requests.first.headers['Cookie'],
        'access_token=nh; refresh_token=refresh',
      );
      expect(adapter.requests.last.headers['Cookie'], isNull);
      expect(
        adapter.requests.first.headers.values.join(),
        isNot(contains('audio-token')),
      );
      http.dispose();
    },
  );
  test(
    'logout drops source token and cookies without clearing audio',
    () async {
      final adapter = _Adapter();
      final http = ComicHttp(
        'picacg',
        client: Dio()..httpClientAdapter = adapter,
      );
      await http.saveSession(token: 'pica', cookie: 'sid=pica');
      await http.clearSession();
      await http.json('https://picaapi.picacomic.com/categories');
      expect(http.hasSession, false);
      expect(http.token, isNull);
      expect(adapter.requests.single.headers['Cookie'], isNull);
      expect(StorageService.getString('auth_token'), 'audio-token');
      http.dispose();
    },
  );
  test('403 becomes a local sign-in requirement', () async {
    final adapter = _Adapter()..status = 403;
    final http = ComicHttp(
      'nhentai',
      client: Dio()..httpClientAdapter = adapter,
    );
    await expectLater(
      http.json('https://nhentai.net/api/v2/favorites'),
      throwsA(
        isA<ComicSourceException>().having(
          (e) => e.loginRequired,
          'login',
          true,
        ),
      ),
    );
    http.dispose();
  });
  test('Pica metadata is available before its paginated chapters', () async {
    final adapter = _Adapter();
    adapter.respond = (request) {
      if (request.uri.path == '/comics/book') {
        return jsonEncode({
          'data': {
            'comic': {
              '_id': 'book',
              'title': 'Book',
              'description': 'Synopsis',
              'created_at': '2023-07-09T12:00:00Z',
              'updated_at': '2023-08-10T12:00:00Z',
              'thumb': {
                'fileServer': 'https://img.example',
                'path': 'cover.jpg',
              },
            },
          },
        });
      }
      final page = int.parse(request.uri.queryParameters['page']!);
      return jsonEncode({
        'data': {
          'eps': {
            'pages': 2,
            'docs': page == 1
                ? [
                    {'order': 2, 'title': 'Second'},
                  ]
                : [
                    {'order': 1, 'title': 'First'},
                  ],
          },
        },
      });
    };
    final source = PicaSource(
      ComicHttp('picacg', client: Dio()..httpClientAdapter = adapter),
    );
    addTearDown(source.http.dispose);
    final detail = await source.details('book');
    expect(detail.description, 'Synopsis');
    expect(detail.coverDate, '2023-08-10');
    expect(detail.chapters, isEmpty);
    expect(adapter.requests, hasLength(1));
    final chapters = await source.chapters(detail);
    expect(chapters.map((chapter) => chapter.title), ['First', 'Second']);
    expect(adapter.requests, hasLength(3));
  });
  test('NH v2 parses page paths and retains signed URLs', () {
    final comic = NhSource.parseComic({
      'id': 42,
      'title': {'english': 'A book'},
      'thumbnail': 'thumb.jpg',
      'upload_date': 1704067200,
      'tags': [
        {'type': 'language', 'name': 'english'},
      ],
      'pages': [
        {'path': '42/1.jpg?verify=a'},
      ],
    });
    expect(comic.id, '42');
    expect(comic.title, 'A book');
    expect(comic.cover, 'https://t.nhentai.net/thumb.jpg');
    expect(comic.coverDate, '2024-01-01');
    expect(
      NhSource.imageUrl((comic.extra['pages'] as List).first['path']),
      'https://i.nhentai.net/42/1.jpg?verify=a',
    );
  });
  test('EH preserves gallery token and the actual next cursor', () {
    final result = EhSource.parseListing(
      '''<table><tr><td><img src="https://ehgt.org/a.jpg"></td>
      <td class="gl2e"><div>
      <a href="https://e-hentai.org/g/42/abc123/"><div class="glink">Title 2020-01-01</div></a>
      <div class="gl3e"><div>2024-05-12 14:30</div></div></div></td></tr></table>
      <a id="dnext" href="/?next=42-abc">Next</a>''',
      'https://e-hentai.org',
    );
    expect(result.items.single.id, '42/abc123');
    expect(result.items.single.title, 'Title 2020-01-01');
    expect(result.items.single.coverDate, '2024-05-12');
    expect(result.next, 'https://e-hentai.org/?next=42-abc');
  });
  test('EH grid listings keep their source posting date', () {
    final result = EhSource.parseListing(
      '''<div class="gl1t"><a href="/g/43/gridtoken/"><div class="glink">Grid book 2021-03-04</div>
      <img src="/cover.jpg"></a><div class="gl5t"><div><div>2024-05-13 10:00</div></div></div></div>''',
      'https://e-hentai.org',
    );
    expect(result.items.single.coverDate, '2024-05-13');
  });
  test('EH minimal listings read date only from metadata', () {
    final result = EhSource.parseListing(
      '''<table><tr><td class="gl2m"><div>2024-05-14 08:00</div></td>
      <td><a href="/g/44/compacttoken/"><div class="glink">Book 2020-01-01</div></a></td></tr></table>''',
      'https://e-hentai.org',
    );
    expect(result.items.single.coverDate, '2024-05-14');
  });
  test('EH default compact listings read the posted date', () {
    final result = EhSource.parseListing(
      '''<table class="itg gltc"><tr><td class="gl2c">
      <div class="glthumb"><div><div><div id="postedpop_45">2021-01-01</div></div></div></div>
      <div><div id="posted_45">2024-05-15 09:00</div></div></td>
      <td class="gl3c glname"><a href="/g/45/defaulttoken/">
      <div class="glink">Book 2020-01-01</div></a></td></tr></table>''',
      'https://e-hentai.org',
    );
    expect(result.items.single.title, 'Book 2020-01-01');
    expect(result.items.single.coverDate, '2024-05-15');
  });
  test('HT online favorites use favorite record IDs, not comic IDs', () {
    final result = HtSource.parseFavorites(
      '''<div class="asTB"><div class="asTBcell thumb"><div><img src="//cdn.example/cover.jpg"></div></div>
      <div class="box_cel u_listcon"><p class="l_title"><a href="/photos-index-aid-42.html">Title</a></p>
      <p class="l_catg"><span>創建時間：2024/6/7</span></p>
      <p class="alopt"><a onclick="del('/users-fav_del-id-99.html')">Delete</a></p></div></div>''',
      'https://www.wnacg.com',
    );
    expect(result.items.single.id, '42');
    expect(result.items.single.extra['favoriteId'], '99');
    expect(result.items.single.coverDate, '2024-06-07');
  });
  test('HT listing keeps its source creation date', () {
    final result = HtSource.parseListing(
      '''<div class="gallary_wrap"><ul><li><div class="pic_box">
      <a href="/photos-index-aid-42.html"><img src="//cdn.example/cover.jpg"></a></div>
      <div class="info"><div class="title"><a>Title</a></div>
      <div class="info_col">2024-06-07, 12 pages</div></div></li></ul></div>''',
      'https://www.wnacg.com',
    );
    expect(result.items.single.coverDate, '2024-06-07');
  });
  test(
    'source dates normalize only real calendar dates and survive storage',
    () {
      const valid = Comic(
        source: 'fixture',
        id: '1',
        title: 'Dated',
        extra: {'sourceDate': 'Created: 2024/2/3 09:15'},
      );
      expect(valid.coverDate, '2024-02-03');
      expect(Comic.fromJson(valid.toJson()).coverDate, '2024-02-03');
      expect(
        const Comic(
          source: 'fixture',
          id: '2',
          title: 'Invalid',
          extra: {'sourceDate': '2024-02-30'},
        ).coverDate,
        isNull,
      );
      expect(
        const Comic(
          source: 'fixture',
          id: '3',
          title: 'Missing',
          extra: {'sourceDate': 0},
        ).coverDate,
        isNull,
      );
    },
  );
  test('Hitomi IDs are big endian and image shard is derived from gg', () {
    expect(
      HitomiSource.decodeIds(Uint8List.fromList([0, 0, 1, 0, 0, 0, 0, 42])),
      [256, 42],
    );
    final hash = '${List.filled(61, '0').join()}abc';
    final url = HitomiSource.imagePath(
      {'hash': hash, 'name': 'page.png', 'hasavif': 1},
      "var o = 0; switch(g){case 3243:} b: '123/'",
      'cdn.example',
    );
    expect(url, 'https://w2.cdn.example/123/3243/$hash.webp');
  });
  test('Hitomi listing and detail map source publication dates', () async {
    final adapter = _Adapter()
      ..respond = (request) => request.uri.path.endsWith('.nozomi')
          ? String.fromCharCodes([0, 0, 0, 42])
          : request.uri.path.endsWith('.html')
          ? '<h1 class="lillie"><a>Book</a></h1><div class="dj-content"><p>2024-01-02</p></div>'
          : 'var galleryinfo = {"date":"2024-03-04","files":[],"tags":[]};';
    final source = HitomiSource(
      ComicHttp('hitomi', client: Dio()..httpClientAdapter = adapter),
    );
    addTearDown(source.http.dispose);
    final listing = await source.explore();
    expect(listing.items.single.coverDate, '2024-01-02');
    final comic = await source.details('42');
    expect(comic.coverDate, '2024-03-04');
    expect(adapter.requests, hasLength(4));
  });
  test('JM reconstruction retains remainder rows', () {
    final input = img.Image(width: 2, height: 23);
    for (var y = 0; y < 23; y++) {
      for (var x = 0; x < 2; x++) {
        input.setPixelRgb(x, y, y, 0, 0);
      }
    }
    final decoded = img.decodeImage(
      decodeJmImage((
        Uint8List.fromList(img.encodePng(input)),
        'https://cdn.example/media/photos/230000/00001.jpg',
        220980,
      )),
    )!;
    expect(
      [for (var y = 0; y < 23; y++) decoded.getPixel(0, y).r.toInt()],
      [
        18,
        19,
        20,
        21,
        22,
        16,
        17,
        14,
        15,
        12,
        13,
        10,
        11,
        8,
        9,
        6,
        7,
        4,
        5,
        2,
        3,
        0,
        1,
      ],
    );
  });
  test(
    'comic identity is source-qualified and chapter serialization survives restart',
    () {
      const first = Comic(
        source: 'picacg',
        id: '42',
        title: 'A',
        chapters: [ComicChapter('2', 'Chapter 2')],
      );
      const second = Comic(source: 'nhentai', id: '42', title: 'B');
      expect(first.key, isNot(second.key));
      expect(
        Comic.fromJson(
          jsonDecode(jsonEncode(first.toJson())),
        ).chapters.single.id,
        '2',
      );
    },
  );
  test('merged results interleave sources without dropping their tails', () {
    Comic comic(String source, String id) =>
        Comic(source: source, id: id, title: id);
    final result = interleaveComicResults([
      [comic('a', '1'), comic('a', '2')],
      [comic('b', '1')],
      [],
    ]);
    expect(result.map((c) => '${c.source}${c.id}'), ['a1', 'b1', 'a2']);
  });
  test('six modes map display indices to real pages', () {
    for (final mode in ComicReadingMode.values) {
      final view = comicViewIndex(5, mode);
      final page = comicPageIndex(view, mode);
      expect(page, isComicSpread(mode) ? 4 : 5);
    }
  });
}

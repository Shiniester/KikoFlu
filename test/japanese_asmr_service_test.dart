import 'dart:async';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/services/japanese_asmr_service.dart';
import 'package:kikoeru_flutter/src/services/proxy_config.dart';
import 'package:kikoeru_flutter/src/utils/tag_localizer.dart';

const _verificationChannel = MethodChannel(
  'com.meteor.kikoeruflutter/japanese_asmr',
);

class _Adapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  _Adapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _page(
  String body, {
  int statusCode = 200,
  Map<String, List<String>>? headers,
}) => ResponseBody.fromString(
  body,
  statusCode,
  headers: {
    'content-type': ['text/html; charset=utf-8'],
    ...?headers,
  },
);

String _card(int id) =>
    '''
<li class="site-archive-post">
<p class="entry-tagline"><time datetime="2026-10-08"></time>
<a rel="category tag" href="/category/rating/sfw/">SFW</a>
<a rel="category tag" href="/category/studio/">Studio</a></p>
<h2 class="entry-title"><a href="https://japaneseasmr.com/$id/">Work $id</a></h2>
<div class="op-square"><img src="data:image/svg+xml,placeholder"
data-src="https://images.example/$id.jpg"></div>
<p>[RJ00000001]</p><p>CV: Voice</p></li>''';

const _detail = '''
<main class="site-main"><h1 class="page-title">A &amp; B</h1>
<p id="work_title_jp">[RJ00000001] A &amp; B</p>
<p id="voice_actors">CV: Voice One, Voice Two</p>
<div class="fotorama"><a id="img_cover" href="https://images.example/cover.jpg"></a>
<a href="https://images.example/art.jpg"></a></div>
<div id="jp-desc">Work description</div>
<div id="cleanp_audio"><video><source src="https://media.example/work.m3u8"></video></div>
<p id="downloadlink"><a href="https://japaneseasmr.com/dlc.php?f=RJ00000001">Download</a></p>
<video><source src="https://ads.example/ad.mp4"></video>
</main>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(_verificationChannel, null),
  );

  test(
    'repaginates native catalog pages without missing or repeating works',
    () async {
      final adapter = _Adapter((request) {
        final page = request.uri.path == '/' ? 1 : 2;
        final start = page == 1 ? 1 : 15;
        final end = page == 1 ? 14 : 23;
        return _page(
          '<main class="site-main">'
          '${[for (var i = start; i <= end; i++) _card(i)].join()}'
          '${page == 1 ? '<a class="next page-numbers">Next</a><a class="page-numbers">2</a>' : ''}'
          '</main>',
        );
      });
      final service = JapaneseAsmrService(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final first = await service.getWorks(page: 1, pageSize: 20);
      final second = await service.getWorks(page: 2, pageSize: 20);
      expect((first['works'] as List).map((w) => w['id']), [
        for (var i = 1; i <= 20; i++) -i,
      ]);
      expect((second['works'] as List).map((w) => w['id']), [-21, -22, -23]);
      expect(first['pagination']['totalCount'], 23);
      final work = Work.fromJson(first['works'][0]);
      expect(work.displayId, 'RJ00000001');
      expect(work.circleTitle, 'Studio');
      expect(work.vas!.single.name, 'Voice');
    },
  );

  for (final keyword in [null, '耳かき & voice']) {
    test(
      'counts the partial final native page for ${keyword == null ? 'browse' : 'search'}',
      () async {
        final adapter = _Adapter((request) {
          if (request.uri.queryParameters.containsKey('s')) {
            return ResponseBody.fromString('Just a moment', 403);
          }
          final pageMarker = request.uri.pathSegments.indexOf('page');
          final page = pageMarker == -1
              ? 1
              : int.parse(request.uri.pathSegments[pageMarker + 1]);
          final start = (page - 1) * 14 + 1;
          final end = page == 3 ? 29 : page * 14;
          return _page(
            '<main class="site-main">'
            '${[for (var i = start; i <= end; i++) _card(i)].join()}'
            '${page < 3 ? '<a class="next page-numbers">Next</a><a class="page-numbers">3</a>' : ''}'
            '</main>',
          );
        });
        final service = JapaneseAsmrService(
          dio: Dio()..httpClientAdapter = adapter,
        );
        Future<Map<String, dynamic>> load(int page) => keyword == null
            ? service.getWorks(page: page, pageSize: 20)
            : service.searchWorks(keyword: keyword, page: page, pageSize: 20);
        final first = await load(1);
        expect(first['pagination']['totalCount'], 29);
        expect((first['pagination']['totalCount'] / 20).ceil(), 2);
        expect((first['works'] as List).map((w) => w['id']), [
          for (var i = 1; i <= 20; i++) -i,
        ]);
        final expectedPaths = keyword == null
            ? [
                [],
                ['page', '2'],
                ['page', '3'],
              ]
            : [
                ['search', keyword],
                ['search', keyword, 'page', '2'],
                ['search', keyword, 'page', '3'],
              ];
        expect(
          adapter.requests.map(
            (r) => r.uri.pathSegments.where((s) => s.isNotEmpty).toList(),
          ),
          expectedPaths,
        );
        final second = await load(2);
        expect(second['pagination']['totalCount'], 29);
        expect((second['works'] as List).map((w) => w['id']), [
          for (var i = 21; i <= 29; i++) -i,
        ]);
        expect(adapter.requests, hasLength(5));
        expect(
          adapter.requests.every((r) => r.uri.queryParameters.isEmpty),
          isTrue,
        );
      },
    );
  }

  test('rejects a challenge when reading the final native page', () async {
    final adapter = _Adapter(
      (request) => _page(
        request.uri.path == '/page/3/'
            ? '<h1>Just a moment...</h1>'
            : '<main class="site-main">${_card(1)}'
                  '<a class="next page-numbers">Next</a>'
                  '<a class="page-numbers">3</a></main>',
      ),
    );
    final service = JapaneseAsmrService(
      dio: Dio()..httpClientAdapter = adapter,
    );
    await expectLater(
      service.getWorks(page: 1, pageSize: 20),
      throwsFormatException,
    );
  });

  test('identifies a Cloudflare challenge returned with HTTP 403', () async {
    final adapter = _Adapter(
      (_) => _page(
        '<html><title>Just a moment</title></html>',
        statusCode: 403,
        headers: {
          'cf-mitigated': ['challenge'],
        },
      ),
    );
    final service = JapaneseAsmrService(
      dio: Dio()..httpClientAdapter = adapter,
    );
    await expectLater(
      service.getWorks(page: 1, pageSize: 20),
      throwsA(
        isA<Object>().having(
          (error) => error.toString(),
          'error string',
          contains('[jp-asmr-verification-required]'),
        ),
      ),
    );
  });

  test(
    'does not treat the normal Cloudflare telemetry script as a challenge',
    () async {
      final adapter = _Adapter(
        (_) => _page(
          '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>'
          '<main class="site-main"></main>',
        ),
      );
      final service = JapaneseAsmrService(
        dio: Dio()..httpClientAdapter = adapter,
      );
      await expectLater(service.getWorks(page: 1, pageSize: 20), completes);
    },
  );

  test('identifies an HTTP 200 Cloudflare interstitial body', () async {
    final adapter = _Adapter(
      (_) => _page(
        '<script>window._cf_chl_opt = {}</script>'
        '<main class="site-main"></main>',
      ),
    );
    final service = JapaneseAsmrService(
      dio: Dio()..httpClientAdapter = adapter,
    );
    await expectLater(
      service.getWorks(page: 1, pageSize: 20),
      throwsA(
        isA<Object>().having(
          (error) => error.toString(),
          'error string',
          contains('[jp-asmr-verification-required]'),
        ),
      ),
    );
  });

  test('preserves an unrelated HTTP 403 as a DioException', () async {
    final adapter = _Adapter(
      (_) => _page('<h1>Forbidden</h1>', statusCode: 403),
    );
    final service = JapaneseAsmrService(
      dio: Dio()..httpClientAdapter = adapter,
    );
    await expectLater(
      service.getWorks(page: 1, pageSize: 20),
      throwsA(
        isA<DioException>().having(
          (error) => error.response?.statusCode,
          'statusCode',
          403,
        ),
      ),
    );
  });

  test(
    'uses the verified cookie and user agent only for Japanese ASMR',
    () async {
      final previousMode = ProxyConfig.mode;
      final previousAddress = ProxyConfig.address;
      addTearDown(() {
        ProxyConfig.mode = previousMode;
        ProxyConfig.address = previousAddress;
      });
      ProxyConfig.mode = ProxyMode.manual;
      ProxyConfig.address = '127.0.0.1:7890';
      final verificationCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_verificationChannel, (call) async {
        verificationCalls.add(call);
        return {'cookie': 'cf_clearance=verified', 'userAgent': 'Browser UA'};
      });
      final adapter = _Adapter((request) {
        if (request.uri.host == 'japaneseasmr.com') {
          return _page('<main class="site-main"></main>');
        }
        if (request.uri.path == '/full') {
          return _page(
            '<a class="download-btn" hx-get="/full/download">Download</a>',
          );
        }
        return _page(
          '',
          headers: {
            'hx-redirect': ['https://media.example/full.m4a'],
          },
        );
      });
      final service = JapaneseAsmrService(
        dio: Dio(
          BaseOptions(
            headers: {
              'Authorization': 'Bearer private',
              'Cookie': 'session=private',
            },
          ),
        )..httpClientAdapter = adapter,
      );

      expect(
        await service.verifyAccess(title: 'Verify', closeLabel: 'Close'),
        isTrue,
      );
      expect(verificationCalls.single.method, 'verify');
      expect(verificationCalls.single.arguments, {
        'url': 'https://japaneseasmr.com/',
        'proxyMode': 'manual',
        'proxyAddress': ProxyConfig.httpsProxyUrl,
        'title': 'Verify',
        'closeLabel': 'Close',
      });

      await service.getWorks(page: 1, pageSize: 20);
      await expectLater(
        service.resolveDownloadUrl(
          'http://japaneseasmr.com/dlc.php?f=RJ00000001',
        ),
        throwsFormatException,
      );
      await service.resolveDownloadUrl('https://buzzheavier.com/full');

      final japaneseRequest = adapter.requests.first;
      expect(japaneseRequest.headers['Cookie'], 'cf_clearance=verified');
      expect(japaneseRequest.headers['User-Agent'], 'Browser UA');
      expect(
        japaneseRequest.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')),
      );
      final insecureJapaneseRequest = adapter.requests[1];
      expect(insecureJapaneseRequest.uri.scheme, 'http');
      expect(
        insecureJapaneseRequest.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains(anyOf('cookie', 'user-agent'))),
      );
      for (final request in adapter.requests.skip(2)) {
        expect(request.uri.host, isNot('japaneseasmr.com'));
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains(anyOf('authorization', 'cookie'))),
        );
        expect(request.headers['User-Agent'], isNot('Browser UA'));
      }
    },
  );

  test(
    'keeps the previous verified session when verification is cancelled',
    () async {
      var callCount = 0;
      messenger.setMockMethodCallHandler(_verificationChannel, (call) async {
        callCount++;
        return callCount == 1
            ? {'cookie': 'cf_clearance=kept', 'userAgent': 'Browser UA'}
            : null;
      });
      final adapter = _Adapter((_) => _page('<main class="site-main"></main>'));
      final service = JapaneseAsmrService(
        dio: Dio()..httpClientAdapter = adapter,
      );
      expect(
        await service.verifyAccess(title: 'Verify', closeLabel: 'Close'),
        isTrue,
      );
      expect(
        await service.verifyAccess(title: 'Verify', closeLabel: 'Close'),
        isFalse,
      );
      await service.getWorks(page: 1, pageSize: 20);
      expect(adapter.requests.single.headers['Cookie'], 'cf_clearance=kept');
      expect(adapter.requests.single.headers['User-Agent'], 'Browser UA');
    },
  );

  test('rejects verification responses containing other cookies', () async {
    messenger.setMockMethodCallHandler(
      _verificationChannel,
      (call) async => {
        'cookie': 'session=private; cf_clearance=unexpected',
        'userAgent': 'Browser UA',
      },
    );
    final adapter = _Adapter((_) => _page('<main class="site-main"></main>'));
    final service = JapaneseAsmrService(
      dio: Dio()..httpClientAdapter = adapter,
    );
    expect(
      await service.verifyAccess(title: 'Verify', closeLabel: 'Close'),
      isFalse,
    );
    await service.getWorks(page: 1, pageSize: 20);
    expect(
      adapter.requests.single.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains(anyOf('cookie', 'user-agent'))),
    );
  });

  test('uses the browse route for an empty search keyword', () async {
    final adapter = _Adapter((_) => _page('<main class="site-main"></main>'));
    final service = JapaneseAsmrService(
      dio: Dio()..httpClientAdapter = adapter,
    );
    await service.searchWorks(keyword: '', page: 1, pageSize: 20);
    expect(adapter.requests.single.uri.path, '/');
    expect(adapter.requests.single.uri.queryParameters, isEmpty);
  });

  test(
    'keeps Japanese ASMR tag names outside the ASMR.ONE translation IDs',
    () async {
      final adapter = _Adapter(
        (_) => _page(
          _detail.replaceFirst(
            '</main>',
            '<a rel="tag">2026</a><a rel="tag">ASMR</a></main>',
          ),
        ),
      );
      final service = JapaneseAsmrService(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final work = Work.fromJson(await service.getWork(31));
      for (final locale in [
        const Locale('zh'),
        const Locale('en'),
        const Locale('ja'),
      ]) {
        expect(
          work.tags!.map(
            (tag) => TagLocalizer.localize(tag.id, tag.name, locale),
          ),
          ['2026', 'ASMR'],
        );
      }
    },
  );

  test(
    'encodes search path segments and never forwards audio account credentials',
    () async {
      final adapter = _Adapter((_) => _page('<main class="site-main"></main>'));
      final dio = Dio(
        BaseOptions(
          headers: {
            'Authorization': 'Bearer private',
            'Cookie': 'session=private',
          },
        ),
      )..httpClientAdapter = adapter;
      const keyword = '耳かき & voice #?/%+';
      await JapaneseAsmrService(
        dio: dio,
      ).searchWorks(keyword: keyword, page: 1, pageSize: 20);
      final request = adapter.requests.single;
      expect(request.uri.pathSegments.where((s) => s.isNotEmpty), [
        'search',
        keyword,
      ]);
      expect(request.uri.path, contains('%23%3F%2F%25'));
      expect(request.uri.path.endsWith('/'), isTrue);
      expect(request.uri.queryParameters, isEmpty);
      expect(request.uri.fragment, isEmpty);
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains(anyOf('authorization', 'cookie'))),
      );
    },
  );

  test(
    'normalizes detail identity and uses only the work player media',
    () async {
      final adapter = _Adapter((_) => _page(_detail));
      final service = JapaneseAsmrService(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final work = Work.fromJson(await service.getWork(31));
      final tracks = await service.getWorkTracks(31);
      expect(work.id, -31);
      expect(work.title, 'A & B');
      expect(work.sourceUrl, 'https://japaneseasmr.com/31/');
      expect(work.vas!.map((va) => va.name), ['Voice One', 'Voice Two']);
      expect(tracks.first['mediaStreamUrl'], 'https://media.example/work.m3u8');
      expect(
        tracks.first['mediaDownloadUrl'],
        contains('/dlc.php?f=RJ00000001'),
      );
      expect(tracks.first['hash'], 'jp-31-main');
      expect(tracks.where((t) => t['type'] == 'image'), hasLength(2));
      expect(adapter.requests, hasLength(1));
      await service.getWork(31, forceRefresh: true);
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'rejects a challenge page instead of returning an empty catalog',
    () async {
      final adapter = _Adapter((_) => _page('<h1>Just a moment...</h1>'));
      final service = JapaneseAsmrService(
        dio: Dio()..httpClientAdapter = adapter,
      );
      await expectLater(
        service.getWorks(page: 1, pageSize: 20),
        throwsFormatException,
      );
      await expectLater(service.getWork(31), throwsFormatException);
    },
  );

  test(
    'resolves full-work download through the host public download button',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.path == '/dlc.php') {
          return _page(
            '<a href="https://buzzheavier.com/chapter">RJ00000001 - 01.m4a</a>'
            '<a href="https://buzzheavier.com/full">RJ00000001.m4a</a>'
            '<a href="https://ads.example/tool.exe">tool.exe</a>',
          );
        }
        if (request.uri.path == '/full') {
          return _page(
            '<a class="download-btn" hx-get="/full/download?t=fresh">Download File</a>',
          );
        }
        expect(request.uri.path, '/full/download');
        expect(request.headers['HX-Request'], 'true');
        expect(request.headers['Referer'], 'https://buzzheavier.com/full');
        return _page(
          '',
          headers: {
            'hx-redirect': ['https://media.example/full.m4a?token=fresh'],
          },
        );
      });
      final service = JapaneseAsmrService(
        dio: Dio()..httpClientAdapter = adapter,
      );
      expect(
        await service.resolveDownloadUrl(
          'https://japaneseasmr.com/dlc.php?f=RJ00000001',
        ),
        'https://media.example/full.m4a?token=fresh',
      );
    },
  );

  test(
    'cancels an in-flight download resolution without following more links',
    () async {
      final started = Completer<void>();
      final adapter = _Adapter((request) async {
        started.complete();
        await request.cancelToken!.whenCancel;
        return _page(
          '<a href="https://buzzheavier.com/full">RJ00000001.m4a</a>',
        );
      });
      final service = JapaneseAsmrService(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final cancelToken = CancelToken();
      final result = service.resolveDownloadUrl(
        'https://japaneseasmr.com/dlc.php?f=RJ00000001',
        cancelToken: cancelToken,
      );
      final check = expectLater(
        result,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await started.future;
      cancelToken.cancel();
      await check;
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'rejects unavailable downloads and HLS manifests as offline files',
    () async {
      final adapter = _Adapter((_) => _page('<h1>No download</h1>'));
      final service = JapaneseAsmrService(
        dio: Dio()..httpClientAdapter = adapter,
      );
      await expectLater(
        service.resolveDownloadUrl('https://buzzheavier.com/full'),
        throwsFormatException,
      );
      await expectLater(
        service.resolveDownloadUrl('https://media.example/work.m3u8'),
        throwsFormatException,
      );
    },
  );
}

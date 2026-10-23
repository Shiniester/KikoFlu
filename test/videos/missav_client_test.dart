import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_browser_adapter.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  int closeCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {
    closeCalls++;
  }
}

class _CancelAwareAdapter extends _Adapter {
  _CancelAwareAdapter(super.respond);

  int cancelledFetches = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final cancelError = options.cancelToken?.cancelError;
    if (cancelError != null) {
      cancelledFetches++;
      throw cancelError;
    }
    requests.add(options);
    return respond(options);
  }
}

class _BlockingRequestTransformer implements Transformer {
  _BlockingRequestTransformer(this.started, this.release);

  final Completer<void> started;
  final Future<void> release;
  final FusedTransformer _delegate = FusedTransformer.sync();

  @override
  Future<String> transformRequest(RequestOptions options) async {
    if (!started.isCompleted) started.complete();
    await release;
    return _delegate.transformRequest(options);
  }

  @override
  Future<dynamic> transformResponse(
    RequestOptions options,
    ResponseBody responseBody,
  ) => _delegate.transformResponse(options, responseBody);
}

class _MemorySecureStorage implements FlutterSecureStorage {
  static const cookieKey = 'missav_session_cookie';

  final values = <String, String>{};
  Future<void> Function()? beforeWrite;

  String? get cookie => values[cookieKey];

  set cookie(String? value) {
    if (value == null) {
      values.remove(cookieKey);
    } else {
      values[cookieKey] = value;
    }
  }

  Future<void> _write(String key, String? value) async {
    await beforeWrite?.call();
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.memberName;
    if (key == #read) {
      return Future<String?>.value(
        values[invocation.namedArguments[#key] as String],
      );
    }
    if (key == #write) {
      return _write(
        invocation.namedArguments[#key] as String,
        invocation.namedArguments[#value] as String?,
      );
    }
    if (key == #delete) {
      values.remove(invocation.namedArguments[#key] as String);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

ResponseBody _response(
  String body, {
  int statusCode = HttpStatus.ok,
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  body,
  statusCode,
  headers: {
    'content-type': ['text/html; charset=utf-8'],
    ...headers,
  },
);

String _cookieHeader(RequestOptions options) {
  final values = options.headers.entries
      .where((entry) => entry.key.toLowerCase() == 'cookie')
      .map((entry) => '${entry.value}')
      .toList();
  return values.isEmpty ? '' : values.first;
}

String? _headerValue(RequestOptions options, String name) {
  for (final entry in options.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return '${entry.value}';
    }
  }
  return null;
}

bool _hasHeader(Iterable<String> names, String name) =>
    names.any((candidate) => candidate.toLowerCase() == name.toLowerCase());

void main() {
  group('VideoItem', () {
    test('round-trips its stable fields', () {
      const item = VideoItem(
        id: 'sample-001',
        title: 'Sample video',
        pageUrl: 'https://missav.ai/sample-001',
        cover: 'https://media.example/cover.jpg',
        durationSeconds: 90,
      );

      expect(VideoItem.fromJson(item.toJson()).toJson(), item.toJson());
    });

    test('uses empty cover and nullable duration defaults', () {
      const item = VideoItem(
        id: 'sample-001',
        title: 'Sample video',
        pageUrl: 'https://missav.ai/sample-001',
      );

      expect(item.cover, '');
      expect(item.durationSeconds, isNull);
    });
  });

  test('unknown video link kinds remain readable as other', () {
    final link = VideoLink.fromJson({
      'label': 'Sample link',
      'url': 'https://missav.ai/sample',
      'kind': 'future-kind',
    });

    expect(link.kind, VideoLinkKind.other);
    expect(link.toJson()['kind'], 'other');
    expect(link.sourceKey, isNull);
    expect(link.isAdded, isNull);
  });

  test(
    'parses the source card structure and leaves media URLs untouched',
    () async {
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final adapter = _Adapter((_) => _response(fixture));
      final storage = _MemorySecureStorage()..cookie = 'session=source-only';
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      final page = await client.browse('https://missav.ai/dm285/ja');

      expect(page.title, 'Newest videos');
      expect(page.videos, hasLength(2));
      expect(page.videos.first.id, 'open-sample-001');
      expect(page.videos.first.pageUrl, 'https://missav.ai/ja/open-sample-001');
      expect(
        page.videos.first.cover,
        'https://fourhoi.com/sample-001/cover-t.jpg',
      );
      expect(page.videos.first.durationSeconds, 83);
      expect(page.videos.last.durationSeconds, 3723);
      expect(page.navigation.map((link) => link.label), ['Home', 'Actors']);
      expect(page.links.map((link) => link.label), [
        'Sample category',
        'Sample actor',
      ]);
      expect(page.links.first.kind, VideoLinkKind.category);
      expect(page.links.last.kind, VideoLinkKind.actor);
      expect(
        page.links.last.cover,
        'https://fourhoi.com/actor/987654321-t.jpg',
      );
      expect(client.homeUrl, 'https://missav.ai/dm285/ja');
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.uri.host, 'missav.ai');
      expect(_cookieHeader(adapter.requests.single), 'session=source-only');
      expect(client.isLoggedIn, isFalse);
      expect(storage.cookie, 'session=source-only');
    },
  );

  test('category navigation does not replace the home route', () async {
    final adapter = _Adapter(
      (_) => _response('''
<nav><a href="/dm278/cn/chinese-subtitle">Category</a></nav>
<main></main>
'''),
    );
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    await client.browse('https://missav.ai/cn');

    expect(client.homeUrl, 'https://missav.ai/cn');
  });

  test(
    'unpacks base-62 streams without replacing inserted numeric paths',
    () async {
      final words = List.filled(43, '');
      words[2] = 'corrupt';
      words.setRange(36, 43, [
        'source',
        'https',
        'media',
        'example',
        'clip',
        'mp4',
        '2',
      ]);
      final adapter = _Adapter(
        (_) => _response('''
<h1>Sample video</h1><script>
eval(function(p,a,c,k,e,d){return p}('A="B://C.D/G/E.F";',62,43,'${words.join('|')}'.split('|'),0,{}))
</script>
'''),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final details = await client.details(
        const VideoItem(
          id: 'sample',
          title: 'Sample',
          pageUrl: 'https://missav.ai/cn/sample',
        ),
      );

      expect(details.streams.single.url, 'https://media.example/2/clip.mp4');
    },
  );

  test(
    'a newer session change prevents an import waiting for initialization',
    () async {
      final storage = _MemorySecureStorage();
      final client = MissavClient(secureStorage: storage);
      addTearDown(client.dispose);

      final imported = client.importVerifiedSession(
        cookieHeader: 'session=stale',
        userAgent: 'Sample browser',
      );
      client.restoreNativeTransport();

      await expectLater(imported, throwsA(isA<MissavException>()));
      expect(storage.values, isEmpty);
      expect(client.isLoggedIn, isFalse);
    },
  );

  test(
    'browser navigates details and confirms the account through the API',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      final documents = <Uri>[];
      final apiRequests = <String>[];
      final nativeAdapter = _Adapter(
        (request) => ResponseBody.fromString(
          request.uri.path.contains('/api/') ? '{"user":null}' : fixture,
          200,
        ),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      late final MissavBrowserAdapter browser;
      browser = MissavBrowserAdapter(
        currentUrl: () async => 'https://missav.ai/ja/open-sample-001',
        disposeBrowser: () async {},
        navigateDocument: (uri, cancelled) async {
          documents.add(uri);
          return fixture;
        },
        runJavaScript: (script) async {
          final match = RegExp(r'const request = (.*);').firstMatch(script);
          if (match == null) return;
          final request = jsonDecode(match.group(1)!) as Map<String, dynamic>;
          apiRequests.add(request['url'] as String);
          browser.receiveMessage({
            'id': request['id'],
            'nonce': request['nonce'],
            'origin': MissavClient.origin,
            'status': 200,
            'url': request['url'],
            'headers': {'content-type': 'application/json'},
            'body': '{"saved":false,"user":{"name":"Sample account"}}',
          }, origin: MissavClient.origin);
        },
      );
      client.useVerifiedBrowserTransport(
        browser,
        mediaRoute: (uri) => Uri.parse('http://127.0.0.1:1234${uri.path}'),
      );

      final details = await client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Sample',
          pageUrl: 'https://missav.ai/ja/open-sample-001',
        ),
      );

      expect(documents.map((uri) => uri.path), ['/ja/open-sample-001']);
      expect(apiRequests, ['https://missav.ai/api/items/source-123/view']);
      expect(client.isLoggedIn, isTrue);
      expect(details.streams, hasLength(2));
      expect(
        details.streams.every(
          (stream) => Uri.parse(stream.url).host == '127.0.0.1',
        ),
        isTrue,
      );
      expect(details.streams.every((stream) => stream.headers.isEmpty), isTrue);
      expect(nativeAdapter.requests, isEmpty);

      client.restoreNativeTransport();
      final nativeDetails = await client.details(details.video);
      expect(
        nativeDetails.streams.every(
          (stream) => Uri.parse(stream.url).host == 'media.example',
        ),
        isTrue,
      );
      expect(nativeAdapter.requests, hasLength(2));
    },
  );

  test('does not treat Cloudflare JSD as a verification challenge', () async {
    final fixture = await File(
      'test/fixtures/missav/catalog.html',
    ).readAsString();
    final pageWithCloudflareJsd = fixture.replaceFirst(
      '</body>',
      '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>'
          '</body>',
    );
    final adapter = _Adapter((_) => _response(pageWithCloudflareJsd));
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://missav.ai/dm285/ja');

    expect(page.videos, hasLength(2));
    expect(adapter.requests, hasLength(1));
  });

  test('recognizes concrete Cloudflare challenge markers', () async {
    final bodies = [
      '<title>Attention Required! | Cloudflare</title>',
      '<script>window._cf_chl_opt = {};</script>',
      '<form id="challenge-form"></form>',
      '<form action="/cdn-cgi/challenge-platform/h/b/flow"></form>',
      '<script src="/orchestrate/chl_page"></script>',
    ];
    var bodyIndex = 0;
    final adapter = _Adapter(
      (_) => _response(bodies[bodyIndex++], statusCode: HttpStatus.forbidden),
    );
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    for (final body in bodies) {
      await expectLater(
        client.browse('https://missav.ai/dm285/ja'),
        throwsA(isA<MissavVerificationRequiredException>()),
        reason: body,
      );
    }

    expect(adapter.requests, hasLength(bodies.length));
  });

  test(
    'restores native transport and invalidates an in-flight browser request',
    () async {
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final started = Completer<void>();
      final browserResponse = Completer<ResponseBody>();
      final nativeAdapter = _Adapter((_) => _response(fixture));
      final browserAdapter = _Adapter((_) {
        started.complete();
        return browserResponse.future;
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      client.useVerifiedBrowserTransport(browserAdapter);
      final staleBrowse = client.browse('https://missav.ai/dm285/ja');
      await started.future;

      client.restoreNativeTransport();
      browserResponse.complete(_response(fixture));

      await expectLater(staleBrowse, throwsA(isA<MissavException>()));
      await client.browse('https://missav.ai/dm285/ja');

      expect(browserAdapter.requests, hasLength(1));
      expect(nativeAdapter.requests, hasLength(1));
      expect(browserAdapter.closeCalls, 1);
      expect(nativeAdapter.closeCalls, 0);
    },
  );

  test(
    'replacing native transport invalidates an in-flight native request',
    () async {
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final started = Completer<void>();
      final nativeResponse = Completer<ResponseBody>();
      var nativeRequestCount = 0;
      final nativeAdapter = _Adapter((_) {
        nativeRequestCount++;
        if (nativeRequestCount == 1) {
          started.complete();
          return nativeResponse.future;
        }
        return _response(fixture);
      });
      final browserAdapter = _Adapter((_) => _response(fixture));
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final staleBrowse = client.browse('https://missav.ai/dm285/ja');
      await started.future;
      client.useVerifiedBrowserTransport(browserAdapter);
      nativeResponse.complete(_response(fixture));

      await expectLater(staleBrowse, throwsA(isA<MissavException>()));
      await client.browse('https://missav.ai/dm285/ja');

      expect(nativeAdapter.requests, hasLength(1));
      expect(nativeAdapter.closeCalls, 0);
      expect(browserAdapter.requests, hasLength(1));
    },
  );

  test(
    'cancels a login before the replacement transport can send it',
    () async {
      final transformStarted = Completer<void>();
      final releaseTransform = Completer<void>();
      final nativeAdapter = _Adapter((_) => _response('{}'));
      final browserAdapter = _CancelAwareAdapter((_) => _response('{}'));
      final dio = Dio()..httpClientAdapter = nativeAdapter;
      dio.transformer = _BlockingRequestTransformer(
        transformStarted,
        releaseTransform.future,
      );
      final client = MissavClient(
        dio: dio,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final login = client.login(email: 'user@example.test', password: 'pw');
      await transformStarted.future;
      client.useVerifiedBrowserTransport(browserAdapter);
      releaseTransform.complete();

      await expectLater(login, throwsA(isA<MissavException>()));

      expect(browserAdapter.requests, isEmpty);
      expect(nativeAdapter.requests, isEmpty);
    },
  );

  test(
    'closes replaced browser adapters and both owned adapters on dispose',
    () {
      final nativeAdapter = _Adapter((_) => _response('{}'));
      final firstBrowserAdapter = _Adapter((_) => _response('{}'));
      final secondBrowserAdapter = _Adapter((_) => _response('{}'));
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: _MemorySecureStorage(),
      );

      var sessionChanges = 0;
      client.addListener(() => sessionChanges++);

      client.useVerifiedBrowserTransport(firstBrowserAdapter);
      client.useVerifiedBrowserTransport(firstBrowserAdapter);
      client.useVerifiedBrowserTransport(secondBrowserAdapter);
      expect(sessionChanges, 2);

      expect(firstBrowserAdapter.closeCalls, 1);
      expect(secondBrowserAdapter.closeCalls, 0);
      expect(nativeAdapter.closeCalls, 0);

      client.dispose();

      expect(firstBrowserAdapter.closeCalls, 1);
      expect(secondBrowserAdapter.closeCalls, 1);
      expect(nativeAdapter.closeCalls, 1);

      final sameAdapter = _Adapter((_) => _response('{}'));
      final sameAdapterClient = MissavClient(
        dio: Dio()..httpClientAdapter = sameAdapter,
        secureStorage: _MemorySecureStorage(),
      );
      sameAdapterClient.useVerifiedBrowserTransport(sameAdapter);
      sameAdapterClient.dispose();

      expect(sameAdapter.closeCalls, 1);
    },
  );

  test(
    'logout restores native transport and closes the browser adapter',
    () async {
      final nativeAdapter = _Adapter((_) => _response('{}'));
      final browserAdapter = _Adapter((_) => _response('{}'));
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: _MemorySecureStorage()..cookie = 'session=source-only',
      );
      addTearDown(client.dispose);

      client.useVerifiedBrowserTransport(browserAdapter);
      await client.logout();
      await client.browse('https://missav.ai/dm285/ja');

      expect(browserAdapter.closeCalls, 1);
      expect(browserAdapter.requests, isEmpty);
      expect(nativeAdapter.requests, hasLength(1));
      expect(nativeAdapter.closeCalls, 0);
    },
  );

  test('rethrows a browser verification exception through Dio', () async {
    const sourceUrl = 'https://missav.ai/dm285/ja';
    const verificationError = MissavVerificationRequiredException(
      sourceUrl: sourceUrl,
    );
    final browserAdapter = _Adapter(
      (options) =>
          throw DioException(requestOptions: options, error: verificationError),
    );
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = _Adapter((_) => _response('{}')),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    client.useVerifiedBrowserTransport(browserAdapter);

    await expectLater(
      client.browse(sourceUrl),
      throwsA(same(verificationError)),
    );
  });

  test(
    'reads login state from the source page rather than the stored cookie',
    () async {
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final authenticatedFixture = fixture.replaceFirst(
        '{user: null}',
        "{user: {username: 'sample-viewer'}}",
      );
      final storage = _MemorySecureStorage()..cookie = 'visitor=source-cookie';
      final adapter = _Adapter((_) => _response(authenticatedFixture));
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      await client.initialize();
      expect(client.isLoggedIn, isFalse);

      await client.browse('https://missav.ai/dm285/ja');

      expect(client.isLoggedIn, isTrue);
      expect(client.accountName, 'sample-viewer');
      expect(storage.cookie, 'visitor=source-cookie');
    },
  );

  test(
    'restores an imported browser session without treating it as logged in',
    () async {
      const cookie = 'session=browser-session';
      const userAgent = 'MissAV WebView/1.0';
      final storage = _MemorySecureStorage();
      final importingClient = MissavClient(
        dio: Dio()..httpClientAdapter = _Adapter((_) => _response('{}')),
        secureStorage: storage,
      );
      await importingClient.importVerifiedSession(
        cookieHeader: cookie,
        userAgent: userAgent,
      );
      expect(importingClient.isLoggedIn, isFalse);
      importingClient.dispose();

      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final adapter = _Adapter((_) => _response(fixture));
      final restoredClient = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(restoredClient.dispose);

      await restoredClient.initialize();
      expect(restoredClient.isLoggedIn, isFalse);
      expect(adapter.requests, isEmpty);

      await restoredClient.browse('https://missav.ai/cn');

      expect(adapter.requests, hasLength(1));
      expect(_cookieHeader(adapter.requests.single), cookie);
      expect(_headerValue(adapter.requests.single, 'User-Agent'), userAgent);
      expect(restoredClient.isLoggedIn, isFalse);
      expect(storage.cookie, cookie);
      expect(
        storage.values.values.any((value) => value.contains(userAgent)),
        isTrue,
      );
    },
  );

  test('surfaces the browser challenge as a source entry point', () async {
    final fixture = await File(
      'test/fixtures/missav/challenge.html',
    ).readAsString();
    final adapter = _Adapter(
      (_) => _response(fixture, statusCode: HttpStatus.forbidden),
    );
    final storage = _MemorySecureStorage()..cookie = 'session=existing';
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: storage,
    );
    addTearDown(client.dispose);

    await expectLater(
      client.browse('https://missav.ai/dm285/ja'),
      throwsA(
        isA<MissavVerificationRequiredException>()
            .having(
              (error) => error.sourceUrl,
              'source URL',
              'https://missav.ai/dm285/ja',
            )
            .having(
              (error) => error.message,
              'message',
              contains('verification'),
            ),
      ),
    );
    expect(storage.cookie, 'session=existing');
    expect(client.isLoggedIn, isFalse);
  });

  test(
    'recognizes the challenge response header and preserves the session',
    () async {
      final adapter = _Adapter(
        (_) => _response(
          '<html>Verification needed</html>',
          statusCode: HttpStatus.forbidden,
          headers: {
            'cf-mitigated': ['challenge'],
          },
        ),
      );
      final storage = _MemorySecureStorage()..cookie = 'session=valid';
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      await expectLater(
        client.browse('https://missav.ai/cn'),
        throwsA(
          isA<MissavVerificationRequiredException>().having(
            (error) => error.message,
            'message',
            contains('verification'),
          ),
        ),
      );

      expect(storage.cookie, 'session=valid');
      expect(client.isLoggedIn, isFalse);
    },
  );

  test('rejects empty or line-breaking browser request headers', () async {
    final storage = _MemorySecureStorage();
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = _Adapter((_) => _response('{}')),
      secureStorage: storage,
    );
    addTearDown(client.dispose);

    for (final values in [
      (cookie: '', userAgent: 'Browser UA'),
      (cookie: 'session=valid', userAgent: ''),
      (cookie: 'session=valid\r\nX-Injected: yes', userAgent: 'Browser UA'),
      (cookie: 'session=valid', userAgent: 'Browser UA\nCookie: injected'),
    ]) {
      await expectLater(
        client.importVerifiedSession(
          cookieHeader: values.cookie,
          userAgent: values.userAgent,
        ),
        throwsArgumentError,
      );
    }

    expect(storage.values, isEmpty);
  });

  test('keeps a stored session after source and network errors', () async {
    final failures =
        <
          ({
            String name,
            FutureOr<ResponseBody> Function(RequestOptions) respond,
          })
        >[
          (
            name: 'server error',
            respond: (RequestOptions _) => _response(
              'Service unavailable',
              statusCode: HttpStatus.serviceUnavailable,
            ),
          ),
          (
            name: 'connection error',
            respond: (RequestOptions options) => throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            ),
          ),
        ];
    for (final failure in failures) {
      final storage = _MemorySecureStorage()..cookie = 'session=valid';
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = _Adapter(failure.respond),
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      await expectLater(
        client.browse('https://missav.ai/cn'),
        throwsA(isA<MissavException>()),
        reason: failure.name,
      );
      expect(storage.cookie, 'session=valid', reason: failure.name);
      expect(client.isLoggedIn, isFalse, reason: failure.name);
    }
  });

  test(
    'parses detail state and packed stream URLs without executing scripts',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      final adapter = _Adapter((options) {
        if (options.uri.path.endsWith('/api/login')) {
          return _response('{"user":{"email":"viewer@example.invalid"}}');
        }
        if (options.uri.path == '/api/items/source-123/view') {
          return _response(
            '{"user":{"email":"viewer@example.invalid"},"saved":true}',
            headers: {
              'content-type': ['application/json'],
            },
          );
        }
        return _response(fixture);
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      await client.login(email: 'viewer@example.invalid', password: 'sample');
      final accountStates = <bool>[];
      client.addListener(() => accountStates.add(client.isLoggedIn));

      final details = await client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Card title',
          pageUrl: 'https://missav.ai/ja/open-sample-001',
        ),
      );

      expect(details.video.title, 'Sample detail');
      expect(details.video.cover, 'https://fourhoi.com/sample-001/cover-n.jpg');
      expect(details.description, 'A sanitized sample description');
      expect(details.metadata['配信開始日'], '2024-03-02');
      expect(details.metadata['メーカー'], 'Sample maker');
      expect(details.actors.map((actor) => actor.label), ['Sample actor']);
      expect(details.tags.map((tag) => tag.label), [
        'Sample genre',
        'Sample maker',
        'Sample director',
        'Sample label',
      ]);
      expect(details.tags.last.kind, VideoLinkKind.category);
      expect(details.related.map((video) => video.id), ['open-related-002']);
      expect(details.sourceId, 'source-123');
      expect(details.isFavorite, isTrue);
      expect(details.streams, hasLength(2));
      expect(
        details.streams.first.url,
        'https://media.example/hls/master.m3u8',
      );
      expect(details.streams.first.isHls, isTrue);
      expect(
        details.streams.first.headers[HttpHeaders.refererHeader],
        'https://missav.ai/ja/open-sample-001',
      );
      expect(details.streams.first.headers['Origin'], MissavClient.origin);
      expect(details.streams.first.headers.containsKey('Cookie'), isFalse);
      expect(
        details.streams.first.headers.containsKey('Authorization'),
        isFalse,
      );
      expect(details.streams.last.url, 'https://media.example/file/clip.mp4');
      expect(client.isLoggedIn, isTrue);
      expect(client.accountName, 'viewer@example.invalid');
      expect(accountStates, isEmpty);
      expect(
        adapter.requests.map((request) => request.uri.host),
        everyElement('missav.ai'),
      );
    },
  );

  test(
    'uses the imported user agent for media without forwarding its cookie',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      const cookie = 'session=browser-only';
      const userAgent = 'MissAV WebView/1.0';
      final adapter = _Adapter((options) {
        if (options.uri.path == '/api/items/source-123/view') {
          return _response(
            '{"user":{"username":"browser-viewer"},"saved":false}',
            headers: {
              'content-type': ['application/json'],
            },
          );
        }
        return _response(fixture);
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      await client.importVerifiedSession(
        cookieHeader: cookie,
        userAgent: userAgent,
      );
      expect(client.isLoggedIn, isFalse);

      final details = await client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Card title',
          pageUrl: 'https://missav.ai/ja/open-sample-001',
        ),
      );

      expect(client.isLoggedIn, isTrue);
      expect(client.accountName, 'browser-viewer');
      expect(adapter.requests, hasLength(2));
      for (final request in adapter.requests) {
        expect(request.uri.host, 'missav.ai');
        expect(_cookieHeader(request), cookie);
        expect(_headerValue(request, 'User-Agent'), userAgent);
      }
      expect(details.streams, hasLength(2));
      for (final stream in details.streams) {
        expect(stream.headers[HttpHeaders.userAgentHeader], userAgent);
        expect(_hasHeader(stream.headers.keys, 'Cookie'), isFalse);
        expect(_hasHeader(stream.headers.keys, 'Authorization'), isFalse);
      }
      expect(details.streams.map((stream) => Uri.parse(stream.url).host), [
        'media.example',
        'media.example',
      ]);
    },
  );

  test(
    'updates video favorites through the observed source endpoint',
    () async {
      late RequestOptions request;
      final adapter = _Adapter((options) {
        request = options;
        return _response(
          '{}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      await client.setVideoFavorite(
        const VideoDetails(
          video: VideoItem(
            id: 'open-sample-001',
            title: 'Sample video',
            pageUrl: 'https://missav.ai/ja/open-sample-001',
          ),
          sourceId: 'source-123',
        ),
        true,
      );

      expect(request.method, 'POST');
      expect(
        request.uri.toString(),
        'https://missav.ai/api/items/source-123/save',
      );
    },
  );

  test('loads an actor source ID before updating its favorite', () async {
    final fixture = await File(
      'test/fixtures/missav/actor.html',
    ).readAsString();
    final adapter = _Adapter((options) {
      if (options.uri.path == '/api/actresses/987654321/view') {
        return _response(
          '{"user":{"username":"sample-viewer"},"saved":false}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      }
      return _response(
        fixture,
        headers: {
          'content-type': ['text/html'],
        },
      );
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    await client.setActorFavorite(
      const VideoLink(
        label: 'Sample actor',
        url: 'https://missav.ai/dm288/ja/actresses/sample-actor',
        kind: VideoLinkKind.actor,
      ),
      true,
    );

    expect(adapter.requests.map((request) => request.uri.path), [
      '/dm288/ja/actresses/sample-actor',
      '/api/actresses/987654321/view',
      '/api/actresses/987654321/save',
    ]);
    expect(adapter.requests.last.method, 'POST');
    expect(client.accountName, 'sample-viewer');
  });

  test(
    'loads playlist state and uses the observed membership endpoints',
    () async {
      final adapter = _Adapter((options) {
        if (options.uri.path == '/api/playlists/open-sample-001') {
          return _response(
            '{"data":[{"key":"list-key","name":"Sample list","is_added":true}]}',
            headers: {
              'content-type': ['application/json'],
            },
          );
        }
        return _response(
          '{}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      const item = VideoItem(
        id: 'open-sample-001',
        title: 'Sample video',
        pageUrl: 'https://missav.ai/ja/open-sample-001',
      );

      final playlists = await client.playlistsFor(item);
      expect(playlists, hasLength(1));
      expect(playlists.single.sourceKey, 'list-key');
      expect(playlists.single.isAdded, isTrue);
      expect(playlists.single.url, 'https://missav.ai/ja/playlists');

      await client.removeFromPlaylist(playlists.single, item);
      final request = adapter.requests.last;
      expect(request.method, 'POST');
      expect(request.uri.toString(), 'https://missav.ai/api/playlists/remove');
      expect(request.data, {'dvdId': 'open-sample-001', 'key': 'list-key'});
    },
  );

  test('does not follow a source redirect to a media host', () async {
    final adapter = _Adapter(
      (_) => _response(
        '',
        statusCode: HttpStatus.found,
        headers: {
          HttpHeaders.locationHeader: ['https://cdn.example/stream.m3u8'],
        },
      ),
    );
    final storage = _MemorySecureStorage()..cookie = 'session=source-only';
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: storage,
    );
    addTearDown(client.dispose);

    await expectLater(
      client.browse('https://missav.ai/dm285/ja'),
      throwsA(isA<MissavUnsupportedException>()),
    );

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.uri.host, 'missav.ai');
    expect(_cookieHeader(adapter.requests.single), 'session=source-only');
  });

  test(
    'posts the observed login contract and stores only source cookies',
    () async {
      final storage = _MemorySecureStorage()..cookie = 'XSRF-TOKEN=token%3D';
      late RequestOptions request;
      final adapter = _Adapter((options) {
        request = options;
        return _response(
          '{"user":{"email":"account@example.invalid"}}',
          headers: {
            'content-type': ['application/json'],
            'set-cookie': ['session=authenticated; Path=/; Secure'],
          },
        );
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      await client.login(
        email: 'account@example.invalid',
        password: 'test-password',
      );

      expect(request.method, 'POST');
      expect(request.uri.toString(), 'https://missav.ai/cn/api/login');
      expect(request.data, {
        'email': 'account@example.invalid',
        'password': 'test-password',
        'remember': true,
      });
      expect(_cookieHeader(request), 'XSRF-TOKEN=token%3D');
      expect(request.headers['X-XSRF-TOKEN'], 'token=');
      expect(request.headers['Accept'], 'application/json, text/plain, */*');
      expect(request.headers['X-Requested-With'], 'XMLHttpRequest');
      expect(storage.cookie, 'XSRF-TOKEN=token%3D; session=authenticated');
      expect(client.isLoggedIn, isTrue);
      expect(client.accountName, 'account@example.invalid');
    },
  );

  test(
    'a late login response cannot replace a newer account session',
    () async {
      final firstResponse = Completer<ResponseBody>();
      final secondResponse = Completer<ResponseBody>();
      final firstSent = Completer<void>();
      final secondSent = Completer<void>();
      final storage = _MemorySecureStorage();
      final adapter = _Adapter((options) {
        final email = (options.data as Map)['email'];
        if (email == 'first@example.invalid') {
          firstSent.complete();
          return firstResponse.future;
        }
        secondSent.complete();
        return secondResponse.future;
      });
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      final firstLogin = client.login(
        email: 'first@example.invalid',
        password: 'first-password',
      );
      final firstLoginRejected = expectLater(
        firstLogin,
        throwsA(isA<MissavException>()),
      );
      await firstSent.future;
      final secondLogin = client.login(
        email: 'second@example.invalid',
        password: 'second-password',
      );
      await secondSent.future;

      secondResponse.complete(
        _response(
          '{"user":{"email":"second@example.invalid"}}',
          headers: {
            'content-type': ['application/json'],
            'set-cookie': ['session=second; Path=/; Secure'],
          },
        ),
      );
      await secondLogin;
      firstResponse.complete(
        _response(
          '{"user":{"email":"first@example.invalid"}}',
          headers: {
            'content-type': ['application/json'],
            'set-cookie': ['session=first; Path=/; Secure'],
          },
        ),
      );

      await firstLoginRejected;
      expect(storage.cookie, 'session=second');
      expect(client.accountName, 'second@example.invalid');
    },
  );

  test(
    'an imported session wins over a delayed response-cookie write',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var blockNextWrite = true;
      final storage = _MemorySecureStorage()
        ..beforeWrite = () {
          if (!blockNextWrite) return Future<void>.value();
          blockNextWrite = false;
          started.complete();
          return release.future;
        };
      final fixture =
          (await File(
            'test/fixtures/missav/catalog.html',
          ).readAsString()).replaceFirst(
            '{user: null}',
            "{user: {username: 'stale-account'}}",
          );
      final adapter = _Adapter(
        (_) => _response(
          fixture,
          headers: {
            'set-cookie': ['session=stale; Path=/; Secure'],
          },
        ),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      final staleBrowse = client.browse('https://missav.ai/cn');
      await started.future;
      final import = client.importVerifiedSession(
        cookieHeader: 'session=browser',
        userAgent: 'Browser UA',
      );
      await Future<void>.value();
      release.complete();

      await expectLater(staleBrowse, throwsA(isA<MissavException>()));
      await import;

      expect(storage.cookie, 'session=browser');
      expect(client.isLoggedIn, isFalse);
      expect(client.accountName, isNull);
    },
  );

  test(
    'logout invalidates a page while its response cookie is being stored',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final storage = _MemorySecureStorage()
        ..beforeWrite = () {
          started.complete();
          return release.future;
        };
      final fixture =
          (await File(
            'test/fixtures/missav/catalog.html',
          ).readAsString()).replaceFirst(
            '{user: null}',
            "{user: {username: 'old-account'}}",
          );
      final adapter = _Adapter(
        (_) => _response(
          fixture,
          headers: {
            'set-cookie': ['session=old; Path=/; Secure'],
          },
        ),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      final request = expectLater(
        client.browse('https://missav.ai/cn'),
        throwsA(isA<MissavException>()),
      );
      await started.future;
      final logout = client.logout();
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await Future.wait([request, logout]);
      expect(client.isLoggedIn, isFalse);
      expect(client.accountName, isNull);
      expect(storage.cookie, isNull);
    },
  );

  test(
    'logout clears the local source session without an unverified endpoint',
    () async {
      final storage = _MemorySecureStorage()..cookie = 'session=source-only';
      final adapter = _Adapter((_) => _response('{}'));
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      await client.initialize();
      await client.importVerifiedSession(
        cookieHeader: 'session=source-only',
        userAgent: 'Browser UA',
      );
      await client.logout();

      expect(storage.cookie, isNull);
      expect(storage.values, isEmpty);
      expect(client.isLoggedIn, isFalse);
      expect(adapter.requests, isEmpty);
    },
  );
}

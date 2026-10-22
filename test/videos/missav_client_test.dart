import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

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
  void close({bool force = false}) {}
}

class _MemorySecureStorage implements FlutterSecureStorage {
  String? cookie;
  Future<void> Function()? beforeWrite;

  Future<void> _write(String? value) async {
    await beforeWrite?.call();
    cookie = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.memberName;
    if (key == #read) return Future<String?>.value(cookie);
    if (key == #write) {
      return _write(invocation.namedArguments[#value] as String?);
    }
    if (key == #delete) {
      cookie = null;
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
        isA<MissavException>()
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

      await expectLater(firstLogin, throwsA(isA<MissavException>()));
      expect(storage.cookie, 'session=second');
      expect(client.accountName, 'second@example.invalid');
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
      await client.logout();

      expect(storage.cookie, isNull);
      expect(client.isLoggedIn, isFalse);
      expect(adapter.requests, isEmpty);
    },
  );
}

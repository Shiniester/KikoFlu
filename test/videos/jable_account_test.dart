import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:kikoeru_flutter/src/videos/jable_client.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';

void main() {
  test('recognizes only the exact same-origin favorites paths', () {
    expect(
      JableAccount.isFavoritesUri(
        Uri.parse('https://jable.tv/my/favourites/videos/?from=2'),
      ),
      isTrue,
    );
    expect(
      JableAccount.isFavoritesUri(
        Uri.parse('https://jable.tv/my/favourites/videos'),
      ),
      isTrue,
    );
    for (final value in [
      'http://jable.tv/my/favourites/videos/',
      'https://www.jable.tv/my/favourites/videos/',
      'https://jable.tv/my/favourites/videos-old/',
      'https://jable.tv.evil.example/my/favourites/videos/',
      'https://user@jable.tv/my/favourites/videos/',
      'https://jable.tv:444/my/favourites/videos/',
    ]) {
      expect(
        JableAccount.isFavoritesUri(Uri.parse(value)),
        isFalse,
        reason: value,
      );
    }
  });

  test(
    'uses the protected list marker and notifies once per login change',
    () async {
      final adapter = _Adapter((_) => _html(_favoritesPage()));
      final testClient = _createClient(adapter);
      var notifications = 0;
      testClient.client.account.addListener(() => notifications++);

      expect(
        JableAccount.hasFavoritesList(html_parser.parse(_favoritesPage())),
        isTrue,
      );
      expect(await testClient.client.account.checkLogin(), isTrue);
      expect(await testClient.client.account.checkLogin(), isTrue);
      expect(testClient.client.account.isLoggedIn, isTrue);
      expect(testClient.client.account.revision, 1);
      expect(notifications, 1);

      await testClient.client.clearSession();
      expect(testClient.client.account.isLoggedIn, isFalse);
      expect(testClient.client.account.revision, 2);
      expect(notifications, 2);
      testClient.dispose();
    },
  );

  test(
    'does not treat a generic 200 page as a login or favorites result',
    () async {
      final adapter = _Adapter(
        (_) => _html('<html><body>Unavailable</body></html>'),
      );
      final testClient = _createClient(adapter);

      await expectLater(
        testClient.client.account.checkLogin(),
        throwsA(isA<VideoSourceException>()),
      );
      expect(testClient.client.account.isLoggedIn, isFalse);
      testClient.dispose();
    },
  );

  test(
    'returns false for an explicit login page and for no saved session',
    () async {
      final loggedOut = _createClient(_Adapter((_) => _html(_loginPage())));
      expect(await loggedOut.client.account.checkLogin(), isFalse);
      expect(loggedOut.adapter.requests, hasLength(1));
      loggedOut.dispose();

      final noSession = _createClient(
        _Adapter((_) => _html(_favoritesPage())),
        savedSession: false,
      );
      expect(await noSession.client.account.checkLogin(), isFalse);
      expect(noSession.adapter.requests, isEmpty);
      noSession.dispose();
    },
  );

  test(
    'uses only same-origin login launchers to recognize a redirected guest',
    () async {
      final guest = _createClient(
        _Adapter(
          (_) => _html(
            '<html><body><a data-href="/login/">Sign in</a></body></html>',
          ),
        ),
      );
      expect(await guest.client.account.checkLogin(), isFalse);
      guest.dispose();

      final unrelated = _createClient(
        _Adapter(
          (_) => _html(
            '<html><body><a data-href="https://ads.example/login/">Sign in</a></body></html>',
          ),
        ),
      );
      await expectLater(
        unrelated.client.account.checkLogin(),
        throwsA(isA<VideoSourceException>()),
      );
      unrelated.dispose();
    },
  );

  test(
    'adds and removes a favorite with the source response confirmation',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.path == '/my/favourites/videos/') {
          return _html(_favoritesPage());
        }
        return ResponseBody.fromString('{"status":"success"}', 200);
      });
      final testClient = _createClient(adapter);
      var notifications = 0;
      testClient.client.account.addListener(() => notifications++);

      await testClient.client.account.setVideoFavorite(_details(), true);
      await testClient.client.account.setVideoFavorite(
        _details(isFavorite: true),
        false,
      );

      final add = adapter.requests[1];
      final remove = adapter.requests[3];
      expect(add.uri.queryParameters['action'], 'add_to_favourites');
      expect(add.uri.queryParameters['video_id'], 'source-123');
      expect(add.uri.queryParameters['video_ids[]'], 'source-123');
      expect(remove.uri.queryParameters['action'], 'delete_from_favourites');
      expect(
        add.headers.entries
            .singleWhere((entry) => entry.key.toLowerCase() == 'cookie')
            .value,
        'session=verified',
      );
      expect(remove.uri.host, 'jable.tv');
      expect(testClient.client.account.revision, 3);
      expect(notifications, 3);
      testClient.dispose();
    },
  );

  test('rejects foreign videos and unconfirmed favorite responses', () async {
    final adapter = _Adapter((request) {
      if (request.uri.path == '/my/favourites/videos/') {
        return _html(_favoritesPage());
      }
      return ResponseBody.fromString('{"status":"ok"}', 200);
    });
    final testClient = _createClient(adapter);

    await expectLater(
      testClient.client.account.setVideoFavorite(
        _details(sourceKey: 'missav'),
        true,
      ),
      throwsA(isA<VideoSourceException>()),
    );
    expect(adapter.requests, isEmpty);
    await expectLater(
      testClient.client.account.setVideoFavorite(_details(), true),
      throwsA(isA<VideoSourceException>()),
    );
    expect(adapter.requests, hasLength(2));
    expect(testClient.client.account.revision, 1);
    testClient.dispose();
  });

  test('maps expired login and challenge responses to the video page', () async {
    for (final response in [
      ResponseBody.fromString(
        '{"status":"error","message":"You must be logged in"}',
        200,
      ),
      ResponseBody.fromString(
        '<html><head><title>Just a moment...</title></head><body>Cloudflare challenge</body></html>',
        403,
      ),
    ]) {
      final adapter = _Adapter((request) {
        if (request.uri.path == '/my/favourites/videos/') {
          return _html(_favoritesPage());
        }
        return response;
      });
      final testClient = _createClient(adapter);
      const expectedUrl = 'https://jable.tv/videos/sample-123/';
      final expectedType = response.statusCode == 403
          ? JableVerificationRequiredException
          : JableLoginRequiredException;

      await expectLater(
        testClient.client.account.setVideoFavorite(_details(), true),
        throwsA(
          isA<VideoSourceException>()
              .having((error) => error.sourceUrl, 'sourceUrl', expectedUrl)
              .having((error) => error.runtimeType, 'type', expectedType),
        ),
      );
      testClient.dispose();
    }
  });

  test(
    'stops accepting a favorite response after the session changes',
    () async {
      final apiStarted = Completer<void>();
      final finishApi = Completer<ResponseBody>();
      final adapter = _Adapter((request) async {
        if (request.uri.path == '/my/favourites/videos/') {
          return _html(_favoritesPage());
        }
        apiStarted.complete();
        return finishApi.future;
      });
      final testClient = _createClient(adapter);
      final mutation = testClient.client.account.setVideoFavorite(
        _details(),
        true,
      );
      await apiStarted.future;
      await testClient.client.clearSession();
      finishApi.complete(ResponseBody.fromString('{"status":"success"}', 200));

      await expectLater(mutation, throwsA(anything));
      expect(testClient.client.account.isLoggedIn, isFalse);
      expect(testClient.client.account.revision, 2);
      testClient.dispose();
    },
  );

  test(
    'searches only favorites pages in server order and supports cancellation',
    () async {
      final adapter = _Adapter((request) {
        if (request.uri.queryParameters['from_my_fav_videos'] == '2') {
          return _html('''
          <div class="list-videos">
            <div class="video-img-box"><a href="/videos/beta/"></a>
              <div class="detail"><h6>Beta</h6></div>
            </div>
          </div>
          <a class="page-link" data-parameters="from_my_fav_videos:4">4</a>
        ''');
        }
        if (request.uri.queryParameters['from_my_fav_videos'] == '3') {
          return _html('''
          <div class="list-videos">
            <div class="video-img-box"><a href="/videos/delta/"></a>
              <div class="detail"><h6>Delta</h6></div>
            </div>
          </div>
          <a class="page-link" data-parameters="from_my_fav_videos:4">4</a>
        ''');
        }
        if (request.uri.queryParameters['from_my_fav_videos'] == '4') {
          return _html('''
          <div class="list-videos">
            <div class="video-img-box"><a href="/videos/alpha/"></a>
              <div class="detail"><h6>Alpha duplicate</h6></div>
            </div>
            <div class="video-img-box"><a href="/videos/gamma/"></a>
              <div class="detail"><h6>Gamma</h6></div>
            </div>
          </div>
        ''');
        }
        return _html('''
        <html><body>
          <div id="list_videos_my_favourite_videos">
            <div class="video-img-box"><a href="/videos/alpha/"></a>
              <div class="detail"><h6>Alpha</h6></div>
            </div>
            <a class="page-link" data-parameters="from_my_fav_videos:2">2</a>
          </div>
          <div class="video-img-box"><a href="/videos/related/"></a>
            <div class="detail"><h6>Related card</h6></div>
          </div>
        </body></html>
      ''');
      });
      final testClient = _createClient(adapter);

      final results = await testClient.client.account.searchFavorites('');

      expect(results.map((video) => video.title), [
        'Alpha',
        'Beta',
        'Delta',
        'Gamma',
      ]);
      expect(adapter.requests, hasLength(4));
      expect(adapter.requests[1].uri.queryParameters['function'], 'get_block');
      expect(
        adapter.requests[1].uri.queryParameters['block_id'],
        'list_videos_my_favourite_videos',
      );
      expect(
        adapter.requests.every((request) => request.uri.host == 'jable.tv'),
        isTrue,
      );
      final secondPage = await testClient.client.browse(
        adapter.requests[1].uri.toString(),
      );
      expect(secondPage.currentPage, 2);
      expect(secondPage.jumpMaxPage, 4);
      expect(secondPage.previousUrl, JableAccount.favoritesUrl);
      expect(
        Uri.parse(secondPage.nextUrl!).queryParameters['from_my_fav_videos'],
        '3',
      );
      expect(secondPage.pageUrl(3), secondPage.nextUrl);
      expect(
        Uri.parse(secondPage.pageUrl(4)).queryParameters['from_my_fav_videos'],
        '4',
      );
      expect(adapter.requests, hasLength(5));
      testClient.dispose();

      final cancelledAdapter = _Adapter((_) => _html(_favoritesPage()));
      final cancelled = _createClient(cancelledAdapter);
      expect(
        await cancelled.client.account.searchFavorites(
          'alpha',
          isCurrent: () => false,
        ),
        isEmpty,
      );
      expect(cancelledAdapter.requests, isEmpty);
      cancelled.dispose();
    },
  );

  test('accepts an authenticated empty favorites list', () async {
    final adapter = _Adapter((_) => _html(_favoritesPage()));
    final testClient = _createClient(adapter);

    expect(await testClient.client.account.searchFavorites(''), isEmpty);
    expect(testClient.client.account.isLoggedIn, isTrue);
    testClient.dispose();
  });

  test(
    'logs out only after the source action invalidates the protected page',
    () async {
      var favoritesReads = 0;
      final adapter = _Adapter((request) {
        if (request.uri.path == '/my/favourites/videos/') {
          favoritesReads++;
          return _html(
            favoritesReads < 2
                ? _favoritesPage('<a data-href="/logout/">Sign out</a>')
                : _loginPage(),
          );
        }
        return _html('<html><body>Signed out</body></html>');
      });
      final testClient = _createClient(adapter);

      await testClient.client.account.logout();

      expect(adapter.requests.map((request) => request.uri.path), [
        '/my/favourites/videos/',
        '/logout/',
        '/my/favourites/videos/',
      ]);
      expect(testClient.storage.values, isEmpty);
      expect(testClient.client.account.isLoggedIn, isFalse);
      testClient.dispose();
    },
  );

  test(
    'keeps the session when the signed-in page has no logout action',
    () async {
      final adapter = _Adapter((_) => _html(_favoritesPage()));
      final testClient = _createClient(adapter);
      final generation = testClient.client.sessionGeneration;

      await expectLater(
        testClient.client.account.logout(),
        throwsA(isA<VideoSourceException>()),
      );

      expect(adapter.requests, hasLength(1));
      expect(testClient.storage.values, contains('jable_verified_session'));
      expect(testClient.client.sessionGeneration, generation);
      testClient.dispose();
    },
  );
}

VideoDetails _details({bool isFavorite = false, String sourceKey = 'jable'}) =>
    VideoDetails(
      video: VideoItem(
        id: 'native-123',
        sourceKey: sourceKey,
        title: 'Sample',
        pageUrl: 'https://jable.tv/videos/sample-123/',
      ),
      sourceId: 'source-123',
      isFavorite: isFavorite,
    );

String _favoritesPage([String extra = '']) =>
    '''
  <html><body>
    <div id="list_videos_my_favourite_videos">$extra</div>
  </body></html>
''';

String _loginPage() => '''
  <html><body><form action="/login/">
    <input name="username"><input type="password" name="password">
  </form></body></html>
''';

ResponseBody _html(String body) => ResponseBody.fromString(body, 200);

_TestClient _createClient(_Adapter adapter, {bool savedSession = true}) {
  final dio = Dio()..httpClientAdapter = adapter;
  final storage = _MemorySecureStorage();
  if (savedSession) {
    storage.values['jable_verified_session'] = jsonEncode({
      'cookie': 'session=verified',
      'userAgent': 'Jable account test',
    });
  }
  return _TestClient(
    JableClient(dio: dio, secureStorage: storage),
    dio,
    storage,
    adapter,
  );
}

class _TestClient {
  _TestClient(this.client, this.dio, this.storage, this.adapter);

  final JableClient client;
  final Dio dio;
  final _MemorySecureStorage storage;
  final _Adapter adapter;

  void dispose() {
    client.dispose();
    dio.close(force: true);
  }
}

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
    return await respond(options);
  }

  @override
  void close({bool force = false}) {}
}

class _MemorySecureStorage implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) {
      return Future<String?>.value(
        values[invocation.namedArguments[#key] as String],
      );
    }
    if (invocation.memberName == #delete) {
      return Future<void>.sync(() {
        values.remove(invocation.namedArguments[#key] as String);
      });
    }
    return super.noSuchMethod(invocation);
  }
}

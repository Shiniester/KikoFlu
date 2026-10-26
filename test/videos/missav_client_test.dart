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

Dio _emptyMetadataDio() => Dio()
  ..httpClientAdapter = _Adapter(
    (_) => ResponseBody.fromString(
      '{"recomms":[]}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    ),
  );

ResponseBody _metadataResponse(Object body, {int statusCode = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

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

_MemorySecureStorage _storedBrowserSession() {
  final storage = _MemorySecureStorage()..cookie = 'session=saved';
  storage.values['missav_verified_session'] = jsonEncode({
    'cookie': 'session=saved',
    'userAgent': 'Saved Browser UA',
  });
  return storage;
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

String _searchCatalogHtml(List<String> ids, {String? nextUrl}) =>
    '''
<main>
${ids.map((id) => '<div class="relative aspect-w-16 aspect-h-9"><a href="/cn/$id"><img alt="Video $id" src="https://media.example/$id.jpg"></a></div>').join()}
${nextUrl == null ? '' : '<a href="$nextUrl" rel="next">Next</a>'}
</main>
''';

void main() {
  group('VideoItem', () {
    test('round-trips its stable fields', () {
      const item = VideoItem(
        id: 'sample-001',
        title: 'Sample video',
        pageUrl: 'https://missav.ai/sample-001',
        cover: 'https://media.example/cover.jpg',
        durationSeconds: 90,
        releaseDate: '2024-03-02',
        actors: [
          VideoLink(
            label: 'Sample actor',
            url: 'https://missav.ai/cn/actresses/sample',
            kind: VideoLinkKind.actor,
          ),
        ],
        tags: [
          VideoLink(
            label: 'Drama',
            url: 'https://missav.ai/cn/genres/drama',
            kind: VideoLinkKind.category,
          ),
        ],
        hasSubtitles: true,
        isUncensored: true,
        makers: ['Studio A'],
        labels: ['Label A'],
        series: ['Series A'],
        directors: ['Director A'],
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
      final restored = VideoItem.fromJson({
        'id': item.id,
        'title': item.title,
        'pageUrl': item.pageUrl,
      });
      expect(restored.releaseDate, isNull);
      expect(restored.actors, isEmpty);
      expect(restored.tags, isEmpty);
      expect(restored.makers, isEmpty);
      expect(restored.labels, isEmpty);
      expect(restored.series, isEmpty);
      expect(restored.directors, isEmpty);
      expect(restored.hasSubtitles, isFalse);
      expect(restored.isUncensored, isFalse);
    });

    test(
      'separates optional directories in legacy tags without losing links',
      () {
        final item = VideoItem.fromJson({
          'id': 'legacy',
          'title': 'Legacy video',
          'pageUrl': 'https://missav.ai/cn/legacy',
          'makers': ['Studio A'],
          'tags': [
            for (final (route, label) in [
              ('genres/drama', 'Drama'),
              ('genres/labels', 'Labels genre'),
              ('dm691/cn/makers/studio-a', 'Studio A'),
              ('cn/studios/studio-b', 'Studio B'),
              ('labels/label-a', 'Label A'),
              ('series/series-a', 'Series A'),
              ('directors/director-a', 'Director A'),
            ])
              VideoLink(
                label: label,
                url: 'https://missav.ai/$route',
                kind: VideoLinkKind.category,
              ).toJson(),
          ],
        });

        expect(item.cardTags.map((tag) => tag.label), [
          'Drama',
          'Labels genre',
        ]);
        expect(item.cardMakers, ['Studio A', 'Studio B']);
        expect(item.cardLabels, ['Label A']);
        expect(item.cardSeries, ['Series A']);
        expect(item.cardDirectors, ['Director A']);
        expect(item.tags, hasLength(7));
        expect(
          item.toJson()['tags'][2]['url'],
          'https://missav.ai/dm691/cn/makers/studio-a',
        );
      },
    );
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
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: storage,
      );
      addTearDown(client.dispose);

      client.setLocale('ja');
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
    'enriches a catalog in one exact-ID batch without account headers',
    () async {
      final source = _Adapter(
        (_) => _response(
          _searchCatalogHtml(['alpha', 'beta', 'alpha-uncensored-leak']),
        ),
      );
      final metadata = _Adapter(
        (_) => _metadataResponse({
          'recomms': [
            {
              'id': 'beta',
              'values': {
                'actors': ['Male performer'],
                'actresses': null,
                'genres': [],
                'duration': 120,
                'type': 'heyzo',
              },
            },
            {
              'id': 'alpha',
              'values': {
                'actresses': [' Actress A ', 'Actress A'],
                'actors': ['Male performer'],
                'genres': ['Tag A', 'Tag B', 'Tag A'],
                'duration': 3723,
                'released_at': 1709337600,
                'has_chinese_subtitle': true,
                'markers': ['Studio A', ' Studio A ', null, 12],
                'labels': ['Label A'],
                'series': ['Series A'],
                'directors': ['Director A'],
              },
            },
            {
              'id': 'unrequested',
              'values': {
                'actresses': ['Wrong actress'],
                'genres': ['Wrong tag'],
              },
            },
          ],
        }),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage()..cookie = 'session=private',
      );
      addTearDown(client.dispose);
      final page = await client.browse('https://missav.ai/cn');

      expect(page.videos.map((video) => video.id), [
        'alpha',
        'beta',
        'alpha-uncensored-leak',
      ]);
      expect(page.videos.first.title, 'Video alpha');
      expect(page.videos.first.cover, 'https://media.example/alpha.jpg');
      expect(page.videos.first.actors.single.label, 'Actress A');
      expect(
        page.videos.first.actors.single.url,
        'https://missav.ai/cn/actresses/Actress%20A',
      );
      expect(page.videos.first.tags.map((tag) => tag.label), [
        'Tag A',
        'Tag B',
      ]);
      expect(page.videos.first.tags.map((tag) => Uri.parse(tag.url).path), [
        '/ja/genres/Tag%20A',
        '/ja/genres/Tag%20B',
      ]);
      expect(page.videos.first.durationSeconds, 3723);
      expect(page.videos.first.releaseDate, '2024-03-02');
      expect(page.videos.first.hasSubtitles, isTrue);
      expect(page.videos.first.makers, ['Studio A']);
      expect(page.videos.first.labels, ['Label A']);
      expect(page.videos.first.series, ['Series A']);
      expect(page.videos.first.directors, ['Director A']);
      expect(page.videos[1].actors, isEmpty);
      expect(page.videos[1].isUncensored, isTrue);
      expect(page.videos.last.actors, isEmpty);
      expect(page.videos.last.tags, isEmpty);
      expect(source.requests, hasLength(1));
      expect(metadata.requests, hasLength(1));
      final request = metadata.requests.single;
      expect(request.uri.host, 'client-rapi-missav.recombee.com');
      expect(
        request.uri.path,
        '/missav-default/recomms/users/anonymous/items/',
      );
      expect(request.data['returnProperties'], isTrue);
      expect(request.data['count'], 3);
      expect(
        request.data['filter'],
        '\'itemId\' in {"alpha","beta","alpha-uncensored-leak"}',
      );
      expect(
        request.uri.queryParameters['frontend_sign'],
        matches(RegExp(r'^[a-f0-9]{40}$')),
      );
      expect(_cookieHeader(request), isEmpty);
      expect(_headerValue(request, 'Authorization'), isNull);
      expect(_cookieHeader(source.requests.single), 'session=private');
      client.dispose();
      expect(source.closeCalls, 1);
      expect(metadata.closeCalls, 1);
    },
  );

  test('reports parsed covers before the complete metadata result', () async {
    final metadataStarted = Completer<void>();
    final metadataResponse = Completer<ResponseBody>();
    final parsed = Completer<VideoCatalogPage>();
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter(
          (_) => _response(_searchCatalogHtml(['alpha'])),
        ),
      metadataDio: Dio()
        ..httpClientAdapter = _Adapter((_) {
          metadataStarted.complete();
          return metadataResponse.future;
        }),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    var finished = false;
    final loading = client
        .browse('https://missav.ai/cn', onParsed: parsed.complete)
        .then((page) {
          finished = true;
          return page;
        });
    final preview = await parsed.future;
    await metadataStarted.future;
    expect(preview.videos.single.cover, 'https://media.example/alpha.jpg');
    expect(preview.videos.single.actors, isEmpty);
    expect(finished, isFalse);

    metadataResponse.complete(
      _metadataResponse({
        'recomms': [
          {
            'id': 'alpha',
            'values': {
              'actresses': ['Actress A'],
              'duration': 120,
            },
          },
        ],
      }),
    );
    final page = await loading;
    expect(page.videos.single.actors.single.label, 'Actress A');
    expect(page.videos.single.durationSeconds, 120);
  });

  for (final cancelMetadata in [false, true]) {
    test(
      'cancels a directory during ${cancelMetadata ? 'metadata' : 'HTML'} loading',
      () async {
        final started = Completer<void>();
        final response = Completer<ResponseBody>();
        final sourcePage = _response(_searchCatalogHtml(['alpha']));
        final client = MissavClient(
          dio: Dio()
            ..httpClientAdapter = _Adapter((_) {
              if (cancelMetadata) return sourcePage;
              started.complete();
              return response.future;
            }),
          metadataDio: Dio()
            ..httpClientAdapter = _Adapter((_) {
              started.complete();
              return response.future;
            }),
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);
        final cancelToken = CancelToken();
        var parsedCount = 0;
        final loading = client.browse(
          'https://missav.ai/cn',
          cancelToken: cancelToken,
          onParsed: (_) => parsedCount++,
        );
        final cancelled = expectLater(
          loading,
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        await started.future;
        cancelToken.cancel('A newer directory was selected.');
        response.complete(
          cancelMetadata ? _metadataResponse({'recomms': []}) : sourcePage,
        );
        await cancelled;
        expect(parsedCount, cancelMetadata ? 1 : 0);
      },
    );
  }

  test(
    'metadata failure preserves source cards and empty catalogs make no metadata call',
    () async {
      final metadata = _Adapter(
        (_) => _metadataResponse({'error': 'unavailable'}, statusCode: 503),
      );
      final source = _Adapter(
        (options) => _response(
          options.uri.path.endsWith('/empty')
              ? '<main></main>'
              : _searchCatalogHtml(['alpha']),
        ),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final page = await client.browse('https://missav.ai/cn');
      expect(page.videos.single.title, 'Video alpha');
      expect(page.videos.single.actors, isEmpty);
      expect(metadata.requests, hasLength(1));
      final empty = await client.browse('https://missav.ai/cn/empty');
      expect(empty.videos, isEmpty);
      expect(metadata.requests, hasLength(1));
    },
  );

  test(
    'account changes cancel pending metadata before publishing a catalog',
    () async {
      final started = Completer<void>();
      final response = Completer<ResponseBody>();
      final metadata = _Adapter((_) {
        started.complete();
        return response.future;
      });
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter(
            (_) => _response(_searchCatalogHtml(['alpha'])),
          ),
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final browsing = client.browse('https://missav.ai/cn');
      final stale = expectLater(browsing, throwsA(isA<MissavException>()));
      await started.future;
      await client.logout();
      expect(metadata.requests.single.cancelToken!.isCancelled, isTrue);
      response.complete(_metadataResponse({'recomms': []}));
      await stale;
    },
  );

  test(
    'session changes cancel remaining browses sharing a request token',
    () async {
      final slowStarted = Completer<void>();
      final slowResponse = Completer<ResponseBody>();
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter((request) {
            if (request.uri.path.endsWith('/slow')) {
              slowStarted.complete();
              return slowResponse.future;
            }
            return _response('<main></main>');
          }),
        metadataDio: _emptyMetadataDio(),
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final cancelToken = CancelToken();
      final slow = client.browse(
        'https://missav.ai/cn/slow',
        cancelToken: cancelToken,
      );
      final rejected = expectLater(slow, throwsA(isA<MissavException>()));
      await slowStarted.future;
      await client.browse(
        'https://missav.ai/cn/fast',
        cancelToken: cancelToken,
      );
      expect(cancelToken.isCancelled, isFalse);

      await client.logout();
      expect(cancelToken.isCancelled, isTrue);
      slowResponse.complete(_response('<main></main>'));
      await rejected;
    },
  );

  test(
    'language changes discard both catalog and detail metadata responses',
    () async {
      for (final details in [false, true]) {
        final started = Completer<void>();
        final response = Completer<ResponseBody>();
        final client = MissavClient(
          dio: Dio()
            ..httpClientAdapter = _Adapter(
              (_) => _response(_searchCatalogHtml(['alpha'])),
            ),
          metadataDio: Dio()
            ..httpClientAdapter = _Adapter((_) {
              started.complete();
              return response.future;
            }),
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);
        final request = details
            ? client.details(
                const VideoItem(
                  id: 'alpha',
                  title: 'Alpha',
                  pageUrl: 'https://missav.ai/cn/alpha',
                ),
              )
            : client.browse('https://missav.ai/cn');
        final stale = expectLater(request, throwsA(isA<MissavException>()));
        await started.future;
        client.setLocale('en');
        response.complete(_metadataResponse({'recomms': []}));
        await stale;
      }
    },
  );

  test(
    'publishes playable details before account and metadata requests finish',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      final account = Completer<ResponseBody>();
      final metadata = Completer<ResponseBody>();
      final accountStarted = Completer<void>();
      final metadataStarted = Completer<void>();
      final ready = Completer<VideoDetails>();
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter((request) {
            if (request.uri.path.contains('/api/')) {
              accountStarted.complete();
              return account.future;
            }
            return _response(fixture);
          }),
        metadataDio: Dio()
          ..httpClientAdapter = _Adapter((_) {
            metadataStarted.complete();
            return metadata.future;
          }),
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      var finished = false;
      final loading = client
          .details(
            const VideoItem(
              id: 'open-sample-001',
              title: 'Sample',
              pageUrl: 'https://missav.ai/cn/open-sample-001',
            ),
            onReady: ready.complete,
          )
          .then((value) {
            finished = true;
            return value;
          });
      final initial = await ready.future;
      expect(initial.streams, hasLength(2));
      expect(initial.isFavorite, isNull);
      await Future.wait([accountStarted.future, metadataStarted.future]);
      expect(finished, isFalse);
      account.complete(
        _metadataResponse({
          'saved': true,
          'user': {'name': 'Saved account'},
        }),
      );
      metadata.complete(
        _metadataResponse({
          'recomms': [
            {
              'id': 'open-sample-001',
              'values': {
                'genres': ['API tag'],
              },
            },
          ],
        }),
      );
      final completed = await loading;
      expect(client.isLoggedIn, isTrue);
      expect(completed.isFavorite, isTrue);
      expect(completed.video.tags.any((tag) => tag.label == 'API tag'), isTrue);
      expect(identical(completed.streams, initial.streams), isTrue);
    },
  );

  test(
    'access checks validate the document without catalog metadata',
    () async {
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final source = _Adapter((_) => _response(fixture));
      final metadata = _Adapter(
        (_) => throw StateError('Unexpected metadata request'),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      await client.checkBrowserAccess();
      expect(source.requests, hasLength(1));
      expect(metadata.requests, isEmpty);
    },
  );

  test(
    'account request failure still publishes enriched playable details',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      final updates = <VideoDetails>[];
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter(
            (request) => request.uri.path.contains('/api/')
                ? _metadataResponse({}, statusCode: 503)
                : _response(fixture),
          ),
        metadataDio: Dio()
          ..httpClientAdapter = _Adapter(
            (_) => _metadataResponse({
              'recomms': [
                {
                  'id': 'open-sample-001',
                  'values': {
                    'genres': ['API tag'],
                  },
                },
              ],
            }),
          ),
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      await expectLater(
        client.details(
          const VideoItem(
            id: 'open-sample-001',
            title: 'Sample',
            pageUrl: 'https://missav.ai/cn/open-sample-001',
          ),
          onReady: updates.add,
        ),
        throwsA(isA<MissavException>()),
      );
      expect(updates, hasLength(2));
      expect(
        updates.last.video.tags.any((tag) => tag.label == 'API tag'),
        isTrue,
      );
      expect(updates.last.isFavorite, isNull);
      expect(identical(updates.first.streams, updates.last.streams), isTrue);
    },
  );

  test('supplement retry reuses the document and playback streams', () async {
    final fixture = await File(
      'test/fixtures/missav/detail.html',
    ).readAsString();
    var accountReads = 0;
    var metadataReads = 0;
    final source = _Adapter((request) {
      if (!request.uri.path.contains('/api/')) return _response(fixture);
      accountReads++;
      return _metadataResponse({
        'saved': true,
        'user': {'name': 'Saved account'},
      }, statusCode: accountReads == 1 ? 503 : 200);
    });
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = source,
      metadataDio: Dio()
        ..httpClientAdapter = _Adapter((_) {
          metadataReads++;
          return _metadataResponse({
            'recomms': [
              {
                'id': 'open-sample-001',
                'values': {
                  'genres': ['API tag $metadataReads'],
                },
              },
            ],
          });
        }),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    final updates = <VideoDetails>[];
    await expectLater(
      client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Sample',
          pageUrl: 'https://missav.ai/cn/open-sample-001',
        ),
        onReady: updates.add,
      ),
      throwsA(isA<MissavException>()),
    );
    final initial = updates.last;
    final updated = await client.supplementDetails(initial);
    expect(
      source.requests.where((request) => !request.uri.path.contains('/api/')),
      hasLength(1),
    );
    expect(accountReads, 2);
    expect(metadataReads, 2);
    expect(identical(updated.streams, initial.streams), isTrue);
    expect(updated.description, initial.description);
    expect(updated.metadata, initial.metadata);
    expect(updated.video.tags.any((tag) => tag.label == 'API tag 2'), isTrue);
    expect(updated.isFavorite, isTrue);
    expect(client.isLoggedIn, isTrue);
  });

  test('account changes discard an in-flight supplement retry', () async {
    final accountStarted = Completer<void>();
    final metadataStarted = Completer<void>();
    final account = Completer<ResponseBody>();
    final metadata = Completer<ResponseBody>();
    final client = MissavClient(
      dio: Dio()
        ..httpClientAdapter = _Adapter((_) {
          accountStarted.complete();
          return account.future;
        }),
      metadataDio: Dio()
        ..httpClientAdapter = _Adapter((_) {
          metadataStarted.complete();
          return metadata.future;
        }),
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    final updates = <VideoDetails>[];
    final loading = client.supplementDetails(
      const VideoDetails(
        video: VideoItem(
          id: 'sample',
          title: 'Sample',
          pageUrl: 'https://missav.ai/cn/sample',
        ),
        sourceId: 'source-id',
      ),
      onReady: updates.add,
    );
    final stale = expectLater(loading, throwsA(isA<MissavException>()));
    await Future.wait([accountStarted.future, metadataStarted.future]);
    await client.logout();
    account.complete(
      _metadataResponse({
        'saved': true,
        'user': {'name': 'Stale account'},
      }),
    );
    metadata.complete(_metadataResponse({'recomms': []}));
    await stale;
    expect(updates, isEmpty);
    expect(client.isLoggedIn, isFalse);
    expect(client.accountName, isNull);
  });

  test(
    'current video and related metadata share one batch and stay separate',
    () async {
      final fixture = await File(
        'test/fixtures/missav/detail.html',
      ).readAsString();
      final metadata = _Adapter(
        (_) => _metadataResponse({
          'recomms': [
            {
              'id': 'open-sample-001',
              'values': {
                'actresses': ['Sample actor'],
                'genres': ['Sample genre', 'API tag'],
                'markers': ['API studio'],
              },
            },
            {
              'id': 'open-related-002',
              'values': {
                'actresses': ['Related actress'],
                'genres': ['Related tag'],
                'markers': ['Related studio'],
              },
            },
          ],
        }),
      );
      final client = MissavClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter(
            (options) => options.uri.path.contains('/api/')
                ? _response('{"saved":false}')
                : _response(fixture),
          ),
        metadataDio: Dio()..httpClientAdapter = metadata,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final details = await client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Main',
          pageUrl: 'https://missav.ai/cn/open-sample-001',
          series: ['Cached series'],
        ),
      );
      expect(details.video.actors.single.label, 'Sample actor');
      expect(
        details.video.actors.single.url,
        'https://missav.ai/dm288/ja/actresses/sample-actor',
      );
      expect(
        details.video.tags.where((tag) => tag.label == 'Sample genre'),
        hasLength(1),
      );
      expect(
        details.video.tags.firstWhere((tag) => tag.label == 'Sample genre').url,
        'https://missav.ai/dm349/ja/genres/sample-genre',
      );
      expect(details.video.tags.any((tag) => tag.label == 'API tag'), isTrue);
      expect(details.related.single.actors.single.label, 'Related actress');
      expect(details.related.single.tags.single.label, 'Related tag');
      expect(details.video.cardMakers, ['API studio', 'Sample maker']);
      expect(details.video.cardLabels, ['Sample label']);
      expect(details.video.cardDirectors, ['Sample director']);
      expect(details.video.series, ['Cached series']);
      expect(details.related.single.makers, ['Related studio']);
      expect(metadata.requests, hasLength(1));
    },
  );

  test(
    'live Recombee catalog batch supplies actresses and genres',
    () async {
      final source = _Adapter(
        (_) =>
            _response(_searchCatalogHtml(['miab-596', 'waaa-578', 'miab-636'])),
      );
      final client = MissavClient(
        dio: Dio()..httpClientAdapter = source,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      final page = await client.browse('https://missav.ai/cn');
      expect(page.videos.map((video) => video.id), [
        'miab-596',
        'waaa-578',
        'miab-636',
      ]);
      for (final video in page.videos) {
        expect(video.actors, isNotEmpty, reason: video.id);
        expect(video.tags, isNotEmpty, reason: video.id);
        for (final tag in video.tags) {
          expect(Uri.parse(tag.url).pathSegments, ['ja', 'genres', tag.label]);
        }
        expect(video.durationSeconds, greaterThan(0));
        expect(video.releaseDate, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
        expect(video.makers, isNotEmpty, reason: video.id);
        expect(video.labels, isNotEmpty, reason: video.id);
        expect(video.directors, isNotEmpty, reason: video.id);
      }
      expect(page.videos[1].series, isNotEmpty);
      expect(source.requests, hasLength(1));
    },
    skip: !const bool.fromEnvironment('KIKOFLU_LIVE_MISSAV_METADATA'),
  );

  test('category navigation does not replace the home route', () async {
    final adapter = _Adapter(
      (_) => _response('''
<nav><a href="/dm278/cn/chinese-subtitle">Category</a></nav>
<main></main>
'''),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    await client.browse('https://missav.ai/cn');

    expect(client.homeUrl, 'https://missav.ai/cn');
  });

  test(
    'reads metadata only from its source card without detail requests',
    () async {
      final adapter = _Adapter(
        (_) => _response('''
<main>
  <div class="space-y-2">
    <div class="relative aspect-w-16 aspect-h-9">
      <a href="/cn/sample"><img alt="Sample" src="/cover.jpg"></a>
      <span class="bottom-1 right-1">1:23</span>
      <span class="bottom-1 left-1"><span title="中文字幕"></span><span aria-label="无码"></span></span>
    </div>
    <time datetime="2024-03-02">2024-03-02</time>
    <a href="/cn/actresses/sample">Sample actor</a>
    <a href="/cn/genres/drama">Drama</a>
  </div>
  <div class="space-y-2">
    <div class="relative aspect-w-16 aspect-h-9">
      <a href="/cn/second"><img alt="Second" src="/second.jpg"></a>
    </div>
  </div>
</main>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final page = await client.browse('https://missav.ai/cn');
      final first = page.videos.first;
      expect(first.releaseDate, '2024-03-02');
      expect(first.actors.single.label, 'Sample actor');
      expect(first.tags.single.label, 'Drama');
      expect(first.hasSubtitles, isTrue);
      expect(first.isUncensored, isTrue);
      final second = page.videos.last;
      expect(second.releaseDate, isNull);
      expect(second.actors, isEmpty);
      expect(second.tags, isEmpty);
      expect(second.hasSubtitles, isFalse);
      expect(second.isUncensored, isFalse);
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'keeps pagination, languages and excluded entries out of directories',
    () async {
      final adapter = _Adapter(
        (_) => _response('''
<nav>
  <a href="/cn">Home</a>
  <a href="/cn/actresses">Actors</a>
  <a href="/cn/genres">Categories</a>
  <a href="/cn/vip">升级 VIP</a>
  <a href="/cn/actresses/ranking">女优排行 NOV 2026</a>
  <a href="/">繁體中文</a>
  <a href="/en" hreflang="en">English</a>
  <a href="/ja" x-bind:href="localizedUrl('ja')">日本語</a>
</nav>
<nav aria-label="Pagination">
  <a href="/cn/new?page=1">1</a>
  <a href="/cn/new?page=2" rel="next">Next</a>
  <a href="/cn/new?page=80">80</a>
</nav>
<a href="/cn/new?page=2">2</a>
<a href="/cn/vip">Upgrade VIP</a>
<a href="/cn/actresses/ranking">Ranking</a>
<a href="/cn/new" hreflang="zh-CN">简体中文</a>
<a href="/cn/genres/sample">Sample category</a>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final page = await client.browse('https://missav.ai/cn/new');

      expect(page.navigation.map((link) => link.label), [
        'Home',
        'Actors',
        'Categories',
      ]);
      expect(page.links.map((link) => link.label), ['Sample category']);
      expect(page.nextUrl, 'https://missav.ai/cn/new?page=2');
      expect(page.currentPage, 1);
      expect(page.jumpMaxPage, 80);
      expect(page.pageUrl(37), 'https://missav.ai/cn/new?page=37');
    },
  );

  test('source service links stay out of navigation and directories', () async {
    const serviceLinks = '''
<a href="/cn/ads">广告查询</a>
<a href="/dm123/ja/contact?from=footer">お問い合わせ</a>
<a href="/terms">使用條款</a>
<a href="/en/upload/">Upload</a>
''';
    const contentLinks = '''
<a href="/cn/new">最近更新</a>
<a href="/cn/release">新作上市</a>
<a href="/cn/chinese-subtitle">中文字幕</a>
<a href="/cn/weekly-hot">本周热门</a>
<a href="/cn/actresses">演员</a>
<a href="/cn/genres">分类</a>
<a href="/cn/makers">厂商</a>
<a href="/cn/series/sample">专题</a>
<a href="/cn/genres/contact">Contact category</a>
''';
    final adapter = _Adapter(
      (_) => _response(
        '<nav>$serviceLinks$contentLinks</nav>$serviceLinks$contentLinks',
      ),
    );
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final page = await client.browse('https://missav.ai/cn');

    const labels = [
      '最近更新',
      '新作上市',
      '中文字幕',
      '本周热门',
      '演员',
      '分类',
      '厂商',
      '专题',
      'Contact category',
    ];
    expect(page.navigation.map((link) => link.label), labels);
    expect(page.links.map((link) => link.label), labels);
  });

  for (final entry in {
    'zh': 'cn',
    'zh-Hant': '',
    'zh-TW': '',
    'en': 'en',
    'ja': 'ja',
  }.entries) {
    test(
      'follows app locale ${entry.key} across old-locale routes and search',
      () async {
        final adapter = _Adapter((_) => _response('<main></main>'));
        final client = MissavClient(
          metadataDio: _emptyMetadataDio(),
          dio: Dio()..httpClientAdapter = adapter,
          secureStorage: _MemorySecureStorage(),
        );
        addTearDown(client.dispose);
        client.setLocale(entry.key);
        expect(client.setLocale(entry.key), isFalse);
        final prefix = entry.value.isEmpty ? '' : '/${entry.value}';
        expect(
          client.homeUrl,
          'https://missav.ai${prefix.isEmpty ? '/' : prefix}',
        );

        await client.browse('https://missav.ai/dm123/cn/new?page=4');
        expect(adapter.requests.single.uri.path, '/dm123$prefix/new');
        expect(adapter.requests.single.uri.queryParameters['page'], '4');
        await client.search('sample query');
        expect(adapter.requests.last.uri.path, '$prefix/search/sample%20query');
        expect(adapter.requests.last.uri.pathSegments.last, 'sample query');
        await client.browse('https://missav.ai/dm123/ja/genres?page=2');
        expect(adapter.requests.last.uri.path, '/dm123$prefix/genres');
        expect(adapter.requests.last.uri.queryParameters['page'], '2');
        expect(
          client.collectionUrl('favorites'),
          'https://missav.ai$prefix/saved',
        );
        expect(
          client.collectionUrl('actorFavorites'),
          'https://missav.ai$prefix/saved/actresses',
        );
        expect(
          client.collectionUrl('playlists'),
          'https://missav.ai$prefix/playlists',
        );
        expect(
          client.collectionUrl('history'),
          'https://missav.ai$prefix/history',
        );
      },
    );
  }

  for (final language in ['zh', 'zh-Hant', 'en', 'ja']) {
    test('genre routes keep their source language under $language', () async {
      final adapter = _Adapter(
        (_) => _response('''
<main><a href="?page=2&amp;sort=published_at" rel="next">Next</a></main>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      )..setLocale(language);
      addTearDown(client.dispose);

      for (final path in [
        '/ja/genres/フェラ',
        '/dm1303/ja/genres/フェラ',
        '/dm1303/cn/genres/口交',
        '/genres/口交',
        '/en/genres/Oral Sex',
      ]) {
        final uri = Uri.https('missav.ai', path, {
          'page': '1',
          'sort': 'published_at',
        });
        final page = await client.browse(uri.toString());
        expect(adapter.requests.last.uri, uri);
        expect(page.url, uri.toString());
        await client.browse(page.nextUrl!);
        expect(
          adapter.requests.last.uri,
          uri.replace(queryParameters: {'page': '2', 'sort': 'published_at'}),
        );
      }
    });
  }

  for (final entry in {
    VideoSearchFilterKind.genre: 'genres',
    VideoSearchFilterKind.actor: 'actresses',
    VideoSearchFilterKind.studio: 'makers',
    VideoSearchFilterKind.series: 'series',
  }.entries) {
    test('filter picker loads only ${entry.value} choices and pages', () async {
      final route = entry.value;
      final adapter = _Adapter(
        (_) => _response('''
<nav><a href="/ja/$route/navigation">Navigation</a></nav>
<main>
<a href="/dm123/ja/$route/choice">Choice</a>
<a href="/ja/$route">Directory</a>
<a href="/ja/$route/ranking">Ranking</a>
<a href="/ja/history">History</a>
<a href="/ja/new">New</a>
<a href="https://elsewhere.example/$route/other">External</a>
<a href="/ja/$route?page=2" rel="next">Next</a>
</main>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      )..setLocale('ja');
      addTearDown(client.dispose);

      final page = await client.searchFilterOptions(entry.key);
      expect(adapter.requests.single.uri.path, '/ja/$route');
      expect(page.links.map((link) => link.label), ['Choice']);
      expect(page.nextUrl, 'https://missav.ai/ja/$route?page=2');
      await client.searchFilterOptions(entry.key, pageUrl: page.nextUrl);
      expect(adapter.requests.last.uri.queryParameters['page'], '2');
    });
  }

  test('combined search intersects every source across later pages', () async {
    final adapter = _Adapter((request) {
      final page = request.uri.queryParameters['page'] ?? '1';
      final path = request.uri.path;
      if (path.contains('/search/')) {
        return _response(
          _searchCatalogHtml(
            page == '1' ? ['query-only'] : ['shared', 'genre-only', 'shared'],
            nextUrl: page == '1' ? '/cn/search/needle%20words?page=2' : null,
          ),
        );
      }
      if (path == '/ja/genres/selected') {
        return _response(
          _searchCatalogHtml(
            page == '1' ? ['genre-only'] : ['shared'],
            nextUrl: page == '1' ? '/ja/genres/selected?page=2' : null,
          ),
        );
      }
      if (path == '/cn/actresses/selected') {
        return _response(
          _searchCatalogHtml(
            page == '1' ? ['genre-only'] : ['shared'],
            nextUrl: '/cn/actresses/selected?page=${int.parse(page) + 1}',
          ),
        );
      }
      return _response(_searchCatalogHtml(['shared']));
    });
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    final results = await client.searchWithFilters(' needle words ', const [
      VideoLink(
        label: 'Genre',
        url: 'https://missav.ai/ja/genres/selected?page=9',
      ),
      VideoLink(label: 'Actor', url: 'https://missav.ai/cn/actresses/selected'),
      VideoLink(label: 'Studio', url: 'https://missav.ai/cn/makers/selected'),
    ]);

    expect(results.map((video) => video.id), ['shared']);
    expect(adapter.requests.first.uri.pathSegments.last, 'needle words');
    expect(adapter.requests[2].uri.path, '/ja/genres/selected');
    expect(adapter.requests[3].uri.path, '/ja/genres/selected');
    expect(
      adapter.requests.map(
        (request) => request.uri.queryParameters['page'] ?? '1',
      ),
      ['1', '2', '1', '2', '1', '2', '1'],
    );
    expect(adapter.requests.last.uri.path, '/cn/makers/selected');
  });

  test(
    'filter-only search keeps source order and deduplicates filters',
    () async {
      final adapter = _Adapter(
        (_) => _response(_searchCatalogHtml(['second', 'first', 'second'])),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      )..setLocale('ja');
      addTearDown(client.dispose);
      const filter = VideoLink(
        label: 'Actor',
        url: 'https://missav.ai/cn/actresses/selected',
      );

      final results = await client.searchWithFilters('', [filter, filter]);
      expect(results.map((video) => video.id), ['second', 'first']);
      expect(adapter.requests.single.uri.path, '/ja/actresses/selected');
    },
  );

  test(
    'superseded combined search stops before reading another page',
    () async {
      var current = true;
      final adapter = _Adapter((_) {
        current = false;
        return _response(
          _searchCatalogHtml(['one'], nextUrl: '/cn/genres/selected?page=2'),
        );
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final result = await client.searchWithFilters('', const [
        VideoLink(label: 'Genre', url: 'https://missav.ai/cn/genres/selected'),
      ], isCurrent: () => current);
      expect(result, isEmpty);
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'combined search fails rather than returning a partial intersection',
    () async {
      final adapter = _Adapter(
        (request) => request.uri.path.contains('/genres/')
            ? _response(_searchCatalogHtml(['one']))
            : _response('Unavailable', statusCode: 503),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      await expectLater(
        client.searchWithFilters('', const [
          VideoLink(
            label: 'Genre',
            url: 'https://missav.ai/cn/genres/selected',
          ),
          VideoLink(
            label: 'Actor',
            url: 'https://missav.ai/cn/actresses/selected',
          ),
        ]),
        throwsA(isA<MissavException>()),
      );
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'page jumps preserve collection filters without counting other catalogs',
    () async {
      final adapter = _Adapter(
        (_) => _response('''
<nav aria-label="Pagination">
  <a href="/cn/new?sort=views&amp;page=3" rel="next">Next</a>
  <a href="/cn/new?sort=views&amp;page=18">18</a>
  <a href="/cn/new?sort=date&amp;page=99">Other sort</a>
  <a href="/cn/actresses?page=200">Other catalog</a>
</nav>
'''),
      );
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final page = await client.browse(
        'https://missav.ai/dm123/cn/new?sort=views&page=2',
      );

      expect(page.currentPage, 2);
      expect(page.jumpMaxPage, 18);
      expect(Uri.parse(page.pageUrl(12)).queryParameters, {
        'sort': 'views',
        'page': '12',
      });
    },
  );

  test(
    'collection search starts at the first page and includes later matches',
    () async {
      final adapter = _Adapter((request) {
        final page =
            int.tryParse(request.uri.queryParameters['page'] ?? '') ?? 1;
        final id = page == 1 ? 'first' : 'matching';
        final title = page == 1 ? 'Unrelated title' : 'Needle video';
        return _response('''
<main>
<div class="relative aspect-w-16 aspect-h-9">
  <a href="/cn/$id"><img alt="$title" src="https://media.example/cover.jpg"></a>
</div>
${page < 3 ? '<a href="/cn/saved?page=${page + 1}" rel="next">Next</a>' : ''}
</main>
''');
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);

      final results = await client.searchCollection(
        'https://missav.ai/cn/saved?page=9',
        'NEEDLE',
      );

      expect(results.map((video) => video.id), ['matching']);
      expect(
        adapter.requests.map(
          (request) => request.uri.queryParameters['page'] ?? '1',
        ),
        ['1', '2', '3'],
      );
      expect(
        adapter.requests.every((request) => request.uri.path == '/cn/saved'),
        isTrue,
      );
    },
  );

  test('superseded collection search stops fetching later pages', () async {
    var current = true;
    final adapter = _Adapter((_) {
      current = false;
      return _response('<a href="/cn/history?page=2" rel="next">Next</a>');
    });
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);

    expect(
      await client.searchCollection(
        client.collectionUrl('history'),
        'sample',
        isCurrent: () => current,
      ),
      isEmpty,
    );
    expect(adapter.requests, hasLength(1));
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
        metadataDio: _emptyMetadataDio(),
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
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        secureStorage: storage,
      );
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
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = nativeAdapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      client.setLocale('ja');
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
      metadataDio: _emptyMetadataDio(),
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
      metadataDio: _emptyMetadataDio(),
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

  test('rebuilds a closed browser session after login', () async {
    final native = _Adapter((_) => _response('<h1>Native catalog</h1>'));
    final replacement = _Adapter((_) => _response('<h1>Restored catalog</h1>'));
    var restorations = 0;
    var browserDisposals = 0;
    final client = MissavClient(
      dio: Dio()..httpClientAdapter = native,
      metadataDio: _emptyMetadataDio(),
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (client, expectedGeneration) async {
        restorations++;
        expect(client.sessionGeneration, expectedGeneration);
        client.useVerifiedBrowserTransport(replacement);
      },
    );
    addTearDown(client.dispose);
    late final MissavBrowserAdapter browser;
    browser = MissavBrowserAdapter(
      currentUrl: () async => MissavClient.origin,
      navigateDocument: (_, _) async => '<h1>Original catalog</h1>',
      disposeBrowser: () async => browserDisposals++,
      runJavaScript: (script) async {
        final match = RegExp(r'const request = (.*);').firstMatch(script)!;
        final request = jsonDecode(match.group(1)!) as Map;
        browser.receiveMessage({
          'id': request['id'],
          'nonce': request['nonce'],
          'origin': MissavClient.origin,
          'status': 200,
          'url': request['url'],
          'headers': {'content-type': 'application/json'},
          'body': '{"user":{"name":"viewer"}}',
        });
      },
    );
    await client.importVerifiedSession(
      cookieHeader: 'session=verified',
      userAgent: 'Test browser',
    );
    client.useVerifiedBrowserTransport(browser);
    final verifiedGeneration = client.sessionGeneration;
    await client.login(email: 'viewer@example.test', password: 'sample');
    expect(client.sessionGeneration, greaterThan(verifiedGeneration));

    browser.close(force: true);
    await browser.whenClosed;
    final page = await client.browse(client.homeUrl);

    expect(page.title, 'Restored catalog');
    expect(restorations, 1);
    expect(browserDisposals, 1);
    expect(native.requests, isEmpty);
    expect(replacement.requests, hasLength(1));
    await client.browse(client.homeUrl);
    expect(restorations, 1);
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
      metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: storage,
    );
    addTearDown(client.dispose);
    client.setLocale('ja');

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
        metadataDio: _emptyMetadataDio(),
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
      metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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

  test('restores one saved session before concurrent first requests', () async {
    final fixture = await File(
      'test/fixtures/missav/catalog.html',
    ).readAsString();
    final storage = _storedBrowserSession();
    final restoreStarted = Completer<void>();
    final finishRestore = Completer<void>();
    var restoreCalls = 0;
    final nativeAdapter = _Adapter((_) => _response('native response'));
    final browserAdapter = _Adapter((request) {
      if (request.uri.path == '/api/playlists/open-sample-001') {
        return _response(
          '{"data":[]}',
          headers: {
            'content-type': ['application/json'],
          },
        );
      }
      return _response(fixture);
    });
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = nativeAdapter,
      secureStorage: storage,
      restoreSavedSession: (client, expectedGeneration) async {
        restoreCalls++;
        if (!restoreStarted.isCompleted) restoreStarted.complete();
        await finishRestore.future;
        await client.importVerifiedSession(
          cookieHeader: 'session=browser',
          userAgent: 'Browser UA',
          expectedGeneration: expectedGeneration,
        );
        client.useVerifiedBrowserTransport(browserAdapter);
      },
    );
    addTearDown(client.dispose);

    final browse = client.browse('https://missav.ai/cn');
    final playlists = client.playlistsFor(
      const VideoItem(
        id: 'open-sample-001',
        title: 'Sample',
        pageUrl: 'https://missav.ai/cn/open-sample-001',
      ),
    );
    await restoreStarted.future;
    expect(restoreCalls, 1);
    finishRestore.complete();

    await browse;
    await playlists;
    await client.browse('https://missav.ai/cn');

    expect(restoreCalls, 1);
    expect(nativeAdapter.requests, isEmpty);
    expect(browserAdapter.requests, hasLength(3));
    for (final request in browserAdapter.requests) {
      expect(_cookieHeader(request), 'session=browser');
      expect(_headerValue(request, 'User-Agent'), 'Browser UA');
    }
    expect(storage.cookie, 'session=browser');
  });

  test(
    'login waits until the restored browser passes its access check',
    () async {
      final fixture = await File(
        'test/fixtures/missav/catalog.html',
      ).readAsString();
      final probeStarted = Completer<void>();
      final finishProbe = Completer<void>();
      var restoreCalls = 0;
      final adapter = _Adapter((request) async {
        if (request.uri.path.endsWith('/api/login')) {
          return _response(
            '{"user":{"name":"restored-viewer"}}',
            headers: {
              'content-type': ['application/json'],
            },
          );
        }
        if (!probeStarted.isCompleted) {
          probeStarted.complete();
          await finishProbe.future;
        }
        return _response(fixture);
      });
      final client = MissavClient(
        metadataDio: _emptyMetadataDio(),
        secureStorage: _storedBrowserSession(),
        restoreSavedSession: (client, expectedGeneration) async {
          restoreCalls++;
          await client.importVerifiedSession(
            cookieHeader: 'session=browser',
            userAgent: 'Browser UA',
            expectedGeneration: expectedGeneration,
          );
          client.useVerifiedBrowserTransport(adapter);
          await client.checkBrowserAccess();
        },
      );
      addTearDown(client.dispose);
      final browse = client
          .browse('https://missav.ai/cn')
          .then<void>(
            (_) {},
            onError: (Object error) => expect(error, isA<MissavException>()),
          );
      await probeStarted.future;
      final generationDuringProbe = client.sessionGeneration;
      final login = client.login(
        email: 'viewer@example.invalid',
        password: 'sample-password',
      );
      await Future<void>.delayed(Duration.zero);

      expect(client.sessionGeneration, generationDuringProbe);
      expect(adapter.requests, hasLength(1));
      finishProbe.complete();
      await browse;
      await login;
      expect(restoreCalls, 1);
      expect(client.accountName, 'restored-viewer');
      expect(adapter.closeCalls, 0);
      await client.browse('https://missav.ai/cn');
    },
  );

  test('does not start browser recovery without a saved session', () async {
    var restoreCalls = 0;
    final adapter = _Adapter((_) => _response(''));
    final client = MissavClient(
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
      restoreSavedSession: (_, _) async {
        restoreCalls++;
      },
    );
    addTearDown(client.dispose);

    await client.browse('https://missav.ai/cn');

    expect(restoreCalls, 0);
    expect(adapter.requests, hasLength(1));
  });

  test(
    'saved-session recovery preserves challenge and ordinary failures',
    () async {
      final challengeStorage = _storedBrowserSession();
      final challengeAdapter = _Adapter(
        (_) => _response(
          '<title>Just a moment...</title>',
          statusCode: HttpStatus.forbidden,
        ),
      );
      final challengeClient = MissavClient(
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = _Adapter((_) => _response('')),
        secureStorage: challengeStorage,
        restoreSavedSession: (client, expectedGeneration) async {
          await client.importVerifiedSession(
            cookieHeader: 'session=browser',
            userAgent: 'Browser UA',
            expectedGeneration: expectedGeneration,
          );
          client.useVerifiedBrowserTransport(challengeAdapter);
        },
      );
      addTearDown(challengeClient.dispose);

      await expectLater(
        challengeClient.browse('https://missav.ai/cn'),
        throwsA(isA<MissavVerificationRequiredException>()),
      );
      expect(challengeStorage.cookie, 'session=browser');

      final runtimeClient = MissavClient(
        metadataDio: _emptyMetadataDio(),
        secureStorage: _storedBrowserSession(),
        restoreSavedSession: (_, _) async {
          throw StateError('WebView runtime unavailable');
        },
      );
      addTearDown(runtimeClient.dispose);
      await expectLater(
        runtimeClient.browse('https://missav.ai/cn'),
        throwsA(isA<StateError>()),
      );

      final networkClient = MissavClient(
        metadataDio: _emptyMetadataDio(),
        secureStorage: _storedBrowserSession(),
        restoreSavedSession: (client, expectedGeneration) async {
          await client.importVerifiedSession(
            cookieHeader: 'session=browser',
            userAgent: 'Browser UA',
            expectedGeneration: expectedGeneration,
          );
          client.useVerifiedBrowserTransport(
            _Adapter(
              (request) => throw DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
              ),
            ),
          );
        },
      );
      addTearDown(networkClient.dispose);
      await expectLater(
        networkClient.browse('https://missav.ai/cn'),
        throwsA(isA<MissavException>()),
      );
    },
  );

  test(
    'late recovery cannot replace logout, a new session, or disposal',
    () async {
      for (final action in ['logout', 'replace', 'dispose']) {
        final storage = _storedBrowserSession();
        final restoreStarted = Completer<void>();
        final finishRestore = Completer<void>();
        final adapter = _Adapter((_) => _response('late response'));
        late MissavClient client;
        client = MissavClient(
          metadataDio: _emptyMetadataDio(),
          secureStorage: storage,
          restoreSavedSession: (client, expectedGeneration) async {
            restoreStarted.complete();
            await finishRestore.future;
            await client.importVerifiedSession(
              cookieHeader: 'session=late',
              userAgent: 'Late UA',
              expectedGeneration: expectedGeneration,
            );
            client.useVerifiedBrowserTransport(adapter);
          },
        );
        addTearDown(client.dispose);

        final browse = expectLater(
          client.browse('https://missav.ai/cn'),
          throwsA(isA<MissavException>()),
        );
        await restoreStarted.future;
        if (action == 'logout') {
          await client.logout();
        } else if (action == 'replace') {
          await client.importVerifiedSession(
            cookieHeader: 'session=new',
            userAgent: 'New UA',
          );
        } else {
          client.dispose();
        }
        finishRestore.complete();
        await browse;

        expect(adapter.requests, isEmpty, reason: action);
        expect(
          storage.cookie,
          action == 'logout'
              ? isNull
              : action == 'replace'
              ? 'session=new'
              : 'session=saved',
          reason: action,
        );
      }
    },
  );

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
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      client.setLocale('ja');

      await client.login(email: 'viewer@example.invalid', password: 'sample');
      final accountStates = <bool>[];
      client.addListener(() => accountStates.add(client.isLoggedIn));

      final details = await client.details(
        const VideoItem(
          id: 'open-sample-001',
          title: 'Card title',
          pageUrl: 'https://missav.ai/ja/open-sample-001',
          hasSubtitles: true,
          isUncensored: true,
        ),
      );

      expect(details.video.title, 'Sample detail');
      expect(details.video.cover, 'https://fourhoi.com/sample-001/cover-n.jpg');
      expect(details.description, 'A sanitized sample description');
      expect(details.metadata['配信開始日'], '2024-03-02');
      expect(details.video.releaseDate, '2024-03-02');
      expect(details.video.actors, details.actors);
      expect(details.video.tags, details.tags);
      expect(details.video.hasSubtitles, isTrue);
      expect(details.video.isUncensored, isTrue);
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
      expect(details.related.single.releaseDate, isNull);
      expect(details.related.single.actors, isEmpty);
      expect(details.related.single.tags, isEmpty);
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
      metadataDio: _emptyMetadataDio(),
      dio: Dio()..httpClientAdapter = adapter,
      secureStorage: _MemorySecureStorage(),
    );
    addTearDown(client.dispose);
    client.setLocale('ja');

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
        metadataDio: _emptyMetadataDio(),
        dio: Dio()..httpClientAdapter = adapter,
        secureStorage: _MemorySecureStorage(),
      );
      addTearDown(client.dispose);
      client.setLocale('ja');
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
      metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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
        metadataDio: _emptyMetadataDio(),
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

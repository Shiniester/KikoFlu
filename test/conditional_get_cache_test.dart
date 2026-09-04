import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/conditional_get_cache.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'kikoflu_conditional_get_cache_test_',
    );
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('a stale GET uses ETag and reuses the body after 304', () async {
    final adapter = _SequenceAdapter([
      ResponseBody.fromString(
        '{"value":1}',
        HttpStatus.ok,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          'etag': ['"tags-v1"'],
          'cache-control': ['max-age=0'],
        },
      ),
      ResponseBody.fromString(
        '',
        HttpStatus.notModified,
        headers: {
          'cache-control': ['max-age=3600'],
        },
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(
      ConditionalGetCache(
        directoryProvider: () async => tempDirectory,
        scopeProvider: () => 'https://example.com|alice',
      ),
    );

    final first = await dio.get<Map<String, dynamic>>('/api/tags');
    final second = await dio.get<Map<String, dynamic>>('/api/tags');

    expect(first.data, {'value': 1});
    expect(second.data, {'value': 1});
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.last.headers['If-None-Match'], '"tags-v1"');
  });

  test('a 304 no-store response removes the previously cached body', () async {
    final adapter = _SequenceAdapter([
      ResponseBody.fromString(
        '{"value":1}',
        HttpStatus.ok,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          'etag': ['"private-v1"'],
          'cache-control': ['max-age=0'],
        },
      ),
      ResponseBody.fromString(
        '',
        HttpStatus.notModified,
        headers: {
          'cache-control': ['no-store'],
        },
      ),
      _jsonResponse('{"value":2}', cacheControl: 'max-age=3600'),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(
      ConditionalGetCache(
        directoryProvider: () async => tempDirectory,
        scopeProvider: () => 'https://example.com|alice',
      ),
    );

    expect((await dio.get('/api/private')).data, {'value': 1});
    expect((await dio.get('/api/private')).data, {'value': 1});
    expect((await dio.get('/api/private')).data, {'value': 2});
    expect(adapter.requests, hasLength(3));
  });

  test(
    'identical in-flight recommender POSTs share one response body',
    () async {
      final adapter = _SequenceAdapter([
        ResponseBody.fromString(
          '{"works":[1]}',
          HttpStatus.ok,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      ], delay: const Duration(milliseconds: 20));
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(
        ConditionalGetCache(
          directoryProvider: () async => tempDirectory,
          scopeProvider: () => 'https://example.com|alice',
        ),
      );

      final responses = await Future.wait([
        dio.post<Map<String, dynamic>>(
          '/api/recommender/popular',
          data: {'page': 1},
        ),
        dio.post<Map<String, dynamic>>(
          '/api/recommender/popular',
          data: {'page': 1},
        ),
      ]);

      expect(adapter.requests, hasLength(1));
      expect(responses.map((response) => response.data), [
        {
          'works': [1],
        },
        {
          'works': [1],
        },
      ]);
    },
  );

  test('no-store and changed Vary headers never reuse a cached body', () async {
    final noStoreAdapter = _SequenceAdapter([
      _jsonResponse('{"value":1}', cacheControl: 'no-store'),
      _jsonResponse('{"value":2}', cacheControl: 'no-store'),
    ]);
    final noStoreDio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..httpClientAdapter = noStoreAdapter;
    noStoreDio.interceptors.add(
      ConditionalGetCache(
        directoryProvider: () async => tempDirectory,
        scopeProvider: () => 'https://example.com|alice',
      ),
    );

    expect((await noStoreDio.get('/api/no-store')).data, {'value': 1});
    expect((await noStoreDio.get('/api/no-store')).data, {'value': 2});
    expect(noStoreAdapter.requests, hasLength(2));

    final varyAdapter = _SequenceAdapter([
      _jsonResponse(
        '{"mode":"compact"}',
        cacheControl: 'max-age=3600',
        vary: 'X-Mode',
      ),
      _jsonResponse(
        '{"mode":"full"}',
        cacheControl: 'max-age=3600',
        vary: 'X-Mode',
      ),
    ]);
    final varyDio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..httpClientAdapter = varyAdapter;
    varyDio.interceptors.add(
      ConditionalGetCache(
        directoryProvider: () async => tempDirectory,
        scopeProvider: () => 'https://example.com|alice',
      ),
    );

    expect(
      (await varyDio.get(
        '/api/vary',
        options: Options(headers: {'X-Mode': 'compact'}),
      )).data,
      {'mode': 'compact'},
    );
    expect(
      (await varyDio.get(
        '/api/vary',
        options: Options(headers: {'X-Mode': 'full'}),
      )).data,
      {'mode': 'full'},
    );
    await ConditionalGetCache.invalidateProcessMemory();
    expect(
      (await varyDio.get(
        '/api/vary',
        options: Options(headers: {'X-Mode': 'compact'}),
      )).data,
      {'mode': 'compact'},
    );
    expect(varyAdapter.requests, hasLength(2));
  });

  test(
    'concurrent GET variants are not coalesced before Vary is known',
    () async {
      final adapter = _HeaderResponseAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(
        ConditionalGetCache(
          directoryProvider: () async => tempDirectory,
          scopeProvider: () => 'https://example.com|alice',
        ),
      );

      final responses = await Future.wait([
        dio.get(
          '/api/layout',
          options: Options(headers: {'X-Mode': 'compact'}),
        ),
        dio.get('/api/layout', options: Options(headers: {'X-Mode': 'full'})),
      ]);

      expect(adapter.requests, hasLength(2));
      expect(responses[0].data, {'mode': 'compact'});
      expect(responses[1].data, {'mode': 'full'});
    },
  );

  test('one cancelled consumer does not abort a shared GET body', () async {
    final adapter = _SequenceAdapter([
      _jsonResponse('{"value":1}', cacheControl: 'no-store'),
    ], delay: const Duration(milliseconds: 50));
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(
      ConditionalGetCache(
        directoryProvider: () async => tempDirectory,
        scopeProvider: () => 'https://example.com|alice',
      ),
    );
    final firstCancellation = CancelToken();
    final secondCancellation = CancelToken();

    final first = dio.get('/api/shared', cancelToken: firstCancellation);
    final second = dio.get('/api/shared', cancelToken: secondCancellation);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    firstCancellation.cancel('page replaced');

    await expectLater(
      first,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect((await second).data, {'value': 1});
    expect(adapter.requests, hasLength(1));
  });

  test('the shared GET transport stops after every consumer cancels', () async {
    final adapter = _CancellationAwareAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(
      ConditionalGetCache(
        directoryProvider: () async => tempDirectory,
        scopeProvider: () => 'https://example.com|alice',
      ),
    );
    final firstCancellation = CancelToken();
    final secondCancellation = CancelToken();
    final first = dio.get('/api/cancel-all', cancelToken: firstCancellation);
    final second = dio.get('/api/cancel-all', cancelToken: secondCancellation);
    final firstExpectation = expectLater(first, throwsA(isA<DioException>()));
    final secondExpectation = expectLater(second, throwsA(isA<DioException>()));

    await adapter.started.future;
    firstCancellation.cancel('first page closed');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(adapter.cancelled.isCompleted, isFalse);
    secondCancellation.cancel('second page closed');

    await adapter.cancelled.future.timeout(const Duration(seconds: 2));
    await Future.wait([firstExpectation, secondExpectation]);
    expect(adapter.requests, 1);
  });

  test(
    'cache is account scoped and explicit invalidation removes fresh data',
    () async {
      var scope = 'https://example.com|alice';
      final adapter = _SequenceAdapter([
        _jsonResponse('{"owner":"alice"}', cacheControl: 'max-age=3600'),
        _jsonResponse('{"owner":"bob"}', cacheControl: 'max-age=3600'),
        _jsonResponse('{"owner":"alice-new"}', cacheControl: 'max-age=3600'),
      ]);
      final cache = ConditionalGetCache(
        directoryProvider: () async => tempDirectory,
        scopeProvider: () => scope,
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
        ..httpClientAdapter = adapter
        ..interceptors.add(cache);

      expect((await dio.get('/api/me')).data, {'owner': 'alice'});
      scope = 'https://example.com|bob';
      expect((await dio.get('/api/me')).data, {'owner': 'bob'});
      scope = 'https://example.com|alice';
      expect((await dio.get('/api/me')).data, {'owner': 'alice'});
      expect(adapter.requests, hasLength(2));

      await cache.invalidateAll();
      expect((await dio.get('/api/me')).data, {'owner': 'alice-new'});
      expect(adapter.requests, hasLength(3));
    },
  );

  test('invalidation waits for and removes an active cache write', () async {
    final writeStarted = Completer<void>();
    final allowWrite = Completer<void>();
    var directoryCalls = 0;
    Future<Directory> directoryProvider() async {
      directoryCalls++;
      if (directoryCalls == 2) {
        writeStarted.complete();
        await allowWrite.future;
      }
      return tempDirectory;
    }

    final adapter = _SequenceAdapter([
      _jsonResponse('{"value":1}', cacheControl: 'max-age=3600'),
      _jsonResponse('{"value":2}', cacheControl: 'max-age=3600'),
    ]);
    final cache = ConditionalGetCache(
      directoryProvider: directoryProvider,
      scopeProvider: () => 'https://example.com|alice',
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..httpClientAdapter = adapter
      ..interceptors.add(cache);

    final first = dio.get('/api/write-race');
    await writeStarted.future;
    final invalidation = cache.invalidateAll();
    allowWrite.complete();
    await Future.wait([first, invalidation]);

    expect((await dio.get('/api/write-race')).data, {'value': 2});
    expect(adapter.requests, hasLength(2));
  });

  test('auth token and Set-Cookie values are never persisted', () async {
    final adapter = _SequenceAdapter([
      ResponseBody.fromString(
        '{"value":1}',
        HttpStatus.ok,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          'cache-control': ['max-age=3600'],
          'vary': ['Authorization'],
          'set-cookie': ['session=server-secret'],
        },
      ),
      ResponseBody.fromString(
        '{"value":2}',
        HttpStatus.ok,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          'cache-control': ['max-age=3600'],
          'vary': ['Authorization'],
          'set-cookie': ['session=second-server-secret'],
        },
      ),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(
      ConditionalGetCache(
        directoryProvider: () async => tempDirectory,
        scopeProvider: () => 'https://example.com|alice',
      ),
    );

    await dio.get(
      '/api/private',
      options: Options(headers: {'Authorization': 'Bearer token-one'}),
    );
    await dio.get(
      '/api/private',
      options: Options(headers: {'Authorization': 'Bearer token-two'}),
    );

    expect(adapter.requests, hasLength(2));
    final entities = await tempDirectory
        .list()
        .where((entity) => entity is File)
        .toList();
    expect(entities, isEmpty);
    for (final entity in entities.cast<File>()) {
      final persisted = await entity.readAsString();
      expect(persisted, isNot(contains('token-one')));
      expect(persisted, isNot(contains('token-two')));
      expect(persisted, isNot(contains('server-secret')));
    }
  });

  test('process-wide cache clearing drops in-memory fresh responses', () async {
    final adapter = _SequenceAdapter([
      _jsonResponse('{"value":1}', cacheControl: 'max-age=3600'),
      _jsonResponse('{"value":2}', cacheControl: 'max-age=3600'),
    ]);
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(
      ConditionalGetCache(
        directoryProvider: () async => tempDirectory,
        scopeProvider: () => 'https://example.com|alice',
      ),
    );

    expect((await dio.get('/api/fresh')).data, {'value': 1});
    await tempDirectory.delete(recursive: true);
    await tempDirectory.create();
    await ConditionalGetCache.invalidateProcessMemory();
    expect((await dio.get('/api/fresh')).data, {'value': 2});
    expect(adapter.requests, hasLength(2));
  });

  test('path-family invalidation preserves unrelated cached bodies', () async {
    final adapter = _SequenceAdapter([
      _jsonResponse('{"value":"review-v1"}', cacheControl: 'max-age=3600'),
      _jsonResponse('{"value":"tags-v1"}', cacheControl: 'max-age=3600'),
      _jsonResponse('{"value":"review-v2"}', cacheControl: 'max-age=3600'),
    ]);
    final cache = ConditionalGetCache(
      directoryProvider: () async => tempDirectory,
      scopeProvider: () => 'https://example.com|alice',
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com'))
      ..httpClientAdapter = adapter
      ..interceptors.add(cache);

    expect((await dio.get('/api/review/42')).data, {'value': 'review-v1'});
    expect((await dio.get('/api/tags')).data, {'value': 'tags-v1'});

    await cache.invalidatePathFamilies(const ['/api/review']);

    expect((await dio.get('/api/tags')).data, {'value': 'tags-v1'});
    expect((await dio.get('/api/review/42')).data, {'value': 'review-v2'});
    expect(adapter.requests, hasLength(3));
  });
}

ResponseBody _jsonResponse(
  String body, {
  required String cacheControl,
  String? vary,
}) {
  return ResponseBody.fromString(
    body,
    HttpStatus.ok,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
      'cache-control': [cacheControl],
      if (vary != null) 'vary': [vary],
    },
  );
}

class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.responses, {this.delay = Duration.zero});

  final List<ResponseBody> responses;
  final Duration delay;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return responses[requests.length - 1];
  }

  @override
  void close({bool force = false}) {}
}

class _HeaderResponseAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final mode = options.headers['X-Mode']?.toString() ?? '';
    return ResponseBody.fromString(
      jsonEncode({'mode': mode}),
      HttpStatus.ok,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'cache-control': ['max-age=3600'],
        'vary': ['X-Mode'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _CancellationAwareAdapter implements HttpClientAdapter {
  final Completer<void> started = Completer<void>();
  final Completer<void> cancelled = Completer<void>();
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (!started.isCompleted) started.complete();
    await cancelFuture;
    if (!cancelled.isCompleted) cancelled.complete();
    return _jsonResponse('{"unused":true}', cacheControl: 'no-store');
  }

  @override
  void close({bool force = false}) {}
}

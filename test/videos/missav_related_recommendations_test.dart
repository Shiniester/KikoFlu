import 'dart:async';
import 'dart:convert';
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
  final values = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) {
      return Future<String?>.value(
        values[invocation.namedArguments[#key] as String],
      );
    }
    if (invocation.memberName == #write) {
      final key = invocation.namedArguments[#key] as String;
      final value = invocation.namedArguments[#value] as String?;
      if (value == null) {
        values.remove(key);
      } else {
        values[key] = value;
      }
      return Future<void>.value();
    }
    if (invocation.memberName == #delete) {
      values.remove(invocation.namedArguments[#key] as String);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

ResponseBody _jsonResponse(Object body, {int statusCode = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ResponseBody _htmlResponse(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=utf-8'],
  },
);

MissavClient _client({required _Adapter source, required _Adapter metadata}) =>
    MissavClient(
      dio: Dio()..httpClientAdapter = source,
      metadataDio: Dio()..httpClientAdapter = metadata,
      secureStorage: _MemorySecureStorage(),
    );

const _currentVideo = VideoItem(
  id: 'current-video',
  title: 'Current video',
  pageUrl: 'https://missav.ai/cn/current-video',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'loads related batches in source order and removes duplicates',
    () async {
      final home = await File(
        'test/fixtures/missav/home_recommendations.html',
      ).readAsString();
      final fixture = jsonDecode(
        await File(
          'test/fixtures/missav/related_recommendations.json',
        ).readAsString(),
      );
      final source = _Adapter((_) => _htmlResponse(home));
      final metadata = _Adapter((request) {
        if (request.uri.path == '/missav-default/batch/') {
          return _jsonResponse(fixture);
        }
        return _jsonResponse({
          'recomms': [
            {
              'id': 'side-first',
              'values': {
                'actresses': ['Actress A'],
                'genres': ['Tag A'],
                'duration': 83,
              },
            },
          ],
        });
      });
      final client = _client(source: source, metadata: metadata);
      addTearDown(client.dispose);

      await client.browse('https://missav.ai/cn');
      metadata.requests.clear();
      final related = await client.loadRelatedRecommendations(_currentVideo);

      expect(related.map((video) => video.id), [
        'side-first',
        'shared-item',
        'bottom-item',
      ]);
      expect(related.first.title, 'SIDE-FIRST 侧边项目');
      expect(related[1].title, 'SHARED-ITEM Shared item');
      expect(related.first.pageUrl, 'https://missav.ai/cn/side-first');
      expect(related.first.actors.single.label, 'Actress A');
      expect(related.first.tags.single.label, 'Tag A');
      expect(related.first.durationSeconds, 83);
      expect(related[1].pageUrl, 'https://missav.ai/dm120/cn/shared-item');
      expect(related.last.cover, 'https://fourhoi.com/bottom-item/cover-t.jpg');
      expect(related.any((video) => video.id == _currentVideo.id), isFalse);
      expect(
        related.any((video) => video.id == 'unrelated-home-card'),
        isFalse,
      );

      expect(metadata.requests, hasLength(2));
      final request = metadata.requests.firstWhere(
        (request) => request.uri.path == '/missav-default/batch/',
      );
      expect(request.uri.path, '/missav-default/batch/');
      expect(
        request.uri.queryParameters['frontend_timestamp'],
        matches(RegExp(r'^\d{10}$')),
      );
      expect(
        request.uri.queryParameters['frontend_sign'],
        matches(RegExp(r'^[a-f0-9]{40}$')),
      );
      expect(request.data, {
        'distinctRecomms': true,
        'requests': [
          {
            'method': 'POST',
            'path': '/recomms/items/current-video/items/',
            'params': {
              'targetUserId': 'source-visitor',
              'count': 24,
              'scenario': 'desktop-watch-next-side',
              'returnProperties': true,
              'includedProperties': ['title_en', 'title_cn', 'dm'],
              'cascadeCreate': true,
            },
          },
          {
            'method': 'POST',
            'path': '/recomms/items/current-video/items/',
            'params': {
              'targetUserId': 'source-visitor',
              'count': 24,
              'scenario': 'desktop-watch-next-bottom',
              'returnProperties': true,
              'includedProperties': ['title_en', 'title_cn', 'dm'],
              'cascadeCreate': true,
            },
          },
        ],
      });
      final enrichmentRequest = metadata.requests.firstWhere(
        (request) => request.uri.path.contains('/users/anonymous/'),
      );
      expect(
        enrichmentRequest.data['filter'],
        '\'itemId\' in {"side-first","shared-item","bottom-item"}',
      );
    },
  );

  test('treats valid empty batch results as no recommendations', () async {
    final empty = [
      for (final recommId in ['side', 'bottom'])
        {
          'code': 200,
          'json': {
            'recommId': recommId,
            'numberNextRecommsCalls': 0,
            'recomms': <Object>[],
          },
        },
    ];
    final metadata = _Adapter((_) => _jsonResponse(empty));
    final client = _client(
      source: _Adapter((_) => _htmlResponse('')),
      metadata: metadata,
    );
    addTearDown(client.dispose);

    expect(await client.loadRelatedRecommendations(_currentVideo), isEmpty);
    final requests = metadata.requests.single.data['requests'] as List;
    final firstRequest = requests.first as Map;
    final params = firstRequest['params'] as Map;
    expect(params['targetUserId'], 'anonymous');
    expect(metadata.requests.single.uri.path, '/missav-default/batch/');
  });

  test('keeps recommendations when metadata enrichment fails', () async {
    final fixture = jsonDecode(
      await File(
        'test/fixtures/missav/related_recommendations.json',
      ).readAsString(),
    );
    final metadata = _Adapter(
      (request) => request.uri.path == '/missav-default/batch/'
          ? _jsonResponse(fixture)
          : _jsonResponse({'error': 'unavailable'}, statusCode: 503),
    );
    final client = _client(
      source: _Adapter((_) => _htmlResponse('')),
      metadata: metadata,
    );
    addTearDown(client.dispose);

    final related = await client.loadRelatedRecommendations(_currentVideo);
    expect(related.map((video) => video.id), [
      'side-first',
      'shared-item',
      'bottom-item',
    ]);
    expect(related.first.title, 'SIDE-FIRST 侧边项目');
  });

  for (final changeSession in [true, false]) {
    for (final waitForMetadata in [false, true]) {
      test(
        'discards related results after ${changeSession ? 'session' : 'language'} changes '
        'during ${waitForMetadata ? 'metadata' : 'batch'} loading',
        () async {
          final fixture = jsonDecode(
            await File(
              'test/fixtures/missav/related_recommendations.json',
            ).readAsString(),
          );
          final started = Completer<void>();
          final response = Completer<ResponseBody>();
          final metadata = _Adapter((request) {
            final batch = request.uri.path == '/missav-default/batch/';
            if (batch == waitForMetadata) return _jsonResponse(fixture);
            started.complete();
            return response.future;
          });
          final client = _client(
            source: _Adapter((_) => _htmlResponse('')),
            metadata: metadata,
          );
          addTearDown(client.dispose);
          final result = client.loadRelatedRecommendations(_currentVideo);
          final rejected = expectLater(
            result,
            throwsA(anyOf(isA<MissavException>(), isA<DioException>())),
          );
          await started.future;
          if (changeSession) {
            client.restoreNativeTransport();
          } else {
            client.setLocale('ja');
          }
          response.complete(
            _jsonResponse(waitForMetadata ? {'recomms': []} : fixture),
          );
          await rejected;
          expect(metadata.requests.length, waitForMetadata ? 2 : 1);
        },
      );
    }
  }

  for (final invalidResponse in [
    [
      {
        'code': 200,
        'json': {'recomms': []},
      },
      {
        'code': 200,
        'json': {'recomms': []},
      },
    ],
    [
      {
        'code': 200,
        'json': {
          'recommId': 'side',
          'numberNextRecommsCalls': 0,
          'recomms': [],
        },
      },
      {
        'code': 503,
        'json': {'error': 'unavailable'},
      },
    ],
    [
      {
        'code': 200,
        'json': {
          'recommId': 'side',
          'numberNextRecommsCalls': 0,
          'recomms': [],
        },
      },
      {
        'code': 200,
        'json': {'recommId': 'bottom'},
      },
    ],
  ]) {
    test('rejects incomplete or failed batch subresponses', () async {
      final metadata = _Adapter((_) => _jsonResponse(invalidResponse));
      final client = _client(
        source: _Adapter((_) => _htmlResponse('')),
        metadata: metadata,
      );
      addTearDown(client.dispose);

      await expectLater(
        client.loadRelatedRecommendations(_currentVideo),
        throwsA(isA<MissavException>()),
      );
    });
  }
}

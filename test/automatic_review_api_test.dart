import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReviewAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool timeout = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (timeout) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    cache = await Directory.systemTemp.createTemp('automatic-review-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => cache.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await cache.delete(recursive: true);
  });

  for (final host in ['https://api.asmr.one', 'https://selfhost.example']) {
    test(
      '$host automatic request changes progress only and carries its original session',
      () async {
        final adapter = ReviewAdapter();
        final api = KikoeruApiService(dio: Dio()..httpClientAdapter = adapter)
          ..init('token-a', host, accountScope: 'alice');
        addTearDown(api.dispose);
        await api.updateAutomaticReviewProgress(1, 'listening');
        final request = adapter.requests.single;
        expect(request.path, '/api/review');
        expect(request.data, {'work_id': 1, 'progress': 'listening'});
        expect(request.queryParameters, {
          'starOnly': false,
          'progressOnly': true,
        });
        expect(request.extra['automaticReview'], isTrue);
        expect(request.extra['audioSessionGeneration'], isA<int>());
        expect(request.headers['Authorization'], contains('token-a'));
        await api.updateReviewProgress(1, progress: 'postponed');
        expect(
          adapter.requests.last.queryParameters,
          host == 'https://api.asmr.one'
              ? isEmpty
              : {'starOnly': false, 'progressOnly': true},
        );
      },
    );
  }

  test('automatic timeouts are never retried', () async {
    final adapter = ReviewAdapter()..timeout = true;
    final api = KikoeruApiService(dio: Dio()..httpClientAdapter = adapter)
      ..init('token-a', 'https://selfhost.example', accountScope: 'alice');
    addTearDown(api.dispose);
    await expectLater(
      api.updateAutomaticReviewProgress(1, 'listening'),
      throwsA(isA<KikoeruApiException>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  for (final remove in [false, true]) {
    test(
      'manual ${remove ? "delete" : "update"} keeps its originating generation',
      () async {
        final adapter = ReviewAdapter();
        final api = KikoeruApiService(dio: Dio()..httpClientAdapter = adapter)
          ..init('token-a', 'https://selfhost.example', accountScope: 'alice');
        addTearDown(api.dispose);
        final operation = remove
            ? api.deleteReview(1)
            : api.updateReviewProgress(1, progress: 'postponed');
        api.init('token-b', 'https://selfhost.example', accountScope: 'bob');
        await expectLater(operation, throwsA(isA<KikoeruApiException>()));
        expect(adapter.requests, isEmpty);
      },
    );
  }

  test(
    'account switch before Dio onRequest cannot restamp an old automatic write',
    () async {
      final adapter = ReviewAdapter();
      final api = KikoeruApiService(dio: Dio()..httpClientAdapter = adapter)
        ..init('token-a', 'https://selfhost.example', accountScope: 'alice');
      addTearDown(api.dispose);
      final oldWrite = api.updateAutomaticReviewProgress(1, 'listening');
      api.init('token-b', 'https://selfhost.example', accountScope: 'bob');
      await expectLater(oldWrite, throwsA(isA<KikoeruApiException>()));
      expect(adapter.requests, isEmpty);
    },
  );

  test(
    'API account must agree with auth snapshot throughout delayed auth persistence',
    () async {
      final api = KikoeruApiService()
        ..init('token-a', 'https://selfhost.example', accountScope: 'alice');
      addTearDown(api.dispose);
      bool aliceIsEligible() => api.isCurrentReviewAccount(
        host: 'https://selfhost.example',
        username: 'alice',
        token: 'token-a',
      );
      expect(aliceIsEligible(), isTrue);
      // AuthState is still Alice while AuthNotifier awaits persistence for Bob.
      api.init('token-b', 'https://selfhost.example', accountScope: 'bob');
      expect(aliceIsEligible(), isFalse);
      expect(
        api.isCurrentReviewAccount(
          host: 'https://selfhost.example',
          username: 'bob',
          token: 'token-b',
        ),
        isTrue,
      );
      expect(
        api.isCurrentReviewAccount(
          host: 'https://other.example',
          username: 'bob',
          token: 'token-b',
        ),
        isFalse,
      );
      api.init('', 'https://selfhost.example', accountScope: 'anonymous');
      expect(aliceIsEligible(), isFalse);
    },
  );
}

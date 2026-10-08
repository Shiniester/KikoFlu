import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'successful preference writes bump the scoped revision only once',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'recommendation-revision-cache-',
      );
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProvider,
            (_) async => cacheDirectory.path,
          );

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var statusCode = HttpStatus.ok;
      server.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = statusCode
          ..headers.contentType = ContentType.json
          ..write('{}');
        await request.response.close();
      });
      final api = KikoeruApiService()
        ..init(
          'test-token',
          'http://127.0.0.1:${server.port}',
          accountScope: 'recommendation-revision-test',
        );

      addTearDown(() async {
        api.dispose();
        await server.close(force: true);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null);
        await cacheDirectory.delete(recursive: true);
      });

      final initialRevision = api.recommendationPreferenceRevision;
      await api.updateReviewProgress(5, rating: 5);
      expect(api.recommendationPreferenceRevision, initialRevision + 1);

      statusCode = HttpStatus.internalServerError;
      await expectLater(
        api.updateReviewProgress(5, rating: 1),
        throwsA(isA<KikoeruApiException>()),
      );
      expect(api.recommendationPreferenceRevision, initialRevision + 1);
    },
  );
}

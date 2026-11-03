import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/automatic_marking_event.dart';
import 'package:kikoeru_flutter/src/models/user.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/automatic_work_marking_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'automatic_work_marking_test.dart' show a;

class CachedReviewApi extends KikoeruApiService {
  Map<String, dynamic> cached = {'id': 1, 'title': 'Work'};
  int writes = 0;
  @override
  Future<Map<String, dynamic>> getWork(
    int id, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    if (forceRefresh) throw StateError('offline');
    return cached;
  }

  @override
  Future<void> updateAutomaticReviewProgress(int id, String progress) async {
    writes++;
  }
}

class SignedInAuth extends AuthNotifier {
  SignedInAuth(super.api);
  void publish() {
    state = const AuthState(
      currentUser: User(name: 'alice'),
      token: 'token-a',
      host: 'https://selfhost.example',
      isLoggedIn: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'setting starts disabled and toggles bindings without replacing serialized work',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final api = CachedReviewApi();
      final auth = (await tester.runAsync(() async {
        final auth = SignedInAuth(api);
        await auth.ready;
        return auth;
      }))!;
      api.init('token-a', 'https://selfhost.example', accountScope: 'alice');
      auth.publish();
      final container = ProviderContainer(
        overrides: [
          kikoeruApiServiceProvider.overrideWithValue(api),
          authProvider.overrideWith((ref) => auth),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
      final original = container.read(automaticWorkMarkingProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Material(
              child: Consumer(
                builder: (context, ref, _) => Switch(
                  value: ref.watch(automaticWorkMarkingEnabledProvider),
                  onChanged: (value) =>
                      setAutomaticWorkMarkingEnabled(ref, value),
                ),
              ),
            ),
          ),
        ),
      );
      expect(original.enabled, isFalse);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(original.enabled, isTrue);
      expect(container.read(automaticWorkMarkingProvider), same(original));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(original.enabled, isFalse);
      expect(StorageService.getBool('automatic_work_marking'), isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final known in [false, true]) {
    test(
      'offline cached progress is ${known ? "known" : "unknown when the field is absent"}',
      () async {
        SharedPreferences.setMockInitialValues({
          'automatic_work_marking': true,
        });
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        final api = CachedReviewApi();
        final auth = SignedInAuth(api);
        await auth.ready;
        api.init('token-a', 'https://selfhost.example', accountScope: 'alice');
        auth.publish();
        if (known) api.cached['progress'] = null;
        final cache = await Directory.systemTemp.createTemp(
          'automatic-review-cache-',
        );
        const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, (_) async => cache.path);
        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(pathProvider, null);
          await cache.delete(recursive: true);
        });
        await CacheService.cacheWorkDetail(
          1,
          api.cached,
          scope: api.recommendationPreferenceScope,
        );
        final container = ProviderContainer(
          overrides: [
            kikoeruApiServiceProvider.overrideWithValue(api),
            authProvider.overrideWith((ref) => auth),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(api.dispose);
        final service = container.read(automaticWorkMarkingProvider);
        await service.handle(
          const AutomaticMarkingEvent(
            AutomaticMarkingEventType.started,
            queueId: 'q',
            queue: [a],
            track: a,
          ),
        );
        expect(service.progressFor(1, null), known ? 'listening' : null);
        expect(api.writes, 0);
      },
    );
  }
}

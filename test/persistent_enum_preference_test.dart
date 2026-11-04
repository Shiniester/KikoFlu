import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/collection_layout_provider.dart';
import 'package:kikoeru_flutter/src/providers/my_reviews_provider.dart';
import 'package:kikoeru_flutter/src/providers/search_result_provider.dart';
import 'package:kikoeru_flutter/src/providers/subtitle_library_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart'
    show LayoutType;
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/persistent_enum_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum _TestLayout { bigGrid, smallGrid, list }

class _TestSubtitleLibraryNotifier extends SubtitleLibraryNotifier {
  @override
  Future<void> refresh() async {}
}

class _TestApiService extends KikoeruApiService {
  String? lastReviewFilter;

  @override
  Future<Map<String, dynamic>> getMyReviews({
    int page = 1,
    int pageSize = 20,
    String? filter,
    String order = 'updated_at',
    String sort = 'desc',
    CancelToken? cancelToken,
  }) async {
    lastReviewFilter = filter;
    return {
      'works': <dynamic>[],
      'pagination': {'totalCount': 0},
    };
  }
}

Future<void> _pumpAsyncPreferenceLoad() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads a saved enum value', () async {
    SharedPreferences.setMockInitialValues({'layout': 'smallGrid'});
    final preference = PersistentEnumPreference<_TestLayout>(
      key: 'layout',
      values: _TestLayout.values,
      fallback: _TestLayout.bigGrid,
    );

    expect(await preference.load(), _TestLayout.smallGrid);
  });

  test('falls back for a missing or invalid value', () async {
    SharedPreferences.setMockInitialValues({'layout': 'unsupported'});
    final preference = PersistentEnumPreference<_TestLayout>(
      key: 'layout',
      values: _TestLayout.values,
      fallback: _TestLayout.bigGrid,
    );

    expect(await preference.load(), _TestLayout.bigGrid);
  });

  test('persists the selected enum value', () async {
    final preference = PersistentEnumPreference<_TestLayout>(
      key: 'layout',
      values: _TestLayout.values,
      fallback: _TestLayout.bigGrid,
    );

    await preference.save(_TestLayout.list);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('layout'), 'list');
  });

  test('an in-flight load cannot overwrite a local selection', () async {
    SharedPreferences.setMockInitialValues({'layout': 'bigGrid'});
    final preference = PersistentEnumPreference<_TestLayout>(
      key: 'layout',
      values: _TestLayout.values,
      fallback: _TestLayout.bigGrid,
    );

    final pendingLoad = preference.load();
    await preference.save(_TestLayout.smallGrid);

    expect(await pendingLoad, isNull);
  });

  test(
    'global search shares audio layout while review filters stay independent',
    () async {
      SharedPreferences.setMockInitialValues({
        'works_layout_type': LayoutType.list.name,
        'my_reviews_layout_type': LayoutType.smallGrid.name,
        'collection_history_layout_type': LayoutType.list.name,
        MyReviewsNotifier.filterPreferenceKey: MyReviewFilter.listening.name,
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final apiService = _TestApiService();
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(null),
          kikoeruApiServiceProvider.overrideWithValue(apiService),
          subtitleLibraryProvider.overrideWith(
            (ref) => _TestSubtitleLibraryNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(audioLayoutProvider), LayoutType.bigGrid);
      expect(
        container.read(searchResultProvider).layoutType,
        SearchLayoutType.bigGrid,
      );

      await container.read(myReviewsProvider.notifier).preferencesReady;
      await _pumpAsyncPreferenceLoad();

      expect(container.read(audioLayoutProvider), LayoutType.bigGrid);
      expect(
        container.read(searchResultProvider).layoutType,
        SearchLayoutType.bigGrid,
      );
      expect(
        container.read(myReviewsProvider).filter,
        MyReviewFilter.listening,
      );
      await container.read(myReviewsProvider.notifier).load();
      expect(apiService.lastReviewFilter, MyReviewFilter.listening.value);

      container.read(audioLayoutProvider.notifier).set(LayoutType.smallGrid);
      expect(container.read(audioLayoutProvider), LayoutType.smallGrid);
      expect(
        container.read(searchResultProvider).layoutType,
        SearchLayoutType.smallGrid,
      );
      container
          .read(myReviewsProvider.notifier)
          .changeFilter(MyReviewFilter.listened);
      container.read(audioLayoutProvider.notifier).cycle();
      expect(container.read(audioLayoutProvider), LayoutType.list);
      expect(
        container.read(searchResultProvider).layoutType,
        SearchLayoutType.list,
      );
      await _pumpAsyncPreferenceLoad();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AudioLayoutNotifier.preferenceKey),
        LayoutType.list.name,
      );
      expect(prefs.containsKey('search_result_layout_type'), isFalse);
      expect(
        prefs.getString(MyReviewsNotifier.filterPreferenceKey),
        MyReviewFilter.listened.name,
      );
      expect(container.read(myReviewsProvider).filter, MyReviewFilter.listened);
    },
  );
}

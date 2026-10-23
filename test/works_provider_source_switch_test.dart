import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/japanese_asmr_browse.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/models/sort_options.dart';
import 'package:kikoeru_flutter/src/models/user.dart';
import 'package:kikoeru_flutter/src/providers/audio_source_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/subtitle_library_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Request {
  _Request(
    this.source,
    this.cancelToken, {
    required this.page,
    this.order,
    this.sort,
    this.japaneseAsmrSort,
    this.japaneseAsmrDirection = SortDirection.desc,
    this.japaneseAsmrAgeRating = AgeRating.all,
    this.japaneseAsmrPeriod = JapaneseAsmrPeriod.week,
    this.archiveYear,
    this.archiveMonth,
    this.endpoint = 'works',
    this.keyword,
  });

  final String endpoint;
  final AudioSource source;
  final CancelToken? cancelToken;
  final int page;
  final String? order;
  final String? sort;
  final JapaneseAsmrSortOption? japaneseAsmrSort;
  final SortDirection japaneseAsmrDirection;
  final AgeRating japaneseAsmrAgeRating;
  final JapaneseAsmrPeriod japaneseAsmrPeriod;
  final int? archiveYear;
  final int? archiveMonth;
  final String? keyword;
  final response = Completer<Map<String, dynamic>>();
}

class _DeferredApi extends KikoeruApiService {
  final requests = <_Request>[];
  final _requestWaiters = <int, Completer<void>>{};

  Future<void> waitForRequestCount(int count) {
    if (requests.length >= count) return Future.value();
    return (_requestWaiters[count] ??= Completer<void>()).future;
  }

  void _recordRequest(_Request request) {
    requests.add(request);
    final readyCounts = _requestWaiters.keys
        .where((count) => requests.length >= count)
        .toList();
    for (final count in readyCounts) {
      _requestWaiters.remove(count)!.complete();
    }
  }

  @override
  Future<Map<String, dynamic>> getWorks({
    int page = 1,
    int pageSize = 40,
    AudioSource source = AudioSource.asmrOne,
    String? order,
    String? sort,
    int? subtitle,
    int? seed,
    JapaneseAsmrSortOption? japaneseAsmrSort,
    SortDirection japaneseAsmrDirection = SortDirection.desc,
    AgeRating japaneseAsmrAgeRating = AgeRating.all,
    JapaneseAsmrPeriod japaneseAsmrPeriod = JapaneseAsmrPeriod.week,
    int? japaneseAsmrArchiveYear,
    int? japaneseAsmrArchiveMonth,
    CancelToken? cancelToken,
  }) {
    final request = _Request(
      source,
      cancelToken,
      page: page,
      order: order,
      sort: sort,
      japaneseAsmrSort: japaneseAsmrSort,
      japaneseAsmrDirection: japaneseAsmrDirection,
      japaneseAsmrAgeRating: japaneseAsmrAgeRating,
      japaneseAsmrPeriod: japaneseAsmrPeriod,
      archiveYear: japaneseAsmrArchiveYear,
      archiveMonth: japaneseAsmrArchiveMonth,
    );
    _recordRequest(request);
    return request.response.future;
  }

  @override
  Future<Map<String, dynamic>> searchWorks({
    required String keyword,
    int page = 1,
    int pageSize = 40,
    AudioSource source = AudioSource.asmrOne,
    List<SearchCondition> conditions = const [],
    String? order,
    String? sort,
    int? subtitle,
    int? seed,
    bool includeTranslationWorks = true,
    CancelToken? cancelToken,
  }) {
    final request = _Request(
      source,
      cancelToken,
      page: page,
      order: order,
      sort: sort,
      endpoint: 'search',
      keyword: keyword,
    );
    _recordRequest(request);
    return request.response.future;
  }

  @override
  Future<Map<String, dynamic>> getPopularWorks({
    int page = 1,
    int pageSize = 20,
    String? keyword,
    int? subtitle,
    List<String>? withPlaylistStatus,
    CancelToken? cancelToken,
  }) {
    final request = _Request(
      AudioSource.asmrOne,
      cancelToken,
      page: page,
      endpoint: 'popular',
    );
    _recordRequest(request);
    return request.response.future;
  }
}

class _EmptySubtitleLibrary extends SubtitleLibraryNotifier {
  @override
  Future<void> refresh() async {}
}

Map<String, dynamic> _response(int workId) => {
  'works': [
    {'id': workId, 'title': 'Work $workId'},
  ],
  'pagination': {'currentPage': 1, 'pageSize': 40, 'totalCount': 1},
};

Map<String, dynamic> _pagedResponse(
  int workId, {
  required int page,
  required int totalCount,
}) => {
  'works': [
    {'id': workId, 'title': 'Work $workId'},
  ],
  'pagination': {'currentPage': page, 'pageSize': 40, 'totalCount': totalCount},
};

Future<ProviderContainer> _createContainer(
  _DeferredApi api, {
  Map<String, Object> preferences = const {},
}) async {
  SharedPreferences.setMockInitialValues(preferences);
  await StorageService.initCritical(
    preferences: await SharedPreferences.getInstance(),
  );
  final container = ProviderContainer(
    overrides: [
      kikoeruApiServiceProvider.overrideWithValue(api),
      subtitleLibraryProvider.overrideWith((ref) => _EmptySubtitleLibrary()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _completeRequest(
  ProviderContainer container,
  _Request request,
  Map<String, dynamic> response,
) async {
  final applied = Completer<void>();
  final subscription = container.listen(worksProvider, (_, state) {
    if (!state.isLoading && !state.isLoadingMore && !applied.isCompleted) {
      applied.complete();
    }
  });
  request.response.complete(response);
  await applied.future;
  subscription.close();
}

void main() {
  test(
    'ASMR age filtering is atomic, paginated, and source-isolated',
    () async {
      final api = _DeferredApi();
      final container = await _createContainer(api);
      final notifier = container.read(worksProvider.notifier);

      final firstLoad = notifier.loadWorks(targetPage: 3, supersede: true);
      expect(api.requests.last.endpoint, 'works');
      expect(api.requests.last.page, 3);
      await _completeRequest(
        container,
        api.requests.last,
        _pagedResponse(3, page: 3, totalCount: 160),
      );
      await firstLoad;

      notifier.applyWorksSort(
        SortOrder.review,
        SortDirection.asc,
        AgeRating.general,
      );
      final filteredRequest = api.requests.last;
      expect(api.requests, hasLength(2));
      expect(filteredRequest.endpoint, 'search');
      expect(filteredRequest.keyword, r'$age:general$');
      expect(filteredRequest.source, AudioSource.asmrOne);
      expect(filteredRequest.page, 1);
      expect(filteredRequest.order, SortOrder.review.value);
      expect(filteredRequest.sort, SortDirection.asc.value);

      notifier.applyWorksSort(
        SortOrder.review,
        SortDirection.asc,
        AgeRating.general,
      );
      expect(api.requests, hasLength(2));
      await _completeRequest(
        container,
        filteredRequest,
        _pagedResponse(1, page: 1, totalCount: 80),
      );
      expect(container.read(worksProvider).currentPage, 1);

      notifier.setSortOption(SortOrder.rating);
      final legacySortRequest = api.requests.last;
      expect(legacySortRequest.endpoint, 'search');
      expect(legacySortRequest.keyword, r'$age:general$');
      expect(legacySortRequest.order, SortOrder.rating.value);
      expect(container.read(worksProvider).asmrOneAgeRating, AgeRating.general);
      await _completeRequest(
        container,
        legacySortRequest,
        _pagedResponse(5, page: 1, totalCount: 80),
      );

      final secondPageLoad = notifier.loadMore();
      final secondPage = api.requests.last;
      expect(secondPage.endpoint, 'search');
      expect(secondPage.keyword, r'$age:general$');
      expect(secondPage.source, AudioSource.asmrOne);
      expect(secondPage.page, 2);
      expect(secondPage.order, SortOrder.rating.value);
      await _completeRequest(
        container,
        secondPage,
        _pagedResponse(2, page: 2, totalCount: 80),
      );
      await secondPageLoad;

      notifier.setDisplayMode(DisplayMode.popular);
      final popularRequest = api.requests.last;
      expect(popularRequest.endpoint, 'popular');
      expect(popularRequest.keyword, isNull);
      await _completeRequest(container, popularRequest, _response(20));

      await container
          .read(audioSourceProvider.notifier)
          .select(AudioSource.jpAsmr);
      final japaneseRequest = api.requests.last;
      expect(japaneseRequest.endpoint, 'works');
      expect(japaneseRequest.source, AudioSource.jpAsmr);
      expect(japaneseRequest.keyword, isNull);
      expect(japaneseRequest.japaneseAsmrAgeRating, AgeRating.all);
      await _completeRequest(container, japaneseRequest, _response(-1));

      final requestCountBeforeJapaneseSort = api.requests.length;
      notifier.applyJapaneseAsmrSort(
        JapaneseAsmrSortOption.title,
        SortDirection.asc,
        AgeRating.adult,
      );
      expect(api.requests, hasLength(requestCountBeforeJapaneseSort + 1));
      final sortedJapaneseRequest = api.requests.last;
      expect(sortedJapaneseRequest.source, AudioSource.jpAsmr);
      expect(
        sortedJapaneseRequest.japaneseAsmrSort,
        JapaneseAsmrSortOption.title,
      );
      expect(sortedJapaneseRequest.japaneseAsmrDirection, SortDirection.asc);
      expect(sortedJapaneseRequest.japaneseAsmrAgeRating, AgeRating.adult);
      expect(container.read(worksProvider).sortOption, SortOrder.rating);
      expect(container.read(worksProvider).sortDirection, SortDirection.asc);
      expect(container.read(worksProvider).asmrOneAgeRating, AgeRating.general);
      await _completeRequest(container, sortedJapaneseRequest, _response(-2));
      notifier.applyJapaneseAsmrSort(
        JapaneseAsmrSortOption.title,
        SortDirection.asc,
        AgeRating.adult,
      );
      expect(api.requests, hasLength(requestCountBeforeJapaneseSort + 1));

      await container
          .read(audioSourceProvider.notifier)
          .select(AudioSource.asmrOne);
      final restoredAsmrRequest = api.requests.last;
      expect(restoredAsmrRequest.endpoint, 'search');
      expect(restoredAsmrRequest.keyword, r'$age:general$');
      expect(restoredAsmrRequest.order, SortOrder.rating.value);
      expect(restoredAsmrRequest.sort, SortDirection.asc.value);
      await _completeRequest(container, restoredAsmrRequest, _response(4));
    },
  );

  test('legacy nsfw sorting maps to the general age filter', () async {
    final api = _DeferredApi();
    final container = await _createContainer(api);
    final notifier = container.read(worksProvider.notifier);

    notifier.setSortOption(SortOrder.nsfw);
    final legacySetterRequest = api.requests.last;
    expect(legacySetterRequest.endpoint, 'search');
    expect(legacySetterRequest.keyword, r'$age:general$');
    expect(container.read(worksProvider).sortOption, SortOrder.release);
    expect(container.read(worksProvider).asmrOneAgeRating, AgeRating.general);
    await _completeRequest(container, legacySetterRequest, _response(1));

    notifier.applyWorksSort(
      SortOrder.release,
      SortDirection.asc,
      AgeRating.all,
    );
    final allAgesRequest = api.requests.last;
    expect(allAgesRequest.endpoint, 'works');
    await _completeRequest(container, allAgesRequest, _response(2));

    notifier.setSortOption(SortOrder.nsfw);
    final legacyDefaultRequest = api.requests.last;
    expect(legacyDefaultRequest.endpoint, 'search');
    expect(legacyDefaultRequest.keyword, r'$age:general$');
    expect(legacyDefaultRequest.order, SortOrder.release.value);
    expect(legacyDefaultRequest.sort, SortDirection.asc.value);
    expect(container.read(worksProvider).asmrOneAgeRating, AgeRating.general);
    await _completeRequest(container, legacyDefaultRequest, _response(3));
  });

  test(
    'switching to a custom host clears unsupported ASMR R-15 filtering',
    () async {
      final api = _DeferredApi();
      final container = await _createContainer(api);
      final notifier = container.read(worksProvider.notifier);
      final worksSubscription = container.listen(worksProvider, (_, _) {});
      addTearDown(worksSubscription.close);

      await container.read(authProvider.notifier).ready;
      notifier.applyWorksSort(
        SortOrder.release,
        SortDirection.desc,
        AgeRating.r15,
      );
      final officialRequest = api.requests.last;
      expect(officialRequest.endpoint, 'search');
      expect(officialRequest.keyword, r'$age:r15$');
      await _completeRequest(container, officialRequest, _response(1));

      notifier.setDisplayMode(DisplayMode.popular);
      final popularRequest = api.requests.last;
      expect(popularRequest.endpoint, 'popular');
      await _completeRequest(container, popularRequest, _response(10));

      final previousRequestCount = api.requests.length;
      final refreshed = api.waitForRequestCount(previousRequestCount + 1);
      await container
          .read(authProvider.notifier)
          .switchUser(
            const User(
              name: 'Custom server',
              host: 'http://custom.example',
              token: 'custom-token',
            ),
          );
      expect(container.read(authProvider).currentUser?.name, 'Custom server');
      await refreshed;

      expect(api.requests, hasLength(previousRequestCount + 1));
      expect(container.read(worksProvider).asmrOneAgeRating, AgeRating.all);
      expect(api.requests.last.endpoint, 'popular');
      expect(
        container.read(worksProvider).modeStates[DisplayMode.all]!.works,
        isEmpty,
      );
      await _completeRequest(container, api.requests.last, _response(11));

      notifier.setDisplayMode(DisplayMode.all);
      expect(api.requests.last.endpoint, 'works');
      expect(api.requests.last.keyword, isNull);
      await _completeRequest(container, api.requests.last, _response(2));
    },
  );

  test('JP rating changes reset the page and supersede old results', () async {
    final api = _DeferredApi();
    final container = await _createContainer(api);
    final notifier = container.read(worksProvider.notifier);
    await container
        .read(audioSourceProvider.notifier)
        .select(AudioSource.jpAsmr);
    notifier.setJapaneseAsmrSortOption(JapaneseAsmrSortOption.title);
    notifier.setJapaneseAsmrSortDirection(SortDirection.asc);
    unawaited(notifier.loadWorks(targetPage: 3, supersede: true));
    final oldRequest = api.requests.last;

    notifier.setJapaneseAsmrAgeRating(AgeRating.general);
    final newRequest = api.requests.last;
    expect(oldRequest.cancelToken!.isCancelled, isTrue);
    expect(newRequest.page, 1);
    expect(newRequest.japaneseAsmrSort, JapaneseAsmrSortOption.title);
    expect(newRequest.japaneseAsmrDirection, SortDirection.asc);
    expect(newRequest.japaneseAsmrAgeRating, AgeRating.general);
    await _completeRequest(container, newRequest, _response(-20));
    oldRequest.response.complete(_response(-30));
    await oldRequest.response.future;
    expect(container.read(worksProvider).works.single.id, -20);

    notifier.setDisplayMode(DisplayMode.popular);
    expect(api.requests.last.japaneseAsmrAgeRating, AgeRating.all);
    await container
        .read(audioSourceProvider.notifier)
        .select(AudioSource.asmrOne);
    expect(api.requests.last.japaneseAsmrAgeRating, AgeRating.all);
    expect(api.requests.last.japaneseAsmrSort, isNull);
  });

  test(
    'source sidebar sorting ignores legacy default sort preferences',
    () async {
      final api = _DeferredApi();
      final container = await _createContainer(
        api,
        preferences: {
          'default_sort_order': SortOrder.review.value,
          'default_sort_direction': SortDirection.asc.value,
        },
      );
      final notifier = container.read(worksProvider.notifier);

      expect(container.read(worksProvider).sortOption, SortOrder.release);
      expect(container.read(worksProvider).sortDirection, SortDirection.desc);
      expect(
        container.read(worksProvider).japaneseAsmrSortOption,
        JapaneseAsmrSortOption.date,
      );
      expect(
        container.read(worksProvider).japaneseAsmrDirection,
        SortDirection.desc,
      );

      notifier.setSortOption(SortOrder.rating);
      notifier.setSortDirection(SortDirection.asc);
      await container
          .read(audioSourceProvider.notifier)
          .select(AudioSource.jpAsmr);
      expect(api.requests.last.japaneseAsmrSort, JapaneseAsmrSortOption.date);
      expect(api.requests.last.japaneseAsmrDirection, SortDirection.desc);

      notifier.setJapaneseAsmrSortOption(JapaneseAsmrSortOption.title);
      notifier.setJapaneseAsmrSortDirection(SortDirection.asc);
      await container
          .read(audioSourceProvider.notifier)
          .select(AudioSource.asmrOne);

      expect(api.requests.last.order, SortOrder.rating.value);
      expect(api.requests.last.sort, SortDirection.asc.value);
      expect(api.requests.last.japaneseAsmrSort, isNull);
      expect(
        container.read(worksProvider).japaneseAsmrSortOption,
        JapaneseAsmrSortOption.title,
      );

      await container
          .read(audioSourceProvider.notifier)
          .select(AudioSource.jpAsmr);
      expect(api.requests.last.japaneseAsmrSort, JapaneseAsmrSortOption.title);
      expect(api.requests.last.japaneseAsmrDirection, SortDirection.asc);
    },
  );

  test('archive popularity does not change home or comment periods', () async {
    final api = _DeferredApi();
    final container = await _createContainer(api);
    final notifier = container.read(worksProvider.notifier);
    await container
        .read(audioSourceProvider.notifier)
        .select(AudioSource.jpAsmr);
    notifier.setDisplayMode(DisplayMode.popular);
    expect(api.requests.last.japaneseAsmrPeriod, JapaneseAsmrPeriod.week);
    notifier.setJapaneseAsmrPeriod(
      JapaneseAsmrPeriod.archiveMonth,
      archiveDate: DateTime(2026, 1),
    );
    expect(api.requests.last.archiveYear, 2026);
    expect(api.requests.last.archiveMonth, 1);

    notifier.setDisplayMode(DisplayMode.all);
    unawaited(notifier.refresh(resetPage: true));
    expect(api.requests.last.japaneseAsmrSort, JapaneseAsmrSortOption.date);
    expect(api.requests.last.archiveYear, isNull);
    expect(api.requests.last.archiveMonth, isNull);
    notifier.setJapaneseAsmrSortOption(JapaneseAsmrSortOption.comments);
    notifier.setJapaneseAsmrPeriod(JapaneseAsmrPeriod.twoWeeks);
    expect(api.requests.last.japaneseAsmrPeriod, JapaneseAsmrPeriod.twoWeeks);
    expect(api.requests.last.page, 1);

    notifier.setDisplayMode(DisplayMode.popular);
    expect(
      container.read(worksProvider).japaneseAsmrPeriod,
      JapaneseAsmrPeriod.archiveMonth,
    );
  });

  test('new popular period supersedes a late response', () async {
    final api = _DeferredApi();
    final container = await _createContainer(api);
    final notifier = container.read(worksProvider.notifier);
    await container
        .read(audioSourceProvider.notifier)
        .select(AudioSource.jpAsmr);
    notifier.setDisplayMode(DisplayMode.popular);
    final oldRequest = api.requests.last;
    notifier.setJapaneseAsmrPeriod(JapaneseAsmrPeriod.month);
    expect(oldRequest.cancelToken!.isCancelled, isTrue);
    await _completeRequest(container, api.requests.last, _response(-2));
    final unchanged = container.read(worksProvider);
    oldRequest.response.complete(_response(-1));
    await oldRequest.response.future;
    expect(container.read(worksProvider), unchanged);
    expect(container.read(worksProvider).works.single.id, -2);
  });

  test('JP popular pagination continues beyond 100 works', () async {
    final api = _DeferredApi();
    final container = await _createContainer(api);
    final notifier = container.read(worksProvider.notifier);
    await container
        .read(audioSourceProvider.notifier)
        .select(AudioSource.jpAsmr);
    notifier.setDisplayMode(DisplayMode.popular);
    for (var page = 1; page <= 3; page++) {
      if (page > 1) unawaited(notifier.loadMore());
      await _completeRequest(container, api.requests.last, {
        'works': [
          for (var index = 0; index < 40; index++)
            {'id': -(page * 40 + index), 'title': 'Work $page/$index'},
        ],
        'pagination': {'currentPage': page, 'totalCount': 200},
      });
    }
    expect(container.read(worksProvider).works, hasLength(120));
    expect(container.read(worksProvider).hasMore, isTrue);
    unawaited(notifier.loadMore());
    expect(api.requests.last.page, 4);
    expect(api.requests.last.japaneseAsmrSort, JapaneseAsmrSortOption.popular);
  });

  test(
    'a late response from the previous source cannot replace JP results',
    () async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final api = _DeferredApi();
      final container = ProviderContainer(
        overrides: [
          kikoeruApiServiceProvider.overrideWithValue(api),
          subtitleLibraryProvider.overrideWith(
            (ref) => _EmptySubtitleLibrary(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final japaneseResultsApplied = Completer<void>();
      final subscription = container.listen(worksProvider, (_, state) {
        if (state.works.any((work) => work.id == -1726738) &&
            !japaneseResultsApplied.isCompleted) {
          japaneseResultsApplied.complete();
        }
      });
      addTearDown(subscription.close);

      final previousSourceRequest = container
          .read(worksProvider.notifier)
          .loadWorks(targetPage: 1, refresh: true, supersede: true);
      expect(api.requests, hasLength(1));
      expect(api.requests.single.source, AudioSource.asmrOne);

      await container
          .read(audioSourceProvider.notifier)
          .select(AudioSource.jpAsmr);
      expect(api.requests, hasLength(2));
      expect(api.requests.last.source, AudioSource.jpAsmr);
      expect(api.requests.first.cancelToken!.isCancelled, isTrue);

      api.requests.last.response.complete(_response(-1726738));
      await japaneseResultsApplied.future;
      api.requests.first.response.complete(_response(1726738));
      await previousSourceRequest;

      expect(container.read(worksProvider).works.map((work) => work.id), [
        -1726738,
      ]);
    },
  );
}

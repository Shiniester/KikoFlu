import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/japanese_asmr_browse.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/models/sort_options.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart'
    show kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/providers/search_result_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart'
    show PageSizeNotifier, pageSizeProvider;
import 'package:kikoeru_flutter/src/providers/subtitle_library_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/subtitle_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FeedRequest {
  _FeedRequest({
    required this.endpoint,
    required this.page,
    required this.pageSize,
    this.source,
    this.subtitle,
    this.keyword,
    this.conditions = const [],
    this.tagId,
    this.vaId,
    this.recommenderUuid,
    this.cancelToken,
  });

  final String endpoint;
  final int page;
  final int pageSize;
  final AudioSource? source;
  final int? subtitle;
  final String? keyword;
  final List<SearchCondition> conditions;
  final int? tagId;
  final String? vaId;
  final String? recommenderUuid;
  final CancelToken? cancelToken;
  final response = Completer<Map<String, dynamic>>();
}

class _RecordingApi extends KikoeruApiService {
  final requests = <_FeedRequest>[];

  Future<Map<String, dynamic>> _request({
    required String endpoint,
    required int page,
    required int pageSize,
    AudioSource? source,
    int? subtitle,
    String? keyword,
    List<SearchCondition> conditions = const [],
    int? tagId,
    String? vaId,
    String? recommenderUuid,
    CancelToken? cancelToken,
  }) {
    final request = _FeedRequest(
      endpoint: endpoint,
      page: page,
      pageSize: pageSize,
      source: source,
      subtitle: subtitle,
      keyword: keyword,
      conditions: conditions,
      tagId: tagId,
      vaId: vaId,
      recommenderUuid: recommenderUuid,
      cancelToken: cancelToken,
    );
    requests.add(request);
    return request.response.future;
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
    JapaneseAsmrPeriod japaneseAsmrPeriod = JapaneseAsmrPeriod.week,
    int? japaneseAsmrArchiveYear,
    int? japaneseAsmrArchiveMonth,
    AgeRating japaneseAsmrAgeRating = AgeRating.all,
    CancelToken? cancelToken,
  }) => _request(
    endpoint: 'works',
    page: page,
    pageSize: pageSize,
    source: source,
    subtitle: subtitle,
    cancelToken: cancelToken,
  );

  @override
  Future<Map<String, dynamic>> getPopularWorks({
    int page = 1,
    int pageSize = 20,
    String? keyword,
    int? subtitle,
    List<String>? withPlaylistStatus,
    CancelToken? cancelToken,
  }) => _request(
    endpoint: 'popular',
    page: page,
    pageSize: pageSize,
    subtitle: subtitle,
    keyword: keyword,
    cancelToken: cancelToken,
  );

  @override
  Future<Map<String, dynamic>> getRecommendedWorks({
    required String recommenderUuid,
    int page = 1,
    int pageSize = 20,
    String? keyword,
    int? subtitle,
    List<String>? withPlaylistStatus,
    CancelToken? cancelToken,
  }) => _request(
    endpoint: 'recommended',
    page: page,
    pageSize: pageSize,
    subtitle: subtitle,
    keyword: keyword,
    recommenderUuid: recommenderUuid,
    cancelToken: cancelToken,
  );

  @override
  Future<Map<String, dynamic>> getWorksByTag({
    required int tagId,
    int page = 1,
    int pageSize = 40,
    String? order,
    String? sort,
    int? subtitle,
    int? seed,
    CancelToken? cancelToken,
  }) => _request(
    endpoint: 'tag',
    page: page,
    pageSize: pageSize,
    subtitle: subtitle,
    tagId: tagId,
    cancelToken: cancelToken,
  );

  @override
  Future<Map<String, dynamic>> getWorksByVa({
    required String vaId,
    int page = 1,
    int pageSize = 40,
    String? order,
    String? sort,
    int? subtitle,
    int? seed,
    CancelToken? cancelToken,
  }) => _request(
    endpoint: 'va',
    page: page,
    pageSize: pageSize,
    subtitle: subtitle,
    vaId: vaId,
    cancelToken: cancelToken,
  );

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
  }) => _request(
    endpoint: 'search',
    page: page,
    pageSize: pageSize,
    source: source,
    subtitle: subtitle,
    keyword: keyword,
    conditions: conditions,
    cancelToken: cancelToken,
  );
}

class _PageSize20 extends PageSizeNotifier {
  _PageSize20() : super() {
    state = 20;
  }
}

Map<String, dynamic> _response(
  List<int> ids, {
  required int currentPage,
  required int pageSize,
  required int totalCount,
}) => {
  'works': [
    for (final id in ids) {'id': id, 'title': 'Work $id', 'has_subtitle': true},
  ],
  'pagination': {
    'currentPage': currentPage,
    'pageSize': pageSize,
    'totalCount': totalCount,
  },
};

Future<void> _initializeStorage({bool jpAsmr = false}) async {
  SharedPreferences.setMockInitialValues({
    'page_size_preference': 20,
    if (jpAsmr) 'audio_selected_source': 'jpAsmr',
  });
  await StorageService.initCritical(
    preferences: await SharedPreferences.getInstance(),
  );
}

ProviderContainer _container(_RecordingApi api) => ProviderContainer(
  overrides: [
    kikoeruApiServiceProvider.overrideWithValue(api),
    pageSizeProvider.overrideWith((ref) => _PageSize20()),
    subtitleLibraryProvider.overrideWith(
      (ref) => throw StateError('Online feeds must not read local subtitles'),
    ),
  ],
);

bool _matchesWorks(
  WorksState state, {
  required int page,
  required int totalCount,
  required List<int> ids,
}) =>
    !state.isLoading &&
    state.currentPage == page &&
    state.totalCount == totalCount &&
    listEquals(state.works.map((work) => work.id).toList(), ids);

Future<void> _waitForWorks(
  ProviderContainer container, {
  required int page,
  required int totalCount,
  required List<int> ids,
}) async {
  final completed = Completer<void>();
  final subscription = container.listen(worksProvider, (_, state) {
    if (_matchesWorks(state, page: page, totalCount: totalCount, ids: ids)) {
      if (!completed.isCompleted) completed.complete();
    } else if (!state.isLoading &&
        state.error != null &&
        !completed.isCompleted) {
      completed.completeError(TestFailure(state.error!));
    }
  });
  if (_matchesWorks(
    container.read(worksProvider),
    page: page,
    totalCount: totalCount,
    ids: ids,
  )) {
    completed.complete();
  }
  try {
    await completed.future;
  } finally {
    subscription.close();
  }
}

bool _matchesSearch(
  SearchResultState state, {
  required int page,
  required int totalCount,
  required List<int> ids,
}) =>
    !state.isLoading &&
    state.currentPage == page &&
    state.totalCount == totalCount &&
    listEquals(state.works.map((work) => work.id).toList(), ids);

Future<void> _waitForSearch(
  ProviderContainer container, {
  required int page,
  required int totalCount,
  required List<int> ids,
}) async {
  final completed = Completer<void>();
  final subscription = container.listen(searchResultProvider, (_, state) {
    if (_matchesSearch(state, page: page, totalCount: totalCount, ids: ids)) {
      if (!completed.isCompleted) completed.complete();
    } else if (!state.isLoading &&
        state.error != null &&
        !completed.isCompleted) {
      completed.completeError(TestFailure(state.error!));
    }
  });
  if (_matchesSearch(
    container.read(searchResultProvider),
    page: page,
    totalCount: totalCount,
    ids: ids,
  )) {
    completed.complete();
  }
  try {
    await completed.future;
  } finally {
    subscription.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'works subtitle filter starts at page one and follows server-filtered pages',
    () async {
      await _initializeStorage();
      final api = _RecordingApi();
      final container = _container(api);
      addTearDown(container.dispose);
      final notifier = container.read(worksProvider.notifier);

      final firstPage = notifier.loadWorks(targetPage: 1, supersede: true);
      expect(api.requests.single.subtitle, 0);
      expect(api.requests.single.pageSize, 20);
      api.requests.single.response.complete(
        _response(
          List.generate(20, (index) => index + 1),
          currentPage: 1,
          pageSize: 20,
          totalCount: 60,
        ),
      );
      await firstPage;

      final secondPage = notifier.nextPage();
      expect(api.requests.last.page, 2);
      api.requests.last.response.complete(
        _response(
          List.generate(20, (index) => index + 21),
          currentPage: 2,
          pageSize: 20,
          totalCount: 60,
        ),
      );
      await secondPage;

      final filteredResult = _waitForWorks(
        container,
        page: 1,
        totalCount: 21,
        ids: List.generate(20, (index) => index + 101),
      );
      notifier.setSubtitleFilter(SubtitleFilterMode.withSubtitles);
      final filteredPage = api.requests.last;
      expect(filteredPage.page, 1);
      expect(filteredPage.pageSize, 20);
      expect(filteredPage.subtitle, 1);
      filteredPage.response.complete(
        _response(
          List.generate(20, (index) => index + 101),
          currentPage: 1,
          pageSize: 20,
          totalCount: 21,
        ),
      );
      await filteredResult;
      expect(container.read(worksProvider).hasMore, isTrue);

      final filteredNextResult = notifier.nextPage();
      final filteredNextPage = api.requests.last;
      expect(filteredNextPage.page, 2);
      expect(filteredNextPage.pageSize, 20);
      expect(filteredNextPage.subtitle, 1);
      filteredNextPage.response.complete(
        _response([121], currentPage: 2, pageSize: 20, totalCount: 21),
      );
      await filteredNextResult;
      expect(container.read(worksProvider).currentPage, 2);
      expect(container.read(worksProvider).totalCount, 21);
      expect(container.read(worksProvider).works.map((work) => work.id), [121]);
      expect(container.read(worksProvider).hasMore, isFalse);

      final allResult = _waitForWorks(
        container,
        page: 1,
        totalCount: 60,
        ids: List.generate(20, (index) => index + 201),
      );
      notifier.setSubtitleFilter(SubtitleFilterMode.all);
      final allPage = api.requests.last;
      expect(allPage.page, 1);
      expect(allPage.pageSize, 20);
      expect(allPage.subtitle, 0);
      allPage.response.complete(
        _response(
          List.generate(20, (index) => index + 201),
          currentPage: 1,
          pageSize: 20,
          totalCount: 60,
        ),
      );
      await allResult;
    },
  );

  test('popular and recommended feeds send the active subtitle mode', () async {
    await _initializeStorage();
    final api = _RecordingApi();
    final container = _container(api);
    addTearDown(container.dispose);
    final notifier = container.read(worksProvider.notifier);

    final filteredResult = _waitForWorks(
      container,
      page: 1,
      totalCount: 1,
      ids: [1],
    );
    notifier.setSubtitleFilter(SubtitleFilterMode.withSubtitles);
    api.requests.last.response.complete(
      _response([1], currentPage: 1, pageSize: 20, totalCount: 1),
    );
    await filteredResult;

    notifier.setDisplayMode(DisplayMode.popular);
    final popularResult = _waitForWorks(
      container,
      page: 1,
      totalCount: 1,
      ids: [2],
    );
    final popular = api.requests.last;
    expect(popular.endpoint, 'popular');
    expect(popular.subtitle, 1);
    expect(popular.pageSize, 20);
    popular.response.complete(
      _response([2], currentPage: 1, pageSize: 20, totalCount: 1),
    );
    await popularResult;

    notifier.setDisplayMode(DisplayMode.recommended);
    final recommendedResult = _waitForWorks(
      container,
      page: 1,
      totalCount: 1,
      ids: [3],
    );
    final recommended = api.requests.last;
    expect(recommended.endpoint, 'recommended');
    expect(recommended.subtitle, 1);
    expect(recommended.pageSize, 20);
    recommended.response.complete(
      _response([3], currentPage: 1, pageSize: 20, totalCount: 1),
    );
    await recommendedResult;
  });

  test(
    'a subtitle change clears other mode snapshots and invalidates old requests',
    () async {
      await _initializeStorage();
      final api = _RecordingApi();
      final container = _container(api);
      addTearDown(container.dispose);
      final notifier = container.read(worksProvider.notifier);

      final initialLoad = notifier.loadWorks(targetPage: 1, supersede: true);
      api.requests.last.response.complete(
        _response([1], currentPage: 1, pageSize: 20, totalCount: 40),
      );
      await initialLoad;

      final staleAllLoad = notifier.loadWorks(
        targetPage: 1,
        refresh: true,
        supersede: true,
      );
      final staleAllRequest = api.requests.last;
      notifier.setDisplayMode(DisplayMode.popular);

      final popularResult = _waitForWorks(
        container,
        page: 1,
        totalCount: 40,
        ids: [2],
      );
      api.requests.last.response.complete(
        _response([2], currentPage: 1, pageSize: 20, totalCount: 40),
      );
      await popularResult;

      final filteredResult = _waitForWorks(
        container,
        page: 1,
        totalCount: 1,
        ids: [3],
      );
      notifier.setSubtitleFilter(SubtitleFilterMode.withSubtitles);
      expect(staleAllRequest.cancelToken!.isCancelled, isTrue);
      final filteredPopular = api.requests.last;
      expect(filteredPopular.endpoint, 'popular');
      expect(filteredPopular.subtitle, 1);
      filteredPopular.response.complete(
        _response([3], currentPage: 1, pageSize: 20, totalCount: 1),
      );
      await filteredResult;

      notifier.setDisplayMode(DisplayMode.all);
      final filteredAllResult = _waitForWorks(
        container,
        page: 1,
        totalCount: 1,
        ids: [4],
      );
      final filteredAll = api.requests.last;
      expect(filteredAll.endpoint, 'works');
      expect(filteredAll.subtitle, 1);
      expect(filteredAll.page, 1);
      filteredAll.response.complete(
        _response([4], currentPage: 1, pageSize: 20, totalCount: 1),
      );
      await filteredAllResult;

      staleAllRequest.response.complete(
        _response([99], currentPage: 1, pageSize: 20, totalCount: 40),
      );
      await staleAllLoad;
      expect(
        container
            .read(worksProvider)
            .modeStates[DisplayMode.all]!
            .works
            .map((work) => work.id),
        [4],
      );
    },
  );

  test(
    'search uses server-filtered pages for keyword, tag, and VA feeds',
    () async {
      await _initializeStorage();
      final api = _RecordingApi();
      final container = _container(api);
      addTearDown(container.dispose);
      final notifier = container.read(searchResultProvider.notifier);

      final initialSearch = notifier.initializeSearch(keyword: 'voice');
      final initial = api.requests.last;
      expect(initial.endpoint, 'search');
      expect(initial.keyword, 'voice');
      expect(initial.subtitle, 0);
      expect(initial.pageSize, 20);
      initial.response.complete(
        _response([1], currentPage: 1, pageSize: 20, totalCount: 1),
      );
      await initialSearch;

      final filteredResult = _waitForSearch(
        container,
        page: 1,
        totalCount: 21,
        ids: List.generate(20, (index) => index + 101),
      );
      notifier.toggleSubtitleFilter();
      final filteredPage = api.requests.last;
      expect(filteredPage.endpoint, 'search');
      expect(filteredPage.page, 1);
      expect(filteredPage.subtitle, 1);
      expect(filteredPage.pageSize, 20);
      filteredPage.response.complete(
        _response(
          List.generate(20, (index) => index + 101),
          currentPage: 1,
          pageSize: 20,
          totalCount: 21,
        ),
      );
      await filteredResult;
      expect(container.read(searchResultProvider).hasMore, isTrue);

      final filteredNextResult = _waitForSearch(
        container,
        page: 2,
        totalCount: 21,
        ids: [121],
      );
      final filteredNextLoad = notifier.goToPage(2);
      final filteredNextPage = api.requests.last;
      expect(filteredNextPage.page, 2);
      expect(filteredNextPage.subtitle, 1);
      expect(filteredNextPage.pageSize, 20);
      filteredNextPage.response.complete(
        _response([121], currentPage: 2, pageSize: 20, totalCount: 21),
      );
      await filteredNextLoad;
      await filteredNextResult;
      expect(container.read(searchResultProvider).totalCount, 21);
      expect(container.read(searchResultProvider).hasMore, isFalse);

      final tagResult = _waitForSearch(
        container,
        page: 1,
        totalCount: 1,
        ids: [201],
      );
      final tagLoad = notifier.initializeSearch(
        keyword: '',
        searchParams: {'tagId': 42},
      );
      final tag = api.requests.last;
      expect(tag.endpoint, 'tag');
      expect(tag.tagId, 42);
      expect(tag.subtitle, 1);
      expect(tag.pageSize, 20);
      tag.response.complete(
        _response([201], currentPage: 1, pageSize: 20, totalCount: 1),
      );
      await tagLoad;
      await tagResult;

      final vaResult = _waitForSearch(
        container,
        page: 1,
        totalCount: 1,
        ids: [301],
      );
      final vaLoad = notifier.initializeSearch(
        keyword: '',
        searchParams: {'vaId': 'va-1'},
      );
      final va = api.requests.last;
      expect(va.endpoint, 'va');
      expect(va.vaId, 'va-1');
      expect(va.subtitle, 1);
      expect(va.pageSize, 20);
      va.response.complete(
        _response([301], currentPage: 1, pageSize: 20, totalCount: 1),
      );
      await vaLoad;
      await vaResult;
    },
  );

  test('JP-ASMR skips online subtitle filtering', () async {
    await _initializeStorage(jpAsmr: true);
    final worksApi = _RecordingApi();
    final worksContainer = _container(worksApi);
    addTearDown(worksContainer.dispose);
    final worksNotifier = worksContainer.read(worksProvider.notifier);

    worksNotifier.setSubtitleFilter(SubtitleFilterMode.withSubtitles);
    expect(worksContainer.read(worksProvider).subtitleFilter, 0);
    final worksLoad = worksNotifier.loadWorks(targetPage: 1, supersede: true);
    expect(worksApi.requests.single.source, AudioSource.jpAsmr);
    expect(worksApi.requests.single.subtitle, isNull);
    worksApi.requests.single.response.complete(
      _response([1], currentPage: 1, pageSize: 20, totalCount: 1),
    );
    await worksLoad;

    final searchApi = _RecordingApi();
    final searchContainer = _container(searchApi);
    addTearDown(searchContainer.dispose);
    final searchNotifier = searchContainer.read(searchResultProvider.notifier);
    searchNotifier.toggleSubtitleFilter();
    expect(searchContainer.read(searchResultProvider).subtitleFilter, 0);
    final searchLoad = searchNotifier.initializeSearch(keyword: 'voice');
    expect(searchApi.requests.single.source, AudioSource.jpAsmr);
    expect(searchApi.requests.single.subtitle, isNull);
    searchApi.requests.single.response.complete(
      _response([2], currentPage: 1, pageSize: 20, totalCount: 1),
    );
    await searchLoad;
  });

  test('JP history query keeps taxonomy paths and unknown totals', () async {
    await _initializeStorage();
    final api = _RecordingApi();
    final container = _container(api);
    addTearDown(container.dispose);
    final notifier = container.read(searchResultProvider.notifier);
    const directoryPath = '/tag/%e8%80%b3/';

    final firstLoad = notifier.initializeSearch(
      keyword: '',
      searchParams: {
        'source': AudioSource.jpAsmr.name,
        'conditions': [
          {
            'searchType': SearchType.tag.name,
            'type': 'Tag',
            'value': 'Name differs from the slug',
            'sourcePath': directoryPath,
            'isExclude': false,
          },
        ],
      },
    );
    final first = api.requests.single;
    expect(first.source, AudioSource.jpAsmr);
    expect(first.keyword, '');
    expect(first.conditions.single.sourcePath, directoryPath);
    first.response.complete({
      'works': [
        {'id': -1, 'title': 'Japanese work'},
      ],
      'pagination': {
        'currentPage': 1,
        'pageSize': 20,
        'totalCount': null,
        'hasMore': true,
      },
    });
    await firstLoad;

    final state = container.read(searchResultProvider);
    expect(state.totalCountKnown, isFalse);
    expect(state.totalCount, 0);
    expect(state.hasMore, isTrue);

    final nextLoad = notifier.goToPage(2);
    final second = api.requests.last;
    expect(second.source, AudioSource.jpAsmr);
    expect(second.conditions.single.sourcePath, directoryPath);
    expect(second.page, 2);
    second.response.complete({
      'works': <dynamic>[],
      'pagination': {
        'currentPage': 2,
        'pageSize': 20,
        'totalCount': null,
        'hasMore': false,
      },
    });
    await nextLoad;
    expect(container.read(searchResultProvider).hasMore, isFalse);
  });
}

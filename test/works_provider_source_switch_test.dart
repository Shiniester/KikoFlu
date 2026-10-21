import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/japanese_asmr_browse.dart';
import 'package:kikoeru_flutter/src/models/sort_options.dart';
import 'package:kikoeru_flutter/src/providers/audio_source_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart'
    show kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/providers/subtitle_library_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
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
    this.japaneseAsmrPeriod = JapaneseAsmrPeriod.week,
    this.archiveYear,
    this.archiveMonth,
  });

  final AudioSource source;
  final CancelToken? cancelToken;
  final int page;
  final String? order;
  final String? sort;
  final JapaneseAsmrSortOption? japaneseAsmrSort;
  final SortDirection japaneseAsmrDirection;
  final JapaneseAsmrPeriod japaneseAsmrPeriod;
  final int? archiveYear;
  final int? archiveMonth;
  final response = Completer<Map<String, dynamic>>();
}

class _DeferredApi extends KikoeruApiService {
  final requests = <_Request>[];

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
      japaneseAsmrPeriod: japaneseAsmrPeriod,
      archiveYear: japaneseAsmrArchiveYear,
      archiveMonth: japaneseAsmrArchiveMonth,
    );
    requests.add(request);
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
    if (!state.isLoading && !applied.isCompleted) applied.complete();
  });
  request.response.complete(response);
  await applied.future;
  subscription.close();
}

void main() {
  test(
    'JP sorting preserves ASMR.ONE sorting across source switches',
    () async {
      final api = _DeferredApi();
      final container = await _createContainer(api);
      final notifier = container.read(worksProvider.notifier);
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
    },
  );

  test('saved unsupported defaults fall back to latest JP works', () async {
    final api = _DeferredApi();
    final container = await _createContainer(
      api,
      preferences: {
        'default_sort_order': SortOrder.rating.value,
        'default_sort_direction': SortDirection.asc.value,
      },
    );
    final loaded = Completer<void>();
    final subscription = container.listen(defaultSortProvider, (_, state) {
      if (state.order == SortOrder.rating && !loaded.isCompleted) {
        loaded.complete();
      }
    });
    await loaded.future;
    subscription.close();

    await container
        .read(audioSourceProvider.notifier)
        .select(AudioSource.jpAsmr);
    final notifier = container.read(worksProvider.notifier);
    unawaited(notifier.loadWorks(targetPage: 1, supersede: true));
    expect(api.requests.last.japaneseAsmrSort, JapaneseAsmrSortOption.date);
    expect(api.requests.last.japaneseAsmrDirection, SortDirection.desc);

    notifier.applyDefaultSort(SortOrder.review, SortDirection.asc);
    expect(api.requests.last.japaneseAsmrSort, JapaneseAsmrSortOption.comments);
    expect(api.requests.last.japaneseAsmrDirection, SortDirection.asc);
  });

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

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/my_reviews_provider.dart';
import 'package:kikoeru_flutter/src/providers/subtitle_library_provider.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/subtitle_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReviewApi extends KikoeruApiService {
  final requests = <(int, int, String?)>[];
  List<Map<String, dynamic>> works = [
    for (var id = 1; id <= 6; id++)
      {'id': id, 'title': 'Work $id', 'has_subtitle': id >= 3 && id <= 5},
  ];
  Completer<Map<String, dynamic>>? pending;
  Completer<void>? requestStarted;

  @override
  Future<Map<String, dynamic>> getMyReviews({
    int page = 1,
    int pageSize = 20,
    String? filter,
    String order = 'updated_at',
    String sort = 'desc',
    CancelToken? cancelToken,
  }) async {
    requests.add((page, pageSize, filter));
    requestStarted?.complete();
    requestStarted = null;
    if (pending != null) return pending!.future;
    return {
      'reviews': works.skip((page - 1) * pageSize).take(pageSize).map((work) {
        return work['id'] == 4 ? {'work': work} : work;
      }).toList(),
      'pagination': {'totalCount': works.length},
    };
  }
}

class _LocalSubtitles extends SubtitleLibraryNotifier {
  @override
  Future<void> refresh() async {
    state = {1};
  }
}

Future<void> _changeAndWait(
  ProviderContainer container,
  void Function() action,
) async {
  final done = Completer<void>();
  var started = false;
  final subscription = container.listen(myReviewsProvider, (_, state) {
    if (state.isLoading) started = true;
    if (started && !state.isLoading && !done.isCompleted) done.complete();
  });
  try {
    action();
    await done.future;
  } finally {
    subscription.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ReviewApi api;
  late ProviderContainer container;
  late MyReviewsNotifier notifier;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    api = _ReviewApi();
    container = ProviderContainer(
      overrides: [
        myReviewsProvider.overrideWith(
          (ref) => MyReviewsNotifier(api, ref, initialPageSize: 2),
        ),
        subtitleLibraryProvider.overrideWith((ref) => _LocalSubtitles()),
      ],
    );
    notifier = container.read(myReviewsProvider.notifier);
    await notifier.preferencesReady;
    addTearDown(container.dispose);
  });

  test('filters the complete marks collection before paginating', () async {
    await notifier.load(targetPage: 2);
    api.requests.clear();
    await _changeAndWait(container, () {
      notifier.setSubtitleFilter(SubtitleFilterMode.withSubtitles);
    });

    var state = container.read(myReviewsProvider);
    expect(state.currentPage, 1);
    expect(state.effectivePageSize, 2);
    expect(state.works.map((work) => work.id), [3, 4]);
    expect(state.totalCount, 3);
    expect(state.hasMore, isTrue);
    expect(api.requests.map((request) => request.$1), [1, 2, 3]);

    final fetchedPages = api.requests.length;
    await notifier.nextPage();
    state = container.read(myReviewsProvider);
    expect(state.works.map((work) => work.id), [5]);
    expect(state.hasMore, isFalse);
    await notifier.previousPage();
    expect(container.read(myReviewsProvider).works.map((work) => work.id), [
      3,
      4,
    ]);
    expect(api.requests, hasLength(fetchedPages));

    await _changeAndWait(container, () {
      notifier.setSubtitleFilter(SubtitleFilterMode.all);
    });
    expect(container.read(myReviewsProvider).currentPage, 1);
    expect(container.read(myReviewsProvider).works.map((work) => work.id), [
      1,
      2,
    ]);
    expect(container.read(myReviewsProvider).totalCount, 6);
  });

  test('refresh and mark changes replace the filtered collection', () async {
    await _changeAndWait(container, () {
      notifier.setSubtitleFilter(SubtitleFilterMode.withSubtitles);
    });
    api.works = [
      {'id': 8, 'title': 'New work', 'has_subtitle': true},
    ];
    await notifier.refresh();
    expect(container.read(myReviewsProvider).works.single.id, 8);
    expect(container.read(myReviewsProvider).totalCount, 1);

    api.works = [];
    await _changeAndWait(container, () {
      notifier.changeFilter(MyReviewFilter.marked);
    });
    expect(api.requests.last.$3, 'marked');
    expect(container.read(myReviewsProvider).works, isEmpty);
    expect(container.read(myReviewsProvider).totalCount, 0);
    expect(container.read(myReviewsProvider).hasMore, isFalse);
  });

  test('a refresh supersedes an in-flight subtitle scan', () async {
    await _changeAndWait(container, () {
      notifier.setSubtitleFilter(SubtitleFilterMode.withSubtitles);
    });
    final pending = Completer<Map<String, dynamic>>();
    final requested = Completer<void>();
    api.pending = pending;
    api.requestStarted = requested;
    final previous = notifier.load(refresh: true);
    await requested.future;
    api.pending = null;
    api.works = [
      {'id': 8, 'title': 'Updated mark', 'has_subtitle': true},
    ];
    await notifier.load(refresh: true);
    pending.complete({
      'works': [
        {'id': 99, 'title': 'Old mark', 'has_subtitle': true},
      ],
      'pagination': {'totalCount': 1},
    });
    await previous;
    expect(container.read(myReviewsProvider).works.map((work) => work.id), [8]);
  });

  test(
    'a superseded subtitle scan cannot overwrite unfiltered results',
    () async {
      await _changeAndWait(container, () {
        notifier.setSubtitleFilter(SubtitleFilterMode.withSubtitles);
      });
      final pending = Completer<Map<String, dynamic>>();
      api.pending = pending;
      final requested = Completer<void>();
      api.requestStarted = requested;
      final previous = notifier.load(refresh: true, supersede: true);
      await requested.future;
      api.pending = null;
      await _changeAndWait(container, () {
        notifier.setSubtitleFilter(SubtitleFilterMode.all);
      });
      pending.complete({
        'works': [
          {'id': 99, 'title': 'Old subtitle result', 'has_subtitle': true},
        ],
        'pagination': {'totalCount': 1},
      });
      await previous;
      expect(container.read(myReviewsProvider).works.map((work) => work.id), [
        1,
        2,
      ]);
    },
  );
}

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/providers/unified_search_history_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart'
    show LayoutType;
import 'package:kikoeru_flutter/src/screens/search_screen.dart';
import 'package:kikoeru_flutter/src/screens/work_detail_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/works_grid_view.dart';

class _SearchCall {
  const _SearchCall(this.keyword, this.order, this.sort, this.subtitle);

  final String keyword;
  final String? order;
  final String? sort;
  final int? subtitle;
}

class _AudioSearchApi extends KikoeruApiService {
  final calls = <_SearchCall>[];
  Future<Map<String, dynamic>> Function()? nextReply;

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
  }) async {
    calls.add(_SearchCall(keyword, order, sort, subtitle));
    final reply = nextReply;
    nextReply = null;
    if (reply != null) return reply();
    return _response('Result ${calls.length}');
  }

  @override
  Future<Map<String, dynamic>> getWork(
    int workId, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async => {'id': workId, 'title': 'Detail result'};

  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async => [];

  Map<String, dynamic> _response(String title) => {
    'works': [
      {'id': 1, 'title': title},
    ],
    'pagination': {'totalCount': 1, 'hasMore': false},
  };
}

Future<void> _pumpSearch(
  WidgetTester tester,
  _AudioSearchApi api, {
  SearchScreen screen = const SearchScreen(),
  double textScale = 1,
}) async {
  final preferences = await SharedPreferences.getInstance();
  await StorageService.initCritical(preferences: preferences);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        kikoeruApiServiceProvider.overrideWithValue(api),
        downloadSummaryProvider.overrideWith(
          (ref) => Stream.value(const DownloadTaskSummary.empty()),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, Object?> _audioPayload({
  required String keyword,
  required String displayText,
  String sortOption = 'release',
  String sortDirection = 'desc',
  int subtitleFilter = 0,
}) {
  final conditions = [
    {
      'type': 'Keyword',
      'searchType': 'keyword',
      'value': keyword,
      'isExclude': false,
    },
  ];
  return {
    'keyword': keyword,
    'displayText': displayText,
    'searchParams': {'keyword': keyword, 'conditions': conditions},
    'conditions': conditions,
    'sortOption': sortOption,
    'sortDirection': sortDirection,
    'subtitleFilter': subtitleFilter,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets(
    'search submits and updates filters on the same page while keeping prior results after failure',
    (tester) async {
      final api = _AudioSearchApi();
      api.nextReply = () async => api._response('First result');
      await _pumpSearch(tester, api);

      final input = find.byType(TextField).first;
      await tester.enterText(input, 'first');
      await tester.tap(find.byKey(const ValueKey('audio-search-submit')));
      await tester.pumpAndSettle();
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.text('First result'), findsOneWidget);

      api.nextReply = () async => api._response('Filtered result');
      await tester.enterText(find.byType(TextField).first, 'filtered');
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      expect(api.calls.map((call) => call.keyword), ['first', 'filtered']);
      expect(find.text('Keyword: filtered'), findsOneWidget);
      expect(find.text('Filtered result'), findsOneWidget);

      final update = Completer<Map<String, dynamic>>();
      api.nextReply = () => update.future;
      await tester.enterText(find.byType(TextField).first, 'failure');
      await tester.tap(find.byKey(const ValueKey('audio-search-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final l10n = await S.delegate.load(const Locale('en'));
      expect(find.text('Filtered result'), findsOneWidget);
      expect(find.text(l10n.searchUpdating), findsOneWidget);

      update.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('Filtered result'), findsOneWidget);
      expect(find.text(l10n.searchUpdateFailedShowingPrevious), findsOneWidget);
      final retryButton = find.widgetWithText(TextButton, l10n.retry);
      expect(retryButton, findsOneWidget);

      api.nextReply = () async => api._response('Retried result');
      await tester.tap(retryButton);
      await tester.pumpAndSettle();
      expect(find.text('Filtered result'), findsNothing);
      expect(find.text('Retried result'), findsOneWidget);
      expect(api.calls, hasLength(4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'result sorting and subtitle filtering use the current input and save its label',
    (tester) async {
      final api = _AudioSearchApi();
      await _pumpSearch(tester, api);
      final l10n = await S.delegate.load(const Locale('en'));
      final input = find.byType(TextField).first;

      await tester.enterText(input, 'initial query');
      await tester.tap(find.byKey(const ValueKey('audio-search-submit')));
      await tester.pumpAndSettle();

      await tester.enterText(input, 'subtitle query');
      await tester.tap(find.byTooltip(l10n.feedSettings));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('audio-search-subtitle-setting')),
      );
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(2));
      expect(api.calls[1].keyword, 'subtitle query');
      expect(api.calls[1].subtitle, 1);

      await tester.tap(find.byTooltip(l10n.feedSettings));
      await tester.pumpAndSettle();
      await tester.enterText(input, 'sorted query');
      await tester.tap(find.byTooltip(l10n.feedSettings));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('audio-search-sort-setting')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.sortRating).last);
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(3));
      expect(api.calls[2].keyword, 'sorted query');
      expect(api.calls[2].order, 'rate_average_2dp');
      expect(api.calls[2].subtitle, 1);

      await tester.tap(find.byTooltip(l10n.feedSettings));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.searchHistory));
      await tester.pumpAndSettle();
      expect(find.text('Keyword: sorted query'), findsOneWidget);
      expect(find.text('Result 3'), findsNothing);
      await tester.tap(find.byTooltip(l10n.searchHistory));
      await tester.pumpAndSettle();
      expect(find.text('Result 3'), findsOneWidget);
      expect(api.calls, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('advanced filters search an unsubmitted input immediately', (
    tester,
  ) async {
    final api = _AudioSearchApi();
    await _pumpSearch(tester, api);
    final l10n = await S.delegate.load(const Locale('en'));

    await tester.enterText(find.byType(TextField).first, 'age filter');
    await tester.tap(find.byTooltip(l10n.advancedFilter));
    await tester.pumpAndSettle();
    final ageRating = find.byType(DropdownButtonFormField<AgeRating>);
    expect(ageRating, findsOneWidget);
    await tester.tap(ageRating);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.ageRatingGeneral).last);
    await tester.pumpAndSettle();
    expect(ageRating, findsOneWidget);
    expect(api.calls, hasLength(1));
    expect(api.calls.single.keyword, 'age filter \$age:general\$');
    expect(find.text('Result 1'), findsOneWidget);
    expect(
      find.text('${l10n.ageRatingLabel}: ${l10n.ageRatingGeneral}'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('global search uses the home layout during loading and refresh', (
    tester,
  ) async {
    final api = _AudioSearchApi();
    api.nextReply = () async => api._response('First layout result');
    await _pumpSearch(tester, api);
    final l10n = await S.delegate.load(const Locale('en'));

    await tester.tap(find.byTooltip(l10n.feedSettings));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('audio-search-layout-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.feedSettings));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'layout query');
    await tester.tap(find.byKey(const ValueKey('audio-search-submit')));
    await tester.pumpAndSettle();
    expect(find.text('First layout result'), findsOneWidget);
    expect(
      tester.widget<WorksGridView>(find.byType(WorksGridView)).layoutType,
      LayoutType.smallGrid,
    );

    final nextReply = Completer<Map<String, dynamic>>();
    api.nextReply = () => nextReply.future;
    await tester.enterText(find.byType(TextField).first, 'refresh query');
    await tester.tap(find.byKey(const ValueKey('audio-search-submit')));
    await tester.pump();
    expect(
      tester.widget<WorksGridView>(find.byType(WorksGridView)).layoutType,
      LayoutType.smallGrid,
    );

    nextReply.complete(api._response('Second layout result'));
    await tester.pumpAndSettle();
    expect(find.text('Second layout result'), findsOneWidget);
    expect(
      tester.widget<WorksGridView>(find.byType(WorksGridView)).layoutType,
      LayoutType.smallGrid,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('audio search header scrolls above the landscape keyboard', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 360);
    addTearDown(tester.view.reset);
    await _pumpSearch(tester, _AudioSearchApi());

    final input = find.byType(TextField).first;
    await tester.enterText(input, 'landscape query');
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('audio-search-submit')));
    await tester.pumpAndSettle();
    await tester.tap(input);
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(WorksGridView)).height, greaterThan(0));
    final header = find.byKey(const ValueKey('audio-search-top-controls'));
    final selected = find.descendant(
      of: header,
      matching: find.text('Keyword: landscape query'),
    );
    await tester.ensureVisible(selected);
    await tester.pumpAndSettle();
    expect(selected.hitTestable(), findsOneWidget);
    await tester.ensureVisible(input);
    await tester.pumpAndSettle();
    expect(input.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 840.0]) {
    testWidgets(
      'audio search header fits at $width with keyboard and large text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 800);
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(tester.view.reset);

        await _pumpSearch(tester, _AudioSearchApi(), textScale: 1.6);
        final l10n = await S.delegate.load(const Locale('en'));
        expect(
          find.byKey(const ValueKey('audio-search-type-row')),
          findsOneWidget,
        );
        for (final type in [
          l10n.searchTypeKeyword,
          l10n.searchTypeTag,
          l10n.searchTypeVa,
          l10n.searchTypeCircle,
          l10n.searchTypeRjNumber,
        ]) {
          expect(find.text(type), findsOneWidget);
        }
        await tester.tap(find.byTooltip(l10n.advancedFilter));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('audio-search-submit')),
          findsOneWidget,
        );
        expect(find.byType(DropdownButtonFormField<AgeRating>), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('history restores sorting and stays isolated by audio source', (
    tester,
  ) async {
    const globalContext = UnifiedSearchHistoryContext(
      contentType: 'audio',
      entryScope: 'global-works',
      source: 'asmrOne',
    );
    const japaneseContext = UnifiedSearchHistoryContext(
      contentType: 'audio',
      entryScope: 'global-works',
      source: 'jpAsmr',
    );
    final saved = UnifiedSearchHistoryEntry(
      id: 'saved',
      context: globalContext,
      payload: _audioPayload(
        keyword: 'saved keyword',
        displayText: 'Saved search',
        sortOption: 'rating',
        sortDirection: 'asc',
        subtitleFilter: 1,
      ),
      timestamp: DateTime.utc(2026, 10, 31),
    );
    final hidden = UnifiedSearchHistoryEntry(
      id: 'japanese',
      context: japaneseContext,
      payload: _audioPayload(
        keyword: 'Japanese only',
        displayText: 'Japanese only',
      ),
      timestamp: DateTime.utc(2026, 10, 30),
    );
    SharedPreferences.setMockInitialValues({
      UnifiedSearchHistoryNotifier.preferenceKey: jsonEncode({
        'version': 1,
        'legacyMigrationComplete': true,
        'records': [saved.toJson(), hidden.toJson()],
      }),
    });
    final api = _AudioSearchApi();
    await _pumpSearch(tester, api);
    await tester.pumpAndSettle();

    expect(find.text('Saved search'), findsOneWidget);
    expect(find.text('Japanese only'), findsNothing);
    await tester.tap(find.text('Saved search'));
    await tester.pumpAndSettle();

    expect(api.calls.single.keyword, 'saved keyword');
    expect(api.calls.single.order, 'rate_average_2dp');
    expect(api.calls.single.sort, 'asc');
    expect(api.calls.single.subtitle, 1);
    expect(find.text('Result 1'), findsOneWidget);
  });

  testWidgets('returning from a detail keeps the unified search page', (
    tester,
  ) async {
    final api = _AudioSearchApi();
    api.nextReply = () async => api._response('Detail result');
    await _pumpSearch(tester, api);

    await tester.enterText(find.byType(TextField).first, 'detail');
    await tester.tap(find.byKey(const ValueKey('audio-search-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Detail result'), findsOneWidget);

    await tester.tap(find.text('Detail result'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkDetailScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.text('Detail result'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

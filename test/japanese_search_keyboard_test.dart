import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/providers/audio_source_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/providers/unified_search_history_provider.dart';
import 'package:kikoeru_flutter/src/screens/search_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';

class _JapaneseSourceNotifier extends AudioSourceNotifier {
  _JapaneseSourceNotifier() {
    state = AudioSource.jpAsmr;
  }
}

class _SearchCall {
  const _SearchCall({
    required this.keyword,
    required this.source,
    required this.conditions,
    required this.ageRating,
    required this.page,
  });

  final String keyword;
  final AudioSource source;
  final List<SearchCondition> conditions;
  final AgeRating ageRating;
  final int page;
}

class _CatalogApi extends KikoeruApiService {
  final catalogTypes = <SearchType>[];
  final tagCatalogRequests = <CancelToken?>[];
  final tagSearchIds = <int>[];
  List<Map<String, dynamic>> asmrTags = [
    {'id': 999999, 'name': '耳かき', 'count': 5},
  ];
  final japaneseTags = <Map<String, dynamic>>[
    {
      'id': -77,
      'name': '耳かき',
      'names': {
        'ja': '耳かき',
        'en': 'Ear Cleaning',
        'fr': 'Nettoyage oreilles',
      },
      'count': 5,
    },
  ];
  final tagCatalogGate = Completer<List<dynamic>>();
  bool holdTagCatalog = false;
  final searchCalls = <_SearchCall>[];

  @override
  Future<List<dynamic>> getAllTags({CancelToken? cancelToken}) {
    tagCatalogRequests.add(cancelToken);
    if (holdTagCatalog) return tagCatalogGate.future;
    return Future.value(asmrTags);
  }

  @override
  Future<List<Map<String, dynamic>>> getSearchCatalog(
    SearchType type, {
    CancelToken? cancelToken,
  }) async {
    catalogTypes.add(type);
    return japaneseTags;
  }

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
  }) async {
    tagSearchIds.add(tagId);
    return {
      'works': <dynamic>[],
      'pagination': {'totalCount': 0, 'hasMore': false},
    };
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
    AgeRating ageRating = AgeRating.all,
    CancelToken? cancelToken,
  }) async {
    searchCalls.add(
      _SearchCall(
        keyword: keyword,
        source: source,
        conditions: List.unmodifiable(conditions),
        ageRating: ageRating,
        page: page,
      ),
    );
    return {
      'works': <dynamic>[],
      'pagination': {'totalCount': 0, 'hasMore': false},
    };
  }
}

Future<void> _pumpSearchScreen(
  WidgetTester tester, {
  required _CatalogApi api,
  required AudioSourceNotifier sourceNotifier,
  Widget screen = const SearchScreen(),
  Locale locale = const Locale('zh'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        kikoeruApiServiceProvider.overrideWithValue(api),
        audioSourceProvider.overrideWith((ref) => sourceNotifier),
        downloadSummaryProvider.overrideWith(
          (ref) => Stream.value(const DownloadTaskSummary.empty()),
        ),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectTag(
  WidgetTester tester, {
  Locale locale = const Locale('zh'),
}) async {
  final l10n = await S.delegate.load(locale);
  await tester.tap(find.text(l10n.searchTypeTag));
  await tester.pumpAndSettle();
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
    'JP search exposes keyword, category candidates, and age filter',
    (tester) async {
      final api = _CatalogApi();
      await _pumpSearchScreen(
        tester,
        api: api,
        sourceNotifier: _JapaneseSourceNotifier(),
      );
      final strings = await S.delegate.load(const Locale('zh'));
      expect(find.text(strings.searchTypeKeyword), findsOneWidget);
      expect(find.text(strings.searchTypeRjNumber), findsOneWidget);
      expect(find.text(strings.searchTypeTag), findsOneWidget);
      expect(find.text(strings.searchTypeVa), findsOneWidget);
      expect(find.text(strings.searchTypeCircle), findsOneWidget);
      expect(
        find.byKey(const ValueKey('audio-search-sort-button')),
        findsOneWidget,
      );

      final field = find.byType(TextField).first;
      await tester.tap(field);
      await tester.enterText(field, 'ear rubbing');
      await tester.tap(find.byKey(const ValueKey('audio-search-submit')));
      await tester.pumpAndSettle();
      expect(api.searchCalls.single.source, AudioSource.jpAsmr);
      expect(api.searchCalls.single.keyword, 'ear rubbing');
      expect(api.searchCalls.single.conditions, isEmpty);
      expect(
        find.byKey(const ValueKey('audio-search-subtitle-toggle')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('audio-search-sort-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('audio-search-advanced-filter')),
        findsNothing,
      );
      expect(api.catalogTypes, isEmpty);
      expect(api.tagCatalogRequests, isEmpty);

      await tester.tap(find.text(strings.searchTypeRjNumber));
      await tester.pumpAndSettle();
      final rjField = find.byType(TextField).first;
      await tester.enterText(rjField, '12345');
      await tester.tap(find.byKey(const ValueKey('audio-search-submit')));
      await tester.pumpAndSettle();
      expect(api.searchCalls, hasLength(2));
      expect(api.searchCalls.last.source, AudioSource.jpAsmr);
      expect(api.searchCalls.last.keyword, 'RJ12345');
      expect(api.searchCalls.last.conditions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('JP translated candidate submits its original name', (
    tester,
  ) async {
    final api = _CatalogApi();
    await _pumpSearchScreen(
      tester,
      api: api,
      sourceNotifier: _JapaneseSourceNotifier(),
      locale: const Locale('en'),
    );
    await _selectTag(tester, locale: const Locale('en'));

    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.enterText(field, 'Nettoyage');
    await tester.pumpAndSettle();
    expect(find.text('Ear Cleaning (5)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(api.catalogTypes, [SearchType.tag]);
    expect(api.searchCalls, hasLength(1));
    expect(api.searchCalls.single.keyword, '耳かき');
    expect(api.searchCalls.single.source, AudioSource.jpAsmr);
    expect(api.searchCalls.single.conditions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'JP search button submits translated candidate by original name',
    (tester) async {
      final api = _CatalogApi();
      await _pumpSearchScreen(
        tester,
        api: api,
        sourceNotifier: _JapaneseSourceNotifier(),
        locale: const Locale('en'),
      );
      await _selectTag(tester, locale: const Locale('en'));

      final field = find.byType(TextField).first;
      await tester.tap(field);
      await tester.enterText(field, 'Nettoyage oreilles');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('audio-search-submit')));
      await tester.pumpAndSettle();

      expect(api.searchCalls.single.keyword, '耳かき');
      expect(api.searchCalls.single.conditions, isEmpty);
      expect(api.searchCalls.single.source, AudioSource.jpAsmr);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('JP unmatched directory input falls back to keyword search', (
    tester,
  ) async {
    final api = _CatalogApi();
    await _pumpSearchScreen(
      tester,
      api: api,
      sourceNotifier: _JapaneseSourceNotifier(),
    );
    await _selectTag(tester);

    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.enterText(field, 'unknown term');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(api.searchCalls.single.keyword, 'unknown term');
    expect(api.searchCalls.single.conditions, isEmpty);
    expect(api.searchCalls.single.ageRating, AgeRating.all);
    expect(tester.takeException(), isNull);
  });

  testWidgets('JP keyboard candidate updates an existing search once', (
    tester,
  ) async {
    final api = _CatalogApi();
    await _pumpSearchScreen(
      tester,
      api: api,
      sourceNotifier: _JapaneseSourceNotifier(),
      locale: const Locale('en'),
    );
    await _selectTag(tester, locale: const Locale('en'));

    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.enterText(field, 'initial query');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(api.searchCalls, hasLength(1));

    await tester.tap(field);
    await tester.enterText(field, 'Nettoyage');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(api.searchCalls, hasLength(2));
    expect(api.searchCalls.last.keyword, contains('initial query'));
    expect(api.searchCalls.last.keyword, contains('耳かき'));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SearchScreen)),
    );
    final history = container.read(unifiedSearchHistoryProvider).itemsFor(
      const UnifiedSearchHistoryContext(
        contentType: 'audio',
        entryScope: 'global-works',
        source: 'jpAsmr',
      ),
    );
    expect(history, hasLength(2));
    expect(history.map((entry) => entry.payload['keyword']), [
      'initial query 耳かき',
      'initial query',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('JP keyboard selects a highlighted candidate with empty input', (
    tester,
  ) async {
    final api = _CatalogApi()
      ..japaneseTags.add({'id': -78, 'name': '寝息', 'count': 3});
    await _pumpSearchScreen(
      tester,
      api: api,
      sourceNotifier: _JapaneseSourceNotifier(),
      locale: const Locale('en'),
    );
    await _selectTag(tester, locale: const Locale('en'));
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(find.text('Ear Cleaning (5)'), findsOneWidget);
    expect(find.text('寝息 (3)'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(api.searchCalls.single.keyword, '寝息');
    expect(tester.takeException(), isNull);
  });

  testWidgets('ASMR.ONE keyboard submit adds typed tag without warning', (
    tester,
  ) async {
    final api = _CatalogApi();
    await _pumpSearchScreen(
      tester,
      api: api,
      sourceNotifier: AudioSourceNotifier(),
    );

    await _selectTag(tester);
    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.enterText(field, '耳');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(api.searchCalls, hasLength(1));
    expect(api.searchCalls.single.source, AudioSource.asmrOne);
    expect(api.searchCalls.single.keyword, r'$tag:耳$');
    expect(api.searchCalls.single.conditions, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '耳',
    );
    expect(find.text('请输入搜索内容'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'restored tag search loads suggestions only when the input is used',
    (tester) async {
      final api = _CatalogApi()..holdTagCatalog = true;
      await _pumpSearchScreen(
        tester,
        api: api,
        sourceNotifier: AudioSourceNotifier(),
        screen: const SearchScreen(
          initialSearchParams: {'tagId': 999999, 'tagName': '耳かき'},
        ),
      );

      expect(api.tagSearchIds, [999999]);
      expect(api.tagCatalogRequests, isEmpty);

      final input = find.byType(TextField).first;
      await tester.tap(input);
      await tester.pump();
      expect(api.tagCatalogRequests, hasLength(1));

      await tester.tap(input);
      await tester.pump();
      expect(api.tagCatalogRequests, hasLength(1));

      api.tagCatalogGate.complete([
        {'id': 999999, 'name': '耳かき', 'count': 5},
      ]);
      await tester.pumpAndSettle();
      expect(find.text('耳かき (5)'), findsOneWidget);
      expect(api.tagCatalogRequests, hasLength(1));
    },
  );

  testWidgets(
    'changing source cancels a pending restored tag suggestion request',
    (tester) async {
      final api = _CatalogApi()..holdTagCatalog = true;
      final sourceNotifier = AudioSourceNotifier();
      await _pumpSearchScreen(
        tester,
        api: api,
        sourceNotifier: sourceNotifier,
        screen: const SearchScreen(
          initialSearchParams: {'tagId': 999999, 'tagName': '耳かき'},
        ),
      );

      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      final requestToken = api.tagCatalogRequests.single;
      expect(requestToken, isNotNull);

      await sourceNotifier.select(AudioSource.jpAsmr);
      await tester.pumpAndSettle();
      expect(requestToken!.isCancelled, isTrue);

      api.tagCatalogGate.complete([
        {'id': 999999, 'name': '耳かき', 'count': 5},
      ]);
      await tester.pumpAndSettle();
      expect(find.text('耳かき (5)'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching from JP reloads ASMR tag candidates', (tester) async {
    final api = _CatalogApi()
      ..asmrTags = [
        {'id': 999999, 'name': 'ASMR-only tag', 'count': 5},
      ];
    final sourceNotifier = _JapaneseSourceNotifier();
    await _pumpSearchScreen(tester, api: api, sourceNotifier: sourceNotifier);
    await _selectTag(tester);

    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(api.catalogTypes, [SearchType.tag]);
    expect(find.text('耳かき (5)'), findsOneWidget);

    await sourceNotifier.select(AudioSource.asmrOne);
    await tester.pumpAndSettle();
    await _selectTag(tester);
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();

    expect(api.tagCatalogRequests, hasLength(1));
    expect(find.text('ASMR-only tag (5)'), findsOneWidget);
    expect(find.text('耳かき (5)'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

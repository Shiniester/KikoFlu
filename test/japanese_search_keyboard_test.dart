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
import 'package:kikoeru_flutter/src/screens/search_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/search_filter_panel.dart';

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
  });

  final String keyword;
  final AudioSource source;
  final List<SearchCondition> conditions;
}

class _CatalogApi extends KikoeruApiService {
  final catalogTypes = <SearchType>[];
  final tagCatalogRequests = <CancelToken?>[];
  final tagSearchIds = <int>[];
  final tagCatalogGate = Completer<List<dynamic>>();
  bool holdTagCatalog = false;
  final searchCalls = <_SearchCall>[];

  @override
  Future<List<dynamic>> getAllTags({CancelToken? cancelToken}) {
    tagCatalogRequests.add(cancelToken);
    if (holdTagCatalog) return tagCatalogGate.future;
    return Future.value([
      {'id': 999999, 'name': '耳かき', 'count': 5},
    ]);
  }

  @override
  Future<List<Map<String, dynamic>>> getSearchCatalog(
    SearchType type, {
    CancelToken? cancelToken,
  }) async {
    catalogTypes.add(type);
    return [
      {
        'name': '耳かき',
        'sourcePath': '/tag/%e8%80%b3%e3%81%8b%e3%81%8d/',
        'count': 5,
      },
    ];
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
    CancelToken? cancelToken,
  }) async {
    searchCalls.add(
      _SearchCall(
        keyword: keyword,
        source: source,
        conditions: List.unmodifiable(conditions),
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
        locale: const Locale('zh'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _expandFiltersAndSelectTag(WidgetTester tester) async {
  final l10n = await S.delegate.load(const Locale('zh'));
  final expandButton = find.descendant(
    of: find.byType(SearchFilterPanel),
    matching: find.byType(TextButton),
  );
  await tester.tap(expandButton);
  await tester.pumpAndSettle();
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

  testWidgets('JP-ASMR keyboard submit selects the highlighted catalog item', (
    tester,
  ) async {
    final api = _CatalogApi();
    await _pumpSearchScreen(
      tester,
      api: api,
      sourceNotifier: _JapaneseSourceNotifier(),
    );

    await _expandFiltersAndSelectTag(tester);
    expect(api.catalogTypes, [SearchType.tag]);

    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.enterText(field, '耳');
    await tester.pumpAndSettle();
    expect(find.text('耳かき (5)'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('标签: 耳かき'), findsOneWidget);
    expect(api.searchCalls, hasLength(1));
    expect(api.searchCalls.single.source, AudioSource.jpAsmr);
    expect(api.searchCalls.single.keyword, isEmpty);
    expect(api.searchCalls.single.conditions, hasLength(1));
    expect(api.searchCalls.single.conditions.single.type, SearchType.tag);
    expect(api.searchCalls.single.conditions.single.value, '耳かき');
    expect(
      api.searchCalls.single.conditions.single.sourcePath,
      '/tag/%e8%80%b3%e3%81%8b%e3%81%8d/',
    );
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

    await _expandFiltersAndSelectTag(tester);
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
}

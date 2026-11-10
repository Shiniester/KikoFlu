import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/providers/audio_source_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/screens/search_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _JapaneseSourceNotifier extends AudioSourceNotifier {
  _JapaneseSourceNotifier() {
    state = AudioSource.jpAsmr;
  }
}

class _SearchCall {
  const _SearchCall(this.keyword, this.source, this.conditions);

  final String keyword;
  final AudioSource source;
  final List<SearchCondition> conditions;
}

class _HistorySearchApi extends KikoeruApiService {
  final calls = <_SearchCall>[];

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
    calls.add(_SearchCall(keyword, source, List.unmodifiable(conditions)));
    return {
      'works': <dynamic>[],
      'pagination': {'totalCount': 0, 'hasMore': false},
    };
  }
}

List<Map<String, dynamic>> _legacyHistory() => [
  {
    'id': 'jp-keyword',
    'keyword': 'ear rubbing',
    'displayText': 'Keyword history',
    'timestamp': DateTime.utc(2026, 11, 2).toIso8601String(),
    'searchParams': {
      'source': 'jpAsmr',
      'conditions': [
        {'searchType': 'keyword', 'value': 'ear rubbing', 'isExclude': false},
      ],
    },
  },
  {
    'id': 'jp-tag',
    'keyword': '',
    'displayText': 'Legacy tag filter',
    'timestamp': DateTime.utc(2026, 11, 1).toIso8601String(),
    'searchParams': {'source': 'jpAsmr', 'tagId': 999999, 'tagName': 'old tag'},
  },
];

Future<void> _pumpSearch(WidgetTester tester, _HistorySearchApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        kikoeruApiServiceProvider.overrideWithValue(api),
        audioSourceProvider.overrideWith((ref) => _JapaneseSourceNotifier()),
        downloadSummaryProvider.overrideWith(
          (ref) => Stream.value(const DownloadTaskSummary.empty()),
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: SearchScreen(),
      ),
    ),
  );
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
    'legacy keyword history remains searchable and old tags fail clearly',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'search_history': jsonEncode(_legacyHistory()),
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final api = _HistorySearchApi();
      await _pumpSearch(tester, api);
      final strings = S.of(tester.element(find.byType(SearchScreen)));

      await tester.tap(find.text('Keyword history'));
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(1));
      expect(api.calls.single.keyword, 'ear rubbing');
      expect(api.calls.single.source, AudioSource.jpAsmr);

      await tester.tap(find.byTooltip(strings.clear));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Legacy tag filter'));
      await tester.pumpAndSettle();

      expect(find.textContaining('old tag'), findsOneWidget);
      expect(find.text(strings.loadFailed), findsOneWidget);
      expect(find.text(strings.retry), findsOneWidget);
      expect(find.textContaining('Unsupported'), findsOneWidget);
      expect(api.calls, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}

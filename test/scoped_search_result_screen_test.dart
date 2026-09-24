import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/models/search_scope_session.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/screens/scoped_search_result_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ScopeApi extends KikoeruApiService {
  final markFilters = <String?>[];
  final markPages = <int>[];
  final playlistPages = <String, int>{};
  final getWorkRefreshes = <bool>[];
  CancelToken? pendingMarkToken;
  Completer<Map<String, dynamic>>? pendingMarks;
  bool returnMetadataAfterRefresh = false;
  bool singleMark = false;
  int failMarkCalls = 0;
  int failGetWorkCalls = 0;

  @override
  Future<Map<String, dynamic>> getMyReviews({
    int page = 1,
    int pageSize = 20,
    String? filter,
    String order = 'updated_at',
    String sort = 'desc',
    CancelToken? cancelToken,
  }) {
    markFilters.add(filter);
    markPages.add(page);
    if (failMarkCalls > 0) {
      failMarkCalls--;
      return Future.error(StateError('mark source unavailable'));
    }
    if (pendingMarks != null) {
      pendingMarkToken = cancelToken;
      return pendingMarks!.future;
    }
    return Future.value({
      'works': [
        if (page == 1) {'id': 1, 'title': 'Need page one'},
        if (!singleMark && page == 2) {'id': 2, 'title': 'Need page two'},
      ],
      'pagination': {
        'currentPage': page,
        'pageSize': 1,
        'totalCount': singleMark ? 1 : 2,
      },
    });
  }

  @override
  Future<Map<String, dynamic>> getWork(
    int workId, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    getWorkRefreshes.add(forceRefresh);
    if (failGetWorkCalls > 0) {
      failGetWorkCalls--;
      throw StateError('work metadata unavailable');
    }
    return {
      'id': workId,
      'title': 'Need metadata',
      if (returnMetadataAfterRefresh && forceRefresh)
        'tags': [
          {'id': 1, 'name': 'Relaxing'},
        ],
    };
  }

  @override
  Future<Map<String, dynamic>> getUserPlaylists({
    int page = 1,
    int pageSize = 20,
    String filterBy = 'all',
    CancelToken? cancelToken,
  }) async => {
    'playlists': [
      if (page == 1)
        {
          'id': 'first',
          'name': 'First',
          'user_name': 'user',
          'privacy': 0,
          'works_count': 1,
        },
      if (page == 1)
        {
          'id': 'second',
          'name': 'Second',
          'user_name': 'user',
          'privacy': 0,
          'works_count': 1,
        },
    ],
    'pagination': {'currentPage': page, 'pageSize': 20, 'totalCount': 2},
  };

  @override
  Future<Map<String, dynamic>> getPlaylistWorks({
    required String playlistId,
    int page = 1,
    int pageSize = 12,
    CancelToken? cancelToken,
  }) async {
    playlistPages[playlistId] = page;
    return {
      'works': [
        {
          'id': 10,
          'title': 'Need shared work',
          if (playlistId == 'second')
            'tags': [
              {'id': 2, 'name': 'Later metadata'},
            ],
        },
      ],
      'pagination': {'currentPage': page, 'pageSize': 20, 'totalCount': 1},
    };
  }
}

Future<void> _pumpSearch(
  WidgetTester tester, {
  required _ScopeApi api,
  required SearchQuery query,
  SearchScopeSession? session,
  Widget? home,
}) async {
  SharedPreferences.setMockInitialValues({});
  await StorageService.initCritical(
    preferences: await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        kikoeruApiServiceProvider.overrideWith((ref) => api),
        currentTrackProvider.overrideWith((ref) => Stream.value(null)),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home:
            home ??
            ScopedSearchResultScreen(
              query: query,
              session: session ?? SearchScopeSession(),
            ),
      ),
    ),
  );
}

SearchQuery _query(
  SearchScope scope,
  SearchType type,
  String value, {
  String? progressFilter,
}) => SearchQuery(
  scope: scope,
  progressFilter: progressFilter,
  conditions: [SearchCondition(id: 'condition', type: type, value: value)],
);

void main() {
  testWidgets(
    'online mark search passes its selected state and reads every page',
    (tester) async {
      final api = _ScopeApi();
      await _pumpSearch(
        tester,
        api: api,
        query: _query(
          SearchScope.onlineMarks,
          SearchType.keyword,
          'Need',
          progressFilter: 'listening',
        ),
      );
      await tester.pumpAndSettle();

      expect(api.markFilters, ['listening', 'listening']);
      expect(api.markPages, [1, 2]);
      expect(find.text('Need page one'), findsOneWidget);
      expect(find.text('Need page two'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('playlist works are deduplicated with all owning playlists', (
    tester,
  ) async {
    final api = _ScopeApi();
    await _pumpSearch(
      tester,
      api: api,
      query: _query(SearchScope.playlists, SearchType.keyword, 'Need'),
    );
    await tester.pumpAndSettle();

    expect(api.playlistPages.keys, containsAll(['first', 'second']));
    expect(find.text('Need shared work'), findsOneWidget);
    expect(find.text('In playlists: First, Second'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unresolved metadata is force-refreshed and then matched', (
    tester,
  ) async {
    final api = _ScopeApi()
      ..returnMetadataAfterRefresh = true
      ..singleMark = true;
    await _pumpSearch(
      tester,
      api: api,
      query: _query(SearchScope.onlineMarks, SearchType.tag, 'relax'),
    );
    await tester.pumpAndSettle();

    expect(api.getWorkRefreshes, [false, true]);
    expect(find.text('Need metadata'), findsOneWidget);
    expect(find.textContaining('could not be checked'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a known false condition avoids fetching missing metadata', (
    tester,
  ) async {
    final api = _ScopeApi()..singleMark = true;
    await _pumpSearch(
      tester,
      api: api,
      query: SearchQuery(
        scope: SearchScope.onlineMarks,
        conditions: const [
          SearchCondition(
            id: 'keyword',
            type: SearchType.keyword,
            value: 'absent',
          ),
          SearchCondition(id: 'tag', type: SearchType.tag, value: 'relax'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(api.getWorkRefreshes, isEmpty);
    expect(find.text('No matching works.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a scope search cancels its pending source request', (
    tester,
  ) async {
    final api = _ScopeApi()..pendingMarks = Completer<Map<String, dynamic>>();
    final query = _query(SearchScope.onlineMarks, SearchType.keyword, 'Need');
    await _pumpSearch(
      tester,
      api: api,
      query: query,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => ScopedSearchResultScreen(
                  query: query,
                  session: SearchScopeSession(),
                ),
              ),
            ),
            child: const Text('Open search'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open search'));
    await tester.pump();
    await tester.pump();
    expect(api.pendingMarkToken, isNotNull);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(api.pendingMarkToken!.isCancelled, isTrue);

    api.pendingMarks!.complete({
      'works': [
        {'id': 1, 'title': 'Late response'},
      ],
      'pagination': {'currentPage': 1, 'pageSize': 1, 'totalCount': 1},
    });
    await tester.pump();
    expect(find.text('Late response'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source failures stay incomplete and retry can recover', (
    tester,
  ) async {
    final api = _ScopeApi()..failMarkCalls = 1;
    await _pumpSearch(
      tester,
      api: api,
      query: _query(SearchScope.onlineMarks, SearchType.keyword, 'Need'),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Some items could not be loaded. Results may be incomplete.'),
      findsOneWidget,
    );
    expect(find.text('No matching works.'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Need page one'), findsOneWidget);
    expect(find.text('No matching works.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'metadata request failure can be retried without rereading source',
    (tester) async {
      final api = _ScopeApi()
        ..singleMark = true
        ..returnMetadataAfterRefresh = true
        ..failGetWorkCalls = 1;
      await _pumpSearch(
        tester,
        api: api,
        query: _query(SearchScope.onlineMarks, SearchType.tag, 'relax'),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not check 1 item'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(api.markPages, [1]);
      expect(api.getWorkRefreshes, [false, true]);
      expect(find.text('Need metadata'), findsOneWidget);
      expect(find.text('No matching works.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a complete session reuses source entries for a changed query', (
    tester,
  ) async {
    final api = _ScopeApi();
    final session = SearchScopeSession();
    final firstQuery = _query(
      SearchScope.onlineMarks,
      SearchType.keyword,
      'Need',
    );
    final changedQuery = _query(
      SearchScope.onlineMarks,
      SearchType.keyword,
      'two',
    );
    await _pumpSearch(
      tester,
      api: api,
      query: firstQuery,
      session: session,
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ScopedSearchResultScreen(
                      query: firstQuery,
                      session: session,
                    ),
                  ),
                ),
                child: const Text('Open first'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ScopedSearchResultScreen(
                      query: changedQuery,
                      session: session,
                    ),
                  ),
                ),
                child: const Text('Open changed'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open first'));
    await tester.pumpAndSettle();
    expect(api.markPages, [1, 2]);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open changed'));
    await tester.pumpAndSettle();

    expect(api.markPages, [1, 2]);
    expect(find.text('Need page two'), findsOneWidget);
    expect(find.text('Need page one'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a canceled response cannot replace a newer scope search', (
    tester,
  ) async {
    final api = _ScopeApi()..pendingMarks = Completer<Map<String, dynamic>>();
    final session = SearchScopeSession();
    final oldQuery = _query(SearchScope.onlineMarks, SearchType.keyword, 'old');
    final newQuery = _query(
      SearchScope.onlineMarks,
      SearchType.keyword,
      'Need',
    );
    await _pumpSearch(
      tester,
      api: api,
      query: oldQuery,
      session: session,
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ScopedSearchResultScreen(
                      query: oldQuery,
                      session: session,
                    ),
                  ),
                ),
                child: const Text('Open old'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ScopedSearchResultScreen(
                      query: newQuery,
                      session: session,
                    ),
                  ),
                ),
                child: const Text('Open new'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open old'));
    await tester.pump();
    await tester.pump();
    final oldResponse = api.pendingMarks!;
    final oldToken = api.pendingMarkToken;
    expect(oldToken, isNotNull);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(oldToken!.isCancelled, isTrue);

    api.pendingMarks = null;
    await tester.tap(find.text('Open new'));
    await tester.pumpAndSettle();
    expect(find.text('Need page one'), findsOneWidget);
    oldResponse.complete({
      'works': [
        {'id': 99, 'title': 'Late old result'},
      ],
      'pagination': {'currentPage': 1, 'pageSize': 1, 'totalCount': 1},
    });
    await tester.pumpAndSettle();

    expect(find.text('Late old result'), findsNothing);
    expect(find.text('Need page one'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

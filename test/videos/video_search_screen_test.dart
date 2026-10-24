import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_search_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_collection_view.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/widgets/pagination_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search supports keyboard submit, replay, delete, and clear', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final submitted = <String>[];
    const result = VideoItem(
      id: 'result-1',
      title: 'Video result',
      pageUrl: 'https://missav.ai/video-result',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (query, _, _) async {
            submitted.add(query);
            return const VideoSearchResults.collection([result]);
          },
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'actor',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(submitted, ['actor']);
    expect(find.text('Video result'), findsOneWidget);
    expect(find.byType(PaginationBar), findsOneWidget);

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    expect(find.text('actor'), findsOneWidget);

    await tester.tap(find.text('actor'));
    await tester.pumpAndSettle();
    expect(submitted, ['actor', 'actor']);

    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.delete));
    await tester.pumpAndSettle();
    expect(find.text('actor'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'tag',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.clearSearchHistory));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.confirm));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.history), findsNothing);
  });

  testWidgets(
    'global search locally pages loaded results without source URLs',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final items = [
        for (var index = 0; index < 41; index++)
          VideoItem(
            id: 'global-$index',
            title: 'Global result $index',
            pageUrl: 'https://missav.ai/global-$index',
          ),
      ];
      final browsed = <String>[];
      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Video search',
            initialQuery: 'actor',
            search: (_, _, _) async => VideoSearchResults.catalog(
              VideoCatalogPage(
                title: 'Search results',
                url: 'https://missav.ai/en/search/actor',
                videos: items,
              ),
            ),
            browsePage: (url) async {
              browsed.add(url);
              return VideoCatalogPage(title: 'Results', url: url);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _scrollToPagination(tester);
      expect(
        tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
        1,
      );

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.text(l10n.nextPage));
      await tester.pumpAndSettle();
      await _scrollToPagination(tester);

      expect(
        tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
        2,
      );
      expect(browsed, isEmpty);
      expect(find.text('Global result 40'), findsOneWidget);
    },
  );

  testWidgets('search result stays mounted when a detail route is pushed', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const result = VideoItem(
      id: 'result-2',
      title: 'Persistent result',
      pageUrl: 'https://missav.ai/persistent-result',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (_, _, _) async =>
              const VideoSearchResults.collection([result]),
          loadFilters: (kind, _) async => _filterPage(kind),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
          onOpenVideo: (context, _) {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Video details')),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _chooseFilter(tester, VideoSearchFilterKind.genre, 'Genre filter');
    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'persistent',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Persistent result'));
    await tester.pumpAndSettle();
    expect(find.text('Video details'), findsOneWidget);

    Navigator.of(tester.element(find.text('Video details'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Persistent result'), findsOneWidget);
    expect(
      find.byKey(
        ValueKey(
          'selected-video-filter-${_filterUrl(VideoSearchFilterKind.genre)}',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'account collection results clear on account change while covered',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = _TestAccountClient();
      var searches = 0;
      const privateResult = VideoItem(
        id: 'private-result',
        title: 'Private account result',
        pageUrl: 'https://missav.ai/private-result',
      );

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Favorites search',
            initialQuery: 'actor',
            accountClient: client,
            search: (_, _, _) async {
              searches++;
              return const VideoSearchResults.collection([privateResult]);
            },
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
            onOpenVideo: (context, _) {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Video details')),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private account result'), findsOneWidget);
      client.notifyUnrelatedChange();
      await tester.pump();
      expect(find.text('Private account result'), findsOneWidget);
      await tester.tap(find.text('Private account result'));
      await tester.pumpAndSettle();

      client.changeAccount('Account B');
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('Video details'))).pop();
      await tester.pumpAndSettle();

      expect(find.text('Private account result'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('video-search-input')))
            .controller
            ?.text,
        'actor',
      );
      expect(searches, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    },
  );

  testWidgets('verification retry reruns the failed catalog search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var attempts = 0;
    var verifiedSource = '';
    const result = VideoItem(
      id: 'verified-result',
      title: 'Verified result',
      pageUrl: 'https://missav.ai/verified-result',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (query, _, _) async {
            attempts++;
            if (attempts == 1) {
              throw const MissavVerificationRequiredException(
                sourceUrl: 'https://missav.ai/en/search?q=actor',
              );
            }
            return const VideoSearchResults.collection([result]);
          },
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
          verifyAccess: (_, error) async {
            verifiedSource = error.sourceUrl ?? '';
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'actor',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.videoVerifyAccess));
    await tester.pumpAndSettle();

    expect(verifiedSource, 'https://missav.ai/en/search?q=actor');
    expect(attempts, 2);
    expect(find.text('Verified result'), findsOneWidget);
  });

  testWidgets('global search combines a keyword with selected filters', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final submitted = <({String query, List<String> filterUrls})>[];
    const result = VideoItem(
      id: 'filtered-result',
      title: 'Filtered result',
      pageUrl: 'https://missav.ai/filtered-result',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (query, filters, _) async {
            submitted.add((
              query: query,
              filterUrls: filters.map((filter) => filter.url).toList(),
            ));
            return const VideoSearchResults.collection([result]);
          },
          loadFilters: (kind, _) async => _filterPage(kind),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _chooseFilter(tester, VideoSearchFilterKind.genre, 'Genre filter');
    expect(submitted.last.query, isEmpty);
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
    ]);

    await _chooseFilter(tester, VideoSearchFilterKind.actor, 'Actor filter');
    expect(submitted.last.query, isEmpty);
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
      _filterUrl(VideoSearchFilterKind.actor),
    ]);

    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'live keyword',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(submitted.last.query, 'live keyword');
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
      _filterUrl(VideoSearchFilterKind.actor),
    ]);
    expect(find.text('Filtered result'), findsOneWidget);

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(
      find.byKey(
        ValueKey(
          'selected-video-filter-${_filterUrl(VideoSearchFilterKind.genre)}',
        ),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        ValueKey(
          'selected-video-filter-${_filterUrl(VideoSearchFilterKind.actor)}',
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('filter changes reset paging and ignore stale search results', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final staleSearch = Completer<VideoSearchResults>();
    final submitted = <({String query, List<String> filterUrls})>[];
    var searchCount = 0;
    final freshResults = [
      for (var index = 0; index < 41; index++)
        VideoItem(
          id: 'fresh-$index',
          title: 'Fresh result $index',
          pageUrl: 'https://missav.ai/fresh-$index',
        ),
    ];
    final updatedResults = [
      for (var index = 0; index < 41; index++)
        VideoItem(
          id: 'updated-$index',
          title: 'Updated result $index',
          pageUrl: 'https://missav.ai/updated-$index',
        ),
    ];
    const staleResult = VideoItem(
      id: 'stale',
      title: 'Stale result',
      pageUrl: 'https://missav.ai/stale',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (query, filters, _) {
            submitted.add((
              query: query,
              filterUrls: filters.map((filter) => filter.url).toList(),
            ));
            searchCount++;
            if (searchCount == 1) return staleSearch.future;
            return Future.value(
              VideoSearchResults.collection(
                searchCount == 2 ? freshResults : updatedResults,
              ),
            );
          },
          loadFilters: (kind, _) async => _filterPage(kind),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _chooseFilter(
      tester,
      VideoSearchFilterKind.genre,
      'Genre filter',
      settle: false,
    );
    await _chooseFilter(
      tester,
      VideoSearchFilterKind.actor,
      'Actor filter',
      settle: false,
    );
    await tester.pump();
    expect(find.text('Fresh result 0'), findsOneWidget);

    staleSearch.complete(const VideoSearchResults.collection([staleResult]));
    await tester.pump();
    await tester.pump();
    expect(find.text('Stale result'), findsNothing);
    expect(find.text('Fresh result 0'), findsOneWidget);

    final l10n = await S.delegate.load(const Locale('en'));
    await _scrollToPagination(tester);
    await tester.tap(find.text(l10n.nextPage));
    await tester.pumpAndSettle();
    await _scrollToPagination(tester);
    expect(
      tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
      2,
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(
          ValueKey(
            'selected-video-filter-${_filterUrl(VideoSearchFilterKind.actor)}',
          ),
        ),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollToPagination(tester);
    expect(
      tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
      1,
    );
    expect(submitted.last.query, isEmpty);
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
    ]);
    tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!
        .jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Updated result 0'), findsOneWidget);
  });

  testWidgets('filter picker retries a failed directory load', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var loads = 0;

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (_, _, _) async => const VideoSearchResults.collection([]),
          loadFilters: (kind, _) async {
            loads++;
            if (loads == 1) throw StateError('directory unavailable');
            return _filterPage(kind);
          },
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('video-filter-genre')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text(l10n.videoLoadFailed), findsOneWidget);

    await tester.tap(find.text(l10n.retry));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(loads, 2);
    expect(
      find.byKey(
        const ValueKey('video-filter-option-https://missav.ai/filter/genre'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('filter picker follows previous and next catalog pages', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final requestedUrls = <String?>[];
    const nextUrl = 'https://missav.ai/genres?page=2';
    const previousUrl = 'https://missav.ai/genres?page=1';

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (_, _, _) async => const VideoSearchResults.collection([]),
          loadFilters: (kind, pageUrl) async {
            requestedUrls.add(pageUrl);
            return pageUrl == nextUrl
                ? const VideoCatalogPage(
                    title: 'Genres',
                    url: nextUrl,
                    links: [
                      VideoLink(
                        label: 'Drama',
                        url: 'https://missav.ai/genre/drama',
                        kind: VideoLinkKind.category,
                      ),
                    ],
                    previousUrl: previousUrl,
                  )
                : const VideoCatalogPage(
                    title: 'Genres',
                    url: 'https://missav.ai/genres',
                    links: [
                      VideoLink(
                        label: 'Comedy',
                        url: 'https://missav.ai/genre/comedy',
                        kind: VideoLinkKind.category,
                      ),
                    ],
                    nextUrl: nextUrl,
                  );
          },
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-filter-genre')));
    await tester.pumpAndSettle();
    expect(find.text('Comedy'), findsOneWidget);

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.nextPage));
    await tester.pumpAndSettle();
    expect(find.text('Drama'), findsOneWidget);
    await tester.tap(find.text(l10n.previousPage));
    await tester.pumpAndSettle();
    expect(find.text('Comedy'), findsOneWidget);
    await tester.tap(find.text('Comedy'));
    await tester.pumpAndSettle();

    expect(requestedUrls, [null, nextUrl, previousUrl]);
    expect(
      find.byKey(
        const ValueKey('selected-video-filter-https://missav.ai/genre/comedy'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'filter controls fit a narrow and expanded window at large text',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Video search',
            search: (_, _, _) async => const VideoSearchResults.collection([]),
            loadFilters: (kind, _) async => _filterPage(
              kind,
              label: 'A very long filter label that should truncate cleanly',
            ),
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
          ),
          textScale: 1.8,
        ),
      );
      await tester.pumpAndSettle();
      for (final kind in VideoSearchFilterKind.values) {
        await _chooseFilter(
          tester,
          kind,
          'A very long filter label that should truncate cleanly',
        );
      }
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      tester.view.viewInsets = const FakeViewPadding();
      tester.view.physicalSize = const Size(900, 900);
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey(
            'selected-video-filter-${_filterUrl(VideoSearchFilterKind.genre)}',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('small-grid video titles fit a narrow screen', (tester) async {
    SharedPreferences.setMockInitialValues({'video_layout_type': 'smallGrid'});
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final items = [
      for (var index = 0; index < 18; index++)
        VideoItem(
          id: 'small-grid-$index',
          title:
              'A very long video title that must wrap across two lines in the small grid $index',
          pageUrl: 'https://missav.ai/small-grid-$index',
        ),
    ];

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          initialQuery: 'small grid',
          search: (_, _, _) async => VideoSearchResults.collection(items),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
        textScale: 1.3,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(items.first.title), findsOneWidget);
    final cover = find.descendant(
      of: find.byType(VideoCard).first,
      matching: find.byType(Stack),
    );
    final coverSize = tester.getSize(cover);
    expect(coverSize.width / coverSize.height, closeTo(4 / 3, .02));
  });
}

Future<void> _scrollToPagination(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byType(PaginationBar),
    500,
    scrollable: find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.ensureVisible(find.byType(PaginationBar));
  await tester.pumpAndSettle();
}

Future<void> _chooseFilter(
  WidgetTester tester,
  VideoSearchFilterKind kind,
  String label, {
  bool settle = true,
}) async {
  await tester.tap(find.byKey(ValueKey('video-filter-${kind.name}')));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
  }
  await tester.tap(
    find.descendant(of: find.byType(AlertDialog), matching: find.text(label)),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
  }
}

VideoCatalogPage _filterPage(VideoSearchFilterKind kind, {String? label}) =>
    VideoCatalogPage(
      title: kind.name,
      url: 'https://missav.ai/filter/${kind.name}',
      links: [
        VideoLink(
          label: label ?? _filterLabel(kind),
          url: _filterUrl(kind),
          kind: switch (kind) {
            VideoSearchFilterKind.genre => VideoLinkKind.category,
            VideoSearchFilterKind.actor => VideoLinkKind.actor,
            VideoSearchFilterKind.studio => VideoLinkKind.studio,
            VideoSearchFilterKind.series => VideoLinkKind.collection,
          },
        ),
      ],
    );

String _filterLabel(VideoSearchFilterKind kind) => switch (kind) {
  VideoSearchFilterKind.genre => 'Genre filter',
  VideoSearchFilterKind.actor => 'Actor filter',
  VideoSearchFilterKind.studio => 'Studio filter',
  VideoSearchFilterKind.series => 'Series filter',
};

String _filterUrl(VideoSearchFilterKind kind) =>
    'https://missav.ai/filter/${kind.name}';

Widget _app(Widget home, {double textScale = 1}) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    theme: ThemeData(useMaterial3: true),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home,
  ),
);

class _TestAccountClient extends MissavClient {
  bool loggedIn = true;
  String? name = 'Account A';

  @override
  bool get isLoggedIn => loggedIn;

  @override
  String? get accountName => name;

  void changeAccount(String accountName) {
    name = accountName;
    notifyListeners();
  }

  void notifyUnrelatedChange() => notifyListeners();
}

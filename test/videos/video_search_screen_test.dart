import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/unified_search_history_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/videos/video_browse_preferences.dart';
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
    expect(find.byKey(const ValueKey('search-filter-toggle')), findsNothing);

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

  testWidgets('first input tap suggests history and fills only its keyword', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final submitted = <({String query, List<String> filterUrls})>[];
    const result = VideoItem(
      id: 'history-result',
      title: 'History result',
      pageUrl: 'https://missav.ai/history-result',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          initialQuery: 'saved keyword',
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
    expect(submitted, hasLength(1));

    await _chooseFilter(tester, VideoSearchFilterKind.genre, 'Genre filter');
    expect(submitted, hasLength(2));
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
    ]);

    await _tapSearchType(tester, 'keyword');
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-search-input')));
    await tester.pump();

    final historySuggestion = find.byKey(
      const ValueKey('video-search-keyword-suggestion-saved keyword'),
    );
    expect(historySuggestion, findsOneWidget);
    expect(submitted, hasLength(2));
    await tester.tap(historySuggestion);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('video-search-input')))
          .controller!
          .text,
      'saved keyword',
    );
    expect(
      find.byKey(
        ValueKey(
          'selected-video-filter-${_filterUrl(VideoSearchFilterKind.genre)}',
        ),
      ),
      findsNothing,
    );
    expect(submitted, hasLength(2));
  });

  testWidgets('initial VideoLink filters search by URL immediately', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final submitted = <({String query, List<String> filterUrls})>[];
    const filter = VideoLink(
      label: 'Actor filter',
      url: 'https://missav.ai/actors/actor-1',
      kind: VideoLinkKind.actor,
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          initialFilters: const [filter],
          search: (query, filters, _) async {
            submitted.add((
              query: query,
              filterUrls: filters.map((filter) => filter.url).toList(),
            ));
            return const VideoSearchResults.collection([]);
          },
          loadFilters: (kind, _) async => _filterPage(kind),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(submitted, hasLength(1));
    expect(submitted.single.query, '');
    expect(submitted.single.filterUrls, [filter.url]);
    expect(
      find.byKey(ValueKey('selected-video-filter-${filter.url}')),
      findsOneWidget,
    );
  });

  testWidgets(
    'display layout stays shared during input, loading, results, and history toggles at 320 and 840 px',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final pendingSearch = Completer<VideoSearchResults>();
      const result = VideoItem(
        id: 'layout-result',
        title: 'Layout result',
        pageUrl: 'https://missav.ai/layout-result',
      );
      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Video search',
            search: (_, _, _) => pendingSearch.future,
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(VideoSearchScreen)),
      );
      final layoutProvider = container.read(videoBrowseLayoutProvider.notifier);
      await layoutProvider.setLayout(LayoutType.list);
      await tester.pumpAndSettle();

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(l10n.feedSettings));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('video-search-layout-list')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('video-search-layout-list')));
      await tester.pumpAndSettle();
      expect(container.read(videoBrowseLayoutProvider), LayoutType.list);
      await tester.tap(find.byTooltip(l10n.feedSettings));
      await tester.pumpAndSettle();

      final input = find.byKey(const ValueKey('video-search-input'));
      await tester.enterText(input, 'kept query');
      expect(container.read(videoBrowseLayoutProvider), LayoutType.list);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(container.read(videoBrowseLayoutProvider), LayoutType.list);

      tester.view.physicalSize = const Size(840, 720);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(container.read(videoBrowseLayoutProvider), LayoutType.list);

      pendingSearch.complete(const VideoSearchResults.collection([result]));
      await tester.pumpAndSettle();
      expect(find.text('Layout result'), findsOneWidget);
      expect(
        tester
            .widget<VideoCollectionView<VideoItem>>(
              find.byType(VideoCollectionView<VideoItem>),
            )
            .layoutType,
        LayoutType.list,
      );
      expect(tester.widget<TextField>(input).controller?.text, 'kept query');

      final historyToggle = find.byKey(
        const ValueKey('video-search-history-toggle'),
      );
      await tester.tap(historyToggle);
      await tester.pumpAndSettle();
      expect(find.text('Layout result'), findsNothing);
      await tester.tap(historyToggle);
      await tester.pumpAndSettle();
      expect(find.text('Layout result'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller?.text, 'kept query');
      expect(container.read(videoBrowseLayoutProvider), LayoutType.list);
    },
  );

  testWidgets('keyboard selects a history suggestion without searching', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final submitted = <String>[];

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          initialQuery: 'saved keyword',
          search: (query, _, _) async {
            submitted.add(query);
            return const VideoSearchResults.collection([]);
          },
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(submitted, ['saved keyword']);

    await tester.tap(find.byKey(const ValueKey('video-search-input')));
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey('video-search-keyword-suggestion-saved keyword'),
      ),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(submitted, ['saved keyword']);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('video-search-input')))
          .controller!
          .text,
      'saved keyword',
    );
  });

  testWidgets('keyboard keeps directory suggestions and browse-all visible', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const query = 'saved keyword';
    final submitted = <({String query, List<String> filterUrls})>[];
    const targetUrl = 'https://missav.ai/genre/7';

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          initialQuery: query,
          search: (searchQuery, filters, _) async {
            submitted.add((
              query: searchQuery,
              filterUrls: filters.map((filter) => filter.url).toList(),
            ));
            return const VideoSearchResults.collection([]);
          },
          loadFilters: (kind, _) async => VideoCatalogPage(
            title: 'Genres',
            url: 'https://missav.ai/genres',
            links: [
              for (var index = 0; index < 12; index++)
                VideoLink(
                  label: 'Genre $index',
                  url: 'https://missav.ai/genre/$index',
                  kind: VideoLinkKind.category,
                ),
            ],
          ),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(submitted, hasLength(1));
    expect(submitted.single.query, query);
    expect(submitted.single.filterUrls, isEmpty);

    await _tapSearchType(tester, 'genre');
    final input = find.byKey(const ValueKey('video-search-input'));
    await tester.tap(input);
    await tester.pump();
    final semantics = tester.ensureSemantics();

    for (var index = 0; index < 8; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.pump();

    final highlightedSuggestion = find.byKey(
      const ValueKey(
        'video-search-filter-suggestion-https://missav.ai/genre/7',
      ),
    );
    expect(highlightedSuggestion.hitTestable(), findsOneWidget);
    final selectedSemantics = find.ancestor(
      of: highlightedSuggestion,
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true,
      ),
    );
    expect(selectedSemantics, findsOneWidget);
    expect(
      tester.getSemantics(selectedSemantics.first).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    semantics.dispose();
    final suggestionSurface = find
        .ancestor(of: highlightedSuggestion, matching: find.byType(Material))
        .first;
    expect(
      tester.widget<Material>(suggestionSurface).color,
      Theme.of(
        tester.element(highlightedSuggestion),
      ).colorScheme.secondaryContainer,
    );

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(submitted, hasLength(2));
    expect(submitted.last.query, query);
    expect(submitted.last.filterUrls, [targetUrl]);
    expect(
      find.byKey(const ValueKey('selected-video-filter-$targetUrl')),
      findsOneWidget,
    );

    await tester.tap(input);
    await tester.pump();
    for (var index = 0; index < 12; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.pump();

    final browseAll = find.byKey(const ValueKey('video-search-browse-all'));
    expect(browseAll.hitTestable(), findsOneWidget);
    final browseAllSemantics = find.ancestor(
      of: browseAll,
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true,
      ),
    );
    expect(browseAllSemantics, findsOneWidget);
    expect(
      tester.widget<TextButton>(browseAll).style?.backgroundColor?.resolve({}),
      Theme.of(tester.element(browseAll)).colorScheme.secondaryContainer,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump();
    final lastSuggestion = find.byKey(
      const ValueKey(
        'video-search-filter-suggestion-https://missav.ai/genre/11',
      ),
    );
    expect(lastSuggestion.hitTestable(), findsOneWidget);
    final lastSuggestionSemantics = find.ancestor(
      of: lastSuggestion,
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true,
      ),
    );
    expect(lastSuggestionSemantics, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    expect(browseAll.hitTestable(), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    final firstSuggestion = find.byKey(
      const ValueKey(
        'video-search-filter-suggestion-https://missav.ai/genre/0',
      ),
    );
    expect(firstSuggestion.hitTestable(), findsOneWidget);
    for (var index = 0; index < 11; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.pump();
    expect(browseAll.hitTestable(), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    final localizations = await S.delegate.load(const Locale('en'));
    final filterPicker = find.byKey(const ValueKey('responsive-sheet-surface'));
    expect(
      find.descendant(
        of: filterPicker,
        matching: find.text(localizations.videoFilterGenre),
      ),
      findsOneWidget,
    );
    expect(submitted, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyword suggestions explain empty and unmatched history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (_, _, _) async => const VideoSearchResults.collection([]),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    final input = find.byKey(const ValueKey('video-search-input'));
    expect(
      find.byKey(const ValueKey('video-search-suggestions')),
      findsNothing,
    );
    await tester.tap(input);
    await tester.pump();
    final menu = find.byKey(const ValueKey('video-search-suggestions'));

    expect(
      find.descendant(of: menu, matching: find.text(l10n.noSearchHistory)),
      findsOneWidget,
    );
    await tester.enterText(input, 'first search');
    await tester.pump();
    expect(
      find.descendant(of: menu, matching: find.text(l10n.noSearchHistory)),
      findsOneWidget,
    );

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(input);
    await tester.pump();
    await tester.enterText(input, 'unmatched');
    await tester.pump();
    expect(
      find.descendant(of: menu, matching: find.text(l10n.noSearchHistory)),
      findsNothing,
    );
    expect(
      find.descendant(of: menu, matching: find.text(l10n.noResults)),
      findsOneWidget,
    );
  });

  testWidgets('directory text requires a selection and preserves keyword', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final submitted = <({String query, List<String> filterUrls})>[];

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (query, filters, _) async {
            submitted.add((
              query: query,
              filterUrls: filters.map((filter) => filter.url).toList(),
            ));
            return const VideoSearchResults.collection([]);
          },
          loadFilters: (kind, _) async => _filterPage(kind),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'kept keyword',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(submitted, hasLength(1));

    await _tapSearchType(tester, 'actor');
    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'not selected',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text(l10n.videoSearchSelectFilterBeforeSearch), findsOneWidget);
    expect(submitted, hasLength(1));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('video-search-input')))
          .controller!
          .text,
      'not selected',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('video-search-input')))
          .decoration!
          .prefixText,
      '${l10n.videoFilterActor} · ',
    );

    await _tapSearchType(tester, 'keyword');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('video-search-input')))
          .controller!
          .text,
      'kept keyword',
    );

    await _chooseFilter(tester, VideoSearchFilterKind.genre, 'Genre filter');
    expect(submitted, hasLength(2));
    await _tapSearchType(tester, 'actor');
    await tester.tap(find.byKey(const ValueKey('video-search-submit')));
    await tester.pumpAndSettle();

    expect(submitted, hasLength(3));
    expect(submitted.last.query, 'kept keyword');
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
    ]);
  });

  testWidgets(
    'directory focus loads suggestions and selected filters search immediately',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final submitted = <({String query, List<String> filterUrls})>[];
      final requestedPages = <(VideoSearchFilterKind, String?)>[];

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Video search',
            search: (query, filters, _) async {
              submitted.add((
                query: query,
                filterUrls: filters.map((filter) => filter.url).toList(),
              ));
              return const VideoSearchResults.collection([]);
            },
            loadFilters: (kind, pageUrl) async {
              requestedPages.add((kind, pageUrl));
              return _filterPage(kind, label: 'First page filter');
            },
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-search-input')),
        'manual keyword',
      );
      await tester.tap(find.byKey(const ValueKey('video-search-type-genre')));
      await tester.pumpAndSettle();

      expect(requestedPages, [(VideoSearchFilterKind.genre, null)]);
      final suggestion = find.byKey(
        ValueKey(
          'video-search-filter-suggestion-${_filterUrl(VideoSearchFilterKind.genre)}',
        ),
      );
      expect(suggestion, findsOneWidget);
      await tester.tap(suggestion, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      expect(submitted, hasLength(1));
      expect(submitted.single.query, 'manual keyword');
      expect(submitted.single.filterUrls, [
        _filterUrl(VideoSearchFilterKind.genre),
      ]);
      await tester.tap(
        find.byKey(const ValueKey('video-search-submit')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(submitted, hasLength(2));
      expect(submitted.last.query, 'manual keyword');
      expect(submitted.last.filterUrls, [
        _filterUrl(VideoSearchFilterKind.genre),
      ]);
    },
  );

  testWidgets(
    'opening directory picker shares its pending first-page request',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final firstPage = Completer<VideoCatalogPage>();
      var requestCount = 0;

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Video search',
            search: (_, _, _) async => const VideoSearchResults.collection([]),
            loadFilters: (_, _) {
              requestCount++;
              return firstPage.future;
            },
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-search-type-genre')));
      await tester.pump();
      expect(requestCount, 1);
      expect(
        find.byKey(const ValueKey('video-search-directory-loading')),
        findsOneWidget,
      );

      final browseAll = find.byKey(const ValueKey('video-search-browse-all'));
      await tester.tap(browseAll, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(requestCount, 1);

      firstPage.complete(_filterPage(VideoSearchFilterKind.genre));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey(
            'video-filter-option-${_filterUrl(VideoSearchFilterKind.genre)}',
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'directory autocomplete keeps verification and retry after page failure',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var loadCount = 0;
      final verifiedSources = <String>[];

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Video search',
            search: (_, _, _) async => const VideoSearchResults.collection([]),
            loadFilters: (kind, _) async {
              loadCount++;
              if (loadCount == 1) {
                throw const MissavVerificationRequiredException(
                  sourceUrl: 'https://missav.ai/genres',
                );
              }
              return _filterPage(kind, label: 'Verified genre');
            },
            verifyAccess: (_, error) async {
              verifiedSources.add(error.sourceUrl ?? '');
              return true;
            },
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-search-type-genre')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('video-search-directory-error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('video-search-directory-retry')),
        findsOneWidget,
      );
      final verifyButton = find.byKey(
        const ValueKey('video-search-directory-verify'),
      );
      expect(verifyButton, findsOneWidget);
      await tester.tap(verifyButton);
      await tester.pumpAndSettle();

      expect(verifiedSources, ['https://missav.ai/genres']);
      expect(loadCount, 2);
      expect(find.text('Verified genre'), findsOneWidget);
    },
  );

  testWidgets(
    'directory suggestions ignore a first-page response from a previous account',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final accountClient = _TestAccountClient();
      final pendingPages = <String, Completer<VideoCatalogPage>>{};
      final requestedAccounts = <String>[];

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Video search',
            accountClient: accountClient,
            search: (_, _, _) async => const VideoSearchResults.collection([]),
            loadFilters: (kind, _) {
              final accountName = accountClient.accountName!;
              requestedAccounts.add(accountName);
              return (pendingPages[accountName] ??=
                      Completer<VideoCatalogPage>())
                  .future;
            },
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-search-type-actor')));
      await tester.pump();
      expect(requestedAccounts, ['Account A']);

      accountClient.changeAccount('Account B');
      await tester.pump();
      await tester.pump();
      expect(requestedAccounts, ['Account A', 'Account B']);

      pendingPages['Account A']!.complete(
        _filterPage(VideoSearchFilterKind.actor, label: 'Stale actor'),
      );
      await tester.pump();
      expect(
        find.byKey(
          ValueKey(
            'video-search-filter-suggestion-${_filterUrl(VideoSearchFilterKind.actor)}',
          ),
        ),
        findsNothing,
      );

      pendingPages['Account B']!.complete(
        _filterPage(VideoSearchFilterKind.actor, label: 'Current actor'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Current actor'), findsOneWidget);
      expect(find.text('Stale actor'), findsNothing);
      accountClient.dispose();
    },
  );

  for (final (size, keyboardHeight) in [
    (const Size(320, 480), 240.0),
    (const Size(800, 360), 200.0),
  ]) {
    testWidgets(
      'directory overlay remains usable at ${size.width}x${size.height} with the keyboard open',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);

        await tester.pumpWidget(
          _app(
            VideoSearchScreen(
              title: 'Video search',
              search: (_, _, _) async =>
                  const VideoSearchResults.collection([]),
              loadFilters: (kind, _) async =>
                  _filterPage(kind, label: 'Long directory suggestion'),
              browsePage: (url) async =>
                  VideoCatalogPage(title: 'Results', url: url),
            ),
            textScale: 1.8,
          ),
        );
        await tester.pumpAndSettle();
        await _tapSearchType(tester, 'series');
        expect(tester.takeException(), isNull);

        final browseAll = find.byKey(const ValueKey('video-search-browse-all'));
        await tester.scrollUntilVisible(
          browseAll,
          80,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('video-search-suggestions')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(browseAll, findsOneWidget);
        await tester.ensureVisible(browseAll);
        await tester.pump();
        await tester.tap(browseAll);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('responsive-sheet-surface')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('history can be opened without clearing the current search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (_, _, _) async => const VideoSearchResults.collection([
            VideoItem(
              id: 'one',
              title: 'Video result',
              pageUrl: 'https://example.test/one',
            ),
          ]),
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

    await tester.tap(find.byKey(const ValueKey('video-search-history-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Video result'), findsNothing);
    expect(find.text('actor'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('video-search-history-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Video result'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('video-search-input')))
          .controller!
          .text,
      'actor',
    );
  });

  testWidgets('source history shows and clears migrated legacy entries', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'video_search_history': ['legacy query'],
    });

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (_, _, _) async => const VideoSearchResults.collection([]),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text('legacy query'), findsOneWidget);
    expect(find.text(l10n.searchLegacyHistory), findsOneWidget);
    await tester.tap(find.byTooltip(l10n.clearSearchHistory));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.confirm));
    await tester.pumpAndSettle();

    expect(find.text('legacy query'), findsNothing);
  });

  testWidgets('non-directory history does not include legacy video entries', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'video_search_history': ['legacy query'],
    });

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Favorites search',
          historyContext: const UnifiedSearchHistoryContext(
            contentType: 'video',
            entryScope: 'favorites',
            source: 'missav',
          ),
          search: (_, _, _) async => const VideoSearchResults.collection([]),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('legacy query'), findsNothing);
  });

  testWidgets('new download searches do not write the legacy video history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Downloads search',
          historyContext: const UnifiedSearchHistoryContext(
            contentType: 'video',
            entryScope: 'downloads',
            source: 'missav',
          ),
          search: (_, _, _) async => const VideoSearchResults.collection([]),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'download query',
    );
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.search));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('video_search_history'), isNull);
  });

  testWidgets('account history follows the active account name', (
    tester,
  ) async {
    final history = [
      UnifiedSearchHistoryEntry(
        id: 'account-a',
        context: const UnifiedSearchHistoryContext(
          contentType: 'video',
          entryScope: 'favorites',
          source: 'missav:Account A',
        ),
        payload: {'keyword': 'Account A query', 'filters': <String>[]},
        timestamp: DateTime.utc(2026, 10, 31, 10),
      ),
      UnifiedSearchHistoryEntry(
        id: 'account-b',
        context: const UnifiedSearchHistoryContext(
          contentType: 'video',
          entryScope: 'favorites',
          source: 'missav:Account B',
        ),
        payload: {'keyword': 'Account B query', 'filters': <String>[]},
        timestamp: DateTime.utc(2026, 10, 31, 11),
      ),
    ];
    SharedPreferences.setMockInitialValues({
      'unified_search_history': jsonEncode({
        'version': 1,
        'legacyMigrationComplete': true,
        'records': history.map((entry) => entry.toJson()).toList(),
      }),
    });
    final client = _TestAccountClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Favorites search',
          accountClient: client,
          historyContext: const UnifiedSearchHistoryContext(
            contentType: 'video',
            entryScope: 'favorites',
            source: 'missav',
          ),
          search: (_, _, _) async => const VideoSearchResults.collection([]),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Account A query'), findsOneWidget);
    expect(find.text('Account B query'), findsNothing);

    client.changeAccount('Account B');
    await tester.pumpAndSettle();
    expect(find.text('Account A query'), findsNothing);
    expect(find.text('Account B query'), findsOneWidget);
  });

  testWidgets('successful empty search replaces the previous results', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var attempts = 0;
    const oldResult = VideoItem(
      id: 'old-result',
      title: 'Old result',
      pageUrl: 'https://missav.ai/old-result',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (_, _, _) async {
            attempts++;
            return attempts == 1
                ? const VideoSearchResults.collection([oldResult])
                : const VideoSearchResults.collection([]);
          },
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'first query',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('Old result'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'empty query',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text('Old result'), findsNothing);
    expect(find.text(l10n.noResults), findsOneWidget);
  });

  testWidgets(
    'search updates keep prior results open through loading, failure, and retry',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final delayedUpdate = Completer<VideoSearchResults>();
      var attempts = 0;
      var verifiedSource = '';
      var openedTitle = '';
      const oldResult = VideoItem(
        id: 'old-result',
        title: 'Old result',
        pageUrl: 'https://missav.ai/old-result',
      );
      final oldResults = [
        for (var index = 0; index < 40; index++)
          VideoItem(
            id: 'old-page-$index',
            title: 'Old page item $index',
            pageUrl: 'https://missav.ai/old-page-$index',
          ),
        oldResult,
      ];
      const updatedResult = VideoItem(
        id: 'updated-result',
        title: 'Updated result',
        pageUrl: 'https://missav.ai/updated-result',
      );

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Video search',
            search: (_, _, _) {
              attempts++;
              return switch (attempts) {
                1 => Future.value(VideoSearchResults.collection(oldResults)),
                2 => delayedUpdate.future,
                3 => throw const MissavVerificationRequiredException(
                  sourceUrl: 'https://missav.ai/en/search?q=updated',
                ),
                _ => Future.value(
                  const VideoSearchResults.collection([updatedResult]),
                ),
              };
            },
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
            onOpenVideo: (_, video) => openedTitle = video.title,
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
        'first query',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('Old page item 0'), findsOneWidget);
      final l10n = await S.delegate.load(const Locale('en'));
      await _scrollToPagination(tester);
      await tester.tap(find.text(l10n.nextPage));
      await tester.pumpAndSettle();
      expect(
        tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
        2,
      );

      final oldPageStorageKey = tester
          .widget<VideoCollectionView<VideoItem>>(
            find.byType(VideoCollectionView<VideoItem>),
          )
          .pageStorageKey;
      await tester.enterText(
        find.byKey(const ValueKey('video-search-input')),
        'updated query',
      );
      await tester.pump();
      expect(
        tester
            .widget<VideoCollectionView<VideoItem>>(
              find.byType(VideoCollectionView<VideoItem>),
            )
            .pageStorageKey,
        oldPageStorageKey,
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.text(l10n.searchUpdating), findsOneWidget);
      expect(find.text('Old result'), findsOneWidget);
      await _scrollToPagination(tester, settle: false);
      expect(
        tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
        2,
      );
      await tester.tap(find.text('Old result'));
      expect(openedTitle, 'Old result');

      delayedUpdate.completeError(StateError('temporary failure'));
      await tester.pumpAndSettle();
      expect(find.text('Old result'), findsOneWidget);
      expect(find.text(l10n.searchUpdateFailedShowingPrevious), findsOneWidget);
      await _scrollToPagination(tester);
      expect(
        tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
        2,
      );
      await tester.tap(find.text(l10n.retry));
      await tester.pumpAndSettle();
      expect(attempts, 3);
      expect(find.text('Old result'), findsOneWidget);
      expect(find.text(l10n.videoVerificationRequired), findsOneWidget);
      await _scrollToPagination(tester);
      expect(
        tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
        2,
      );
      await tester.tap(find.text(l10n.videoVerifyAccess));
      await tester.pumpAndSettle();

      expect(verifiedSource, 'https://missav.ai/en/search?q=updated');
      expect(attempts, 4);
      expect(find.text('Old result'), findsNothing);
      expect(find.text('Updated result'), findsOneWidget);
    },
  );

  testWidgets('replaying a search restores filters and preserves its history', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final submitted = <({String query, List<String> filterUrls})>[];

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (query, filters, _) async {
            submitted.add((
              query: query,
              filterUrls: filters.map((filter) => filter.url).toList(),
            ));
            return const VideoSearchResults.collection([]);
          },
          loadFilters: (kind, _) async => _filterPage(kind),
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _chooseFilter(tester, VideoSearchFilterKind.genre, 'Genre filter');
    await _tapSearchType(tester, 'keyword');
    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'history keyword',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    await tester.tap(find.text('history keyword · Genre filter'));
    await tester.pumpAndSettle();

    expect(submitted.last.query, 'history keyword');
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
    ]);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('video-search-input')))
          .controller
          ?.text,
      'history keyword',
    );
    expect(
      find.byKey(
        ValueKey(
          'selected-video-filter-${_filterUrl(VideoSearchFilterKind.genre)}',
        ),
      ),
      findsOneWidget,
    );

    await _chooseFilter(tester, VideoSearchFilterKind.actor, 'Actor filter');
    expect(submitted, hasLength(4));
    expect(submitted.last.query, 'history keyword');
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
      _filterUrl(VideoSearchFilterKind.actor),
    ]);

    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    expect(find.text('history keyword · Genre filter'), findsOneWidget);
    expect(
      find.text('history keyword · Genre filter · Actor filter'),
      findsOneWidget,
    );
  });

  testWidgets('failed catalog paging labels the retained page and retries', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var pageAttempts = 0;
    const oldResult = VideoItem(
      id: 'catalog-page-one',
      title: 'Catalog page one',
      pageUrl: 'https://missav.ai/catalog-page-one',
    );
    const nextResult = VideoItem(
      id: 'catalog-page-two',
      title: 'Catalog page two',
      pageUrl: 'https://missav.ai/catalog-page-two',
    );

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          initialQuery: 'actor',
          search: (_, _, _) async => VideoSearchResults.catalog(
            const VideoCatalogPage(
              title: 'Catalog',
              url: 'https://missav.ai/catalog?page=1',
              videos: [oldResult],
              nextUrl: 'https://missav.ai/catalog?page=2',
            ),
          ),
          browsePage: (url) async {
            pageAttempts++;
            if (pageAttempts == 1) throw StateError('page unavailable');
            return VideoCatalogPage(
              title: 'Catalog',
              url: url,
              videos: [nextResult],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.nextPage));
    await tester.pumpAndSettle();

    expect(find.text('Catalog page one'), findsOneWidget);
    expect(find.text(l10n.searchUpdateFailedShowingPrevious), findsOneWidget);
    await tester.tap(find.text(l10n.retry));
    await tester.pumpAndSettle();

    expect(pageAttempts, 2);
    expect(find.text('Catalog page one'), findsNothing);
    expect(find.text('Catalog page two'), findsOneWidget);
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
    await _tapSearchType(tester, 'keyword');
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
    'account search keeps a 401 prompt and retry after clearing old results',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = _TestAccountClient();
      var attempts = 0;
      const oldResult = VideoItem(
        id: 'account-old-result',
        title: 'Old account result',
        pageUrl: 'https://missav.ai/account-old-result',
      );
      const recoveredResult = VideoItem(
        id: 'account-recovered-result',
        title: 'Recovered account result',
        pageUrl: 'https://missav.ai/account-recovered-result',
      );

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Favorites search',
            historyContext: const UnifiedSearchHistoryContext(
              contentType: 'video',
              entryScope: 'favorites',
              source: 'missav',
            ),
            initialQuery: 'actor',
            accountClient: client,
            search: (_, _, _) async {
              attempts++;
              if (attempts == 1) {
                return const VideoSearchResults.collection([oldResult]);
              }
              if (attempts == 2) {
                client.expireSession();
                throw const MissavAuthenticationException(
                  sourceUrl: 'https://missav.ai/favorites',
                );
              }
              return const VideoSearchResults.collection([recoveredResult]);
            },
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(oldResult.title), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('video-search-input')),
        'updated actor',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      final l10n = await S.delegate.load(const Locale('en'));
      expect(find.text(oldResult.title), findsNothing);
      expect(find.text(l10n.videoLoginRequired), findsOneWidget);
      expect(find.text(l10n.videoLoadFailed), findsNothing);
      expect(find.text(l10n.retry), findsOneWidget);

      await tester.tap(find.text(l10n.retry));
      await tester.pumpAndSettle();

      expect(attempts, 3);
      expect(find.text(l10n.videoLoginRequired), findsNothing);
      expect(find.text(recoveredResult.title), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    },
  );

  testWidgets(
    'account changes ignore late search results and authentication failures',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final client = _TestAccountClient();
      final oldAccountSuccess = Completer<VideoSearchResults>();
      final oldAccountFailure = Completer<VideoSearchResults>();
      final logoutFailure = Completer<VideoSearchResults>();
      var attempts = 0;
      const accountBResult = VideoItem(
        id: 'account-b-result',
        title: 'Account B result',
        pageUrl: 'https://missav.ai/account-b-result',
      );
      const accountCResult = VideoItem(
        id: 'account-c-result',
        title: 'Account C result',
        pageUrl: 'https://missav.ai/account-c-result',
      );

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Favorites search',
            historyContext: const UnifiedSearchHistoryContext(
              contentType: 'video',
              entryScope: 'favorites',
              source: 'missav',
            ),
            initialQuery: 'actor',
            accountClient: client,
            search: (_, _, _) {
              attempts++;
              return switch (attempts) {
                1 => oldAccountSuccess.future,
                2 => Future.value(
                  const VideoSearchResults.collection([accountBResult]),
                ),
                3 => oldAccountFailure.future,
                4 => Future.value(
                  const VideoSearchResults.collection([accountCResult]),
                ),
                _ => logoutFailure.future,
              };
            },
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
          ),
        ),
      );
      await tester.pump();

      final l10n = await S.delegate.load(const Locale('en'));
      client.changeAccount('Account B');
      await tester.pump();
      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();
      expect(find.text(accountBResult.title), findsOneWidget);

      oldAccountSuccess.complete(
        const VideoSearchResults.collection([
          VideoItem(
            id: 'account-a-result',
            title: 'Account A result',
            pageUrl: 'https://missav.ai/account-a-result',
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text(accountBResult.title), findsOneWidget);
      expect(find.text('Account A result'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('video-search-input')),
        'account C query',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      client.changeAccount('Account C');
      await tester.pump();
      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();
      expect(find.text(accountCResult.title), findsOneWidget);

      oldAccountFailure.completeError(
        const MissavAuthenticationException(
          sourceUrl: 'https://missav.ai/favorites',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(accountCResult.title), findsOneWidget);
      expect(find.text(l10n.videoLoginRequired), findsNothing);
      expect(find.text(l10n.retry), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('video-search-input')),
        'logout query',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      client.expireSession();
      await tester.pump();
      expect(find.text(l10n.videoLoginRequired), findsOneWidget);
      expect(find.text(l10n.retry), findsOneWidget);
      logoutFailure.completeError(
        const MissavAuthenticationException(
          sourceUrl: 'https://missav.ai/favorites',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.videoLoginRequired), findsOneWidget);
      expect(find.text(l10n.retry), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    },
  );

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
            historyContext: const UnifiedSearchHistoryContext(
              contentType: 'video',
              entryScope: 'favorites',
              source: 'missav',
            ),
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
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
        textScale: 1.3,
      ),
    );
    await tester.pumpAndSettle();

    await _chooseFilter(tester, VideoSearchFilterKind.genre, 'Genre filter');
    expect(submitted, hasLength(1));
    expect(submitted.last.query, '');
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
    ]);
    expect(
      find.byKey(const ValueKey('video-search-type-genre')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey(
          'selected-video-filter-${_filterUrl(VideoSearchFilterKind.genre)}',
        ),
      ),
      findsOneWidget,
    );

    await _chooseFilter(tester, VideoSearchFilterKind.actor, 'Actor filter');
    expect(submitted, hasLength(2));
    expect(submitted.last.query, '');
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
      _filterUrl(VideoSearchFilterKind.actor),
    ]);

    await _tapSearchType(tester, 'keyword');
    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'live keyword',
    );
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.search));
    await tester.pumpAndSettle();

    expect(submitted, hasLength(3));
    expect(submitted.last.query, 'live keyword');
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
      _filterUrl(VideoSearchFilterKind.actor),
    ]);
    expect(find.text('Filtered result'), findsOneWidget);

    await _chooseFilter(tester, VideoSearchFilterKind.studio, 'Studio filter');
    expect(
      find.byKey(const ValueKey('video-search-type-genre')),
      findsOneWidget,
    );
    expect(submitted, hasLength(4));
    expect(submitted.last.query, 'live keyword');
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
      _filterUrl(VideoSearchFilterKind.actor),
      _filterUrl(VideoSearchFilterKind.studio),
    ]);

    final selectedFiltersRow = find.byKey(
      const ValueKey('video-search-selected-filters'),
    );
    expect(selectedFiltersRow, findsOneWidget);
    final studioFilter = find.byKey(
      ValueKey(
        'selected-video-filter-${_filterUrl(VideoSearchFilterKind.studio)}',
      ),
    );
    final removeStudio = find.descendant(
      of: studioFilter,
      matching: find.byIcon(Icons.close),
    );
    for (
      var attempt = 0;
      attempt < 3 && removeStudio.hitTestable().evaluate().isEmpty;
      attempt++
    ) {
      final rowBounds = tester.getRect(selectedFiltersRow);
      await tester.dragFrom(
        Offset(rowBounds.right - 8, rowBounds.center.dy),
        Offset(-rowBounds.width * .75, 0),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryButton,
      );
      await tester.pumpAndSettle();
    }
    expect(studioFilter.hitTestable(), findsOneWidget);
    expect(removeStudio.hitTestable(), findsOneWidget);
    await tester.tap(removeStudio);
    await tester.pumpAndSettle();
    expect(submitted, hasLength(5));
    expect(submitted.last.query, 'live keyword');
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
      _filterUrl(VideoSearchFilterKind.actor),
    ]);

    await tester.tap(find.byTooltip(l10n.clear));
    await tester.pumpAndSettle();
    expect(find.text(l10n.searchHistory), findsOneWidget);
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

    await tester.enterText(
      find.byKey(const ValueKey('video-search-input')),
      'stale query',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await _chooseFilter(tester, VideoSearchFilterKind.genre, 'Genre filter');
    expect(submitted.last.query, 'stale query');
    expect(submitted.last.filterUrls, [
      _filterUrl(VideoSearchFilterKind.genre),
    ]);
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
            'selected-video-filter-${_filterUrl(VideoSearchFilterKind.genre)}',
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
    expect(submitted.last.query, 'stale query');
    expect(submitted.last.filterUrls, isEmpty);
    tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!
        .jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Updated result 0'), findsOneWidget);
  });

  testWidgets(
    'video search retry stays reachable with expanded filters and keyboard in landscape',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var attempts = 0;
      const result = VideoItem(
        id: 'recovered',
        title: 'Recovered result',
        pageUrl: 'https://missav.ai/recovered',
      );

      await tester.pumpWidget(
        _app(
          VideoSearchScreen(
            title: 'Video search',
            initialQuery: 'actor',
            search: (_, _, _) async {
              attempts++;
              if (attempts == 2) throw StateError('temporary failure');
              return const VideoSearchResults.collection([result]);
            },
            loadFilters: (kind, _) async => _filterPage(kind),
            browsePage: (url) async =>
                VideoCatalogPage(title: 'Results', url: url),
          ),
          textScale: 1.3,
        ),
      );
      await tester.pumpAndSettle();
      expect(attempts, 1);

      await _chooseFilter(tester, VideoSearchFilterKind.genre, 'Genre filter');
      expect(attempts, 2);
      expect(
        find.byKey(const ValueKey('video-search-type-genre')),
        findsOneWidget,
      );

      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final l10n = await S.delegate.load(const Locale('en'));
      expect(find.text(l10n.searchUpdateFailedShowingPrevious), findsOneWidget);
      final retry = find.text(l10n.retry);
      await tester.scrollUntilVisible(
        retry,
        40,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('video-search-top-controls')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(attempts, 3);
      expect(find.text('Recovered result'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
            if (loads < 3) throw StateError('directory unavailable');
            return _filterPage(kind);
          },
          browsePage: (url) async =>
              VideoCatalogPage(title: 'Results', url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openFilterPicker(tester, VideoSearchFilterKind.genre);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text(l10n.videoLoadFailed), findsOneWidget);

    await tester.tap(find.text(l10n.retry));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(loads, 3);
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
    final requestedPages = <(VideoSearchFilterKind, String?)>[];
    final searchedFilterUrls = <List<String>>[];
    const nextUrl = 'https://missav.ai/genres?page=2';
    const previousUrl = 'https://missav.ai/genres?page=1';

    await tester.pumpWidget(
      _app(
        VideoSearchScreen(
          title: 'Video search',
          search: (_, filters, _) async {
            searchedFilterUrls.add(
              filters.map((filter) => filter.url).toList(),
            );
            return const VideoSearchResults.collection([]);
          },
          loadFilters: (kind, pageUrl) async {
            requestedPages.add((kind, pageUrl));
            if (kind == VideoSearchFilterKind.actor) {
              return const VideoCatalogPage(
                title: 'Actors',
                url: 'https://missav.ai/actors',
                links: [
                  VideoLink(
                    label: 'Actor',
                    url: 'https://missav.ai/actor/example',
                    kind: VideoLinkKind.actor,
                  ),
                ],
              );
            }
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
    await _openFilterPicker(tester, VideoSearchFilterKind.genre);
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

    expect(requestedPages, [
      (VideoSearchFilterKind.genre, null),
      (VideoSearchFilterKind.genre, nextUrl),
      (VideoSearchFilterKind.genre, previousUrl),
    ]);
    expect(
      find.byKey(
        const ValueKey('selected-video-filter-https://missav.ai/genre/comedy'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('video-search-input')));
    await tester.pump();
    expect(
      find.byKey(
        const ValueKey(
          'video-search-filter-suggestion-https://missav.ai/genre/drama',
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        const ValueKey(
          'video-search-filter-suggestion-https://missav.ai/genre/drama',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey('selected-video-filter-https://missav.ai/genre/drama'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('video-search-submit')));
    await tester.pumpAndSettle();
    expect(searchedFilterUrls, [
      ['https://missav.ai/genre/comedy'],
      ['https://missav.ai/genre/comedy', 'https://missav.ai/genre/drama'],
      ['https://missav.ai/genre/comedy', 'https://missav.ai/genre/drama'],
    ]);

    await _tapSearchType(tester, 'actor');
    expect(
      find.byKey(
        const ValueKey(
          'video-search-filter-suggestion-https://missav.ai/genre/drama',
        ),
      ),
      findsNothing,
    );
    expect(requestedPages, [
      (VideoSearchFilterKind.genre, null),
      (VideoSearchFilterKind.genre, nextUrl),
      (VideoSearchFilterKind.genre, previousUrl),
      (VideoSearchFilterKind.actor, null),
    ]);
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
      tester.view.physicalSize = const Size(840, 900);
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

Future<void> _scrollToPagination(
  WidgetTester tester, {
  bool settle = true,
}) async {
  await tester.scrollUntilVisible(
    find.byType(PaginationBar),
    500,
    scrollable: find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.ensureVisible(find.byType(PaginationBar));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _chooseFilter(
  WidgetTester tester,
  VideoSearchFilterKind kind,
  String label,
) async {
  await _openFilterPicker(tester, kind);
  final filterOption = find.descendant(
    of: find.byKey(const ValueKey('responsive-sheet-surface')),
    matching: find.byKey(ValueKey('video-filter-option-${_filterUrl(kind)}')),
  );
  expect(
    find.descendant(of: filterOption, matching: find.text(label)),
    findsOneWidget,
  );
  await tester.tap(filterOption);
  await tester.pumpAndSettle();
}

Future<void> _openFilterPicker(
  WidgetTester tester,
  VideoSearchFilterKind kind,
) async {
  await _tapSearchType(tester, kind.name);
  final browseAll = find.byKey(const ValueKey('video-search-browse-all'));
  await tester.scrollUntilVisible(
    browseAll,
    80,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('video-search-suggestions')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.ensureVisible(browseAll);
  await tester.pump();
  await tester.tap(browseAll);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _tapSearchType(WidgetTester tester, String type) async {
  final filterType = find.byKey(ValueKey('video-search-type-$type'));
  await tester.ensureVisible(filterType);
  await tester.pump();
  await tester.tap(filterType);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
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
    loggedIn = true;
    name = accountName;
    notifyListeners();
  }

  void expireSession() {
    loggedIn = false;
    name = null;
    notifyListeners();
  }

  void notifyUnrelatedChange() => notifyListeners();
}

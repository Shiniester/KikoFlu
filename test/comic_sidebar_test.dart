import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/comics/comic_downloads.dart';
import 'package:kikoeru_flutter/src/comics/comic_http.dart';
import 'package:kikoeru_flutter/src/comics/comic_library.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/comic_providers.dart';
import 'package:kikoeru_flutter/src/comics/comic_source.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_search_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_settings_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_widgets.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/library_page_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _testPng = Uint8List.fromList(
  img.encodePng(img.Image(width: 1, height: 1)),
);

class _TestComicSource extends ComicSource {
  _TestComicSource({
    this.key = 'fixture',
    this.supportsAccount = true,
    this.supportsRemoteFavorites = true,
  }) : super(ComicHttp(key));

  @override
  final String key;
  final bool supportsAccount;
  final bool supportsRemoteFavorites;

  @override
  String get name => key;

  @override
  String get website => 'https://fixture.invalid';

  @override
  bool get hasAccount => supportsAccount;

  @override
  bool get hasRemoteFavorites => supportsRemoteFavorites;

  @override
  Future<ComicResult> search(
    String query, {
    String? cursor,
    String? sort,
  }) async => const ComicResult([]);

  @override
  Future<Comic> details(String id) async => throw UnimplementedError();

  @override
  Future<ComicResult> favorites({String? cursor}) async => const ComicResult([
    Comic(source: 'fixture', id: 'remote-favorite', title: 'Remote favorite'),
  ]);

  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async =>
      const [];
}

class _TestComicLibrary extends ComicLibrary {
  _TestComicLibrary({this.localFavorites = const []});

  final List<Comic> localFavorites;

  @override
  Future<List<Map<String, dynamic>>> loadTasks() async => const [];

  @override
  Future<List<Comic>> favorites() async => localFavorites;

  @override
  Future<List<ComicProgress>> history() async => const [];

  @override
  Future<ComicProgress?> progress(Comic comic) async => null;
}

Future<void> _pumpComicScreen(
  WidgetTester tester, {
  required _TestComicSource source,
  List<_TestComicSource> otherSources = const [],
  String? selectedSource,
  Set<String> disabledSources = const {},
  List<Comic> localFavorites = const [],
}) async {
  if (selectedSource != null) {
    await StorageService.setString('comic_selected_source', selectedSource);
  }
  for (final sourceKey in disabledSources) {
    await StorageService.setBool('comic_${sourceKey}_enabled', false);
  }
  final library = _TestComicLibrary(localFavorites: localFavorites);
  final sources = [source, ...otherSources];
  final downloads = ComicDownloads(
    library,
    (key) => sources.firstWhere((source) => source.key == key),
  );
  final container = ProviderContainer(
    overrides: [
      comicSourcesProvider.overrideWithValue(sources),
      comicImageLoaderProvider.overrideWithValue((_, _) async => _testPng),
      comicLibraryProvider.overrideWith((ref) => library),
      comicDownloadsProvider.overrideWith((ref) => downloads),
    ],
  );
  addTearDown(container.dispose);
  for (final source in sources) {
    addTearDown(source.http.dispose);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const ComicScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('library-menu-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _pumpNavigation(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 20 && finder.evaluate().isEmpty; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, findsOneWidget);
}

Future<Finder> _drawerTile(WidgetTester tester, String label) async {
  final drawer = find.byKey(const ValueKey('library-drawer'));
  final text = find.descendant(of: drawer, matching: find.text(label));
  await tester.scrollUntilVisible(
    text,
    200,
    scrollable: find
        .descendant(of: drawer, matching: find.byType(Scrollable))
        .first,
  );
  final tile = find.ancestor(of: text, matching: find.byType(ListTile));
  return tile;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'comic_selected_source': 'fixture',
      'comic_grid': false,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('comic sidebar separates account and local favorites', (
    tester,
  ) async {
    final source = _TestComicSource();
    await _pumpComicScreen(tester, source: source);
    final s = S.of(tester.element(find.byType(ComicScreen)));
    final scaffold = tester.widget<LibraryPageScaffold>(
      find.byType(LibraryPageScaffold),
    );
    expect(
      scaffold.drawerChildren.whereType<LibraryDrawerSection>().map(
        (section) => section.title,
      ),
      [
        s.librarySources,
        s.libraryAccount,
        s.libraryContent,
        s.libraryLocal,
        s.libraryBrowseOptions,
      ],
    );

    await _openDrawer(tester);
    final account = await _drawerTile(tester, s.login);
    await tester.tap(account);
    await _pumpNavigation(tester);
    expect(
      tester
          .widget<ComicSourceSettingsScreen>(
            find.byType(ComicSourceSettingsScreen),
          )
          .source,
      same(source),
    );
    await tester.pageBack();
    await _pumpNavigation(tester);

    await _openDrawer(tester);
    final online = await _drawerTile(tester, s.comicOnlineFavorites);
    await tester.tap(online);
    await _pumpNavigation(tester);
    expect(StorageService.getBool('comic_online_favorites'), isTrue);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('library-page-title')))
          .data,
      s.comicOnlineFavorites,
    );
    expect(
      find.text(s.librarySearchHint(s.comicOnlineFavorites)),
      findsOneWidget,
    );

    await _openDrawer(tester);
    final selectedOnline = await _drawerTile(tester, s.comicOnlineFavorites);
    expect(tester.widget<ListTile>(selectedOnline).selected, isTrue);
    final local = await _drawerTile(tester, s.comicLocalFavorites);
    await tester.tap(local);
    await _pumpNavigation(tester);
    expect(StorageService.getBool('comic_online_favorites'), isFalse);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('library-page-title')))
          .data,
      s.comicLocalFavorites,
    );
    expect(
      find.text(s.librarySearchHint(s.comicLocalFavorites)),
      findsOneWidget,
    );

    await _openDrawer(tester);
    final selectedLocal = await _drawerTile(tester, s.comicLocalFavorites);
    expect(tester.widget<ListTile>(selectedLocal).selected, isTrue);
  });

  testWidgets('source without account support keeps only local favorites', (
    tester,
  ) async {
    await _pumpComicScreen(
      tester,
      source: _TestComicSource(
        supportsAccount: false,
        supportsRemoteFavorites: false,
      ),
    );
    final s = S.of(tester.element(find.byType(ComicScreen)));
    final sections = tester
        .widget<LibraryPageScaffold>(find.byType(LibraryPageScaffold))
        .drawerChildren
        .whereType<LibraryDrawerSection>()
        .toList();

    expect(
      sections.any((section) => section.title == s.libraryAccount),
      isFalse,
    );
    expect(sections.map((section) => section.title), contains(s.libraryLocal));
    expect(
      sections
          .where((section) => section.title == s.libraryLocal)
          .single
          .children
          .whereType<LibraryDrawerTile>()
          .map((tile) => tile.title),
      contains(s.comicLocalFavorites),
    );
    expect(
      sections
          .expand((section) => section.children)
          .whereType<LibraryDrawerTile>()
          .map((tile) => tile.title),
      isNot(contains(s.comicOnlineFavorites)),
    );
  });

  testWidgets('unsupported source stays local after default changes', (
    tester,
  ) async {
    await _pumpComicScreen(
      tester,
      source: _TestComicSource(
        supportsAccount: false,
        supportsRemoteFavorites: false,
      ),
      localFavorites: const [
        Comic(source: 'fixture', id: 'local-favorite', title: 'Local favorite'),
      ],
    );
    final s = S.of(tester.element(find.byType(ComicScreen)));
    final localFavoriteContent = find.byWidgetPredicate(
      (widget) =>
          widget is ComicGrid &&
          widget.comics.any((comic) => comic.id == 'local-favorite'),
    );

    await _openDrawer(tester);
    final local = await _drawerTile(tester, s.comicLocalFavorites);
    await tester.tap(local);
    await _pumpNavigation(tester);
    await _pumpUntilFound(tester, localFavoriteContent);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('library-page-title')))
          .data,
      s.comicLocalFavorites,
    );
    expect(localFavoriteContent, findsOneWidget);
    expect(find.byType(ComicErrorView), findsNothing);

    await _openDrawer(tester);
    final settings = await _drawerTile(tester, s.comicSettings);
    await tester.tap(settings);
    await _pumpNavigation(tester);
    final defaultOnlineFavorites = find.widgetWithText(
      SwitchListTile,
      s.comicDefaultOnlineFavorites,
    );
    expect(
      tester.widget<SwitchListTile>(defaultOnlineFavorites).value,
      isFalse,
    );
    await tester.tap(defaultOnlineFavorites);
    await tester.pump();
    await tester.pump();
    expect(StorageService.getBool('comic_online_favorites'), isTrue);

    await tester.pageBack();
    await _pumpNavigation(tester);
    await _pumpUntilFound(tester, localFavoriteContent);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('library-page-title')))
          .data,
      s.comicLocalFavorites,
    );
    expect(localFavoriteContent, findsOneWidget);
    expect(find.byType(ComicErrorView), findsNothing);
    expect(
      find.text(s.librarySearchHint(s.comicLocalFavorites)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search uses the displayed fallback source for online favorites',
    (tester) async {
      await StorageService.setBool('comic_online_favorites', true);
      final disabledSource = _TestComicSource(key: 'disabled');
      final fallbackSource = _TestComicSource(key: 'fallback');
      await _pumpComicScreen(
        tester,
        source: disabledSource,
        otherSources: [fallbackSource],
        selectedSource: 'disabled',
        disabledSources: const {'disabled'},
      );
      final s = S.of(tester.element(find.byType(ComicScreen)));

      await _openDrawer(tester);
      final online = await _drawerTile(tester, s.comicOnlineFavorites);
      await tester.tap(online);
      await _pumpNavigation(tester);
      await tester.tap(find.byKey(const ValueKey('library-page-search')));
      await _pumpNavigation(tester);

      final search = tester.widget<ComicSearchScreen>(
        find.byType(ComicSearchScreen),
      );
      expect(search.initialSource, 'fallback');
      expect(search.onlineFavorites, isTrue);
    },
  );
}

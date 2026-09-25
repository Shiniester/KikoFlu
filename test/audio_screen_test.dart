import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/history_provider.dart';
import 'package:kikoeru_flutter/src/providers/my_reviews_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/providers/subtitle_library_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_screen.dart';
import 'package:kikoeru_flutter/src/screens/search_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/providers/my_tabs_display_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/screens/main_screen.dart';
import 'package:kikoeru_flutter/src/screens/works_screen.dart';
import 'package:kikoeru_flutter/src/screens/history_screen.dart';
import 'package:kikoeru_flutter/src/screens/local_downloads_screen.dart';
import 'package:kikoeru_flutter/src/screens/subtitle_library_screen.dart';
import 'package:kikoeru_flutter/src/widgets/global_audio_player_wrapper.dart';
import 'package:kikoeru_flutter/src/widgets/floating_feed_toolbar.dart';

class _Reviews extends MyReviewsNotifier {
  _Reviews(Ref ref) : super(KikoeruApiService(), ref);

  void populate() {
    final works = List.generate(
      40,
      (i) => Work(id: 200 + i, title: 'Marked $i'),
    );
    state = state.copyWith(
      works: works,
      rawWorks: works,
      totalCount: 40,
      hasMore: false,
    );
  }

  @override
  Future<void> load({
    bool refresh = false,
    int? targetPage,
    bool append = false,
    bool supersede = false,
  }) async {}
}

class _History extends HistoryNotifier {
  _History(super.ref);

  void populate() {
    state = HistoryState(
      records: List.generate(
        40,
        (i) => HistoryRecord(
          work: Work(id: 100 + i, title: 'History $i'),
          lastPlayedTime: DateTime(2026),
        ),
      ),
      totalCount: 40,
      pageSize: 40,
      hasMore: false,
    );
  }

  @override
  Future<void> load({
    bool refresh = false,
    bool force = false,
    int? targetPage,
  }) async {}
}

class _Works extends WorksNotifier {
  _Works(Ref ref) : super(KikoeruApiService(), ref) {
    state = WorksState(
      layoutType: LayoutType.list,
      modeStates: {
        for (final mode in DisplayMode.values)
          mode: WorksModeSnapshot(
            works: List.generate(30, (i) => Work(id: i + 1, title: 'Work $i')),
            hasMore: false,
          ),
      },
    );
  }

  @override
  Future<void> loadWorks({
    bool refresh = false,
    int? targetPage,
    bool append = false,
    bool supersede = false,
  }) async {}
}

class _SubtitleLibrary extends SubtitleLibraryNotifier {}

Future<void> _pumpAudioScreen(
  WidgetTester tester,
  ValueNotifier<bool> reduced, {
  Widget screen = const AudioScreen(),
  bool settle = true,
}) async {
  final app = ProviderScope(
    overrides: [
      myReviewsProvider.overrideWith((ref) => _Reviews(ref)),
      worksProvider.overrideWith((ref) => _Works(ref)),
      subtitleLibraryProvider.overrideWith((ref) => _SubtitleLibrary()),
      historyProvider.overrideWith((ref) => _History(ref)),
      downloadSummaryProvider.overrideWith(
        (ref) => Stream.value(const DownloadTaskSummary.empty()),
      ),
      downloadTaskIdsProvider.overrideWith((ref) => Stream.value(<String>[])),
      currentTrackProvider.overrideWith((ref) => Stream.value(null)),
    ],
    child: MaterialApp(
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: ValueListenableBuilder<bool>(
        valueListenable: reduced,
        child: screen,
        builder: (context, value, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: value),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpWidget(app);
  if (settle) await tester.pumpAndSettle();
}

PageController _pages(WidgetTester tester) => tester
    .widget<PageView>(
      find.descendant(
        of: find.byType(TabBarView),
        matching: find.byType(PageView),
      ),
    )
    .controller!;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'works_layout_type': 'list',
      'my_tabs_show_playlists': false,
      'my_tabs_show_subtitle_library': false,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  for (final disableAnimations in [false, true]) {
    for (final layout in LayoutType.values) {
      testWidgets(
        'online marks retain position after visiting downloads ($disableAnimations, $layout)',
        (tester) async {
          final reduced = ValueNotifier(disableAnimations);
          addTearDown(reduced.dispose);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('my_reviews_layout_type', layout.name);
          await prefs.setString('collection_history_layout_type', layout.name);
          await _pumpAudioScreen(tester, reduced);
          final container = ProviderScope.containerOf(
            tester.element(find.byType(AudioScreen)),
          );
          (container.read(myReviewsProvider.notifier) as _Reviews).populate();
          await tester.tap(find.byType(Tab).at(1));
          await tester.pumpAndSettle();
          ScrollController marksScroll() => tester
              .widget<CustomScrollView>(
                find.descendant(
                  of: find.byKey(const ValueKey('onlineMarks')),
                  matching: find.byType(CustomScrollView),
                ),
              )
              .controller!;
          marksScroll().jumpTo(510);
          await tester.pumpAndSettle();
          expect(
            marksScroll().offset,
            510,
            reason: 'before leaving online marks',
          );
          for (var i = 0; i < 2; i++) {
            await tester.drag(find.byType(TabBarView), const Offset(-600, 0));
            await tester.pumpAndSettle();
          }
          expect(_pages(tester).page, 3);
          for (var i = 0; i < 2; i++) {
            await tester.drag(find.byType(TabBarView), const Offset(600, 0));
            await tester.pumpAndSettle();
          }
          expect(_pages(tester).page, 1);
          expect(marksScroll().offset, 510);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'history retains position after swiping back from home ($disableAnimations, $layout)',
        (tester) async {
          final reduced = ValueNotifier(disableAnimations);
          addTearDown(reduced.dispose);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('my_reviews_layout_type', layout.name);
          await prefs.setString('collection_history_layout_type', layout.name);
          await _pumpAudioScreen(tester, reduced);
          final container = ProviderScope.containerOf(
            tester.element(find.byType(AudioScreen)),
          );
          (container.read(historyProvider.notifier) as _History).populate();
          await tester.tap(find.byType(Tab).at(2));
          await tester.pumpAndSettle();
          ScrollController historyScroll() => tester
              .widget<CustomScrollView>(
                find.descendant(
                  of: find.byType(HistoryScreen),
                  matching: find.byType(CustomScrollView),
                ),
              )
              .controller!;
          historyScroll().jumpTo(360);
          await tester.pumpAndSettle();
          expect(historyScroll().offset, 360);
          for (var i = 0; i < 2; i++) {
            await tester.drag(find.byType(TabBarView), const Offset(600, 0));
            await tester.pumpAndSettle();
          }
          expect(_pages(tester).page, 0);
          for (var i = 0; i < 2; i++) {
            await tester.drag(find.byType(TabBarView), const Offset(-600, 0));
            await tester.pumpAndSettle();
          }
          expect(_pages(tester).page, 2);
          expect(historyScroll().offset, 360);
          final historyElement = tester.element(find.byType(HistoryScreen));
          await tester.tap(find.byIcon(Icons.search).last);
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.arrow_back));
          await tester.pumpAndSettle();
          expect(historyScroll().offset, 360);
          expect(
            tester.element(find.byType(HistoryScreen)),
            same(historyElement),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('home toolbar follows tab visibility ($disableAnimations)', (
      tester,
    ) async {
      final reduced = ValueNotifier(disableAnimations);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      final toolbar = find.descendant(
        of: find.byType(WorksScreen),
        matching: find.byType(FloatingFeedToolbar),
      );
      final scrollView = find
          .descendant(
            of: find.byType(WorksScreen),
            matching: find.byType(CustomScrollView),
          )
          .first;
      final initialTop = tester.getTopLeft(toolbar).dy;
      await tester.drag(scrollView, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(toolbar).dy,
        closeTo(initialTop - kTextTabBarHeight - 8, 0.1),
      );
      await tester.drag(scrollView, const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(toolbar).dy, closeTo(initialTop, 0.1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('subtitle library stays mounted across distant tab switches', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('my_tabs_show_subtitle_library', true);
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced, settle: false);
    await tester.pump(const Duration(milliseconds: 300));
    final tabs = tester.widget<TabBar>(find.byType(TabBar)).controller!;
    tabs.animateTo(tabs.length - 1);
    await tester.pump(const Duration(milliseconds: 300));
    final libraryElement = tester.element(find.byType(SubtitleLibraryScreen));
    tabs.animateTo(0);
    await tester.pump(const Duration(milliseconds: 300));
    tabs.animateTo(tabs.length - 1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.element(find.byType(SubtitleLibraryScreen)),
      same(libraryElement),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion switches Audio tabs immediately', (tester) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    expect(
      tester.widget<TabBar>(find.byType(TabBar)).controller!.animationDuration,
      Duration.zero,
    );
    for (final index in [1, 2, 0]) {
      await tester.tap(find.byType(Tab).at(index));
      await tester.pump();
      expect(_pages(tester).page, index.toDouble());
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('online search returns to the selected Audio tab', (
    tester,
  ) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.controller!.index, 0);
    expect(
      find.descendant(of: find.byType(TabBar), matching: find.text('Home')),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byType(Tab).at(2));
    await tester.tap(find.byType(Tab).at(2));
    await tester.pumpAndSettle();
    final history = tester.state(find.byType(HistoryScreen));
    await tester.tap(find.byTooltip('Search online works'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(
      tester.widget<SearchScreen>(find.byType(SearchScreen)).scope,
      SearchScope.history,
    );
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);
    expect(tester.state(find.byType(HistoryScreen)), same(history));
  });

  testWidgets('outer tab swipe moves between Works Home and online marks', (
    tester,
  ) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    final initialMode = container.read(worksProvider).displayMode;

    await tester.drag(find.byType(TabBarView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
    expect(container.read(worksProvider).displayMode, initialMode);

    await tester.drag(find.byType(TabBarView), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
    expect(container.read(worksProvider).displayMode, initialMode);
    expect(tester.takeException(), isNull);
  });

  testWidgets('online mark search captures the selected mark state', (
    tester,
  ) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    container
        .read(myReviewsProvider.notifier)
        .changeFilter(MyReviewFilter.marked);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Tab).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search online works'));
    await tester.pumpAndSettle();

    final search = tester.widget<SearchScreen>(find.byType(SearchScreen));
    expect(search.scope, SearchScope.onlineMarks);
    expect(search.progressFilter, 'marked');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'optional tabs preserve identity and a hidden current tab returns home',
    (tester) async {
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AudioScreen)),
      );
      await tester.ensureVisible(find.byType(Tab).at(2));
      await tester.tap(find.byType(Tab).at(2));
      await tester.pumpAndSettle();
      await container
          .read(myTabsDisplayProvider.notifier)
          .setShowOnlineMarks(false);
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
      expect(find.byType(HistoryScreen), findsOneWidget);
      await container
          .read(myTabsDisplayProvider.notifier)
          .setShowOnlineMarks(true);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Tab).at(1));
      await tester.pumpAndSettle();
      await container
          .read(myTabsDisplayProvider.notifier)
          .setShowOnlineMarks(false);
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
      expect(find.byType(WorksScreen), findsOneWidget);
    },
  );

  testWidgets('inline home and marks controls keep preferences independent', (
    tester,
  ) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    final reviewLayout = container.read(myReviewsProvider).layoutType;
    final homeLayout = container.read(worksProvider).layoutType;
    await tester.tap(find.byTooltip('Layout').first);
    await tester.pumpAndSettle();
    expect(container.read(worksProvider).layoutType, LayoutType.bigGrid);
    expect(container.read(myReviewsProvider).layoutType, reviewLayout);
    expect(container.read(worksProvider).layoutType, isNot(homeLayout));
    await tester.tap(find.byTooltip('Subtitle filter'));
    await tester.pumpAndSettle();
    final homeSubtitleFilter = container.read(worksProvider).subtitleFilter;
    expect(homeSubtitleFilter, isNot(0));

    for (final mode in [DisplayMode.popular, DisplayMode.recommended]) {
      container.read(worksProvider.notifier).setDisplayMode(mode);
      await tester.pumpAndSettle();
      final sortButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Sort'),
          matching: find.byType(IconButton),
        ),
      );
      expect(sortButton.onPressed, isNull);
    }

    await tester.tap(find.byType(Tab).at(1));
    await tester.pumpAndSettle();
    final workLayout = container.read(worksProvider).layoutType;
    final workSubtitleFilter = container.read(worksProvider).subtitleFilter;
    await tester.tap(find.byTooltip('Layout').first);
    await tester.pumpAndSettle();
    expect(container.read(myReviewsProvider).layoutType, isNot(reviewLayout));
    expect(container.read(worksProvider).layoutType, workLayout);
    await tester.tap(find.byTooltip('Subtitle filter'));
    await tester.pumpAndSettle();
    expect(container.read(myReviewsProvider).subtitleFilter, isNot(0));
    expect(container.read(worksProvider).subtitleFilter, workSubtitleFilter);
    expect(container.read(worksProvider).subtitleFilter, homeSubtitleFilter);
  });

  for (final size in [const Size(390, 844), const Size(1000, 600)]) {
    testWidgets('main navigation retains Audio state at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced, screen: const MainScreen());
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AudioScreen)),
      );
      final navigation = size.width > size.height
          ? find.byType(NavigationRail)
          : find.byType(NavigationBar);
      if (size.width > size.height) {
        expect(
          tester.widget<NavigationRail>(navigation).destinations.length,
          2,
        );
      } else {
        expect(
          tester
              .widget<NavigationBar>(navigation)
              .destinations
              .map((item) => (item as NavigationDestination).label),
          ['Audio', 'Settings'],
        );
      }
      final scroll = tester
          .widget<CustomScrollView>(
            find.descendant(
              of: find.byType(WorksScreen),
              matching: find.byType(CustomScrollView),
            ),
          )
          .controller!;
      scroll.jumpTo(400);
      await tester.pumpAndSettle();
      final offset = scroll.offset;
      await tester.tap(find.byTooltip('Search online works'));
      await tester.pumpAndSettle();
      expect(find.byType(GlobalAudioPlayerWrapper), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(NavigationRail), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(scroll.offset, offset);
      // Scroll up enough to reveal the tab switcher before choosing History.
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(Tab).at(2));
      await tester.tap(find.byType(Tab).at(2));
      await tester.pumpAndSettle();
      final history = tester.state(find.byType(HistoryScreen));
      final refresh = container.read(settingsCacheRefreshTriggerProvider);
      await tester.tap(
        find.descendant(
          of: navigation,
          matching: find.byIcon(Icons.settings_outlined),
        ),
      );
      await tester.pumpAndSettle();
      expect(container.read(settingsCacheRefreshTriggerProvider), refresh + 1);
      await tester.tap(
        find.descendant(
          of: navigation,
          matching: find.byIcon(Icons.library_music_outlined),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);
      expect(tester.state(find.byType(HistoryScreen)), same(history));
      expect(tester.takeException(), isNull);
    });
  }

  for (final subtitles in [false, true]) {
    testWidgets(
      'local search tools remain usable at 320px, subtitles=$subtitles',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final reduced = ValueNotifier(true);
        addTearDown(reduced.dispose);
        final screen = subtitles
            ? const SubtitleLibraryScreen()
            : const LocalDownloadsScreen();
        await _pumpAudioScreen(
          tester,
          reduced,
          screen: screen,
          settle: !subtitles,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final tooltip = subtitles
            ? 'Search subtitles...'
            : 'Search downloaded works...';
        await tester.tap(find.byTooltip(tooltip));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(TextField), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'test');
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('Search online works'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'reduced motion finishes Audio tab travel without remounting pages',
    (tester) async {
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      final pageView = tester.element(find.byType(TabBarView));
      await tester.ensureVisible(find.byType(Tab).at(2));
      await tester.tap(find.byType(Tab).at(2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(_pages(tester).page, lessThan(2));
      reduced.value = true;
      await tester.pump();
      expect(_pages(tester).page, 2);
      await tester.pumpAndSettle();

      reduced.value = false;
      await tester.pump();
      expect(tester.element(find.byType(TabBarView)), same(pageView));
      expect(_pages(tester).page, 2);

      await tester.tap(find.byType(Tab).at(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(_pages(tester).page, greaterThan(1));
      expect(_pages(tester).page, lessThan(2));
      reduced.value = true;
      await tester.pump();
      expect(_pages(tester).page, 1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

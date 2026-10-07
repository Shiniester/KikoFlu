import 'package:kikoeru_flutter/src/screens/settings_screen.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:kikoeru_flutter/src/comics/ui/comic_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show BaseCacheManager, FileResponse;
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
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    hide kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart'
    show AuthNotifier, AuthState, authProvider, kikoeruApiServiceProvider;
import 'package:kikoeru_flutter/src/models/user.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/models/history_record.dart';
import 'package:kikoeru_flutter/src/models/search_query.dart';
import 'package:kikoeru_flutter/src/providers/my_tabs_display_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/screens/main_screen.dart';
import 'package:kikoeru_flutter/src/screens/works_screen.dart';
import 'package:kikoeru_flutter/src/screens/work_detail_screen.dart';
import 'package:kikoeru_flutter/src/screens/history_screen.dart';
import 'package:kikoeru_flutter/src/screens/playlists_screen.dart';
import 'package:kikoeru_flutter/src/screens/local_downloads_screen.dart';
import 'package:kikoeru_flutter/src/screens/subtitle_library_screen.dart';
import 'package:kikoeru_flutter/src/widgets/global_audio_player_wrapper.dart';
import 'package:kikoeru_flutter/src/widgets/floating_feed_toolbar.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/widgets/enhanced_work_card.dart';
import 'package:kikoeru_flutter/src/widgets/pagination_bar.dart';
import 'package:kikoeru_flutter/src/utils/snackbar_util.dart';
import 'package:kikoeru_flutter/src/widgets/settings_section.dart';

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

  void useGrid() => state = state.copyWith(layoutType: LayoutType.bigGrid);

  @override
  Future<void> loadWorks({
    bool refresh = false,
    int? targetPage,
    bool append = false,
    bool supersede = false,
  }) async {}
}

class _SubtitleLibrary extends SubtitleLibraryNotifier {}

class _PendingDetailsApi extends KikoeruApiService {
  final metadata = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> getWork(
    int id, {
    bool forceRefresh = false,
    dynamic cancelToken,
  }) => metadata.future;

  @override
  Future<List<dynamic>> getWorkTracks(
    int id, {
    bool forceRefresh = false,
  }) async => [];
}

class _PendingCoverLease extends Fake implements RemoteAssetLease {
  final completed = Completer<File>();
  @override
  Future<File> get file => completed.future;
  @override
  Future<void> release() async {}
}

class _PendingCoverCache extends Fake implements RemoteAssetImageCacheManager {
  @override
  RemoteAssetLease acquireFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool speculative = false,
    bool forceRevalidate = false,
  }) => _PendingCoverLease();
}

class _NoImageCache extends Fake implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => const Stream.empty();
}

Future<void> _pumpAudioScreen(
  WidgetTester tester,
  ValueNotifier<bool> reduced, {
  Widget screen = const AudioScreen(),
  bool settle = true,
  AudioTrack? track,
  ThemeData? theme,
  VoidCallback? onHistoryCreated,
  GlobalKey? sceneKey,
  KikoeruApiService? detailApi,
}) async {
  final app = ProviderScope(
    overrides: [
      if (detailApi != null)
        kikoeruApiServiceProvider.overrideWithValue(detailApi),
      if (detailApi != null)
        workDetailCoverCacheProvider.overrideWithValue(_PendingCoverCache()),
      authProvider.overrideWith(
        (ref) => _AuthenticatedAudio(
          host: detailApi == null ? 'https://api.asmr-200.com' : '',
        ),
      ),
      myReviewsProvider.overrideWith((ref) => _Reviews(ref)),
      worksProvider.overrideWith((ref) => _Works(ref)),
      subtitleLibraryProvider.overrideWith((ref) => _SubtitleLibrary()),
      historyProvider.overrideWith((ref) {
        onHistoryCreated?.call();
        return _History(ref);
      }),
      downloadSummaryProvider.overrideWith(
        (ref) => Stream.value(const DownloadTaskSummary.empty()),
      ),
      downloadTaskIdsProvider.overrideWith((ref) => Stream.value(<String>[])),
      currentTrackProvider.overrideWith((ref) => Stream.value(track)),
      if (track != null) ...[
        isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        playerStateProvider.overrideWith(
          (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
        ),
        queueProvider.overrideWith((ref) => Stream.value([track])),
        manualSkipAvailabilityProvider.overrideWith(
          (ref) => Stream.value(ManualSkipAvailability.unavailable),
        ),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
      ],
    ],
    child: MaterialApp(
      theme: theme,
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
  await tester.pumpWidget(
    sceneKey == null ? app : RepaintBoundary(key: sceneKey, child: app),
  );
  if (settle) await tester.pumpAndSettle();
}

PageController _pages(WidgetTester tester) => tester
    .widget<PageView>(find.byKey(const ValueKey('audio-tab-pages')))
    .controller!;

class _AuthenticatedAudio extends AuthNotifier {
  _AuthenticatedAudio({String host = 'https://api.asmr-200.com'})
    : super(KikoeruApiService()) {
    state = AuthState(
      currentUser: const User(name: 'listener'),
      host: host,
      isLoggedIn: true,
    );
  }
  @override
  Future<void> enterAnonymous({String? host}) async {}
}

void main() {
  setUp(() async {
    CachedNetworkImageProvider.defaultCacheManager = _NoImageCache();
    SharedPreferences.setMockInitialValues({
      'works_layout_type': 'list',
      'my_tabs_show_playlists': false,
      'my_tabs_show_subtitle_library': false,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('audio home remains visible after rotating the main screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced, screen: const MainScreen());
    final audioState = tester.state(find.byType(AudioScreen));
    final worksState = tester.state(find.byType(WorksScreen));
    for (final size in [const Size(844, 390), const Size(390, 844)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(find.byType(WorksScreen), findsOneWidget);
      expect(find.text('Work 0'), findsOneWidget);
      expect(tester.state(find.byType(AudioScreen)), same(audioState));
      expect(tester.state(find.byType(WorksScreen)), same(worksState));
      expect(tester.takeException(), isNull);
    }
    tester
        .widget<NavigationBar>(find.byType(NavigationBar))
        .onDestinationSelected!(2);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      2,
    );
    final pages = tester
        .widget<PageView>(find.byKey(const ValueKey('main-tab-pages')))
        .controller!;
    expect(pages.page, 2);
    expect(pages.positions.length, 1);
    expect(find.byType(SettingsSectionList), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Android system back restores the painted audio home after rotation',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      final scene = GlobalKey();
      await _pumpAudioScreen(
        tester,
        reduced,
        screen: const MainScreen(),
        theme: AppTheme.lightTheme(
          null,
        ).copyWith(platform: TargetPlatform.android),
        sceneKey: scene,
        detailApi: _PendingDetailsApi(),
      );
      for (final size in [const Size(844, 390), const Size(390, 844)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
      }
      final source = tester.element(find.byType(WorksScreen));
      (ProviderScope.containerOf(source).read(worksProvider.notifier) as _Works)
          .useGrid();
      await tester.pumpAndSettle();
      Future<List<int>> homePixels() => tester
          .runAsync(() async {
            final boundary =
                scene.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            try {
              final pixels = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              return pixels.buffer.asUint8List().toList();
            } finally {
              image.dispose();
            }
          })
          .then((value) => value!);
      final before = await homePixels();
      final homeState = tester.state(find.byType(WorksScreen));
      pushWorkDetailRoute(
        source,
        builder: (_) =>
            const WorkDetailScreen(work: Work(id: 1, title: 'Work 0')),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(WorkDetailScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(WorkDetailScreen), findsNothing);
      expect(tester.state(find.byType(WorksScreen)), same(homeState));
      final after = await homePixels();
      var changed = 0;
      for (var i = 0; i < before.length; i++) {
        if (before[i] != after[i]) changed++;
      }
      expect(
        changed,
        0,
        reason: 'The home body must paint again after system back.',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final withTrack in [false, true]) {
    testWidgets('main content fills the moving Dock gap (track=$withTrack)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.reset);
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(
        tester,
        reduced,
        screen: const MainScreen(),
        theme: AppTheme.lightTheme(null),
        track: withTrack
            ? const AudioTrack(
                id: 'dock-gap-track',
                title: 'Audio',
                url: 'https://example.invalid/audio.mp3',
              )
            : null,
      );
      final source = find.descendant(
        of: find.byType(WorksScreen, skipOffstage: false),
        matching: find.byType(CustomScrollView, skipOffstage: false),
      );
      final scroll = tester.widget<CustomScrollView>(source).controller!;
      final dockTop = tester.getRect(find.byType(AppBottomDock)).top;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(PaginationBar)).bottom,
        lessThanOrEqualTo(dockTop),
        reason: 'Pagination must remain reachable above the Dock.',
      );
      scroll.jumpTo(400);
      await tester.pumpAndSettle();
      final offset = scroll.offset;
      final viewport = tester.getRect(source);
      final sourceContext = tester.element(source);
      pushWorkDetailRoute(
        sourceContext,
        builder: (_) => const GlobalAudioPlayerWrapper.workDetails(
          child: Scaffold(body: Center(child: Text('Details'))),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final movingDock = find.byKey(
        withTrack
            ? appBottomDockMiniPlayerHandoffRootKey
            : appBottomDockTabBarHandoffRootKey,
      );
      final movingTop = tester.getRect(movingDock).top;
      expect(movingTop, greaterThan(dockTop));
      expect(
        tester.getRect(source).bottom,
        greaterThanOrEqualTo(tester.getRect(movingDock).top),
        reason: 'The revealed strip must contain the source list viewport.',
      );
      expect(tester.getSize(source), viewport.size);
      expect(scroll.offset, offset);
      expect(
        find
            .byType(EnhancedWorkCard, skipOffstage: false)
            .evaluate()
            .any(
              (element) => tester
                  .getRect(find.byWidget(element.widget, skipOffstage: false))
                  .overlaps(Rect.fromLTRB(0, dockTop, 100, movingTop)),
            ),
        isTrue,
        reason: 'Work cards must continue into the revealed strip.',
      );
      await tester.pumpAndSettle();
      Navigator.of(sourceContext).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.getRect(source).bottom,
        greaterThanOrEqualTo(tester.getRect(movingDock).top),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(source), viewport);
      expect(scroll.offset, offset);
      final container = ProviderScope.containerOf(sourceContext);
      SnackBarUtil.showInfo(sourceContext, 'Dock notice');
      await tester.pump();
      expect(
        (tester.widget<SnackBar>(find.byType(SnackBar)).margin! as EdgeInsets)
            .bottom,
        34 + 144,
        reason:
            'Notice placement uses the physical safe area, not Dock height.',
      );
      ScaffoldMessenger.of(sourceContext).removeCurrentSnackBar();
      (container.read(historyProvider.notifier) as _History).populate();
      tester.widget<TabBar>(find.byType(TabBar)).onTap!(2);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(FloatingActionButton)).bottom,
        lessThanOrEqualTo(dockTop - 16),
        reason: 'Nested Scaffold buttons must remain above the Dock.',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('audio search hands off the app tab bar and restores it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(
      tester,
      reduced,
      screen: AppBottomDockTransitionScope(
        child: Scaffold(
          body: const AudioScreen(),
          bottomNavigationBar: AppBottomDock(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            miniPlayer: const MiniPlayer(),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.library_music),
                label: 'Audio',
              ),
              NavigationDestination(
                icon: Icon(Icons.menu_book),
                label: 'Comics',
              ),
            ],
          ),
        ),
      ),
      track: const AudioTrack(
        id: 'audio-search-track',
        title: 'Audio',
        url: 'https://example.invalid/audio.mp3',
      ),
    );
    await tester.tap(find.byTooltip('Search online works'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
    expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
    expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsNothing);
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(tester.takeException(), isNull);
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
            await tester.drag(
              find.byKey(const ValueKey('audio-tab-pages')),
              const Offset(-600, 0),
            );
            await tester.pumpAndSettle();
          }
          expect(_pages(tester).page, 3);
          for (var i = 0; i < 2; i++) {
            await tester.drag(
              find.byKey(const ValueKey('audio-tab-pages')),
              const Offset(600, 0),
            );
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
            await tester.drag(
              find.byKey(const ValueKey('audio-tab-pages')),
              const Offset(600, 0),
            );
            await tester.pumpAndSettle();
          }
          expect(_pages(tester).page, 0);
          for (var i = 0; i < 2; i++) {
            await tester.drag(
              find.byKey(const ValueKey('audio-tab-pages')),
              const Offset(-600, 0),
            );
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
    tester.widget<TabBar>(find.byType(TabBar)).onTap!(tabs.length - 1);
    await tester.pump(const Duration(milliseconds: 300));
    final libraryElement = tester.element(find.byType(SubtitleLibraryScreen));
    tester.widget<TabBar>(find.byType(TabBar)).onTap!(0);
    await tester.pump(const Duration(milliseconds: 300));
    tester.widget<TabBar>(find.byType(TabBar)).onTap!(tabs.length - 1);
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

    await tester.drag(
      find.byKey(const ValueKey('audio-tab-pages')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
    expect(container.read(worksProvider).displayMode, initialMode);

    await tester.drag(
      find.byKey(const ValueKey('audio-tab-pages')),
      const Offset(600, 0),
    );
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

  for (final reducedMotion in [false, true]) {
    for (final size in [const Size(390, 844), const Size(1000, 600)]) {
      testWidgets(
        'main navigation slides and retains state ($size, reduced=$reducedMotion)',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final reduced = ValueNotifier(reducedMotion);
          addTearDown(reduced.dispose);
          await _pumpAudioScreen(tester, reduced, screen: const MainScreen());
          final audioState = tester.state(find.byType(AudioScreen));
          final start = tester.getRect(find.byType(AudioScreen));
          final navigation = size.width > size.height
              ? find.byType(NavigationRail)
              : find.byType(NavigationBar);
          await tester.tap(
            find.descendant(
              of: navigation,
              matching: find.byIcon(Icons.settings_outlined),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          final destination = tester.getRect(find.byType(SettingsScreen));
          final settingsCards = find.descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(SettingsSectionList),
          );
          if (reducedMotion) {
            expect(destination.left, closeTo(start.left, .1));
            expect(settingsCards, findsWidgets);
          } else {
            expect(settingsCards, findsNothing);
            expect(destination.left, greaterThan(start.left));
            expect(destination.left, lessThan(start.right));
            final pages = tester
                .widget<PageView>(find.byKey(const ValueKey('main-tab-pages')))
                .controller!;
            expect(pages.page, closeTo(2 * Curves.ease.transform(1 / 3), .001));
          }
          await tester.pumpAndSettle();
          expect(settingsCards, findsWidgets);
          final settingsState = tester.state(find.byType(SettingsScreen));
          expect(
            tester.getRect(find.byType(SettingsScreen)).left,
            closeTo(start.left, .1),
          );
          await tester.tap(
            find.descendant(
              of: navigation,
              matching: find.byIcon(Icons.library_music_outlined),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(AudioScreen)), same(audioState));
          await tester.tap(
            find.descendant(
              of: navigation,
              matching: find.byIcon(Icons.settings_outlined),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(settingsCards, findsWidgets);
          expect(
            tester.state(find.byType(SettingsScreen)),
            same(settingsState),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

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
          3,
        );
      } else {
        expect(
          tester
              .widget<NavigationBar>(navigation)
              .destinations
              .map((item) => (item as NavigationDestination).label),
          ['Audio', 'Comics', 'Settings'],
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
      final pageView = tester.element(
        find.byKey(const ValueKey('audio-tab-pages')),
      );
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
      expect(
        tester.element(find.byKey(const ValueKey('audio-tab-pages'))),
        same(pageView),
      );
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

  testWidgets(
    'Audio click follows ease motion and retargets from its position',
    (tester) async {
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      final pages = _pages(tester);
      await tester.tap(find.byType(Tab).at(2));
      await tester.pump();
      expect(pages.page, 0);
      expect(tabs.controller!.animation!.value, 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(pages.page, closeTo(2 * Curves.ease.transform(1 / 3), .001));
      expect(tabs.controller!.animation!.value, closeTo(pages.page!, .001));
      final from = pages.page!;
      await tester.tap(find.byType(Tab).at(0));
      await tester.pump();
      expect(pages.page, closeTo(from, .001));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        pages.page,
        closeTo(from * (1 - Curves.ease.transform(1 / 3)), .001),
      );
      expect(tabs.controller!.animation!.value, closeTo(pages.page!, .001));
      await tester.pump(const Duration(milliseconds: 199));
      expect(pages.page, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 1));
      expect(pages.page, 0);
      expect(tabs.controller!.index, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Audio drag interrupts click and reselecting the current tab settles',
    (tester) async {
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      await tester.tap(find.byType(Tab).at(2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('audio-tab-pages'))),
      );
      await gesture.moveBy(const Offset(220, 0));
      await tester.pump();
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(
        tabs.controller!.animation!.value,
        closeTo(_pages(tester).page!, .001),
      );
      await gesture.up();
      final current = tabs.controller!.index;
      expect(_pages(tester).page, isNot(closeTo(current.toDouble(), .001)));
      await tester.tap(find.byType(Tab).at(current));
      await tester.pumpAndSettle();
      expect(_pages(tester).page, current);
      expect(tabs.controller!.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing Audio tabs during travel keeps the destination identity',
    (tester) async {
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AudioScreen)),
      );
      await tester.tap(find.byType(Tab).at(2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await container
          .read(myTabsDisplayProvider.notifier)
          .setShowOnlineMarks(false);
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
      expect(_pages(tester).page, 1);
      final history = tester.state(find.byType(HistoryScreen));
      await container
          .read(myTabsDisplayProvider.notifier)
          .setShowOnlineMarks(true);
      await tester.pumpAndSettle();
      expect(_pages(tester).page, 2);
      expect(tester.state(find.byType(HistoryScreen)), same(history));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('first online marks content waits until tab travel finishes', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    (container.read(myReviewsProvider.notifier) as _Reviews).populate();
    await tester.pumpAndSettle();
    tester.widget<TabBar>(find.byType(TabBar)).onTap!(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_pages(tester).page, inExclusiveRange(0, 1));
    expect(find.text('Marked 0', skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Marked 0'), findsOneWidget);
    final card = tester.element(find.text('Marked 0'));
    tester.widget<TabBar>(find.byType(TabBar)).onTap!(0);
    await tester.pumpAndSettle();
    tester.widget<TabBar>(find.byType(TabBar)).onTap!(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Marked 0', skipOffstage: false), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.element(find.text('Marked 0')), same(card));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retargeting leaves abandoned cold content unbuilt', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    (container.read(myReviewsProvider.notifier) as _Reviews).populate();
    (container.read(historyProvider.notifier) as _History).populate();
    await tester.pumpAndSettle();
    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    tabs.onTap!(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    tabs.onTap!(2);
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 2);
    expect(find.text('History 0'), findsOneWidget);
    expect(find.text('Marked 0', skipOffstage: false), findsNothing);
    reduced.value = true;
    await tester.pump();
    tabs.onTap!(1);
    await tester.pumpAndSettle();
    expect(find.text('Marked 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first History click initializes before page movement', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    double? createdAtPage;
    await _pumpAudioScreen(
      tester,
      reduced,
      onHistoryCreated: () => createdAtPage = _pages(tester).page,
    );
    expect(createdAtPage, isNull);
    tester.widget<TabBar>(find.byType(TabBar)).onTap!(2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      createdAtPage,
      0,
      reason: 'First-entry initialization must precede the sliding frames.',
    );
    final pageView = tester.widget<PageView>(
      find.byKey(const ValueKey('audio-tab-pages')),
    );
    expect(pageView.scrollCacheExtent.value, 0);
    expect(pageView.allowImplicitScrolling, isFalse);
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('distant Audio clicks only initialize the chosen library', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('my_tabs_show_playlists', true);
    await prefs.setBool('my_tabs_show_subtitle_library', true);
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    tabs.onTap!(tabs.tabs.length - 1);
    await tester.pump();
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(HistoryScreen, skipOffstage: false), findsNothing);
      expect(find.byType(PlaylistsScreen, skipOffstage: false), findsNothing);
      expect(
        find.byType(LocalDownloadsScreen, skipOffstage: false),
        findsNothing,
      );
    }
    expect(find.byType(SubtitleLibraryScreen), findsOneWidget);
    final library = tester.state(find.byType(SubtitleLibraryScreen));
    tabs.onTap!(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    tabs.onTap!(tabs.tabs.length - 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.state(find.byType(SubtitleLibraryScreen)), same(library));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [const Size(390, 844), const Size(1000, 600)]) {
    testWidgets(
      'main paging stays lazy, ignores dragging and retargets ($size)',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final reduced = ValueNotifier(false);
        addTearDown(reduced.dispose);
        await _pumpAudioScreen(tester, reduced, screen: const MainScreen());
        final pagesFinder = find.byKey(const ValueKey('main-tab-pages'));
        final pages = tester.widget<PageView>(pagesFinder).controller!;
        final navigation = size.width > size.height
            ? find.byType(NavigationRail)
            : find.byType(NavigationBar);
        void select(int index) {
          if (size.width > size.height) {
            tester.widget<NavigationRail>(navigation).onDestinationSelected!(
              index,
            );
          } else {
            tester.widget<NavigationBar>(navigation).onDestinationSelected!(
              index,
            );
          }
        }

        final audioState = tester.state(find.byType(AudioScreen));
        select(2);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(pages.page, closeTo(2 * Curves.ease.transform(1 / 3), .001));
        expect(find.byType(ComicScreen, skipOffstage: false), findsNothing);
        select(0);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(pages.page, 0);
        expect(tester.state(find.byType(AudioScreen)), same(audioState));
        expect(
          find.descendant(
            of: find.byType(SettingsScreen, skipOffstage: false),
            matching: find.byType(SettingsSectionList, skipOffstage: false),
          ),
          findsNothing,
        );
        select(2);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        reduced.value = true;
        await tester.pump();
        expect(pages.page, 2);
        await tester.drag(pagesFinder, const Offset(600, 0));
        await tester.pumpAndSettle();
        expect(pages.page, 2);
        expect(find.byType(ComicScreen, skipOffstage: false), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

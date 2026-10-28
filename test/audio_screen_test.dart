import 'package:kikoeru_flutter/src/screens/settings_screen.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:kikoeru_flutter/src/comics/ui/comic_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
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
import 'package:kikoeru_flutter/src/providers/playlists_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/providers/subtitle_library_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_screen.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
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
import 'package:kikoeru_flutter/src/models/japanese_asmr_browse.dart';
import 'package:kikoeru_flutter/src/models/sort_options.dart';
import 'package:kikoeru_flutter/src/models/search_type.dart';
import 'package:kikoeru_flutter/src/screens/blocked_items_screen.dart';
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
import 'package:kikoeru_flutter/src/widgets/app_navigation_scope.dart';
import 'package:kikoeru_flutter/src/widgets/app_navigation_shell.dart';
import 'package:kikoeru_flutter/src/widgets/library_page_scaffold.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:kikoeru_flutter/src/widgets/volume_control.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/audio_source.dart' as audio_source;
import 'package:kikoeru_flutter/src/providers/audio_source_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/utils/l10n_extensions.dart';
import 'package:kikoeru_flutter/src/widgets/pagination_bar.dart';
import 'package:kikoeru_flutter/src/utils/snackbar_util.dart';
import 'package:kikoeru_flutter/src/widgets/settings_section.dart';
import 'package:kikoeru_flutter/src/widgets/japanese_asmr_access_prompt.dart';

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
  int loadWorksCalls = 0;

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

  void requireVerification() {
    state = state.copyWith(
      modeStates: {
        ...state.modeStates,
        state.displayMode: state.modeStates[state.displayMode]!.copyWith(
          error: '[jp-asmr-verification-required]',
        ),
      },
    );
  }

  void useDistinctModeTitles() {
    final modeStates = Map<DisplayMode, WorksModeSnapshot>.from(
      state.modeStates,
    );
    for (final mode in DisplayMode.values) {
      final works = List.generate(
        30,
        (i) => Work(id: i + 1, title: '${mode.name} $i'),
      );
      modeStates[mode] = modeStates[mode]!.copyWith(
        works: works,
        rawWorks: works,
      );
    }
    state = state.copyWith(modeStates: modeStates);
  }

  @override
  Future<void> loadWorks({
    bool refresh = false,
    int? targetPage,
    bool append = false,
    bool supersede = false,
  }) async {
    loadWorksCalls++;
  }
}

class _SubtitleLibrary extends SubtitleLibraryNotifier {}

class _EmptyPlaylistsApi extends KikoeruApiService {
  @override
  Future<Map<String, dynamic>> getUserPlaylists({
    int page = 1,
    int pageSize = 20,
    String filterBy = 'all',
    dynamic cancelToken,
  }) async => {'playlists': <dynamic>[]};
}

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
  Stream<AudioTrack?>? currentTrackStream,
  ThemeData? theme,
  VoidCallback? onHistoryCreated,
  GlobalKey? sceneKey,
  KikoeruApiService? detailApi,
}) async {
  final navigationController = screen is MainScreen
      ? AppNavigationController()
      : null;
  if (navigationController != null) {
    addTearDown(navigationController.dispose);
  }
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
      currentTrackProvider.overrideWith(
        (ref) => currentTrackStream ?? Stream.value(track),
      ),
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
      navigatorObservers: [
        if (navigationController != null) navigationController,
      ],
      builder: navigationController == null
          ? null
          : (context, navigator) => AppNavigationShell(
              controller: navigationController,
              child: navigator!,
            ),
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

void _pushGlobalAudioDetail(BuildContext context, String label) {
  unawaited(
    pushWorkDetailRoute(
      context,
      builder: (_) => GlobalAudioPlayerWrapper(
        child: Scaffold(body: Center(child: Text(label))),
      ),
    ),
  );
}

PageController _pages(WidgetTester tester) => tester
    .widget<PageView>(find.byKey(const ValueKey('audio-tab-pages')))
    .controller!;

LibraryPageScaffold _library(WidgetTester tester) => tester.widget(
  find.descendant(
    of: find.byType(AudioScreen),
    matching: find.byType(LibraryPageScaffold),
  ),
);

String _pageLabel(S s, String page) => switch (page) {
  'onlineMarks' => s.libraryMarks,
  'history' => s.libraryHistory,
  'playlists' => s.libraryFavorites,
  'downloads' => s.libraryDownloads,
  'subtitleLibrary' => s.librarySubtitles,
  'popular' => s.displayModePopular,
  'recommended' => s.displayModeRecommended,
  _ => s.navHome,
};

LibraryDrawerSection _section(WidgetTester tester, String title) =>
    _library(tester).drawerChildren
        .whereType<LibraryDrawerSection>()
        .firstWhere((section) => section.title == title);

LibraryDrawerTile _audioPageTile(WidgetTester tester, String page) {
  final s = S.of(tester.element(find.byType(AudioScreen)));
  return _section(tester, s.libraryPages).children
      .whereType<LibraryDrawerTile>()
      .singleWhere((tile) => tile.title == _pageLabel(s, page));
}

void _requestAudioPage(WidgetTester tester, String page) {
  final s = S.of(tester.element(find.byType(AudioScreen)));
  final section = _section(tester, s.libraryPages);
  final tiles = section.children.whereType<LibraryDrawerTile>();
  final tile = tiles.firstWhere((tile) => tile.title == _pageLabel(s, page));
  tile.onTap!();
}

void _requestAudioSource(WidgetTester tester, audio_source.AudioSource source) {
  final s = S.of(tester.element(find.byType(AudioScreen)));
  final section = _section(tester, s.librarySources);
  final tile = section.children.whereType<LibraryDrawerTile>().firstWhere(
    (tile) => tile.title == source.label,
  );
  tile.onTap!();
}

FractionalTranslation _outgoingAudioTransition(WidgetTester tester) =>
    tester.widget<FractionalTranslation>(
      find
          .ancestor(
            of: find.byType(RawImage),
            matching: find.byType(FractionalTranslation),
          )
          .first,
    );

ScrollController _worksScroll(WidgetTester tester) => tester
    .widget<CustomScrollView>(
      find.descendant(
        of: find.byType(WorksScreen),
        matching: find.byType(CustomScrollView),
      ),
    )
    .controller!;

LibraryDrawerTile _browseTile(WidgetTester tester, String title) {
  final s = S.of(tester.element(find.byType(AudioScreen)));
  final pageOptions = _section(tester, s.libraryPages).children
      .whereType<LibraryDrawerTile>()
      .expand((page) => page.children.whereType<LibraryDrawerTile>());
  final browseOptions = _section(
    tester,
    s.libraryBrowseOptions,
  ).children.whereType<LibraryDrawerTile>();
  return [
    ...pageOptions,
    ...browseOptions,
  ].firstWhere((tile) => tile.title == title);
}

void _advancedSearch(WidgetTester tester) => _library(tester).onSearch();

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

  testWidgets(
    'JP verification remains available when the home already has works',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        AudioSourceNotifier.preferenceKey,
        audio_source.AudioSource.jpAsmr.name,
      );
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AudioScreen)),
      );
      expect(container.read(worksProvider).works, isNotEmpty);

      (container.read(worksProvider.notifier) as _Works).requireVerification();
      await tester.pumpAndSettle();

      expect(container.read(worksProvider).works, isNotEmpty);
      expect(find.byType(JapaneseAsmrAccessPrompt), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
        .onDestinationSelected!(3);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      3,
    );
    final pages = tester
        .widget<PageView>(find.byKey(const ValueKey('main-tab-pages')))
        .controller!;
    expect(pages.page, 3);
    expect(pages.positions.length, 1);
    expect(find.byType(SettingsSectionList), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'source switch hides JP-unsupported tabs and restores ASMR tabs',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        AudioSourceNotifier.preferenceKey,
        audio_source.AudioSource.jpAsmr.name,
      );
      await prefs.setBool('my_tabs_show_online_marks', true);
      await prefs.setBool('my_tabs_show_playlists', true);
      await prefs.setBool('my_tabs_show_subtitle_library', false);
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);

      await _pumpAudioScreen(tester, reduced);

      final s = S.of(tester.element(find.byType(AudioScreen)));
      List<String> pageTitles() => _section(tester, s.libraryPages).children
          .whereType<LibraryDrawerTile>()
          .map((tile) => tile.title)
          .toList();
      expect(pageTitles(), [
        s.navHome,
        s.displayModePopular,
        s.libraryHistory,
        s.libraryDownloads,
      ]);
      expect(find.byType(TabBar), findsNothing);
      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      final one = find.text(audio_source.AudioSource.asmrOne.label);
      final jp = find.text(audio_source.AudioSource.jpAsmr.label);
      expect(tester.getTopLeft(one).dy, lessThan(tester.getTopLeft(jp).dy));
      await tester.tap(one);
      await tester.pumpAndSettle();
      expect(pageTitles(), [
        s.navHome,
        s.displayModePopular,
        s.displayModeRecommended,
        s.libraryMarks,
        s.libraryHistory,
        s.libraryFavorites,
        s.libraryDownloads,
      ]);
      expect(_library(tester).title, s.navHome);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('JP sidebar sorts home and selects independent popular periods', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AudioSourceNotifier.preferenceKey,
      audio_source.AudioSource.jpAsmr.name,
    );
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final s = S.of(tester.element(find.byType(AudioScreen)));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    final works = container.read(worksProvider.notifier) as _Works;
    final initialState = container.read(worksProvider);
    final initialLoadCalls = works.loadWorksCalls;

    _browseTile(tester, s.sort).onTap!();
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<AgeRating>), findsNothing);
    expect(
      find.byKey(const ValueKey('sort-age-rating-section')),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text(s.jpAsmrSortTitle));
    await tester.tap(find.text(s.jpAsmrSortTitle));
    await tester.pumpAndSettle();
    expect(find.text('R15').last, findsOneWidget);
    expect(find.text('R18').last, findsOneWidget);
    await tester.ensureVisible(find.text(s.sortAsc));
    await tester.tap(find.text(s.sortAsc));
    await tester.pump();
    await tester.ensureVisible(find.text(s.ageRatingGeneral));
    await tester.tap(find.text(s.ageRatingGeneral).last);
    await tester.pump();
    expect(
      container.read(worksProvider).japaneseAsmrSortOption,
      initialState.japaneseAsmrSortOption,
    );
    expect(
      container.read(worksProvider).japaneseAsmrDirection,
      initialState.japaneseAsmrDirection,
    );
    expect(
      container.read(worksProvider).japaneseAsmrAgeRating,
      initialState.japaneseAsmrAgeRating,
    );
    expect(works.loadWorksCalls, initialLoadCalls);
    await tester.tap(find.text(s.cancel));
    await tester.pumpAndSettle();

    _browseTile(tester, s.sort).onTap!();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(s.jpAsmrSortTitle));
    await tester.tap(find.text(s.jpAsmrSortTitle));
    await tester.pump();
    await tester.ensureVisible(find.text(s.sortAsc));
    await tester.tap(find.text(s.sortAsc));
    await tester.pump();
    await tester.ensureVisible(find.text(s.ageRatingGeneral));
    await tester.tap(find.text(s.ageRatingGeneral).last);
    await tester.pump();
    await tester.tap(find.text(s.confirm));
    await tester.pumpAndSettle();
    expect(
      container.read(worksProvider).japaneseAsmrSortOption,
      JapaneseAsmrSortOption.title,
    );
    expect(
      container.read(worksProvider).japaneseAsmrDirection,
      SortDirection.asc,
    );
    expect(
      container.read(worksProvider).japaneseAsmrAgeRating,
      AgeRating.general,
    );
    expect(works.loadWorksCalls, initialLoadCalls + 1);

    _browseTile(tester, s.sort).onTap!();
    await tester.pumpAndSettle();
    await tester.tap(find.text(s.sortReviewCount));
    await tester.tap(find.text(s.confirm));
    await tester.pumpAndSettle();
    _browseTile(tester, s.jpAsmrCommentsPeriod).onTap!();
    await tester.pumpAndSettle();
    await tester.tap(find.text(s.jpAsmrPeriodTwoWeeks));
    await tester.pumpAndSettle();
    expect(
      container.read(worksProvider).japaneseAsmrPeriod,
      JapaneseAsmrPeriod.twoWeeks,
    );

    _requestAudioPage(tester, 'popular');
    await tester.pumpAndSettle();
    expect(_library(tester).title, s.displayModePopular);
    expect(
      _section(tester, s.libraryBrowseOptions).children
          .whereType<LibraryDrawerTile>()
          .where((tile) => tile.title == s.sort),
      isEmpty,
    );
    _browseTile(tester, s.jpAsmrPopularPeriod).onTap!();
    await tester.pumpAndSettle();
    for (final label in [
      s.jpAsmrPeriodRecent,
      s.jpAsmrPeriodWeek,
      s.jpAsmrPeriodMonth,
      s.jpAsmrPeriodSixMonths,
      s.jpAsmrPeriodYear,
      s.jpAsmrPeriodAllTime,
      s.jpAsmrPeriodSelectYear,
      s.jpAsmrPeriodSelectMonth,
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text(s.jpAsmrPeriodRecent));
    await tester.pumpAndSettle();
    expect(
      container.read(worksProvider).japaneseAsmrPeriod,
      JapaneseAsmrPeriod.recent,
    );
    _requestAudioPage(tester, 'home');
    await tester.pumpAndSettle();
    expect(
      container.read(worksProvider).japaneseAsmrPeriod,
      JapaneseAsmrPeriod.twoWeeks,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ASMR sorting stages changes and source tiles share field text size',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        AudioSourceNotifier.preferenceKey,
        audio_source.AudioSource.asmrOne.name,
      );
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      final s = S.of(tester.element(find.byType(AudioScreen)));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AudioScreen)),
      );
      final works = container.read(worksProvider.notifier) as _Works;
      final initialState = container.read(worksProvider);
      final initialLoadCalls = works.loadWorksCalls;

      Future<void> openSortOptions() async {
        _browseTile(tester, s.sort).onTap!();
        await tester.pumpAndSettle();
      }

      Future<void> selectNewSortValues() async {
        await tester.ensureVisible(find.text(s.sortDlCount));
        await tester.tap(find.text(s.sortDlCount));
        await tester.pump();
        await tester.ensureVisible(find.text(s.sortAsc));
        await tester.tap(find.text(s.sortAsc));
        await tester.pump();
        await tester.ensureVisible(find.text(s.ageRatingGeneral));
        await tester.tap(find.text(s.ageRatingGeneral));
        await tester.pump();
      }

      await openSortOptions();
      final fields = find.byKey(const ValueKey('sort-field-section'));
      expect(
        find.descendant(of: fields, matching: find.text(s.sortNsfw)),
        findsNothing,
      );
      expect(find.text('R15'), findsOneWidget);
      expect(find.text('R18'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<AgeRating>), findsNothing);
      await selectNewSortValues();
      expect(container.read(worksProvider).sortOption, initialState.sortOption);
      expect(
        container.read(worksProvider).sortDirection,
        initialState.sortDirection,
      );
      expect(
        container.read(worksProvider).asmrOneAgeRating,
        initialState.asmrOneAgeRating,
      );
      expect(works.loadWorksCalls, initialLoadCalls);
      await tester.tap(find.text(s.cancel));
      await tester.pumpAndSettle();

      await openSortOptions();
      await selectNewSortValues();
      await tester.tap(find.text(s.confirm));
      await tester.pumpAndSettle();
      expect(container.read(worksProvider).sortOption, SortOrder.dlCount);
      expect(container.read(worksProvider).sortDirection, SortDirection.asc);
      expect(container.read(worksProvider).asmrOneAgeRating, AgeRating.general);
      expect(works.loadWorksCalls, initialLoadCalls + 1);

      Future<double> currentSortTextSize() async {
        await tester.tap(find.byKey(const ValueKey('library-menu-button')));
        await tester.pumpAndSettle();
        final drawer = find.byKey(const ValueKey('library-drawer'));
        final sortTitle = find
            .descendant(of: drawer, matching: find.text(s.sort))
            .first;
        await tester.scrollUntilVisible(
          sortTitle,
          160,
          scrollable: find
              .descendant(of: drawer, matching: find.byType(Scrollable))
              .first,
        );
        final sortTile = find
            .ancestor(of: sortTitle, matching: find.byType(ListTile))
            .first;
        final fieldLabel =
            container.read(audioSourceProvider) ==
                audio_source.AudioSource.asmrOne
            ? s.sortDlCount
            : s.sortRelease;
        final trailing = find.descendant(
          of: sortTile,
          matching: find.text(fieldLabel),
        );
        expect(trailing, findsOneWidget);
        return DefaultTextStyle.of(tester.element(trailing)).style.fontSize!;
      }

      final asmrFieldTextSize = await currentSortTextSize();
      await tester.ensureVisible(
        find.text(audio_source.AudioSource.jpAsmr.label),
      );
      await tester.tap(find.text(audio_source.AudioSource.jpAsmr.label));
      await tester.pumpAndSettle();
      expect(
        container.read(audioSourceProvider),
        audio_source.AudioSource.jpAsmr,
      );
      final jpFieldTextSize = await currentSortTextSize();
      expect(jpFieldTextSize, asmrFieldTextSize);
      expect(tester.takeException(), isNull);
    },
  );

  for (final source in audio_source.AudioSource.values) {
    testWidgets('sidebar opens existing blocking settings for ${source.name}', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AudioSourceNotifier.preferenceKey, source.name);
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      final s = S.of(tester.element(find.byType(AudioScreen)));
      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(s.block),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('library-drawer')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(s.block));
      await tester.pumpAndSettle();
      expect(find.byType(BlockedItemsScreen), findsOneWidget);
      expect(
        tester
            .widget<BlockedItemsScreen>(find.byType(BlockedItemsScreen))
            .source,
        source,
      );
      expect(find.text(s.blockedItems), findsOneWidget);
      Navigator.of(tester.element(find.byType(BlockedItemsScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(BlockedItemsScreen), findsNothing);
      expect(find.byType(AudioScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('JP sidebar selects a calendar year and month', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AudioSourceNotifier.preferenceKey,
      audio_source.AudioSource.jpAsmr.name,
    );
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final s = S.of(tester.element(find.byType(AudioScreen)));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    final ok = MaterialLocalizations.of(
      tester.element(find.byType(AudioScreen)),
    ).okButtonLabel;
    _requestAudioPage(tester, 'popular');
    await tester.pumpAndSettle();
    _browseTile(tester, s.jpAsmrPopularPeriod).onTap!();
    await tester.pumpAndSettle();
    await tester.tap(find.text(s.jpAsmrPeriodSelectYear));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2020'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ok));
    await tester.pumpAndSettle();
    expect(
      container.read(worksProvider).japaneseAsmrPeriod,
      JapaneseAsmrPeriod.archiveYear,
    );
    expect(container.read(worksProvider).japaneseAsmrArchiveDate?.year, 2020);

    _browseTile(tester, s.jpAsmrPopularPeriod).onTap!();
    await tester.pumpAndSettle();
    await tester.tap(find.text(s.jpAsmrPeriodSelectMonth));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ok));
    await tester.pumpAndSettle();
    expect(
      container.read(worksProvider).japaneseAsmrPeriod,
      JapaneseAsmrPeriod.archiveMonth,
    );
    expect(container.read(worksProvider).japaneseAsmrArchiveDate?.year, 2020);
    expect(tester.takeException(), isNull);
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
    testWidgets(
      'main content and Dock retain their layout (track=$withTrack)',
      (tester) async {
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
          builder: (_) => const GlobalAudioPlayerWrapper(
            child: Scaffold(body: Center(child: Text('Details'))),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getRect(find.byType(AppBottomDock)).top, dockTop);
        expect(tester.getSize(source), viewport.size);
        expect(scroll.offset, offset);
        await tester.pumpAndSettle();
        Navigator.of(sourceContext).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getRect(find.byType(AppBottomDock)).top, dockTop);
        await tester.pumpAndSettle();
        expect(tester.getRect(source), viewport);
        expect(scroll.offset, offset);
        SnackBarUtil.showInfo(sourceContext, 'Dock notice');
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TopFloatingNoticeWidget>(
                find.byType(TopFloatingNoticeWidget),
              )
              .topOffset,
          16.0,
          reason: 'Notice placement is fixed at the top (16 dp).',
        );
        SnackBarUtil.clearAll();
        _requestAudioPage(tester, 'downloads');
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byType(FloatingActionButton)).bottom,
          lessThanOrEqualTo(dockTop - 16),
          reason: 'Nested Scaffold buttons must remain above the Dock.',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('audio search keeps the app tab bar at the source page bottom', (
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
      screen: Scaffold(
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
            NavigationDestination(icon: Icon(Icons.menu_book), label: 'Comics'),
          ],
        ),
      ),
      track: const AudioTrack(
        id: 'audio-search-track',
        title: 'Audio',
        url: 'https://example.invalid/audio.mp3',
      ),
    );
    _advancedSearch(tester);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(find.byType(AppBottomDock)).bottom, 844);
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(find.byType(AppBottomDock)).bottom, 844);
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
          _requestAudioPage(tester, 'onlineMarks');
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
          _requestAudioPage(tester, 'downloads');
          await tester.pumpAndSettle();
          expect(_pages(tester).page, 3);
          _requestAudioPage(tester, 'onlineMarks');
          await tester.pumpAndSettle();
          expect(_pages(tester).page, 1);
          expect(marksScroll().offset, 510);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'history retains position after returning from home ($disableAnimations, $layout)',
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
          _requestAudioPage(tester, 'history');
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
          _requestAudioPage(tester, 'home');
          await tester.pumpAndSettle();
          expect(_pages(tester).page, 0);
          _requestAudioPage(tester, 'history');
          await tester.pumpAndSettle();
          expect(_pages(tester).page, 2);
          expect(historyScroll().offset, 360);
          final historyElement = tester.element(find.byType(HistoryScreen));
          _advancedSearch(tester);
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

    testWidgets(
      'home header stays fixed while scrolling ($disableAnimations)',
      (tester) async {
        final reduced = ValueNotifier(disableAnimations);
        addTearDown(reduced.dispose);
        await _pumpAudioScreen(tester, reduced);
        final toolbar = find.byKey(const ValueKey('library-page-header'));
        final scrollView = find
            .descendant(
              of: find.byType(WorksScreen),
              matching: find.byType(CustomScrollView),
            )
            .first;
        final initialTop = tester.getTopLeft(toolbar).dy;
        await tester.drag(scrollView, const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(toolbar).dy, closeTo(initialTop, 0.1));
        await tester.drag(scrollView, const Offset(0, 150));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(toolbar).dy, closeTo(initialTop, 0.1));
        expect(tester.takeException(), isNull);
      },
    );
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
    _requestAudioPage(tester, 'subtitleLibrary');
    await tester.pump(const Duration(milliseconds: 300));
    final libraryElement = tester.element(find.byType(SubtitleLibraryScreen));
    _requestAudioPage(tester, 'home');
    await tester.pump(const Duration(milliseconds: 300));
    _requestAudioPage(tester, 'subtitleLibrary');
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.element(find.byType(SubtitleLibraryScreen)),
      same(libraryElement),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced motion switches Audio pages, modes, and sources immediately',
    (tester) async {
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      for (final (index, page) in [
        (1, 'onlineMarks'),
        (2, 'history'),
        (0, 'home'),
      ]) {
        _requestAudioPage(tester, page);
        await tester.pump();
        expect(_pages(tester).page, index.toDouble());
      }
      _requestAudioPage(tester, 'popular');
      await tester.pump();
      expect(_pages(tester).page, 0);
      expect(_library(tester).title, 'Popular');
      expect(find.byType(RawImage), findsNothing);

      _requestAudioSource(tester, audio_source.AudioSource.jpAsmr);
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AudioScreen)),
      );
      expect(
        container.read(audioSourceProvider),
        audio_source.AudioSource.jpAsmr,
      );
      expect(container.read(worksProvider).displayMode, DisplayMode.all);
      expect(_pages(tester).page, 0);
      expect(_library(tester).title, 'Home');
      expect(find.byType(RawImage), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Audio page selection finishes when reduced motion turns on', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    (container.read(historyProvider.notifier) as _History).populate();

    _requestAudioPage(tester, 'history');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_pages(tester).page, lessThan(2));
    expect(find.text('History 0'), findsNothing);

    reduced.value = true;
    await tester.pump();
    expect(_pages(tester).page, 2);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_pages(tester).page, 2);
    expect(find.text('History 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'work modes slide in semantic order and restore their scroll positions',
    (tester) async {
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AudioScreen)),
      );
      (container.read(worksProvider.notifier) as _Works)
          .useDistinctModeTitles();
      await tester.pumpAndSettle();
      final worksState = tester.state(find.byType(WorksScreen));

      _worksScroll(tester).jumpTo(300);
      await tester.pumpAndSettle();
      expect(_worksScroll(tester).offset, 300);

      _requestAudioPage(tester, 'popular');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(RawImage), findsOneWidget);
      expect(_outgoingAudioTransition(tester).translation.dx, lessThan(0));
      expect(find.text('popular 0'), findsOneWidget);
      expect(_library(tester).title, 'Popular');
      expect(tester.state(find.byType(WorksScreen)), same(worksState));
      expect(_worksScroll(tester).offset, 0);
      await tester.pumpAndSettle();
      expect(find.byType(RawImage), findsNothing);

      _worksScroll(tester).jumpTo(240);
      await tester.pumpAndSettle();
      _requestAudioPage(tester, 'recommended');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_outgoingAudioTransition(tester).translation.dx, lessThan(0));
      expect(find.text('recommended 0'), findsOneWidget);
      await tester.pumpAndSettle();

      _requestAudioPage(tester, 'popular');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_outgoingAudioTransition(tester).translation.dx, greaterThan(0));
      await tester.pumpAndSettle();
      expect(_worksScroll(tester).offset, 240);

      _requestAudioPage(tester, 'home');
      await tester.pumpAndSettle();
      expect(_worksScroll(tester).offset, 300);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rapid work-mode changes keep the last selection', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);

    _requestAudioPage(tester, 'popular');
    _requestAudioPage(tester, 'recommended');
    _requestAudioPage(tester, 'home');
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    expect(container.read(worksProvider).displayMode, DisplayMode.all);
    expect(_library(tester).title, 'Home');
    expect(_pages(tester).page, 0);
    expect(find.byType(RawImage), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsNothing);

    container.read(worksProvider.notifier).setDisplayMode(DisplayMode.popular);
    await tester.pump();
    expect(_library(tester).title, 'Popular');
    expect(find.byType(RawImage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_outgoingAudioTransition(tester).translation.dx, lessThan(0));
    await tester.pumpAndSettle();
    expect(_library(tester).title, 'Popular');
    expect(tester.takeException(), isNull);
  });

  testWidgets('source changes slide to home from works and collection pages', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);

    _requestAudioPage(tester, 'popular');
    await tester.pumpAndSettle();
    _requestAudioSource(tester, audio_source.AudioSource.jpAsmr);
    await tester.pump();
    expect(_pages(tester).page, 0);
    expect(_library(tester).title, 'Home');
    expect(find.byType(RawImage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_outgoingAudioTransition(tester).translation.dx, lessThan(0));
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsNothing);

    _requestAudioSource(tester, audio_source.AudioSource.jpAsmr);
    await tester.pump();
    expect(find.byType(RawImage), findsNothing);

    _requestAudioPage(tester, 'history');
    await tester.pumpAndSettle();
    _requestAudioSource(tester, audio_source.AudioSource.asmrOne);
    await tester.pump();
    expect(_pages(tester).page, 0);
    expect(_library(tester).title, 'Home');
    expect(find.byType(RawImage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_outgoingAudioTransition(tester).translation.dx, greaterThan(0));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    expect(
      container.read(audioSourceProvider),
      audio_source.AudioSource.asmrOne,
    );
    expect(container.read(worksProvider).displayMode, DisplayMode.all);
    expect(_library(tester).title, 'Home');
    expect(tester.takeException(), isNull);
  });

  testWidgets('current Audio source returns to Home with a slide', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    _requestAudioPage(tester, 'popular');
    await tester.pumpAndSettle();
    _requestAudioSource(tester, audio_source.AudioSource.asmrOne);
    await tester.pump();
    expect(_library(tester).title, 'Home');
    expect(find.byType(RawImage), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_outgoingAudioTransition(tester).translation.dx, greaterThan(0));
    await tester.pumpAndSettle();

    _requestAudioPage(tester, 'history');
    await tester.pumpAndSettle();
    _requestAudioSource(tester, audio_source.AudioSource.asmrOne);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_pages(tester).page, inExclusiveRange(0, 2));
    expect(_library(tester).title, 'Home');
    expect(find.byType(RawImage), findsNothing);
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'first library visits expose management and open subtitle search',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('my_tabs_show_subtitle_library', true);
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced, settle: false);
      await tester.pump(const Duration(milliseconds: 300));
      final s = S.of(tester.element(find.byType(AudioScreen)));
      _requestAudioPage(tester, 'downloads');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(_browseTile(tester, s.select).onTap, isNotNull);
      expect(_browseTile(tester, s.sortOptions).onTap, isNotNull);

      _requestAudioPage(tester, 'subtitleLibrary');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(_browseTile(tester, s.importSubtitle).onTap, isNotNull);
      await tester.tap(find.byKey(const ValueKey('library-page-search')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SubtitleLibraryScreen && widget.searchPage,
        ),
        findsOneWidget,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reordering pages preserves history state and search scope', (
    tester,
  ) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    _requestAudioPage(tester, 'history');
    await tester.pumpAndSettle();
    final history = tester.state(find.byType(HistoryScreen));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    await container.read(myTabsDisplayProvider.notifier).setPageOrder([
      'history',
      ...MyTabsDisplaySettings.defaultPageOrder.where(
        (page) => page != 'history',
      ),
    ]);
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 1);
    expect(_library(tester).title, 'History');
    expect(tester.state(find.byType(HistoryScreen)), same(history));

    await tester.tap(find.byKey(const ValueKey('library-page-search')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(
      tester.widget<SearchScreen>(find.byType(SearchScreen)).scope,
      SearchScope.history,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('hiding the current page preserves the works mode title', (
    tester,
  ) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    _requestAudioPage(tester, 'popular');
    await tester.pumpAndSettle();
    _requestAudioPage(tester, 'onlineMarks');
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    await container
        .read(myTabsDisplayProvider.notifier)
        .setShowOnlineMarks(false);
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 0);
    expect(container.read(worksProvider).displayMode, DisplayMode.popular);
    expect(_library(tester).title, 'Popular');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home entry returns to the feed and footer opens audio settings',
    (tester) async {
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced);
      _requestAudioPage(tester, 'history');
      await tester.pumpAndSettle();
      final s = S.of(tester.element(find.byType(AudioScreen)));
      final home =
          _section(tester, s.libraryPages).children.first as LibraryDrawerTile;
      expect(home.title, s.navHome);
      home.onTap!();
      await tester.pumpAndSettle();
      expect(_pages(tester).page, 0);
      expect(_library(tester).title, s.navHome);
      final settings = _library(tester).drawerFooter! as LibraryDrawerTile;
      expect(settings.title, s.audioSettings);
      settings.onTap!();
      await tester.pumpAndSettle();
      expect(
        tester.widget<SettingsScreen>(find.byType(SettingsScreen)).audioOnly,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('online search returns to the selected Audio tab', (
    tester,
  ) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);

    expect(_pages(tester).page, 0);
    expect(_library(tester).title, 'Home');

    _requestAudioPage(tester, 'history');
    await tester.pumpAndSettle();
    final history = tester.state(find.byType(HistoryScreen));
    _advancedSearch(tester);
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(
      tester.widget<SearchScreen>(find.byType(SearchScreen)).scope,
      SearchScope.history,
    );
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(_pages(tester).page!.round(), 2);
    expect(tester.state(find.byType(HistoryScreen)), same(history));
  });

  testWidgets('sidebar pages slide and ignore horizontal dragging', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    _requestAudioPage(tester, 'onlineMarks');
    await tester.pump();
    expect(_pages(tester).page, lessThan(1));
    expect(_library(tester).title, 'Marks');
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 1);
    await tester.drag(
      find.byKey(const ValueKey('audio-tab-pages')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 1);
    _requestAudioPage(tester, 'home');
    await tester.pump();
    expect(_pages(tester).page, greaterThan(0));
    expect(_library(tester).title, 'Home');
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 0);
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
    _requestAudioPage(tester, 'onlineMarks');
    await tester.pumpAndSettle();
    _advancedSearch(tester);
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
      _requestAudioPage(tester, 'history');
      await tester.pumpAndSettle();
      await container
          .read(myTabsDisplayProvider.notifier)
          .setShowOnlineMarks(false);
      await tester.pumpAndSettle();
      expect(_pages(tester).page!.round(), 1);
      expect(find.byType(HistoryScreen), findsOneWidget);
      await container
          .read(myTabsDisplayProvider.notifier)
          .setShowOnlineMarks(true);
      await tester.pumpAndSettle();
      _requestAudioPage(tester, 'onlineMarks');
      await tester.pumpAndSettle();
      await container
          .read(myTabsDisplayProvider.notifier)
          .setShowOnlineMarks(false);
      await tester.pumpAndSettle();
      expect(_pages(tester).page!.round(), 0);
      expect(find.byType(WorksScreen), findsOneWidget);
    },
  );

  testWidgets('sidebar automatic translation shares the saved preference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AutoTranslateWorkDetailsNotifier.preferenceKey, true);
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    final s = S.of(tester.element(find.byType(AudioScreen)));
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    final drawer = find.byKey(const ValueKey('library-drawer'));
    final translation = find.descendant(
      of: drawer,
      matching: find.text(s.autoTranslateWorkDetails),
    );
    await tester.scrollUntilVisible(
      translation,
      200,
      scrollable: find
          .descendant(of: drawer, matching: find.byType(Scrollable))
          .first,
    );
    await tester.ensureVisible(translation);
    await tester.pumpAndSettle();
    final toggle = find.descendant(of: drawer, matching: find.byType(Switch));
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(translation);
    await tester.pumpAndSettle();
    expect(container.read(autoTranslateWorkDetailsProvider), isFalse);
    expect(
      prefs.getBool(AutoTranslateWorkDetailsNotifier.preferenceKey),
      isFalse,
    );
    expect(Scaffold.of(tester.element(translation)).isDrawerOpen, isTrue);

    await container
        .read(autoTranslateWorkDetailsProvider.notifier)
        .setEnabled(true);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(container.read(autoTranslateWorkDetailsProvider), isFalse);
    expect(
      prefs.getBool(AutoTranslateWorkDetailsNotifier.preferenceKey),
      isFalse,
    );

    _requestAudioPage(tester, 'history');
    await tester.pumpAndSettle();
    expect(
      (_browseTile(tester, s.autoTranslateWorkDetails).trailing as Switch)
          .value,
      isFalse,
    );
    _requestAudioSource(tester, audio_source.AudioSource.jpAsmr);
    await tester.pumpAndSettle();
    expect(
      (_browseTile(tester, s.autoTranslateWorkDetails).trailing as Switch)
          .value,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline home and marks controls keep preferences independent', (
    tester,
  ) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final s = S.of(tester.element(find.byType(AudioScreen)));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    expect(
      _section(
        tester,
        s.libraryBrowseOptions,
      ).children.whereType<LibraryDrawerTile>().map((tile) => tile.title),
      [s.block, s.autoTranslateWorkDetails],
    );
    expect(
      _audioPageTile(
        tester,
        'home',
      ).children.whereType<LibraryDrawerTile>().map((tile) => tile.title),
      contains(s.layout),
    );
    final reviewLayout = container.read(myReviewsProvider).layoutType;
    final homeLayout = container.read(worksProvider).layoutType;
    _browseTile(tester, 'Layout').onTap!();
    await tester.pumpAndSettle();
    expect(container.read(worksProvider).layoutType, LayoutType.bigGrid);
    expect(container.read(myReviewsProvider).layoutType, reviewLayout);
    expect(container.read(worksProvider).layoutType, isNot(homeLayout));
    _browseTile(tester, 'Subtitle filter').onTap!();
    await tester.pumpAndSettle();
    final homeSubtitleFilter = container.read(worksProvider).subtitleFilter;
    expect(homeSubtitleFilter, isNot(0));
    expect(_browseTile(tester, s.sort).onTap, isNotNull);

    for (final page in ['popular', 'recommended']) {
      _requestAudioPage(tester, page);
      await tester.pumpAndSettle();
      final options = _audioPageTile(
        tester,
        page,
      ).children.whereType<LibraryDrawerTile>().map((tile) => tile.title);
      expect(options, isNot(contains(s.sort)));
      expect(options, contains(s.layout));
      expect(options, contains(s.subtitleFilter));
    }

    _requestAudioPage(tester, 'onlineMarks');
    await tester.pumpAndSettle();
    expect(_audioPageTile(tester, 'home').children, isEmpty);
    expect(
      _section(tester, s.libraryPages).children
          .whereType<LibraryDrawerTile>()
          .where((tile) => tile.children.isNotEmpty)
          .map((tile) => tile.title),
      [s.libraryMarks],
    );
    final markedLabel = MyReviewFilter.marked.localizedLabel(
      tester.element(find.byType(AudioScreen)),
    );
    expect(
      _audioPageTile(
        tester,
        'onlineMarks',
      ).children.whereType<LibraryDrawerTile>().map((tile) => tile.title),
      contains(markedLabel),
    );
    final workLayout = container.read(worksProvider).layoutType;
    final workSubtitleFilter = container.read(worksProvider).subtitleFilter;
    _browseTile(tester, 'Layout').onTap!();
    await tester.pumpAndSettle();
    expect(container.read(myReviewsProvider).layoutType, isNot(reviewLayout));
    expect(container.read(worksProvider).layoutType, workLayout);
    _browseTile(tester, 'Subtitle filter').onTap!();
    await tester.pumpAndSettle();
    expect(container.read(myReviewsProvider).subtitleFilter, isNot(0));
    expect(container.read(worksProvider).subtitleFilter, workSubtitleFilter);
    expect(container.read(worksProvider).subtitleFilter, homeSubtitleFilter);
    final menu = find.byKey(const ValueKey('library-menu-button'));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final drawer = find.byKey(const ValueKey('library-drawer'));
    final marked = find.descendant(
      of: drawer,
      matching: find.text(markedLabel),
    );
    await tester.scrollUntilVisible(
      marked,
      250,
      scrollable: find
          .descendant(of: drawer, matching: find.byType(Scrollable))
          .first,
    );
    await tester.tap(marked);
    await tester.pumpAndSettle();
    expect(Scaffold.of(tester.element(menu)).isDrawerOpen, isTrue);
    expect(container.read(myReviewsProvider).filter, MyReviewFilter.marked);
  });

  testWidgets('playlist options stay under the selected Audio page', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('my_tabs_show_playlists', true);
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(
      tester,
      reduced,
      screen: ProviderScope(
        overrides: [
          playlistsProvider.overrideWith(
            (ref) => PlaylistsNotifier(_EmptyPlaylistsApi()),
          ),
        ],
        child: const AudioScreen(),
      ),
    );
    final s = S.of(tester.element(find.byType(AudioScreen)));

    _requestAudioPage(tester, 'playlists');
    await tester.pumpAndSettle();

    final menu = find.byKey(const ValueKey('library-menu-button'));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final drawer = find.byKey(const ValueKey('library-drawer'));
    final favoritesTile = find.descendant(
      of: drawer,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is LibraryDrawerTile && widget.title == s.libraryFavorites,
      ),
    );
    final createPlaylist = find.descendant(
      of: drawer,
      matching: find.text(s.createPlaylist),
    );
    expect(
      find.descendant(of: favoritesTile, matching: find.text(s.createPlaylist)),
      findsOneWidget,
    );
    final browseOptions = find.descendant(
      of: drawer,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is LibraryDrawerSection &&
            widget.title == s.libraryBrowseOptions,
      ),
    );
    expect(
      find.descendant(of: browseOptions, matching: find.text(s.createPlaylist)),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      createPlaylist,
      250,
      scrollable: find
          .descendant(of: drawer, matching: find.byType(Scrollable))
          .first,
    );
    await tester.tap(createPlaylist);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.text(s.cancel));
    await tester.pumpAndSettle();
  });

  for (final withTrack in [false, true]) {
    testWidgets(
      'app Dock remains visible above detail routes (track=$withTrack)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final reduced = ValueNotifier(true);
        addTearDown(reduced.dispose);
        await _pumpAudioScreen(
          tester,
          reduced,
          screen: const MainScreen(),
          track: withTrack
              ? const AudioTrack(
                  id: 'detail-dock-track',
                  title: 'Audio',
                  url: 'https://example.invalid/audio.mp3',
                )
              : null,
        );

        _pushGlobalAudioDetail(
          tester.element(find.byType(WorksScreen)),
          'Browsing detail',
        );
        await tester.pumpAndSettle();

        expect(find.text('Browsing detail'), findsOneWidget);
        expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
        expect(
          find.byType(MiniPlayer, skipOffstage: false),
          withTrack ? findsOneWidget : findsNothing,
        );
        tester.view.physicalSize = const Size(844, 390);
        await tester.pumpAndSettle();
        expect(find.text('Browsing detail'), findsOneWidget);
        expect(find.byType(NavigationRail).hitTestable(), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        expect(find.text('Browsing detail'), findsOneWidget);
        expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'top-level tab changes return to each home and retain audio scroll state',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced, screen: const MainScreen());

      final works = find.byType(WorksScreen);
      final audioState = tester.state(find.byType(AudioScreen));
      final worksState = tester.state(works);
      final scroll = tester
          .widget<CustomScrollView>(
            find.descendant(of: works, matching: find.byType(CustomScrollView)),
          )
          .controller!;
      scroll.jumpTo(400);
      await tester.pumpAndSettle();
      final audioContext = tester.element(works);
      _pushGlobalAudioDetail(audioContext, 'Audio detail');
      await tester.pumpAndSettle();

      final navigation = find.byType(NavigationBar);
      expect(navigation.hitTestable(), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: navigation,
          matching: find.byIcon(Icons.menu_book_outlined),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationBar>(navigation).selectedIndex, 1);
      expect(find.text('Audio detail'), findsNothing);
      expect(find.byType(ComicScreen), findsOneWidget);

      final comicContext = tester.element(find.byType(ComicScreen));
      _pushGlobalAudioDetail(comicContext, 'Comic detail');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: navigation,
          matching: find.byIcon(Icons.settings_outlined),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationBar>(navigation).selectedIndex, 3);
      expect(find.text('Comic detail'), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: navigation,
          matching: find.byIcon(Icons.library_music_outlined),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationBar>(navigation).selectedIndex, 0);
      expect(find.text('Audio detail'), findsNothing);
      expect(find.text('Comic detail'), findsNothing);
      expect(tester.state(find.byType(AudioScreen)), same(audioState));
      expect(tester.state(find.byType(WorksScreen)), same(worksState));
      expect(scroll.offset, 400);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'landscape NavigationRail remains selected after a tab detail returns',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced, screen: const MainScreen());

      final navigation = find.byType(NavigationRail);
      final settingsLabel = S
          .of(tester.element(find.byType(MainScreen)))
          .navSettings;
      await tester.tap(
        find.descendant(
          of: navigation,
          matching: find.byIcon(Icons.settings_outlined),
        ),
      );
      await tester.pumpAndSettle();
      final settingsContext = tester.element(find.byType(SettingsScreen));
      _pushGlobalAudioDetail(settingsContext, 'Landscape detail');
      await tester.pumpAndSettle();

      expect(find.text('Landscape detail'), findsOneWidget);
      expect(navigation.hitTestable(), findsOneWidget);
      expect(tester.widget<NavigationRail>(navigation).selectedIndex, 3);
      Navigator.of(settingsContext).pop();
      await tester.pumpAndSettle();
      expect(navigation.hitTestable(), findsOneWidget);
      expect(tester.widget<NavigationRail>(navigation).selectedIndex, 3);
      expect(
        find.descendant(of: navigation, matching: find.text(settingsLabel)),
        findsOneWidget,
      );
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('full audio player hides the Dock and restores it on return', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(
      tester,
      reduced,
      screen: const MainScreen(),
      track: const AudioTrack(
        id: 'full-player-dock-track',
        title: 'Audio',
        url: 'https://example.invalid/audio.mp3',
      ),
    );

    expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('mini-player-upward-launcher')),
      ),
    );
    await gesture.moveBy(const Offset(0, -400));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(AudioPlayerScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(
      find.byType(NavigationBar, skipOffstage: false).hitTestable(),
      findsNothing,
    );
    expect(
      find.byType(NavigationRail, skipOffstage: false).hitTestable(),
      findsNothing,
    );

    final playerContext = tester.element(find.byType(AudioPlayerScreen));
    _pushGlobalAudioDetail(playerContext, 'Player work detail');
    await tester.pumpAndSettle();
    expect(find.text('Player work detail'), findsOneWidget);
    expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
    expect(find.byType(MiniPlayer, skipOffstage: false), findsOneWidget);
    Navigator.of(playerContext).pop();
    await tester.pumpAndSettle();
    expect(find.byType(AudioPlayerScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    unawaited(
      showDialog<void>(
        context: playerContext,
        builder: (_) => const AlertDialog(content: Text('Player modal')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets(
      'Mini Player preview cancel and fast handoff preserve navigation at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final reduced = ValueNotifier(false);
        addTearDown(reduced.dispose);
        await _pumpAudioScreen(
          tester,
          reduced,
          screen: const MainScreen(),
          track: AudioTrack(
            id: 'interactive-player-dock-track-$size',
            title: 'Audio',
            url: 'https://example.invalid/audio.mp3',
          ),
        );

        final landscape = size.width > size.height;
        final dock = find.byType(AppBottomDock, skipOffstage: false);
        final rail = find.byType(NavigationRail, skipOffstage: false);
        final navigation = landscape ? rail : dock;
        final mini = find.byType(MiniPlayer, skipOffstage: false);
        final launcher = find.byKey(
          const ValueKey('mini-player-upward-launcher'),
        );
        final initialNavigationRect = tester.getRect(navigation);
        final initialMiniRect = tester.getRect(mini);
        final miniState = tester.state(mini);

        final cancelledGesture = await tester.startGesture(
          tester.getCenter(launcher),
        );
        await cancelledGesture.moveBy(const Offset(0, -120));
        await tester.pump();
        await tester.pump();
        expect(
          find.byType(AudioPlayerScreen, skipOffstage: false),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 240));
        expect(navigation, findsOneWidget);
        expect(tester.state(mini), same(miniState));
        if (landscape) {
          expect(tester.getRect(rail).right, lessThanOrEqualTo(0));
          expect(tester.getTopLeft(mini).dy, greaterThan(initialMiniRect.top));
        } else {
          expect(tester.getTopLeft(dock).dy, closeTo(size.height, 0.01));
        }
        expect(mini.hitTestable(), findsNothing);

        await cancelledGesture.cancel();
        await tester.pumpAndSettle();
        expect(navigation.hitTestable(), findsOneWidget);
        expect(launcher.hitTestable(), findsOneWidget);
        final restoredNavigationRect = tester.getRect(navigation);
        expect(
          restoredNavigationRect.left,
          closeTo(initialNavigationRect.left, 0.01),
        );
        expect(
          restoredNavigationRect.top,
          closeTo(initialNavigationRect.top, 0.01),
        );
        expect(
          restoredNavigationRect.size.width,
          closeTo(initialNavigationRect.width, 0.01),
        );
        expect(
          restoredNavigationRect.size.height,
          closeTo(initialNavigationRect.height, 0.01),
        );
        final restoredMiniRect = tester.getRect(mini);
        expect(restoredMiniRect.left, closeTo(initialMiniRect.left, 0.01));
        expect(restoredMiniRect.top, closeTo(initialMiniRect.top, 0.01));
        expect(
          restoredMiniRect.size.width,
          closeTo(initialMiniRect.width, 0.01),
        );
        expect(
          restoredMiniRect.size.height,
          closeTo(initialMiniRect.height, 0.01),
        );
        expect(tester.state(mini), same(miniState));

        final gesture = await tester.startGesture(tester.getCenter(launcher));
        await gesture.moveBy(const Offset(0, -600));
        await tester.pump();
        await tester.pump();
        await tester.pump();
        final preview = find.byType(AudioPlayerScreen, skipOffstage: false);
        final previewState = tester.state(preview);
        expect(
          (ModalRoute.of(tester.element(preview))!
                  as AudioPlayerPageRoute<void>)
              .skipInitialTransition,
          isFalse,
        );

        await gesture.up();
        var handedOff = false;
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final player = find.byType(AudioPlayerScreen, skipOffstage: false);
          if (player.evaluate().isEmpty) continue;
          final route = ModalRoute.of(tester.element(player));
          if (route is! AudioPlayerPageRoute<void> ||
              !route.skipInitialTransition) {
            continue;
          }
          expect(tester.state(player), same(previewState));
          expect(
            tester
                .widget<Transform>(
                  find.byKey(
                    const ValueKey('player-route-vertical-translation'),
                    skipOffstage: false,
                  ),
                )
                .transform
                .entry(1, 3),
            closeTo(0, 0.01),
          );
          expect(dock, findsNothing);
          expect(rail, findsNothing);
          handedOff = true;
          break;
        }
        expect(handedOff, isTrue);
        await tester.pumpAndSettle();
        expect(find.byType(AudioPlayerScreen), findsOneWidget);
        expect(dock, findsNothing);
        expect(rail, findsNothing);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(AudioPlayerScreen), findsNothing);
        expect(navigation.hitTestable(), findsOneWidget);
        expect(launcher.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'interactive preview aborts cleanly when its Mini Player changes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      final tracks = StreamController<AudioTrack?>();
      addTearDown(tracks.close);
      const firstTrack = AudioTrack(
        id: 'preview-track-first',
        title: 'First track',
        url: 'https://example.invalid/first.mp3',
      );
      const secondTrack = AudioTrack(
        id: 'preview-track-second',
        title: 'Second track',
        url: 'https://example.invalid/second.mp3',
      );
      await _pumpAudioScreen(
        tester,
        reduced,
        screen: const MainScreen(),
        track: firstTrack,
        currentTrackStream: tracks.stream,
      );
      tracks.add(firstTrack);
      await tester.pumpAndSettle();

      final launcher = find.byKey(
        const ValueKey('mini-player-upward-launcher'),
      );
      final gesture = await tester.startGesture(tester.getCenter(launcher));
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      await tester.pump();
      expect(
        find.byType(AudioPlayerScreen, skipOffstage: false),
        findsOneWidget,
      );

      tracks.add(secondTrack);
      await tester.pumpAndSettle();
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(find.byType(AudioPlayerScreen, skipOffstage: false), findsNothing);
      expect(find.text('Second track'), findsOneWidget);
      expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      final removingGesture = await tester.startGesture(
        tester.getCenter(launcher),
      );
      await removingGesture.moveBy(const Offset(0, -120));
      await tester.pump();
      await tester.pump();
      expect(
        find.byType(AudioPlayerScreen, skipOffstage: false),
        findsOneWidget,
      );

      tracks.add(null);
      await tester.pumpAndSettle();
      await removingGesture.cancel();
      await tester.pumpAndSettle();
      expect(find.byType(AudioPlayerScreen, skipOffstage: false), findsNothing);
      expect(find.byType(MiniPlayer, skipOffstage: false), findsNothing);
      expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail tab switch keeps Dock usable during the longer player close',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(
        tester,
        reduced,
        screen: const MainScreen(),
        theme: AppTheme.lightTheme(null),
        track: const AudioTrack(
          id: 'player-close-dock-track',
          title: 'Audio',
          url: 'https://example.invalid/audio.mp3',
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('mini-player-upward-launcher')),
      );
      await tester.pumpAndSettle();
      final playerContext = tester.element(find.byType(AudioPlayerScreen));
      _pushGlobalAudioDetail(playerContext, 'Player work detail');
      await tester.pumpAndSettle();

      final navigation = find.byType(NavigationBar);
      await tester.tap(
        find.descendant(
          of: navigation,
          matching: find.byIcon(Icons.settings_outlined),
        ),
      );
      await tester.pump();
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        expect(navigation.hitTestable(), findsOneWidget);
        expect(tester.widget<NavigationBar>(navigation).selectedIndex, 3);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('modal routes block Dock tab changes until dismissed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced, screen: const MainScreen());

    final navigation = find.byType(NavigationBar);
    final settings = find.descendant(
      of: navigation,
      matching: find.byIcon(Icons.settings_outlined),
    );
    final settingsCenter = tester.getCenter(settings);
    final mainContext = tester.element(find.byType(MainScreen));
    unawaited(
      showDialog<void>(
        context: mainContext,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: const Text('Dock blocking modal'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close modal'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Dock blocking modal'), findsOneWidget);
    expect(navigation.hitTestable(), findsNothing);
    await tester.tapAt(settingsCenter);
    await tester.pumpAndSettle();
    expect(find.text('Dock blocking modal'), findsOneWidget);
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 0);

    await tester.tap(find.text('Close modal'));
    await tester.pumpAndSettle();
    expect(navigation.hitTestable(), findsOneWidget);
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a modal cannot dismiss the detail beneath it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced, screen: const MainScreen());
    _pushGlobalAudioDetail(
      tester.element(find.byType(WorksScreen)),
      'Retained detail',
    );
    await tester.pumpAndSettle();

    final detailContext = tester.element(find.text('Retained detail'));
    final navigation = find.byType(NavigationBar);
    final dockPoint = tester.getCenter(
      find.descendant(
        of: navigation,
        matching: find.byIcon(Icons.settings_outlined),
      ),
    );
    unawaited(
      showDialog<void>(
        context: detailContext,
        builder: (_) => const AlertDialog(content: Text('Dismissible modal')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tapAt(dockPoint);
    await tester.pump();
    expect(AppNavigationScope.of(detailContext).popupRoute?.isCurrent, isFalse);
    await tester.tapAt(dockPoint);
    await tester.pumpAndSettle();

    expect(find.text('Dismissible modal'), findsNothing);
    expect(find.text('Retained detail'), findsOneWidget);
    expect(navigation.hitTestable(), findsOneWidget);
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('modal routes hide the hovered global volume slider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(
      tester,
      reduced,
      screen: const MainScreen(),
      track: const AudioTrack(
        id: 'volume-modal-track',
        title: 'Audio',
        url: 'https://example.invalid/audio.mp3',
      ),
    );

    final volumeControl = find.byType(VolumeControl);
    final volumeCenter = tester.getCenter(volumeControl);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: volumeCenter);
    await mouse.moveTo(volumeCenter);
    await tester.pump();
    final slider = find.descendant(
      of: find.byType(CompositedTransformFollower),
      matching: find.byType(Slider),
    );
    expect(slider.hitTestable(), findsOneWidget);
    await mouse.moveTo(tester.getCenter(slider));
    await tester.pump();

    final mainContext = tester.element(find.byType(MainScreen));
    unawaited(
      showDialog<void>(
        context: mainContext,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: const Text('Volume modal'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close modal'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Volume modal'), findsOneWidget);
    expect(slider, findsNothing);
    expect(slider.hitTestable(), findsNothing);
    await tester.tap(find.text('Close modal'));
    await tester.pumpAndSettle();
    final navigation = find.byType(NavigationBar);
    expect(navigation.hitTestable(), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: navigation,
        matching: find.byIcon(Icons.settings_outlined),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 3);

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 101));
    expect(tester.takeException(), isNull);
  });

  for (final reducedMotion in [false, true]) {
    for (final size in [const Size(390, 844), const Size(1000, 600)]) {
      testWidgets(
        'main navigation animates or snaps and retains state ($size, reduced=$reducedMotion)',
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
          final settingsCards = find.descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(SettingsSectionList),
          );
          if (reducedMotion) {
            expect(
              tester.getRect(find.byType(SettingsScreen)).left,
              closeTo(start.left, .1),
            );
          }
          expect(settingsCards, reducedMotion ? findsWidgets : findsNothing);
          final pages = tester
              .widget<PageView>(find.byKey(const ValueKey('main-tab-pages')))
              .controller!;
          if (reducedMotion) {
            expect(pages.page, 3);
          } else {
            expect(pages.page, inExclusiveRange(0, 3));
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
          expect(
            tester.state(find.byType(SettingsScreen, skipOffstage: false)),
            same(settingsState),
          );
          await tester.pumpAndSettle();
          expect(settingsCards, findsWidgets);
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
          4,
        );
      } else {
        expect(
          tester
              .widget<NavigationBar>(navigation)
              .destinations
              .map((item) => (item as NavigationDestination).label),
          ['Audio', 'Comics', 'Videos', 'Settings'],
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
      _advancedSearch(tester);
      await tester.pumpAndSettle();
      expect(find.byType(GlobalAudioPlayerWrapper), findsOneWidget);
      expect(navigation.hitTestable(), findsOneWidget);
      expect(
        size.width > size.height
            ? find.byType(NavigationBar)
            : find.byType(NavigationRail),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(scroll.offset, offset);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      _requestAudioPage(tester, 'history');
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
      expect(_pages(tester).page!.round(), 2);
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

  testWidgets('audio destinations slide in and retain visited content', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    (container.read(historyProvider.notifier) as _History).populate();
    (container.read(myReviewsProvider.notifier) as _Reviews).populate();
    _requestAudioPage(tester, 'history');
    await tester.pump();
    expect(_pages(tester).page, lessThan(2));
    expect(_library(tester).title, 'History');
    expect(find.text('History 0'), findsNothing);
    expect(find.text('Marked 0', skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 2);
    expect(find.text('History 0'), findsOneWidget);
    final history = tester.state(find.byType(HistoryScreen));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_pages(tester).page, 2);
    _requestAudioPage(tester, 'onlineMarks');
    await tester.pump();
    expect(_pages(tester).page, greaterThan(1));
    await tester.pumpAndSettle();
    expect(find.text('Marked 0'), findsOneWidget);
    _requestAudioPage(tester, 'history');
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 2);
    expect(tester.state(find.byType(HistoryScreen)), same(history));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid sidebar selections only build the final new page', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AudioScreen)),
    );
    (container.read(historyProvider.notifier) as _History).populate();
    (container.read(myReviewsProvider.notifier) as _Reviews).populate();
    _requestAudioPage(tester, 'onlineMarks');
    _requestAudioPage(tester, 'history');
    await tester.pump();
    expect(_pages(tester).page, lessThan(2));
    expect(_library(tester).title, 'History');
    expect(find.text('History 0'), findsNothing);
    expect(find.text('Marked 0', skipOffstage: false), findsNothing);
    await tester.pumpAndSettle();
    expect(_pages(tester).page, 2);
    expect(find.text('History 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('distant Audio selections only initialize the chosen library', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('my_tabs_show_playlists', true);
    await prefs.setBool('my_tabs_show_subtitle_library', true);
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await _pumpAudioScreen(tester, reduced);
    _requestAudioPage(tester, 'subtitleLibrary');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(SubtitleLibraryScreen), findsOneWidget);
    expect(find.byType(HistoryScreen, skipOffstage: false), findsNothing);
    expect(find.byType(PlaylistsScreen, skipOffstage: false), findsNothing);
    expect(
      find.byType(LocalDownloadsScreen, skipOffstage: false),
      findsNothing,
    );
    final library = tester.state(find.byType(SubtitleLibraryScreen));
    _requestAudioPage(tester, 'home');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    _requestAudioPage(tester, 'subtitleLibrary');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(tester.state(find.byType(SubtitleLibraryScreen)), same(library));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final size in [const Size(390, 844), const Size(1000, 600)]) {
    testWidgets('main destinations slide and keep lazy state ($size)', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await _pumpAudioScreen(tester, reduced, screen: const MainScreen());
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MainScreen)),
      );
      expect(container.exists(videoClientProvider), isFalse);
      expect(container.exists(videoLibraryProvider), isFalse);
      expect(container.exists(videoDownloadsProvider), isFalse);
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
      select(3);
      await tester.pump();
      expect(pages.page, lessThan(3));
      expect(find.byType(SettingsSectionList), findsNothing);
      expect(find.byType(ComicScreen, skipOffstage: false), findsNothing);
      expect(find.byType(VideoScreen, skipOffstage: false), findsNothing);
      await tester.pumpAndSettle();
      expect(pages.page, 3);
      expect(find.byType(SettingsSectionList), findsWidgets);
      await tester.drag(pagesFinder, const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(pages.page, 3);
      select(0);
      await tester.pump();
      expect(pages.page, greaterThan(0));
      await tester.pumpAndSettle();
      expect(pages.page, 0);
      expect(tester.state(find.byType(AudioScreen)), same(audioState));
      expect(container.exists(videoClientProvider), isFalse);
      expect(container.exists(videoLibraryProvider), isFalse);
      expect(container.exists(videoDownloadsProvider), isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}

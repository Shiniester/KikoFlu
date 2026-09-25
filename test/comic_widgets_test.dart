import 'package:kikoeru_flutter/src/comics/comic_downloads.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_widgets.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/metadata_search_chip.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/comic_source.dart';
import 'package:kikoeru_flutter/src/comics/comic_http.dart';
import 'package:kikoeru_flutter/src/comics/comic_library.dart';
import 'package:kikoeru_flutter/src/comics/comic_providers.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_detail_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_reader_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_search_screen.dart';

const _comic = Comic(
  source: 'fixture',
  id: 'book',
  title: 'Fixture book',
  cover: 'fixture-cover',
  tags: ['Fixture tag'],
  chapters: [
    ComicChapter('one', 'Chapter 1'),
    ComicChapter('two', 'Chapter 2'),
  ],
);

class _Source extends ComicSource {
  _Source([this.sourceKey = 'fixture']) : super(ComicHttp(sourceKey));
  final String sourceKey;
  bool loggedIn = false, favoriteFails = false;
  int searches = 0, favoriteWrites = 0;
  @override
  bool get isLoggedIn => loggedIn;
  @override
  Future<void> setFavorite(Comic comic, bool value) async {
    favoriteWrites++;
    if (favoriteFails) throw const ComicSourceException('favorite rejected');
  }

  bool fail = false;
  String? failedChapter;
  @override
  String get key => sourceKey;
  @override
  String get name => sourceKey == 'fixture' ? 'Fixture' : 'Other';
  @override
  String get website => 'https://fixture.invalid';
  @override
  Future<ComicResult> search(
    String query, {
    String? cursor,
    String? sort,
  }) async {
    searches++;
    if (fail) throw const ComicSourceException('fixture error');
    return ComicResult([
      key == 'fixture'
          ? _comic
          : Comic(source: key, id: 'book', title: 'Other book'),
    ]);
  }

  @override
  Future<Comic> details(String id) async => _comic;
  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async {
    if (chapter.id == failedChapter) {
      throw const ComicSourceException('Chapter unavailable');
    }
    return List.generate(8, (i) => ComicPage('page-$i'));
  }
}

class _Library extends ComicLibrary {
  final List<Map<String, dynamic>> savedTasks = [];
  @override
  Future<void> saveTask(String id, Map<String, dynamic> task) async {}
  @override
  Future<void> deleteTask(String id) async {}

  ComicProgress? last;
  int favoriteWrites = 0;
  @override
  Future<void> favorite(Comic comic, bool value) async {
    favoriteWrites++;
  }

  @override
  Future<List<Map<String, dynamic>>> loadTasks() async => savedTasks;
  @override
  Future<List<Comic>> favorites() async => [];
  @override
  Future<List<ComicProgress>> history() async => last == null ? [] : [last!];
  @override
  Future<ComicProgress?> progress(Comic comic) async => last;
  @override
  Future<void> saveProgress(Comic comic, String chapter, int page) async {
    last = ComicProgress(comic, chapter, page, DateTime.now());
  }
}

final _png = Uint8List.fromList(
  img.encodePng(img.Image(width: 100, height: 160)),
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'comic_grid': false,
      'comic_selected_source': 'fixture',
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });
  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget child,
    _Library library,
    _Source source, {
    _Source? other,
    AudioTrack? track,
    Future<Uint8List> Function(ComicPage)? loadImage,
  }) async {
    final container = ProviderContainer(
      overrides: [
        comicSourcesProvider.overrideWithValue([
          source,
          if (other != null) other,
        ]),
        comicLibraryProvider.overrideWith((ref) => library),
        currentTrackProvider.overrideWith((ref) => Stream.value(track)),
        isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        playerStateProvider.overrideWith(
          (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
        ),
        queueProvider.overrideWith(
          (ref) => Stream.value([if (track != null) track]),
        ),
        manualSkipAvailabilityProvider.overrideWith(
          (ref) => Stream.value(ManualSkipAvailability.unavailable),
        ),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
        comicImageLoaderProvider.overrideWithValue(
          (source, page) => loadImage?.call(page) ?? Future.value(_png),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(source.http.dispose);
    if (other != null) addTearDown(other.http.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('reader controls do not resize comic pages', (tester) async {
    await StorageService.setString('comic_reading_mode', 'vertical');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          tester.view.physicalSize = call.arguments == 'SystemUiMode.edgeToEdge'
              ? const Size(390, 796)
              : const Size(390, 844);
          tester.view.padding = call.arguments == 'SystemUiMode.edgeToEdge'
              ? const FakeViewPadding(top: 24, bottom: 24)
              : const FakeViewPadding();
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(
      tester,
      const ComicReaderScreen(
        comic: _comic,
        chapter: ComicChapter('one', 'Chapter 1'),
      ),
      _Library(),
      _Source(),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    final before = tester.getRect(find.byType(FutureBuilder<Uint8List>).first);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect(tester.getRect(find.byType(FutureBuilder<Uint8List>).first), before);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  testWidgets(
    'returning to earlier pages preserves their height while reloading',
    (tester) async {
      await StorageService.setString('comic_reading_mode', 'continuous');
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final reload = Completer<Uint8List>();
      final requests = <String, int>{};
      await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('one', 'Chapter 1'),
        ),
        _Library(),
        _Source(),
        loadImage: (page) {
          final count = requests.update(
            page.url,
            (v) => v + 1,
            ifAbsent: () => 1,
          );
          return page.url == 'page-0' && count > 1
              ? reload.future
              : Future.value(_png);
        },
      );
      final firstHeight = tester.getSize(find.byType(Image).first).height;
      final controller = tester
          .widget<ScrollablePositionedList>(
            find.byType(ScrollablePositionedList),
          )
          .itemScrollController!;
      controller.jumpTo(index: 6);
      await tester.pumpAndSettle();
      controller.jumpTo(index: 0);
      await tester.pump();
      await tester.pump();
      expect(
        tester.getSize(find.byType(FutureBuilder<Uint8List>).first).height,
        closeTo(firstHeight, .1),
      );
      reload.complete(_png);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('comic download entry disappears when the last task is removed', (
    tester,
  ) async {
    final library = _Library();
    final task = ComicDownloadTask(
      comic: _comic,
      chapter: _comic.chapters.first,
      directory: '',
      status: ComicDownloadStatus.paused,
    );
    library.savedTasks.add(task.toJson());
    final container = await pump(
      tester,
      const ComicScreen(),
      library,
      _Source(),
    );
    expect(find.byTooltip('Download Tasks'), findsOneWidget);
    final downloads = container.read(comicDownloadsProvider);
    await downloads.remove(downloads.tasks.single);
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  for (final size in [const Size(320, 640), const Size(1000, 600)]) {
    testWidgets('comic details keep toolbar actions and shared tags at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(
        tester,
        const ComicDetailScreen(comic: _comic),
        _Library(),
        _Source(),
      );
      final appBar = find.byType(AppBar);
      expect(
        find.descendant(of: appBar, matching: find.byTooltip('Download')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: appBar, matching: find.byTooltip('Favorites')),
        findsOneWidget,
      );
      final download = tester.getCenter(find.byTooltip('Download'));
      final favorite = tester.getCenter(find.byTooltip('Favorites'));
      expect(download.dx, lessThan(favorite.dx));
      expect(download.dy, favorite.dy);
      expect(find.byType(MetadataSearchChip), findsOneWidget);
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'comic detail route hands off both dock parts and restores them on return',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(
        tester,
        AppBottomDockTransitionScope(
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => openComic(context, _comic),
                  child: const Text('Open comic'),
                ),
              ),
            ),
            bottomNavigationBar: AppBottomDock(
              selectedIndex: 1,
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
                NavigationDestination(
                  icon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            ),
          ),
        ),
        _Library(),
        _Source(),
        track: const AudioTrack(
          id: 'dock-track',
          title: 'Audio',
          url: 'https://example.invalid/audio.mp3',
        ),
      );
      final sourceRect = tester.getRect(find.byType(MiniPlayer));
      await tester.tap(find.text('Open comic'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(appBottomDockMiniPlayerFlightRootKey), findsOneWidget);
      expect(find.byKey(appBottomDockTabBarFlightRootKey), findsOneWidget);
      expect(
        tester.getRect(find.byKey(appBottomDockMiniPlayerFlightRootKey)).top,
        greaterThan(sourceRect.top),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ComicDetailScreen), findsOneWidget);
      expect(find.byType(MiniPlayer), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(appBottomDockMiniPlayerFlightRootKey), findsOneWidget);
      expect(find.byKey(appBottomDockTabBarFlightRootKey), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(MiniPlayer)), sourceRect);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'aggregate retry preserves successful sources and supports both layouts',
    (tester) async {
      final source = _Source();
      final other = _Source('other')..fail = true;
      await pump(
        tester,
        const ComicSearchScreen(
          initialSource: 'fixture',
          initialQuery: 'query',
        ),
        _Library(),
        source,
        other: other,
      );
      await tester.tap(find.text('Grouped results'));
      await tester.pumpAndSettle();
      expect(find.text('Fixture book'), findsOneWidget);
      final successfulCalls = source.searches;
      other.fail = false;
      await tester.ensureVisible(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(source.searches, successfulCalls);
      expect(find.text('Other book'), findsOneWidget);
      await tester.tap(find.text('Merged results'));
      await tester.pumpAndSettle();
      expect(find.text('Fixture book'), findsOneWidget);
      expect(find.text('Other book'), findsOneWidget);
    },
  );
  testWidgets(
    'source favorite failure never silently writes a local favorite',
    (tester) async {
      final source = _Source()
        ..loggedIn = true
        ..favoriteFails = true;
      final library = _Library();
      await pump(
        tester,
        const ComicDetailScreen(comic: _comic),
        library,
        source,
      );
      await tester.tap(find.byTooltip('Favorites'));
      await tester.pumpAndSettle();
      expect(source.favoriteWrites, 1);
      expect(library.favoriteWrites, 0);
      source.favoriteFails = false;
      await tester.tap(find.byTooltip('Favorites'));
      await tester.pumpAndSettle();
      expect(source.favoriteWrites, 2);
      expect(library.favoriteWrites, 0);
      await tester.tap(find.text('Save locally'));
      await tester.pumpAndSettle();
      expect(library.favoriteWrites, 1);
      source.loggedIn = false;
      await tester.tap(find.byTooltip('Favorites'));
      await tester.pumpAndSettle();
      expect(library.favoriteWrites, 2);
    },
  );
  testWidgets('comic tabs preserve home content after switching to history', (
    tester,
  ) async {
    await pump(tester, const ComicScreen(), _Library(), _Source());
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('Fixture book'), findsOneWidget);
    await tester.tap(find.text('History').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home').first);
    await tester.pumpAndSettle();
    expect(find.text('Fixture book'), findsOneWidget);
  });
  testWidgets(
    'reader changes mode without losing the real page and saves on exit',
    (tester) async {
      final library = _Library();
      final container = await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('one', 'Chapter 1'),
          initialPage: 5,
        ),
        library,
        _Source(),
      );
      await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('6/8'), findsOneWidget);
      for (final mode in ComicReadingMode.values.where(
        (m) => m != ComicReadingMode.continuous,
      )) {
        container.read(comicReadingModeProvider.notifier).state = mode;
        await tester.pumpAndSettle();
        expect(find.text('6/8'), findsOneWidget, reason: mode.name);
      }
      container.read(comicReadingModeProvider.notifier).state =
          ComicReadingMode.continuous;
      await tester.pumpAndSettle();
      expect(library.last?.chapterId, 'one');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(library.last?.page, greaterThanOrEqualTo(4));
    },
  );
  testWidgets(
    'failed chapter transition preserves the last readable chapter progress',
    (tester) async {
      final library = _Library();
      await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('one', 'Chapter 1'),
          initialPage: 5,
        ),
        library,
        _Source()..failedChapter = 'two',
      );
      await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next chapter'));
      await tester.pumpAndSettle();
      expect(find.text('Chapter unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(library.last?.chapterId, 'one');
      expect(library.last?.page, 5);
    },
  );
  testWidgets(
    'reader has one Mini Player and retains progress after the full player closes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = _Library();
      await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('one', 'Chapter 1'),
          initialPage: 3,
        ),
        library,
        _Source(),
        track: const AudioTrack(
          id: 'reader-track',
          title: 'Audio',
          url: 'https://example.invalid/audio.mp3',
        ),
      );
      await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(find.text('4/8'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mini-player-artwork-frame')));
      await tester.pumpAndSettle();
      expect(find.byType(AudioPlayerScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(AudioPlayerScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(find.text('4/8'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(library.last?.page, 3);
    },
  );
  testWidgets('search failure stays in the search page and can retry', (
    tester,
  ) async {
    final source = _Source()..fail = true;
    await pump(
      tester,
      const ComicSearchScreen(initialSource: 'fixture', initialQuery: 'test'),
      _Library(),
      source,
    );
    expect(find.text('fixture error'), findsOneWidget);
    source.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Fixture book'), findsOneWidget);
  });
}

import 'package:kikoeru_flutter/src/comics/comic_downloads.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_widgets.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/metadata_search_chip.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_title_header.dart';
import 'package:kikoeru_flutter/src/services/log_service.dart';
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
import 'package:kikoeru_flutter/src/providers/settings_provider.dart'
    show pageSizeProvider;
import 'package:kikoeru_flutter/src/providers/works_provider.dart'
    show LayoutType;
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/comic_source.dart';
import 'package:kikoeru_flutter/src/comics/comic_http.dart';
import 'package:kikoeru_flutter/src/comics/comic_library.dart';
import 'package:kikoeru_flutter/src/comics/comic_providers.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_settings_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_detail_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_reader_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_search_screen.dart';
import 'package:kikoeru_flutter/src/widgets/pagination_bar.dart';

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
  bool commentsEnabled = false;
  int searches = 0, favoriteWrites = 0;
  int detailRequests = 0, chapterRequests = 0;
  final searchGates = <int, Completer<ComicResult>>{};
  Completer<Comic>? detailGate;
  Completer<List<ComicChapter>>? chapterGate;
  bool detailFails = false, chaptersFail = false;
  @override
  bool get isLoggedIn => loggedIn;
  @override
  bool get hasComments => commentsEnabled;
  @override
  Future<List<ComicComment>> comments(Comic comic) async => const [
    ComicComment('Reader', 'Existing comment'),
  ];
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
    final gate = searchGates.remove(searches);
    if (gate != null) return gate.future;
    return ComicResult([
      key == 'fixture'
          ? _comic
          : Comic(source: key, id: 'book', title: 'Other book'),
    ]);
  }

  @override
  Future<Comic> details(String id) async {
    detailRequests++;
    if (detailFails) throw const ComicSourceException('detail unavailable');
    return detailGate?.future ?? _comic;
  }

  @override
  Future<List<ComicChapter>> chapters(Comic comic) async {
    chapterRequests++;
    if (chaptersFail) throw const ComicSourceException('chapters unavailable');
    return chapterGate?.future ?? comic.chapters;
  }

  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async {
    if (chapter.id == failedChapter) {
      throw const ComicSourceException('Chapter unavailable');
    }
    return List.generate(8, (i) => ComicPage('page-$i'));
  }
}

class _PaginatedSource extends _Source {
  _PaginatedSource(this.firstPage, this.secondPage);

  final List<Comic> firstPage;
  final List<Comic> secondPage;
  final cursors = <String?>[];

  @override
  Future<ComicResult> explore({String? cursor}) async {
    cursors.add(cursor);
    return cursor == null
        ? ComicResult(firstPage, next: 'second-page')
        : ComicResult(secondPage);
  }
}

class _Library extends ComicLibrary {
  final List<Map<String, dynamic>> savedTasks = [];
  Comic? lastFavorite;
  @override
  Future<void> saveTask(String id, Map<String, dynamic> task) async {}
  @override
  Future<void> deleteTask(String id) async {}

  ComicProgress? last;
  int favoriteWrites = 0;
  @override
  Future<void> favorite(Comic comic, bool value) async {
    favoriteWrites++;
    lastFavorite = comic;
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
final _widePng = Uint8List.fromList(
  img.encodePng(img.Image(width: 180, height: 100)),
);
final _tallPng = Uint8List.fromList(
  img.encodePng(img.Image(width: 100, height: 220)),
);

void expectVisibleComicCoverRatio(WidgetTester tester, double ratio) {
  final images = find.descendant(
    of: find.byType(ComicImage),
    matching: find.byType(Image),
  );
  expect(images, findsWidgets);
  for (var i = 0; i < images.evaluate().length; i++) {
    final rect = tester.getRect(images.at(i));
    expect(rect.width / rect.height, closeTo(ratio, 0.001));
  }
}

void expectComicCoverFlightRadius() {
  expect(
    find.byWidgetPredicate((widget) {
      if (widget is! ClipRRect || widget.borderRadius is! BorderRadius) {
        return false;
      }
      final radius = (widget.borderRadius as BorderRadius).topLeft.x;
      return radius > workCoverCompactRadius && radius < workCoverDetailRadius;
    }),
    findsWidgets,
  );
}

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
    bool settle = true,
    bool reduceMotion = false,
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          locale: const Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: child,
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
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
    'reader waits for its route transition before changing system bars',
    (tester) async {
      tester.view.physicalSize = const Size(390, 796);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
            final immersive = call.arguments == 'SystemUiMode.immersiveSticky';
            tester.binding.addPostFrameCallback((_) {
              tester.view.physicalSize = const Size(390, 796);
              tester.view.padding = immersive
                  ? const FakeViewPadding()
                  : const FakeViewPadding(top: 24, bottom: 24);
            });
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
        const ComicDetailScreen(comic: _comic),
        _Library(),
        _Source(),
      );

      final detail = find.byType(ComicDetailScreen, skipOffstage: false);
      final detailSize = MediaQuery.sizeOf(tester.element(detail));
      final detailPadding = MediaQuery.paddingOf(tester.element(detail));
      final detailScaffold = find.descendant(
        of: detail,
        matching: find.byType(Scaffold),
      );
      Size detailBodySize() => tester
          .renderObject(
            find.descendant(
              of: detail,
              matching: find.byType(SingleChildScrollView),
            ),
          )
          .paintBounds
          .size;
      Rect coverInDetailBody() {
        final body =
            tester.renderObject(
                  find.descendant(
                    of: detail,
                    matching: find.byType(SingleChildScrollView),
                  ),
                )
                as RenderBox;
        final cover =
            tester.renderObject(
                  find.byKey(const ValueKey('comic-detail-cover')),
                )
                as RenderBox;
        return cover.localToGlobal(Offset.zero, ancestor: body) & cover.size;
      }

      Rect coverInDetailScaffold() {
        final scaffold = tester.renderObject(detailScaffold.first) as RenderBox;
        final cover =
            tester.renderObject(
                  find.byKey(const ValueKey('comic-detail-cover')),
                )
                as RenderBox;
        return cover.localToGlobal(Offset.zero, ancestor: scaffold) &
            cover.size;
      }

      final coverRect = coverInDetailBody();
      final scaffoldCoverRect = coverInDetailScaffold();
      final bodySize = detailBodySize();
      await tester.tap(find.text('Continue reading'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();

      final reader = find.byType(ComicReaderScreen);
      expect(reader, findsOneWidget);
      final route = ModalRoute.of(tester.element(reader))!;
      expect(route.animation!.value, lessThan(1));
      expect(detailBodySize(), bodySize);
      expect(coverInDetailBody(), coverRect);
      expect(coverInDetailScaffold(), scaffoldCoverRect);
      expect(MediaQuery.sizeOf(tester.element(detail)), detailSize);
      expect(MediaQuery.paddingOf(tester.element(detail)), detailPadding);
      await tester.pumpAndSettle();
      expect(MediaQuery.paddingOf(tester.element(detail)), EdgeInsets.zero);
      Navigator.of(tester.element(reader)).pop();
      await tester.pumpAndSettle();
      expect(MediaQuery.paddingOf(tester.element(detail)), detailPadding);
      expect(coverInDetailScaffold(), scaffoldCoverRect);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reader applies system bars with reduced route motion', (
    tester,
  ) async {
    final modes = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          modes.add(call.arguments);
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
      const ComicDetailScreen(comic: _comic),
      _Library(),
      _Source(),
      reduceMotion: true,
    );
    await tester.tap(find.text('Continue reading'));
    await tester.pumpAndSettle();

    final reader = find.byType(ComicReaderScreen);
    expect(reader, findsOneWidget);
    expect(
      ModalRoute.of(tester.element(reader))!.animation!.status,
      AnimationStatus.completed,
    );
    expect(modes, contains('SystemUiMode.immersiveSticky'));
    Navigator.of(tester.element(reader)).pop();
    await tester.pumpAndSettle();
    expect(modes, contains('SystemUiMode.edgeToEdge'));
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

  testWidgets('resuming mid-chapter does not abruptly resize an earlier page', (
    tester,
  ) async {
    await StorageService.setString('comic_reading_mode', 'continuous');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final earlierPage = Completer<Uint8List>();
    var earlierRequested = false;
    await pump(
      tester,
      const ComicReaderScreen(
        comic: _comic,
        chapter: ComicChapter('one', 'Chapter 1'),
        initialPage: 5,
      ),
      _Library(),
      _Source(),
      settle: false,
      loadImage: (page) {
        if (page.url == 'page-4') {
          earlierRequested = true;
          return earlierPage.future;
        }
        return Future.value(_png);
      },
    );
    expect(earlierRequested, isTrue);
    final controller = tester
        .widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList))
        .itemScrollController!;
    controller.jumpTo(index: 4);
    await tester.pump();
    final pageFinder = find.byKey(const ValueKey('comic-page-size-4'));
    final pendingHeight = tester.getSize(pageFinder).height;
    earlierPage.complete(
      Uint8List.fromList(img.encodePng(img.Image(width: 100, height: 300))),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final firstFrameHeight = tester.getSize(pageFinder).height;
    expect(firstFrameHeight, lessThan(pendingHeight + 150));
    await tester.pumpAndSettle();
    expect(tester.getSize(pageFinder).height, closeTo(1170, 1));
  });

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

  testWidgets('comic layout toolbar cycles and persists all three layouts', (
    tester,
  ) async {
    await StorageService.setBool('comic_grid', true);
    final container = await pump(
      tester,
      const ComicScreen(),
      _Library(),
      _Source(),
    );
    final layoutButton = find.byTooltip('Layout');
    expect(container.read(comicLayoutProvider), LayoutType.bigGrid);

    await tester.tap(layoutButton);
    await tester.pumpAndSettle();
    expect(container.read(comicLayoutProvider), LayoutType.smallGrid);
    expect(find.byIcon(Icons.grid_on), findsOneWidget);

    await tester.tap(layoutButton);
    await tester.pumpAndSettle();
    expect(container.read(comicLayoutProvider), LayoutType.list);
    expect(find.byIcon(Icons.view_list), findsOneWidget);

    await tester.tap(layoutButton);
    await tester.pumpAndSettle();
    expect(container.read(comicLayoutProvider), LayoutType.bigGrid);
    await tester.pump();
    expect(StorageService.getString('comic_layout_type'), 'bigGrid');
  });

  testWidgets('comic settings selects the shared small-grid preference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = await pump(
      tester,
      const ComicSettingsScreen(),
      _Library(),
      _Source(),
    );

    await tester.tap(find.text('Layout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Small grid'));
    await tester.pumpAndSettle();

    expect(container.read(comicLayoutProvider), LayoutType.smallGrid);
    expect(StorageService.getString('comic_layout_type'), 'smallGrid');
    expect(find.text('Small grid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('comic layout preference restores and migrates legacy values', () async {
    final legacyList = ProviderContainer();
    addTearDown(legacyList.dispose);
    expect(legacyList.read(comicLayoutProvider), LayoutType.list);

    await StorageService.setBool('comic_grid', true);
    final legacyGrid = ProviderContainer();
    addTearDown(legacyGrid.dispose);
    expect(legacyGrid.read(comicLayoutProvider), LayoutType.bigGrid);

    await StorageService.setString(
      'comic_layout_type',
      LayoutType.smallGrid.name,
    );
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(restored.read(comicLayoutProvider), LayoutType.smallGrid);
  });

  test(
    'comic page size defaults to 40 and persists independently of audio',
    () async {
      final audio = ProviderContainer();
      addTearDown(audio.dispose);
      await audio.read(pageSizeProvider.notifier).updatePageSize(20);
      final initial = ProviderContainer();
      addTearDown(initial.dispose);
      expect(initial.read(comicPageSizeProvider), 40);
      initial.read(comicPageSizeProvider.notifier).setPageSize(60);
      await Future<void>.delayed(Duration.zero);

      final restored = ProviderContainer();
      addTearDown(restored.dispose);
      expect(restored.read(comicPageSizeProvider), 60);

      expect(audio.read(pageSizeProvider), 20);
    },
  );

  testWidgets('comic settings change the collection page size', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = await pump(
      tester,
      const ComicSettingsScreen(),
      _Library(),
      _Source(),
    );
    final pageSize = find.text('Items Per Page');
    await tester.ensureVisible(pageSize);
    await tester.tap(pageSize);
    await tester.pumpAndSettle();
    await tester.tap(find.text('60').last);
    await tester.pumpAndSettle();

    expect(container.read(comicPageSizeProvider), 60);
    expect(find.text('60 items per page'), findsOneWidget);
  });

  testWidgets('unknown comic total keeps paging without a jump action', (
    tester,
  ) async {
    var previousCalls = 0;
    await pump(
      tester,
      Scaffold(
        body: PaginationBar(
          currentPage: 2,
          pageSize: 40,
          totalCount: null,
          hasMore: true,
          isLoading: false,
          onPreviousPage: () => previousCalls++,
          onNextPage: () {},
        ),
      ),
      _Library(),
      _Source(),
    );

    expect(find.text('2'), findsOneWidget);
    expect(find.byIcon(Icons.edit_location_alt), findsNothing);
    await tester.tap(find.text('Previous'));
    expect(previousCalls, 1);
  });

  for (final layout in [LayoutType.bigGrid, LayoutType.smallGrid]) {
    testWidgets(
      'ComicScreen keeps covers stable during fast down and reverse scroll in $layout',
      (tester) async {
        await StorageService.setString('comic_layout_type', layout.name);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final firstPage = List.generate(
          48,
          (i) => Comic(
            source: 'fixture',
            id: 'first-$i',
            title: 'First $i',
            cover: 'first-cover-$i',
          ),
        );
        final secondPage = List.generate(
          24,
          (i) => Comic(
            source: 'fixture',
            id: 'second-$i',
            title: 'Second $i',
            cover: 'second-cover-$i',
          ),
        );
        final source = _PaginatedSource(firstPage, secondPage);
        final firstCoverReload = Completer<Uint8List>();
        final firstCoverReloadStarted = Completer<void>();
        var firstCoverRequests = 0;
        await pump(
          tester,
          const ComicScreen(),
          _Library(),
          source,
          loadImage: (page) {
            if (page.url == 'first-cover-0') {
              firstCoverRequests++;
              if (firstCoverRequests > 1) {
                if (!firstCoverReloadStarted.isCompleted) {
                  firstCoverReloadStarted.complete();
                }
                return firstCoverReload.future;
              }
            }
            return Future.value(_png);
          },
          settle: false,
        );
        await tester.pumpAndSettle();
        final firstCard = find
            .ancestor(of: find.text('First 0'), matching: find.byType(Card))
            .first;
        final firstCardRect = tester.getRect(firstCard);
        final firstCardContentTop = firstCardRect.top;
        final firstCardLeft = firstCardRect.left;
        final anchorTitle = layout == LayoutType.smallGrid
            ? 'First 3'
            : 'First 2';
        final anchor = find
            .ancestor(of: find.text(anchorTitle), matching: find.byType(Card))
            .first;
        final anchorRect = tester.getRect(anchor);
        final anchorContentTop = anchorRect.top;
        final anchorLeft = anchorRect.left;

        final grid = find.byType(ComicGrid);
        final scrollable = find.descendant(
          of: grid,
          matching: find.byType(Scrollable),
        );
        expect(scrollable, findsOneWidget);
        final position = tester.state<ScrollableState>(scrollable).position;
        await tester.fling(scrollable, const Offset(0, -1800), 12000);
        await tester.pumpAndSettle();
        expect(position.pixels, greaterThan(1000));
        expect(source.cursors, [null]);

        final reverseGesture = await tester.startGesture(
          tester.getCenter(scrollable),
        );
        final offsets = <double>[position.pixels];
        final anchorContentTops = <double>[];
        final anchorLefts = <double>[];
        var reloadFrames = 0;
        var anchorWasObserved = false;
        void recordAnchor() {
          final currentAnchor = find.ancestor(
            of: find.text(anchorTitle),
            matching: find.byType(Card),
          );
          if (currentAnchor.evaluate().isEmpty) return;
          anchorWasObserved = true;
          final rect = tester.getRect(currentAnchor.first);
          anchorContentTops.add(rect.top + position.pixels);
          anchorLefts.add(rect.left);
        }

        for (var frame = 0; frame < 180; frame++) {
          if (position.pixels > 0) {
            await reverseGesture.moveBy(const Offset(0, 64));
          }
          await tester.pump(const Duration(milliseconds: 16));
          offsets.add(position.pixels);
          recordAnchor();
          if (firstCoverReloadStarted.isCompleted &&
              !firstCoverReload.isCompleted) {
            reloadFrames++;
            if (reloadFrames == 6) firstCoverReload.complete(_png);
          }
        }
        await reverseGesture.up();
        while (firstCoverReloadStarted.isCompleted &&
            !firstCoverReload.isCompleted &&
            reloadFrames < 6) {
          await tester.pump(const Duration(milliseconds: 16));
          offsets.add(position.pixels);
          recordAnchor();
          reloadFrames++;
        }
        if (!firstCoverReload.isCompleted) firstCoverReload.complete(_png);
        await tester.pump();
        recordAnchor();
        await tester.pumpAndSettle();

        expect(firstCoverReloadStarted.isCompleted, isTrue);
        expect(anchorWasObserved, isTrue);
        expect(offsets, isNotEmpty);
        for (var i = 1; i < offsets.length; i++) {
          expect(offsets[i], lessThanOrEqualTo(offsets[i - 1] + 0.5));
        }
        expect(anchorContentTops, isNotEmpty);
        for (final top in anchorContentTops) {
          expect(top, closeTo(anchorContentTop, 3));
        }
        for (final left in anchorLefts) {
          expect(left, closeTo(anchorLeft, 1));
        }
        final restoredCard = tester.getRect(firstCard);
        expect(restoredCard.top, closeTo(firstCardContentTop, 3));
        expect(restoredCard.left, closeTo(firstCardLeft, 1));
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(source.cursors, [null, 'second-page']);
        await tester.tap(find.text('Previous'));
        await tester.pumpAndSettle();
        expect(source.cursors, [null, 'second-page']);
        expect(find.text('First 0'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('changing comic page size returns the collection to page one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _PaginatedSource(
      List.generate(
        48,
        (i) => Comic(
          source: 'fixture',
          id: 'size-first-$i',
          title: 'Size first $i',
          cover: 'size-first-cover-$i',
        ),
      ),
      List.generate(
        24,
        (i) => Comic(
          source: 'fixture',
          id: 'size-second-$i',
          title: 'Size second $i',
          cover: 'size-second-cover-$i',
        ),
      ),
    );
    final container = await pump(
      tester,
      const ComicScreen(),
      _Library(),
      source,
    );

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    final pagination = find.byType(PaginationBar);
    expect(
      find.descendant(of: pagination, matching: find.text('2')),
      findsOneWidget,
    );
    expect(source.cursors, [null, 'second-page']);

    final grid = find.byType(ComicGrid);
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.maxScrollExtent.clamp(1, 300));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));

    container.read(comicPageSizeProvider.notifier).setPageSize(20);
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: pagination, matching: find.text('1')),
      findsOneWidget,
    );
    expect(find.text('Size first 0'), findsOneWidget);
    expect(source.cursors, [null, 'second-page', null]);
    expect(position.pixels, closeTo(0, 0.1));
  });

  testWidgets(
    'comic grid cards hug covers and grow with existing title content',
    (tester) async {
      await StorageService.setBool('comic_grid', true);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const longTitle = Comic(
        source: 'fixture',
        id: 'long',
        title: 'A deliberately long comic title that wraps over several lines',
        cover: 'second-cover',
      );
      await pump(
        tester,
        const Scaffold(body: ComicGrid(comics: [_comic, longTitle])),
        _Library(),
        _Source(),
      );
      final cards = find.byType(Card);
      expect(cards, findsNWidgets(2));
      final first = tester.getRect(cards.at(0));
      final second = tester.getRect(cards.at(1));
      expect(first.width, second.width);
      expect(second.height, greaterThan(first.height));
      final cover = tester.getRect(find.byType(ComicImage).first);
      expect((cover.top - first.top).abs(), lessThan(1));
      expect((cover.left - first.left).abs(), lessThan(1));
      expect(
        tester.widget<ComicImage>(find.byType(ComicImage).first).fit,
        BoxFit.contain,
      );
      expect(cover.width / cover.height, closeTo(100 / 160, 0.001));
      expect(find.text('Fixture tag'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('comic list card keeps its rounded cover inside the card', (
    tester,
  ) async {
    await StorageService.setBool('comic_grid', false);
    await pump(
      tester,
      const Scaffold(body: ComicGrid(comics: [_comic])),
      _Library(),
      _Source(),
    );
    final card = tester.getRect(find.byType(Card));
    final cover = tester.getRect(find.byType(ComicImage));
    expect(cover.width, 80);
    expect(cover.height, 128);
    expect(
      tester.widget<ComicImage>(find.byType(ComicImage)).fit,
      BoxFit.contain,
    );
    expect(card.contains(cover.topLeft), isTrue);
    expect(card.contains(cover.bottomRight), isTrue);
    final clip = tester.widget<ClipRRect>(
      find
          .ancestor(
            of: find.byType(ComicImage),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(clip.borderRadius, BorderRadius.circular(workCoverCompactRadius));
    final title = tester.getRect(find.text('Fixture book'));
    final tag = tester.getRect(find.text('Fixture tag'));
    expect(tag.top, greaterThanOrEqualTo(title.bottom + 6));
    final chip = tester.widget<MetadataSearchChip>(
      find.ancestor(
        of: find.text('Fixture tag'),
        matching: find.byType(MetadataSearchChip),
      ),
    );
    expect(chip.fontSize, 13);
    expect(chip.borderRadius, 6);
    expect(
      chip.padding,
      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('big comic cards show only a real source date inside the cover', (
    tester,
  ) async {
    await StorageService.setBool('comic_grid', true);
    const dated = Comic(
      source: 'fixture',
      id: 'dated',
      title: 'Dated book',
      cover: 'dated-cover',
      extra: {'sourceDate': '2024-05-12T09:30:00Z'},
    );
    const invalid = Comic(
      source: 'fixture',
      id: 'invalid',
      title: 'Invalid date',
      cover: 'invalid-cover',
      extra: {'sourceDate': 'unknown'},
    );
    final container = await pump(
      tester,
      const Scaffold(body: ComicGrid(comics: [dated, invalid, _comic])),
      _Library(),
      _Source(),
    );
    expect(find.text('2024-05-12'), findsOneWidget);
    final badgeFinder = find
        .ancestor(of: find.text('2024-05-12'), matching: find.byType(Container))
        .first;
    final badge = tester.getRect(badgeFinder);
    final decoration =
        tester.widget<Container>(badgeFinder).decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(4));
    expect(decoration.color, Colors.black.withValues(alpha: 0.7));
    final cover = tester.getRect(find.byType(ComicImage).first);
    expect(badge.right, closeTo(cover.right - 6, 0.1));
    expect(badge.bottom, closeTo(cover.bottom - 6, 0.1));
    expect(badge.right, greaterThan(cover.center.dx));
    expect(find.text('unknown'), findsNothing);
    expect(find.text('Fixture tag'), findsNothing);
    container.read(comicLayoutProvider.notifier).set(LayoutType.list);
    await tester.pumpAndSettle();
    expect(find.text('2024-05-12'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final (
        size,
        gridWidth,
        gridInset,
        gridGap,
        listInset,
        gridFont,
        listFont,
      )
      in [
        (const Size(320, 640), 304.0, 8.0, 8.0, 24.0, 12.0, 14.0),
        (const Size(390, 844), 183.0, 8.0, 8.0, 24.0, 12.0, 14.0),
        (const Size(1000, 600), 904 / 3, 24.0, 24.0, 40.0, 14.5, 16.0),
      ]) {
    testWidgets('comic cards match Audio spacing and title at $size', (
      tester,
    ) async {
      await StorageService.setBool('comic_grid', true);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const second = Comic(
        source: 'fixture',
        id: 'second',
        title: 'Second book',
        cover: 'second-cover',
      );
      final container = await pump(
        tester,
        const Scaffold(body: ComicGrid(comics: [_comic, second])),
        _Library(),
        _Source(),
        loadImage: (_) async => _widePng,
      );
      final cards = find.byType(Card);
      final first = tester.getRect(cards.at(0));
      final next = tester.getRect(cards.at(1));
      expect(first.left, closeTo(gridInset, 0.1));
      expect(first.width, closeTo(gridWidth, 0.1));
      if (size.width == 320) {
        expect(next.top - first.bottom, closeTo(gridGap, 0.1));
      } else {
        expect(next.left - first.right, closeTo(gridGap, 0.1));
      }
      final gridTitle = tester.widget<Text>(find.text('Fixture book'));
      expect(gridTitle.style?.fontSize, gridFont);
      expect(gridTitle.style?.fontWeight, FontWeight.bold);
      expect(
        gridTitle.style?.letterSpacing,
        Theme.of(
          tester.element(find.text('Fixture book')),
        ).textTheme.titleSmall?.letterSpacing,
      );
      expect(find.text('fixture'), findsNothing);

      container.read(comicLayoutProvider.notifier).set(LayoutType.smallGrid);
      await tester.pumpAndSettle();
      final smallGridCards = find.byType(Card);
      final smallGridFirst = tester.getRect(smallGridCards.at(0));
      final smallGridNext = tester.getRect(smallGridCards.at(1));
      final smallGridInset = size.width > size.height ? 24.0 : 8.0;
      final smallGridGap = smallGridInset;
      final smallGridColumns = size.width > size.height ? 5 : 3;
      final smallGridCardWidth =
          (size.width -
              smallGridInset * 2 -
              smallGridGap * (smallGridColumns - 1)) /
          smallGridColumns;
      expect(smallGridFirst.left, closeTo(smallGridInset, 0.1));
      expect(smallGridFirst.width, closeTo(smallGridCardWidth, 0.1));
      expect(
        smallGridNext.left - smallGridFirst.right,
        closeTo(smallGridGap, 0.1),
      );
      final smallGridTitle = tester.widget<Text>(find.text('Fixture book'));
      expect(
        smallGridTitle.style?.fontSize,
        size.width > size.height ? 13.5 : 11,
      );
      expect(smallGridTitle.style?.fontWeight, FontWeight.bold);

      container.read(comicLayoutProvider.notifier).set(LayoutType.list);
      await tester.pumpAndSettle();
      final listCards = find.byType(Card);
      final listFirst = tester.getRect(
        find
            .descendant(of: listCards.at(0), matching: find.byType(InkWell))
            .first,
      );
      final listNext = tester.getRect(
        find
            .descendant(of: listCards.at(1), matching: find.byType(InkWell))
            .first,
      );
      expect(listFirst.left, closeTo(listInset, 0.1));
      expect(listFirst.right, closeTo(size.width - listInset, 0.1));
      expect(listNext.top - listFirst.bottom, closeTo(16, 0.1));
      final listTitle = tester.widget<Text>(find.text('Fixture book'));
      expect(listTitle.style?.fontSize, listFont);
      expect(listTitle.style?.fontWeight, FontWeight.bold);
      expect(listTitle.style?.letterSpacing, gridTitle.style?.letterSpacing);
      expect(find.text('fixture'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final layout in LayoutType.values) {
    for (final (label, bytes, ratio) in [
      ('wide', _widePng, 180 / 100),
      ('tall', _tallPng, 100 / 220),
    ]) {
      testWidgets('$label comic cover uses its real ratio in $layout layout', (
        tester,
      ) async {
        await StorageService.setString('comic_layout_type', layout.name);
        await pump(
          tester,
          const Scaffold(body: ComicGrid(comics: [_comic])),
          _Library(),
          _Source(),
          loadImage: (_) async => bytes,
        );
        final frame = tester.getRect(find.byType(WorkCoverHeroFrame));
        final image = tester.getRect(find.byType(ComicImage));
        expect(frame, image);
        expect(frame.width / frame.height, closeTo(ratio, 0.001));
        expect(
          tester.widget<ComicImage>(find.byType(ComicImage)).fit,
          BoxFit.contain,
        );
        final clip = tester.widget<ClipRRect>(
          find
              .ancestor(
                of: find.byType(ComicImage),
                matching: find.byType(ClipRRect),
              )
              .first,
        );
        expect(
          clip.borderRadius,
          BorderRadius.circular(workCoverCompactRadius),
        );
        if (layout != LayoutType.list) {
          final card = tester.getRect(find.byType(Card));
          expect((frame.left - card.left).abs(), lessThan(1));
          expect((frame.right - card.right).abs(), lessThan(1));
          expect(card.height, greaterThan(frame.height));
          expect(card.bottom, greaterThan(frame.bottom));
        } else {
          expect(frame.width, 80);
          expect(
            tester.getRect(find.byType(Card)).bottom,
            greaterThan(frame.bottom),
          );
        }
        expect(
          find.text('Fixture tag'),
          layout == LayoutType.list ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('updated local cover keeps the previous image until ready', (
    tester,
  ) async {
    final page = ValueNotifier(const ComicPage('fixture-cover'));
    final replacement = Completer<Uint8List>();
    addTearDown(page.dispose);
    await pump(
      tester,
      Scaffold(
        body: ValueListenableBuilder<ComicPage>(
          valueListenable: page,
          builder: (context, value, _) => ComicCover(
            source: 'fixture',
            page: value,
            heroTag: 'replacement-cover',
            maxWidth: 120,
          ),
        ),
      ),
      _Library(),
      _Source(),
      loadImage: (value) =>
          value.localPath == null ? Future.value(_widePng) : replacement.future,
    );
    expectVisibleComicCoverRatio(tester, 180 / 100);
    page.value = const ComicPage('fixture-cover', localPath: 'offline');
    await tester.pump();
    expectVisibleComicCoverRatio(tester, 180 / 100);
    expect(
      find.descendant(
        of: find.byType(ComicImage),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    replacement.complete(_tallPng);
    await tester.pumpAndSettle();
    expectVisibleComicCoverRatio(tester, 100 / 220);
  });

  for (final size in [const Size(320, 640), const Size(1000, 600)]) {
    testWidgets('comic details keep toolbar actions and shared tags at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final library = _Library();
      await pump(
        tester,
        const ComicDetailScreen(comic: _comic),
        library,
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
      final cover = tester.getRect(
        find.byKey(const ValueKey('comic-detail-cover')),
      );
      final title = tester.getRect(find.byType(WorkTitleHeader));
      if (size.width == 320) {
        expect(cover.left, closeTo(title.left, 0.1));
        expect(cover.bottom, lessThan(title.top));
      } else {
        expect(cover.left, lessThan(title.left));
        expect((cover.top - title.top).abs(), lessThan(24));
      }
      expect(cover.width, closeTo(size.width == 320 ? 304 : 904 / 3, 0.1));
      expect(
        tester
            .widget<ComicImage>(
              find.descendant(
                of: find.byKey(const ValueKey('comic-detail-cover')),
                matching: find.byType(ComicImage),
              ),
            )
            .fit,
        BoxFit.contain,
      );
      final button = tester.getRect(
        find.ancestor(
          of: find.text('Continue reading'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(
        button.right,
        closeTo(size.width - (size.width == 320 ? 8 : 16) - 8, 0.1),
      );
      expect(button.top, greaterThan(title.bottom));
      if (size.width == 320) {
        expect(button.top, greaterThan(cover.bottom));
      } else {
        expect(button.left, greaterThan(cover.right));
      }
      final icon = tester.getRect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.byIcon(Icons.menu_book),
        ),
      );
      final label = tester.getRect(find.text('Continue reading'));
      expect((icon.left + label.right) / 2, closeTo(button.center.dx, 2));
      expect(icon.center.dy, closeTo(button.center.dy, 2));
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('comments sit between tags and chapters and remain read only', (
    tester,
  ) async {
    final source = _Source()..commentsEnabled = true;
    await pump(
      tester,
      const ComicDetailScreen(comic: _comic),
      _Library(),
      source,
    );
    final labels = S.of(tester.element(find.byType(ComicDetailScreen)));
    final comments = find.text(labels.comicComments);
    expect(
      tester.getTopLeft(find.text('Fixture tag')).dy,
      lessThan(tester.getTopLeft(comments).dy),
    );
    expect(
      tester.getTopLeft(comments).dy,
      lessThan(tester.getTopLeft(find.text(labels.comicChapters)).dy),
    );
    await tester.ensureVisible(comments);
    await tester.tap(comments);
    await tester.pumpAndSettle();
    expect(find.text('Existing comment'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('detail cover follows big grid width when a window is resized', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      const ComicDetailScreen(comic: _comic),
      _Library(),
      _Source(),
    );
    final cover = find.byKey(const ValueKey('comic-detail-cover'));
    expect(tester.getSize(cover).width, closeTo(304, 0.1));
    tester.view.physicalSize = const Size(900, 600);
    await tester.pumpAndSettle();
    expect(tester.getSize(cover).width, closeTo(268, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'detail cover matches a tab grid narrowed by the landscape rail',
    (tester) async {
      await StorageService.setBool('comic_grid', true);
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(
        tester,
        const Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 920,
              height: 600,
              child: ComicGrid(comics: [_comic]),
            ),
          ),
        ),
        _Library(),
        _Source(),
      );
      final cardCover = tester.getSize(find.byType(ComicImage)).width;
      expect(cardCover, closeTo(824 / 3, 0.1));
      await tester.tap(find.text('Fixture book'));
      await tester.pumpAndSettle();
      final detailCover = find.byKey(const ValueKey('comic-detail-cover'));
      expect(tester.getSize(detailCover).width, closeTo(cardCover, 0.1));
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.getSize(detailCover).width, closeTo(183, 0.1));
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(1000, 600),
  ]) {
    for (final (label, bytes, ratio) in [
      ('wide', _widePng, 180 / 100),
      ('tall', _tallPng, 100 / 220),
    ]) {
      testWidgets('$label detail cover and right-inset reading at $size', (
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
          loadImage: (_) async => bytes,
        );
        final cover = tester.getRect(
          find.byKey(const ValueKey('comic-detail-cover')),
        );
        expect(cover.width / cover.height, closeTo(ratio, 0.001));
        final expectedWidth = switch (size.width) {
          320 => 304.0,
          390 => 183.0,
          _ => 904 / 3,
        };
        expect(cover.width, closeTo(expectedWidth, 0.1));
        final button = tester.getRect(
          find.ancestor(
            of: find.text('Continue reading'),
            matching: find.byType(FilledButton),
          ),
        );
        final title = tester.getRect(find.byType(WorkTitleHeader));
        expect(
          button.right,
          closeTo(size.width - (size.width == 320 ? 8 : 16) - 8, 0.1),
        );
        expect(button.top, greaterThan(title.bottom));
        if (size.width == 320) {
          expect(button.top, greaterThan(cover.bottom));
        } else {
          expect(button.left, greaterThan(cover.right));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'detail paints listing data before metadata and chapters finish',
    (tester) async {
      const listing = Comic(
        source: 'fixture',
        id: 'book',
        title: 'Fixture book',
        cover: 'fixture-cover',
      );
      final source = _Source()
        ..detailGate = Completer<Comic>()
        ..chapterGate = Completer<List<ComicChapter>>();
      await pump(
        tester,
        const ComicDetailScreen(comic: listing),
        _Library(),
        source,
        settle: false,
      );
      expect(find.byKey(const ValueKey('comic-detail-cover')), findsOneWidget);
      expect(find.byType(WorkTitleHeader), findsOneWidget);
      expect(source.detailRequests, 1);
      final downloadButton = find.ancestor(
        of: find.byTooltip('Download'),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(downloadButton).onPressed, isNull);
      source.detailGate!.complete(
        const Comic(
          source: 'fixture',
          id: 'book',
          title: 'Fixture book',
          cover: 'fixture-cover',
          description: 'Loaded synopsis',
          rating: '4.5',
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Loaded synopsis'), findsOneWidget);
      expect(source.chapterRequests, 1);
      expect(tester.widget<IconButton>(downloadButton).onPressed, isNull);
      source.chapterGate!.complete(_comic.chapters);
      await tester.pumpAndSettle();
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(tester.widget<IconButton>(downloadButton).onPressed, isNotNull);
      final timings = LogService.instance.logs
          .where(
            (entry) =>
                entry.tag == 'Comics' && entry.message.startsWith('Detail '),
          )
          .map((entry) => entry.message)
          .toList();
      expect(
        timings.any((message) => message.contains('first visible')),
        isTrue,
      );
      expect(timings.any((message) => message.contains('metadata')), isTrue);
      expect(timings.any((message) => message.contains('chapters')), isTrue);
    },
  );

  testWidgets('detail keeps a list-only source date for local favorites', (
    tester,
  ) async {
    const listing = Comic(
      source: 'fixture',
      id: 'book',
      title: 'Fixture book',
      cover: 'fixture-cover',
      extra: {'sourceDate': '2024-05-12'},
    );
    final library = _Library();
    await pump(
      tester,
      const ComicDetailScreen(comic: listing),
      library,
      _Source(),
    );
    await tester.tap(find.byTooltip('Favorites'));
    await tester.pumpAndSettle();
    expect(library.lastFavorite?.coverDate, '2024-05-12');
    expect(tester.takeException(), isNull);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'reader control overlays animate without moving pages; reduced motion $reduceMotion',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
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
          reduceMotion: reduceMotion,
        );
        final page = tester.getRect(
          find.byType(FutureBuilder<Uint8List>).first,
        );
        final top = find.byKey(const ValueKey('comic-reader-top-controls'));
        final bottom = find.byKey(
          const ValueKey('comic-reader-bottom-controls'),
        );
        final topMaterial = find
            .descendant(of: top, matching: find.byType(Material))
            .first;
        final bottomMaterial = find
            .descendant(of: bottom, matching: find.byType(Material))
            .first;
        final hiddenTop = tester.getTopLeft(topMaterial).dy;
        final hiddenBottom = tester.getTopLeft(bottomMaterial).dy;
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.descendant(
                  of: bottom,
                  matching: find.byType(AnimatedOpacity),
                ),
              )
              .opacity,
          0,
        );
        expect(find.byType(MiniPlayer), findsOneWidget);
        await tester.tapAt(const Offset(195, 420));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.getRect(find.byType(FutureBuilder<Uint8List>).first),
          page,
        );
        if (!reduceMotion) {
          final topSlide = tester.widget<AnimatedSlide>(top);
          final bottomSlide = tester.widget<AnimatedSlide>(bottom);
          expect(topSlide.offset, Offset.zero);
          expect(bottomSlide.offset, Offset.zero);
          final topOpacity = tester.widget<AnimatedOpacity>(
            find.descendant(of: top, matching: find.byType(AnimatedOpacity)),
          );
          expect(topOpacity.opacity, 1);
          final topPosition = tester.getTopLeft(topMaterial).dy;
          expect(topPosition, greaterThan(hiddenTop));
          expect(topPosition, lessThan(0));
          expect(tester.getTopLeft(bottomMaterial).dy, lessThan(hiddenBottom));
        }
        await tester.pumpAndSettle();
        expect(find.text('4/8'), findsOneWidget);
        expect(find.byType(MiniPlayer), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IgnorePointer>(
                find
                    .ancestor(of: bottom, matching: find.byType(IgnorePointer))
                    .first,
              )
              .ignoring,
          isTrue,
        );
        expect(
          tester.getRect(find.byType(FutureBuilder<Uint8List>).first),
          page,
        );
        expect(
          tester
              .widget<ExcludeFocus>(
                find
                    .ancestor(of: bottom, matching: find.byType(ExcludeFocus))
                    .first,
              )
              .excluding,
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(library.last?.page, 3);
      },
    );
  }

  testWidgets(
    'metadata and chapter failures retain the cover and retry locally',
    (tester) async {
      const listing = Comic(
        source: 'fixture',
        id: 'book',
        title: 'Fixture book',
      );
      final source = _Source()
        ..detailFails = true
        ..chaptersFail = true;
      await pump(
        tester,
        const ComicDetailScreen(comic: listing),
        _Library(),
        source,
      );
      expect(find.byType(WorkTitleHeader), findsOneWidget);
      expect(find.text('detail unavailable'), findsOneWidget);
      expect(find.text('chapters unavailable'), findsOneWidget);
      source.detailFails = false;
      await tester.ensureVisible(find.text('Retry').first);
      await tester.tap(find.text('Retry').first);
      await tester.pumpAndSettle();
      expect(find.text('detail unavailable'), findsNothing);
      expect(find.text('chapters unavailable'), findsOneWidget);
      source.chaptersFail = false;
      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(source.detailRequests, 2);
      expect(source.chapterRequests, 2);
    },
  );

  testWidgets('completed offline comic opens without metadata requests', (
    tester,
  ) async {
    final library = _Library();
    library.savedTasks.add(
      ComicDownloadTask(
        comic: _comic,
        chapter: _comic.chapters.first,
        directory: 'offline',
        status: ComicDownloadStatus.complete,
        coverPath: 'offline-cover',
      ).toJson(),
    );
    final source = _Source();
    await pump(
      tester,
      const ComicDetailScreen(
        comic: Comic(
          source: 'fixture',
          id: 'book',
          title: 'Fixture book',
          cover: 'fixture-cover',
        ),
      ),
      library,
      source,
    );
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(source.detailRequests, 0);
    expect(source.chapterRequests, 0);
    final cover = tester.widget<ComicImage>(
      find.descendant(
        of: find.byKey(const ValueKey('comic-detail-cover')),
        matching: find.byType(ComicImage),
      ),
    );
    expect(cover.page.localPath, 'offline-cover');
  });

  for (final layout in LayoutType.values) {
    testWidgets('comic $layout cover heroes into detail and returns', (
      tester,
    ) async {
      await StorageService.setString('comic_layout_type', layout.name);
      await pump(
        tester,
        const Scaffold(body: ComicGrid(comics: [_comic])),
        _Library(),
        _Source(),
        loadImage: (_) async => _widePng,
      );
      final hero = find.byWidgetPredicate(
        (widget) => widget is Hero && widget.tag == comicCoverHeroTag(_comic),
      );
      expect(hero, findsOneWidget);
      final start = tester.getRect(find.byType(ComicImage).first);
      await tester.tap(find.text('Fixture book'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ComicDetailScreen), findsOneWidget);
      expect(hero, findsWidgets);
      expectVisibleComicCoverRatio(tester, 180 / 100);
      expectComicCoverFlightRadius();
      await tester.pumpAndSettle();
      final destination = tester.getRect(
        find.byKey(const ValueKey('comic-detail-cover')),
      );
      if (layout != LayoutType.list) {
        expect(destination.width, closeTo(start.width, 0.1));
      } else {
        expect(destination.width, greaterThan(start.width));
      }
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expectVisibleComicCoverRatio(tester, 180 / 100);
      expectComicCoverFlightRadius();
      await tester.pumpAndSettle();
      expect(find.byType(ComicDetailScreen), findsNothing);
      expect(tester.getRect(find.byType(ComicImage).first), start);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('search cover also heroes to detail', (tester) async {
    await pump(
      tester,
      const ComicSearchScreen(initialSource: 'fixture', initialQuery: 'book'),
      _Library(),
      _Source(),
      loadImage: (_) async => _widePng,
    );
    await tester.tap(find.text('Grouped results'));
    await tester.pumpAndSettle();
    final hero = find.byWidgetPredicate(
      (widget) => widget is Hero && widget.tag == comicCoverHeroTag(_comic),
    );
    expect(hero, findsOneWidget);
    final start = tester.getRect(find.byType(WorkCoverHeroFrame));
    expect(start.width / start.height, closeTo(180 / 100, 0.001));
    await tester.tap(find.text('Fixture book'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expectVisibleComicCoverRatio(tester, 180 / 100);
    expectComicCoverFlightRadius();
    await tester.pumpAndSettle();
    expect(find.byType(ComicDetailScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expectVisibleComicCoverRatio(tester, 180 / 100);
    expectComicCoverFlightRadius();
    await tester.pumpAndSettle();
    expect(hero, findsOneWidget);
  });

  testWidgets('reduced motion omits the comic cover Hero', (tester) async {
    await pump(
      tester,
      const Scaffold(body: ComicGrid(comics: [_comic])),
      _Library(),
      _Source(),
      reduceMotion: true,
    );
    final hero = find.byWidgetPredicate(
      (widget) => widget is Hero && widget.tag == comicCoverHeroTag(_comic),
    );
    expect(hero, findsNothing);
    expectVisibleComicCoverRatio(tester, 100 / 160);
    await tester.tap(find.text('Fixture book'));
    await tester.pumpAndSettle();
    expect(find.byType(ComicDetailScreen), findsOneWidget);
    expect(hero, findsNothing);
    expectVisibleComicCoverRatio(tester, 100 / 160);
  });

  for (final grid in [false, true]) {
    testWidgets('comic $grid card and cover appear together at final size', (
      tester,
    ) async {
      await StorageService.setBool('comic_grid', grid);
      final image = Completer<Uint8List>();
      var loads = 0;
      await pump(
        tester,
        const Scaffold(body: ComicGrid(comics: [_comic])),
        _Library(),
        _Source(),
        loadImage: (_) {
          loads++;
          return image.future;
        },
        settle: false,
      );
      expect(find.byType(Card), findsNothing);
      expect(find.text('Fixture book'), findsNothing);
      expect(loads, 1);
      image.complete(_widePng);
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsOneWidget);
      final cover = tester.getRect(find.byType(ComicImage));
      expect(cover.width / cover.height, closeTo(180 / 100, 0.001));
      expect(loads, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('loaded comic cover stays visible throughout Hero push and pop', (
    tester,
  ) async {
    var loads = 0;
    await pump(
      tester,
      const Scaffold(body: ComicGrid(comics: [_comic])),
      _Library(),
      _Source(),
      loadImage: (_) {
        loads++;
        return Future.value(_widePng);
      },
    );
    expect(loads, 1);
    await tester.tap(find.text('Fixture book'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(loads, 1);
    expect(find.byType(ComicImage), findsWidgets);
    expectVisibleComicCoverRatio(tester, 180 / 100);
    expectComicCoverFlightRadius();
    expect(
      find.descendant(
        of: find.byType(ComicImage),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(find.byType(Image), findsWidgets);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(loads, 1);
    expect(find.byType(ComicImage), findsWidgets);
    expectVisibleComicCoverRatio(tester, 180 / 100);
    expectComicCoverFlightRadius();
    expect(
      find.descendant(
        of: find.byType(ComicImage),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(find.byType(Image), findsWidgets);
  });

  for (final grid in [false, true]) {
    testWidgets('dated $grid card keeps its badge rule during Hero flight', (
      tester,
    ) async {
      await StorageService.setBool('comic_grid', grid);
      const dated = Comic(
        source: 'fixture',
        id: 'book',
        title: 'Fixture book',
        cover: 'fixture-cover',
        extra: {'sourceDate': '2024-05-12'},
      );
      await pump(
        tester,
        const Scaffold(body: ComicGrid(comics: [dated])),
        _Library(),
        _Source(),
        loadImage: (_) async => _widePng,
      );
      expect(find.text('2024-05-12'), grid ? findsOneWidget : findsNothing);
      await tester.tap(find.text('Fixture book'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('2024-05-12'), grid ? findsOneWidget : findsNothing);
      expectVisibleComicCoverRatio(tester, 180 / 100);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('2024-05-12'), grid ? findsOneWidget : findsNothing);
      expectVisibleComicCoverRatio(tester, 180 / 100);
      await tester.pumpAndSettle();
      expect(find.text('2024-05-12'), grid ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(390, 844), const Size(700, 360)]) {
    testWidgets('reading button centers a longer translation at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(
        tester,
        Builder(
          builder: (context) => Localizations.override(
            context: context,
            locale: const Locale('ru'),
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: const ComicDetailScreen(comic: _comic),
            ),
          ),
        ),
        _Library(),
        _Source(),
      );
      final buttonFinder = find.ancestor(
        of: find.text('Продолжить чтение'),
        matching: find.byType(FilledButton),
      );
      final button = tester.getRect(buttonFinder);
      final icon = tester.getRect(
        find.descendant(
          of: buttonFinder,
          matching: find.byIcon(Icons.menu_book),
        ),
      );
      final label = tester.getRect(find.text('Продолжить чтение'));
      expect(icon.left, greaterThan(button.left));
      expect(label.right, lessThan(button.right));
      expect((icon.left + label.right) / 2, closeTo(button.center.dx, 2));
      expect(icon.center.dy, closeTo(button.center.dy, 2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed cover keeps its placeholder through flight and retries', (
    tester,
  ) async {
    final pending = Completer<Uint8List>();
    var loads = 0;
    await pump(
      tester,
      const Scaffold(body: ComicGrid(comics: [_comic])),
      _Library(),
      _Source(),
      loadImage: (_) => ++loads == 1 ? pending.future : Future.value(_widePng),
      settle: false,
    );
    expect(find.byType(Card), findsNothing);
    pending.completeError(StateError('cover failed'));
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsOneWidget);
    await tester.tap(find.text('Fixture book'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final flight = tester.getRect(find.byType(ComicImage).first);
    expect(flight.width / flight.height, closeTo(2 / 3, 0.001));
    expectComicCoverFlightRadius();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Retry'), findsWidgets);
    await tester.tap(find.byTooltip('Retry').last);
    await tester.pumpAndSettle();
    expect(loads, 2);
    expectVisibleComicCoverRatio(tester, 180 / 100);
    expect(tester.takeException(), isNull);
  });

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
    'comic search hands off the Dock and Mini Player on both directions',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(
        tester,
        AppBottomDockTransitionScope(
          child: Scaffold(
            body: const ComicScreen(),
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
          id: 'search-track',
          title: 'Audio',
          url: 'https://example.invalid/audio.mp3',
        ),
      );
      await tester.tap(find.byTooltip('Search').first);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(appBottomDockMiniPlayerFlightRootKey), findsOneWidget);
      expect(find.byKey(appBottomDockTabBarFlightRootKey), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(ComicSearchScreen), findsOneWidget);
      expect(find.byType(MiniPlayer), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(appBottomDockMiniPlayerFlightRootKey), findsOneWidget);
      expect(find.byKey(appBottomDockTabBarFlightRootKey), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(ComicSearchScreen), findsNothing);
      expect(find.byType(MiniPlayer), findsOneWidget);
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
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(source.favoriteWrites, 2);
      expect(library.favoriteWrites, 1);
      expect(find.text('Save locally'), findsNothing);
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
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
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

  testWidgets('switching grouped mode cancels the paged loading indicator', (
    tester,
  ) async {
    final gate = Completer<ComicResult>();
    final source = _Source()..searchGates[1] = gate;
    await pump(
      tester,
      const ComicSearchScreen(initialSource: 'fixture', initialQuery: 'book'),
      _Library(),
      source,
      settle: false,
    );
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.tap(find.text('Grouped results'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LinearProgressIndicator), findsNothing);

    gate.complete(const ComicResult([_comic]));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('switching from grouped mode clears its pending sources', (
    tester,
  ) async {
    final source = _Source();
    await pump(
      tester,
      const ComicSearchScreen(initialSource: 'fixture', initialQuery: 'book'),
      _Library(),
      source,
    );
    final gate = Completer<ComicResult>();
    source.searchGates[source.searches + 1] = gate;

    await tester.tap(find.text('Grouped results'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsWidgets);

    await tester.tap(find.text('Single source'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LinearProgressIndicator), findsNothing);

    gate.complete(const ComicResult([_comic]));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}

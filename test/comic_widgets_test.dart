import 'package:kikoeru_flutter/src/comics/comic_downloads.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_widgets.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/metadata_search_chip.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_title_header.dart';
import 'package:kikoeru_flutter/src/services/log_service.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/rendering.dart';
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
    show LayoutType, WorksNotifier, worksProvider;
import 'package:kikoeru_flutter/src/screens/main_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/providers/download_provider.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/comics/comic_models.dart';
import 'package:kikoeru_flutter/src/comics/comic_source.dart';
import 'package:kikoeru_flutter/src/comics/comic_http.dart';
import 'package:kikoeru_flutter/src/comics/sources/pica_source.dart';
import 'package:kikoeru_flutter/src/comics/comic_library.dart';
import 'package:kikoeru_flutter/src/comics/comic_providers.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_settings_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_detail_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_reader_screen.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_page_preview.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_chapter_thumbnails.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_search_screen.dart';
import 'package:kikoeru_flutter/src/widgets/pagination_bar.dart';
import 'package:kikoeru_flutter/src/widgets/settings_option_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/work_image_reader.dart';
import 'package:kikoeru_flutter/src/utils/local_file_url.dart';

Finder readerPageValue(String value) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.value == value,
);

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
  List<ComicComment> commentsResult = const [
    ComicComment('Reader', 'Existing comment'),
  ];
  final pageRequests = <String>[];
  int searches = 0, favoriteWrites = 0, favoriteReads = 0;
  int detailRequests = 0, chapterRequests = 0;
  final searchGates = <int, Completer<ComicResult>>{};
  Completer<Comic>? detailGate;
  Completer<List<ComicChapter>>? chapterGate;
  Comic? detailResult;
  bool detailFails = false, chaptersFail = false;
  @override
  bool get isLoggedIn => loggedIn;
  @override
  bool get hasComments => commentsEnabled;
  @override
  Future<List<ComicComment>> comments(Comic comic) async => commentsResult;
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
  Future<List<ComicCategory>> categories() async => const [
    ComicCategory('fixture-category', 'Fixture category'),
  ];
  @override
  Future<ComicResult> favorites({String? cursor}) async {
    favoriteReads++;
    return ComicResult([
      Comic(source: key, id: 'favorite', title: 'Online favorite'),
    ]);
  }

  @override
  Future<Comic> details(String id) async {
    detailRequests++;
    if (detailFails) throw const ComicSourceException('detail unavailable');
    return detailGate?.future ?? detailResult ?? _comic;
  }

  @override
  Future<List<ComicChapter>> chapters(Comic comic) async {
    chapterRequests++;
    if (chaptersFail) throw const ComicSourceException('chapters unavailable');
    return chapterGate?.future ?? comic.chapters;
  }

  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async {
    pageRequests.add(chapter.id);
    if (chapter.id == failedChapter) {
      throw const ComicSourceException('Chapter unavailable');
    }
    return List.generate(8, (i) => ComicPage('page-$i'));
  }
}

class _SortedSource extends _Source {
  final sortRequests = <String?>[];

  @override
  List<String> get searchSorts => const ['dd', 'da'];

  @override
  Future<ComicResult> search(String query, {String? cursor, String? sort}) {
    sortRequests.add(sort);
    return super.search(query, cursor: cursor, sort: sort);
  }
}

class _ThreePageChapterSource extends _Source {
  @override
  Future<List<ComicPage>> pages(Comic comic, ComicChapter chapter) async {
    if (chapter.id == 'one') {
      return List.generate(3, (i) => ComicPage('page-$i'));
    }
    return super.pages(comic, chapter);
  }
}

class _PaginatedSource extends _Source {
  _PaginatedSource(this.firstPage, this.secondPage);

  final List<Comic> firstPage;
  final List<Comic> secondPage;
  final cursors = <String?>[];
  Completer<ComicResult>? secondPageGate;

  @override
  Future<ComicResult> explore({String? cursor}) async {
    cursors.add(cursor);
    if (cursor == null) return ComicResult(firstPage, next: 'second-page');
    return secondPageGate?.future ?? ComicResult(secondPage);
  }
}

class _IdleWorks extends WorksNotifier {
  _IdleWorks(Ref ref) : super(KikoeruApiService(), ref);

  @override
  Future<void> loadWorks({
    bool refresh = false,
    int? targetPage,
    bool append = false,
    bool supersede = false,
  }) async {}
}

class _PaginatedSearchSource extends _Source {
  _PaginatedSearchSource(this.firstPage, this.secondPage);

  final List<Comic> firstPage;
  final List<Comic> secondPage;
  final cursors = <String?>[];
  Completer<ComicResult>? secondPageGate;

  @override
  Future<ComicResult> search(
    String query, {
    String? cursor,
    String? sort,
  }) async {
    searches++;
    cursors.add(cursor);
    if (cursor != null && secondPageGate != null) return secondPageGate!.future;
    return cursor == null
        ? ComicResult(firstPage, next: 'search-next')
        : ComicResult(secondPage);
  }
}

class _BatchSource extends _Source {
  @override
  Future<ComicResult> search(
    String query, {
    String? cursor,
    String? sort,
  }) async {
    searches++;
    return ComicResult(
      List.generate(
        12,
        (index) => Comic(
          source: key,
          id: 'batch-$index',
          title: 'Batch $index',
          cover: 'batch-cover-$index',
        ),
      ),
    );
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
  int favoriteReads = 0, historyReads = 0;
  VoidCallback? onHistoryRead;
  @override
  Future<void> favorite(Comic comic, bool value) async {
    favoriteWrites++;
    lastFavorite = comic;
  }

  @override
  Future<List<Map<String, dynamic>>> loadTasks() async => savedTasks;
  @override
  Future<List<Comic>> favorites() async {
    favoriteReads++;
    return [];
  }

  @override
  Future<List<ComicProgress>> history() async {
    historyReads++;
    onHistoryRead?.call();
    return last == null ? [] : [last!];
  }

  @override
  Future<ComicProgress?> progress(Comic comic) async => last;
  @override
  Future<void> saveProgress(Comic comic, String chapter, int page) async {
    last = ComicProgress(comic, chapter, page, DateTime.now());
  }
}

class _NotifyingLibrary extends _Library {
  @override
  Future<void> saveProgress(Comic comic, String chapter, int page) async {
    await super.saveProgress(comic, chapter, page);
    notifyListeners();
  }

  @override
  Future<void> removeHistory(Comic comic) async {
    last = null;
    notifyListeners();
  }
}

class _RecordingComicDownloads extends ComicDownloads {
  _RecordingComicDownloads(_Library library, _Source source)
    : super(library, (_) => source);
  final enqueued = <List<ComicChapter>>[];
  bool fail = false;

  @override
  Future<void> enqueue(Comic comic, List<ComicChapter> chapters) async {
    if (fail) throw StateError('queue unavailable');
    enqueued.add(chapters);
  }
}

class _PreviewDownloads extends ComicDownloads {
  _PreviewDownloads(_Library library, _Source source, this.pages)
    : super(library, (_) => source);
  final List<ComicPage> pages;

  @override
  Future<List<ComicPage>?> offlinePages(
    Comic comic,
    ComicChapter chapter,
  ) async => pages;
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
final _highResolutionPng = Uint8List.fromList(
  img.encodePng(img.Image(width: 1800, height: 1000)),
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

Future<void> pumpFrames(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void expectComicCardHidden(WidgetTester tester) {
  final visibility = find.ancestor(
    of: find.byType(Card),
    matching: find.byType(Visibility),
  );
  expect(visibility, findsOneWidget);
  expect(tester.widget<Visibility>(visibility).visible, isFalse);
}

Finder comicCardForTitle(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(Card));

void expectComicTitleHidden(WidgetTester tester, String title) {
  final card = comicCardForTitle(title);
  expect(card, findsOneWidget);
  final visibility = find.ancestor(of: card, matching: find.byType(Visibility));
  expect(tester.widget<Visibility>(visibility).visible, isFalse);
}

void expectComicCardReady(WidgetTester tester, String title) {
  final card = comicCardForTitle(title);
  expect(card, findsOneWidget);
  final visibility = find.ancestor(of: card, matching: find.byType(Visibility));
  expect(
    tester.widget<Visibility>(visibility).visible,
    isTrue,
    reason: '$title remains hidden after its image was prepared.',
  );
  expect(find.text(title).hitTestable(), findsOneWidget);
  final rawImages = find.descendant(of: card, matching: find.byType(RawImage));
  expect(rawImages, findsOneWidget);
  expect(tester.widget<RawImage>(rawImages).image, isNotNull);
}

Finder memoryImageForBytes(Uint8List bytes) => find.byWidgetPredicate((widget) {
  bool usesBytes(ImageProvider provider) {
    if (provider is MemoryImage) return identical(provider.bytes, bytes);
    if (provider is ResizeImage) return usesBytes(provider.imageProvider);
    return false;
  }

  return widget is Image && usesBytes(widget.image);
});

Future<void> waitForCoverBytes(WidgetTester tester, Uint8List bytes) async {
  final image = memoryImageForBytes(bytes);
  for (var frame = 0; frame < 24 && image.evaluate().isEmpty; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(image, findsOneWidget);
  await waitForDecodedImage(tester, image);
  await pumpFrames(tester, frames: 3);
}

Future<void> waitForComicCardImage(WidgetTester tester, String title) async {
  final image = find.descendant(
    of: comicCardForTitle(title),
    matching: find.byType(Image),
  );
  for (var frame = 0; frame < 24 && image.evaluate().isEmpty; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(image, findsOneWidget);
  await waitForDecodedImage(tester, image);
  await pumpFrames(tester, frames: 3);
}

void expectComicCoversAttached() {
  expect(find.byType(WorkCoverClip), findsWidgets);
  expect(
    find.ancestor(of: find.byType(WorkCoverClip), matching: find.byType(Hero)),
    findsNothing,
  );
}

Future<Size> waitForDecodedImage(WidgetTester tester, Finder finder) async {
  final size = await tester.runAsync(() async {
    final imageWidget = tester.widget<Image>(finder);
    final stream = imageWidget.image.resolve(
      createLocalImageConfiguration(tester.element(finder)),
    );
    final decoded = Completer<Size>();
    final listener = ImageStreamListener((imageInfo, _) {
      if (!decoded.isCompleted) {
        decoded.complete(
          Size(
            imageInfo.image.width.toDouble(),
            imageInfo.image.height.toDouble(),
          ),
        );
      }
    });
    stream.addListener(listener);
    try {
      return await decoded.future.timeout(const Duration(seconds: 5));
    } finally {
      stream.removeListener(listener);
    }
  });
  await tester.pump();
  return size!;
}

Future<void> expectComicCoverDecodeMatchesDisplay(
  WidgetTester tester,
  Finder cover,
  int sourceWidth,
) async {
  final imageFinder = find.descendant(of: cover, matching: find.byType(Image));
  expect(imageFinder, findsOneWidget);
  final provider = tester.widget<Image>(imageFinder).image;
  expect(provider, isA<ResizeImage>());
  final resized = provider as ResizeImage;
  final targetWidth = math.min(
    (tester.getSize(cover).width * tester.view.devicePixelRatio).ceil(),
    sourceWidth,
  );
  expect(resized.width, targetWidth);

  final decodedSize = await waitForDecodedImage(tester, imageFinder);
  expect(decodedSize.width, targetWidth.toDouble());
  expect(
    decodedSize.width,
    lessThanOrEqualTo(
      (tester.getSize(cover).width * tester.view.devicePixelRatio)
          .ceil()
          .toDouble(),
    ),
  );
  expect(decodedSize.width, lessThanOrEqualTo(sourceWidth.toDouble()));

  final cacheKey = await provider.obtainKey(ImageConfiguration.empty);
  expect(
    PaintingBinding.instance.imageCache.statusForKey(cacheKey).keepAlive,
    isTrue,
    reason:
        'The resize provider key must identify the decoded cover cache entry.',
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'comic_grid': false,
      'comic_selected_source': 'fixture',
      'comic_chapter_thumbnails': false,
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
    double textScale = 1,
    Locale locale = const Locale('en'),
    ThemeData? theme,
    ComicDownloads? downloads,
  }) async {
    final container = ProviderContainer(
      overrides: [
        comicSourcesProvider.overrideWithValue([
          source,
          if (other != null) other,
        ]),
        comicLibraryProvider.overrideWith((ref) => library),
        if (downloads != null)
          comicDownloadsProvider.overrideWith((ref) => downloads),
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
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduceMotion,
              textScaler: TextScaler.linear(textScale),
            ),
            child: RepaintBoundary(
              key: const ValueKey('app-paint'),
              child: child!,
            ),
          ),
          locale: locale,
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

  Future<void> doubleTapAt(WidgetTester tester, Offset position) async {
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> waitForPreviewContent(
    WidgetTester tester,
    Finder content,
  ) async {
    for (var i = 0; i < 50 && content.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(content, findsOneWidget);
  }

  Future<void> startAutoPageTurn(
    WidgetTester tester, {
    ComicReadingMode mode = ComicReadingMode.leftToRight,
    int? interval,
    Comic comic = _comic,
    ComicChapter chapter = const ComicChapter('one', 'Chapter 1'),
    int initialPage = 0,
    _Source? source,
    Future<Uint8List> Function(ComicPage)? loadImage,
    bool reduceMotion = false,
  }) async {
    await StorageService.setString('comic_reading_mode', mode.name);
    if (interval != null) {
      await StorageService.setInt('comic_auto_page_interval', interval);
    }
    await pump(
      tester,
      ComicReaderScreen(
        comic: comic,
        chapter: chapter,
        initialPage: initialPage,
      ),
      _Library(),
      source ?? _Source(),
      loadImage: loadImage,
      reduceMotion: reduceMotion,
    );
    await waitForDecodedImage(tester, find.byType(Image).first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('comic-auto-page-turn')));
    await tester.pump();
  }

  for (final mode in ComicReadingMode.values.where(
    (mode) => mode != ComicReadingMode.continuous,
  )) {
    for (final reduceMotion in [false, true]) {
      testWidgets(
        'reader edge taps animate in ${mode.name}; reduced motion $reduceMotion',
        (tester) async {
          await StorageService.setString('comic_reading_mode', mode.name);
          await StorageService.setBool('comic_double_tap_zoom', false);
          await pump(
            tester,
            const ComicReaderScreen(
              comic: _comic,
              chapter: ComicChapter('one', 'Chapter 1'),
            ),
            _Library(),
            _Source(),
            reduceMotion: reduceMotion,
          );
          final view = find.byType(PageView);
          final controller = tester.widget<PageView>(view).controller!;
          final bounds = tester.getRect(view);
          final reverse = tester.widget<PageView>(view).reverse;
          final forward = Offset(
            reverse ? bounds.left + 20 : bounds.right - 20,
            bounds.center.dy,
          );
          final backward = Offset(
            reverse ? bounds.right - 20 : bounds.left + 20,
            bounds.center.dy,
          );

          await tester.tapAt(forward);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          if (reduceMotion) {
            expect(controller.page, 1);
          } else {
            expect(controller.page, inExclusiveRange(0, 1));
          }
          await tester.pumpAndSettle();
          expect(controller.page, 1);
          expect(
            readerPageValue(isComicSpread(mode) ? '3/8' : '2/8'),
            findsOneWidget,
          );

          await tester.tapAt(backward);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          if (reduceMotion) {
            expect(controller.page, 0);
          } else {
            expect(controller.page, inExclusiveRange(0, 1));
          }
          await tester.pumpAndSettle();
          expect(controller.page, 0);
          expect(readerPageValue('1/8'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final deltas in const [
    [1, 1],
    [1, -1],
    [1, -1, 1, 1],
  ]) {
    testWidgets('reader rapid edge taps $deltas keep the pending target', (
      tester,
    ) async {
      await StorageService.setString('comic_reading_mode', 'leftToRight');
      await StorageService.setBool('comic_double_tap_zoom', false);
      final source = _Source();
      await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('two', 'Chapter 2'),
        ),
        _Library(),
        source,
      );
      final view = find.byType(PageView);
      final controller = tester.widget<PageView>(view).controller!;
      final bounds = tester.getRect(view);
      for (final delta in deltas) {
        await tester.tapAt(
          Offset(
            delta > 0 ? bounds.right - 20 : bounds.left + 20,
            bounds.center.dy,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      final target = deltas.reduce((a, b) => a + b);
      expect(source.pageRequests, ['two']);
      expect(controller.page, target.toDouble());
      expect(readerPageValue('${target + 1}/8'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final interruption in ['drag', 'controls']) {
    testWidgets('reader $interruption clears an interrupted edge turn', (
      tester,
    ) async {
      await StorageService.setString('comic_reading_mode', 'leftToRight');
      await StorageService.setBool('comic_double_tap_zoom', false);
      await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('two', 'Chapter 2'),
        ),
        _Library(),
        _Source(),
      );
      final view = find.byType(PageView);
      final controller = tester.widget<PageView>(view).controller!;
      final bounds = tester.getRect(view);
      final forward = Offset(bounds.right - 20, bounds.center.dy);
      await tester.tapAt(forward);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      if (interruption == 'drag') {
        await tester.drag(view, const Offset(600, 0));
      } else {
        await tester.tapAt(bounds.center);
      }
      await tester.pumpAndSettle();
      expect(controller.page, 0);
      await tester.tapAt(forward);
      await tester.pumpAndSettle();
      expect(controller.page, 1);
      expect(readerPageValue('2/8'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reader bottom controls keep eight icons in one row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await StorageService.setString('comic_reading_mode', 'leftToRight');
    await StorageService.setInt('comic_auto_page_interval', 1);
    const comic = Comic(
      source: 'fixture',
      id: 'book',
      title: 'Fixture book',
      chapters: [
        ComicChapter('one', 'Chapter 1'),
        ComicChapter('two', 'Chapter 2'),
        ComicChapter('three', 'Chapter 3'),
      ],
    );
    final library = _Library();
    await pump(
      tester,
      const ComicReaderScreen(
        comic: comic,
        chapter: ComicChapter('one', 'Chapter 1'),
      ),
      library,
      _Source(),
    );
    await waitForDecodedImage(tester, find.byType(Image).first);
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(PageView)));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    final bottom = find.byKey(const ValueKey('comic-reader-bottom-controls'));
    final auto = find.byKey(const ValueKey('comic-auto-page-turn'));
    final chooser = find.descendant(
      of: bottom,
      matching: find.byTooltip('Choose chapters'),
    );
    expect(auto, findsOneWidget);
    expect(chooser, findsOneWidget);
    expect(
      find.descendant(of: auto, matching: find.text('Auto page turn')),
      findsNothing,
    );
    expect(find.byType(Slider), findsNothing);
    expect(find.text('1/8'), findsNothing);
    final actions = [
      find.byKey(const ValueKey('comic-page-preview')),
      chooser,
      auto,
      find.byTooltip('Reading mode'),
      find.byTooltip('Screen orientation'),
      find.byTooltip('Favorites'),
      find.byTooltip('Download'),
      find.byTooltip('Save Image'),
    ];
    for (final width in [320.0, 1000.0]) {
      tester.view.physicalSize = Size(width, 640);
      await tester.pumpAndSettle();
      final centers = actions.map(tester.getCenter).toList();
      for (var i = 0; i < centers.length; i++) {
        expect(centers[i].dy, centers.first.dy);
        if (i > 0) expect(centers[i].dx, greaterThan(centers[i - 1].dx));
      }
      expect(tester.takeException(), isNull);
    }
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('comic-reader-top-controls')),
        matching: find.byType(PopupMenuButton<ComicReadingMode>),
      ),
      findsNothing,
    );
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    expect(find.byTooltip('Previous chapter'), findsNothing);
    expect(find.byTooltip('Next chapter'), findsNothing);
    expect(tester.widget<IconButton>(auto).isSelected, isFalse);
    expect(tester.getRect(auto).bottom, lessThanOrEqualTo(640));
    expect(tester.getRect(chooser).bottom, lessThanOrEqualTo(640));

    await tester.tap(auto);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(auto).isSelected, isTrue);
    expect(readerPageValue('2/8'), findsOneWidget);
    await tester.tap(auto);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.widget<IconButton>(auto).isSelected, isFalse);
    expect(readerPageValue('2/8'), findsOneWidget);

    await tester.tap(chooser);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Chapter 1'))
          .selected,
      isTrue,
    );
    await tester.tap(find.widgetWithText(ListTile, 'Chapter 3'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Chapter 3'), findsOneWidget);
    expect(readerPageValue('1/8'), findsOneWidget);
    expect(library.last?.chapterId, 'three');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(readerPageValue('2/8'), findsOneWidget);
    await tester.tap(chooser);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Chapter 3'))
          .selected,
      isTrue,
    );
    await tester.tap(find.widgetWithText(ListTile, 'Chapter 3'));
    await tester.pumpAndSettle();
    expect(readerPageValue('2/8'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'page preview reuses the current image and retries failed loads',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await StorageService.setString('comic_reading_mode', 'leftToRight');
      await StorageService.setInt('comic_preload', 0);
      final attempts = <String, int>{};
      await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('one', 'Chapter 1'),
          initialPage: 3,
        ),
        _Library(),
        _Source(),
        loadImage: (page) async {
          final count = attempts.update(
            page.url,
            (value) => value + 1,
            ifAbsent: () => 1,
          );
          if (page.url == 'page-4' && count == 1) {
            throw StateError('image unavailable');
          }
          return _png;
        },
      );
      await waitForDecodedImage(tester, find.byType(Image).first);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('comic-page-preview')));
      await tester.pump();
      final tile = find.byKey(const ValueKey('comic-page-preview-4'));
      await waitForPreviewContent(
        tester,
        find.descendant(
          of: tile,
          matching: find.byIcon(Icons.broken_image_outlined),
        ),
      );
      expect(attempts['page-3'], 1);
      expect(attempts['page-4'], 1);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(tile);
      final thumbnail = find.descendant(of: tile, matching: find.byType(Image));
      await waitForPreviewContent(tester, thumbnail);
      await waitForDecodedImage(tester, thumbnail);
      expect(attempts['page-4'], 2);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(readerPageValue('5/8'), findsOneWidget);
      expect(find.byType(ComicPagePreview), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reader mode menu stays compact with a Mini Player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await StorageService.setString('comic_reading_mode', 'leftToRight');
    await pump(
      tester,
      const ComicReaderScreen(
        comic: _comic,
        chapter: ComicChapter('one', 'Chapter 1'),
        initialPage: 3,
      ),
      _Library(),
      _Source(),
      track: const AudioTrack(
        id: 'reader-track',
        title: 'Audio',
        url: 'https://example.invalid/audio.mp3',
      ),
    );
    await waitForDecodedImage(tester, find.byType(Image).first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    final modeButtonTop = tester.getRect(find.byTooltip('Reading mode')).top;
    await tester.tap(find.byTooltip('Reading mode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final items = find.byType(MenuItemButton);
    final panel = find
        .ancestor(of: items.first, matching: find.byType(Material))
        .first;
    expect(tester.getRect(panel).bottom, lessThanOrEqualTo(modeButtonTop));
    await tester.pumpAndSettle();
    expect(items, findsNWidgets(ComicReadingMode.values.length));
    final readerButtons = tester.widgetList<MenuItemButton>(items).toList();
    final selectedReaderButton = readerButtons.singleWhere(
      (button) => button.autofocus,
    );
    final unselectedReaderButton = readerButtons.firstWhere(
      (button) => !button.autofocus,
    );
    final colors = Theme.of(tester.element(items.first)).colorScheme;
    expect(
      selectedReaderButton.style?.foregroundColor?.resolve({}),
      colors.onPrimaryContainer,
    );
    expect(
      selectedReaderButton.style?.backgroundColor?.resolve({}),
      colors.primaryContainer,
    );
    expect(unselectedReaderButton.style?.foregroundColor?.resolve({}), isNull);
    expect(unselectedReaderButton.style?.backgroundColor?.resolve({}), isNull);
    expect(
      find.descendant(of: items, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    expect(readerButtons.every((button) => button.leadingIcon == null), isTrue);
    expect(tester.getSize(items.first).width, lessThanOrEqualTo(360));
    for (final text
        in find.descendant(of: items, matching: find.byType(Text)).evaluate()) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byWidget(text.widget),
      );
      final label = text.widget as Text;
      expect(
        tester.getRect(find.byWidget(text.widget)).right,
        lessThanOrEqualTo(tester.getRect(panel).right),
        reason: label.data,
      );
      expect(
        paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: label.data!.length),
        ),
        hasLength(1),
      );
    }
    final menu = find
        .ancestor(of: items.first, matching: find.byType(SingleChildScrollView))
        .first;
    expect(tester.getRect(menu).bottom, lessThanOrEqualTo(modeButtonTop));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(readerPageValue('4/8'), findsOneWidget);
    await tester.tap(find.widgetWithText(MenuItemButton, 'Vertical pages'));
    await tester.pumpAndSettle();
    expect(StorageService.getString('comic_reading_mode'), 'vertical');
    expect(
      tester.widget<PageView>(find.byType(PageView)).scrollDirection,
      Axis.vertical,
    );
    expect(readerPageValue('4/8'), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget);
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    final landscapeButtonTop = tester
        .getRect(find.byTooltip('Reading mode'))
        .top;
    await tester.tap(find.byTooltip('Reading mode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getRect(panel).bottom, lessThanOrEqualTo(landscapeButtonTop));
    await tester.pumpAndSettle();
    expect(tester.getRect(menu).bottom, lessThanOrEqualTo(landscapeButtonTop));
    await tester.ensureVisible(items.last);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(items.last).bottom,
      lessThanOrEqualTo(landscapeButtonTop),
    );
    await tester.tap(items.last);
    await tester.pumpAndSettle();
    expect(StorageService.getString('comic_reading_mode'), 'reverseSpread');
    await tester.tap(find.byTooltip('Reading mode'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(items, findsNothing);
    await tester.tap(find.byTooltip('Reading mode'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 100));
    await tester.pumpAndSettle();
    expect(items, findsNothing);
    expect(find.byTooltip('Reading mode'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chinese reader menus fit labels without reserved icon space', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      const ComicReaderScreen(
        comic: _comic,
        chapter: ComicChapter('one', 'Chapter 1'),
      ),
      _Library(),
      _Source(),
      locale: const Locale('zh'),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    for (final tooltip in ['阅读模式', '屏幕方向']) {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      final items = find.byType(MenuItemButton);
      final panel = find
          .ancestor(of: items.first, matching: find.byType(Material))
          .first;
      final panelRect = tester.getRect(panel);
      final texts = find.descendant(of: items, matching: find.byType(Text));
      var longestLabelWidth = 0.0;
      for (final text in texts.evaluate()) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byWidget(text.widget),
        );
        longestLabelWidth = math.max(
          longestLabelWidth,
          paragraph.getMaxIntrinsicWidth(double.infinity),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      final inset = tester.getRect(texts.first).left - panelRect.left;
      expect(panelRect.width, closeTo(longestLabelWidth + inset * 2, 0.5));
      expect(panelRect.width, lessThanOrEqualTo(360));
      expect(
        tester
            .widgetList<MenuItemButton>(items)
            .every(
              (item) => item.leadingIcon == null && item.trailingIcon == null,
            ),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader menus pause auto turns and close before route back', (
    tester,
  ) async {
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ComicReaderScreen(
                comic: _comic,
                chapter: ComicChapter('one', 'Chapter 1'),
              ),
            ),
          ),
          child: const Text('Read'),
        ),
      ),
      _Library(),
      _Source(),
    );
    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('comic-auto-page-turn')));
    await tester.pump();
    expect(find.byTooltip('Pause'), findsOneWidget);
    await tester.tap(find.byTooltip('Reading mode'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Auto page turn'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(find.byType(ComicReaderScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ComicReaderScreen), findsNothing);
    expect(find.text('Read'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reader orientation persists, shares settings and restores on exit',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <List<String>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            calls.add(List<String>.from(call.arguments as List));
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
      await StorageService.setString('comic_reading_mode', 'leftToRight');
      await StorageService.setString('comic_screen_orientation', 'portrait');
      final container = await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('one', 'Chapter 1'),
          initialPage: 3,
        ),
        _Library(),
        _Source(),
      );
      await waitForDecodedImage(tester, find.byType(Image).first);
      await tester.pumpAndSettle();
      expect(calls.last, [
        'DeviceOrientation.portraitUp',
        'DeviceOrientation.portraitDown',
      ]);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      final orientationButtonTop = tester
          .getRect(find.byTooltip('Screen orientation'))
          .top;
      await tester.tap(find.byTooltip('Reading mode'));
      await tester.pumpAndSettle();
      final readingMenuWidth = tester
          .getSize(find.byType(MenuItemButton).first)
          .width;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Screen orientation'));
      await tester.pumpAndSettle();
      final orientationItems = find.byType(MenuItemButton);
      final orientationWidth = tester.getSize(orientationItems.first).width;
      expect(orientationWidth, lessThan(280));
      expect(orientationWidth, lessThan(readingMenuWidth));
      expect(orientationWidth, lessThanOrEqualTo(360));
      final selectedOrientation = tester
          .widgetList<MenuItemButton>(orientationItems)
          .singleWhere((button) => button.autofocus);
      expect(
        selectedOrientation.style?.backgroundColor?.resolve({}),
        Theme.of(
          tester.element(orientationItems.first),
        ).colorScheme.primaryContainer,
      );
      expect(
        tester
            .getRect(
              find
                  .ancestor(
                    of: find.byType(MenuItemButton).first,
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .bottom,
        lessThanOrEqualTo(orientationButtonTop),
      );
      await tester.tap(find.widgetWithText(MenuItemButton, 'Landscape'));
      await tester.pumpAndSettle();
      expect(calls.last, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
      expect(StorageService.getString('comic_screen_orientation'), 'landscape');
      expect(
        container.read(comicScreenOrientationProvider),
        ComicScreenOrientation.landscape,
      );
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(readerPageValue('4/8'), findsOneWidget);
      await tester.tap(find.byTooltip('Reader settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Screen orientation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Portrait'));
      await tester.pumpAndSettle();
      expect(StorageService.getString('comic_screen_orientation'), 'portrait');
      expect(
        container.read(comicScreenOrientationProvider),
        ComicScreenOrientation.portrait,
      );
      expect(calls.last, [
        'DeviceOrientation.portraitUp',
        'DeviceOrientation.portraitDown',
      ]);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(readerPageValue('4/8'), findsOneWidget);
      expect(find.byIcon(Icons.screen_lock_portrait), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(
        calls.last,
        unorderedEquals(
          DeviceOrientation.values.map((value) => value.toString()),
        ),
      );
      calls.clear();
      await pump(
        tester,
        const ComicReaderSettingsScreen(),
        _Library(),
        _Source(),
      );
      await tester.tap(find.text('Screen orientation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Follow system'));
      await tester.pumpAndSettle();
      expect(StorageService.getString('comic_screen_orientation'), 'system');
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reader favorite keeps source-first saving and can retry', (
    tester,
  ) async {
    final library = _Library();
    final source = _Source()
      ..loggedIn = true
      ..favoriteFails = true;
    final container = await pump(
      tester,
      const ComicReaderScreen(
        comic: _comic,
        chapter: ComicChapter('one', 'Chapter 1'),
      ),
      library,
      source,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Favorites'));
    await tester.pumpAndSettle();
    expect(source.favoriteWrites, 1);
    expect(library.favoriteWrites, 0);
    expect(container.read(comicRemoteFavoritesRevisionProvider), 0);
    source.favoriteFails = false;
    await tester.tap(find.byTooltip('Favorites'));
    await tester.pumpAndSettle();
    expect(source.favoriteWrites, 2);
    expect(library.favoriteWrites, 1);
    expect(container.read(comicRemoteFavoritesRevisionProvider), 1);
    source.loggedIn = false;
    await tester.tap(find.byTooltip('Favorites'));
    await tester.pumpAndSettle();
    expect(source.favoriteWrites, 2);
    expect(library.favoriteWrites, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reader download defaults to current chapter and supports selection',
    (tester) async {
      final library = _Library();
      final source = _Source();
      final downloads = _RecordingComicDownloads(library, source);
      await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('two', 'Chapter 2'),
          initialPage: 3,
        ),
        library,
        source,
        downloads: downloads,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Chapter 1'),
            )
            .value,
        false,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Chapter 2'),
            )
            .value,
        true,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(downloads.enqueued, isEmpty);
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Chapter 1'));
      await tester.tap(find.text('Download selected chapters'));
      await tester.pumpAndSettle();
      expect(downloads.enqueued.single.map((chapter) => chapter.id), [
        'one',
        'two',
      ]);
      expect(readerPageValue('4/8'), findsOneWidget);
      downloads.fail = true;
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download selected chapters'));
      await tester.pumpAndSettle();
      expect(find.textContaining('queue unavailable'), findsOneWidget);
      expect(downloads.enqueued, hasLength(1));
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.download))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reader saves the current image bytes and reports failures', (
    tester,
  ) async {
    final library = _Library();
    final source = _Source();
    final saved = <({Uint8List bytes, String name})>[];
    var failSave = false;
    await pump(
      tester,
      ComicReaderScreen(
        comic: _comic,
        chapter: const ComicChapter('two', 'Chapter 2'),
        initialPage: 3,
        saveImage: (_, bytes, name) async {
          if (failSave) throw StateError('disk full');
          saved.add((bytes: bytes, name: name));
        },
      ),
      library,
      source,
    );
    await waitForDecodedImage(tester, find.byType(Image).first);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save Image'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.bytes, same(_png));
    expect(saved.single.name, 'image_4');
    expect(source.pageRequests, ['two']);

    failSave = true;
    await tester.tap(find.byTooltip('Save Image'));
    await tester.pumpAndSettle();
    expect(find.textContaining('disk full'), findsOneWidget);
    expect(find.textContaining('Image saved'), findsNothing);
    expect(saved, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final mode in ComicReadingMode.values) {
    testWidgets('image reader shares comic interactions in ${mode.name}', (
      tester,
    ) async {
      await StorageService.setString('comic_reading_mode', mode.name);
      await StorageService.setInt('comic_auto_page_interval', 20);
      final library = _Library();
      final source = _Source();
      final images = [_png, _widePng, _tallPng];
      final saved = <({Uint8List bytes, String name})>[];
      await pump(
        tester,
        ComicReaderScreen.images(
          title: 'Work title',
          imageTitles: const ['First image', 'Second image', 'Last image'],
          initialPage: 1,
          loadImage: (index) async => images[index],
          saveImage: (_, bytes, name) async {
            saved.add((bytes: bytes, name: name));
          },
        ),
        library,
        source,
        track: const AudioTrack(
          id: 'audio',
          title: 'Audio',
          url: 'https://example.invalid/audio.mp3',
        ),
        reduceMotion: mode.index.isEven,
      );
      await waitForDecodedImage(tester, find.byType(Image).first);

      final zoom = find.byKey(
        ValueKey(
          mode == ComicReadingMode.continuous
              ? 'comic-continuous-zoom'
              : isComicSpread(mode)
              ? 'comic-spread-zoom-0'
              : 'comic-page-zoom-1',
        ),
      );
      await doubleTapAt(tester, tester.getCenter(zoom));
      await tester.pumpAndSettle();
      if (mode == ComicReadingMode.continuous) {
        expect(
          tester
              .widget<Transform>(
                find.byKey(const ValueKey('comic-reader-canvas-transform')),
              )
              .transform
              .getMaxScaleOnAxis(),
          greaterThan(1),
        );
      } else {
        final viewer = tester.widget<InteractiveViewer>(
          find.descendant(of: zoom, matching: find.byType(InteractiveViewer)),
        );
        expect(
          viewer.transformationController!.value.getMaxScaleOnAxis(),
          greaterThan(1),
        );
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.text('Work title'), findsOneWidget);
      expect(find.byTooltip('Choose chapters'), findsNothing);
      expect(find.byTooltip('Favorites'), findsNothing);
      expect(find.byTooltip('Reading mode'), findsOneWidget);
      expect(find.byTooltip('Screen orientation'), findsOneWidget);
      expect(find.byType(MiniPlayer), findsOneWidget);

      final auto = find.byKey(const ValueKey('comic-auto-page-turn'));
      await tester.tap(auto);
      await tester.pump();
      expect(tester.widget<IconButton>(auto).isSelected, isTrue);
      await tester.tap(find.byTooltip('Save Image'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<IconButton>(auto).isSelected, isFalse);

      if (isComicSpread(mode)) {
        final firstTitle = find.text('First image');
        final secondTitle = find.text('Second image');
        expect(firstTitle, findsOneWidget);
        expect(secondTitle, findsOneWidget);
        expect(
          tester
              .getTopLeft(
                mode == ComicReadingMode.reverseSpread
                    ? secondTitle
                    : firstTitle,
              )
              .dy,
          lessThan(
            tester
                .getTopLeft(
                  mode == ComicReadingMode.reverseSpread
                      ? firstTitle
                      : secondTitle,
                )
                .dy,
          ),
        );
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(saved, isEmpty);
        expect(find.textContaining('Image saved'), findsNothing);

        await tester.tap(find.byTooltip('Save Image'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(secondTitle);
        await tester.pumpAndSettle();
      } else {
        expect(find.byType(AlertDialog), findsNothing);
      }

      expect(saved.single.bytes, same(_widePng));
      expect(saved.single.name, 'Second image');
      expect(library.historyReads, 0);
      expect(library.last, isNull);
      expect(source.pageRequests, isEmpty);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(library.last, isNull);
    });
  }

  testWidgets('image reader retries a failed image load', (tester) async {
    var loads = 0;
    await pump(
      tester,
      ComicReaderScreen.images(
        title: 'Work title',
        imageTitles: const ['Image'],
        loadImage: (_) async {
          loads++;
          if (loads == 1) throw StateError('temporary read failure');
          return _png;
        },
      ),
      _Library(),
      _Source(),
    );
    expect(find.byTooltip('Retry'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'single covers and an unpaired final spread image save directly',
    (tester) async {
      await StorageService.setString('comic_reading_mode', 'spread');
      for (final scenario in [
        (titles: ['Cover'], initialPage: 0, bytes: _png),
        (
          titles: ['First image', 'Second image', 'Last image'],
          initialPage: 2,
          bytes: _tallPng,
        ),
      ]) {
        final saved = <Uint8List>[];
        await pump(
          tester,
          ComicReaderScreen.images(
            title: 'Work title',
            imageTitles: scenario.titles,
            initialPage: scenario.initialPage,
            loadImage: (_) async => scenario.bytes,
            saveImage: (_, bytes, _) async => saved.add(bytes),
          ),
          _Library(),
          _Source(),
        );
        await waitForDecodedImage(tester, find.byType(Image).first);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Save Image'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(saved.single, same(scenario.bytes));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets('image reader ignores repeated save taps while saving', (
    tester,
  ) async {
    final saveGate = Completer<void>();
    var saveCalls = 0;
    await pump(
      tester,
      ComicReaderScreen.images(
        title: 'Work title',
        imageTitles: const ['Image'],
        loadImage: (_) async => _png,
        saveImage: (_, _, _) {
          saveCalls++;
          return saveGate.future;
        },
      ),
      _Library(),
      _Source(),
    );
    await waitForDecodedImage(tester, find.byType(Image).first);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    final saveButton = find.byTooltip('Save Image');
    final savePosition = tester.getCenter(saveButton);
    await tester.tap(saveButton);
    await tester.pump();
    await tester.pump();
    expect(saveCalls, 1);
    expect(find.byTooltip('Save Image'), findsNothing);
    await tester.tapAt(savePosition);
    await tester.pump();
    expect(saveCalls, 1);
    saveGate.complete();
    await tester.pumpAndSettle();
    expect(saveCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WorkImageReader loads cached local bytes and initial index', (
    tester,
  ) async {
    await StorageService.setString('comic_reading_mode', 'leftToRight');
    final directory = Directory.systemTemp.createTempSync('work-image-reader');
    addTearDown(() => directory.deleteSync(recursive: true));
    final files = <String>[];
    for (var index = 0; index < 3; index++) {
      final file = File('${directory.path}/image-$index.png');
      file.writeAsBytesSync([_png, _widePng, _tallPng][index]);
      files.add(file.path);
    }
    final source = _Source();
    await pump(
      tester,
      WorkImageReader(
        title: 'Work title',
        images: [
          for (var index = 0; index < files.length; index++)
            {
              'title': 'Image $index',
              'url': LocalFileUrl.fromPath(files[index]),
            },
        ],
        initialIndex: 1,
      ),
      _Library(),
      source,
      settle: false,
    );
    for (
      var attempt = 0;
      attempt < 24 && find.byType(Image).evaluate().isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await waitForDecodedImage(tester, find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byType(ComicReaderScreen), findsOneWidget);
    expect(readerPageValue('2/3'), findsOneWidget);
    expect(source.pageRequests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final mode in ComicReadingMode.values) {
    testWidgets('page preview jumps and resets zoom in ${mode.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await StorageService.setString('comic_reading_mode', mode.name);
      final library = _Library();
      await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('one', 'Chapter 1'),
          initialPage: 2,
        ),
        library,
        _Source(),
      );
      await waitForDecodedImage(tester, find.byType(Image).first);
      await tester.pumpAndSettle();
      final view = find.byKey(
        ValueKey(
          mode == ComicReadingMode.continuous
              ? 'comic-continuous-zoom'
              : isComicSpread(mode)
              ? 'comic-spread-zoom-1'
              : 'comic-page-zoom-2',
        ),
      );
      await doubleTapAt(tester, tester.getCenter(view));
      await tester.pumpAndSettle();
      if (mode == ComicReadingMode.continuous) {
        expect(
          tester
              .widget<Transform>(
                find.byKey(const ValueKey('comic-reader-canvas-transform')),
              )
              .transform
              .getMaxScaleOnAxis(),
          greaterThan(1),
        );
      } else {
        expect(
          tester
              .widget<InteractiveViewer>(
                find.descendant(
                  of: view,
                  matching: find.byType(InteractiveViewer),
                ),
              )
              .transformationController!
              .value
              .getMaxScaleOnAxis(),
          greaterThan(1),
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('comic-page-preview')));
      await tester.pump();
      final tile = find.byKey(const ValueKey('comic-page-preview-5'));
      final thumbnail = find.descendant(of: tile, matching: find.byType(Image));
      await waitForPreviewContent(tester, thumbnail);
      await waitForDecodedImage(tester, thumbnail);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(ComicPagePreview), findsNothing);
      expect(readerPageValue('6/8'), findsOneWidget);
      expect(library.last?.page, 5);
      expect(
        tester
            .widget<AnimatedSlide>(
              find.byKey(const ValueKey('comic-reader-bottom-controls')),
            )
            .offset,
        Offset.zero,
      );
      if (mode == ComicReadingMode.continuous) {
        expect(
          tester
              .widget<Transform>(
                find.byKey(const ValueKey('comic-reader-canvas-transform')),
              )
              .transform
              .getMaxScaleOnAxis(),
          1,
        );
      } else {
        expect(
          tester.widget<PageView>(find.byType(PageView)).controller!.page,
          comicViewIndex(5, mode),
        );
        final selectedView = find.byKey(
          ValueKey(
            isComicSpread(mode) ? 'comic-spread-zoom-2' : 'comic-page-zoom-5',
          ),
        );
        expect(
          tester
              .widget<InteractiveViewer>(
                find.descendant(
                  of: selectedView,
                  matching: find.byType(InteractiveViewer),
                ),
              )
              .transformationController!
              .value
              .getMaxScaleOnAxis(),
          1,
        );
      }
      expect(tester.takeException(), isNull);
    });

    for (final reduceMotion in [false, true]) {
      testWidgets(
        'auto page turn animates in ${mode.name}; reduced motion $reduceMotion',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await startAutoPageTurn(
            tester,
            mode: mode,
            interval: 1,
            reduceMotion: reduceMotion,
          );

          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(milliseconds: 100));
          if (mode == ComicReadingMode.continuous) {
            final view = find.byKey(const ValueKey('comic-continuous-zoom'));
            final list = find.descendant(
              of: view,
              matching: find.byType(ScrollablePositionedList),
            );
            final scrollable = find.descendant(
              of: list,
              matching: find.byType(Scrollable),
            );
            final position = tester
                .state<ScrollableState>(scrollable.first)
                .position;
            if (reduceMotion) {
              expect(position.pixels, closeTo(600, .1));
            } else {
              expect(position.pixels, inExclusiveRange(0, 600));
            }
            expect(position.pixels, lessThan(position.maxScrollExtent));
            await tester.pumpAndSettle();
            expect(position.pixels, closeTo(600, .1));
          } else {
            final controller = tester
                .widget<PageView>(find.byType(PageView))
                .controller!;
            const targetView = 1;
            if (reduceMotion) {
              expect(controller.page, targetView.toDouble());
            } else {
              expect(controller.page, inExclusiveRange(0, targetView));
            }
            await tester.pumpAndSettle();
            expect(controller.page, targetView.toDouble());
            expect(
              readerPageValue(isComicSpread(mode) ? '3/8' : '2/8'),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('reader preloads a decoded image before it is turned to', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await StorageService.setString('comic_reading_mode', 'leftToRight');
    await StorageService.setInt('comic_preload', 2);
    final nextPageBytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 153, height: 277)),
    );
    final nextPageLoadStarted = Completer<void>();
    await pump(
      tester,
      const ComicReaderScreen(
        comic: _comic,
        chapter: ComicChapter('one', 'Chapter 1'),
      ),
      _Library(),
      _Source(),
      loadImage: (page) async {
        if (page.url == 'page-2' && !nextPageLoadStarted.isCompleted) {
          nextPageLoadStarted.complete();
        }
        return page.url == 'page-2' ? nextPageBytes : _png;
      },
    );
    await tester.runAsync(() async {
      await nextPageLoadStarted.future;
    });
    final cacheKey = await MemoryImage(
      nextPageBytes,
    ).obtainKey(ImageConfiguration.empty);
    for (var frame = 0; frame < 50; frame++) {
      if (PaintingBinding.instance.imageCache
          .statusForKey(cacheKey)
          .keepAlive) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(
      PaintingBinding.instance.imageCache.statusForKey(cacheKey).keepAlive,
      isTrue,
      reason: 'Preloading must decode the image before its page is visible.',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any(
            (image) => image.image?.width == 153 && image.image?.height == 277,
          ),
      isTrue,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final mode in [
    ComicReadingMode.spread,
    ComicReadingMode.reverseSpread,
  ]) {
    testWidgets('auto page turn advances from an odd image in ${mode.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await startAutoPageTurn(
        tester,
        mode: mode,
        interval: 1,
        initialPage: 1,
        source: _ThreePageChapterSource(),
      );

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('Chapter 1'), findsOneWidget);
      expect(readerPageValue('3/3'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('Chapter 2'), findsOneWidget);
      expect(readerPageValue('1/8'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final zoomed in [false, true]) {
    for (final hasNextChapter in [true, false]) {
      for (final reduceMotion in zoomed ? [false, true] : [false]) {
        testWidgets(
          'continuous auto page turn reaches the final image; zoomed $zoomed, next chapter $hasNextChapter, reduced motion $reduceMotion',
          (tester) async {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final comic = Comic(
              source: 'fixture',
              id: 'book',
              title: 'Fixture book',
              cover: 'fixture-cover',
              chapters: [
                const ComicChapter('one', 'Chapter 1'),
                if (hasNextChapter) const ComicChapter('two', 'Chapter 2'),
              ],
            );
            await startAutoPageTurn(
              tester,
              mode: ComicReadingMode.continuous,
              interval: 1,
              comic: comic,
              initialPage: 7,
              loadImage: (_) async => _tallPng,
              reduceMotion: reduceMotion,
            );

            final auto = find.byKey(const ValueKey('comic-auto-page-turn'));
            final view = find.byKey(const ValueKey('comic-continuous-zoom'));
            final transformFinder = find.byKey(
              const ValueKey('comic-reader-canvas-transform'),
            );
            double? beforePanScale;
            double? beforePanY;
            var panned = false;
            if (zoomed) {
              await tester.tap(auto);
              await tester.pump();
              await doubleTapAt(tester, tester.getCenter(view));
              await tester.pumpAndSettle();
              final beforePan = tester
                  .widget<Transform>(transformFinder)
                  .transform
                  .clone();
              beforePanScale = beforePan.getMaxScaleOnAxis();
              beforePanY = beforePan.getTranslation().y;
              expect(beforePanScale, greaterThan(1));
              expect(
                tester
                    .getRect(find.byKey(const ValueKey('comic-page-size-7')))
                    .bottom,
                greaterThan(tester.getRect(view).bottom + 1),
              );

              await tester.tap(auto);
              await tester.pump();
            }
            for (var i = 0; zoomed && i < 12 && !panned; i++) {
              await tester.pump(const Duration(seconds: 1));
              await tester.pump(const Duration(milliseconds: 100));
              final duringPanY = tester
                  .widget<Transform>(transformFinder)
                  .transform
                  .getTranslation()
                  .y;
              await tester.pumpAndSettle();
              final afterPanY = tester
                  .widget<Transform>(transformFinder)
                  .transform
                  .getTranslation()
                  .y;
              panned = afterPanY < beforePanY! - 1;
              if (panned) {
                if (reduceMotion) {
                  expect(duringPanY, closeTo(afterPanY, .1));
                } else {
                  expect(duringPanY, lessThan(beforePanY - 1));
                  expect(duringPanY, greaterThan(afterPanY + 1));
                }
              }
            }
            if (!zoomed) {
              await tester.pump(const Duration(seconds: 1));
              await tester.pumpAndSettle();
            }
            expect(find.textContaining('Chapter 1'), findsOneWidget);
            expect(readerPageValue('8/8'), findsOneWidget);
            if (zoomed) {
              expect(panned, isTrue);
              final afterPan = tester
                  .widget<Transform>(transformFinder)
                  .transform;
              expect(
                afterPan.getMaxScaleOnAxis(),
                closeTo(beforePanScale!, .01),
              );
              expect(
                tester
                    .getRect(find.byKey(const ValueKey('comic-page-size-7')))
                    .bottom,
                lessThanOrEqualTo(tester.getRect(view).bottom + 1),
              );
            }
            final list = find.descendant(
              of: view,
              matching: find.byType(ScrollablePositionedList),
            );
            final scrollable = find.descendant(
              of: list,
              matching: find.byType(Scrollable),
            );
            final position = tester
                .state<ScrollableState>(scrollable.first)
                .position;
            expect(position.pixels, closeTo(position.maxScrollExtent, .1));

            await tester.pump(const Duration(seconds: 1));
            await tester.pump();
            if (hasNextChapter) {
              expect(find.textContaining('Chapter 2'), findsOneWidget);
              expect(find.byTooltip('Pause'), findsOneWidget);
            } else {
              expect(find.textContaining('Chapter 1'), findsOneWidget);
              expect(find.byTooltip('Auto page turn'), findsOneWidget);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('auto page turn uses its saved interval and stops at the end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await startAutoPageTurn(tester);

    await tester.pump(const Duration(seconds: 4, milliseconds: 999));
    expect(readerPageValue('1/8'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(readerPageValue('2/8'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('comic-auto-page-turn')));
    await tester.pump();
    await StorageService.setInt('comic_auto_page_interval', 2);
    await tester.tap(find.byKey(const ValueKey('comic-auto-page-turn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1, milliseconds: 999));
    expect(readerPageValue('2/8'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(readerPageValue('3/8'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('comic-auto-page-turn')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(readerPageValue('3/8'), findsOneWidget);
    expect(find.byTooltip('Auto page turn'), findsOneWidget);
  });

  testWidgets(
    'auto page turn stops at the final page without another chapter',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const oneChapterComic = Comic(
        source: 'fixture',
        id: 'book',
        title: 'Fixture book',
        cover: 'fixture-cover',
        chapters: [ComicChapter('one', 'Chapter 1')],
      );
      await startAutoPageTurn(
        tester,
        comic: oneChapterComic,
        initialPage: 7,
        interval: 1,
      );

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(readerPageValue('8/8'), findsOneWidget);
      expect(find.byTooltip('Auto page turn'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'auto page turn stops on reader failure and can restart manually',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = _Source()..failedChapter = 'two';
      await startAutoPageTurn(
        tester,
        initialPage: 7,
        interval: 1,
        source: source,
      );

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);

      source.failedChapter = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Chapter 2'), findsOneWidget);
      expect(find.byTooltip('Auto page turn'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('auto page turn saves interval changes only on Save', (
    tester,
  ) async {
    await StorageService.setInt('comic_auto_page_interval', 4);
    await pump(
      tester,
      const ComicReaderSettingsScreen(),
      _Library(),
      _Source(),
    );

    await tester.tap(find.text('Auto page turn interval'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('4 seconds'),
      ),
      findsOneWidget,
    );
    await tester.drag(find.byType(Slider), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Slider>(find.byType(Slider)).value.round(),
      greaterThan(4),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(StorageService.getInt('comic_auto_page_interval'), 4);

    await tester.tap(find.text('Auto page turn interval'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Slider), const Offset(120, 0));
    await tester.pumpAndSettle();
    final selected = tester.widget<Slider>(find.byType(Slider)).value.round();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(StorageService.getInt('comic_auto_page_interval'), selected);
  });

  testWidgets('auto page turn stops when reader is covered or backgrounded', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await startAutoPageTurn(tester, interval: 1);

    await tester.tap(find.byTooltip('Reader settings'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(readerPageValue('1/8'), findsOneWidget);
    expect(find.byTooltip('Auto page turn'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('comic-auto-page-turn')));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(readerPageValue('1/8'), findsOneWidget);
    expect(find.byTooltip('Auto page turn'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('comic-auto-page-turn')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'reader route slides and restores details; reduced motion $reduceMotion',
      (tester) async {
        final library = _Library()
          ..last = ComicProgress(_comic, 'one', 3, DateTime.now());
        await pump(
          tester,
          const ComicDetailScreen(comic: _comic),
          library,
          _Source(),
          theme: AppTheme.lightTheme(null),
          reduceMotion: reduceMotion,
        );
        await tester.tap(find.text('Continue reading'));
        await tester.pump();
        await tester.pump();
        final reader = find.byType(ComicReaderScreen);
        final route = ModalRoute.of(tester.element(reader))!;
        expect(route.transitionDuration, const Duration(milliseconds: 300));
        await tester.pump(route.transitionDuration ~/ 2);
        expect(tester.widget<ComicReaderScreen>(reader).initialPage, 3);
        expect(
          tester.getTopLeft(reader).dx,
          reduceMotion ? 0 : closeTo(800 * (1 - Curves.ease.transform(.5)), .1),
        );
        await tester.pumpAndSettle();
        Navigator.of(tester.element(reader)).pop();
        await tester.pumpAndSettle();
        expect(find.byType(ComicReaderScreen), findsNothing);
        expect(find.byType(ComicDetailScreen), findsOneWidget);
        expect(library.last?.chapterId, 'one');
        expect(tester.takeException(), isNull);
      },
    );
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
    expect(find.byType(Slider), findsNothing);
    expect(find.byKey(const ValueKey('comic-page-preview')), findsOneWidget);
    expect(tester.getRect(find.byType(FutureBuilder<Uint8List>).first), before);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  testWidgets('spread zoom follows its focal point and interrupts smoothly', (
    tester,
  ) async {
    await StorageService.setString('comic_reading_mode', 'spread');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

    final view = find.byKey(const ValueKey('comic-spread-zoom-0'));
    expect(
      find.descendant(
        of: view,
        matching: find.byType(FutureBuilder<Uint8List>),
      ),
      findsNWidgets(2),
    );
    final rect = tester.getRect(view);
    final focal = Offset(
      rect.left + rect.width * .75,
      rect.top + rect.height * .35,
    );
    await doubleTapAt(tester, focal);
    await tester.pump(const Duration(milliseconds: 50));
    final transform = tester
        .widget<InteractiveViewer>(
          find.descendant(of: view, matching: find.byType(InteractiveViewer)),
        )
        .transformationController!;
    final firstScale = transform.value.getMaxScaleOnAxis();
    expect(firstScale, greaterThan(1));
    expect(firstScale, lessThan(1.75));
    expect(transform.value.getTranslation().x, lessThan(0));

    final touch = await tester.startGesture(rect.center);
    await tester.pump(const Duration(milliseconds: 100));
    final interruptedScale = transform.value.getMaxScaleOnAxis();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      transform.value.getMaxScaleOnAxis(),
      closeTo(interruptedScale, .001),
    );
    await touch.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));

    await doubleTapAt(tester, rect.center);
    final resetStart = transform.value.getMaxScaleOnAxis();
    expect(resetStart, lessThan(interruptedScale));
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), closeTo(1, .001));
    expect(transform.value.getTranslation().x, closeTo(0, .01));
    expect(transform.value.getTranslation().y, closeTo(0, .01));
  });

  testWidgets('continuous zoom covers the strip and preserves list gestures', (
    tester,
  ) async {
    await StorageService.setString('comic_reading_mode', 'continuous');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

    final view = find.byKey(const ValueKey('comic-continuous-zoom'));
    final list = find.descendant(
      of: view,
      matching: find.byType(ScrollablePositionedList),
    );
    expect(list, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(readerPageValue('1/8'), findsOneWidget);
    await tester.drag(list, const Offset(0, -524));
    await tester.pumpAndSettle();
    expect(readerPageValue('1/8'), findsOneWidget);

    await doubleTapAt(tester, tester.getCenter(view));
    await tester.pumpAndSettle();
    final canvas = find.byKey(const ValueKey('comic-reader-canvas-transform'));
    var transform = tester.widget<Transform>(canvas).transform;
    expect(transform.getMaxScaleOnAxis(), closeTo(1.75, .01));
    expect(readerPageValue('2/8'), findsOneWidget);

    final beforePan = transform.getTranslation().x;
    await tester.drag(list, const Offset(-40, 0));
    await tester.pumpAndSettle();
    transform = tester.widget<Transform>(canvas).transform;
    expect(transform.getTranslation().x, lessThan(beforePan));

    expect(
      tester.widget<ScrollablePositionedList>(list).physics,
      isA<BouncingScrollPhysics>(),
    );
    await tester.drag(list, const Offset(0, -650));
    await tester.pumpAndSettle();
    await tester.drag(list, const Offset(0, -650));
    await tester.pumpAndSettle();
    expect(readerPageValue('3/8'), findsOneWidget);

    final beforePinch = transform.getMaxScaleOnAxis();
    final center = tester.getCenter(view);
    final first = await tester.startGesture(
      Offset(center.dx - 20, center.dy),
      pointer: 1,
    );
    final second = await tester.startGesture(
      Offset(center.dx + 20, center.dy),
      pointer: 2,
    );
    await tester.pump();
    expect(
      tester.widget<ScrollablePositionedList>(list).physics,
      isA<NeverScrollableScrollPhysics>(),
    );
    await first.moveBy(const Offset(-20, 0));
    await second.moveBy(const Offset(20, 0));
    await tester.pump();
    transform = tester.widget<Transform>(canvas).transform;
    expect(transform.getMaxScaleOnAxis(), greaterThan(beforePinch));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(
      tester.widget<ScrollablePositionedList>(list).physics,
      isA<BouncingScrollPhysics>(),
    );
    await doubleTapAt(tester, tester.getCenter(view));
    await tester.pumpAndSettle();
    transform = tester.widget<Transform>(canvas).transform;
    expect(transform.getMaxScaleOnAxis(), closeTo(1, .01));

    await doubleTapAt(tester, tester.getCenter(view));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.widget<Transform>(canvas).transform.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    await tester.tap(find.byTooltip('Choose chapters'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Chapter 2'));
    await tester.pumpAndSettle();
    expect(readerPageValue('1/8'), findsOneWidget);
    expect(
      tester.widget<Transform>(canvas).transform.getMaxScaleOnAxis(),
      closeTo(1, .01),
    );
  });

  testWidgets('single-page zoom cycles PhotoView scales around the center', (
    tester,
  ) async {
    await StorageService.setString('comic_reading_mode', 'vertical');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

    final view = find.byKey(const ValueKey('comic-page-zoom-0'));
    final rect = tester.getRect(view);
    final center = rect.center;
    await doubleTapAt(tester, center);
    final interactiveViewer = tester.widget<InteractiveViewer>(
      find.descendant(of: view, matching: find.byType(InteractiveViewer)),
    );
    final transform = interactiveViewer.transformationController!;
    await tester.pumpAndSettle();
    final contained = math.min(rect.width / 100, rect.height / 160);
    final covering = math.max(rect.width / 100, rect.height / 160);
    expect(
      transform.value.getMaxScaleOnAxis(),
      closeTo(covering / contained, .01),
    );
    expect(
      transform.value.getTranslation().x,
      closeTo(rect.width / 2 * (1 - covering / contained), .1),
    );

    await tester.drag(view, const Offset(600, 0));
    await tester.pumpAndSettle();
    final coverTranslation = transform.value.getTranslation().x;
    expect(coverTranslation, lessThanOrEqualTo(.01));
    expect(
      coverTranslation,
      greaterThanOrEqualTo(
        rect.width * (1 - transform.value.getMaxScaleOnAxis()) - .1,
      ),
    );
    await tester.fling(view, const Offset(600, 0), 2000);
    await tester.pumpAndSettle();
    final flingTranslation = transform.value.getTranslation().x;
    expect(flingTranslation, lessThanOrEqualTo(.01));
    expect(
      flingTranslation,
      greaterThanOrEqualTo(
        rect.width * (1 - transform.value.getMaxScaleOnAxis()) - .1,
      ),
    );

    await doubleTapAt(tester, center);
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), closeTo(1 / contained, .01));

    final first = await tester.startGesture(
      Offset(center.dx - 25, center.dy),
      pointer: 1,
    );
    final second = await tester.startGesture(
      Offset(center.dx + 25, center.dy),
      pointer: 2,
    );
    await first.moveBy(const Offset(-20, 0));
    await tester.pump();
    await second.moveBy(const Offset(20, 0));
    await tester.pump();
    await first.moveBy(const Offset(-4, 0));
    await second.moveBy(const Offset(4, 0));
    await tester.pump();
    expect(transform.value.getMaxScaleOnAxis(), greaterThan(1 / contained));
    expect(transform.value.getMaxScaleOnAxis(), lessThan(1));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    await doubleTapAt(tester, center);
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), closeTo(1, .01));
  });

  testWidgets('single-page covering zoom supports a target above five', (
    tester,
  ) async {
    await StorageService.setString('comic_reading_mode', 'leftToRight');
    final tallImage = Uint8List.fromList(
      img.encodePng(img.Image(width: 100, height: 1800)),
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      const ComicReaderScreen(
        comic: _comic,
        chapter: ComicChapter('one', 'Chapter 1'),
      ),
      _Library(),
      _Source(),
      loadImage: (_) async => tallImage,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();

    final view = find.byKey(const ValueKey('comic-page-zoom-0'));
    final rect = tester.getRect(view);
    await doubleTapAt(tester, rect.center);
    final transform = tester
        .widget<InteractiveViewer>(
          find.descendant(of: view, matching: find.byType(InteractiveViewer)),
        )
        .transformationController!;
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), greaterThan(5));
  });

  testWidgets(
    'single-page reduced motion and double-tap preference are honored',
    (tester) async {
      await StorageService.setString('comic_reading_mode', 'leftToRight');
      await StorageService.setBool('comic_double_tap_zoom', false);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('one', 'Chapter 1'),
        ),
        _Library(),
        _Source(),
        reduceMotion: true,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      final disabledView = find.byKey(const ValueKey('comic-page-zoom-0'));
      await doubleTapAt(tester, tester.getCenter(disabledView));
      var transform = tester
          .widget<InteractiveViewer>(
            find.descendant(
              of: disabledView,
              matching: find.byType(InteractiveViewer),
            ),
          )
          .transformationController!;
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1, .001));

      await StorageService.setBool('comic_double_tap_zoom', true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await pump(
        tester,
        const ComicReaderScreen(
          comic: _comic,
          chapter: ComicChapter('one', 'Chapter 1'),
        ),
        _Library(),
        _Source(),
        reduceMotion: true,
      );
      final reducedView = find.byKey(const ValueKey('comic-page-zoom-0'));
      await doubleTapAt(tester, tester.getCenter(reducedView));
      transform = tester
          .widget<InteractiveViewer>(
            find.descendant(
              of: reducedView,
              matching: find.byType(InteractiveViewer),
            ),
          )
          .transformationController!;
      expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
      expect(tester.takeException(), isNull);
    },
  );

  for (final resizeWindow in [false, true]) {
    for (final reduceMotion in [false, true]) {
      for (final withAudio in [false, true]) {
        testWidgets(
          'reader keeps detail stable across system bars (resize: $resizeWindow, reduced: $reduceMotion, audio: $withAudio)',
          (tester) async {
            tester.view.physicalSize = const Size(390, 796);
            tester.view.devicePixelRatio = 1;
            tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
            tester.view.viewPadding = const FakeViewPadding(
              top: 24,
              bottom: 24,
            );
            addTearDown(tester.view.reset);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              (call) async {
                if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
                  final immersive =
                      call.arguments == 'SystemUiMode.immersiveSticky';
                  void deliverInsets(int remainingFrames) {
                    tester.binding.addPostFrameCallback((_) {
                      if (remainingFrames > 0) {
                        deliverInsets(remainingFrames - 1);
                        tester.binding.scheduleFrame();
                        return;
                      }
                      final insets = immersive
                          ? const FakeViewPadding()
                          : const FakeViewPadding(top: 24, bottom: 24);
                      tester.view.padding = insets;
                      tester.view.viewPadding = insets;
                      if (resizeWindow) {
                        tester.view.physicalSize = immersive
                            ? const Size(390, 844)
                            : const Size(390, 796);
                      }
                    });
                  }

                  deliverInsets(immersive ? 0 : 3);
                }
                return null;
              },
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(SystemChannels.platform, null),
            );
            await pump(
              tester,
              const Scaffold(body: ComicGrid(comics: [_comic])),
              _Library(),
              _Source(),
              reduceMotion: reduceMotion,
              track: withAudio
                  ? const AudioTrack(
                      id: 'return-track',
                      title: 'Audio',
                      url: 'https://example.invalid/audio.mp3',
                    )
                  : null,
            );
            await waitForComicCardImage(tester, 'Fixture book');
            await tester.tap(find.text('Fixture book'));
            await tester.pumpAndSettle();

            final detail = find.byType(ComicDetailScreen, skipOffstage: false);
            final detailSize = MediaQuery.sizeOf(tester.element(detail));
            final detailPadding = MediaQuery.paddingOf(tester.element(detail));
            final detailScaffold = find.descendant(
              of: detail,
              matching: find.byType(Scaffold),
            );
            Rect rectInDetailScaffold(Finder target) {
              final scaffold =
                  tester.renderObject(detailScaffold.first) as RenderBox;
              final cover = tester.renderObject(target) as RenderBox;
              return cover.localToGlobal(Offset.zero, ancestor: scaffold) &
                  cover.size;
            }

            Rect coverInDetailScaffold() => rectInDetailScaffold(
              find.byKey(const ValueKey('comic-detail-cover')),
            );
            final title = find.descendant(
              of: detail,
              matching: find.byType(WorkTitleHeader),
            );
            final miniPlayer = find.descendant(
              of: detail,
              matching: find.byType(MiniPlayer),
            );

            final scaffoldCoverRect = coverInDetailScaffold();
            final globalCoverTop = tester
                .getTopLeft(find.byKey(const ValueKey('comic-detail-cover')))
                .dy;
            final titleRect = rectInDetailScaffold(title);
            final miniPlayerRect = withAudio
                ? rectInDetailScaffold(miniPlayer)
                : null;
            await tester.tap(find.text('Start reading'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 60));
            await tester.pump();

            final reader = find.byType(ComicReaderScreen);
            expect(reader, findsOneWidget);
            final route = ModalRoute.of(tester.element(reader))!;
            if (!reduceMotion) expect(route.animation!.value, lessThan(1));
            if (!reduceMotion) {
              expect(MediaQuery.sizeOf(tester.element(detail)), detailSize);
              expect(coverInDetailScaffold(), scaffoldCoverRect);
              expect(
                MediaQuery.paddingOf(tester.element(detail)),
                detailPadding,
              );
            }
            await tester.pumpAndSettle();
            expect(
              MediaQuery.paddingOf(tester.element(detail)),
              EdgeInsets.zero,
            );
            final readerImage = find
                .descendant(of: reader, matching: find.byType(Image))
                .first;
            final readerScaffold = find
                .descendant(of: reader, matching: find.byType(Scaffold))
                .first;
            Rect readerImageRect() {
              final image = tester.renderObject<RenderBox>(readerImage);
              final scaffold = tester.renderObject<RenderBox>(readerScaffold);
              return image.localToGlobal(Offset.zero, ancestor: scaffold) &
                  image.size;
            }

            final readingRect = readerImageRect();
            Navigator.of(tester.element(reader)).pop();
            for (var frame = 0; frame < 40; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              if (reader.evaluate().isNotEmpty) {
                expect(
                  readerImageRect(),
                  readingRect,
                  reason:
                      'reading image moved within its scaffold during exit frame $frame',
                );
              }
              expect(
                coverInDetailScaffold(),
                scaffoldCoverRect,
                reason: 'detail cover moved on return frame $frame',
              );
              expect(
                tester
                    .getTopLeft(
                      find.byKey(const ValueKey('comic-detail-cover')),
                    )
                    .dy,
                closeTo(globalCoverTop, 0.01),
                reason: 'detail cover shifted on screen at return frame $frame',
              );
              expect(rectInDetailScaffold(title), titleRect);
              if (withAudio) {
                expect(rectInDetailScaffold(miniPlayer), miniPlayerRect);
              }
            }
            await tester.pumpAndSettle();
            expect(MediaQuery.paddingOf(tester.element(detail)), detailPadding);
            expect(coverInDetailScaffold(), scaffoldCoverRect);
            tester.view.padding = const FakeViewPadding(top: 30, bottom: 20);
            tester.view.viewPadding = const FakeViewPadding(
              top: 30,
              bottom: 20,
            );
            tester.view.physicalSize = const Size(390, 820);
            await tester.pump();
            expect(tester.getSize(detailScaffold.first), const Size(390, 820));
            expect(
              MediaQuery.paddingOf(tester.element(detailScaffold.first)),
              const EdgeInsets.only(top: 30, bottom: 20),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final systemGesture in [false, true]) {
    testWidgets(
      'reader return keeps painted pages and cover at their original height (gesture: $systemGesture)',
      (tester) async {
        final modes = <Object?>[];
        final prematureRestores = <double>[];
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.reset);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method != 'SystemChrome.setEnabledSystemUIMode') {
              return null;
            }
            modes.add(call.arguments);
            final immersive = call.arguments == 'SystemUiMode.immersiveSticky';
            if (!immersive) {
              final reader = find.byType(ComicReaderScreen);
              if (reader.evaluate().isNotEmpty) {
                final progress = ModalRoute.of(
                  tester.element(reader),
                )!.animation!.value;
                if (progress > 0) prematureRestores.add(progress);
              }
            }
            void deliverInsets(int step) {
              tester.binding.addPostFrameCallback((_) {
                final padding = immersive ? 0.0 : step * 4.0;
                tester.view.padding = FakeViewPadding(
                  top: padding,
                  bottom: padding,
                );
                tester.view.viewPadding = FakeViewPadding(
                  top: padding,
                  bottom: padding,
                );
                tester.view.physicalSize = Size(390, 892 - padding * 2);
                if (!immersive && step < 6) deliverInsets(step + 1);
                tester.binding.scheduleFrame();
              });
            }

            deliverInsets(0);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final marker = img.Image(width: 100, height: 160);
        img.fill(marker, color: img.ColorRgb8(255, 0, 255));
        final bytes = Uint8List.fromList(img.encodePng(marker));
        final pageMarker = img.Image(width: 100, height: 160);
        img.fill(pageMarker, color: img.ColorRgb8(0, 255, 0));
        final pageBytes = Uint8List.fromList(img.encodePng(pageMarker));
        await pump(
          tester,
          const Scaffold(body: ComicGrid(comics: [_comic])),
          _Library(),
          _Source(),
          loadImage: (page) async =>
              page.url == 'fixture-cover' ? bytes : pageBytes,
          theme: AppTheme.lightTheme(null),
        );
        await waitForComicCardImage(tester, 'Fixture book');
        await tester.tap(find.text('Fixture book'));
        await tester.pumpAndSettle();
        await waitForDecodedImage(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('comic-detail-cover')),
            matching: find.byType(Image),
          ),
        );

        Future<int?> paintedCoverTop({bool reader = false}) async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('app-paint')),
          );
          return tester.runAsync<int?>(() async {
            final image = await boundary.toImage();
            final data = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final width = image.width;
            final height = image.height;
            image.dispose();
            for (var y = 0; y < height; y++) {
              var matching = 0;
              for (var x = 0; x < width; x++) {
                final offset = (y * width + x) * 4;
                final r = data.getUint8(offset);
                final g = data.getUint8(offset + 1);
                final b = data.getUint8(offset + 2);
                if (reader
                    ? g > 80 && g > r * 2 && g > b * 2
                    : r > 80 && b > 80 && r > g * 2 && b > g * 2) {
                  matching++;
                }
              }
              if (matching > 20) return y;
            }
            return null;
          });
        }

        final top = await paintedCoverTop();
        expect(top, isNotNull);
        await tester.tap(find.text('Start reading'));
        await tester.pumpAndSettle();
        await waitForDecodedImage(
          tester,
          find
              .descendant(
                of: find.byType(ComicReaderScreen),
                matching: find.byType(Image),
              )
              .first,
        );
        final readerTop = await paintedCoverTop(reader: true);
        expect(readerTop, isNotNull);
        if (systemGesture) {
          Future<void> backEvent(
            String method, [
            Map<String, Object>? arguments,
          ]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'flutter/backgesture',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, arguments),
            ),
            (_) {},
          );
          await backEvent('startBackGesture', {
            'touchOffset': [5.0, 300.0],
            'progress': 0.0,
            'swipeEdge': 0,
          });
          await tester.pump();
          expect(find.byType(ComicReaderScreen), findsOneWidget);
          await backEvent('updateBackGestureProgress', {
            'touchOffset': [100.0, 340.0],
            'progress': 0.35,
            'swipeEdge': 0,
          });
          await tester.pumpAndSettle();
          await backEvent('cancelBackGesture');
          await tester.pumpAndSettle();
          expect(find.byType(ComicReaderScreen), findsOneWidget);
          expect(modes.last, 'SystemUiMode.immersiveSticky');
          await backEvent('startBackGesture', {
            'touchOffset': [5.0, 300.0],
            'progress': 0.0,
            'swipeEdge': 0,
          });
          await tester.pump();
          await backEvent('commitBackGesture');
        } else {
          Navigator.of(tester.element(find.byType(ComicReaderScreen))).pop();
        }
        var visibleFrames = 0;
        for (var frame = 0; frame < 40; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (frame == 0) {
            expect(find.byType(ComicReaderScreen), findsOneWidget);
          }
          final actual = await paintedCoverTop();
          final actualReader = await paintedCoverTop(reader: true);
          if (actualReader != null) {
            expect(
              actualReader,
              closeTo(readerTop!, 1),
              reason:
                  'painted reader shifted vertically at return frame $frame',
            );
          }
          if (actual != null) {
            visibleFrames++;
            expect(
              actual,
              closeTo(top!, 1),
              reason: 'painted return frame $frame',
            );
          }
        }
        expect(visibleFrames, greaterThan(10));
        expect(
          prematureRestores,
          isEmpty,
          reason:
              'native window mode must stay unchanged while the reader is visible',
        );
        expect(
          modes.where((mode) => mode == 'SystemUiMode.edgeToEdge'),
          hasLength(1),
        );
      },
    );
  }

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
    await tester.tap(find.text('Start reading'));
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

  testWidgets('cancelled reader return restores immersive reading', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 796);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);
    final modes = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          modes.add(call.arguments);
          final immersive = call.arguments == 'SystemUiMode.immersiveSticky';
          tester.binding.addPostFrameCallback((_) {
            tester.view.physicalSize = Size(390, immersive ? 844 : 796);
            tester.view.padding = immersive
                ? const FakeViewPadding()
                : const FakeViewPadding(top: 24, bottom: 24);
            tester.view.viewPadding = tester.view.padding;
          });
          tester.binding.scheduleFrame();
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
    await tester.tap(find.text('Start reading'));
    await tester.pumpAndSettle();
    final reader = find.byType(ComicReaderScreen);
    final route = ModalRoute.of(tester.element(reader))! as PageRoute<void>;
    route.handleStartBackGesture(progress: 1);
    route.handleUpdateBackGestureProgress(progress: 0);
    await tester.pump();
    route.handleCancelBackGesture();
    await tester.pumpAndSettle();
    expect(reader, findsOneWidget);
    expect(route.animation!.status, AnimationStatus.completed);
    expect(modes.last, 'SystemUiMode.immersiveSticky');
    expect(modes, isNot(contains('SystemUiMode.edgeToEdge')));
    tester.view.physicalSize = const Size(390, 900);
    await tester.pump();
    expect(
      tester.getSize(
        find.descendant(of: reader, matching: find.byType(Scaffold)),
      ),
      const Size(390, 900),
    );
    Navigator.of(tester.element(reader)).pop();
    await tester.pump();
    expect(modes.last, 'SystemUiMode.immersiveSticky');
    await tester.pumpAndSettle();
    expect(modes.last, 'SystemUiMode.edgeToEdge');
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

  testWidgets('comic settings opens and persists reader settings', (
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

    await tester.tap(find.text('Reader settings'));
    await tester.pumpAndSettle();
    expect(find.byType(ComicReaderSettingsScreen), findsOneWidget);
    await tester.tap(find.text('Reading mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Left to right'));
    await tester.pumpAndSettle();
    expect(
      container.read(comicReadingModeProvider),
      ComicReadingMode.leftToRight,
    );
    expect(StorageService.getString('comic_reading_mode'), 'leftToRight');

    for (final (title, key) in [
      ('Tap edges to turn pages', 'comic_tap_to_turn'),
      ('Double-tap to zoom', 'comic_double_tap_zoom'),
      ('Keep awake while reading', 'comic_keep_awake'),
    ]) {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(StorageService.getBool(key), isFalse);
    }
    await tester.tap(find.text('Preload pages'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5'));
    await tester.pumpAndSettle();
    expect(StorageService.getInt('comic_preload'), 5);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reader settings'));
    await tester.pumpAndSettle();
    expect(find.text('Left to right'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(
      tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .every((tile) => !tile.value),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader settings apply gestures without losing the page', (
    tester,
  ) async {
    await StorageService.setString('comic_reading_mode', 'leftToRight');
    await StorageService.setBool('comic_double_tap_zoom', false);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      const ComicReaderScreen(
        comic: _comic,
        chapter: ComicChapter('one', 'Chapter 1'),
        initialPage: 3,
      ),
      _Library(),
      _Source(),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(readerPageValue('4/8'), findsOneWidget);

    await tester.tap(find.byTooltip('Reader settings'));
    await tester.pumpAndSettle();
    expect(find.byType(ComicReaderSettingsScreen), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Double-tap to zoom'),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.text('Double-tap to zoom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tap edges to turn pages'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(readerPageValue('4/8'), findsOneWidget);

    final view = find.byKey(const ValueKey('comic-page-zoom-3'));
    final transform = tester
        .widget<InteractiveViewer>(
          find.descendant(of: view, matching: find.byType(InteractiveViewer)),
        )
        .transformationController!;
    await doubleTapAt(tester, tester.getCenter(view));
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
    expect(StorageService.getBool('comic_double_tap_zoom'), isTrue);

    await tester.tapAt(const Offset(25, 420));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(readerPageValue('4/8'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedSlide>(
            find.byKey(const ValueKey('comic-reader-top-controls')),
          )
          .offset,
      const Offset(0, -1),
    );
    expect(StorageService.getBool('comic_tap_to_turn'), isFalse);
    expect(tester.takeException(), isNull);
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

  testWidgets('comic source login form opens in debug mode', (tester) async {
    final source = PicaSource(ComicHttp('picacg'));
    addTearDown(source.http.dispose);
    await pump(
      tester,
      ComicSourceSettingsScreen(source: source),
      _Library(),
      _Source(),
    );

    expect(find.byType(TextField), findsNWidgets(4));
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
    expect(find.byType(CommonOptionDialog<int>), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);
    expect(find.text('60'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    final selectedOption = tester.widget<RadioListTile<int>>(
      find.ancestor(
        of: find.text('40'),
        matching: find.byType(RadioListTile<int>),
      ),
    );
    expect(selectedOption.selected, isTrue);
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

  testWidgets('unknown comic total jumps only within visited pages', (
    tester,
  ) async {
    final jumpedPages = <int>[];
    await pump(
      tester,
      Scaffold(
        body: PaginationBar(
          currentPage: 2,
          pageSize: 40,
          totalCount: null,
          jumpMaxPage: 5,
          hasMore: true,
          isLoading: false,
          onPreviousPage: () {},
          onNextPage: () {},
          onGoToPage: jumpedPages.add,
        ),
      ),
      _Library(),
      _Source(),
    );

    await tester.tap(find.byIcon(Icons.edit_location_alt));
    await tester.pumpAndSettle();
    expect(find.text('Page (1-5)'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '6');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Jump'),
      ),
    );
    expect(jumpedPages, isEmpty);
    await tester.enterText(find.byType(TextField), '5');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Jump'),
      ),
    );

    expect(jumpedPages, [5]);
  });

  for (final layout in [LayoutType.bigGrid, LayoutType.smallGrid]) {
    for (final search in [false, true]) {
      testWidgets(
        'comic long paging error scrolls without jumping ($layout, search=$search)',
        (tester) async {
          await StorageService.setString('comic_layout_type', layout.name);
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final comics = List.generate(
            40,
            (i) => Comic(
              source: 'fixture',
              id: 'error-$i',
              title: 'Book $i',
              cover: 'error-cover-$i',
            ),
          );
          final gate = Completer<ComicResult>();
          final _Source source;
          if (search) {
            source = _PaginatedSearchSource(comics, [])..secondPageGate = gate;
          } else {
            source = _PaginatedSource(comics, [])..secondPageGate = gate;
          }
          await pump(
            tester,
            search
                ? const ComicSearchScreen(
                    initialSource: 'fixture',
                    initialQuery: 'book',
                  )
                : const ComicScreen(),
            _Library(),
            source,
            textScale: 1.5,
          );
          final scrollable = find.descendant(
            of: find.byType(ComicGrid),
            matching: find.byType(Scrollable),
          );
          final position = tester.state<ScrollableState>(scrollable).position;
          await tester.scrollUntilVisible(
            find.text('Next').hitTestable(),
            500,
            scrollable: scrollable,
          );
          await tester.tap(find.text('Next'));
          await tester.pump();
          gate.completeError(
            ComicSourceException(
              List.generate(
                160,
                (i) => 'Paging failure $i: source unavailable',
              ).join('\n'),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(MaterialBanner), findsOneWidget);
          for (var step = 0; step < 15; step++) {
            final before = position.pixels;
            await tester.drag(scrollable, const Offset(0, -240));
            await tester.pumpAndSettle();
            expect(position.pixels, greaterThanOrEqualTo(before));
          }
          tester.view.physicalSize = const Size(844, 390);
          await tester.pumpAndSettle();
          final before = position.pixels;
          await tester.drag(scrollable, const Offset(0, -240));
          await tester.pumpAndSettle();
          expect(position.pixels, greaterThanOrEqualTo(before));
          expect(
            tester.widget<ComicGrid>(find.byType(ComicGrid)).comics.first.id,
            'error-0',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
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

        expect(firstCoverReloadStarted.isCompleted, isFalse);
        expect(firstCoverRequests, 1);
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
        final next = find.text('Next');
        expect(next.hitTestable(), findsNothing);
        await tester.scrollUntilVisible(
          next.hitTestable(),
          400,
          scrollable: scrollable,
        );
        expect(next.hitTestable(), findsOneWidget);
        await tester.tap(next);
        await pumpFrames(tester);
        expect(tester.widget<ComicGrid>(grid).comics.first.id, 'first-40');
        expect(source.cursors, [null, 'second-page']);
        final previous = find.text('Previous');
        expect(previous.hitTestable(), findsNothing);
        await tester.scrollUntilVisible(
          previous.hitTestable(),
          400,
          scrollable: scrollable,
        );
        expect(
          tester.widget<PaginationBar>(find.byType(PaginationBar)).isLoading,
          isFalse,
        );
        await tester.tap(previous);
        await pumpFrames(tester);
        expect(tester.widget<ComicGrid>(grid).comics.first.id, 'first-0');
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

    final pagination = find.byType(PaginationBar);
    final next = find.text('Next');
    final grid = find.byType(ComicGrid);
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    expect(next.hitTestable(), findsNothing);
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    expect(next.hitTestable(), findsOneWidget);
    await tester.tap(next);
    await pumpFrames(tester);
    expect(tester.widget<ComicGrid>(grid).comics.first.id, 'size-first-40');
    expect(find.text('Previous').hitTestable(), findsNothing);
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, closeTo(0, 0.1));

    final pageTwo = find.descendant(of: pagination, matching: find.text('2'));
    await tester.scrollUntilVisible(
      pageTwo.hitTestable(),
      400,
      scrollable: scrollable,
    );
    expect(tester.widget<PaginationBar>(pagination).isLoading, isFalse);
    expect(
      find.descendant(of: pagination, matching: find.text('2')),
      findsOneWidget,
    );
    expect(source.cursors, [null, 'second-page']);

    position.jumpTo(position.pixels.clamp(1, 300));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));

    container.read(comicPageSizeProvider.notifier).setPageSize(20);
    await tester.pumpAndSettle();

    final resetPosition = tester.state<ScrollableState>(scrollable).position;
    expect(resetPosition.pixels, closeTo(0, 0.1));
    expect(find.text('Size first 0'), findsOneWidget);
    final pageOne = find.descendant(of: pagination, matching: find.text('1'));
    await tester.scrollUntilVisible(
      pageOne.hitTestable(),
      400,
      scrollable: scrollable,
    );
    expect(pageOne, findsOneWidget);
    expect(find.byIcon(Icons.edit_location_alt), findsNothing);
    expect(source.cursors, [null, 'second-page', null]);
  });

  testWidgets('comic jump returns to a page that was already displayed', (
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
          id: 'jump-first-$i',
          title: 'Jump first $i',
          cover: 'jump-first-cover-$i',
        ),
      ),
      List.generate(
        24,
        (i) => Comic(
          source: 'fixture',
          id: 'jump-second-$i',
          title: 'Jump second $i',
          cover: 'jump-second-cover-$i',
        ),
      ),
    );
    await pump(tester, const ComicScreen(), _Library(), source);

    final grid = find.byType(ComicGrid);
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    expect(find.byIcon(Icons.edit_location_alt), findsNothing);
    final next = find.text('Next');
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    expect(find.byIcon(Icons.edit_location_alt), findsNothing);
    await tester.tap(next);
    await pumpFrames(tester);
    expect(tester.widget<ComicGrid>(grid).comics.first.id, 'jump-first-40');

    final previous = find.text('Previous');
    await tester.scrollUntilVisible(
      previous.hitTestable(),
      400,
      scrollable: scrollable,
    );
    expect(find.byIcon(Icons.edit_location_alt).hitTestable(), findsOneWidget);
    await tester.tap(previous);
    await pumpFrames(tester);
    expect(tester.widget<ComicGrid>(grid).comics.first.id, 'jump-first-0');

    final jump = find.byIcon(Icons.edit_location_alt);
    await tester.scrollUntilVisible(
      jump.hitTestable(),
      400,
      scrollable: scrollable,
    );
    await tester.tap(jump);
    await tester.pumpAndSettle();
    expect(find.text('Page (1-2)'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Jump'),
      ),
    );
    await pumpFrames(tester);

    expect(tester.widget<ComicGrid>(grid).comics.first.id, 'jump-first-40');
    expect(source.cursors, [null, 'second-page']);
    await tester.scrollUntilVisible(
      previous.hitTestable(),
      400,
      scrollable: scrollable,
    );
    expect(
      tester.widget<PaginationBar>(find.byType(PaginationBar)).isLoading,
      isFalse,
    );
  });

  testWidgets('ComicScreen does not show a new page at the old scroll offset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _PaginatedSource(
      List.generate(
        40,
        (i) => Comic(
          source: 'fixture',
          id: 'transition-first-$i',
          title: 'Transition first $i',
          cover: 'transition-first-cover-$i',
        ),
      ),
      List.generate(
        40,
        (i) => Comic(
          source: 'fixture',
          id: 'transition-second-$i',
          title: 'Transition second $i',
          cover: i >= 35
              ? 'transition-first-cover-${35 + (i - 35) % 5}'
              : 'transition-second-cover-$i',
        ),
      ),
    );
    final slowFirstCover = Completer<Uint8List>();
    await pump(
      tester,
      const ComicScreen(),
      _Library(),
      source,
      loadImage: (page) => page.url == 'transition-second-cover-0'
          ? slowFirstCover.future
          : Future.value(Uint8List.fromList(_png)),
    );

    final grid = find.byType(ComicGrid);
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    final next = find.text('Next');
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    final previousOffset = position.pixels;
    expect(previousOffset, greaterThan(0));

    final gesture = await tester.startGesture(tester.getCenter(next));
    await gesture.up();
    await tester.pump(Duration.zero);

    final pageTwoTitles = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data?.startsWith('Transition second ') == true,
    );
    final displacedFrames = <String>[];
    void recordDisplacedPage() {
      final titles = pageTwoTitles.hitTestable().evaluate().toList();
      final gridItems = tester.widget<ComicGrid>(grid).comics;
      final isPageTwo = gridItems.first.id.startsWith('transition-second-');
      if (isPageTwo && position.pixels > 1) {
        displacedFrames.add(
          'offset=${position.pixels.toStringAsFixed(1)}, '
          'page=${gridItems.first.id}, '
          'visible=${titles.map((element) => (element.widget as Text).data).toList()}',
        );
      }
    }

    recordDisplacedPage();
    for (var frame = 0; frame < 20 && position.pixels > 1; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      recordDisplacedPage();
    }

    expect(source.cursors, [null, 'second-page']);
    expect(
      displacedFrames,
      isEmpty,
      reason:
          'New-page rows must not replace the old page until the existing '
          'scroll offset $previousOffset has reached the top. Observed: '
          '$displacedFrames',
    );
    expect(position.pixels, closeTo(0, 1));
    if (!slowFirstCover.isCompleted) slowFirstCover.complete(_png);
    await tester.pump();
    await waitForComicCardImage(tester, 'Transition second 0');
    expectComicCardReady(tester, 'Transition second 0');
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    expect(
      tester.widget<PaginationBar>(find.byType(PaginationBar)).isLoading,
      isFalse,
    );
    expect(
      tester.widget<ComicGrid>(grid).comics.first.id,
      'transition-second-0',
    );
  });

  testWidgets('comic search sort menu closes on Escape and selects a sort', (
    tester,
  ) async {
    final source = _SortedSource();
    await pump(
      tester,
      const ComicSearchScreen(initialSource: 'fixture', initialQuery: 'book'),
      _Library(),
      source,
    );

    final sortButton = find.byIcon(Icons.sort);
    expect(sortButton, findsOneWidget);
    expect(source.sortRequests, [null]);
    await tester.tap(sortButton);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuItemButton, 'Newest'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'Oldest'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);

    await tester.tap(sortButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Oldest'));
    await tester.pumpAndSettle();
    expect(source.sortRequests.last, 'da');
    await tester.tap(sortButton);
    await tester.pumpAndSettle();
    final sortItems = find.byType(MenuItemButton);
    final sortButtons = tester.widgetList<MenuItemButton>(sortItems).toList();
    final selectedSort = sortButtons.singleWhere((button) => button.autofocus);
    final unselectedSort = sortButtons.firstWhere(
      (button) => !button.autofocus,
    );
    final colors = Theme.of(tester.element(sortItems.first)).colorScheme;
    expect(
      selectedSort.style?.foregroundColor?.resolve({}),
      colors.onPrimaryContainer,
    );
    expect(
      selectedSort.style?.backgroundColor?.resolve({}),
      colors.primaryContainer,
    );
    expect(unselectedSort.style?.foregroundColor?.resolve({}), isNull);
    expect(unselectedSort.style?.backgroundColor?.resolve({}), isNull);
    expect(
      find.descendant(of: sortItems, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('full comic search places list pagination at the scroll end', (
    tester,
  ) async {
    await StorageService.setString(
      ComicLayoutNotifier.preferenceKey,
      LayoutType.list.name,
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _PaginatedSearchSource(
      List.generate(
        48,
        (i) => Comic(
          source: 'fixture',
          id: 'search-first-$i',
          title: 'Search first $i',
          cover: 'search-first-cover-$i',
        ),
      ),
      List.generate(
        8,
        (i) => Comic(
          source: 'fixture',
          id: 'search-second-$i',
          title: 'Search second $i',
          cover: 'search-second-cover-$i',
        ),
      ),
    );
    await pump(
      tester,
      const ComicSearchScreen(initialSource: 'fixture', initialQuery: 'book'),
      _Library(),
      source,
    );

    final next = find.text('Next');
    final grid = find.byType(ComicGrid);
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    expect(next.hitTestable(), findsNothing);
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    expect(next.hitTestable(), findsOneWidget);
    await tester.tap(next);
    await pumpFrames(tester);
    expect(tester.widget<ComicGrid>(grid).comics.first.id, 'search-first-40');

    expect(source.cursors, [null, 'search-next']);
    expect(find.text('Previous').hitTestable(), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Previous').hitTestable(),
      400,
      scrollable: scrollable,
    );
    expect(
      tester.widget<PaginationBar>(find.byType(PaginationBar)).isLoading,
      isFalse,
    );
  });

  testWidgets('full comic search commits a new page only at the top', (
    tester,
  ) async {
    await StorageService.setString(
      ComicLayoutNotifier.preferenceKey,
      LayoutType.list.name,
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _PaginatedSearchSource(
      List.generate(
        40,
        (i) => Comic(
          source: 'fixture',
          id: 'search-transition-first-$i',
          title: 'Search transition first $i',
          cover: 'search-transition-cover-$i',
        ),
      ),
      List.generate(
        40,
        (i) => Comic(
          source: 'fixture',
          id: 'search-transition-second-$i',
          title: 'Search transition second $i',
          cover: 'search-transition-cover-$i',
        ),
      ),
    );
    await pump(
      tester,
      const ComicSearchScreen(initialSource: 'fixture', initialQuery: 'book'),
      _Library(),
      source,
    );

    final grid = find.byType(ComicGrid);
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    final next = find.text('Next');
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, greaterThan(0));
    final gesture = await tester.startGesture(tester.getCenter(next));
    await gesture.up();
    await tester.pump(Duration.zero);

    final displacedPages = <String>[];
    void recordPageAtOffset() {
      final comics = tester.widget<ComicGrid>(grid).comics;
      if (comics.first.id.startsWith('search-transition-second-') &&
          position.pixels > 1) {
        final visibleTitles = find
            .byWidgetPredicate(
              (widget) =>
                  widget is Text &&
                  widget.data?.startsWith('Search transition second ') == true,
            )
            .hitTestable()
            .evaluate()
            .map((element) => (element.widget as Text).data)
            .toList();
        displacedPages.add(
          'offset=${position.pixels.toStringAsFixed(1)}, '
          'visible=$visibleTitles',
        );
      }
    }

    recordPageAtOffset();
    for (var frame = 0; frame < 20 && position.pixels > 1; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      recordPageAtOffset();
    }

    expect(source.cursors, [null, 'search-next']);
    expect(
      displacedPages,
      isEmpty,
      reason:
          'The complete search should keep its old page during the top scroll. '
          'Observed: $displacedPages',
    );
    expect(position.pixels, closeTo(0, 1));
  });

  testWidgets('leaving a comic route cancels its pending page turn', (
    tester,
  ) async {
    await StorageService.setString(
      ComicLayoutNotifier.preferenceKey,
      LayoutType.list.name,
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _PaginatedSource(
      List.generate(
        48,
        (i) => Comic(
          source: 'fixture',
          id: 'route-first-$i',
          title: 'Route first $i',
          cover: 'route-first-cover-$i',
        ),
      ),
      List.generate(
        24,
        (i) => Comic(
          source: 'fixture',
          id: 'route-second-$i',
          title: 'Route second $i',
          cover: 'route-second-cover-$i',
        ),
      ),
    )..secondPageGate = Completer<ComicResult>();
    await pump(tester, const ComicScreen(), _Library(), source);

    final grid = find.byType(ComicGrid);
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    final next = find.text('Next');
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    await tester.tap(next);
    await tester.pump();
    expect(source.cursors, [null, 'second-page']);

    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(0);
    await tester.pump();
    await waitForComicCardImage(tester, 'Route first 0');
    expect(find.text('Route first 0').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Route first 0'));
    await pumpFrames(tester);
    expect(find.byType(ComicDetailScreen), findsOneWidget);

    source.secondPageGate!.complete(ComicResult(source.secondPage));
    await tester.pump();
    await pumpFrames(tester, frames: 3);
    expect(find.byType(ComicDetailScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await pumpFrames(tester);
    expect(tester.widget<ComicGrid>(grid).comics.first.id, 'route-first-0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('main navigation cancels a pending comic page turn', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _PaginatedSource(
      List.generate(
        40,
        (i) => Comic(
          source: 'fixture',
          id: 'main-first-$i',
          title: 'Main first $i',
          cover: 'main-first-$i',
        ),
      ),
      List.generate(
        40,
        (i) => Comic(
          source: 'fixture',
          id: 'main-second-$i',
          title: 'Main second $i',
          cover: 'main-second-$i',
        ),
      ),
    )..secondPageGate = Completer<ComicResult>();
    await pump(
      tester,
      ProviderScope(
        overrides: [
          worksProvider.overrideWith((ref) => _IdleWorks(ref)),
          downloadSummaryProvider.overrideWith(
            (ref) => Stream.value(const DownloadTaskSummary.empty()),
          ),
          downloadTaskIdsProvider.overrideWith(
            (ref) => Stream.value(<String>[]),
          ),
        ],
        child: const MainScreen(),
      ),
      _Library(),
      source,
    );
    final navigation = find.byType(NavigationBar);
    Future<void> select(String label) async {
      await tester.tap(
        find.descendant(of: navigation, matching: find.text(label)),
      );
      await pumpFrames(tester, frames: 25);
    }

    await select('Comics');
    final grid = find
        .descendant(
          of: find.byType(ComicScreen),
          matching: find.byType(ComicGrid),
        )
        .first;
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    final next = find.descendant(of: grid, matching: find.text('Next'));
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    await tester.tap(next);
    await tester.pump();
    expect(source.cursors, [null, 'second-page']);
    final position = tester.state<ScrollableState>(scrollable).position;
    final oldOffset = position.pixels;
    await select('Audio');
    await select('Comics');
    source.secondPageGate!.complete(ComicResult(source.secondPage));
    await pumpFrames(tester, frames: 25);
    expect(tester.widget<ComicGrid>(grid).comics.first.id, 'main-first-0');
    expect(position.pixels, closeTo(oldOffset, 1));
    var bar = tester.widget<PaginationBar>(
      find.descendant(of: grid, matching: find.byType(PaginationBar)),
    );
    expect(bar.currentPage, 1);
    expect(bar.jumpMaxPage, 1);
    expect(bar.isLoading, isFalse);
    await tester.tap(next);
    await pumpFrames(tester, frames: 25);
    expect(tester.widget<ComicGrid>(grid).comics.first.id, 'main-second-0');
    expect(source.cursors, [null, 'second-page']);
    position.jumpTo(position.maxScrollExtent);
    await pumpFrames(tester);
    bar = tester.widget<PaginationBar>(
      find.descendant(of: grid, matching: find.byType(PaginationBar)),
    );
    expect(bar.currentPage, 2);
    expect(bar.jumpMaxPage, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching tabs cancels a pending comic page turn', (
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
          id: 'tab-first-$i',
          title: 'Tab first $i',
          cover: 'tab-first-cover-$i',
        ),
      ),
      List.generate(
        24,
        (i) => Comic(
          source: 'fixture',
          id: 'tab-second-$i',
          title: 'Tab second $i',
          cover: 'tab-second-cover-$i',
        ),
      ),
    )..secondPageGate = Completer<ComicResult>();
    await pump(tester, const ComicScreen(), _Library(), source);

    final grid = find.byType(ComicGrid).first;
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    final next = find.text('Next');
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    await tester.tap(next);
    await tester.pump();
    expect(source.cursors, [null, 'second-page']);

    final position = tester.state<ScrollableState>(scrollable).position;
    final tabView = find.byKey(const ValueKey('comic-tab-pages'));
    for (var index = 1; index <= 2; index++) {
      await tester.drag(tabView, const Offset(-400, 0));
      await pumpFrames(tester, frames: 25);
      expect(
        tester.widget<TabBar>(find.byType(TabBar)).controller?.index,
        index,
      );
    }
    for (var index = 1; index >= 0; index--) {
      await tester.drag(tabView, const Offset(400, 0));
      await pumpFrames(tester, frames: 25);
      expect(
        tester.widget<TabBar>(find.byType(TabBar)).controller?.index,
        index,
      );
    }
    source.secondPageGate!.complete(ComicResult(source.secondPage));
    await tester.pump();
    await pumpFrames(tester, frames: 3);

    expect(tester.widget<ComicGrid>(grid).comics.first.id, 'tab-first-0');
    position.jumpTo(position.maxScrollExtent);
    await pumpFrames(tester, frames: 3);
    expect(
      tester
          .widget<PaginationBar>(
            find.descendant(of: grid, matching: find.byType(PaginationBar)),
          )
          .isLoading,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging during page scroll cancels the page commit', (
    tester,
  ) async {
    await StorageService.setString(
      ComicLayoutNotifier.preferenceKey,
      LayoutType.list.name,
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _PaginatedSource(
      List.generate(
        48,
        (i) => Comic(
          source: 'fixture',
          id: 'drag-first-$i',
          title: 'Drag first $i',
          cover: 'drag-first-cover-$i',
        ),
      ),
      List.generate(
        24,
        (i) => Comic(
          source: 'fixture',
          id: 'drag-second-$i',
          title: 'Drag second $i',
          cover: 'drag-second-cover-$i',
        ),
      ),
    );
    await pump(tester, const ComicScreen(), _Library(), source);

    final grid = find.byType(ComicGrid);
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    final next = find.text('Next');
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    final tapNext = await tester.startGesture(tester.getCenter(next));
    await tapNext.up();
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 16));
    expect(source.cursors, [null, 'second-page']);

    final drag = await tester.startGesture(tester.getCenter(scrollable));
    await drag.moveBy(const Offset(0, 32));
    await tester.pump(const Duration(milliseconds: 16));
    await drag.up();
    await pumpFrames(tester);

    expect(tester.widget<ComicGrid>(grid).comics.first.id, 'drag-first-0');
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, greaterThan(0));
    await tester.scrollUntilVisible(
      next.hitTestable(),
      400,
      scrollable: scrollable,
    );
    expect(find.byIcon(Icons.edit_location_alt), findsNothing);
    expect(
      tester.widget<PaginationBar>(find.byType(PaginationBar)).isLoading,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  for (final layout in LayoutType.values) {
    testWidgets(
      'seen covers survive fast reverse scrolling under cache pressure ($layout)',
      (tester) async {
        await StorageService.setString('comic_layout_type', layout.name);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final cache = PaintingBinding.instance.imageCache;
        final oldLimit = cache.maximumSizeBytes;
        cache.maximumSizeBytes = 100000;
        addTearDown(() => cache.maximumSizeBytes = oldLimit);
        final source = _PaginatedSource(
          List.generate(
            40,
            (i) => Comic(
              source: 'fixture',
              id: 'pressure-$i',
              title: 'Pressure $i',
              cover: 'pressure-$i',
            ),
          ),
          const [
            Comic(
              source: 'fixture',
              id: 'pressure-next',
              title: 'Pressure next',
              cover: 'pressure-next',
            ),
          ],
        );
        final loads = <String, int>{};
        await pump(
          tester,
          const ComicScreen(),
          _Library(),
          source,
          loadImage: (page) {
            loads.update(page.url, (value) => value + 1, ifAbsent: () => 1);
            final bytes = page.url == 'pressure-0' ? _highResolutionPng : _png;
            return Future.value(Uint8List.fromList(bytes));
          },
        );
        await waitForComicCardImage(tester, 'Pressure 0');
        final firstCard = comicCardForTitle('Pressure 0');
        final original = tester
            .widget<RawImage>(
              find.descendant(of: firstCard, matching: find.byType(RawImage)),
            )
            .image;
        expect(original, isNotNull);
        final firstProvider = tester
            .widget<Image>(
              find.descendant(of: firstCard, matching: find.byType(Image)),
            )
            .image;
        expect(firstProvider, isA<ResizeImage>());
        final firstResize = firstProvider as ResizeImage;
        final firstCoverWidth = tester
            .getSize(
              find.descendant(of: firstCard, matching: find.byType(ComicImage)),
            )
            .width;
        expect(
          firstResize.width,
          math.min(
            (firstCoverWidth * tester.view.devicePixelRatio).ceil(),
            1800,
          ),
        );
        final firstCacheKey = await firstProvider.obtainKey(
          ImageConfiguration.empty,
        );
        expect(cache.statusForKey(firstCacheKey).keepAlive, isTrue);
        final grid = find.byType(ComicGrid);
        final scrollable = find.descendant(
          of: grid,
          matching: find.byType(Scrollable),
        );
        final position = tester.state<ScrollableState>(scrollable).position;
        await tester.scrollUntilVisible(
          find.text('Next').hitTestable(),
          500,
          scrollable: scrollable,
        );
        await waitForComicCardImage(tester, 'Pressure 39');
        expect(
          cache
              .statusForKey(
                await firstProvider.obtainKey(ImageConfiguration.empty),
              )
              .keepAlive,
          isFalse,
        );
        position.jumpTo(0);
        await tester.pump();
        expect(
          find.text('Pressure 0').hitTestable(),
          findsOneWidget,
          reason:
              'An already displayed cover must paint on the first reverse-scroll frame, even after eviction from the shared decoded cache.',
        );
        expect(
          tester
              .widget<RawImage>(
                find.descendant(of: firstCard, matching: find.byType(RawImage)),
              )
              .image,
          same(original),
        );
        expect(loads['pressure-0'], 1);
        await tester.scrollUntilVisible(
          find.text('Next').hitTestable(),
          500,
          scrollable: scrollable,
        );
        await tester.tap(find.text('Next'));
        await pumpFrames(tester);
        await waitForComicCardImage(tester, 'Pressure next');
        expect(find.text('Pressure 0', skipOffstage: false), findsNothing);
        expect(original!.debugDisposed, isTrue);
      },
    );
  }

  for (final layout in LayoutType.values) {
    for (final evictDecoded in [false, true]) {
      testWidgets(
        'ComicScreen revisits covers without blank frames ($layout, evicted=$evictDecoded)',
        (tester) async {
          await StorageService.setString('comic_layout_type', layout.name);
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          const cachedComic = Comic(
            source: 'fixture',
            id: 'cached-cover-book',
            title: 'Cached cover book',
            cover: 'cached-cover-image',
          );
          final source = _PaginatedSource(
            [
              cachedComic,
              ...List.generate(
                39,
                (i) => Comic(
                  source: 'fixture',
                  id: 'cached-first-$i',
                  title: 'Cached first $i',
                  cover: 'cached-first-cover-$i',
                ),
              ),
            ],
            List.generate(
              40,
              (i) => Comic(
                source: 'fixture',
                id: 'cached-second-$i',
                title: 'Cached second $i',
                cover: 'cached-second-cover-$i',
              ),
            ),
          );
          var cachedCoverLoads = 0;
          await pump(
            tester,
            const ComicScreen(),
            _Library(),
            source,
            loadImage: (page) {
              if (page.url == 'cached-cover-image') {
                cachedCoverLoads++;
              }
              return Future.value(Uint8List.fromList(_widePng));
            },
          );
          final title = find.text('Cached cover book');
          Finder currentComicImage() {
            final card = find
                .ancestor(of: title, matching: find.byType(Card))
                .first;
            return find.descendant(of: card, matching: find.byType(ComicImage));
          }

          Finder currentRawImages() => find.descendant(
            of: currentComicImage(),
            matching: find.byType(RawImage),
          );

          Finder currentMemoryImage() => find.descendant(
            of: currentComicImage(),
            matching: find.byType(Image),
          );

          var memoryImage = currentMemoryImage();
          for (
            var frame = 0;
            frame < 24 && memoryImage.evaluate().isEmpty;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 16));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            memoryImage = currentMemoryImage();
          }
          expect(memoryImage, findsOneWidget);
          await waitForDecodedImage(tester, memoryImage);
          expect(
            tester
                .widgetList<RawImage>(currentRawImages())
                .any((image) => image.image != null),
            isTrue,
          );

          final grid = find.byType(ComicGrid);
          final scrollable = find.descendant(
            of: grid,
            matching: find.byType(Scrollable),
          );
          final next = find.text('Next');
          await tester.scrollUntilVisible(
            next.hitTestable(),
            400,
            scrollable: scrollable,
          );
          await tester.tap(next);
          final position = tester.state<ScrollableState>(scrollable).position;
          for (var frame = 0; frame < 20 && position.pixels > 1; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          await tester.pump();
          final previous = find.text('Previous');
          await tester.scrollUntilVisible(
            previous.hitTestable(),
            400,
            scrollable: scrollable,
          );
          if (evictDecoded) {
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
          }
          await tester.tap(previous);
          var returned = false;
          for (var frame = 0; frame < 24; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            if (tester.widget<ComicGrid>(grid).comics.first.id ==
                cachedComic.id) {
              returned = true;
              if (!evictDecoded) {
                expect(
                  title.hitTestable(),
                  findsOneWidget,
                  reason:
                      'The first returning frame must already show the cached cover.',
                );
                expect(
                  tester
                      .widgetList<RawImage>(currentRawImages())
                      .any((image) => image.image != null),
                  isTrue,
                );
              }
              break;
            }
          }
          expect(returned, isTrue);
          expect(cachedCoverLoads, 1);
          final prematureFrames = <String>[];
          var sawNullRawImage = false;
          void recordVisibleCoverState(String frame) {
            if (title.hitTestable().evaluate().isEmpty) return;
            final rawImage = currentRawImages();
            final images = tester.widgetList<RawImage>(rawImage).toList();
            if (images.isEmpty) {
              prematureFrames.add(
                '$frame: title visible before RawImage exists',
              );
              return;
            }
            final decoded = images.any((image) => image.image != null);
            if (!decoded) {
              sawNullRawImage = true;
              prematureFrames.add(
                '$frame: title visible with RawImage.image == null',
              );
            }
          }

          recordVisibleCoverState('revisit pending');
          var reloadedDecoded = false;
          for (var frame = 0; frame < 24; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            recordVisibleCoverState('frame $frame');
            final memoryImage = currentMemoryImage();
            if (memoryImage.evaluate().isNotEmpty) {
              await waitForDecodedImage(tester, memoryImage.first);
              for (
                var revealFrame = 0;
                revealFrame < 5 && title.hitTestable().evaluate().isEmpty;
                revealFrame++
              ) {
                await tester.pump(const Duration(milliseconds: 16));
                recordVisibleCoverState('reveal frame $revealFrame');
              }
              reloadedDecoded = tester
                  .widgetList<RawImage>(currentRawImages())
                  .any((image) => image.image != null);
              break;
            }
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }

          expect(reloadedDecoded, isTrue);
          expect(title.hitTestable(), findsOneWidget);
          expect(
            prematureFrames,
            isEmpty,
            reason:
                'A remounted comic title became visible before its decoded cover '
                'frame. Saw null RawImage: $sawNullRawImage; states: '
                '$prematureFrames',
          );
        },
      );
    }
  }

  for (final layout in [
    LayoutType.list,
    LayoutType.smallGrid,
    LayoutType.bigGrid,
  ]) {
    testWidgets(
      '$layout keeps comic card space while cover frames resolve in reverse order',
      (tester) async {
        await StorageService.setString('comic_layout_type', layout.name);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final stablePng = Uint8List.fromList(
          img.encodePng(img.Image(width: 100, height: 150)),
        );
        final imageBytes = List.generate(
          12,
          (_) => Uint8List.fromList(stablePng),
        );
        final gates = {
          for (var i = 0; i < 12; i++)
            'reverse-cover-$i': Completer<Uint8List>(),
        };
        final comics = List.generate(
          12,
          (i) => Comic(
            source: 'fixture',
            id: 'reverse-$i',
            title: 'Reverse $i',
            cover: 'reverse-cover-$i',
          ),
        );
        await pump(
          tester,
          Scaffold(body: ComicGrid(comics: comics)),
          _Library(),
          _Source(),
          loadImage: (page) => gates[page.url]!.future,
          settle: false,
        );

        final grid = find.byType(ComicGrid);
        final scrollable = find.descendant(
          of: grid,
          matching: find.byType(Scrollable),
        );
        final position = tester.state<ScrollableState>(scrollable).position;
        final anchor = comicCardForTitle('Reverse 3');
        expect(anchor, findsOneWidget);
        final anchorContentTop = tester.getRect(anchor).top + position.pixels;
        for (var i = 0; i < 3; i++) {
          expectComicTitleHidden(tester, 'Reverse $i');
        }

        for (final i in [1, 0, 2]) {
          gates['reverse-cover-$i']!.complete(imageBytes[i]);
          await tester.pump();
          await waitForCoverBytes(tester, imageBytes[i]);
          expectComicCardReady(tester, 'Reverse $i');
          expect(
            tester.getRect(anchor).top + position.pixels,
            closeTo(anchorContentTop, 1),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

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
        final frame = tester.getRect(find.byType(WorkCoverClip));
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
          builder: (context, value, _) =>
              ComicCover(source: 'fixture', page: value, maxWidth: 120),
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
      final library = _NotifyingLibrary();
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
      final scrollable = find
          .descendant(
            of: find.byType(ComicDetailScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Fixture tag'),
        300,
        scrollable: scrollable,
      );
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
          of: find.text('Start reading'),
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
      final label = tester.getRect(find.text('Start reading'));
      expect((icon.left + label.right) / 2, closeTo(button.center.dx, 2));
      expect(icon.center.dy, closeTo(button.center.dy, 2));
      expect(find.text('Continue reading'), findsNothing);
      await library.saveProgress(_comic, 'one', 0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byIcon(Icons.history),
        -200,
        scrollable: scrollable,
      );
      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.text('Start reading'), findsNothing);
      expect(
        tester.getTopLeft(find.byIcon(Icons.history)).dx,
        closeTo(tester.getTopLeft(find.byType(WorkTitleHeader)).dx, 0.1),
      );
      await tester.tap(find.byTooltip('Download'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(320, 640), const Size(1000, 600)]) {
    testWidgets('comic release and update dates share a row at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const comic = Comic(
        source: 'fixture',
        id: 'dated-book',
        title: 'Dated book',
        extra: {
          'publishedAt': '2020-01-02T00:00:00Z',
          'updatedAt': '2024-03-04T00:00:00Z',
        },
      );
      await pump(
        tester,
        const ComicDetailScreen(comic: comic),
        _Library(),
        _Source()..detailResult = comic,
      );
      final labels = S.of(tester.element(find.byType(ComicDetailScreen)));
      await tester.scrollUntilVisible(
        find.text(labels.releaseDate),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final release = find.text(labels.releaseDate);
      final updated = find.text(labels.lastUpdated);
      expect(
        tester.getTopLeft(release).dy,
        closeTo(tester.getTopLeft(updated).dy, 0.1),
      );
      expect(find.text('2020-01-02'), findsOneWidget);
      expect(find.text('2024-03-04'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'detail history follows library changes and offline chapter metadata',
    (tester) async {
      const comic = Comic(
        source: 'fixture',
        id: 'book',
        title: 'Fixture book',
        chapters: [ComicChapter('two', 'Online chapter')],
      );
      const progressComic = Comic(
        source: 'fixture',
        id: 'book',
        title: 'Fixture book',
        chapters: [ComicChapter('one', 'Saved offline chapter')],
      );
      final library = _NotifyingLibrary();
      await pump(
        tester,
        const ComicDetailScreen(comic: comic),
        library,
        _Source()..detailResult = comic,
      );
      expect(find.byIcon(Icons.history), findsNothing);

      expect(find.text('Start reading'), findsOneWidget);
      expect(find.text('Continue reading'), findsNothing);
      await library.saveProgress(progressComic, 'one', 0);
      await tester.pumpAndSettle();
      final page = S.of(tester.element(find.byType(ComicDetailScreen)));
      expect(
        find.text('Saved offline chapter ${page.comicPreviewPage(1)}'),
        findsOneWidget,
      );
      expect(
        tester
            .getTopLeft(
              find.text('Saved offline chapter ${page.comicPreviewPage(1)}'),
            )
            .dy,
        greaterThan(
          tester
              .getRect(
                find.ancestor(
                  of: find.text('Continue reading'),
                  matching: find.byType(FilledButton),
                ),
              )
              .bottom,
        ),
      );
      expect(find.byIcon(Icons.history), findsOneWidget);
      expect(find.text('Continue reading'), findsOneWidget);
      expect(find.text('Start reading'), findsNothing);
      expect(tester.takeException(), isNull);

      await library.removeHistory(progressComic);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.history), findsNothing);
      expect(find.text('Start reading'), findsOneWidget);
      expect(find.text('Continue reading'), findsNothing);
      expect(
        find.text('Saved offline chapter ${page.comicPreviewPage(1)}'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'chapter thumbnails open a page preview before reading a selected page',
    (tester) async {
      await StorageService.remove('comic_chapter_thumbnails');
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await StorageService.setString('comic_reading_mode', 'leftToRight');
      await StorageService.setInt('comic_preload', 0);
      final comic = Comic(
        source: 'fixture',
        id: 'book',
        title: 'Fixture book',
        description: List.filled(80, 'Synopsis').join('\n'),
        chapters: _comic.chapters,
      );
      final source = _Source()..detailResult = comic;
      final library = _Library()
        ..last = ComicProgress(comic, 'one', 7, DateTime(2026));
      final loaded = <String>[];
      await pump(
        tester,
        ComicDetailScreen(comic: comic),
        library,
        source,
        loadImage: (page) async {
          loaded.add(page.url);
          return _png;
        },
      );
      expect(source.pageRequests, isEmpty);
      await tester.scrollUntilVisible(
        find.text('Chapter 1'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final thumbnail = find.byKey(
        const ValueKey('comic-chapter-thumbnail-one-3'),
      );
      await waitForPreviewContent(tester, thumbnail);
      final image = find.descendant(
        of: thumbnail,
        matching: find.byType(Image),
      );
      await waitForPreviewContent(tester, image);
      await waitForDecodedImage(tester, image);
      await tester.ensureVisible(thumbnail);
      await tester.pumpAndSettle();
      expect(source.pageRequests, contains('one'));
      expect(loaded.where((url) => url.startsWith('page-')).toSet(), {
        'page-0',
        'page-3',
        'page-7',
      });
      await tester.tap(thumbnail);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(ComicPagePreview), findsOneWidget);
      expect(find.byType(ComicReaderScreen), findsNothing);
      expect(
        tester
            .widget<ComicPagePreview>(find.byType(ComicPagePreview))
            .initialPage,
        3,
      );
      expect(library.last?.page, 7);
      final previewTile = find.byKey(const ValueKey('comic-page-preview-3'));
      final previewImage = find.descendant(
        of: previewTile,
        matching: find.byType(Image),
      );
      await waitForPreviewContent(tester, previewImage);
      await waitForDecodedImage(tester, previewImage);
      await tester.tap(find.byKey(const ValueKey('comic-page-preview-close')));
      await tester.pumpAndSettle();
      expect(find.byType(ComicReaderScreen), findsNothing);
      expect(library.last?.page, 7);

      await tester.tap(thumbnail);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      final selectedTile = find.byKey(const ValueKey('comic-page-preview-3'));
      final selectedImage = find.descendant(
        of: selectedTile,
        matching: find.byType(Image),
      );
      await waitForPreviewContent(tester, selectedImage);
      await waitForDecodedImage(tester, selectedImage);
      await tester.tap(selectedTile);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ComicReaderScreen>(find.byType(ComicReaderScreen))
            .initialPage,
        3,
      );
      expect(readerPageValue('4/8'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(library.last?.page, 3);
      Navigator.of(tester.element(find.byType(ComicReaderScreen))).pop();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byIcon(Icons.history),
        -400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final historyPage = S.of(tester.element(find.byType(ComicDetailScreen)));
      expect(
        find.text('Chapter 1 ${historyPage.comicPreviewPage(4)}'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chapter thumbnails retry a failed page listing', (tester) async {
    final source = _Source()..failedChapter = 'one';
    await pump(
      tester,
      Scaffold(
        body: ComicChapterThumbnails(
          comic: _comic,
          chapter: const ComicChapter('one', 'Chapter 1'),
          onSelected: (_, _) {},
        ),
      ),
      _Library(),
      source,
    );
    expect(find.text('Retry'), findsOneWidget);
    source.failedChapter = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('comic-chapter-thumbnail-one-7')),
      findsOneWidget,
    );
    expect(source.pageRequests, ['one', 'one']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'chapter detail previews reuse offline pages without source requests',
    (tester) async {
      await StorageService.remove('comic_chapter_thumbnails');
      final source = _Source()..failedChapter = 'one';
      final library = _Library();
      final downloads = _PreviewDownloads(
        library,
        source,
        List.generate(
          8,
          (i) => ComicPage('page-$i', localPath: 'offline-$i.png'),
        ),
      );
      final loaded = <String?>[];
      await pump(
        tester,
        const ComicDetailScreen(comic: _comic),
        library,
        source,
        downloads: downloads,
        loadImage: (page) async {
          loaded.add(page.localPath);
          return _png;
        },
      );
      await tester.scrollUntilVisible(
        find.text('Chapter 1'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      final thumbnail = find.byKey(
        const ValueKey('comic-chapter-thumbnail-one-3'),
      );
      await waitForPreviewContent(tester, thumbnail);
      expect(source.pageRequests, isEmpty);
      expect(loaded.whereType<String>().toSet(), {
        'offline-0.png',
        'offline-3.png',
        'offline-7.png',
      });
      await tester.tap(thumbnail);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      final selectedTile = find.byKey(const ValueKey('comic-page-preview-3'));
      final selectedImage = find.descendant(
        of: selectedTile,
        matching: find.byType(Image),
      );
      await waitForPreviewContent(tester, selectedImage);
      await waitForDecodedImage(tester, selectedImage);
      expect(loaded, contains('offline-3.png'));
      await tester.tap(selectedTile);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ComicReaderScreen>(find.byType(ComicReaderScreen))
            .initialPage,
        3,
      );
      expect(source.pageRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chapter thumbnail setting persists and prevents page requests', (
    tester,
  ) async {
    await StorageService.remove('comic_chapter_thumbnails');
    final source = _Source();
    final library = _Library();
    await pump(tester, const ComicSettingsScreen(), library, source);
    final title = find.text('Chapter thumbnails');
    await tester.ensureVisible(title);
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(StorageService.getBool('comic_chapter_thumbnails'), isFalse);
    await pump(tester, const ComicDetailScreen(comic: _comic), library, source);
    await tester.scrollUntilVisible(
      find.text('Chapter 1'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(ComicChapterThumbnails), findsNothing);
    expect(source.pageRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comic metadata uses shared styles and deduplicates tags', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await StorageService.setBool('comic_chapter_thumbnails', false);
    const comic = Comic(
      source: 'fixture',
      id: 'book',
      title: 'Fixture book',
      tags: ['Fixture tag', 'Fixture tag', 'Other tag'],
      chapters: [
        ComicChapter('one', 'Chapter 1'),
        ComicChapter('two', 'Chapter 2'),
      ],
      extra: {
        'authors': ['Fixture author'],
        'publishedAt': '2026-01-02T00:00:00Z',
        'updatedAt': '2026-02-03T00:00:00Z',
      },
    );
    await pump(
      tester,
      const ComicDetailScreen(comic: comic),
      _Library(),
      _Source()..detailResult = comic,
    );
    expect(find.text('Fixture tag'), findsOneWidget);
    expect(find.text('Fixture author'), findsOneWidget);
    expect(find.text('2026-01-02'), findsOneWidget);
    expect(find.text('2026-02-03'), findsOneWidget);
    final author = tester.widget<MetadataSearchChip>(
      find.ancestor(
        of: find.text('Fixture author'),
        matching: find.byType(MetadataSearchChip),
      ),
    );
    expect(author.fontSize, 12);
    expect(author.borderRadius, 6);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comic comments display avatars and localized creation times', (
    tester,
  ) async {
    await StorageService.setBool('comic_chapter_thumbnails', false);
    final createdAt = DateTime.utc(2026, 1, 2, 3, 4);
    final source = _Source()
      ..commentsEnabled = true
      ..commentsResult = [
        ComicComment(
          'Reader',
          'Timed comment',
          createdAt: createdAt,
          avatar: const ComicPage('fixture-avatar'),
          score: '5',
        ),
        const ComicComment('Other reader', 'Untimed comment'),
      ];
    final loaded = <String>[];
    await pump(
      tester,
      const ComicDetailScreen(comic: _comic),
      _Library(),
      source,
      loadImage: (page) async {
        loaded.add(page.url);
        return _png;
      },
    );
    final comments = find.text('Comments');
    await tester.scrollUntilVisible(
      comments,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(comments);
    await tester.pump();
    final avatar = find.byWidgetPredicate(
      (widget) => widget is ComicCover && widget.page.url == 'fixture-avatar',
    );
    final avatarImage = find.descendant(
      of: avatar,
      matching: find.byType(Image),
    );
    await waitForPreviewContent(tester, avatarImage);
    await waitForDecodedImage(tester, avatarImage);
    await tester.pumpAndSettle();
    final labels = S.of(tester.element(find.text('Timed comment')));
    expect(
      find.text(
        labels.comicCommentTime(createdAt.toLocal(), createdAt.toLocal()),
      ),
      findsOneWidget,
    );
    expect(find.text('5'), findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
    expect(loaded, contains('fixture-avatar'));
    expect(find.text('Untimed comment'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comments follow all chapters and remain read only', (
    tester,
  ) async {
    final source = _Source()..commentsEnabled = true;
    await pump(
      tester,
      const ComicDetailScreen(comic: _comic),
      _Library(),
      source,
    );
    await tester.ensureVisible(find.text('Fixture tag'));
    await tester.pumpAndSettle();
    final labels = S.of(tester.element(find.byType(ComicDetailScreen)));
    final comments = find.text(labels.comicComments);
    expect(
      tester.getTopLeft(find.text('Fixture tag')).dy,
      lessThan(tester.getTopLeft(comments).dy),
    );
    await tester.scrollUntilVisible(
      comments,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.getTopLeft(comments).dy,
      greaterThan(tester.getTopLeft(find.text('Chapter 2')).dy),
    );
    await tester.tap(comments);
    await tester.pumpAndSettle();
    expect(find.text('Existing comment'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('offscreen detail tags are built only when scrolled into view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final listing = Comic(
      source: 'fixture',
      id: 'book',
      title: 'Fixture book',
      cover: 'fixture-cover',
      tags: List.generate(40, (index) => 'Tag $index'),
    );
    final source = _Source()..detailResult = listing;
    await pump(
      tester,
      const ComicDetailScreen(comic: _comic),
      _Library(),
      source,
    );
    expect(find.byType(MetadataSearchChip), findsNothing);
    final scrollable = find
        .descendant(
          of: find.byType(ComicDetailScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Tag 39'),
      320,
      scrollable: scrollable,
    );
    expect(find.text('Tag 39'), findsOneWidget);
    expect(find.byType(MetadataSearchChip), findsWidgets);
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
      await waitForComicCardImage(tester, 'Fixture book');
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
            of: find.text('Start reading'),
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

  testWidgets('detail metadata appears during push while chapter rows wait', (
    tester,
  ) async {
    const listing = Comic(
      source: 'fixture',
      id: 'book',
      title: 'Fixture book',
      cover: 'fixture-cover',
      description: 'Listing synopsis',
      tags: ['Fixture tag'],
      chapters: [ComicChapter('one', 'Chapter 1')],
    );
    final source = _Source()
      ..commentsEnabled = true
      ..chapterGate = Completer<List<ComicChapter>>()
      ..detailResult = const Comic(
        source: 'fixture',
        id: 'book',
        title: 'Loaded metadata',
        cover: 'fixture-cover',
        chapters: [ComicChapter('one', 'Chapter 1')],
      );
    await pump(
      tester,
      const Scaffold(body: Text('Origin')),
      _Library(),
      source,
      theme: AppTheme.lightTheme(null),
    );
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    final route = MaterialPageRoute<void>(
      builder: (_) => const ComicDetailScreen(comic: listing),
    );
    navigator.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(route.animation!.status, AnimationStatus.forward);
    expect(source.detailRequests, 1);
    expect(source.chapterRequests, 1);
    expect(find.text('Listing synopsis'), findsOneWidget);
    expect(find.text('Fixture tag'), findsOneWidget);
    final labels = S.of(tester.element(find.byType(ComicDetailScreen)));
    expect(find.text('Chapter 1'), findsNothing);
    expect(
      tester.widget<WorkTitleHeader>(find.byType(WorkTitleHeader)).title,
      'Fixture book',
    );
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byTooltip('Download'),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('Start reading'),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );
    source.chapterGate!.complete(
      List.generate(
        1000,
        (index) => ComicChapter('chapter-$index', 'Loaded chapter $index'),
      ),
    );
    await tester.pump();
    final rows = find.byWidgetPredicate(
      (widget) =>
          widget is ListTile &&
          widget.title is Text &&
          ((widget.title! as Text).data?.startsWith('Loaded chapter ') ??
              false),
    );
    expect(rows, findsNothing);
    expect(find.text('Loaded chapter 999'), findsNothing);
    await tester.pumpAndSettle();
    expect(
      tester.widget<WorkTitleHeader>(find.byType(WorkTitleHeader)).title,
      'Loaded metadata',
    );
    expect(rows.evaluate().length, lessThan(30));
    final scrollable = find
        .descendant(
          of: find.byType(ComicDetailScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Loaded chapter 999'),
      4000,
      scrollable: scrollable,
      maxScrolls: 50,
    );
    expect(find.text('Loaded chapter 999'), findsOneWidget);
    expect(rows.evaluate().length, lessThan(30));
    await tester.scrollUntilVisible(
      find.text(labels.comicComments),
      200,
      scrollable: scrollable,
    );
    expect(
      tester.getTopLeft(find.text(labels.comicComments)).dy,
      greaterThan(tester.getTopLeft(find.text('Loaded chapter 999')).dy),
    );
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('Origin'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('metadata and chapter failures wait for the entry route', (
    tester,
  ) async {
    final source = _Source()
      ..detailFails = true
      ..chapterGate = Completer<List<ComicChapter>>();
    await pump(
      tester,
      const Scaffold(body: Text('Origin')),
      _Library(),
      source,
      settle: false,
    );
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    final route = MaterialPageRoute<void>(
      builder: (_) => const ComicDetailScreen(comic: _comic),
    );
    navigator.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(source.detailRequests, 1);
    expect(source.chapterRequests, 1);
    expect(find.text('detail unavailable'), findsNothing);
    expect(find.text('chapters unavailable'), findsNothing);
    expect(find.text('Chapter 1'), findsNothing);

    source.chapterGate!.complete(_comic.chapters);
    await tester.pump();
    expect(find.text('detail unavailable'), findsNothing);
    expect(find.text('Chapter 1'), findsNothing);

    await tester.pumpAndSettle();
    expect(find.text('detail unavailable'), findsOneWidget);
    expect(find.text('chapters unavailable'), findsNothing);
    final scrollable = find
        .descendant(
          of: find.byType(ComicDetailScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Chapter 1'),
      400,
      scrollable: scrollable,
    );
    expect(find.text('Chapter 1'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('popping detail before metadata returns drops the late result', (
    tester,
  ) async {
    final source = _Source()..detailGate = Completer<Comic>();
    await pump(
      tester,
      const Scaffold(body: Text('Origin')),
      _Library(),
      source,
      settle: false,
    );
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    final route = MaterialPageRoute<void>(
      builder: (_) => const ComicDetailScreen(comic: _comic),
    );
    navigator.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(source.detailRequests, 1);
    navigator.pop();
    await tester.pumpAndSettle();

    source.detailGate!.complete(
      const Comic(source: 'fixture', id: 'book', title: 'Late metadata'),
    );
    await tester.pump();
    expect(find.text('Origin'), findsOneWidget);
    expect(find.text('Late metadata'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail keeps list-only dates for local favorites', (
    tester,
  ) async {
    const listing = Comic(
      source: 'fixture',
      id: 'book',
      title: 'Fixture book',
      cover: 'fixture-cover',
      extra: {
        'sourceDate': '2024-05-12',
        'publishedAt': '2024-04-11',
        'updatedAt': '2024-05-12',
      },
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
    expect(library.lastFavorite?.publishedDate, '2024-04-11');
    expect(library.lastFavorite?.updatedDate, '2024-05-12');
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
        for (final overlay in [top, bottom]) {
          final slide = tester.widget<AnimatedSlide>(overlay);
          expect(
            slide.duration,
            reduceMotion ? Duration.zero : const Duration(milliseconds: 300),
          );
          expect(slide.curve, Curves.ease);
          expect(
            find.descendant(
              of: overlay,
              matching: find.byType(AnimatedOpacity),
            ),
            findsNothing,
          );
        }
        expect(find.byType(MiniPlayer), findsOneWidget);
        await tester.tapAt(const Offset(195, 420));
        await tester.pump(const Duration(milliseconds: 300));
        if (!reduceMotion) {
          await tester.pump(const Duration(milliseconds: 150));
          final topPosition = tester.getTopLeft(topMaterial).dy;
          final bottomPosition = tester.getTopLeft(bottomMaterial).dy;
          expect(topPosition, greaterThan(hiddenTop));
          expect(topPosition, lessThan(0));
          expect(bottomPosition, lessThan(hiddenBottom));
          await tester.pump(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byType(FutureBuilder<Uint8List>).first),
          page,
        );
        if (!reduceMotion) {
          final topSlide = tester.widget<AnimatedSlide>(top);
          final bottomSlide = tester.widget<AnimatedSlide>(bottom);
          expect(topSlide.offset, Offset.zero);
          expect(bottomSlide.offset, Offset.zero);
        }
        expect(readerPageValue('4/8'), findsOneWidget);
        expect(find.byType(MiniPlayer), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        for (final overlay in [top, bottom]) {
          expect(
            tester
                .widget<IgnorePointer>(
                  find
                      .ancestor(
                        of: overlay,
                        matching: find.byType(IgnorePointer),
                      )
                      .first,
                )
                .ignoring,
            isTrue,
          );
          expect(
            tester
                .widget<ExcludeFocus>(
                  find
                      .ancestor(
                        of: overlay,
                        matching: find.byType(ExcludeFocus),
                      )
                      .first,
                )
                .excluding,
            isTrue,
          );
          expect(
            tester
                .widget<ExcludeSemantics>(
                  find
                      .ancestor(
                        of: overlay,
                        matching: find.byType(ExcludeSemantics),
                      )
                      .first,
                )
                .excluding,
            isTrue,
          );
        }
        expect(
          tester.getRect(find.byType(FutureBuilder<Uint8List>).first),
          page,
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
      const Scaffold(body: Text('Origin')),
      library,
      source,
      settle: false,
    );
    final navigator = Navigator.of(tester.element(find.text('Origin')));
    final route = MaterialPageRoute<void>(
      builder: (_) => const ComicDetailScreen(comic: _comic),
    );
    navigator.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Chapter 1'), findsNothing);
    expect(source.detailRequests, 0);
    expect(source.chapterRequests, 0);
    await tester.pumpAndSettle();
    expect(source.detailRequests, 0);
    expect(source.chapterRequests, 0);
    final cover = tester.widget<ComicImage>(
      find.descendant(
        of: find.byKey(const ValueKey('comic-detail-cover')),
        matching: find.byType(ComicImage),
      ),
    );
    expect(cover.page.localPath, 'offline-cover');
    await tester.scrollUntilVisible(
      find.text('Chapter 1'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ComicDetailScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Chapter 1'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
  });

  for (final layout in LayoutType.values) {
    testWidgets(
      'comic $layout high-resolution cover stays sized into detail and returns',
      (tester) async {
        await StorageService.setString('comic_layout_type', layout.name);
        tester.view.physicalSize = const Size(780, 1688);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await pump(
          tester,
          const Scaffold(body: ComicGrid(comics: [_comic])),
          _Library(),
          _Source(),
          loadImage: (_) async => Uint8List.fromList(_highResolutionPng),
        );
        await waitForComicCardImage(tester, 'Fixture book');
        final cardCover = find.byType(ComicCover);
        await expectComicCoverDecodeMatchesDisplay(tester, cardCover, 1800);
        final sourceImage = find.descendant(
          of: cardCover,
          matching: find.byType(Image),
        );
        final sourceProvider = tester.widget<Image>(sourceImage).image;
        final sourceKey = await sourceProvider.obtainKey(
          ImageConfiguration.empty,
        );
        final hero = find.descendant(
          of: find.byType(ComicCover),
          matching: find.byType(Hero),
        );
        expect(hero, findsNothing);
        final start = tester.getRect(find.byType(ComicImage).first);
        await tester.tap(find.text('Fixture book'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(ComicDetailScreen), findsOneWidget);
        expect(hero, findsNothing);
        expectVisibleComicCoverRatio(tester, 180 / 100);
        expectComicCoversAttached();
        final detailCoverFinder = find.byKey(
          const ValueKey('comic-detail-cover'),
        );
        final route = ModalRoute.of(tester.element(detailCoverFinder))!;
        expect(route.animation!.status, AnimationStatus.forward);
        for (
          var frame = 0;
          frame < 20 && route.animation!.status != AnimationStatus.completed;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(route.animation!.status, AnimationStatus.completed);
        final detailImageFinder = find.descendant(
          of: detailCoverFinder,
          matching: find.byType(Image),
        );
        final heldProvider = tester.widget<Image>(detailImageFinder).image;
        expect(
          await heldProvider.obtainKey(ImageConfiguration.empty),
          sourceKey,
        );
        await tester.pump();
        final upgradedProvider = tester.widget<Image>(detailImageFinder).image;
        expect(upgradedProvider, isA<ResizeImage>());
        final upgradedWidth = (upgradedProvider as ResizeImage).width!;
        final sourceWidth = (sourceProvider as ResizeImage).width!;
        expect(
          upgradedWidth,
          layout == LayoutType.list ? greaterThan(sourceWidth) : sourceWidth,
        );
        await tester.pumpAndSettle();
        final destination = tester.getRect(
          find.byKey(const ValueKey('comic-detail-cover')),
        );
        await expectComicCoverDecodeMatchesDisplay(
          tester,
          find.byKey(const ValueKey('comic-detail-cover')),
          1800,
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
        expectComicCoversAttached();
        await tester.pumpAndSettle();
        expect(find.byType(ComicDetailScreen), findsNothing);
        expect(tester.getRect(find.byType(ComicImage).first), start);
        await expectComicCoverDecodeMatchesDisplay(
          tester,
          find.byType(ComicCover),
          1800,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('comic detail cover resize width is capped by source width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      const ComicDetailScreen(comic: _comic),
      _Library(),
      _Source(),
      loadImage: (_) async => _png,
    );
    final detailCover = find.byKey(const ValueKey('comic-detail-cover'));
    await expectComicCoverDecodeMatchesDisplay(tester, detailCover, 100);
  });

  testWidgets('detail cover stays loaded while the reader covers and returns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(
      tester,
      const ComicDetailScreen(comic: _comic),
      _Library(),
      _Source(),
      loadImage: (_) async => _widePng,
    );
    final detailCover = find.byKey(const ValueKey('comic-detail-cover'));
    final detailImage = find.descendant(
      of: detailCover,
      matching: find.byType(Image),
    );
    await waitForDecodedImage(tester, detailImage);
    final initialProvider = tester.widget<Image>(detailImage).image;
    final initialKey = await initialProvider.obtainKey(
      ImageConfiguration.empty,
    );

    await tester.tap(find.text('Start reading'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final coveredDetail = find.byKey(
      const ValueKey('comic-detail-cover'),
      skipOffstage: false,
    );
    final coveredImage = find.descendant(
      of: coveredDetail,
      matching: find.byType(Image),
      skipOffstage: false,
    );
    expect(coveredImage, findsOneWidget);
    expect(
      await tester
          .widget<Image>(coveredImage)
          .image
          .obtainKey(ImageConfiguration.empty),
      initialKey,
    );

    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(ComicReaderScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      await tester
          .widget<Image>(coveredImage)
          .image
          .obtainKey(ImageConfiguration.empty),
      initialKey,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed replacement cover keeps the decoded listing image', (
    tester,
  ) async {
    final updated = Comic(
      source: 'fixture',
      id: 'book',
      title: 'Fixture book',
      cover: 'changed-cover',
      chapters: _comic.chapters,
    );
    final source = _Source()..detailGate = Completer<Comic>();
    final loadedPages = <String?>[];
    await pump(
      tester,
      const ComicDetailScreen(comic: _comic),
      _Library(),
      source,
      settle: false,
      loadImage: (page) {
        loadedPages.add(page.url);
        if (page.url == 'changed-cover') {
          return Future.error(StateError('replacement unavailable'));
        }
        return Future.value(_widePng);
      },
    );
    await waitForCoverBytes(tester, _widePng);
    source.detailGate!.complete(updated);
    await tester.pumpAndSettle();
    expect(loadedPages, contains('changed-cover'));
    expect(memoryImageForBytes(_widePng), findsOneWidget);
    final raw = find.descendant(
      of: find.byKey(const ValueKey('comic-detail-cover')),
      matching: find.byType(RawImage),
    );
    expect(tester.widget<RawImage>(raw).image, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search cover stays with its page into detail', (tester) async {
    await pump(
      tester,
      const ComicSearchScreen(initialSource: 'fixture', initialQuery: 'book'),
      _Library(),
      _Source(),
      loadImage: (_) async => _widePng,
    );
    await tester.tap(find.text('Grouped results'));
    await tester.pumpAndSettle();
    final hero = find.descendant(
      of: find.byType(ComicCover),
      matching: find.byType(Hero),
    );
    expect(hero, findsNothing);
    final start = tester.getRect(find.byType(WorkCoverClip));
    expect(start.width / start.height, closeTo(180 / 100, 0.001));
    await tester.tap(find.text('Fixture book'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expectVisibleComicCoverRatio(tester, 180 / 100);
    expectComicCoversAttached();
    await tester.pumpAndSettle();
    expect(find.byType(ComicDetailScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expectVisibleComicCoverRatio(tester, 180 / 100);
    expectComicCoversAttached();
    await tester.pumpAndSettle();
    expect(hero, findsNothing);
  });

  testWidgets('reduced motion omits the comic cover Hero', (tester) async {
    await pump(
      tester,
      const Scaffold(body: ComicGrid(comics: [_comic])),
      _Library(),
      _Source(),
      reduceMotion: true,
    );
    final hero = find.descendant(
      of: find.byType(ComicCover),
      matching: find.byType(Hero),
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
      expect(find.byType(Card), findsOneWidget);
      expectComicCardHidden(tester);
      expect(find.text('Fixture book'), findsOneWidget);
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

  for (final layout in LayoutType.values) {
    testWidgets(
      'unselected comic cover remains visible on detail return ($layout)',
      (tester) async {
        await StorageService.setString('comic_layout_type', layout.name);
        const other = Comic(
          source: 'fixture',
          id: 'other',
          title: 'Other comic',
          cover: 'other-cover',
        );
        var loads = 0;
        await pump(
          tester,
          const Scaffold(body: ComicGrid(comics: [_comic, other])),
          _Library(),
          _Source(),
          loadImage: (_) {
            loads++;
            return Future.value(Uint8List.fromList(_widePng));
          },
        );
        await waitForComicCardImage(tester, 'Fixture book');
        await waitForComicCardImage(tester, 'Other comic');
        final cover = find.byWidgetPredicate(
          (widget) =>
              widget is ComicCover &&
              widget.source == other.source &&
              widget.page.url == other.cover,
        );
        final raw = find.descendant(of: cover, matching: find.byType(RawImage));
        expect(tester.widget<RawImage>(raw).image, isNotNull);
        final image = tester.widget<Image>(
          find.descendant(of: cover, matching: find.byType(Image)),
        );
        final cacheKey = await image.image.obtainKey(ImageConfiguration.empty);
        final originalState = tester.state(cover);
        await tester.tap(find.text('Fixture book'));
        await tester.pumpAndSettle();
        PaintingBinding.instance.imageCache.clear();
        final cacheStatus = PaintingBinding.instance.imageCache.statusForKey(
          cacheKey,
        );
        expect(cacheStatus.live, isFalse);
        expect(cacheStatus.keepAlive, isFalse);
        expect(cacheStatus.pending, isFalse);
        await tester.tap(find.byTooltip('Back'));
        await tester.pump();
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.state(cover), same(originalState));
          expect(raw, findsOneWidget, reason: 'frame=$frame');
          expect(
            tester.widget<RawImage>(raw).image,
            isNotNull,
            reason: 'frame=$frame',
          );
        }
        expect(loads, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('loaded comic cover stays visible throughout page push and pop', (
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
    await waitForComicCardImage(tester, 'Fixture book');
    expect(loads, 1);
    await tester.tap(find.text('Fixture book'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(loads, 1);
    expect(find.byType(ComicImage), findsWidgets);
    expectVisibleComicCoverRatio(tester, 180 / 100);
    expectComicCoversAttached();
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
    expectComicCoversAttached();
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
    testWidgets(
      'dated $grid card keeps its badge rule during page transitions',
      (tester) async {
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
      },
    );
  }

  for (final size in [const Size(390, 844), const Size(700, 360)]) {
    testWidgets('reading button centers a longer translation at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final library = _Library()
        ..last = ComicProgress(_comic, 'one', 0, DateTime(2026));
      await pump(
        tester,
        Builder(
          builder: (context) => Localizations.override(
            context: context,
            locale: const Locale('en'),
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: const ComicDetailScreen(comic: _comic),
            ),
          ),
        ),
        library,
        _Source(),
      );
      final buttonFinder = find.ancestor(
        of: find.text('Continue reading'),
        matching: find.byType(FilledButton),
      );
      final button = tester.getRect(buttonFinder);
      final icon = tester.getRect(
        find.descendant(
          of: buttonFinder,
          matching: find.byIcon(Icons.menu_book),
        ),
      );
      final label = tester.getRect(find.text('Continue reading'));
      expect(icon.left, greaterThan(button.left));
      expect(label.right, lessThan(button.right));
      expect((icon.left + label.right) / 2, closeTo(button.center.dx, 2));
      expect(icon.center.dy, closeTo(button.center.dy, 2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'failed cover keeps its placeholder through page transitions and retries',
    (tester) async {
      final pending = Completer<Uint8List>();
      var loads = 0;
      await pump(
        tester,
        const Scaffold(body: ComicGrid(comics: [_comic])),
        _Library(),
        _Source(),
        loadImage: (_) =>
            ++loads == 1 ? pending.future : Future.value(_widePng),
        settle: false,
      );
      expect(find.byType(Card), findsOneWidget);
      expectComicCardHidden(tester);
      pending.completeError(StateError('cover failed'));
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsOneWidget);
      await tester.tap(find.text('Fixture book'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final cover = tester.getRect(find.byType(ComicImage).first);
      expect(cover.width / cover.height, closeTo(2 / 3, 0.001));
      expectComicCoversAttached();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Retry'), findsWidgets);
      await tester.tap(find.byTooltip('Retry').last);
      await tester.pumpAndSettle();
      expect(loads, 2);
      expectVisibleComicCoverRatio(tester, 180 / 100);
      expect(tester.takeException(), isNull);
    },
  );

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
      expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsOneWidget);
      expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
      expect(
        tester.getRect(find.byKey(appBottomDockMiniPlayerHandoffRootKey)).top,
        greaterThan(sourceRect.top),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ComicDetailScreen), findsOneWidget);
      expect(find.byType(MiniPlayer), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsOneWidget);
      expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
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
      expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsOneWidget);
      expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(ComicSearchScreen), findsOneWidget);
      expect(find.byType(MiniPlayer), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsOneWidget);
      expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(ComicSearchScreen), findsNothing);
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'comic categories and nested results hand off the Dock without artwork flights',
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
      await tester.tap(find.byTooltip('Categories').first);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsOneWidget);
      expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(appBottomDockMiniPlayerHandoffRootKey)).dx,
        0,
      );
      expect(
        find.byKey(const ValueKey('player-artwork-flight-frame')),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ComicCategoryScreen), findsOneWidget);
      expect(find.byType(MiniPlayer), findsOneWidget);
      await tester.tap(find.text('Fixture category'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final nestedDock = tester.getRect(
        find.byKey(appBottomDockMiniPlayerHandoffRootKey),
      );
      expect(nestedDock.left, 0);
      expect(nestedDock.bottom, 844);
      expect(
        find.byKey(const ValueKey('player-artwork-flight-frame')),
        findsNothing,
      );
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(ComicSearchScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.getRect(find.byKey(appBottomDockMiniPlayerHandoffRootKey)),
        nestedDock,
      );
      expect(
        find.byKey(const ValueKey('player-artwork-flight-frame')),
        findsNothing,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(appBottomDockMiniPlayerHandoffRootKey), findsOneWidget);
      expect(find.byKey(appBottomDockTabBarHandoffRootKey), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(appBottomDockMiniPlayerHandoffRootKey)).dx,
        0,
      );
      expect(
        find.byKey(const ValueKey('player-artwork-flight-frame')),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ComicCategoryScreen), findsNothing);
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
  for (final loggedIn in [false, true]) {
    testWidgets(
      'comic home ignores online favorites preference when loggedIn=$loggedIn',
      (tester) async {
        await StorageService.setBool('comic_online_favorites', true);
        final source = _Source()..loggedIn = loggedIn;
        final container = await pump(
          tester,
          const ComicScreen(),
          _Library(),
          source,
        );

        expect(find.text('Fixture book'), findsOneWidget);
        expect(find.text('Online favorite'), findsNothing);
        expect(source.favoriteReads, 0);

        container.read(comicSettingsRevisionProvider.notifier).state++;
        await tester.pumpAndSettle();
        expect(find.text('Fixture book'), findsOneWidget);
        expect(source.favoriteReads, 0);

        await tester.tap(find.text('Favorites').first);
        await tester.pumpAndSettle();
        if (loggedIn) {
          expect(find.text('Online favorite'), findsOneWidget);
          expect(source.favoriteReads, 1);
        } else {
          expect(
            find.text('Sign in to this source in comic settings.'),
            findsOneWidget,
          );
          expect(source.favoriteReads, 0);
        }

        await tester.tap(find.text('Home').first);
        await tester.pumpAndSettle();
        expect(find.text('Fixture book'), findsOneWidget);
      },
    );
  }

  testWidgets('comic tabs preserve home content after switching to history', (
    tester,
  ) async {
    const historyComic = Comic(
      source: 'fixture',
      id: 'history',
      title: 'History book',
      cover: 'history-cover',
    );
    final historyGate = Completer<Uint8List>();
    var homeLoads = 0;
    var historyLoads = 0;
    final library = _Library()
      ..last = ComicProgress(historyComic, 'one', 0, DateTime(2026));
    await pump(
      tester,
      const ComicScreen(),
      library,
      _Source(),
      loadImage: (page) {
        if (page.url == historyComic.cover) {
          historyLoads++;
          return historyGate.future;
        }
        homeLoads++;
        return Future.value(_widePng);
      },
    );
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('Fixture book'), findsOneWidget);
    await waitForComicCardImage(tester, 'Fixture book');
    final homeCover = find.byWidgetPredicate(
      (widget) => widget is ComicCover && widget.page.url == _comic.cover,
      skipOffstage: false,
    );
    final homeState = tester.state(homeCover);
    final homeRawImage = find.descendant(
      of: homeCover,
      matching: find.byType(RawImage),
    );
    expect(tester.widget<RawImage>(homeRawImage).image, isNotNull);
    expect(homeLoads, 1);

    await tester.tap(find.text('History').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(historyLoads, 1);
    expect(homeCover, findsOneWidget);
    expect(tester.state(homeCover), same(homeState));
    expect(tester.widget<ComicCover>(homeCover).loadImage, isTrue);
    expect(find.text('History book', skipOffstage: false), findsOneWidget);
    historyGate.complete(_png);
    await tester.pumpAndSettle();
    await waitForComicCardImage(tester, 'History book');
    expectComicCardReady(tester, 'History book');

    await tester.tap(find.text('Home').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final historyCover = find.byWidgetPredicate(
      (widget) => widget is ComicCover && widget.page.url == historyComic.cover,
      skipOffstage: false,
    );
    expect(historyCover, findsOneWidget);
    final historyState = tester.state(historyCover);
    expect(tester.widget<ComicCover>(historyCover).loadImage, isTrue);
    expect(homeCover, findsOneWidget);
    expect(tester.state(homeCover), same(homeState));
    await tester.pumpAndSettle();
    expect(tester.state(historyCover), same(historyState));
    expectComicCardReady(tester, 'Fixture book');
    expect(find.text('Fixture book'), findsOneWidget);
    expect(historyLoads, 1);
    expect(homeLoads, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'first main comic switch prepares its cover during outer paging',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = _Source();
      var coverRequests = 0;
      await pump(
        tester,
        ProviderScope(
          overrides: [
            worksProvider.overrideWith((ref) => _IdleWorks(ref)),
            downloadSummaryProvider.overrideWith(
              (ref) => Stream.value(const DownloadTaskSummary.empty()),
            ),
            downloadTaskIdsProvider.overrideWith(
              (ref) => Stream.value(<String>[]),
            ),
          ],
          child: const MainScreen(),
        ),
        _Library(),
        source,
        loadImage: (_) {
          coverRequests++;
          return Future.value(_png);
        },
      );
      final pagesFinder = find.byKey(const ValueKey('main-tab-pages'));
      final pages = tester.widget<PageView>(pagesFinder).controller!;
      final navigation = find.byType(NavigationBar);
      void select(int index) => tester
          .widget<NavigationBar>(navigation)
          .onDestinationSelected!(index);

      select(1);
      await tester.pump();
      expect(pages.page, 0);
      expect(source.searches, 1);
      final comicState = tester.state(
        find.byType(ComicScreen, skipOffstage: false),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(pages.page, inExclusiveRange(0, 1));
      expect(find.byType(ComicCover, skipOffstage: false), findsOneWidget);
      expect(coverRequests, greaterThan(0));
      final preparedRequests = coverRequests;
      final pageView = tester.widget<PageView>(pagesFinder);
      expect(pageView.scrollCacheExtent.value, 0);
      expect(pageView.allowImplicitScrolling, isFalse);

      select(0);
      await tester.pump();
      await pumpFrames(tester, frames: 25);
      expect(pages.page, 0);
      expect(coverRequests, preparedRequests);
      select(1);
      await tester.pump();
      await pumpFrames(tester, frames: 25);
      expect(find.byType(ComicCover), findsWidgets);
      expect(coverRequests, preparedRequests);
      expect(tester.state(find.byType(ComicScreen)), same(comicState));
      select(0);
      await tester.pump();
      await pumpFrames(tester, frames: 25);
      select(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ComicCover), findsWidgets);
      expect(coverRequests, preparedRequests);
      expect(source.searches, 1);
      expect(tester.state(find.byType(ComicScreen)), same(comicState));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'comic grid warms the current slice and reuses display-size decoded covers',
    (tester) async {
      await StorageService.setString('comic_layout_type', LayoutType.list.name);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final comics = List.generate(
        12,
        (index) => Comic(
          source: 'fixture',
          id: 'prefetch-$index',
          title: 'Prefetch $index',
          cover: 'prefetch-cover-$index',
        ),
      );
      final gates = {
        for (var index = 0; index < comics.length; index++)
          comics[index].cover: Completer<Uint8List>(),
      };
      final bytes = {
        for (var index = 0; index < comics.length; index++)
          comics[index].cover: Uint8List.fromList(_png),
      };
      final starts = <String, int>{};
      await pump(
        tester,
        Scaffold(body: ComicGrid(comics: comics)),
        _Library(),
        _Source(),
        loadImage: (page) {
          starts.update(page.url, (count) => count + 1, ifAbsent: () => 1);
          return gates[page.url]!.future;
        },
        settle: false,
      );

      expect(starts, isNotEmpty);
      expect(starts.length, lessThan(comics.length));
      expect(
        starts.length,
        lessThanOrEqualTo(2),
        reason: 'Visible cards must enter the bounded queue before loading.',
      );
      final initiallyStarted = starts.keys.toSet();
      final grid = find.byType(ComicGrid);
      final scrollable = find
          .descendant(of: grid, matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(
        find.text('Prefetch ${comics.length - 1}'),
        240,
        scrollable: scrollable,
      );
      final viewportRect = tester.getRect(
        find.descendant(of: scrollable, matching: find.byType(Viewport)).first,
      );
      final newlyVisible = <String>{};
      for (final comic in comics) {
        final title = find.text(comic.title);
        if (title.evaluate().isNotEmpty &&
            tester.getRect(title.first).overlaps(viewportRect)) {
          newlyVisible.add(comic.cover);
        }
      }
      expect(newlyVisible, isNotEmpty);
      expect(
        starts.keys.toSet(),
        initiallyStarted,
        reason:
            'Fast scrolling must keep the original two requests bounded while '
            'they are still pending.',
      );
      for (final url in initiallyStarted) {
        gates[url]!.complete(bytes[url]!);
      }
      for (
        var frame = 0;
        frame < 12 && starts.length == initiallyStarted.length;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      final firstAfterScroll = starts.keys
          .where((url) => !initiallyStarted.contains(url))
          .toSet();
      expect(firstAfterScroll, isNotEmpty);
      expect(
        firstAfterScroll,
        everyElement(isIn(newlyVisible)),
        reason: 'Newly visible covers must precede queued background covers.',
      );
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pump();
      for (
        var frame = 0;
        frame < 120 && starts.length < comics.length;
        frame++
      ) {
        for (final url in starts.keys.toList()) {
          final gate = gates[url]!;
          if (!gate.isCompleted) gate.complete(bytes[url]!);
        }
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(starts.keys.toSet(), {for (final comic in comics) comic.cover});
      expect(starts.values, everyElement(1));
      for (final url in starts.keys) {
        final gate = gates[url]!;
        if (!gate.isCompleted) gate.complete(bytes[url]!);
      }
      await tester.pump();

      final prefetchedBytes = bytes[comics.last.cover]!;
      final prefetchedProvider = ResizeImage(
        MemoryImage(prefetchedBytes),
        width: 80,
      );
      final prefetchedKey = await prefetchedProvider.obtainKey(
        ImageConfiguration.empty,
      );
      var prefetchedStatus = PaintingBinding.instance.imageCache.statusForKey(
        prefetchedKey,
      );
      for (var frame = 0; frame < 120 && !prefetchedStatus.keepAlive; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        prefetchedStatus = PaintingBinding.instance.imageCache.statusForKey(
          prefetchedKey,
        );
      }
      for (var frame = 0; frame < 8 && prefetchedStatus.live; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        prefetchedStatus = PaintingBinding.instance.imageCache.statusForKey(
          prefetchedKey,
        );
      }
      expect(
        prefetchedStatus.keepAlive,
        isTrue,
        reason:
            'Background work should warm the exact 80px display decode; '
            'status=$prefetchedStatus.',
      );
      expect(
        prefetchedStatus.live,
        isFalse,
        reason: 'Page prefetch must release its temporary image listener.',
      );

      await tester.scrollUntilVisible(
        find.text('Prefetch ${comics.length - 1}'),
        240,
        scrollable: scrollable,
      );
      await waitForComicCardImage(tester, 'Prefetch ${comics.length - 1}');
      expect(starts[comics.last.cover], 1);
      expect(memoryImageForBytes(prefetchedBytes), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('comic grid reprioritizes cards revealed by wide cover ratios', (
    tester,
  ) async {
    await StorageService.setString('comic_layout_type', LayoutType.list.name);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final comics = List.generate(
      12,
      (index) => Comic(
        source: 'fixture',
        id: 'wide-prefetch-$index',
        title: 'Wide Prefetch $index',
        cover: 'wide-prefetch-cover-$index',
      ),
    );
    final starts = <String, int>{};
    await pump(
      tester,
      Scaffold(body: ComicGrid(comics: comics)),
      _Library(),
      _Source(),
      loadImage: (page) {
        starts.update(page.url, (count) => count + 1, ifAbsent: () => 1);
        return Future.value(_widePng);
      },
      settle: false,
    );

    for (var frame = 0; frame < 120 && starts.length < comics.length; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }

    final scrollable = find
        .descendant(
          of: find.byType(ComicGrid),
          matching: find.byType(Scrollable),
        )
        .first;
    final viewportRect = tester.getRect(
      find.descendant(of: scrollable, matching: find.byType(Viewport)).first,
    );
    final visibleTitles = <String>[];
    for (final comic in comics) {
      final title = find.text(comic.title, skipOffstage: false);
      if (title.evaluate().isNotEmpty &&
          tester.getRect(title.first).overlaps(viewportRect)) {
        visibleTitles.add(comic.title);
      }
    }

    expect(starts.keys, containsAll(comics.map((comic) => comic.cover)));
    expect(visibleTitles.length, greaterThan(2));
    for (final title in visibleTitles) {
      expectComicCardReady(tester, title);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving a motion-prepared comic page stops pending cover work', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _BatchSource();
    final gates = <String, Completer<Uint8List>>{};
    var coverRequests = 0;
    await pump(
      tester,
      ProviderScope(
        overrides: [
          worksProvider.overrideWith((ref) => _IdleWorks(ref)),
          downloadSummaryProvider.overrideWith(
            (ref) => Stream.value(const DownloadTaskSummary.empty()),
          ),
          downloadTaskIdsProvider.overrideWith(
            (ref) => Stream.value(<String>[]),
          ),
        ],
        child: const MainScreen(),
      ),
      _Library(),
      source,
      loadImage: (page) {
        coverRequests++;
        return gates.putIfAbsent(page.url, Completer<Uint8List>.new).future;
      },
    );
    final navigation = find.byType(NavigationBar);
    void select(int index) =>
        tester.widget<NavigationBar>(navigation).onDestinationSelected!(index);

    select(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ComicCover, skipOffstage: false), findsWidgets);
    expect(coverRequests, greaterThan(0));
    expect(coverRequests, lessThan(12));

    await pumpFrames(tester, frames: 25);
    final pendingRequests = coverRequests;
    expect(pendingRequests, lessThan(12));

    select(0);
    await tester.pump();
    await pumpFrames(tester, frames: 5);
    expect(coverRequests, pendingRequests);

    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete(_png);
    }
    await pumpFrames(tester, frames: 5);
    expect(
      coverRequests,
      pendingRequests,
      reason:
          'Resolving an already-started cover after leaving the tab must not '
          'start queued background covers.',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('retrying a visible comic cover stays inside the bounded queue', (
    tester,
  ) async {
    await StorageService.setString('comic_layout_type', LayoutType.list.name);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final comics = List.generate(
      12,
      (index) => Comic(
        source: 'fixture',
        id: 'retry-$index',
        title: 'Retry $index',
        cover: 'retry-cover-$index',
      ),
    );
    final firstFailure = Completer<Uint8List>();
    final firstRetry = Completer<Uint8List>();
    final secondCover = Completer<Uint8List>();
    final thirdCover = Completer<Uint8List>();
    final starts = <String, int>{};
    var activeLoads = 0;
    var maxActiveLoads = 0;
    Future<Uint8List> loadImage(ComicPage page) {
      final attempt = starts.update(
        page.url,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      activeLoads++;
      maxActiveLoads = math.max(maxActiveLoads, activeLoads);
      final future = switch (page.url) {
        'retry-cover-0' when attempt == 1 => firstFailure.future,
        'retry-cover-0' => firstRetry.future,
        'retry-cover-1' => secondCover.future,
        'retry-cover-2' => thirdCover.future,
        _ => Future<Uint8List>.value(_png),
      };
      return future.whenComplete(() => activeLoads--);
    }

    await pump(
      tester,
      Scaffold(body: ComicGrid(comics: comics)),
      _Library(),
      _Source(),
      loadImage: loadImage,
      settle: false,
    );
    expect(starts.keys.toSet(), {'retry-cover-0', 'retry-cover-1'});
    expect(activeLoads, 2);

    firstFailure.completeError(StateError('cover failed'));
    for (
      var frame = 0;
      frame < 24 && find.byTooltip('Retry').evaluate().isEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(find.byTooltip('Retry'), findsWidgets);
    expect(starts['retry-cover-2'], 1);
    expect(activeLoads, 2);

    await tester.tap(find.byTooltip('Retry').first);
    await tester.pump();
    expect(
      starts['retry-cover-0'],
      1,
      reason: 'Retry must wait for a queue slot before invalidating the image.',
    );
    secondCover.complete(_png);
    for (var frame = 0; frame < 24 && starts['retry-cover-0'] != 2; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(starts['retry-cover-0'], 2);
    expect(maxActiveLoads, lessThanOrEqualTo(2));

    firstRetry.complete(_png);
    thirdCover.complete(_png);
    await waitForComicCardImage(tester, 'Retry 0');
    expect(maxActiveLoads, lessThanOrEqualTo(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'first comic History click warms its cover before page movement',
    (tester) async {
      const historyComic = Comic(
        source: 'fixture',
        id: 'history',
        title: 'History book',
        cover: 'history-cover',
      );
      final library = _Library()
        ..last = ComicProgress(historyComic, 'one', 0, DateTime(2026));
      final historyCover = Completer<Uint8List>();
      var historyCoverLoads = 0;
      await pump(
        tester,
        const ComicScreen(),
        library,
        _Source(),
        loadImage: (page) {
          if (page.url == historyComic.cover) {
            historyCoverLoads++;
            return historyCover.future;
          }
          return Future.value(_png);
        },
      );
      await waitForComicCardImage(tester, 'Fixture book');
      final pages = tester
          .widget<PageView>(find.byKey(const ValueKey('comic-tab-pages')))
          .controller!;
      double? readAtPage;
      library.onHistoryRead = () => readAtPage = pages.page;
      expect(library.historyReads, 0);
      await tester.tap(find.text('History').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(readAtPage, 0);
      final historyCovers = find.descendant(
        of: find.byKey(const ValueKey('comic-tab-2'), skipOffstage: false),
        matching: find.byType(ComicCover, skipOffstage: false),
      );
      expect(historyCovers, findsOneWidget);
      expect(historyCoverLoads, 1);
      final pageView = tester.widget<PageView>(
        find.byKey(const ValueKey('comic-tab-pages')),
      );
      expect(pageView.scrollCacheExtent.value, 0);
      expect(pageView.allowImplicitScrolling, isFalse);
      historyCover.complete(_png);
      await tester.pumpAndSettle();
      expect(pages.page, 2);
      expect(library.historyReads, 1);
      expect(historyCovers, findsOneWidget);
      expectComicCardReady(tester, 'History book');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('comic tab clicks use ease paging and retain the home page', (
    tester,
  ) async {
    await pump(tester, const ComicScreen(), _Library(), _Source());
    final pagesFinder = find.byKey(const ValueKey('comic-tab-pages'));
    final pages = tester.widget<PageView>(pagesFinder).controller!;
    final tabs = tester.widget<TabBar>(find.byType(TabBar)).controller!;
    final home = tester.state(find.byKey(const ValueKey('comic-tab-0')));
    await tester.tap(find.text('History').first);
    await tester.pump();
    expect(pages.page, 0);
    expect(tabs.animation!.value, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(pages.page, closeTo(2 * Curves.ease.transform(1 / 3), .001));
    expect(tabs.animation!.value, closeTo(pages.page!, .001));
    await tester.pump(const Duration(milliseconds: 199));
    expect(pages.page, lessThan(2));
    await tester.pump(const Duration(milliseconds: 1));
    expect(pages.page, 2);
    await tester.tap(find.text('Home').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final from = pages.page!;
    await tester.tap(find.text('Favorites').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      pages.page,
      closeTo(from + (1 - from) * Curves.ease.transform(1 / 3), .001),
    );
    expect(tabs.animation!.value, closeTo(pages.page!, .001));
    await tester.pumpAndSettle();
    await tester.drag(pagesFinder, const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(pages.page, 0);
    expect(tabs.index, 0);
    expect(tabs.offset, 0);
    expect(tester.state(find.byKey(const ValueKey('comic-tab-0'))), same(home));
    expect(find.text('Fixture book'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('comic reduced motion completes travel without remounting', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    await pump(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: reduced,
        builder: (context, value, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: value),
          child: child!,
        ),
        child: const ComicScreen(),
      ),
      _Library(),
      _Source(),
    );
    final finder = find.byKey(const ValueKey('comic-tab-pages'));
    final element = tester.element(finder);
    final pages = tester.widget<PageView>(finder).controller!;
    final tabs = tester.widget<TabBar>(find.byType(TabBar)).controller!;
    await tester.tap(find.text('History').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(pages.page, inExclusiveRange(0, 2));
    reduced.value = true;
    await tester.pump();
    expect(pages.page, 2);
    expect(tabs.animation!.value, 2);
    expect(tester.element(finder), same(element));
    await tester.tap(find.text('Home').first);
    await tester.pump();
    expect(pages.page, 0);
    expect(tabs.index, 0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'distant comic tab clicks leave intermediate libraries unloaded',
    (tester) async {
      final library = _Library();
      await pump(tester, const ComicScreen(), library, _Source());
      expect(library.favoriteReads, 0);
      expect(library.historyReads, 0);
      await tester.tap(find.text('Downloaded').first);
      await tester.pump();
      await pumpFrames(tester);
      await tester.pumpAndSettle();
      expect(library.favoriteReads, 0);
      expect(library.historyReads, 0);
      await tester.tap(find.text('Home').first);
      await tester.pump();
      await pumpFrames(tester);
      await tester.pumpAndSettle();
      expect(library.favoriteReads, 0);
      expect(library.historyReads, 0);
      await tester.drag(
        find.byKey(const ValueKey('comic-tab-pages')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      expect(library.favoriteReads, 1);
      expect(library.historyReads, 0);
      expect(tester.takeException(), isNull);
    },
  );
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
      expect(readerPageValue('6/8'), findsOneWidget);
      for (final mode in ComicReadingMode.values.where(
        (m) => m != ComicReadingMode.continuous,
      )) {
        container.read(comicReadingModeProvider.notifier).state = mode;
        await tester.pumpAndSettle();
        expect(readerPageValue('6/8'), findsOneWidget, reason: mode.name);
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
      await tester.tap(find.byTooltip('Choose chapters'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Chapter 2'));
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
      expect(readerPageValue('4/8'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mini-player-artwork-frame')));
      await tester.pumpAndSettle();
      expect(find.byType(AudioPlayerScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(AudioPlayerScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(readerPageValue('4/8'), findsOneWidget);
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

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_collection_view.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_details_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_downloads_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_playback_panel.dart';
import 'package:kikoeru_flutter/src/videos/ui/jable_account_screen.dart';
import 'package:kikoeru_flutter/src/videos/missav_browser_adapter.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_verification.dart';
import 'package:kikoeru_flutter/src/videos/jable_client.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_screen.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_search_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_browse_preferences.dart';
import 'package:kikoeru_flutter/src/videos/video_download_task.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/pagination_bar.dart';

typedef _RecommendationHandler =
    Future<VideoRecommendationPage> Function(
      String? cursor,
      int count,
      CancelToken? cancelToken,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'prepares parsed covers before metadata returns and waits before showing cards',
    (tester) async {
      final browseStarted = Completer<void>();
      final browseResult = Completer<VideoCatalogPage>();
      const page = VideoCatalogPage(
        title: 'Prepared catalog',
        url: 'https://missav.ai/cn',
        videos: [
          VideoItem(
            id: 'prepared',
            title: 'Prepared video',
            pageUrl: 'https://missav.ai/cn/prepared',
            cover: 'https://missav.ai/images/prepared.png',
          ),
        ],
      );
      final parsedPage = VideoCatalogPage(
        title: 'Parsed catalog',
        url: page.url,
        videos: const [
          VideoItem(
            id: 'prepared',
            title: 'Parsed video',
            pageUrl: 'https://missav.ai/cn/prepared',
            cover: 'https://missav.ai/images/prepared.png',
          ),
        ],
      );
      final client = _TestMissavClient(
        parsedCatalog: parsedPage,
        browseStarted: browseStarted,
        browseResult: browseResult,
        browseCompleted: Completer<void>(),
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final imageBytes = img.encodePng(img.Image(width: 2, height: 2));
      final imageBody = Completer<List<int>>();
      final imageRequestStarted = Completer<void>();
      final imageClient = _DeferredVideoCoverHttpClient(
        imageBody.future,
        imageRequestStarted: imageRequestStarted,
        contentLength: imageBytes.length,
      );
      final previousHttpClientProvider = debugNetworkImageHttpClientProvider;
      debugNetworkImageHttpClientProvider = () => imageClient;
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        if (!browseResult.isCompleted) browseResult.complete(page);
        if (!imageBody.isCompleted) imageBody.complete(imageBytes);
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        } finally {
          debugNetworkImageHttpClientProvider = previousHttpClientProvider;
        }
      });

      try {
        await tester.pumpWidget(
          _app(client, library, downloads, const VideoScreen()),
        );
        await tester.runAsync(
          () => browseStarted.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw StateError('Browse did not start.'),
          ),
        );
        await tester.pump();
        await tester.runAsync(
          () => imageRequestStarted.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw StateError('Cover request did not start.'),
          ),
        );

        expect(imageClient.requestCount, greaterThan(0));
        expect(find.text('Parsed catalog'), findsNothing);
        expect(find.text('Prepared catalog'), findsNothing);

        browseResult.complete(page);
        await tester.runAsync(
          () => client.browseCompleted!.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw StateError('Browse did not complete.'),
          ),
        );
        await tester.pump();
        expect(find.text('Parsed catalog'), findsNothing);
        expect(find.text('Prepared catalog'), findsNothing);

        await tester.runAsync(() async => imageBody.complete(imageBytes));
        final rawImageFinder = find.byType(RawImage, skipOffstage: false);
        ui.Image? decodedImage;
        for (var attempt = 0; attempt < 10 && decodedImage == null; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          decodedImage = tester.widget<RawImage>(rawImageFinder).image;
        }
        expect(decodedImage, isNotNull);
        await tester.pumpAndSettle();
        expect(find.text('Parsed video'), findsNothing);
        expect(find.text('Prepared catalog'), findsOneWidget);
        expect(find.text('Prepared video'), findsOneWidget);
      } finally {
        debugNetworkImageHttpClientProvider = previousHttpClientProvider;
      }
    },
  );

  testWidgets('opens the localized new releases route by default', (
    tester,
  ) async {
    const releaseUrl = 'https://missav.ai/dm539/cn/release';
    final client = _TestMissavClient(
      sourceHomeUrl: 'https://missav.ai/dm539/cn',
      catalog: const VideoCatalogPage(
        title: 'Source release title',
        url: releaseUrl,
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();

    expect(client.browsedUrls, [releaseUrl]);
    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text(l10n.videoNewReleases), findsOneWidget);
    expect(find.text('Source release title'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    expect(
      (await _videoDrawerTile(tester, l10n.videoNewReleases)).selected,
      isTrue,
    );
    expect(
      (await _videoDrawerTile(tester, l10n.videoRecentlyUpdated)).selected,
      isFalse,
    );
  });

  testWidgets('single metadata filter loads one source page at a time', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const tag = VideoLink(
      label: 'Drama',
      url: 'https://missav.ai/cn/genres/drama',
      kind: VideoLinkKind.category,
    );
    const video = VideoItem(
      id: 'catalog-tagged',
      title: 'Catalog tagged video',
      pageUrl: 'https://missav.ai/cn/catalog-tagged',
      tags: [tag],
    );
    const nextUrl = 'https://missav.ai/cn/genres/drama?page=2';
    const secondFilter = VideoLink(
      label: 'Comedy',
      url: 'https://missav.ai/cn/genres/comedy',
      kind: VideoLinkKind.category,
    );
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Catalog',
        url: 'https://missav.ai/cn/release',
        videos: [video],
      ),
      pagesByUrl: const {
        'https://missav.ai/cn/genres/drama': VideoCatalogPage(
          title: 'Drama',
          url: 'https://missav.ai/cn/genres/drama',
          nextUrl: nextUrl,
          videos: [
            VideoItem(
              id: 'first-tagged',
              title: 'First tagged result',
              pageUrl: 'https://missav.ai/cn/first-tagged',
            ),
          ],
        ),
        nextUrl: VideoCatalogPage(
          title: 'Drama',
          url: nextUrl,
          previousUrl: 'https://missav.ai/cn/genres/drama',
          currentPage: 2,
          videos: [
            VideoItem(
              id: 'second-tagged',
              title: 'Second tagged result',
              pageUrl: 'https://missav.ai/cn/second-tagged',
              tags: [secondFilter],
            ),
          ],
        ),
      },
    );
    addTearDown(client.dispose);
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(tag.label));
    await tester.pumpAndSettle();

    expect(find.byType(VideoSearchScreen), findsOneWidget);
    expect(find.text('First tagged result'), findsOneWidget);
    expect(client.combinedSearchRequests, isEmpty);
    expect(client.browsedUrls.where((url) => url.startsWith(tag.url)), [
      tag.url,
    ]);
    expect(client.browsedUrls, isNot(contains(nextUrl)));

    final l10n = await S.delegate.load(const Locale('en'));
    await _tapNextPage(tester, l10n);
    expect(find.text('Second tagged result'), findsOneWidget);
    expect(find.text('First tagged result'), findsNothing);
    expect(client.browsedUrls.where((url) => url.startsWith(tag.url)), [
      tag.url,
      nextUrl,
    ]);
    expect(client.combinedSearchRequests, isEmpty);
    await tester.tap(find.text(secondFilter.label));
    await tester.pumpAndSettle();
    expect(client.combinedSearchRequests, hasLength(1));
    expect(client.combinedSearchRequests.single.query, '');
    expect(
      client.combinedSearchRequests.single.filters.map((filter) => filter.url),
      [tag.url, secondFilter.url],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'details metadata opens a filtered search and returns to details',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      const tag = VideoLink(
        label: 'Drama',
        url: 'https://missav.ai/cn/genres/drama',
        kind: VideoLinkKind.category,
      );
      const video = VideoItem(
        id: 'detail-tagged',
        title: 'Detail tagged video',
        pageUrl: 'https://missav.ai/cn/detail-tagged',
        tags: [tag],
      );
      final client = _TestMissavClient(
        detailsResult: const VideoDetails(video: video),
      );
      addTearDown(client.dispose);
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoDetailsScreen(
            video: video,
            sessionFactory: _TestVideoPlaybackSession.new,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(tag.label));
      await tester.pumpAndSettle();

      expect(find.byType(VideoSearchScreen), findsOneWidget);
      expect(client.combinedSearchRequests, isEmpty);
      expect(
        tester
            .widget<VideoSearchScreen>(find.byType(VideoSearchScreen))
            .initialFilters
            .map((filter) => filter.url),
        [tag.url],
      );
      expect(client.browsedUrls, contains(tag.url));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(VideoDetailsScreen), findsOneWidget);
      expect(find.byType(VideoSearchScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed cover retries only after tapping retry', (tester) async {
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Failed cover catalog',
        url: 'https://missav.ai/cn',
        videos: [
          VideoItem(
            id: 'failed-cover',
            title: 'Failed cover video',
            pageUrl: 'https://missav.ai/cn/failed-cover',
            cover: 'https://missav.ai/images/failed-cover.png',
          ),
        ],
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final imageClient = _DeferredVideoCoverHttpClient(
      Future.value(const <int>[]),
      contentLength: 0,
      statusCode: HttpStatus.notFound,
    );
    final previousHttpClientProvider = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () => imageClient;
    try {
      await tester.pumpWidget(
        _app(client, library, downloads, const VideoScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Failed cover catalog'), findsOneWidget);
      expect(find.text('Failed cover video'), findsOneWidget);
      expect(imageClient.requestCount, 1);
      expect(find.byTooltip('Retry'), findsOneWidget);

      await tester.tap(find.byTooltip('Retry'));
      await tester.pumpAndSettle();

      expect(imageClient.requestCount, 2);
      expect(find.byTooltip('Retry'), findsOneWidget);
    } finally {
      debugNetworkImageHttpClientProvider = previousHttpClientProvider;
    }
  });

  testWidgets(
    'recommendation failed covers publish retry state without another request',
    (tester) async {
      final client = _TestMissavClient(
        recommendationHandler: (_, _, _) async => const VideoRecommendationPage(
          videos: [
            VideoItem(
              id: 'recommended-failed-cover',
              title: 'Recommended cover video',
              pageUrl: 'https://missav.ai/cn/recommended-failed-cover',
              cover: 'https://missav.ai/images/recommended-failed-cover.png',
            ),
          ],
          cursor: null,
        ),
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final imageClient = _DeferredVideoCoverHttpClient(
        Future.value(const <int>[]),
        contentLength: 0,
        statusCode: HttpStatus.notFound,
      );
      final previousHttpClientProvider = debugNetworkImageHttpClientProvider;
      debugNetworkImageHttpClientProvider = () => imageClient;
      final l10n = await S.delegate.load(const Locale('en'));
      try {
        await tester.pumpWidget(
          _app(client, library, downloads, const VideoScreen()),
        );
        await tester.pumpAndSettle();
        await _selectVideoDrawerLabel(
          tester,
          l10n,
          l10n.videoRecommendedForYou,
        );
        await tester.pumpAndSettle();

        expect(find.text('Recommended cover video'), findsOneWidget);
        expect(imageClient.requestCount, 1);
        expect(find.byTooltip('Retry'), findsOneWidget);

        await tester.pump(const Duration(seconds: 12));
        await tester.pumpAndSettle();
        expect(imageClient.requestCount, 1);
      } finally {
        debugNetworkImageHttpClientProvider = previousHttpClientProvider;
      }
    },
  );

  testWidgets(
    'stalled cover times out without bypassing metadata and retries',
    (tester) async {
      const page = VideoCatalogPage(
        title: 'Stalled cover catalog',
        url: 'https://missav.ai/cn',
        videos: [
          VideoItem(
            id: 'stalled-cover',
            title: 'Stalled cover video',
            pageUrl: 'https://missav.ai/cn/stalled-cover',
            cover: 'https://missav.ai/images/stalled-cover.png',
          ),
        ],
      );
      final metadata = Completer<VideoCatalogPage>();
      final client = _TestMissavClient(
        parsedCatalog: page,
        browseResult: metadata,
        browseCompleted: Completer<void>(),
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final imageBytes = img.encodePng(img.Image(width: 2, height: 2));
      final stalledBody = Completer<List<int>>();
      final imageStarted = Completer<void>();
      final retryStarted = Completer<void>();
      final imageClient = _DeferredVideoCoverHttpClient(
        stalledBody.future,
        imageRequestStarted: imageStarted,
        contentLength: imageBytes.length,
        bodyForRequest: (count) =>
            count == 1 ? stalledBody.future : Future.value(imageBytes),
        onRequest: (count) {
          if (count == 2 && !retryStarted.isCompleted) retryStarted.complete();
        },
      );
      final previousHttpClientProvider = debugNetworkImageHttpClientProvider;
      debugNetworkImageHttpClientProvider = () => imageClient;
      addTearDown(() async {
        if (!metadata.isCompleted) metadata.complete(page);
        if (!stalledBody.isCompleted) stalledBody.complete(imageBytes);
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        } finally {
          debugNetworkImageHttpClientProvider = previousHttpClientProvider;
        }
      });

      try {
        await tester.pumpWidget(
          _app(client, library, downloads, const VideoScreen()),
        );
        await tester.pump();
        await tester.runAsync(
          () => imageStarted.future.timeout(const Duration(seconds: 5)),
        );
        await tester.pump(const Duration(seconds: 9));
        expect(find.byTooltip('Retry', skipOffstage: false), findsNothing);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.byTooltip('Retry', skipOffstage: false), findsOneWidget);
        expect(find.text('Stalled cover catalog'), findsNothing);

        metadata.complete(page);
        await tester.runAsync(() => client.browseCompleted!.future);
        await tester.pumpAndSettle();
        expect(find.text('Stalled cover catalog'), findsOneWidget);
        expect(find.text('Stalled cover video'), findsOneWidget);
        expect(imageClient.requestCount, 1);
        expect(find.byTooltip('Retry').hitTestable(), findsOneWidget);

        await tester.tap(find.byTooltip('Retry').hitTestable());
        await tester.pump();
        await tester.runAsync(
          () => retryStarted.future.timeout(const Duration(seconds: 5)),
        );
        final rawImage = find.byType(RawImage);
        for (var attempt = 0; attempt < 10; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (tester.widget<RawImage>(rawImage).image != null) break;
        }
        expect(tester.widget<RawImage>(rawImage).image, isNotNull);
        expect(find.byTooltip('Retry'), findsNothing);
        expect(imageClient.requestCount, 2);
      } finally {
        debugNetworkImageHttpClientProvider = previousHttpClientProvider;
      }
    },
  );

  testWidgets('cached catalog refresh retains the current scroll position', (
    tester,
  ) async {
    const releaseUrl = 'https://missav.ai/cn/release';
    const nextUrl = 'https://missav.ai/cn/weekly-hot';
    final videos = _videos('scroll-cache', 40);
    final cachedPage = VideoCatalogPage(
      title: 'Cached scroll catalog',
      url: releaseUrl,
      videos: videos,
    );
    final refreshedPage = VideoCatalogPage(
      title: 'Refreshed scroll catalog',
      url: releaseUrl,
      videos: [
        for (final video in videos)
          VideoItem(
            id: video.id,
            title: '${video.title} refreshed',
            pageUrl: video.pageUrl,
          ),
      ],
    );
    final refresh = Completer<VideoCatalogPage>();
    final refreshStarted = Completer<void>();
    var releaseBrowseCount = 0;
    final client = _TestMissavClient(
      catalog: cachedPage,
      pagesByUrl: {
        nextUrl: VideoCatalogPage(
          title: 'Next scroll catalog',
          url: nextUrl,
          videos: _videos('next-scroll', 40),
        ),
      },
      browseHandler: (url, parsedPage) {
        if (url == releaseUrl && ++releaseBrowseCount == 2) {
          refreshStarted.complete();
          return refresh.future;
        }
        return Future.value(parsedPage);
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    addTearDown(() {
      if (!refresh.isCompleted) refresh.complete(refreshedPage);
    });
    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    await _videoDrawerTile(tester, l10n.videoNewReleases);
    await tester.tap(find.widgetWithText(ListTile, l10n.videoNewReleases));
    for (
      var attempt = 0;
      attempt < 10 && !refreshStarted.isCompleted;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(refreshStarted.isCompleted, isTrue);
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.videoNewReleases), findsOneWidget);
    final scroll = tester
        .widget<CustomScrollView>(
          find.byWidgetPredicate(
            (widget) =>
                widget is CustomScrollView &&
                widget.key == const PageStorageKey<String>('video-$releaseUrl'),
          ),
        )
        .controller!;
    scroll.jumpTo(180);
    await tester.pump();
    expect(scroll.offset, 180);

    refresh.complete(refreshedPage);
    await tester.pumpAndSettle();
    expect(find.textContaining('refreshed'), findsWidgets);
    expect(scroll.offset, 180);

    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    await _videoDrawerTile(tester, l10n.videoWeeklyHot);
    await tester.tap(find.widgetWithText(ListTile, l10n.videoWeeklyHot));
    await tester.pumpAndSettle();
    expect(find.text(l10n.videoWeeklyHot), findsOneWidget);
    expect(scroll.offset, 0);
  });

  testWidgets('cached cover retry does not bypass the pending refresh gate', (
    tester,
  ) async {
    const releaseUrl = 'https://missav.ai/cn/release';
    const coverUrl = 'https://missav.ai/images/cached-retry.png';
    final displayedVideos = find.byKey(
      const PageStorageKey<String>('video-$releaseUrl'),
    );
    Finder displayedVideo(String title) =>
        find.descendant(of: displayedVideos, matching: find.text(title));
    const video = VideoItem(
      id: 'cached-retry',
      title: 'Cached retry video',
      pageUrl: 'https://missav.ai/cn/cached-retry',
      cover: coverUrl,
    );
    const cachedPage = VideoCatalogPage(
      title: 'Cached retry catalog',
      url: releaseUrl,
      videos: [video],
    );
    const refreshedVideo = VideoItem(
      id: 'cached-retry',
      title: 'Refreshed retry video',
      pageUrl: 'https://missav.ai/cn/cached-retry',
      cover: coverUrl,
    );
    const refreshedPage = VideoCatalogPage(
      title: 'Refreshed retry catalog',
      url: releaseUrl,
      videos: [refreshedVideo],
    );
    final refreshResult = Completer<VideoCatalogPage>();
    final refreshStarted = Completer<void>();
    final refreshBrowseFinished = Completer<void>();
    final retryRequestStarted = Completer<void>();
    var releaseBrowseCount = 0;
    final client = _TestMissavClient(
      catalog: cachedPage,
      browseHandler: (url, parsedPage) {
        if (url == releaseUrl && ++releaseBrowseCount == 2) {
          refreshStarted.complete();
          return refreshResult.future;
        }
        return Future.value(parsedPage);
      },
      onBrowseCompleted: (url) {
        if (url == releaseUrl &&
            releaseBrowseCount == 2 &&
            !refreshBrowseFinished.isCompleted) {
          refreshBrowseFinished.complete();
        }
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final imageBytes = img.encodePng(img.Image(width: 2, height: 2));
    final retryBody = Completer<List<int>>();
    final imageClient = _DeferredVideoCoverHttpClient(
      Future.value(const <int>[]),
      contentLength: 0,
      statusCode: HttpStatus.notFound,
      bodyForRequest: (count) =>
          count == 1 ? Future.value(const <int>[]) : retryBody.future,
      contentLengthForRequest: (count) => count == 1 ? 0 : imageBytes.length,
      statusCodeForRequest: (count) =>
          count == 1 ? HttpStatus.notFound : HttpStatus.ok,
      onRequest: (count) {
        if (count == 2 && !retryRequestStarted.isCompleted) {
          retryRequestStarted.complete();
        }
      },
    );
    final previousHttpClientProvider = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () => imageClient;
    addTearDown(() async {
      if (!refreshResult.isCompleted) refreshResult.complete(refreshedPage);
      if (!retryBody.isCompleted) retryBody.complete(imageBytes);
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      } finally {
        debugNetworkImageHttpClientProvider = previousHttpClientProvider;
      }
    });

    try {
      await tester.pumpWidget(
        _app(client, library, downloads, const VideoScreen()),
      );
      await tester.pumpAndSettle();
      expect(displayedVideo('Cached retry video'), findsOneWidget);
      expect(find.byTooltip('Retry'), findsOneWidget);
      expect(imageClient.requestCount, 1);

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      await _videoDrawerTile(tester, l10n.videoNewReleases);
      await tester.tap(find.widgetWithText(ListTile, l10n.videoNewReleases));
      for (
        var attempt = 0;
        attempt < 10 && !refreshStarted.isCompleted;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(refreshStarted.isCompleted, isTrue);
      await tester.pump();
      expect(displayedVideo('Cached retry video'), findsOneWidget);
      expect(find.byTooltip('Retry').hitTestable(), findsOneWidget);
      expect(imageClient.requestCount, 1);
      // Publish the cache, then let its replacement staging tree inspect covers.
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('Retry').hitTestable());
      await tester.pump();
      await tester.runAsync(
        () => retryRequestStarted.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw StateError('Retry request did not start.'),
        ),
      );

      await tester.runAsync(() async {
        refreshResult.complete(refreshedPage);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.runAsync(
        () => refreshBrowseFinished.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw StateError('Refresh browse did not finish.'),
        ),
      );
      for (var attempt = 0; attempt < 5; attempt++) {
        await tester.pump();
      }
      expect(displayedVideo('Cached retry video'), findsOneWidget);
      expect(displayedVideo('Refreshed retry video'), findsNothing);

      await tester.runAsync(() async => retryBody.complete(imageBytes));
      for (var attempt = 0; attempt < 10; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (displayedVideo('Refreshed retry video').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(displayedVideo('Refreshed retry video'), findsOneWidget);
      expect(imageClient.requestCount, 2);
    } finally {
      debugNetworkImageHttpClientProvider = previousHttpClientProvider;
    }
  });

  testWidgets('catalog keeps favorites reachable while logged out', (
    tester,
  ) async {
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Source catalog',
        url: 'https://missav.ai/cn',
        navigation: [
          VideoLink(
            label: 'Video favorites',
            url: 'https://missav.ai/cn/favorites',
            kind: VideoLinkKind.navigation,
          ),
        ],
        videos: [
          VideoItem(
            id: 'dvd-1',
            title: 'Fixture video',
            pageUrl: 'https://missav.ai/cn/dvd-1',
          ),
        ],
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();
    expect(client.isLoggedIn, isFalse);
    expect(find.text('Fixture video'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    final drawer = find.byKey(const ValueKey('library-drawer'));
    await tester.scrollUntilVisible(
      find.descendant(of: drawer, matching: find.text(l10n.videoFavorites)),
      240,
      scrollable: find
          .descendant(of: drawer, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: drawer, matching: find.text(l10n.videoFavorites)),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: drawer, matching: find.text(l10n.videoFavorites)),
    );
    await tester.pumpAndSettle();

    expect(client.browsedUrls, contains('https://missav.ai/en/saved'));
  });

  testWidgets('MissAV groups account actions and localizes collection pages', (
    tester,
  ) async {
    const favoritesUrl = 'https://missav.ai/en/saved';
    final client = _TestMissavClient(
      sourceHomeUrl: 'https://missav.ai/en',
      loggedIn: true,
      accountName: 'Signed in account',
      catalog: const VideoCatalogPage(
        title: 'Home source title',
        url: 'https://missav.ai/en/release',
      ),
      pagesByUrl: const {
        favoritesUrl: VideoCatalogPage(
          title: 'Saved source title',
          url: favoritesUrl,
        ),
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final l10n = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();

    final drawer = find.byKey(const ValueKey('library-drawer'));
    expect(
      find.descendant(of: drawer, matching: find.text(l10n.libraryAccount)),
      findsOneWidget,
    );
    expect(
      (await _videoDrawerTile(tester, 'Signed in account')).onTap,
      isNotNull,
    );
    for (final label in [
      l10n.videoFavorites,
      l10n.videoActorFavorites,
      l10n.playlists,
      l10n.videoWatchHistory,
    ]) {
      expect((await _videoDrawerTile(tester, label)).onTap, isNotNull);
    }

    await _videoDrawerTile(tester, l10n.videoFavorites);
    await tester.tap(
      find.descendant(of: drawer, matching: find.text(l10n.videoFavorites)),
    );
    await tester.pumpAndSettle();
    expect(client.browsedUrls, contains(favoritesUrl));
    expect(find.text(l10n.videoFavorites), findsOneWidget);
    expect(find.text('Saved source title'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    expect(
      (await _videoDrawerTile(tester, l10n.videoFavorites)).selected,
      isTrue,
    );
  });

  testWidgets(
    'playlist entries stay in their collection page and browse in place',
    (tester) async {
      const collectionUrl = 'https://missav.ai/en/playlists';
      const playlistUrl = 'https://missav.ai/dm123/en/playlists/123';
      final client = _TestMissavClient(
        catalog: const VideoCatalogPage(
          title: 'Home catalog',
          url: 'https://missav.ai/en',
          links: [
            VideoLink(
              label: 'Playlist one',
              url: playlistUrl,
              kind: VideoLinkKind.playlist,
              sourceKey: '123',
            ),
          ],
        ),
        pagesByUrl: {
          collectionUrl: const VideoCatalogPage(
            title: 'Playlists',
            url: collectionUrl,
            links: [
              VideoLink(
                label: 'Playlist one',
                url: playlistUrl,
                kind: VideoLinkKind.playlist,
                sourceKey: '123',
              ),
            ],
          ),
          playlistUrl: const VideoCatalogPage(
            title: 'Playlist one videos',
            url: playlistUrl,
            links: [
              VideoLink(
                label: 'Another playlist',
                url: 'https://missav.ai/en/playlists/456',
                kind: VideoLinkKind.playlist,
                sourceKey: '456',
              ),
            ],
            videos: [
              VideoItem(
                id: 'playlist-video',
                title: 'Playlist video',
                pageUrl: 'https://missav.ai/en/playlist-video',
              ),
            ],
          ),
        },
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final observer = _PushObserver();

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen(),
          observer: observer,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      final drawer = find.byKey(const ValueKey('library-drawer'));
      expect(
        find.descendant(of: drawer, matching: find.text('Playlist one')),
        findsNothing,
      );
      expect(find.text('Playlist one'), findsNothing);

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.scrollUntilVisible(
        find.descendant(of: drawer, matching: find.text(l10n.playlists)),
        240,
        scrollable: find
            .descendant(of: drawer, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: drawer, matching: find.text(l10n.playlists)),
      );
      await tester.pumpAndSettle();
      expect(client.browsedUrls, contains(collectionUrl));
      expect(find.text('Playlist one'), findsOneWidget);
      expect(find.byIcon(Icons.playlist_play), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: drawer, matching: find.text('Playlist one')),
        findsNothing,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final coverRequestsBeforeMenu = client.playlistCoverRequests.length;
      await tester.tap(find.byTooltip('Playlist one'));
      await tester.pumpAndSettle();
      expect(client.playlistCoverRequests.length, coverRequestsBeforeMenu);
      expect(find.text(l10n.videoOpenSource), findsOneWidget);
      expect(find.text(l10n.videoRenamePlaylist), findsOneWidget);
      expect(find.text(l10n.videoDeletePlaylist), findsOneWidget);
      await tester.tap(find.text(l10n.videoRenamePlaylist));
      await tester.pumpAndSettle();
      expect(find.text(l10n.videoPlaylistName), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(client.playlistCoverRequests.length, coverRequestsBeforeMenu);

      final pushesBeforeSelection = observer.pushes;
      await tester.tap(find.text('Playlist one'));
      await tester.pumpAndSettle();

      expect(find.text('Playlist video'), findsOneWidget);
      expect(client.browsedUrls, contains(playlistUrl));
      expect(observer.pushes, pushesBeforeSelection);

      await tester.tap(find.text('Playlist video'));
      await tester.pump();
      expect(observer.pushes, pushesBeforeSelection + 1);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(VideoDetailsScreen), findsOneWidget);
    },
  );

  testWidgets(
    'playlist cards honor all layouts at compact and wide sizes with larger text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cardWidths = <(int, LayoutType), double>{};

      for (final size in const [Size(360, 800), Size(1280, 900)]) {
        tester.view.physicalSize = size;
        for (final layoutType in const [
          LayoutType.bigGrid,
          LayoutType.smallGrid,
          LayoutType.list,
        ]) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();

          final library = await _testLibrary();
          final preferences = await SharedPreferences.getInstance();
          await preferences.setString(
            VideoBrowseLayoutNotifier.preferenceKey,
            layoutType.name,
          );
          const collectionUrl = 'https://missav.ai/en/playlists';
          final links = [
            for (var index = 0; index < 8; index++)
              VideoLink(
                label: 'Playlist ${index + 1} with a longer title',
                url: 'https://missav.ai/en/playlists/${index + 1}',
                kind: VideoLinkKind.playlist,
              ),
          ];
          final client = _TestMissavClient(
            pagesByUrl: {
              collectionUrl: VideoCatalogPage(
                title: 'Playlists',
                url: collectionUrl,
                links: links,
              ),
            },
          );
          final downloads = _TestVideoDownloads(
            client: client,
            library: library,
          );

          await tester.pumpWidget(
            _app(
              client,
              library,
              downloads,
              const VideoScreen.catalog(url: collectionUrl),
              textScale: 1.3,
            ),
          );
          await tester.pumpAndSettle();

          final collection = tester.widget<VideoCollectionView<VideoLink>>(
            find.byType(VideoCollectionView<VideoLink>),
          );
          expect(collection.layoutType, layoutType);
          final card = find.byKey(
            const ValueKey(
              'video-playlist-card-https://missav.ai/en/playlists/1',
            ),
          );
          expect(card, findsOneWidget);
          cardWidths[(size.width.toInt(), layoutType)] = tester
              .getSize(card)
              .width;
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          client.dispose();
        }
      }

      for (final width in const [360, 1280]) {
        expect(
          cardWidths[(width, LayoutType.list)],
          greaterThan(cardWidths[(width, LayoutType.bigGrid)]!),
        );
        expect(
          cardWidths[(width, LayoutType.bigGrid)],
          greaterThan(cardWidths[(width, LayoutType.smallGrid)]!),
        );
      }
    },
  );

  testWidgets(
    'playlist cover lookup keeps the directory visible and replaces its cover',
    (tester) async {
      const collectionUrl = 'https://missav.ai/en/playlists';
      const playlist = VideoLink(
        label: 'Playlist with cover',
        url: 'https://missav.ai/en/playlists/with-cover',
        cover: 'https://missav.ai/images/directory-cover.jpg',
        kind: VideoLinkKind.playlist,
      );
      const firstVideoCover = 'https://missav.ai/images/first-video-cover.jpg';
      final coverResult = Completer<String?>();
      final client = _TestMissavClient(
        pagesByUrl: {
          collectionUrl: const VideoCatalogPage(
            title: 'Playlists',
            url: collectionUrl,
            links: [playlist],
          ),
        },
        playlistCoverHandler: (_, {cancelToken}) => coverResult.future,
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);

      try {
        await tester.pumpWidget(
          _app(
            client,
            library,
            downloads,
            const VideoScreen.catalog(url: collectionUrl),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(
          const ValueKey(
            'video-playlist-card-https://missav.ai/en/playlists/with-cover',
          ),
        );
        expect(find.text(playlist.label), findsOneWidget);
        expect(client.playlistCoverRequests, [playlist.url]);
        expect(
          find.descendant(of: card, matching: find.byIcon(Icons.playlist_play)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: card, matching: find.byType(Image)),
          findsNothing,
        );

        coverResult.complete(firstVideoCover);
        await tester.pumpAndSettle();
        expect(_playlistCardImageUrl(tester, playlist.url), firstVideoCover);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        client.dispose();
      }
    },
  );

  testWidgets('playlist first-video cover image loads successfully', (
    tester,
  ) async {
    const collectionUrl = 'https://missav.ai/en/playlists';
    const playlist = VideoLink(
      label: 'Playlist with cover',
      url: 'https://missav.ai/en/playlists/with-cover-image',
      cover: 'https://missav.ai/images/directory-cover.jpg',
      kind: VideoLinkKind.playlist,
    );
    const firstVideoCover = 'https://missav.ai/images/first-video-cover.png';
    final client = _TestMissavClient(
      pagesByUrl: {
        collectionUrl: const VideoCatalogPage(
          title: 'Playlists',
          url: collectionUrl,
          links: [playlist],
        ),
      },
      playlistCoverHandler: (_, {cancelToken}) async => firstVideoCover,
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final imageBytes = img.encodePng(img.Image(width: 2, height: 2));
    final imageBody = Completer<List<int>>();
    final imageRequestStarted = Completer<void>();
    final imageClient = _DeferredVideoCoverHttpClient(
      imageBody.future,
      imageRequestStarted: imageRequestStarted,
      contentLength: imageBytes.length,
    );
    final previousHttpClientProvider = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () => imageClient;

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => imageRequestStarted.future.timeout(const Duration(seconds: 5)),
      );
      await tester.pumpAndSettle();

      final card = find.byKey(
        const ValueKey(
          'video-playlist-card-https://missav.ai/en/playlists/with-cover-image',
        ),
      );
      final imageFinder = find.descendant(
        of: card,
        matching: find.byType(Image),
      );
      expect(_playlistCardImageUrl(tester, playlist.url), firstVideoCover);
      final imageStream = tester
          .widget<Image>(imageFinder)
          .image
          .resolve(createLocalImageConfiguration(tester.element(imageFinder)));
      final imageDecoded = Completer<void>();
      final listener = ImageStreamListener((_, _) {
        if (!imageDecoded.isCompleted) imageDecoded.complete();
      });
      imageStream.addListener(listener);
      expect(
        find.descendant(of: card, matching: find.byIcon(Icons.playlist_play)),
        findsOneWidget,
      );
      try {
        await tester.runAsync(() async => imageBody.complete(imageBytes));
        final timeout = Stopwatch()..start();
        while (!imageDecoded.isCompleted &&
            timeout.elapsed < const Duration(seconds: 5)) {
          await tester.runAsync(() {
            final eventLoopTurn = Completer<void>();
            Timer.run(() => eventLoopTurn.complete());
            return eventLoopTurn.future;
          });
          await tester.pump();
        }
        expect(imageDecoded.isCompleted, isTrue);
      } finally {
        imageStream.removeListener(listener);
      }
      await tester.pumpAndSettle();
      final rawImage = find.descendant(
        of: card,
        matching: find.byType(RawImage),
      );
      expect(rawImage, findsOneWidget);
      expect(tester.widget<RawImage>(rawImage).image, isNotNull);
      expect(
        find.descendant(of: card, matching: find.byIcon(Icons.playlist_play)),
        findsNothing,
      );
      expect(imageClient.requestCount, 1);
      expect(client.playlistCoverRequests, [playlist.url]);
      expect(tester.takeException(), isNull);
    } finally {
      debugNetworkImageHttpClientProvider = previousHttpClientProvider;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    }
  });

  testWidgets('playlist image load failure keeps the playlist icon', (
    tester,
  ) async {
    const collectionUrl = 'https://missav.ai/en/playlists';
    const playlist = VideoLink(
      label: 'Playlist with broken image',
      url: 'https://missav.ai/en/playlists/broken-image',
      cover: 'https://missav.ai/images/directory-cover.jpg',
      kind: VideoLinkKind.playlist,
    );
    const firstVideoCover = 'https://missav.ai/images/broken-cover.jpg';
    final client = _TestMissavClient(
      pagesByUrl: {
        collectionUrl: const VideoCatalogPage(
          title: 'Playlists',
          url: collectionUrl,
          links: [playlist],
        ),
      },
      playlistCoverHandler: (_, {cancelToken}) async => firstVideoCover,
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final imageRequestStarted = Completer<void>();
    final imageRetryStarted = Completer<void>();
    final imageClient = _DeferredVideoCoverHttpClient(
      Future.value(const <int>[]),
      imageRequestStarted: imageRequestStarted,
      contentLength: 0,
      statusCode: HttpStatus.notFound,
      onRequest: (count) {
        if (count == 2) imageRetryStarted.complete();
      },
    );
    final previousHttpClientProvider = debugNetworkImageHttpClientProvider;
    debugNetworkImageHttpClientProvider = () => imageClient;

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => imageRequestStarted.future.timeout(const Duration(seconds: 5)),
      );
      await tester.pumpAndSettle();

      final card = find.byKey(
        const ValueKey(
          'video-playlist-card-https://missav.ai/en/playlists/broken-image',
        ),
      );
      expect(_playlistCardImageUrl(tester, playlist.url), firstVideoCover);
      expect(
        find.descendant(of: card, matching: find.byIcon(Icons.playlist_play)),
        findsOneWidget,
      );
      expect(imageClient.requestCount, 1);
      expect(client.playlistCoverRequests, [playlist.url]);

      final l10n = await S.delegate.load(const Locale('en'));
      await _selectVideoDrawerLabel(tester, l10n, l10n.playlists);
      await tester.runAsync(
        () => imageRetryStarted.future.timeout(const Duration(seconds: 5)),
      );
      await tester.pumpAndSettle();

      expect(imageClient.requestCount, 2);
      expect(client.playlistCoverRequests, [playlist.url, playlist.url]);
      expect(tester.takeException(), isNull);
    } finally {
      debugNetworkImageHttpClientProvider = previousHttpClientProvider;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    }
  });

  testWidgets('failed playlist cover lookup retries after reentry', (
    tester,
  ) async {
    const collectionUrl = 'https://missav.ai/en/playlists';
    const playlist = VideoLink(
      label: 'Playlist with broken cover',
      url: 'https://missav.ai/en/playlists/broken-cover',
      cover: 'https://missav.ai/images/directory-cover.jpg',
      kind: VideoLinkKind.playlist,
    );
    const firstVideoCover = 'https://missav.ai/images/retried-cover.jpg';
    var coverAttempts = 0;
    final client = _TestMissavClient(
      pagesByUrl: {
        collectionUrl: const VideoCatalogPage(
          title: 'Playlists',
          url: collectionUrl,
          links: [playlist],
        ),
      },
      playlistCoverHandler: (_, {cancelToken}) async {
        if (++coverAttempts == 1) throw StateError('Cover lookup failed.');
        return firstVideoCover;
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();
      expect(client.playlistCoverRequests, [playlist.url]);
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey(
              'video-playlist-card-https://missav.ai/en/playlists/broken-cover',
            ),
          ),
          matching: find.byIcon(Icons.playlist_play),
        ),
        findsOneWidget,
      );

      final l10n = await S.delegate.load(const Locale('en'));
      await _selectVideoDrawerLabel(tester, l10n, l10n.playlists);

      expect(client.playlistCoverRequests, [playlist.url, playlist.url]);
      expect(_playlistCardImageUrl(tester, playlist.url), firstVideoCover);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    }
  });

  testWidgets('visible playlists replace stale queued cover lookups', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const collectionUrl = 'https://missav.ai/en/playlists';
    final links = [
      for (var index = 0; index < 12; index++)
        VideoLink(
          label: 'Playlist ${index + 1}',
          url: 'https://missav.ai/en/playlists/${index + 1}',
          kind: VideoLinkKind.playlist,
        ),
    ];
    final coverResults = <Completer<String?>>[];
    final client = _TestMissavClient(
      pagesByUrl: {
        collectionUrl: VideoCatalogPage(
          title: 'Playlists',
          url: collectionUrl,
          links: links,
        ),
      },
      playlistCoverHandler: (_, {cancelToken}) {
        final result = Completer<String?>();
        coverResults.add(result);
        return result.future;
      },
    );
    final library = await _testLibrary();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      VideoBrowseLayoutNotifier.preferenceKey,
      LayoutType.list.name,
    );
    final downloads = _TestVideoDownloads(client: client, library: library);

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();
      expect(client.playlistCoverRequests, [links.first.url]);

      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView).first)
          .controller!;
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      controller.jumpTo(0);
      await tester.pumpAndSettle();

      coverResults.first.complete(null);
      await tester.pumpAndSettle();
      expect(client.playlistCoverRequests, hasLength(2));
      final nextIndex = links.indexWhere(
        (link) => link.url == client.playlistCoverRequests[1],
      );
      expect(nextIndex, greaterThan(0));
      expect(nextIndex, lessThan(links.length ~/ 2));
      expect(coverResults, hasLength(2));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    }
  });

  testWidgets('returning to playlists keeps the local page and scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const collectionUrl = 'https://missav.ai/en/playlists';
    final links = [
      for (var index = 0; index < 45; index++)
        VideoLink(
          label: 'Playlist ${index + 1}',
          url: 'https://missav.ai/en/playlists/${index + 1}',
          kind: VideoLinkKind.playlist,
        ),
    ];
    final client = _TestMissavClient(
      pagesByUrl: {
        collectionUrl: VideoCatalogPage(
          title: 'Playlists',
          url: collectionUrl,
          links: links,
        ),
      },
    );
    final library = await _testLibrary();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('page_size_preference', 20);
    await preferences.setString(
      VideoBrowseLayoutNotifier.preferenceKey,
      LayoutType.list.name,
    );
    final downloads = _TestVideoDownloads(client: client, library: library);
    final active = ValueNotifier(true);

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, value, _) =>
                VideoScreen.catalog(url: collectionUrl, active: value),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pagination = await _visiblePaginationBar(tester);
      pagination.onNextPage!();
      await tester.pumpAndSettle();
      expect((await _visiblePaginationBar(tester)).currentPage, 2);
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView).first)
          .controller!;
      scroll.jumpTo(160);
      await tester.pumpAndSettle();
      final coverRequests = client.playlistCoverRequests.length;
      expect(scroll.offset, 160);

      active.value = false;
      await tester.pumpAndSettle();
      expect(
        tester.widget<VideoScreen>(find.byType(VideoScreen)).active,
        isFalse,
      );
      active.value = true;
      await tester.pumpAndSettle();
      expect(
        tester.widget<VideoScreen>(find.byType(VideoScreen)).active,
        isTrue,
      );

      expect(scroll.offset, 160);
      expect(client.browsedUrls, [collectionUrl]);
      expect(client.playlistCoverRequests.length, greaterThan(coverRequests));
      expect((await _visiblePaginationBar(tester)).currentPage, 2);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      active.dispose();
      client.dispose();
    }
  });

  testWidgets('returning to playlists keeps a pending source page', (
    tester,
  ) async {
    const firstUrl = 'https://missav.ai/en/playlists?page=1';
    const secondUrl = 'https://missav.ai/en/playlists?page=2';
    const firstPage = VideoCatalogPage(
      title: 'Playlists',
      url: firstUrl,
      nextUrl: secondUrl,
      links: [
        VideoLink(
          label: 'First playlist',
          url: 'https://missav.ai/en/playlists/first',
          kind: VideoLinkKind.playlist,
        ),
      ],
    );
    const secondPage = VideoCatalogPage(
      title: 'Playlists',
      url: secondUrl,
      previousUrl: firstUrl,
      currentPage: 2,
      links: [
        VideoLink(
          label: 'Second playlist',
          url: 'https://missav.ai/en/playlists/second',
          kind: VideoLinkKind.playlist,
        ),
      ],
    );
    final secondResult = Completer<VideoCatalogPage>();
    final client = _TestMissavClient(
      pagesByUrl: {firstUrl: firstPage, secondUrl: secondPage},
      browseHandler: (url, page) =>
          url == secondUrl ? secondResult.future : Future.value(page),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final active = ValueNotifier(true);

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, value, _) =>
                VideoScreen.catalog(url: firstUrl, active: value),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = await S.delegate.load(const Locale('en'));
      await _visiblePaginationBar(tester);
      await tester.tap(find.text(l10n.nextPage));
      await tester.pump();
      expect(client.browsedUrls, [firstUrl, secondUrl]);

      active.value = false;
      await tester.pump();
      active.value = true;
      await tester.pump();
      await tester.pump();
      expect(client.browsedUrls, [firstUrl, secondUrl]);

      secondResult.complete(secondPage);
      await tester.pumpAndSettle();
      expect(find.text('Second playlist'), findsOneWidget);
    } finally {
      if (!secondResult.isCompleted) secondResult.complete(secondPage);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      active.dispose();
      client.dispose();
    }
  });

  testWidgets('returning from search reloads covers without browsing again', (
    tester,
  ) async {
    const collectionUrl = 'https://missav.ai/en/playlists';
    const playlist = VideoLink(
      label: 'Playlist with pending cover',
      url: 'https://missav.ai/en/playlists/pending',
      kind: VideoLinkKind.playlist,
    );
    const refreshedCover = 'https://missav.ai/images/refreshed-cover.jpg';
    final pendingCover = Completer<String?>();
    CancelToken? firstToken;
    var attempts = 0;
    final client = _TestMissavClient(
      pagesByUrl: {
        collectionUrl: const VideoCatalogPage(
          title: 'Playlists',
          url: collectionUrl,
          links: [playlist],
        ),
      },
      playlistCoverHandler: (_, {cancelToken}) {
        if (++attempts == 1) {
          firstToken = cancelToken;
          return pendingCover.future;
        }
        return Future.value(refreshedCover);
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-page-search')));
      await tester.pumpAndSettle();
      expect(find.byType(VideoSearchScreen), findsOneWidget);
      expect(firstToken!.isCancelled, isTrue);
      expect(client.playlistCoverRequests, [playlist.url]);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(client.playlistCoverRequests, [playlist.url, playlist.url]);
      expect(client.browsedUrls, [collectionUrl]);
      expect(_playlistCardImageUrl(tester, playlist.url), refreshedCover);

      pendingCover.complete('https://missav.ai/images/stale-cover.jpg');
      await tester.pumpAndSettle();
      expect(_playlistCardImageUrl(tester, playlist.url), refreshedCover);
    } finally {
      if (!pendingCover.isCompleted) pendingCover.complete(null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    }
  });

  testWidgets('playlist covers load for items revealed behind a menu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const collectionUrl = 'https://missav.ai/en/playlists';
    final links = [
      for (var index = 0; index < 20; index++)
        VideoLink(
          label: 'Playlist ${index + 1}',
          url: 'https://missav.ai/en/playlists/${index + 1}',
          kind: VideoLinkKind.playlist,
        ),
    ];
    final client = _TestMissavClient(
      pagesByUrl: {
        collectionUrl: VideoCatalogPage(
          title: 'Playlists',
          url: collectionUrl,
          links: links,
        ),
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();
      final previousRequests = client.playlistCoverRequests.toSet();
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip('Playlist 1'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.videoRenamePlaylist), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(VideoScreen)))?.isCurrent,
        isFalse,
      );

      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      expect(find.text(l10n.videoRenamePlaylist), findsOneWidget);
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView).first)
          .controller!;
      scroll.jumpTo(200);
      await tester.pumpAndSettle();
      final newlyVisible = links.where((link) {
        final card = find.byKey(ValueKey('video-playlist-card-${link.url}'));
        if (previousRequests.contains(link.url) || card.evaluate().isEmpty) {
          return false;
        }
        final rect = tester.getRect(card);
        return rect.top < 800 && rect.bottom > 0;
      }).toList();
      expect(newlyVisible, isNotEmpty);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        client.playlistCoverRequests,
        containsAll(newlyVisible.map((link) => link.url)),
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    }
  });

  testWidgets('account change discards an old playlist cover result', (
    tester,
  ) async {
    const collectionUrl = 'https://missav.ai/en/playlists';
    const playlist = VideoLink(
      label: 'Playlist with pending cover',
      url: 'https://missav.ai/en/playlists/pending-cover',
      kind: VideoLinkKind.playlist,
    );
    const oldCover = 'https://missav.ai/images/old-account-cover.jpg';
    const newCover = 'https://missav.ai/images/new-account-cover.jpg';
    final coverResults = [Completer<String?>(), Completer<String?>()];
    final coverTokens = <CancelToken?>[];
    final client = _TestMissavClient(
      pagesByUrl: {
        collectionUrl: const VideoCatalogPage(
          title: 'Playlists',
          url: collectionUrl,
          links: [playlist],
        ),
      },
      playlistCoverHandler: (_, {cancelToken}) {
        coverTokens.add(cancelToken);
        return coverResults[coverTokens.length - 1].future;
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();
      expect(client.playlistCoverRequests, [playlist.url]);

      client.advanceSessionGeneration();
      await tester.pumpAndSettle();
      expect(coverTokens, hasLength(2));
      expect(coverTokens.first!.isCancelled, isTrue);

      coverResults.first.complete(oldCover);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);

      coverResults.last.complete(newCover);
      await tester.pumpAndSettle();
      expect(_playlistCardImageUrl(tester, playlist.url), newCover);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    }
  });

  testWidgets('opening a playlist cancels its directory cover lookup', (
    tester,
  ) async {
    const collectionUrl = 'https://missav.ai/en/playlists';
    const playlistUrl = 'https://missav.ai/en/playlists/pending-cover';
    const playlist = VideoLink(
      label: 'Playlist with pending cover',
      url: playlistUrl,
      kind: VideoLinkKind.playlist,
    );
    final coverResult = Completer<String?>();
    CancelToken? coverToken;
    final client = _TestMissavClient(
      pagesByUrl: {
        collectionUrl: const VideoCatalogPage(
          title: 'Playlists',
          url: collectionUrl,
          links: [playlist],
        ),
        playlistUrl: const VideoCatalogPage(
          title: 'Playlist videos',
          url: playlistUrl,
          videos: [
            VideoItem(
              id: 'playlist-video',
              title: 'Playlist video',
              pageUrl: 'https://missav.ai/en/playlist-video',
            ),
          ],
        ),
      },
      playlistCoverHandler: (_, {cancelToken}) {
        coverToken = cancelToken;
        return coverResult.future;
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(playlist.label));
      await tester.pumpAndSettle();
      expect(coverToken!.isCancelled, isTrue);
      expect(find.text('Playlist video'), findsOneWidget);

      coverResult.complete('https://missav.ai/images/stale-cover.jpg');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('video-playlist-card-$playlistUrl')),
        findsNothing,
      );
      expect(find.byType(VideoCollectionView<VideoLink>), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    }
  });

  testWidgets('recommendations cancel pending playlist cover lookups', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const collectionUrl = 'https://missav.ai/en/playlists';
    final links = [
      for (var index = 0; index < 12; index++)
        VideoLink(
          label: 'Playlist ${index + 1}',
          url: 'https://missav.ai/en/playlists/${index + 1}',
          kind: VideoLinkKind.playlist,
        ),
    ];
    final coverResult = Completer<String?>();
    CancelToken? coverToken;
    final client = _TestMissavClient(
      pagesByUrl: {
        collectionUrl: VideoCatalogPage(
          title: 'Playlists',
          url: collectionUrl,
          links: links,
        ),
      },
      playlistCoverHandler: (_, {cancelToken}) {
        coverToken = cancelToken;
        return coverResult.future;
      },
      recommendationHandler: (_, _, _) async => const VideoRecommendationPage(
        videos: [
          VideoItem(
            id: 'recommendation-after-playlists',
            title: 'Recommendation after playlists',
            pageUrl: 'https://missav.ai/en/recommendation-after-playlists',
          ),
        ],
        cursor: null,
      ),
    );
    final library = await _testLibrary();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      VideoBrowseLayoutNotifier.preferenceKey,
      LayoutType.list.name,
    );
    final downloads = _TestVideoDownloads(client: client, library: library);

    try {
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();
      expect(client.playlistCoverRequests, [links.first.url]);
      expect(coverToken, isNotNull);
      final secondCard = find.byKey(
        ValueKey('video-playlist-card-${links[1].url}'),
      );
      expect(secondCard, findsOneWidget);
      expect(tester.getRect(secondCard).top, lessThan(800));

      final l10n = await S.delegate.load(const Locale('en'));
      await _selectVideoDrawerLabel(tester, l10n, l10n.videoRecommendedForYou);

      expect(coverToken!.isCancelled, isTrue);
      expect(client.playlistCoverRequests, [links.first.url]);
      expect(client.recommendationRequests, [(cursor: null, count: 40)]);
      expect(find.text('Recommendation after playlists'), findsOneWidget);

      coverResult.complete('https://missav.ai/images/stale-cover.jpg');
      await tester.pumpAndSettle();
      expect(client.playlistCoverRequests, [links.first.url]);
      expect(tester.takeException(), isNull);
    } finally {
      if (!coverResult.isCompleted) {
        coverResult.complete('https://missav.ai/images/stale-cover.jpg');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    }
  });

  testWidgets('drawer catalog selection replaces the current page in place', (
    tester,
  ) async {
    const destination = 'https://missav.ai/dm539/cn/new';
    const pageTwo = '$destination?page=2';
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Home catalog',
        url: 'https://missav.ai/cn',
        navigation: [
          VideoLink(
            label: 'Source recent feed',
            url: destination,
            kind: VideoLinkKind.navigation,
          ),
        ],
      ),
      pagesByUrl: {
        destination: const VideoCatalogPage(
          title: 'Recently updated page',
          url: destination,
          nextUrl: pageTwo,
        ),
        pageTwo: const VideoCatalogPage(
          title: 'Recently updated page 2',
          url: pageTwo,
          previousUrl: destination,
        ),
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final observer = _PushObserver();

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen(), observer: observer),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    final pushesAfterOpeningDrawer = observer.pushes;
    final browsesBeforeSelection = client.browsedUrls.length;
    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text('Source recent feed'), findsNothing);
    await tester.tap(find.text(l10n.videoRecentlyUpdated));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text(l10n.videoRecentlyUpdated), findsOneWidget);
    expect(client.browsedUrls, hasLength(browsesBeforeSelection));
    await tester.pumpAndSettle();

    expect(client.browsedUrls, hasLength(browsesBeforeSelection + 1));
    expect(client.browsedUrls.last, destination);
    expect(find.text('Source recent feed'), findsNothing);
    expect(find.text(l10n.videoRecentlyUpdated), findsOneWidget);
    expect(observer.pushes, pushesAfterOpeningDrawer);

    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    expect(
      (await _videoDrawerTile(tester, l10n.videoRecentlyUpdated)).selected,
      isTrue,
    );
    expect(
      (await _videoDrawerTile(tester, l10n.videoNewReleases)).selected,
      isFalse,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await _tapNextPage(tester, l10n);
    expect(client.browsedUrls.last, pageTwo);
    expect(find.text(l10n.videoRecentlyUpdated), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    expect(
      (await _videoDrawerTile(tester, l10n.videoRecentlyUpdated)).selected,
      isTrue,
    );
  });

  testWidgets('failed catalog source action opens the requested URL', (
    tester,
  ) async {
    const releaseUrl = 'https://missav.ai/cn/release';
    const weeklyHotUrl = 'https://missav.ai/cn/weekly-hot';
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final launchedUrls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'launch') {
        launchedUrls.add((call.arguments as Map)['url'] as String);
        return true;
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(title: 'Releases', url: releaseUrl),
      browseHandler: (url, parsedPage) async {
        if (url == weeklyHotUrl) {
          throw const MissavException(
            'Weekly hot is unavailable.',
            sourceUrl: weeklyHotUrl,
          );
        }
        return parsedPage;
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        const VideoScreen.catalog(url: releaseUrl),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await _selectVideoDrawerLabel(tester, l10n, l10n.videoWeeklyHot);

    expect(client.browsedUrls, [releaseUrl, weeklyHotUrl]);
    await tester.tap(find.text(l10n.videoOpenSource));
    await tester.pumpAndSettle();

    expect(launchedUrls, [weeklyHotUrl]);
  });

  testWidgets('session generation keeps the selected catalog destination', (
    tester,
  ) async {
    const destination = 'https://missav.ai/cn/weekly-hot';
    late _TestMissavClient client;
    var changedSession = false;
    client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Home catalog',
        url: 'https://missav.ai/cn',
      ),
      pagesByUrl: {
        destination: const VideoCatalogPage(
          title: 'Weekly hot catalog',
          url: destination,
        ),
      },
      onBrowse: (url) {
        if (url == destination && !changedSession) {
          changedSession = true;
          client.advanceSessionGeneration();
        }
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await _videoDrawerTile(tester, l10n.videoWeeklyHot);
    await tester.tap(find.text(l10n.videoWeeklyHot));
    await tester.pumpAndSettle();

    expect(changedSession, isTrue);
    expect(client.browsedUrls, [
      'https://missav.ai/cn/release',
      destination,
      destination,
    ]);
    expect(find.text(l10n.videoWeeklyHot), findsOneWidget);
  });

  testWidgets('recommendations stay selected until a catalog page is shown', (
    tester,
  ) async {
    const weeklyHotUrl = 'https://missav.ai/cn/weekly-hot';
    final weeklyHotPage = Completer<VideoCatalogPage>();
    final weeklyHotStarted = Completer<void>();
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Home source title',
        url: 'https://missav.ai/cn',
      ),
      pagesByUrl: const {
        weeklyHotUrl: VideoCatalogPage(
          title: 'Weekly hot source title',
          url: weeklyHotUrl,
        ),
      },
      browseHandler: (url, page) {
        if (url == weeklyHotUrl) {
          weeklyHotStarted.complete();
          return weeklyHotPage.future;
        }
        return Future.value(page);
      },
      recommendationHandler: (_, _, _) async =>
          const VideoRecommendationPage(videos: [], cursor: null),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final l10n = await S.delegate.load(const Locale('en'));
    addTearDown(() {
      if (!weeklyHotPage.isCompleted) {
        weeklyHotPage.complete(
          const VideoCatalogPage(title: 'Weekly hot', url: weeklyHotUrl),
        );
      }
    });

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();
    await _selectVideoDrawerLabel(tester, l10n, l10n.videoRecommendedForYou);
    expect(find.text(l10n.videoRecommendedForYou), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    final drawer = find.byKey(const ValueKey('library-drawer'));
    final weeklyHotLabel = find.descendant(
      of: drawer,
      matching: find.text(l10n.videoWeeklyHot),
    );
    await tester.scrollUntilVisible(
      weeklyHotLabel,
      240,
      scrollable: find
          .descendant(of: drawer, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(weeklyHotLabel);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(weeklyHotStarted.isCompleted, isTrue);

    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pump(const Duration(milliseconds: 300));
    final recommendationLabel = find.descendant(
      of: drawer,
      matching: find.text(l10n.videoRecommendedForYou),
    );
    await tester.scrollUntilVisible(
      recommendationLabel,
      240,
      scrollable: find
          .descendant(of: drawer, matching: find.byType(Scrollable))
          .first,
    );
    final recommendationTile = find.ancestor(
      of: recommendationLabel,
      matching: find.byType(ListTile),
    );
    expect(tester.widget<ListTile>(recommendationTile).selected, isTrue);
    final weeklyHotTile = find.ancestor(
      of: weeklyHotLabel,
      matching: find.byType(ListTile),
    );
    expect(tester.widget<ListTile>(weeklyHotTile).selected, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));

    weeklyHotPage.complete(client.pagesByUrl[weeklyHotUrl]!);
    await tester.pumpAndSettle();
    expect(find.text(l10n.videoWeeklyHot), findsOneWidget);
  });

  testWidgets('downloads route waits for the drawer to finish closing', (
    tester,
  ) async {
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Home catalog',
        url: 'https://missav.ai/cn',
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final observer = _PushObserver();

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen(), observer: observer),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    final pushesBeforeSelection = observer.pushes;
    final l10n = await S.delegate.load(const Locale('en'));
    final drawer = find.byKey(const ValueKey('library-drawer'));
    final downloadTile = find.descendant(
      of: drawer,
      matching: find.widgetWithText(ListTile, l10n.videoDownloads),
    );
    await tester.scrollUntilVisible(
      downloadTile,
      240,
      scrollable: find
          .descendant(of: drawer, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();

    await tester.tap(downloadTile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(downloadTile, findsOneWidget);
    expect(observer.pushes, pushesBeforeSelection);
    expect(find.byType(VideoDownloadsScreen), findsNothing);
    await tester.pumpAndSettle();
    expect(observer.pushes, pushesBeforeSelection + 1);
    expect(find.byType(VideoDownloadsScreen), findsOneWidget);
  });

  testWidgets('video drawer uses the source route allowlist', (tester) async {
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Home catalog',
        url: 'https://missav.ai/cn',
        navigation: [
          VideoLink(
            label: 'Recently updated',
            url: 'https://missav.ai/cn/newer',
            kind: VideoLinkKind.navigation,
          ),
          VideoLink(
            label: 'New releases',
            url: 'https://missav.ai/cn/release-videos',
            kind: VideoLinkKind.navigation,
          ),
          VideoLink(
            label: 'Amateur directory',
            url: 'https://missav.ai/cn/amateur',
            kind: VideoLinkKind.navigation,
          ),
          VideoLink(
            label: 'Series directory',
            url: 'https://missav.ai/cn/series',
            kind: VideoLinkKind.navigation,
          ),
          VideoLink(
            label: 'Uncensored films',
            url: 'https://missav.ai/cn/uncensored',
            kind: VideoLinkKind.navigation,
          ),
        ],
        links: [
          VideoLink(
            label: 'Actor directory',
            url: 'https://missav.ai/cn/actresses',
            kind: VideoLinkKind.actor,
          ),
          VideoLink(
            label: 'Category directory',
            url: 'https://missav.ai/cn/genres',
            kind: VideoLinkKind.category,
          ),
          VideoLink(
            label: 'Tag directory',
            url: 'https://missav.ai/cn/tag/fixture',
            kind: VideoLinkKind.tag,
          ),
          VideoLink(
            label: 'Studio directory',
            url: 'https://missav.ai/cn/studio/fixture',
            kind: VideoLinkKind.studio,
          ),
          VideoLink(
            label: 'Manufacturer directory',
            url: 'https://missav.ai/cn/studio/maker',
            kind: VideoLinkKind.studio,
          ),
          VideoLink(
            label: 'Playlist on home page',
            url: 'https://missav.ai/cn/playlists/123',
            kind: VideoLinkKind.playlist,
          ),
        ],
      ),
    );
    final library = await _testLibrary();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('video_layout_type', 'bigGrid');
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(VideoScreen)),
    );
    final drawer = find.byKey(const ValueKey('library-drawer'));

    Future<void> openDrawer() async {
      final menu = find
          .byKey(const ValueKey('library-menu-button'))
          .hitTestable();
      if (menu.evaluate().isNotEmpty) await tester.tap(menu);
      await tester.pumpAndSettle();
    }

    Future<void> scrollToDrawerLabel(String label) async {
      await tester.scrollUntilVisible(
        find.descendant(of: drawer, matching: find.text(label)),
        240,
        scrollable: find
            .descendant(of: drawer, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
    }

    await openDrawer();
    expect(find.text(l10n.libraryContent), findsOneWidget);
    await scrollToDrawerLabel(l10n.libraryBrowseOptions);
    expect(
      tester.getTopLeft(find.text(l10n.libraryLocal)).dy,
      lessThan(tester.getTopLeft(find.text(l10n.libraryBrowseOptions)).dy),
    );
    expect(
      find.descendant(of: drawer, matching: find.text(l10n.navHome)),
      findsNothing,
    );
    final approvedPaths = {
      l10n.videoNewReleases: 'release',
      l10n.videoRecentlyUpdated: 'new',
      l10n.videoChineseSubtitles: 'chinese-subtitle',
      l10n.videoWeeklyHot: 'weekly-hot',
      l10n.videoUncensoredLeak: 'uncensored-leak',
    };
    for (final label in approvedPaths.keys) {
      expect(find.text(label), findsOneWidget);
    }
    final contentLabels = [...approvedPaths.keys, l10n.videoRecommendedForYou];
    for (var index = 1; index < contentLabels.length; index++) {
      final previousTop = tester
          .getTopLeft(
            find.descendant(
              of: drawer,
              matching: find.text(contentLabels[index - 1]),
            ),
          )
          .dy;
      final currentTop = tester
          .getTopLeft(
            find.descendant(
              of: drawer,
              matching: find.text(contentLabels[index]),
            ),
          )
          .dy;
      expect(currentTop, greaterThan(previousTop));
    }
    for (final label in const [
      'Amateur directory',
      'Series directory',
      'Uncensored films',
      'Actor directory',
      'Category directory',
      'Tag directory',
      'Studio directory',
      'Manufacturer directory',
      'Playlist on home page',
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(find.text(l10n.videoRecentlyUpdated), findsOneWidget);
    expect(find.text(l10n.videoNewReleases), findsOneWidget);

    for (final entry in approvedPaths.entries) {
      await openDrawer();
      await scrollToDrawerLabel(entry.key);
      await tester.tap(
        find.descendant(of: drawer, matching: find.text(entry.key)),
      );
      await tester.pumpAndSettle();
      expect(client.browsedUrls.last, 'https://missav.ai/cn/${entry.value}');
    }

    await openDrawer();
    await scrollToDrawerLabel(l10n.videoRecommendedForYou);
    await tester.tap(
      find.descendant(
        of: drawer,
        matching: find.text(l10n.videoRecommendedForYou),
      ),
    );
    await tester.pumpAndSettle();
    expect(client.recommendationRequests, [(cursor: null, count: 40)]);
    expect(find.text(l10n.noResults), findsOneWidget);

    await openDrawer();
    await scrollToDrawerLabel(l10n.layout);
    await tester.tap(find.text(l10n.layout));
    await tester.pumpAndSettle();
    expect(container.read(videoBrowseLayoutProvider), LayoutType.smallGrid);

    await openDrawer();
    await scrollToDrawerLabel(l10n.layout);
    expect(find.byIcon(Icons.grid_on), findsOneWidget);
    await tester.tap(find.text(l10n.layout));
    await tester.pumpAndSettle();
    expect(container.read(videoBrowseLayoutProvider), LayoutType.list);

    await openDrawer();
    await scrollToDrawerLabel(l10n.layout);
    expect(find.byIcon(Icons.view_list), findsOneWidget);
    await tester.tap(find.text(l10n.layout));
    await tester.pumpAndSettle();
    expect(container.read(videoBrowseLayoutProvider), LayoutType.bigGrid);
    expect(
      preferences.getString(VideoBrowseLayoutNotifier.preferenceKey),
      'bigGrid',
    );
    await openDrawer();
    await scrollToDrawerLabel(l10n.layout);
    expect(
      find.descendant(of: drawer, matching: find.byIcon(Icons.grid_view)),
      findsOneWidget,
    );
  });

  testWidgets(
    'switching to Jable loads its catalog and ignores a late MissAV response',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final oldMissavResponse = Completer<VideoCatalogPage>();
      late String oldMissavUrl;
      final missav = _TestMissavClient(
        browseHandler: (url, _) {
          oldMissavUrl = url;
          return oldMissavResponse.future;
        },
      );
      final jable = _TestJableClient();
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: missav, library: library);

      await tester.pumpWidget(
        _app(
          missav,
          library,
          downloads,
          const VideoScreen(),
          jableClient: jable,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(missav.browsedUrls, hasLength(1));
      expect(missav.browsedUrls.single, startsWith('https://missav.ai/'));

      final menuButton = find.byKey(const ValueKey('library-menu-button'));
      Scaffold.of(tester.element(menuButton)).openDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Jable').last.hitTestable());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(jable.browsedUrls, ['https://jable.tv']);
      expect(find.text('Jable catalog'), findsOneWidget);
      Scaffold.of(tester.element(menuButton)).openDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final l10n = await S.delegate.load(const Locale('en'));
      expect(find.text(l10n.videoJableAccount), findsOneWidget);
      expect(find.text(l10n.videoFavorites), findsOneWidget);
      expect(find.text(l10n.videoActorFavorites), findsNothing);
      expect(find.text(l10n.playlists), findsNothing);
      expect(find.text(l10n.videoWatchHistory), findsNothing);
      expect(find.text(l10n.videoNewReleases), findsOneWidget);
      expect(find.text(l10n.videoChineseSubtitles), findsOneWidget);
      expect(
        (await _videoDrawerTile(tester, l10n.videoNewReleases)).selected,
        isFalse,
      );

      await _videoDrawerTile(tester, l10n.videoFavorites);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('library-drawer')),
          matching: find.text(l10n.videoFavorites),
        ),
      );
      await tester.pumpAndSettle();
      expect(jable.browsedUrls, contains(JableAccount.favoritesUrl));
      expect(find.text(l10n.videoFavorites), findsOneWidget);
      Scaffold.of(tester.element(menuButton)).openDrawer();
      await tester.pumpAndSettle();
      expect(
        (await _videoDrawerTile(tester, l10n.videoFavorites)).selected,
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      oldMissavResponse.complete(
        VideoCatalogPage(title: 'Late MissAV catalog', url: oldMissavUrl),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.text(l10n.videoFavorites), findsOneWidget);
      expect(find.text('Late MissAV catalog'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Jable favorite catalog offers account login after auth failure',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final missav = _TestMissavClient();
      final jable = _TestJableClient(
        browseHandler: (url) async {
          if (JableAccount.isFavoritesUri(Uri.parse(url))) {
            throw const JableLoginRequiredException();
          }
          return VideoCatalogPage(
            title: 'Jable catalog',
            url: url,
            videos: const [
              VideoItem(
                id: 'public-catalog-item',
                sourceKey: 'jable',
                title: 'Public catalog item',
                pageUrl: 'https://jable.tv/videos/public-catalog-item/',
              ),
            ],
          );
        },
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: missav, library: library);
      await tester.pumpWidget(
        _app(
          missav,
          library,
          downloads,
          const VideoScreen(),
          selectedVideoSource: 'jable',
          jableClient: jable,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Public catalog item'), findsOneWidget);

      final menuButton = find.byKey(const ValueKey('library-menu-button'));
      Scaffold.of(tester.element(menuButton)).openDrawer();
      await tester.pumpAndSettle();
      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.text(l10n.videoFavorites).last.hitTestable());
      await tester.pumpAndSettle();

      expect(jable.browsedUrls, contains(JableAccount.favoritesUrl));
      expect(find.text(l10n.videoJableLoginRequired), findsOneWidget);
      expect(find.text('Public catalog item'), findsNothing);
      final openAccount = find.byKey(
        const ValueKey('video-open-jable-account'),
      );
      expect(openAccount, findsOneWidget);
      await tester.tap(openAccount);
      await tester.pumpAndSettle();
      expect(find.byType(JableAccountScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final verifiedImmediately in [true, false]) {
    testWidgets(
      'Jable favorites retry after session import during verification '
      '(verifiedImmediately=$verifiedImmediately)',
      (tester) async {
        final account = _TestJableAccount(loggedIn: true, revision: 1);
        var attempts = 0;
        var verified = verifiedImmediately;
        final missav = _TestMissavClient();
        final jable = _TestJableClient(
          account: account,
          browseHandler: (url) async {
            attempts++;
            if (attempts == 1) {
              throw const JableVerificationRequiredException(
                sourceUrl: JableAccount.favoritesUrl,
              );
            }
            return VideoCatalogPage(
              title: 'Verified favorites',
              url: url,
              videos: const [
                VideoItem(
                  id: 'verified-favorite',
                  sourceKey: 'jable',
                  title: 'Verified favorite video',
                  pageUrl: 'https://jable.tv/videos/verified-favorite/',
                ),
              ],
            );
          },
        );
        final library = await _testLibrary();
        final downloads = _TestVideoDownloads(client: missav, library: library);
        await tester.pumpWidget(
          _app(
            missav,
            library,
            downloads,
            const VideoScreen.catalog(
              url: JableAccount.favoritesUrl,
              sourceKey: 'jable',
            ),
            jableClient: jable,
            verifyJable:
                (
                  context,
                  client, {
                  required sourceUrl,
                  requireLogin = false,
                }) async {
                  // Importing a verified session resets the account state.
                  account.expireSession();
                  return verified;
                },
          ),
        );
        await tester.pumpAndSettle();

        final l10n = await S.delegate.load(const Locale('en'));
        await tester.tap(find.text(l10n.videoVerifyAccess));
        await tester.pumpAndSettle();
        if (!verifiedImmediately) {
          expect(attempts, 1);
          expect(find.text(l10n.videoVerifyAccess), findsOneWidget);
          expect(find.text(l10n.videoJableLoginRequired), findsNothing);
          verified = true;
          await tester.tap(find.text(l10n.videoVerifyAccess));
          await tester.pumpAndSettle();
        }

        expect(attempts, 2);
        expect(find.text('Verified favorite video'), findsOneWidget);
        expect(find.text(l10n.videoJableLoginRequired), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('Jable favorite metadata filters stay within that collection', (
    tester,
  ) async {
    const tag = VideoLink(
      label: 'Favorite genre',
      url: 'https://jable.tv/categories/favorite-genre/',
      kind: VideoLinkKind.category,
    );
    const matching = VideoItem(
      id: 'matching-favorite',
      sourceKey: 'jable',
      title: 'Matching favorite',
      pageUrl: 'https://jable.tv/videos/matching-favorite/',
    );
    const otherFavorite = VideoItem(
      id: 'other-favorite',
      sourceKey: 'jable',
      title: 'Other favorite',
      pageUrl: 'https://jable.tv/videos/other-favorite/',
    );
    const outsideFavorite = VideoItem(
      id: 'outside-favorite',
      sourceKey: 'jable',
      title: 'Outside favorite',
      pageUrl: 'https://jable.tv/videos/outside-favorite/',
    );
    final client = _TestMissavClient();
    addTearDown(client.dispose);
    final jable = _TestJableClient(
      account: _TestJableAccount(
        loggedIn: true,
        revision: 1,
        favorites: const [matching, otherFavorite],
      ),
      filteredVideos: const [matching, outsideFavorite],
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        Builder(
          builder: (context) => VideoScreen.searchScreen(
            context,
            client: jable,
            collectionKey: 'favorites',
            initialFilters: const [tag],
          ),
        ),
        jableClient: jable,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(matching.title), findsOneWidget);
    expect(find.text(otherFavorite.title), findsNothing);
    expect(find.text(outsideFavorite.title), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Jable logout clears favorite content during page navigation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    const favoritesPageTwo = 'https://jable.tv/my/favourites/videos/?page=2';
    final pageTwo = Completer<VideoCatalogPage>();
    final account = _TestJableAccount(loggedIn: true, revision: 1);
    const privateVideo = VideoItem(
      id: 'account-favorite',
      sourceKey: 'jable',
      title: 'Private account favorite',
      pageUrl: 'https://jable.tv/videos/account-favorite/',
    );
    final missav = _TestMissavClient();
    final jable = _TestJableClient(
      account: account,
      browseHandler: (url) => url == favoritesPageTwo
          ? pageTwo.future
          : Future.value(
              url == JableAccount.favoritesUrl
                  ? const VideoCatalogPage(
                      title: 'Jable favorites',
                      url: JableAccount.favoritesUrl,
                      videos: [privateVideo],
                      nextUrl: favoritesPageTwo,
                    )
                  : VideoCatalogPage(title: 'Jable catalog', url: url),
            ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: missav, library: library);
    await tester.pumpWidget(
      _app(
        missav,
        library,
        downloads,
        const VideoScreen(),
        selectedVideoSource: 'jable',
        jableClient: jable,
      ),
    );
    await tester.pumpAndSettle();

    final menuButton = find.byKey(const ValueKey('library-menu-button'));
    Scaffold.of(tester.element(menuButton)).openDrawer();
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.videoFavorites).last.hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Private account favorite'), findsOneWidget);

    await tester.tap(find.text(l10n.nextPage));
    await tester.pump();
    expect(jable.browsedUrls, contains(favoritesPageTwo));
    account.expireSession();
    await tester.pump();
    expect(find.text('Private account favorite'), findsNothing);
    expect(find.text(l10n.videoJableLoginRequired), findsOneWidget);

    pageTwo.complete(
      const VideoCatalogPage(
        title: 'Jable favorites',
        url: favoritesPageTwo,
        videos: [privateVideo],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Private account favorite'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'recommendation pages keep source order and cached pages across catalogs',
    (tester) async {
      const releaseUrl = 'https://missav.ai/cn/release';
      var partialBatchCalls = 0;
      final client = _TestMissavClient(
        catalog: const VideoCatalogPage(
          title: 'Release directory',
          url: releaseUrl,
        ),
        recommendationHandler: (cursor, _, _) async {
          if (cursor == null) {
            return VideoRecommendationPage(
              videos: _videos('recommendation-page-1', 40),
              cursor: 'recomm-id',
            );
          }
          if (cursor == 'recomm-id') {
            partialBatchCalls++;
            if (partialBatchCalls == 1) {
              return VideoRecommendationPage(
                videos: _videos('recommendation-page-2-first', 10),
                cursor: 'recomm-id',
              );
            }
            if (partialBatchCalls == 2) {
              return VideoRecommendationPage(
                videos: _videos('recommendation-page-2-last', 30),
                cursor: 'recomm-id',
              );
            }
            return VideoRecommendationPage(
              videos: _videos('recommendation-page-3', 40),
              cursor: 'recomm-id',
            );
          }
          return const VideoRecommendationPage(videos: [], cursor: null);
        },
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final l10n = await S.delegate.load(const Locale('en'));

      await tester.pumpWidget(
        _app(client, library, downloads, const VideoScreen()),
      );
      await tester.pumpAndSettle();
      await _selectVideoDrawerLabel(tester, l10n, l10n.videoRecommendedForYou);
      expect(find.text('recommendation-page-1 0'), findsOneWidget);
      expect(client.recommendationRequests, [(cursor: null, count: 40)]);

      await _tapNextPage(tester, l10n);
      expect(find.text('recommendation-page-2-first 0'), findsOneWidget);
      final pageTwoPagination = await _visiblePaginationBar(tester);
      expect(pageTwoPagination.currentPage, 2);
      expect(pageTwoPagination.jumpMaxPage, 2);
      expect(client.recommendationRequests, [
        (cursor: null, count: 40),
        (cursor: 'recomm-id', count: 40),
        (cursor: 'recomm-id', count: 40),
      ]);

      await _tapPreviousPage(tester, l10n);
      expect(find.text('recommendation-page-1 0'), findsOneWidget);
      await _tapNextPage(tester, l10n);
      expect(find.text('recommendation-page-2-first 0'), findsOneWidget);
      expect(client.recommendationRequests, hasLength(3));

      await _tapNextPage(tester, l10n);
      expect(find.text('recommendation-page-3 0'), findsOneWidget);
      expect(client.recommendationRequests, [
        (cursor: null, count: 40),
        (cursor: 'recomm-id', count: 40),
        (cursor: 'recomm-id', count: 40),
        (cursor: 'recomm-id', count: 40),
      ]);

      await _selectVideoDrawerLabel(tester, l10n, l10n.videoNewReleases);
      expect(find.text(l10n.videoNewReleases), findsOneWidget);
      await _selectVideoDrawerLabel(tester, l10n, l10n.videoRecommendedForYou);
      expect(find.text('recommendation-page-3 0'), findsOneWidget);
      expect(client.recommendationRequests, hasLength(4));
    },
  );

  testWidgets(
    'partial recommendation batches survive a later failure and retry',
    (tester) async {
      var cursorAttempts = 0;
      final client = _TestMissavClient(
        recommendationHandler: (cursor, _, _) async {
          if (cursor == null) {
            return VideoRecommendationPage(
              videos: _videos('recommendation-page-1', 40),
              cursor: 'recomm-id',
            );
          }
          cursorAttempts++;
          if (cursorAttempts == 1) {
            return VideoRecommendationPage(
              videos: _videos('recommendation-page-2-first', 10),
              cursor: 'recomm-id',
            );
          }
          if (cursorAttempts == 2) {
            throw StateError('Temporary recommendation failure.');
          }
          return VideoRecommendationPage(
            videos: _videos('recommendation-page-2-last', 30),
            cursor: 'recomm-id',
          );
        },
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final l10n = await S.delegate.load(const Locale('en'));

      await tester.pumpWidget(
        _app(client, library, downloads, const VideoScreen()),
      );
      await tester.pumpAndSettle();
      await _selectVideoDrawerLabel(tester, l10n, l10n.videoRecommendedForYou);
      await _tapNextPage(tester, l10n);
      expect(find.text('recommendation-page-1 0'), findsOneWidget);
      expect(find.text(l10n.retry), findsOneWidget);

      await tester.tap(find.text(l10n.retry));
      await tester.pumpAndSettle();
      expect(find.text('recommendation-page-2-first 0'), findsOneWidget);
      final pagination = await _visiblePaginationBar(tester);
      expect(pagination.currentPage, 2);
      expect(client.recommendationRequests, [
        (cursor: null, count: 40),
        (cursor: 'recomm-id', count: 40),
        (cursor: 'recomm-id', count: 40),
        (cursor: 'recomm-id', count: 40),
      ]);
    },
  );

  testWidgets('initial recommendations offer browser verification', (
    tester,
  ) async {
    final client = _TestMissavClient(
      recommendationHandler: (_, _, _) async =>
          throw const MissavVerificationRequiredException(
            sourceUrl: 'https://missav.ai/cn',
          ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final l10n = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();
    await _selectVideoDrawerLabel(tester, l10n, l10n.videoRecommendedForYou);

    expect(find.text(l10n.videoVerificationRequired), findsOneWidget);
    expect(find.text(l10n.videoVerifyAccess), findsOneWidget);
    expect(find.text(l10n.retry), findsOneWidget);
    expect(find.text(l10n.videoOpenSource), findsOneWidget);
  });

  testWidgets(
    'recommendation retry preserves the current page and empty next batches end paging',
    (tester) async {
      var pageTwoAttempts = 0;
      final client = _TestMissavClient(
        recommendationHandler: (cursor, _, _) async {
          if (cursor == null) {
            return VideoRecommendationPage(
              videos: _videos('recommendation-page-1', 40),
              cursor: 'page-2',
            );
          }
          if (cursor == 'page-2') {
            if (pageTwoAttempts++ == 0) {
              throw const MissavVerificationRequiredException(
                sourceUrl: 'https://missav.ai/cn',
              );
            }
            return VideoRecommendationPage(
              videos: _videos('recommendation-page-2', 40),
              cursor: 'page-3',
            );
          }
          return const VideoRecommendationPage(
            videos: [],
            cursor: 'expired-page-4',
          );
        },
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final l10n = await S.delegate.load(const Locale('en'));

      await tester.pumpWidget(
        _app(client, library, downloads, const VideoScreen()),
      );
      await tester.pumpAndSettle();
      await _selectVideoDrawerLabel(tester, l10n, l10n.videoRecommendedForYou);
      await _tapNextPage(tester, l10n);
      expect(find.text('recommendation-page-1 0'), findsOneWidget);
      expect(find.text(l10n.videoVerificationRequired), findsOneWidget);
      expect(find.text(l10n.retry), findsOneWidget);
      expect(find.text(l10n.videoVerifyAccess), findsOneWidget);

      await tester.tap(find.text(l10n.retry));
      await tester.pumpAndSettle();
      expect(find.text('recommendation-page-2 0'), findsOneWidget);
      final pageTwoPagination = await _visiblePaginationBar(tester);
      expect(pageTwoPagination.currentPage, 2);

      await _tapNextPage(tester, l10n);
      expect(find.text('recommendation-page-2 0'), findsOneWidget);
      final pagination = await _visiblePaginationBar(tester);
      expect(pagination.currentPage, 2);
      expect(pagination.hasMore, isFalse);

      await _selectVideoDrawerLabel(tester, l10n, l10n.videoRecommendedForYou);
      expect(find.text('recommendation-page-1 0'), findsOneWidget);
      expect(client.recommendationRequests.last, (cursor: null, count: 40));
    },
  );

  testWidgets('recommendation cache resets when locale or session changes', (
    tester,
  ) async {
    late _TestMissavClient client;
    var pageNumber = 0;
    client = _TestMissavClient(
      recommendationHandler: (cursor, _, _) async {
        expect(cursor, isNull);
        pageNumber++;
        return VideoRecommendationPage(
          videos: _videos(
            'recommendation-${client.testLocale}-$pageNumber',
            40,
          ),
          cursor: null,
        );
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final en = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();
    await _selectVideoDrawerLabel(tester, en, en.videoRecommendedForYou);
    expect(find.text('recommendation-en-1 0'), findsOneWidget);

    expect(client.setLocale('ja'), isTrue);
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        const VideoScreen(),
        locale: const Locale('ja'),
      ),
    );
    await tester.pumpAndSettle();
    final ja = await S.delegate.load(const Locale('ja'));
    expect(find.text(ja.videoRecommendedForYou), findsOneWidget);
    expect(find.text('recommendation-ja-2 0'), findsOneWidget);
    expect(client.recommendationRequests, [
      (cursor: null, count: 40),
      (cursor: null, count: 40),
    ]);

    client.advanceSessionGeneration();
    await tester.pumpAndSettle();
    expect(find.text('recommendation-ja-3 0'), findsOneWidget);
    expect(client.recommendationRequests, hasLength(3));
  });

  testWidgets('stale recommendation responses cannot replace a catalog page', (
    tester,
  ) async {
    const releaseUrl = 'https://missav.ai/cn/release';
    final pageTwo = Completer<VideoRecommendationPage>();
    final requestStarted = Completer<void>();
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Release directory',
        url: releaseUrl,
      ),
      recommendationHandler: (cursor, _, _) {
        if (cursor == null) {
          return Future.value(
            VideoRecommendationPage(
              videos: _videos('recommendation-page-1', 40),
              cursor: 'page-2',
            ),
          );
        }
        requestStarted.complete();
        return pageTwo.future;
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final l10n = await S.delegate.load(const Locale('en'));
    addTearDown(() {
      if (!pageTwo.isCompleted) {
        pageTwo.complete(
          const VideoRecommendationPage(videos: [], cursor: null),
        );
      }
    });

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();
    await _selectVideoDrawerLabel(tester, l10n, l10n.videoRecommendedForYou);
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
    await tester.tap(find.text(l10n.nextPage));
    await tester.pump();
    expect(requestStarted.isCompleted, isTrue);

    final drawer = find.byKey(const ValueKey('library-drawer'));
    final scaffold = find.byWidgetPredicate(
      (widget) =>
          widget is Scaffold &&
          widget.drawer?.key == const ValueKey('library-drawer'),
    );
    final scaffoldState = tester.state<ScaffoldState>(scaffold);
    scaffoldState.openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(scaffoldState.isDrawerOpen, isTrue);
    await tester.scrollUntilVisible(
      find.descendant(of: drawer, matching: find.text(l10n.videoNewReleases)),
      240,
      scrollable: find
          .descendant(of: drawer, matching: find.byType(Scrollable))
          .first,
    );
    final releaseTile = find.descendant(
      of: drawer,
      matching: find.text(l10n.videoNewReleases),
    );
    await tester.ensureVisible(releaseTile);
    await tester.pump();
    expect(tester.getCenter(releaseTile).dx, greaterThanOrEqualTo(0));
    await tester.tap(releaseTile);
    await tester.pumpAndSettle();
    expect(find.text(l10n.videoNewReleases), findsOneWidget);

    pageTwo.complete(
      VideoRecommendationPage(
        videos: _videos('stale-recommendation-page-2', 40),
        cursor: null,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.videoNewReleases), findsOneWidget);

    await _selectVideoDrawerLabel(tester, l10n, l10n.videoRecommendedForYou);
    expect(find.text('recommendation-page-1 0'), findsOneWidget);
    expect(client.recommendationRequests, hasLength(2));
  });

  testWidgets('playlist directory pages accept source route prefixes', (
    tester,
  ) async {
    const firstUrl = 'https://missav.ai/en/playlists';
    const secondUrl = 'https://missav.ai/dm123/en/playlists/?page=2';
    final client = _TestMissavClient(
      pagesByUrl: {
        firstUrl: const VideoCatalogPage(
          title: 'Playlists',
          url: firstUrl,
          nextUrl: secondUrl,
          links: [
            VideoLink(
              label: 'First playlist',
              url: 'https://missav.ai/en/playlists/first',
              kind: VideoLinkKind.playlist,
            ),
          ],
        ),
        secondUrl: const VideoCatalogPage(
          title: 'Playlists',
          url: secondUrl,
          currentPage: 2,
          previousUrl: firstUrl,
          links: [
            VideoLink(
              label: 'Second playlist',
              url: 'https://missav.ai/en/playlists/second',
              kind: VideoLinkKind.playlist,
            ),
          ],
        ),
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        const VideoScreen.catalog(url: firstUrl),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('First playlist'), findsOneWidget);
    final l10n = await S.delegate.load(const Locale('en'));
    await _tapNextPage(tester, l10n);
    expect(find.text('Second playlist'), findsOneWidget);
    expect(
      tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
      2,
    );
    await tester.tap(find.text(l10n.previousPage));
    await tester.pumpAndSettle();
    expect(find.text('First playlist'), findsOneWidget);
  });

  testWidgets(
    'main video search submits keywords and selected filters together',
    (tester) async {
      final client = _TestMissavClient(
        catalog: const VideoCatalogPage(
          title: 'Home',
          url: 'https://missav.ai/en',
        ),
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      await tester.pumpWidget(
        _app(client, library, downloads, const VideoScreen()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-page-search')));
      await tester.pumpAndSettle();
      final genreType = find.byKey(const ValueKey('video-search-type-genre'));
      await tester.ensureVisible(genreType);
      await tester.tap(genreType);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drama'));
      await tester.pumpAndSettle();
      expect(client.filterOptionKinds, [VideoSearchFilterKind.genre]);
      expect(client.combinedSearchRequests, isEmpty);
      expect(client.browsedUrls, contains('https://missav.ai/en/genres/drama'));

      final keywordType = find.byKey(
        const ValueKey('video-search-type-keyword'),
      );
      await tester.ensureVisible(keywordType);
      await tester.tap(keywordType);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-search-input')),
        'keyword',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(client.combinedSearchRequests, hasLength(1));
      expect(client.combinedSearchRequests.last.query, 'keyword');
      expect(client.combinedSearchRequests.last.filters.single.label, 'Drama');
      expect(
        client.combinedSearchRequests.last.filters.single.url,
        'https://missav.ai/en/genres/drama',
      );
      expect(client.combinedSearchRequests.last.current, isTrue);
    },
  );

  testWidgets('source pagination uses previous, next, and jump URLs', (
    tester,
  ) async {
    const page1Url = 'https://missav.ai/en/catalog?page=1';
    const page2Url = 'https://missav.ai/en/catalog?page=2';
    const page3Url = 'https://missav.ai/en/catalog?page=3';
    const page4Url = 'https://missav.ai/en/catalog?page=4';
    const page2 = VideoCatalogPage(
      title: 'Source catalog',
      url: page2Url,
      previousUrl: page1Url,
      nextUrl: page3Url,
      currentPage: 2,
      jumpMaxPage: 8,
      videos: [
        VideoItem(
          id: 'source-page-2',
          title: 'Source page 2',
          pageUrl: 'https://missav.ai/en/source-page-2',
        ),
      ],
    );
    final client = _TestMissavClient(
      catalog: page2,
      pagesByUrl: {
        page1Url: const VideoCatalogPage(
          title: 'Source catalog',
          url: page1Url,
          nextUrl: page2Url,
          currentPage: 1,
          jumpMaxPage: 8,
          videos: [
            VideoItem(
              id: 'source-page-1',
              title: 'Source page 1',
              pageUrl: 'https://missav.ai/en/source-page-1',
            ),
          ],
        ),
        page3Url: const VideoCatalogPage(
          title: 'Source catalog',
          url: page3Url,
          previousUrl: page2Url,
          nextUrl: page4Url,
          currentPage: 3,
          jumpMaxPage: 8,
          videos: [
            VideoItem(
              id: 'source-page-3',
              title: 'Source page 3',
              pageUrl: 'https://missav.ai/en/source-page-3',
            ),
          ],
        ),
        page4Url: const VideoCatalogPage(
          title: 'Source catalog',
          url: page4Url,
          previousUrl: page3Url,
          currentPage: 4,
          jumpMaxPage: 8,
          videos: [
            VideoItem(
              id: 'source-page-4',
              title: 'Source page 4',
              pageUrl: 'https://missav.ai/en/source-page-4',
            ),
          ],
        ),
      },
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        const VideoScreen.catalog(url: page2Url),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));

    await tester.tap(find.text(l10n.nextPage));
    await tester.pumpAndSettle();
    expect(client.browsedUrls, contains(page3Url));
    await tester.tap(find.text(l10n.previousPage));
    await tester.pumpAndSettle();
    expect(client.browsedUrls, contains(page2Url));
    await tester.tap(find.text(l10n.jumpTo));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '4');
    await tester.tap(find.text(l10n.jumpTo).last);
    await tester.pumpAndSettle();

    expect(client.browsedUrls, contains(page4Url));
    expect(
      tester.widget<PaginationBar>(find.byType(PaginationBar)).jumpMaxPage,
      8,
    );
  });

  testWidgets('catalog locally pages loaded home items above the bottom dock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    final client = _TestMissavClient(
      catalog: VideoCatalogPage(
        title: 'Home catalog',
        url: 'https://missav.ai/en',
        videos: _videos('home', 41),
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    final home = Scaffold(
      extendBody: true,
      body: Builder(
        builder: (context) {
          final mediaQuery = MediaQuery.of(context);
          return MediaQuery(
            data: mediaQuery.copyWith(
              viewPadding: mediaQuery.viewPadding.copyWith(
                bottom: mediaQuery.padding.bottom,
              ),
            ),
            child: const SafeArea(
              top: false,
              bottom: false,
              child: VideoScreen(),
            ),
          );
        },
      ),
      bottomNavigationBar: AppBottomDock(
        selectedIndex: 0,
        onDestinationSelected: (_) {},
        destinations: const [
          NavigationDestination(icon: Icon(Icons.movie), label: 'Videos'),
          NavigationDestination(icon: Icon(Icons.menu_book), label: 'Comics'),
        ],
      ),
    );
    await tester.pumpWidget(_app(client, library, downloads, home));
    await tester.pumpAndSettle();

    final collection = tester.widget<VideoCollectionView<VideoItem>>(
      find.byType(VideoCollectionView<VideoItem>),
    );
    expect(collection.items, hasLength(40));
    final scrollController = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(PaginationBar)).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(AppBottomDock)).top),
    );

    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.nextPage));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<VideoCollectionView<VideoItem>>(
            find.byType(VideoCollectionView<VideoItem>),
          )
          .items
          .single
          .id,
      'home-40',
    );
  });

  testWidgets('favorites and history searches page one full local result', (
    tester,
  ) async {
    final l10n = await S.delegate.load(const Locale('en'));
    for (final collection in const [
      (path: 'saved', prefix: 'favorite'),
      (path: 'history', prefix: 'history'),
    ]) {
      final url = 'https://missav.ai/en/${collection.path}';
      final client = _TestMissavClient(
        loggedIn: true,
        catalog: VideoCatalogPage(title: collection.path, url: url),
        collectionSearchResults: _videos(collection.prefix, 41),
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      await tester.pumpWidget(
        _app(client, library, downloads, VideoScreen.catalog(url: url)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-page-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('video-filter-genre')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('video-search-input')),
        collection.prefix,
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(client.collectionSearchCalls, 1);

      await _tapNextPage(tester, l10n);
      expect(client.collectionSearchCalls, 1);
      expect(find.text('${collection.prefix} 40'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      client.dispose();
    }
  });

  testWidgets(
    'metadata filters from account search stay within that collection',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const tag = VideoLink(
        label: 'Account genre',
        url: 'https://missav.ai/cn/genres/account-genre',
        kind: VideoLinkKind.category,
      );
      const video = VideoItem(
        id: 'account-tagged',
        title: 'Account result',
        pageUrl: 'https://missav.ai/cn/account-tagged',
        tags: [tag],
      );
      const collectionUrl = 'https://missav.ai/en/saved';
      final client = _TestMissavClient(
        loggedIn: true,
        catalog: const VideoCatalogPage(title: 'Favorites', url: collectionUrl),
        collectionSearchResults: const [video],
      );
      addTearDown(client.dispose);
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final l10n = await S.delegate.load(const Locale('en'));

      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-page-search')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-search-input')),
        'Account',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(client.collectionSearchCalls, 1);
      expect(find.text(video.title), findsOneWidget);

      await tester.tap(find.text(tag.label));
      await tester.pumpAndSettle();

      expect(client.collectionSearchCalls, 2);
      expect(client.combinedSearchRequests, hasLength(1));
      expect(client.combinedSearchRequests.single.query, 'Account');
      expect(
        client.combinedSearchRequests.single.filters.map(
          (filter) => filter.url,
        ),
        [tag.url],
      );
      expect(client.browsedUrls, isNot(contains(tag.url)));
      expect(find.text(video.title), findsNothing);
      expect(find.text(l10n.noResults), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('download queue shares card geometry after resize', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = VideoItem(
      id: 'download-duration',
      title: List.filled(12, 'A deliberately long download title').join(' '),
      pageUrl: 'https://missav.ai/en/download-duration',
      durationSeconds: 3723,
    );
    final client = _TestMissavClient();
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(
      client: client,
      library: library,
      tasks: [
        VideoDownloadTask(
          id: 'download-duration',
          video: video,
          quality: '720p',
          isHls: false,
          status: VideoDownloadStatus.queued,
        ),
      ],
    );
    final s = await S.delegate.load(const Locale('en'));
    for (final (size, textScale) in [
      (const Size(320, 800), 1.3),
      (const Size(1280, 800), 1.3),
      (const Size(320, 800), 2.5),
      (const Size(1280, 800), 2.5),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoDownloadsScreen(),
          textScale: textScale,
        ),
      );
      await tester.pumpAndSettle();

      final titleFinder = find.text(video.title);
      final titleWidget = tester.widget<Text>(titleFinder);
      expect(titleWidget.maxLines, 4);
      expect(titleWidget.overflow, TextOverflow.ellipsis);
      if (size.width == 320) {
        expect(
          tester.renderObject<RenderParagraph>(titleFinder).didExceedMaxLines,
          isTrue,
        );
      }
      final card = find.ancestor(of: titleFinder, matching: find.byType(Card));
      final surface = tester.getRect(
        find.descendant(of: card, matching: find.byType(Material)).first,
      );
      final horizontalPadding = size.width > size.height ? 24.0 : 8.0;
      expect(surface.left, closeTo(horizontalPadding, 0.1));
      expect(surface.right, closeTo(size.width - horizontalPadding, 0.1));

      final title = tester.getRect(titleFinder);
      final duration = tester.getRect(
        find.byKey(const ValueKey('video-duration-download-duration')),
      );
      final coverFinder = find.byKey(
        const ValueKey('video-cover-download-duration'),
      );
      final cover = tester.getRect(coverFinder);
      expect(cover.width / cover.height, closeTo(4 / 3, 0.001));
      if (size.width == 320) {
        expect(cover.height, closeTo(title.height, 0.1));
      }
      expect(find.text('01:02:03'), findsOneWidget);
      expect(duration.top, greaterThan(title.bottom));
      expect(duration.top, greaterThan(cover.bottom));
      expect(duration.left, closeTo(cover.left, 0.1));
      expect(
        duration.top,
        greaterThan(tester.getRect(find.text('Queued · 720p')).bottom),
      );
      for (final icon in [Icons.pause, Icons.delete_outline]) {
        final button = find.descendant(
          of: card,
          matching: find.widgetWithIcon(IconButton, icon),
        );
        final bounds = tester.getRect(button);
        expect(bounds.left, greaterThanOrEqualTo(surface.left));
        expect(bounds.right, lessThanOrEqualTo(surface.right));
        expect(bounds.bottom, lessThanOrEqualTo(surface.bottom));
      }
      expect(tester.takeException(), isNull, reason: '$size at $textScale');

      final delete = find.descendant(
        of: card,
        matching: find.widgetWithIcon(IconButton, Icons.delete_outline),
      );
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text(s.cancel));
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    'downloads list paginates, clamps after delete, and search pages',
    (tester) async {
      final client = _TestMissavClient();
      final library = await _testLibrary();
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt('page_size_preference', 20);
      final downloads = _TestVideoDownloads(
        client: client,
        library: library,
        tasks: [
          for (final video in _videos('download', 41))
            VideoDownloadTask(
              id: video.id,
              video: video,
              quality: '720p',
              isHls: false,
              status: VideoDownloadStatus.queued,
            ),
        ],
      );
      await tester.pumpWidget(
        _app(client, library, downloads, const VideoDownloadsScreen()),
      );
      await tester.pumpAndSettle();
      final l10n = await S.delegate.load(const Locale('en'));

      await _tapNextPage(tester, l10n);
      await _tapNextPage(tester, l10n);
      expect(
        tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
        3,
      );
      final lastTask = find.ancestor(
        of: find.text('download 40'),
        matching: find.byType(Card),
      );
      await tester.tap(
        find.descendant(of: lastTask, matching: find.byTooltip(l10n.delete)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.delete).last);
      await tester.pumpAndSettle();
      final downloadsScroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      downloadsScroll.jumpTo(downloadsScroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        tester.widget<PaginationBar>(find.byType(PaginationBar)).currentPage,
        2,
      );
      expect(downloads.tasks, hasLength(40));

      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-search-input')),
        'download',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await _tapNextPage(tester, l10n);
      expect(find.text('download 20'), findsOneWidget);
    },
  );

  for (final sourceKey in ['missav', 'jable']) {
    testWidgets(
      '$sourceKey actors in download search open their source catalog',
      (tester) async {
        final actor = VideoLink(
          label: 'Sample actor',
          url: sourceKey == 'jable'
              ? 'https://jable.tv/models/sample/'
              : 'https://missav.ai/en/actresses/sample',
          kind: VideoLinkKind.actor,
        );
        final video = VideoItem(
          id: 'sample',
          sourceKey: sourceKey,
          title: 'Sample video',
          pageUrl: sourceKey == 'jable'
              ? 'https://jable.tv/videos/sample/'
              : 'https://missav.ai/en/sample',
          actors: [actor],
        );
        final catalog = VideoCatalogPage(
          title: 'Actor catalog',
          url: actor.url,
        );
        final client = _TestMissavClient(pagesByUrl: {actor.url: catalog});
        final jableClient = _TestJableClient(
          browseHandler: (_) async => catalog,
        );
        final library = await _testLibrary();
        final downloads = _TestVideoDownloads(
          client: client,
          library: library,
          tasks: [
            VideoDownloadTask(
              id: video.storageKey,
              video: video,
              quality: '720p',
              isHls: false,
              status: VideoDownloadStatus.completed,
              localPath: 'unused.mp4',
            ),
          ],
        );
        await tester.pumpWidget(
          _app(
            client,
            library,
            downloads,
            const VideoDownloadsScreen(),
            jableClient: jableClient,
          ),
        );
        await tester.pumpAndSettle();
        final s = await S.delegate.load(const Locale('en'));
        await tester.tap(find.byTooltip(s.search));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('video-search-input')),
          'Sample',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        await tester.tap(find.text(actor.label));
        await tester.pumpAndSettle();

        expect(find.text('Actor catalog'), findsOneWidget);
        expect(
          sourceKey == 'jable' ? jableClient.browsedUrls : client.browsedUrls,
          contains(actor.url),
        );
        expect(
          sourceKey == 'jable' ? client.browsedUrls : jableClient.browsedUrls,
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'tags in online and download collection searches open their catalog',
    (tester) async {
      const tag = VideoLink(
        label: 'Drama',
        url: 'https://missav.ai/cn/genres/drama',
        kind: VideoLinkKind.category,
      );
      const video = VideoItem(
        id: 'tagged',
        title: 'Sample video',
        pageUrl: 'https://missav.ai/cn/tagged',
        tags: [tag],
      );
      final l10n = await S.delegate.load(const Locale('en'));
      for (final isDownload in [false, true]) {
        final searchedFilterUrls = <List<String>>[];
        final client = _TestMissavClient(
          pagesByUrl: {
            tag.url: VideoCatalogPage(title: 'Genre catalog', url: tag.url),
          },
        );
        final library = await _testLibrary();
        final downloads = _TestVideoDownloads(
          client: client,
          library: library,
          tasks: const [
            VideoDownloadTask(
              id: 'tagged',
              video: video,
              quality: '720p',
              isHls: false,
              status: VideoDownloadStatus.completed,
              localPath: 'unused.mp4',
            ),
          ],
        );
        await tester.pumpWidget(
          _app(
            client,
            library,
            downloads,
            isDownload
                ? const VideoDownloadsScreen()
                : VideoSearchScreen(
                    title: 'Search',
                    initialQuery: 'Sample',
                    search: (_, filters, _) async {
                      searchedFilterUrls.add(
                        filters.map((filter) => filter.url).toList(),
                      );
                      return const VideoSearchResults.collection([video]);
                    },
                    browsePage: client.browse,
                  ),
          ),
        );
        await tester.pumpAndSettle();
        if (isDownload) {
          await tester.tap(find.byTooltip(l10n.search));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('video-search-input')),
            'Sample',
          );
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Drama'));
        await tester.pumpAndSettle();
        if (isDownload) {
          expect(client.browsedUrls, contains(tag.url));
          expect(find.text('Genre catalog'), findsOneWidget);
        } else {
          expect(searchedFilterUrls.last, [tag.url]);
          expect(client.browsedUrls, isNot(contains(tag.url)));
          expect(find.text('Genre catalog'), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets('finishing a deletion after leaving downloads is safe', (
    tester,
  ) async {
    final client = _TestMissavClient();
    final library = await _testLibrary();
    final video = _videos('pending-delete', 1).single;
    final removeCompleter = Completer<void>();
    final downloads = _TestVideoDownloads(
      client: client,
      library: library,
      tasks: [
        VideoDownloadTask(
          id: video.id,
          video: video,
          quality: '720p',
          isHls: false,
          status: VideoDownloadStatus.queued,
        ),
      ],
      removeCompleter: removeCompleter,
    );
    final home = Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const VideoDownloadsScreen(),
              ),
            ),
            child: const Text('Open downloads'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(_app(client, library, downloads, home));
    await tester.tap(find.text('Open downloads'));
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.byTooltip(l10n.delete));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.delete).last);
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();
    removeCompleter.complete();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  for (final covered in [false, true]) {
    testWidgets(
      'account confirmation retains public catalog and scroll (covered=$covered)',
      (tester) async {
        final client = _TestMissavClient(
          catalog: VideoCatalogPage(
            title: 'Public catalog',
            url: 'https://missav.ai/en',
            videos: _videos('public', 40),
          ),
        );
        final library = await _testLibrary();
        final downloads = _TestVideoDownloads(client: client, library: library);
        await tester.pumpWidget(
          _app(client, library, downloads, const VideoScreen()),
        );
        await tester.pumpAndSettle();
        final scroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        scroll.jumpTo(180);
        await tester.pumpAndSettle();
        final navigator = Navigator.of(
          tester.element(find.byType(VideoScreen)),
        );
        if (covered) {
          unawaited(
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Details')),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }
        client.confirmAccount('Saved account');
        await tester.pumpAndSettle();
        if (covered) {
          navigator.pop();
          await tester.pumpAndSettle();
        }
        expect(client.browsedUrls, hasLength(1));
        expect(scroll.offset, 180);
        expect(find.text('Public catalog'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final path in [
    'saved',
    'saved/actresses',
    'playlists',
    'playlists/123',
    'history',
  ]) {
    testWidgets('account changes refresh the $path collection', (tester) async {
      final url = 'https://missav.ai/en/$path';
      final client = _TestMissavClient(
        loggedIn: true,
        accountName: 'Account A',
        catalog: VideoCatalogPage(title: 'Account collection', url: url),
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      await tester.pumpWidget(
        _app(client, library, downloads, VideoScreen.catalog(url: url)),
      );
      await tester.pumpAndSettle();
      client.confirmAccount('Account B');
      await tester.pumpAndSettle();
      expect(client.browsedUrls, [url, url]);
    });
  }

  for (final (path, kind, previousAccount)
      in <(String, VideoLinkKind?, String?)>[
        ('saved', null, null),
        ('saved/actresses', VideoLinkKind.actor, null),
        ('playlists', VideoLinkKind.playlist, null),
        ('history', null, null),
        ('saved', null, 'Previous account'),
      ]) {
    testWidgets('account confirmation refreshes an in-flight $path '
        '(previous account: $previousAccount)', (tester) async {
      final url = 'https://missav.ai/en/$path';
      final stalePage = VideoCatalogPage(
        title: 'Account collection',
        url: url,
        videos: previousAccount == null
            ? const []
            : const [
                VideoItem(
                  id: 'old-video',
                  title: 'Previous account item',
                  pageUrl: 'https://missav.ai/en/old-video',
                ),
              ],
      );
      final freshPage = VideoCatalogPage(
        title: 'Account collection',
        url: url,
        videos: kind == null
            ? const [
                VideoItem(
                  id: 'saved-video',
                  title: 'Account item',
                  pageUrl: 'https://missav.ai/en/saved-video',
                ),
              ]
            : const [],
        links: kind == null
            ? const []
            : [
                VideoLink(
                  label: 'Account item',
                  url: kind == VideoLinkKind.actor
                      ? 'https://missav.ai/en/actresses/example'
                      : 'https://missav.ai/en/playlists/example',
                  kind: kind,
                ),
              ],
      );
      final firstStarted = Completer<void>();
      final firstResult = Completer<VideoCatalogPage>();
      var requests = 0;
      final client = _TestMissavClient(
        catalog: stalePage,
        loggedIn: previousAccount != null,
        accountName: previousAccount,
        browseHandler: (_, _) {
          requests++;
          if (requests == 1) {
            firstStarted.complete();
            return firstResult.future;
          }
          return Future.value(freshPage);
        },
      );
      addTearDown(() {
        if (!firstResult.isCompleted) firstResult.complete(stalePage);
      });
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      await tester.pumpWidget(
        _app(client, library, downloads, VideoScreen.catalog(url: url)),
      );
      await tester.runAsync(() => firstStarted.future);

      client.confirmAccount('Saved account');
      expect(requests, 2);
      await tester.pumpAndSettle();
      expect(find.text('Account item'), findsOneWidget);

      firstResult.complete(stalePage);
      await tester.pumpAndSettle();

      expect(client.isLoggedIn, isTrue);
      expect(find.text('Account item'), findsOneWidget);
      expect(find.text('Previous account item'), findsNothing);
    });
  }

  testWidgets('account confirmed by a collection page reloads once', (
    tester,
  ) async {
    const url = 'https://missav.ai/en/saved/actresses';
    var requests = 0;
    final adapter = MissavBrowserAdapter(
      runJavaScript: (_) async {},
      currentUrl: () async => 'https://missav.ai/en',
      navigateDocument: (uri, _) async {
        requests++;
        return '''
<html><body x-data="{user: {name: 'Saved account'}}">
<main><a href="/en/actresses/example">Account actor</a></main>
</body></html>
''';
      },
      disposeBrowser: () async {},
    );
    final client = MissavClient(secureStorage: _EmptyVideoSecureStorage())
      ..useVerifiedBrowserTransport(adapter);
    addTearDown(client.dispose);
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen.catalog(url: url)),
    );
    await tester.pumpAndSettle();

    expect(client.isLoggedIn, isTrue);
    expect(find.text('Account actor'), findsOneWidget);
    expect(requests, 2);
  });

  testWidgets('logout clears and reloads an account catalog on return', (
    tester,
  ) async {
    var browserCleanupCalls = 0;
    final client = _TestMissavClient(
      loggedIn: true,
      accountName: 'Account A',
      catalog: const VideoCatalogPage(
        title: 'Account history',
        url: 'https://missav.ai/cn/favorites',
        videos: [
          VideoItem(
            id: 'private-1',
            title: 'Private account video',
            pageUrl: 'https://missav.ai/cn/private-1',
          ),
        ],
      ),
      signedOutCatalog: const VideoCatalogPage(
        title: 'Signed out',
        url: 'https://missav.ai/cn/favorites',
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        const VideoScreen.catalog(url: 'https://missav.ai/cn/favorites'),
        clearBrowserSession: () async {
          browserCleanupCalls++;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private account video'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Account A'));
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text('Account A'), findsOneWidget);
    expect(find.text(l10n.logout), findsOneWidget);
    await tester.tap(find.text(l10n.logout));
    await tester.pumpAndSettle();
    expect(client.isLoggedIn, isFalse);
    expect(browserCleanupCalls, 1);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Private account video'), findsNothing);
    expect(find.text(l10n.videoFavorites), findsOneWidget);
    expect(
      client.browsedUrls.where((url) => url.endsWith('/favorites')).length,
      2,
    );
  });

  testWidgets(
    'unfavoriting an actor removes only that actor from saved actresses',
    (tester) async {
      const collectionUrl = 'https://missav.ai/en/saved/actresses';
      const actor = VideoLink(
        label: 'Saved actor',
        url: 'https://missav.ai/en/actresses/saved',
        kind: VideoLinkKind.actor,
      );
      const otherActor = VideoLink(
        label: 'Other saved actor',
        url: 'https://missav.ai/en/actresses/other',
        kind: VideoLinkKind.actor,
      );
      final client = _TestMissavClient(
        loggedIn: true,
        catalog: const VideoCatalogPage(
          title: 'Saved actresses',
          url: collectionUrl,
          links: [actor, otherActor],
        ),
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoScreen.catalog(url: collectionUrl),
        ),
      );
      await tester.pumpAndSettle();

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byTooltip(actor.label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.videoUnfavoriteActor));
      await tester.pumpAndSettle();

      expect(client.actorFavoriteChanges, [false]);
      expect(find.text(actor.label), findsNothing);
      expect(find.text(otherActor.label), findsOneWidget);
    },
  );

  testWidgets(
    'actor favorites show avatar fallbacks and retain pagination and actions',
    (tester) async {
      final actors = List.generate(
        41,
        (index) => VideoLink(
          label: 'Fixture actor $index',
          url: 'https://missav.ai/cn/actresses/fixture-$index',
          cover: index == 0 || index == 40
              ? 'https://fourhoi.com/actor/fixture-$index.jpg'
              : '',
          kind: VideoLinkKind.actor,
        ),
      );
      final client = _TestMissavClient(
        loggedIn: true,
        catalog: const VideoCatalogPage(
          title: 'Source actor directory',
          url: 'https://missav.ai/cn/actresses',
        ),
        pagesByUrl: {
          'https://missav.ai/en/saved/actresses': VideoCatalogPage(
            title: 'Actor favorites',
            url: 'https://missav.ai/en/saved/actresses',
            links: actors,
          ),
        },
      );
      final library = await _testLibrary();
      final downloads = _TestVideoDownloads(client: client, library: library);
      final imageBytes = img.encodePng(img.Image(width: 2, height: 2));
      final imageBody = Completer<List<int>>();
      final imageRequestStarted = Completer<void>();
      final imageClient = _DeferredVideoCoverHttpClient(
        imageBody.future,
        imageRequestStarted: imageRequestStarted,
        contentLength: imageBytes.length,
        bodyForRequest: (request) =>
            request == 1 ? imageBody.future : Future.value(const <int>[]),
        contentLengthForRequest: (request) =>
            request == 1 ? imageBytes.length : 0,
        statusCodeForRequest: (request) =>
            request == 1 ? HttpStatus.ok : HttpStatus.notFound,
      );
      final previousHttpClientProvider = debugNetworkImageHttpClientProvider;
      debugNetworkImageHttpClientProvider = () => imageClient;
      try {
        await tester.pumpWidget(
          _app(
            client,
            library,
            downloads,
            const VideoScreen.catalog(url: 'https://missav.ai/cn/actresses'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('library-menu-button')));
        await tester.pumpAndSettle();
        final drawer = find.byKey(const ValueKey('library-drawer'));
        expect(
          find.descendant(of: drawer, matching: find.text('Fixture actor 0')),
          findsNothing,
        );
        final l10n = await S.delegate.load(const Locale('en'));
        await tester.scrollUntilVisible(
          find.descendant(
            of: drawer,
            matching: find.text(l10n.videoActorFavorites),
          ),
          240,
          scrollable: find
              .descendant(of: drawer, matching: find.byType(Scrollable))
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: drawer,
            matching: find.text(l10n.videoActorFavorites),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => imageRequestStarted.future.timeout(const Duration(seconds: 5)),
        );
        await tester.pumpAndSettle();

        expect(find.text('Fixture actor 0'), findsOneWidget);
        expect(imageClient.requestCount, 1);
        final firstActorTile = find.ancestor(
          of: find.text('Fixture actor 0'),
          matching: find.byType(ListTile),
        );
        final firstActorImage = find.descendant(
          of: firstActorTile,
          matching: find.byType(Image),
        );
        expect(firstActorImage, findsOneWidget);
        final imageStream = tester
            .widget<Image>(firstActorImage)
            .image
            .resolve(
              createLocalImageConfiguration(tester.element(firstActorImage)),
            );
        final imageDecoded = Completer<void>();
        final imageStreamListener = ImageStreamListener((
          image,
          synchronousCall,
        ) {
          if (!imageDecoded.isCompleted) imageDecoded.complete();
        });
        imageStream.addListener(imageStreamListener);
        expect(
          find.descendant(
            of: firstActorTile,
            matching: find.byIcon(Icons.person_outline),
          ),
          findsOneWidget,
        );
        final secondActorTile = find.ancestor(
          of: find.text('Fixture actor 1'),
          matching: find.byType(ListTile),
        );
        expect(
          find.descendant(
            of: secondActorTile,
            matching: find.byIcon(Icons.person_outline),
          ),
          findsOneWidget,
        );
        final thirdActorTile = find.ancestor(
          of: find.text('Fixture actor 2'),
          matching: find.byType(ListTile),
        );
        expect(
          find.descendant(
            of: thirdActorTile,
            matching: find.byIcon(Icons.person_outline),
          ),
          findsOneWidget,
        );

        try {
          await tester.runAsync(() async => imageBody.complete(imageBytes));
          final decodeTimeout = Stopwatch()..start();
          while (!imageDecoded.isCompleted &&
              decodeTimeout.elapsed < const Duration(seconds: 5)) {
            await tester.runAsync(() {
              final eventLoopTurn = Completer<void>();
              Timer.run(() => eventLoopTurn.complete());
              return eventLoopTurn.future;
            });
            await tester.pump();
          }
          expect(imageDecoded.isCompleted, isTrue);
        } finally {
          imageStream.removeListener(imageStreamListener);
        }
        final firstActorRawImage = find.descendant(
          of: firstActorTile,
          matching: find.byType(RawImage),
        );
        expect(firstActorRawImage, findsOneWidget);
        expect(tester.widget<RawImage>(firstActorRawImage).image, isNotNull);
        expect(imageClient.requestCount, 1);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: firstActorTile,
            matching: find.byIcon(Icons.person_outline),
          ),
          findsNothing,
        );
        await tester.tap(find.byTooltip('Fixture actor 0'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.videoFavoriteActor));
        await tester.pumpAndSettle();
        expect(client.actorFavoriteChanges, [true]);

        await _tapNextPage(tester, l10n);
        expect(find.text('Fixture actor 40'), findsOneWidget);
        expect(imageClient.requestCount, 2);
        final lastActorTile = find.ancestor(
          of: find.text('Fixture actor 40'),
          matching: find.byType(ListTile),
        );
        expect(
          find.descendant(
            of: lastActorTile,
            matching: find.byIcon(Icons.person_outline),
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('Fixture actor 40'));
        await tester.tap(find.text('Fixture actor 40'));
        await tester.pumpAndSettle();
        expect(client.browsedUrls, contains(actors.last.url));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        client.dispose();
      } finally {
        if (!imageBody.isCompleted) imageBody.complete(imageBytes);
        debugNetworkImageHttpClientProvider = previousHttpClientProvider;
      }
    },
  );

  testWidgets('watch history clearing confirms and refreshes from source', (
    tester,
  ) async {
    final client = _TestMissavClient(
      loggedIn: true,
      catalog: const VideoCatalogPage(
        title: 'Watch history',
        url: 'https://missav.ai/cn/history',
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(
        client,
        library,
        downloads,
        const VideoScreen.catalog(url: 'https://missav.ai/cn/history'),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.clearHistory));
    await tester.pumpAndSettle();
    expect(find.text(l10n.clearHistoryConfirm), findsOneWidget);
    await tester.tap(find.text(l10n.confirm));
    await tester.pumpAndSettle();

    expect(client.clearHistoryCalls, 1);
    expect(client.browsedUrls, [
      'https://missav.ai/cn/history',
      'https://missav.ai/cn/history',
    ]);
  });

  testWidgets('source challenge exposes a source action', (tester) async {
    final client = _TestMissavClient(
      browseError: const MissavVerificationRequiredException(
        sourceUrl: 'https://missav.ai/cn',
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text(l10n.videoVerificationRequired), findsOneWidget);
    expect(find.text(l10n.videoVerifyAccess), findsOneWidget);
    expect(find.text(l10n.videoOpenSource), findsOneWidget);
  });

  testWidgets('account collection authentication failure prompts login', (
    tester,
  ) async {
    const url = 'https://missav.ai/en/saved';
    final client = _TestMissavClient(
      browseError: const MissavAuthenticationException(sourceUrl: url),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen.catalog(url: url)),
    );
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text(l10n.videoLoginRequired), findsOneWidget);
  });

  testWidgets('expired browser collection session returns to login', (
    tester,
  ) async {
    const url = 'https://missav.ai/en/saved';
    var requests = 0;
    final adapter = MissavBrowserAdapter(
      runJavaScript: (_) async {},
      currentUrl: () async => 'https://missav.ai/en',
      navigateDocument: (uri, cancelled) => navigateMissavDocument(
        uri,
        cancelled,
        navigate: (_) async {
          requests++;
        },
        read: (_) async => {
          'url': uri.toString(),
          'html': requests == 1
              ? '<html><body x-data="{user: {name: \'viewer\'}}"></body></html>'
              : '<html><body><main></main></body></html>',
          'responseStatus': requests == 1 ? 200 : 401,
        },
        stop: () async {},
      ),
      disposeBrowser: () async {},
    );
    final client = MissavClient(secureStorage: _EmptyVideoSecureStorage())
      ..useVerifiedBrowserTransport(adapter);
    addTearDown(client.dispose);
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen.catalog(url: url)),
    );
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    expect(client.isLoggedIn, isFalse);
    expect(find.text(l10n.videoLoginRequired), findsOneWidget);
    expect(requests, 3);
  });

  testWidgets('ordinary error does not offer browser verification', (
    tester,
  ) async {
    final client = _TestMissavClient(
      browseError: const MissavException(
        'MissAV requires browser verification.',
        sourceUrl: 'https://missav.ai/cn',
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();

    final l10n = await S.delegate.load(const Locale('en'));
    expect(find.text(l10n.videoLoadFailed), findsOneWidget);
    expect(find.text(l10n.videoVerifyAccess), findsNothing);
    expect(find.text(l10n.videoOpenSource), findsOneWidget);
  });

  testWidgets('catalog fits narrow and wide windows at larger text scale', (
    tester,
  ) async {
    final client = _TestMissavClient(
      catalog: VideoCatalogPage(
        title: 'Source catalog',
        url: 'https://missav.ai/cn',
        videos: [
          for (var index = 0; index < 6; index++)
            VideoItem(
              id: 'dvd-$index',
              title: 'Fixture video $index with a longer title',
              pageUrl: 'https://missav.ai/cn/dvd-$index',
            ),
        ],
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen(), textScale: 1.3),
    );
    await tester.pumpAndSettle();
    final narrowError = tester.takeException();
    expect(narrowError, isNull);

    tester.view.physicalSize = const Size(1280, 900);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  testWidgets('writes a local catalog preview image', (tester) async {
    final client = _TestMissavClient(
      catalog: VideoCatalogPage(
        title: 'Video catalog',
        url: 'https://missav.ai/cn',
        videos: [
          for (var index = 0; index < 6; index++)
            VideoItem(
              id: 'preview-$index',
              title: 'Fixture video ${index + 1}',
              pageUrl: 'https://missav.ai/cn/preview-$index',
            ),
        ],
      ),
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('video-ui-preview'),
        child: _app(client, library, downloads, const VideoScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('video-ui-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final directory = Directory('build');
      await directory.create(recursive: true);
      await File('build/video-ui-preview.png').writeAsBytes(
        data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    });
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });
}

Widget _app(
  MissavClient client,
  VideoLibrary library,
  VideoDownloads downloads,
  Widget home, {
  double textScale = 1,
  Locale locale = const Locale('en'),
  String selectedVideoSource = 'missav',
  JableClient? jableClient,
  Future<bool> Function(
    BuildContext context,
    JableClient client, {
    required String sourceUrl,
    bool requireLogin,
  })?
  verifyJable,
  Future<void> Function()? clearBrowserSession,
  NavigatorObserver? observer,
}) => ProviderScope(
  overrides: [
    videoClientProvider.overrideWith((ref) => client),
    videoSelectedSourceProvider.overrideWith((ref) => selectedVideoSource),
    jableVideoClientProvider.overrideWith((ref) {
      final sourceClient = jableClient ?? JableClient();
      ref.onDispose(sourceClient.dispose);
      return sourceClient;
    }),
    if (verifyJable != null)
      jableAccessVerifierProvider.overrideWithValue(verifyJable),
    videoLibraryProvider.overrideWith((ref) => library),
    videoDownloadsProvider.overrideWith((ref) => downloads),
    videoBrowserSessionCleanupProvider.overrideWithValue(
      clearBrowserSession ?? () async {},
    ),
    currentTrackProvider.overrideWith((ref) => Stream.value(null)),
  ],
  child: MaterialApp(
    locale: locale,
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    navigatorObservers: [if (observer != null) observer],
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

class _TestJableClient extends JableClient {
  _TestJableClient({
    this.browseHandler,
    JableAccount? account,
    this.filteredVideos = const [],
  }) : _testAccount = account;

  final browsedUrls = <String>[];
  final Future<VideoCatalogPage> Function(String url)? browseHandler;
  final List<VideoItem> filteredVideos;
  JableAccount? _testAccount;

  @override
  JableAccount get account => _testAccount ?? super.account;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<VideoItem>> searchWithFilters(
    String query,
    List<VideoLink> filters, {
    bool Function()? isCurrent,
  }) async => filteredVideos;

  @override
  Future<VideoCatalogPage> browse(
    String url, {
    CancelToken? cancelToken,
    void Function(VideoCatalogPage page)? onParsed,
    bool Function()? isCurrent,
  }) async {
    browsedUrls.add(url);
    final page =
        await browseHandler?.call(url) ??
        VideoCatalogPage(title: 'Jable catalog', url: url);
    onParsed?.call(page);
    return page;
  }

  @override
  void dispose() {
    _testAccount?.dispose();
    _testAccount = null;
    super.dispose();
  }
}

class _TestJableAccount extends ChangeNotifier implements JableAccount {
  _TestJableAccount({
    required this.loggedIn,
    required this.revision,
    this.favorites = const [],
  });

  bool loggedIn;
  final List<VideoItem> favorites;
  @override
  int revision;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  Future<List<VideoItem>> searchFavorites(
    String query, {
    bool Function()? isCurrent,
  }) async => favorites;

  void expireSession() {
    loggedIn = false;
    revision++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<VideoLibrary> _testLibrary() async {
  SharedPreferences.setMockInitialValues({});
  return VideoLibrary(preferences: await SharedPreferences.getInstance());
}

class _EmptyVideoSecureStorage implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) return Future<String?>.value();
    return Future<void>.value();
  }
}

class _TestVideoPlaybackSession implements VideoPlaybackSession {
  final ValueNotifier<VideoPlaybackSnapshot> _snapshot = ValueNotifier(
    const VideoPlaybackSnapshot(),
  );

  @override
  ValueListenable<VideoPlaybackSnapshot> get snapshot => _snapshot;

  @override
  Widget buildSurface({required double aspectRatio}) =>
      const ColoredBox(color: Colors.black);

  @override
  Future<void> loadStream(
    VideoStream stream, {
    required Duration position,
    required double volume,
  }) async {}

  @override
  Future<void> loadFile(
    String path, {
    required Duration position,
    required double volume,
  }) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> selectAudioTrack(String id) async {}

  @override
  Future<void> selectSubtitleTrack(String id) async {}

  @override
  Future<void> dispose() async => _snapshot.dispose();
}

class _TestMissavClient extends MissavClient {
  _TestMissavClient({
    this.catalog,
    this.sourceHomeUrl = 'https://missav.ai/cn',
    this.parsedCatalog,
    this.browseError,
    this.browseStarted,
    this.browseResult,
    this.browseCompleted,
    this.signedOutCatalog,
    this.loggedIn = false,
    this.accountName,
    this.pagesByUrl = const {},
    this.browseHandler,
    this.onBrowseCompleted,
    this.onBrowse,
    this.playlistCoverHandler,
    this.collectionSearchResults = const [],
    this.recommendationHandler,
    this.detailsResult,
  });

  final VideoCatalogPage? catalog;
  final String sourceHomeUrl;
  final VideoCatalogPage? parsedCatalog;
  final Object? browseError;
  final Completer<void>? browseStarted;
  final Completer<VideoCatalogPage>? browseResult;
  final Completer<void>? browseCompleted;
  final VideoCatalogPage? signedOutCatalog;
  final Map<String, VideoCatalogPage> pagesByUrl;
  final Future<VideoCatalogPage> Function(
    String url,
    VideoCatalogPage parsedPage,
  )?
  browseHandler;
  final void Function(String url)? onBrowseCompleted;
  final void Function(String url)? onBrowse;
  final Future<String?> Function(String url, {CancelToken? cancelToken})?
  playlistCoverHandler;
  final List<VideoItem> collectionSearchResults;
  final _RecommendationHandler? recommendationHandler;
  final VideoDetails? detailsResult;
  bool loggedIn;
  int _testSessionGeneration = 0;
  @override
  String? accountName;
  final List<bool> actorFavoriteChanges = [];
  final List<String> playlistCoverRequests = [];
  int clearHistoryCalls = 0;
  int collectionSearchCalls = 0;
  final List<String> browsedUrls = [];
  final recommendationRequests = <({String? cursor, int count})>[];
  bool browseFinished = false;
  String testLocale = 'cn';
  final filterOptionKinds = <VideoSearchFilterKind>[];
  final combinedSearchRequests =
      <({String query, List<VideoLink> filters, bool? current})>[];

  @override
  String get homeUrl => sourceHomeUrl;

  @override
  bool setLocale(String languageTag) {
    testLocale = languageTag.split('-').first;
    return super.setLocale(languageTag);
  }

  @override
  bool get isLoggedIn => loggedIn;

  @override
  int get sessionGeneration => _testSessionGeneration;

  void advanceSessionGeneration() {
    _testSessionGeneration++;
    notifyListeners();
  }

  void confirmAccount(String name) {
    loggedIn = true;
    accountName = name;
    notifyListeners();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<VideoDetails> details(
    VideoItem item, {
    FutureOr<void> Function(VideoDetails)? onReady,
    bool includeAccountState = true,
  }) async {
    final details = detailsResult ?? VideoDetails(video: item);
    await onReady?.call(details);
    return details;
  }

  @override
  Future<VideoCatalogPage> browse(
    String url, {
    CancelToken? cancelToken,
    void Function(VideoCatalogPage page)? onParsed,
  }) async {
    browsedUrls.add(url);
    onBrowse?.call(url);
    if (browseError != null) throw browseError!;
    final parsedPage =
        parsedCatalog ??
        pagesByUrl[url] ??
        signedOutCatalog ??
        catalog ??
        VideoCatalogPage(title: 'Fixture', url: url);
    onParsed?.call(parsedPage);
    if (browseStarted case final started? when !started.isCompleted) {
      started.complete();
    }
    if (browseResult != null) {
      final page = await browseResult!.future;
      browseFinished = true;
      if (browseCompleted case final completed? when !completed.isCompleted) {
        completed.complete();
      }
      return page;
    }
    final handler = browseHandler;
    if (handler != null) {
      final page = await handler(url, parsedPage);
      browseFinished = true;
      onBrowseCompleted?.call(url);
      if (browseCompleted case final completed? when !completed.isCompleted) {
        completed.complete();
      }
      return page;
    }
    final page =
        pagesByUrl[url] ??
        (!loggedIn && signedOutCatalog != null ? signedOutCatalog! : null) ??
        catalog ??
        VideoCatalogPage(title: 'Fixture', url: url);
    browseFinished = true;
    if (browseCompleted case final completed? when !completed.isCompleted) {
      completed.complete();
    }
    return page;
  }

  @override
  Future<String?> loadPlaylistCover(String url, {CancelToken? cancelToken}) {
    playlistCoverRequests.add(url);
    return playlistCoverHandler?.call(url, cancelToken: cancelToken) ??
        Future.value(null);
  }

  @override
  Future<VideoRecommendationPage> loadRecommendations({
    String? cursor,
    required int count,
    CancelToken? cancelToken,
  }) async {
    recommendationRequests.add((cursor: cursor, count: count));
    final handler = recommendationHandler;
    if (handler != null) return handler(cursor, count, cancelToken);
    return const VideoRecommendationPage(videos: [], cursor: null);
  }

  @override
  Future<void> logout() async {
    loggedIn = false;
    accountName = null;
    notifyListeners();
  }

  @override
  Future<void> setActorFavorite(VideoLink actor, bool favorite) async {
    actorFavoriteChanges.add(favorite);
  }

  @override
  Future<void> clearWatchHistory() async {
    clearHistoryCalls++;
  }

  @override
  Future<List<VideoItem>> searchCollection(
    String url,
    String query, {
    bool Function()? isCurrent,
  }) async {
    collectionSearchCalls++;
    return collectionSearchResults
        .where(
          (video) => video.title.toLowerCase().contains(query.toLowerCase()),
        )
        .toList(growable: false);
  }

  @override
  Future<VideoCatalogPage> searchFilterOptions(
    VideoSearchFilterKind kind, {
    String? pageUrl,
  }) async {
    filterOptionKinds.add(kind);
    return const VideoCatalogPage(
      title: 'Genres',
      url: 'https://missav.ai/en/genres',
      links: [
        VideoLink(
          label: 'Drama',
          url: 'https://missav.ai/en/genres/drama',
          kind: VideoLinkKind.category,
        ),
      ],
    );
  }

  @override
  Future<List<VideoItem>> searchWithFilters(
    String query,
    List<VideoLink> filters, {
    bool Function()? isCurrent,
  }) async {
    combinedSearchRequests.add((
      query: query,
      filters: [...filters],
      current: isCurrent?.call(),
    ));
    return [];
  }
}

class _PushObserver extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}

Future<void> _tapNextPage(WidgetTester tester, S l10n) async {
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
  await tester.tap(find.text(l10n.nextPage));
  await tester.pumpAndSettle();
}

Future<PaginationBar> _visiblePaginationBar(WidgetTester tester) async {
  final finder = find.byType(PaginationBar);
  await tester.scrollUntilVisible(
    finder,
    500,
    scrollable: find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  return tester.widget<PaginationBar>(finder);
}

Future<void> _tapPreviousPage(WidgetTester tester, S l10n) async {
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
  await tester.tap(find.text(l10n.previousPage));
  await tester.pumpAndSettle();
}

Future<void> _selectVideoDrawerLabel(
  WidgetTester tester,
  S l10n,
  String label,
) async {
  await tester.tap(find.byKey(const ValueKey('library-menu-button')));
  await tester.pumpAndSettle();
  final drawer = find.byKey(const ValueKey('library-drawer'));
  await _videoDrawerTile(tester, label);
  await tester.tap(find.descendant(of: drawer, matching: find.text(label)));
  await tester.pumpAndSettle();
}

Future<ListTile> _videoDrawerTile(WidgetTester tester, String label) async {
  final drawer = find.byKey(const ValueKey('library-drawer'));
  final labelFinder = find.descendant(of: drawer, matching: find.text(label));
  await tester.scrollUntilVisible(
    labelFinder,
    240,
    scrollable: find
        .descendant(of: drawer, matching: find.byType(Scrollable))
        .first,
  );
  await tester.pumpAndSettle();
  final tileFinder = find.ancestor(
    of: labelFinder,
    matching: find.byType(ListTile),
  );
  return tester.widget<ListTile>(tileFinder);
}

String _playlistCardImageUrl(WidgetTester tester, String playlistUrl) {
  final card = find.byKey(ValueKey('video-playlist-card-$playlistUrl'));
  final image = tester.widget<Image>(
    find.descendant(of: card, matching: find.byType(Image)),
  );
  expect(image.image, isA<NetworkImage>());
  return (image.image as NetworkImage).url;
}

class _TestVideoDownloads extends VideoDownloads {
  _TestVideoDownloads({
    required super.client,
    required super.library,
    List<VideoDownloadTask> tasks = const [],
    this.removeCompleter,
  }) : _tasks = [...tasks];

  final List<VideoDownloadTask> _tasks;
  final Completer<void>? removeCompleter;

  @override
  List<VideoDownloadTask> get tasks => List.unmodifiable(_tasks);

  @override
  Future<void> initialize() async {}

  @override
  Future<void> remove(String videoId) async {
    await removeCompleter?.future;
    _tasks.removeWhere((task) => task.id == videoId);
    notifyListeners();
  }
}

List<VideoItem> _videos(String prefix, int count) => [
  for (var index = 0; index < count; index++)
    VideoItem(
      id: '$prefix-$index',
      title: '$prefix $index',
      pageUrl: 'https://missav.ai/en/$prefix-$index',
    ),
];

class _DeferredVideoCoverHttpClient implements HttpClient {
  _DeferredVideoCoverHttpClient(
    this._body, {
    this.imageRequestStarted,
    required this.contentLength,
    this.statusCode = HttpStatus.ok,
    this.bodyForRequest,
    this.contentLengthForRequest,
    this.statusCodeForRequest,
    this.onRequest,
  });

  final Future<List<int>> _body;
  final Completer<void>? imageRequestStarted;
  final int contentLength;
  final int statusCode;
  final Future<List<int>> Function(int requestCount)? bodyForRequest;
  final int Function(int requestCount)? contentLengthForRequest;
  final int Function(int requestCount)? statusCodeForRequest;
  final void Function(int requestCount)? onRequest;
  int requestCount = 0;

  @override
  bool autoUncompress = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requestCount++;
    if (imageRequestStarted case final started? when !started.isCompleted) {
      started.complete();
    }
    onRequest?.call(requestCount);
    return _DeferredVideoCoverHttpRequest(
      bodyForRequest?.call(requestCount) ?? _body,
      contentLengthForRequest?.call(requestCount) ?? contentLength,
      statusCodeForRequest?.call(requestCount) ?? statusCode,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _DeferredVideoCoverHttpRequest implements HttpClientRequest {
  _DeferredVideoCoverHttpRequest(
    this._body,
    this._contentLength,
    this._statusCode,
  );

  final Future<List<int>> _body;
  final int _contentLength;
  final int _statusCode;

  @override
  final HttpHeaders headers = _VideoCoverHttpHeaders();

  @override
  Future<HttpClientResponse> close() async =>
      _DeferredVideoCoverHttpResponse(_body, _contentLength, _statusCode);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _DeferredVideoCoverHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _DeferredVideoCoverHttpResponse(
    this._body,
    this._contentLength,
    this._statusCode,
  ) : headers = _VideoCoverHttpHeaders({
        HttpHeaders.contentTypeHeader: 'image/png',
        HttpHeaders.contentLengthHeader: _contentLength.toString(),
      });

  final Future<List<int>> _body;
  final int _contentLength;
  final int _statusCode;

  @override
  final HttpHeaders headers;

  @override
  int get contentLength => _contentLength;

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => 'OK';

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  int get statusCode => _statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromFuture(_body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _VideoCoverHttpHeaders implements HttpHeaders {
  _VideoCoverHttpHeaders([Map<String, String> values = const {}])
    : _values = {
        for (final entry in values.entries)
          entry.key.toLowerCase(): <String>[entry.value],
      };

  final Map<String, List<String>> _values;

  @override
  String? value(String name) => _values[name.toLowerCase()]?.join(', ');

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _values.forEach(action);

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

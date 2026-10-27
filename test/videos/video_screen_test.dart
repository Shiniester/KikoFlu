import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_collection_view.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_downloads_screen.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
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
    );
    final library = await _testLibrary();
    final downloads = _TestVideoDownloads(client: client, library: library);

    await tester.pumpWidget(
      _app(client, library, downloads, const VideoScreen()),
    );
    await tester.pumpAndSettle();

    expect(client.browsedUrls, [releaseUrl]);
  });

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
      videos: videos,
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
    await tester.tap(find.text(l10n.videoNewReleases));
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
    expect(find.text('Cached scroll catalog'), findsOneWidget);
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
    expect(find.text('Refreshed scroll catalog'), findsOneWidget);
    expect(scroll.offset, 180);

    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.videoWeeklyHot));
    await tester.pumpAndSettle();
    expect(find.text('Next scroll catalog'), findsOneWidget);
    expect(scroll.offset, 0);
  });

  testWidgets('cached cover retry does not bypass the pending refresh gate', (
    tester,
  ) async {
    const releaseUrl = 'https://missav.ai/cn/release';
    const coverUrl = 'https://missav.ai/images/cached-retry.png';
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
    const refreshedPage = VideoCatalogPage(
      title: 'Refreshed retry catalog',
      url: releaseUrl,
      videos: [video],
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
      expect(find.text('Cached retry catalog'), findsOneWidget);
      expect(find.byTooltip('Retry'), findsOneWidget);
      expect(imageClient.requestCount, 1);

      final l10n = await S.delegate.load(const Locale('en'));
      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.videoNewReleases));
      for (
        var attempt = 0;
        attempt < 10 && !refreshStarted.isCompleted;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(refreshStarted.isCompleted, isTrue);
      await tester.pump();
      expect(find.text('Cached retry catalog'), findsOneWidget);
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
      expect(find.text('Cached retry catalog'), findsOneWidget);
      expect(find.text('Refreshed retry catalog'), findsNothing);

      await tester.runAsync(() async => retryBody.complete(imageBytes));
      for (var attempt = 0; attempt < 10; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.text('Refreshed retry catalog').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.text('Refreshed retry catalog'), findsOneWidget);
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

  testWidgets(
    'playlist entries stay in their collection page and browse in place',
    (tester) async {
      const collectionUrl = 'https://missav.ai/en/playlists';
      const playlistUrl = 'https://missav.ai/en/playlists/123';
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

      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: drawer, matching: find.text('Playlist one')),
        findsNothing,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Playlist one'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.videoRenamePlaylist), findsOneWidget);
      expect(find.text(l10n.videoDeletePlaylist), findsOneWidget);
      await tester.tap(find.text(l10n.videoRenamePlaylist));
      await tester.pumpAndSettle();
      expect(find.text(l10n.videoPlaylistName), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();

      final pushesBeforeSelection = observer.pushes;
      await tester.tap(find.text('Playlist one'));
      await tester.pumpAndSettle();

      expect(find.text('Playlist video'), findsOneWidget);
      expect(client.browsedUrls, contains(playlistUrl));
      expect(observer.pushes, pushesBeforeSelection);
    },
  );

  testWidgets('drawer catalog selection replaces the current page in place', (
    tester,
  ) async {
    const destination = 'https://missav.ai/dm539/cn/new';
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
    expect(find.text('Recently updated page'), findsOneWidget);
    expect(observer.pushes, pushesAfterOpeningDrawer);
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
    await tester.tap(find.text(l10n.videoWeeklyHot));
    await tester.pumpAndSettle();

    expect(changedSession, isTrue);
    expect(client.browsedUrls, [
      'https://missav.ai/cn/release',
      destination,
      destination,
    ]);
    expect(find.text('Weekly hot catalog'), findsOneWidget);
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
    expect(find.text(l10n.videoContent), findsOneWidget);
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
    expect(find.byIcon(Icons.apps), findsOneWidget);
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
    expect(find.byIcon(Icons.grid_view), findsOneWidget);
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
      expect(find.text('Release directory'), findsOneWidget);
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
    expect(find.text('Release directory'), findsOneWidget);

    pageTwo.complete(
      VideoRecommendationPage(
        videos: _videos('stale-recommendation-page-2', 40),
        cursor: null,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Release directory'), findsOneWidget);

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
      await tester.tap(find.byKey(const ValueKey('video-filter-genre')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drama'));
      await tester.pumpAndSettle();
      expect(client.filterOptionKinds, [VideoSearchFilterKind.genre]);
      expect(client.combinedSearchRequests.last.query, isEmpty);
      expect(
        client.combinedSearchRequests.last.filters.single.url,
        'https://missav.ai/en/genres/drama',
      );
      expect(client.combinedSearchRequests.last.current, isTrue);

      await tester.enterText(
        find.byKey(const ValueKey('video-search-input')),
        'keyword',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(client.combinedSearchRequests.last.query, 'keyword');
      expect(client.combinedSearchRequests.last.filters.single.label, 'Drama');
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
    for (final size in [const Size(320, 800), const Size(1280, 800)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        _app(
          client,
          library,
          downloads,
          const VideoDownloadsScreen(),
          textScale: 1.3,
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
      expect(tester.getSize(coverFinder), const Size(112, 84));
      expect(find.text('01:02:03'), findsOneWidget);
      expect(duration.top, greaterThan(title.bottom));
      expect(duration.top, greaterThan(cover.bottom));
      expect(duration.left, closeTo(cover.left, 0.1));
      expect(
        duration.top,
        greaterThan(tester.getRect(find.text('Queued · 720p')).bottom),
      );
      expect(tester.takeException(), isNull, reason: '$size');
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
                    search: (_, _, _) async =>
                        const VideoSearchResults.collection([video]),
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
        expect(client.browsedUrls, contains(tag.url));
        expect(find.text('Genre catalog'), findsOneWidget);
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
    expect(find.text(l10n.videoPasswordOnSource), findsOneWidget);
    expect(find.text(l10n.videoAccountSourceHint), findsOneWidget);
    await tester.tap(find.text(l10n.logout));
    await tester.pumpAndSettle();
    expect(client.isLoggedIn, isFalse);
    expect(browserCleanupCalls, 1);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Private account video'), findsNothing);
    expect(find.text('Signed out'), findsOneWidget);
    expect(
      client.browsedUrls.where((url) => url.endsWith('/favorites')).length,
      2,
    );
  });

  testWidgets('actor favorites remain accessible from their saved collection', (
    tester,
  ) async {
    const actor = VideoLink(
      label: 'Fixture actor',
      url: 'https://missav.ai/cn/actress/fixture',
      kind: VideoLinkKind.actor,
    );
    final client = _TestMissavClient(
      loggedIn: true,
      catalog: const VideoCatalogPage(
        title: 'Source actor directory',
        url: 'https://missav.ai/cn/actresses',
        links: [actor],
      ),
      pagesByUrl: {
        'https://missav.ai/en/saved/actresses': const VideoCatalogPage(
          title: 'Actor favorites',
          url: 'https://missav.ai/en/saved/actresses',
          links: [actor],
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
        const VideoScreen.catalog(url: 'https://missav.ai/cn/actresses'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    final drawer = find.byKey(const ValueKey('library-drawer'));
    expect(
      find.descendant(of: drawer, matching: find.text('Fixture actor')),
      findsNothing,
    );
    expect(find.text('Fixture actor'), findsNothing);
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
    expect(find.text('Fixture actor'), findsOneWidget);
    await tester.tap(find.byTooltip('Fixture actor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.videoFavoriteActor));
    await tester.pumpAndSettle();

    expect(client.actorFavoriteChanges, [true]);
  });

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
  _TestMissavClient client,
  VideoLibrary library,
  VideoDownloads downloads,
  Widget home, {
  double textScale = 1,
  Locale locale = const Locale('en'),
  Future<void> Function()? clearBrowserSession,
  NavigatorObserver? observer,
}) => ProviderScope(
  overrides: [
    videoClientProvider.overrideWith((ref) => client),
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

Future<VideoLibrary> _testLibrary() async {
  SharedPreferences.setMockInitialValues({});
  return VideoLibrary(preferences: await SharedPreferences.getInstance());
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
    this.collectionSearchResults = const [],
    this.recommendationHandler,
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
  final List<VideoItem> collectionSearchResults;
  final _RecommendationHandler? recommendationHandler;
  bool loggedIn;
  int _testSessionGeneration = 0;
  @override
  String? accountName;
  final List<bool> actorFavoriteChanges = [];
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
  await tester.scrollUntilVisible(
    find.descendant(of: drawer, matching: find.text(label)),
    240,
    scrollable: find
        .descendant(of: drawer, matching: find.byType(Scrollable))
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: drawer, matching: find.text(label)));
  await tester.pumpAndSettle();
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

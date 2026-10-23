import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/works_provider.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_collection_view.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_downloads_screen.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_browse_preferences.dart';
import 'package:kikoeru_flutter/src/videos/video_download_task.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';
import 'package:kikoeru_flutter/src/widgets/pagination_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('catalog uses parsed source links while logged out', (
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
    expect(find.text(l10n.videoFavorites), findsOneWidget);
    await tester.tap(find.text(l10n.videoFavorites));
    await tester.pumpAndSettle();

    expect(client.browsedUrls, contains('https://missav.ai/en/saved'));
  });

  testWidgets('playlist entries stay in drawer and browse in place', (
    tester,
  ) async {
    const playlistUrl = 'https://missav.ai/en/playlists/123';
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Playlists',
        url: 'https://missav.ai/en/playlists',
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
        const VideoScreen.catalog(url: 'https://missav.ai/en/playlists'),
        observer: observer,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();

    expect(find.text('Playlist one'), findsOneWidget);
    await tester.tap(find.byTooltip('Playlist one'));
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
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
  });

  testWidgets('drawer catalog selection replaces the current page in place', (
    tester,
  ) async {
    const destination = 'https://missav.ai/cn/genres';
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Home catalog',
        url: 'https://missav.ai/cn',
        navigation: [
          VideoLink(
            label: 'Genres',
            url: destination,
            kind: VideoLinkKind.navigation,
          ),
        ],
      ),
      pagesByUrl: {
        destination: const VideoCatalogPage(
          title: 'Genres page',
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
    await tester.tap(find.text('Genres'));
    await tester.pumpAndSettle();

    expect(client.browsedUrls, contains(destination));
    expect(find.text('Genres page'), findsOneWidget);
    expect(observer.pushes, pushesAfterOpeningDrawer);
  });

  testWidgets('directory links share one content section and layout cycles', (
    tester,
  ) async {
    const exactUrl = 'https://missav.ai/cn/genres';
    final client = _TestMissavClient(
      catalog: const VideoCatalogPage(
        title: 'Home catalog',
        url: 'https://missav.ai/cn',
        navigation: [
          VideoLink(
            label: 'Navigation directory',
            url: exactUrl,
            kind: VideoLinkKind.navigation,
          ),
        ],
        links: [
          VideoLink(
            label: 'Duplicate directory',
            url: exactUrl,
            kind: VideoLinkKind.category,
          ),
          VideoLink(
            label: 'Other locale directory',
            url: 'https://missav.ai/en/genres',
            kind: VideoLinkKind.category,
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

    Future<void> openDrawer() async {
      await tester.tap(find.byKey(const ValueKey('library-menu-button')));
      await tester.pumpAndSettle();
    }

    await openDrawer();
    expect(find.text(l10n.videoContent), findsOneWidget);
    expect(find.text('Navigation directory'), findsOneWidget);
    expect(find.text('Duplicate directory'), findsNothing);
    expect(find.text('Other locale directory'), findsOneWidget);
    await tester.tap(find.text(l10n.layout));
    await tester.pumpAndSettle();
    expect(container.read(videoBrowseLayoutProvider), LayoutType.smallGrid);

    await openDrawer();
    expect(find.byIcon(Icons.apps), findsOneWidget);
    await tester.tap(find.text(l10n.layout));
    await tester.pumpAndSettle();
    expect(container.read(videoBrowseLayoutProvider), LayoutType.list);

    await openDrawer();
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
    final home = AppBottomDockTransitionScope(
      child: Scaffold(
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

  testWidgets('actor navigation exposes source favorite actions', (
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
        title: 'Actors',
        url: 'https://missav.ai/cn/actresses',
        links: [actor],
      ),
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
    await tester.tap(find.byTooltip('Fixture actor'));
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
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
    locale: const Locale('en'),
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
    this.browseError,
    this.signedOutCatalog,
    this.loggedIn = false,
    this.accountName,
    this.pagesByUrl = const {},
    this.collectionSearchResults = const [],
  });

  final VideoCatalogPage? catalog;
  final Object? browseError;
  final VideoCatalogPage? signedOutCatalog;
  final Map<String, VideoCatalogPage> pagesByUrl;
  final List<VideoItem> collectionSearchResults;
  bool loggedIn;
  @override
  String? accountName;
  final List<bool> actorFavoriteChanges = [];
  int clearHistoryCalls = 0;
  int collectionSearchCalls = 0;
  final List<String> browsedUrls = [];

  @override
  String get homeUrl => 'https://missav.ai/cn';

  @override
  bool get isLoggedIn => loggedIn;

  @override
  Future<void> initialize() async {}

  @override
  Future<VideoCatalogPage> browse(String url) async {
    browsedUrls.add(url);
    if (browseError != null) throw browseError!;
    if (pagesByUrl[url] case final page?) return page;
    if (!loggedIn && signedOutCatalog != null) return signedOutCatalog!;
    return catalog ?? VideoCatalogPage(title: 'Fixture', url: url);
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
  final scrollController = tester
      .widget<CustomScrollView>(find.byType(CustomScrollView))
      .controller!;
  scrollController.jumpTo(scrollController.position.maxScrollExtent);
  await tester.pumpAndSettle();
  await tester.tap(find.text(l10n.nextPage));
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

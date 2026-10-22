import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_downloads.dart';
import 'package:kikoeru_flutter/src/videos/video_library.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';

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

    expect(client.browsedUrls, contains('https://missav.ai/cn/favorites'));
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
        clearBrowserSession: () async { browserCleanupCalls++; },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private account video'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('library-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Account A'));
    await tester.pumpAndSettle();
    final l10n = await S.delegate.load(const Locale('en'));
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
    expect(tester.takeException(), isNull);

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
}) => ProviderScope(
  overrides: [
    videoClientProvider.overrideWith((ref) => client),
    videoLibraryProvider.overrideWith((ref) => library),
    videoDownloadsProvider.overrideWith((ref) => downloads),
    videoBrowserSessionCleanupProvider.overrideWithValue(clearBrowserSession ?? () async {}),
    currentTrackProvider.overrideWith((ref) => Stream.value(null)),
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
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
  });

  final VideoCatalogPage? catalog;
  final Object? browseError;
  final VideoCatalogPage? signedOutCatalog;
  bool loggedIn;
  @override
  String? accountName;
  final List<bool> actorFavoriteChanges = [];
  int clearHistoryCalls = 0;
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
}

class _TestVideoDownloads extends VideoDownloads {
  _TestVideoDownloads({required super.client, required super.library});

  @override
  Future<void> initialize() async {}
}

import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/artwork_theme_provider.dart';
import 'package:kikoeru_flutter/src/services/cache_service.dart';
import 'package:kikoeru_flutter/src/services/remote_asset_cache.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/image_blur_util.dart';
import 'package:kikoeru_flutter/src/utils/local_file_url.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Network extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final previousOverrides = HttpOverrides.current;
  late Directory directory;
  late HttpServer server;
  late String host;
  late BaseCacheManager previousCache;
  final requests = <HttpRequest>[];
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  setUpAll(() => HttpOverrides.global = _Network());
  tearDownAll(() => HttpOverrides.global = previousOverrides);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'player-artwork-headers-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    SharedPreferences.setMockInitialValues({'server_cookie': 'session=secret'});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
    previousCache = CachedNetworkImageProvider.defaultCacheManager;
    CachedNetworkImageProvider.defaultCacheManager =
        RemoteAssetImageCacheManager(cache: CacheService.remoteAssetCache);
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      requests.add(request);
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(png);
      await request.response.close();
    });
  });

  tearDown(() async {
    CachedNetworkImageProvider.defaultCacheManager = previousCache;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  void expectJapaneseHeaders(HttpRequest request) {
    expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
    expect(
      request.headers.value(HttpHeaders.refererHeader),
      'https://japaneseasmr.com/',
    );
    expect(request.headers.value('Origin'), 'https://japaneseasmr.com');
  }

  Future<void> pumpCover(WidgetTester tester, Widget cover) =>
      tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Center(child: SizedBox(width: 320, child: cover)),
          ),
        ),
      );

  Future<void> waitForArtwork(WidgetTester tester) async {
    for (var i = 0; i < 500; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null)) {
        return;
      }
    }
    fail('The cold-cache artwork did not decode');
  }

  for (final compact in [true, false]) {
    testWidgets('cold-cache ${compact ? 'compact' : 'full'} JP cover headers', (
      tester,
    ) async {
      final track = AudioTrack(
        id: 'jp-cover',
        title: 'Japanese ASMR',
        url: '$host/audio.m3u8',
        artworkUrl: '$host/jp-cover.png',
        workId: -123,
      );
      await pumpCover(
        tester,
        compact
            ? PlayerCompactArtwork(track: track, url: track.artworkUrl)
            : PlayerCoverWidget(track: track),
      );
      await waitForArtwork(tester);

      expect(requests, hasLength(1));
      expectJapaneseHeaders(requests.single);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('track transition preloads JP artwork with public headers', (
    tester,
  ) async {
    await pumpCover(
      tester,
      const PlayerCoverWidget(
        track: AudioTrack(id: 'initial', title: 'Initial', url: 'initial.wav'),
        animateTrackChanges: true,
      ),
    );
    await pumpCover(
      tester,
      PlayerCoverWidget(
        track: AudioTrack(
          id: 'jp-transition',
          title: 'Japanese ASMR',
          url: '$host/audio.m3u8',
          artworkUrl: '$host/jp-transition.png',
          workId: -124,
        ),
        animateTrackChanges: true,
      ),
    );
    await waitForArtwork(tester);

    expect(requests, hasLength(1));
    expectJapaneseHeaders(requests.single);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('JP theme extraction carries the source through its descriptor', (
    tester,
  ) async {
    final descriptor = resolveArtworkDescriptor(
      track: AudioTrack(
        id: 'jp-theme',
        title: 'Japanese ASMR',
        url: '$host/audio.m3u8',
        artworkUrl: '$host/jp-theme.png',
        workId: -125,
      ),
      host: 'https://asmr.invalid',
      token: 'account-token',
    )!;
    final seed = await tester.runAsync(
      () => ArtworkSeedCache(maxEntries: 1).load(descriptor.seedRequest),
    );

    expect(seed, isA<Color>());
    expect(requests, hasLength(1));
    expectJapaneseHeaders(requests.single);
  });

  testWidgets('system blur isolates JP headers and keeps ASMR cookies', (
    tester,
  ) async {
    for (final workId in [-126, 126]) {
      final blurredUrl = await tester.runAsync(
        () => ImageBlurUtil.blurNetworkImageToFile(
          '$host/blur-$workId.png',
          cacheKey: 'work_cover_$workId',
          workId: workId,
        ),
      );
      expect(blurredUrl, isNotNull);
      expect(File(LocalFileUrl.pathFromUrl(blurredUrl!)!).existsSync(), isTrue);
      if (workId < 0) {
        expectJapaneseHeaders(requests.last);
      } else {
        expect(
          requests.last.headers.value(HttpHeaders.cookieHeader),
          'session=secret',
        );
      }
    }
    expect(requests, hasLength(2));
  });
}

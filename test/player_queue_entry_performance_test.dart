import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:file/local.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> openQueue(WidgetTester tester, List<AudioTrack> tracks) async {
  SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = const Size(1170, 2532);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTrackProvider.overrideWith((ref) => Stream.value(tracks.first)),
        queueProvider.overrideWith((ref) => Stream.value(tracks)),
        isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        playerStateProvider.overrideWith(
          (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
        ),
        positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        manualSkipAvailabilityProvider.overrideWith(
          (ref) => Stream.value(
            const ManualSkipAvailability(
              canSkipNext: true,
              canSkipPrevious: false,
            ),
          ),
        ),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
      ],
      child: const MaterialApp(
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: Scaffold(bottomNavigationBar: MiniPlayer()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('mini-player-queue-button')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    CachedNetworkImageProvider.defaultCacheManager = _CoverCache();
  });
  testWidgets('queue entry only mounts visible rows for 2000 tracks', (
    tester,
  ) async {
    final tracks = List.generate(
      2000,
      (i) => AudioTrack(
        id: 'track-$i',
        title: 'Queue track $i',
        url: 'https://example.invalid/$i.wav',
      ),
    );
    await openQueue(tester, tracks);
    expect(
      find.byType(ReorderableDelayedDragStartListener).evaluate().length,
      inExclusiveRange(0, 40),
    );
    expect(tester.takeException(), isNull);
  });

  for (final remote in [false, true]) {
    testWidgets(
      'eight distinct ${remote ? 'cached remote' : 'local'} queue covers decode at cover resolution',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync('queue-covers-');
        final cache = _CoverCache();
        final previousCache = CachedNetworkImageProvider.defaultCacheManager;
        CachedNetworkImageProvider.defaultCacheManager = cache;
        addTearDown(() {
          CachedNetworkImageProvider.defaultCacheManager = previousCache;
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
          directory.deleteSync(recursive: true);
        });
        final tracks = <AudioTrack>[];
        await tester.runAsync(() async {
          final square = File(
            'assets/icons/app_icon_opaque.png',
          ).readAsBytesSync();
          final wide = File(
            'test/goldens/audio_player_wide_1280x720_light.png',
          ).readAsBytesSync();
          final portrait = File(
            'test/goldens/audio_player_compact_390x844_light.png',
          ).readAsBytesSync();
          final tiny = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          );
          final fixtures = [square, wide, portrait, tiny];
          for (var i = 0; i < 8; i++) {
            final file = File('${directory.path}/cover-$i.png');
            await file.writeAsBytes(fixtures[i % fixtures.length]);
            final remoteUrl = 'https://example.invalid/cover-$i.png';
            cache.files[remoteUrl] = file.path;
            tracks.add(
              AudioTrack(
                id: 'track-$i',
                title: 'Queue track $i',
                url: 'https://example.invalid/$i.wav',
                artworkUrl: remote ? remoteUrl : file.uri.toString(),
              ),
            );
          }
        });
        await openQueue(tester, tracks);
        List<ui.Image> decodedForTrack(int index) => tester
            .widgetList<RawImage>(
              find.descendant(
                of: find.byKey(
                  ValueKey('player-queue-track-content-track-$index'),
                ),
                matching: find.byType(RawImage),
              ),
            )
            .map((raw) => raw.image)
            .whereType<ui.Image>()
            .toList();
        for (var i = 0; i < 150; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          if (List.generate(
            8,
            decodedForTrack,
          ).every((images) => images.isNotEmpty)) {
            break;
          }
        }
        // Finish the network image cross-fade before inspecting visible images.
        await tester.pumpAndSettle();
        const expectedSizes = [
          Size(192, 192),
          Size(256, 144),
          Size(192, 416),
          Size(1, 1),
        ];
        for (var i = 0; i < 8; i++) {
          final decoded = decodedForTrack(i);
          expect(decoded, hasLength(1));
          expect(decoded.single.width, expectedSizes[i % 4].width);
          expect(decoded.single.height, expectedSizes[i % 4].height);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _CoverCache extends Fake implements BaseCacheManager {
  final files = <String, String>{};

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    yield FileInfo(
      const LocalFileSystem().file(files[url]!),
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }
}

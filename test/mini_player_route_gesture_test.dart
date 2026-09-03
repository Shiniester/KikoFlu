import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:kikoeru_flutter/src/widgets/mini_player.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_vertical_gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('shared artwork tween preserves the player cover aspect ratio', () {
    final tween = createPlayerArtworkRectTween(
      const Rect.fromLTWH(16, 16, 64, 48),
      const Rect.fromLTWH(40, 80, 320, 240),
    );

    for (final progress in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final rect = tween.transform(progress)!;
      expect(
        rect.width / rect.height,
        closeTo(PlayerCoverWidget.preferredAspectRatio, 0.0001),
      );
    }
  });

  testWidgets('mini player upward drag opens the canonical player route', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const track = AudioTrack(
      id: 'mini-route-track',
      title: 'Mini route track',
      url: 'https://example.invalid/audio.mp3',
      artist: 'Artist',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(track)),
          isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          durationProvider.overrideWith(
            (ref) => Stream.value(const Duration(minutes: 4)),
          ),
          playerStateProvider.overrideWith(
            (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
          ),
          queueProvider.overrideWith((ref) => Stream.value(const [track])),
          lyricAutoLoaderProvider.overrideWith((ref) {}),
        ],
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            body: Center(child: Text('mini-route-host')),
            bottomNavigationBar: MiniPlayer(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final launcher = find.byKey(const ValueKey('mini-player-upward-launcher'));
    final cancelledGesture = await tester.startGesture(
      tester.getCenter(launcher),
    );
    await cancelledGesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(AudioPlayerScreen, skipOffstage: false), findsOneWidget);
    final openingOffset = tester
        .widget<SlideTransition>(
          find.byKey(
            const ValueKey('player-route-vertical-slide'),
            skipOffstage: false,
          ),
        )
        .position
        .value
        .dy;
    await cancelledGesture.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(
      tester
          .widget<SlideTransition>(
            find.byKey(
              const ValueKey('player-route-vertical-slide'),
              skipOffstage: false,
            ),
          )
          .position
          .value
          .dy,
      greaterThan(openingOffset),
    );
    await cancelledGesture.cancel();
    await tester.pumpAndSettle();
    expect(find.byType(AudioPlayerScreen), findsNothing);
    expect(find.text('mini-route-host'), findsOneWidget);
    expect(find.byType(MiniPlayer, skipOffstage: false), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('mini-player-upward-launcher'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );

    final gesture = await tester.startGesture(tester.getCenter(launcher));
    for (var index = 0; index < 14; index++) {
      await gesture.moveBy(const Offset(0, -16));
      await tester.pump();
      if (index == 1) {
        expect(
          find.byType(AudioPlayerScreen, skipOffstage: false),
          findsOneWidget,
        );
      }
      if (index == 3) {
        expect(
          find.byKey(
            const ValueKey('player-artwork-flight-frame'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        final interactiveSlide = tester.widget<SlideTransition>(
          find.byKey(
            const ValueKey('player-route-vertical-slide'),
            skipOffstage: false,
          ),
        );
        expect(interactiveSlide.position.value.dy, closeTo(1 - 64 / 844, 0.02));
      }
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(AudioPlayerScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('compact-player-layout')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-route-vertical-slide')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mini-player-route-preview-slide')),
      findsNothing,
    );

    await tester.drag(
      find.byKey(const ValueKey('compact-header-dismiss-surface')),
      const Offset(0, 240),
    );
    await tester.pumpAndSettle();
    expect(find.text('mini-route-host'), findsOneWidget);
    expect(find.byType(AudioPlayerScreen), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mini-player-artwork-frame')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      find.byKey(
        const ValueKey('player-artwork-flight-frame'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(find.byType(AudioPlayerScreen), findsOneWidget);
  });

  testWidgets(
    'mini player keeps artwork and controls fixed while title swipes',
    (tester) async {
      SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      const track = AudioTrack(
        id: 'mini-layout-track',
        title: 'Swipe this title',
        url: 'https://example.invalid/layout.mp3',
        artist: 'Artist',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentTrackProvider.overrideWith((ref) => Stream.value(track)),
            isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
            positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
            durationProvider.overrideWith(
              (ref) => Stream.value(const Duration(minutes: 4)),
            ),
            playerStateProvider.overrideWith(
              (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
            ),
            queueProvider.overrideWith((ref) => Stream.value(const [track])),
            lyricAutoLoaderProvider.overrideWith((ref) {}),
          ],
          child: const MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: Center(child: Text('mini-layout-host')),
              bottomNavigationBar: MiniPlayer(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final mini = find.byType(MiniPlayer);
      final artwork = find.byKey(const ValueKey('mini-player-artwork-frame'));
      expect(tester.getSize(artwork), const Size(64, 48));
      final artworkDecoration =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: artwork,
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(artworkDecoration.borderRadius, BorderRadius.circular(10));
      expect(
        find.descendant(of: mini, matching: find.byIcon(Icons.skip_previous)),
        findsNothing,
      );
      expect(
        find.descendant(of: mini, matching: find.byIcon(Icons.skip_next)),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mini-player-queue-button')),
        findsOneWidget,
      );

      final swipeRegion = find.byKey(
        const ValueKey('mini-player-track-swipe-region'),
      );
      final queueButton = find.byKey(
        const ValueKey('mini-player-queue-button'),
      );
      final artworkRect = tester.getRect(artwork);
      final queueRect = tester.getRect(queueButton);
      final gesture = await tester.startGesture(tester.getCenter(swipeRegion));
      await gesture.moveBy(const Offset(-24, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-24, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-24, 0));
      await tester.pump();
      final transform = tester.widget<Transform>(
        find.byKey(const ValueKey('mini-player-track-swipe-transform')),
      );
      expect(transform.transform.storage[12], lessThan(0));
      expect(tester.getRect(artwork), artworkRect);
      expect(tester.getRect(queueButton), queueRect);
      expect(find.byType(AudioPlayerScreen), findsNothing);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(find.text('没有下一首可播放'), findsOneWidget);
      expect(
        tester
            .widget<Transform>(
              find.byKey(const ValueKey('mini-player-track-swipe-transform')),
            )
            .transform
            .storage[12],
        closeTo(0, 0.01),
      );
      await tester.pump(const Duration(seconds: 2));

      final previousGesture = await tester.startGesture(
        tester.getCenter(swipeRegion),
      );
      for (var index = 0; index < 3; index++) {
        await previousGesture.moveBy(const Offset(24, 0));
        await tester.pump();
      }
      expect(
        tester
            .widget<Transform>(
              find.byKey(const ValueKey('mini-player-track-swipe-transform')),
            )
            .transform
            .storage[12],
        greaterThan(0),
      );
      await previousGesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(tester.getRect(artwork), artworkRect);
      expect(tester.getRect(queueButton), queueRect);
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(queueButton);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.byKey(
          const ValueKey('player-artwork-flight-frame'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AudioPlayerScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('player-queue-pane')), findsOneWidget);
      expect(
        tester
            .widget<AudioPlayerScreen>(find.byType(AudioPlayerScreen))
            .initialSurface,
        PlayerInitialSurface.queue,
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('mini-layout-host'), findsOneWidget);
      expect(find.byType(AudioPlayerScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mini artwork retains and cross-fades the cached image', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final tracks = StreamController<AudioTrack?>();
    addTearDown(tracks.close);
    const first = AudioTrack(
      id: 'crossfade-first',
      title: 'First',
      url: 'https://example.invalid/first.mp3',
      artworkUrl: 'https://example.invalid/first.jpg',
    );
    const second = AudioTrack(
      id: 'crossfade-second',
      title: 'Second',
      url: 'https://example.invalid/second.mp3',
      artworkUrl: 'https://example.invalid/second.jpg',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentTrackProvider.overrideWith((ref) => tracks.stream),
          isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          durationProvider.overrideWith(
            (ref) => Stream.value(const Duration(minutes: 4)),
          ),
          playerStateProvider.overrideWith(
            (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
          ),
          queueProvider.overrideWith(
            (ref) => Stream.value(const [first, second]),
          ),
          lyricAutoLoaderProvider.overrideWith((ref) {}),
        ],
        child: const MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: Scaffold(
            bottomNavigationBar: MiniPlayer(enableArtworkHero: false),
          ),
        ),
      ),
    );
    tracks.add(first);
    await tester.pump();
    await tester.pump();
    final firstImage = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(firstImage.imageUrl, first.artworkUrl);
    expect(firstImage.fadeInDuration, const Duration(milliseconds: 220));
    expect(firstImage.fadeOutDuration, const Duration(milliseconds: 220));
    expect(firstImage.fadeInCurve, Curves.easeOutCubic);
    expect(firstImage.fadeOutCurve, Curves.easeOutCubic);
    expect(firstImage.useOldImageOnUrlChange, isTrue);

    tracks.add(second);
    await tester.pump();
    await tester.pump();
    final secondImage = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(secondImage.imageUrl, second.artworkUrl);
    expect(secondImage.fadeInDuration, const Duration(milliseconds: 220));
    expect(secondImage.fadeOutDuration, const Duration(milliseconds: 220));
    expect(secondImage.fadeInCurve, Curves.easeOutCubic);
    expect(secondImage.fadeOutCurve, Curves.easeOutCubic);
    expect(secondImage.useOldImageOnUrlChange, isTrue);
    expect(
      find.byKey(const ValueKey('mini-player-artwork-frame')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    // Let the palette extractor's bounded decode timeout finish in fake time.
    await tester.pump(const Duration(seconds: 9));
  });
}

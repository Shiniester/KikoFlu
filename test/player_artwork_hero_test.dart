import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/widgets/privacy_blur_cover.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = AudioTrack(
  id: 'artwork-track',
  title: 'Artwork track',
  url: 'audio.mp3',
);

void main() {
  testWidgets(
    'compact artwork target for Player Cover Page uses route progress',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlayerArtworkHero(
              trackId: 'artwork-track',
              target: PlayerArtworkFlightTarget.main,
              cornerRadius: PlayerCompactArtwork.cornerRadius,
              child: PlayerCompactArtwork(track: _track, url: null),
            ),
          ),
        ),
      );

      expect(
        tester.getSize(find.byType(PlayerCompactArtwork)),
        const Size(64, 48),
      );
      final hero = tester.widget<Hero>(find.byType(Hero));
      expect(
        hero.tag,
        playerArtworkHeroTag(_track.id, PlayerArtworkFlightTarget.main),
      );
      expect(hero.curve, Curves.linear);
      expect(hero.reverseCurve, Curves.linear);
    },
  );

  test(
    'Player Cover Page artwork holds, chases, then attaches to the page',
    () {
      const source = Rect.fromLTWH(16, 720, 64, 48);
      const target = Rect.fromLTWH(40, 120, 320, 240);
      const viewportHeight = 800.0;
      final tween = createPlayerArtworkRectTween(
        source,
        target,
        viewportHeight: viewportHeight,
      );

      expect(tween.transform(0), source);
      expect(tween.transform(playerArtworkAttachmentStart), source);

      const midpoint =
          (playerArtworkAttachmentStart + playerArtworkAttachmentEnd) / 2;
      final movingMidpointTarget = target.shift(
        const Offset(0, viewportHeight * (1 - midpoint)),
      );
      expect(
        tween.transform(midpoint),
        Rect.lerp(
          source,
          movingMidpointTarget,
          playerArtworkAttachment(midpoint),
        ),
      );

      for (final progress in <double>[playerArtworkAttachmentEnd, 0.9, 1]) {
        expect(
          tween.transform(progress),
          target.shift(Offset(0, viewportHeight * (1 - progress))),
        );
      }

      final reverseTween = createPlayerArtworkRectTween(
        target,
        source,
        viewportHeight: viewportHeight,
        reverse: true,
      );
      for (final visualProgress in <double>[0, 0.2, 0.5, 0.8, 1]) {
        expect(
          reverseTween.transform(1 - visualProgress),
          tween.transform(visualProgress),
        );
      }
    },
  );

  test('Player Cover Page title row fades only during the chase', () {
    expect(playerCoverHeaderOpacity(0), 0);
    expect(playerCoverHeaderOpacity(playerCoverHeaderFadeStart), 0);
    expect(
      playerCoverHeaderOpacity(
        (playerCoverHeaderFadeStart + playerCoverHeaderFadeEnd) / 2,
      ),
      closeTo(0.5, 0.0001),
    );
    expect(playerCoverHeaderOpacity(playerCoverHeaderFadeEnd), 1);
    expect(playerCoverHeaderOpacity(1), 1);
  });

  testWidgets('player artwork flight interpolates 10 to 14 pixel radius', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              PlayerArtworkHero(
                trackId: 'mini',
                target: PlayerArtworkFlightTarget.main,
                cornerRadius: 10,
                child: SizedBox(width: 64, height: 48),
              ),
              PlayerArtworkHero(
                trackId: 'player',
                target: PlayerArtworkFlightTarget.main,
                cornerRadius: 14,
                child: SizedBox(width: 320, height: 240),
              ),
            ],
          ),
        ),
      ),
    );

    final heroes = find.byType(Hero).evaluate().toList(growable: false);
    final from = heroes.first.widget as Hero;
    final to = heroes.last.widget as Hero;

    BorderRadius flightRadius(HeroFlightDirection direction, double progress) {
      final fromContext = direction == HeroFlightDirection.push
          ? heroes.first
          : heroes.last;
      final toContext = direction == HeroFlightDirection.push
          ? heroes.last
          : heroes.first;
      final hero = direction == HeroFlightDirection.push ? from : to;
      final shuttle =
          hero.flightShuttleBuilder!(
                fromContext,
                AlwaysStoppedAnimation<double>(progress),
                direction,
                fromContext,
                toContext,
              )
              as AnimatedBuilder;
      final clip = shuttle.builder(fromContext, shuttle.child) as ClipRRect;
      return clip.borderRadius as BorderRadius;
    }

    expect(
      flightRadius(HeroFlightDirection.push, 0),
      BorderRadius.circular(10),
    );
    expect(
      flightRadius(HeroFlightDirection.push, 0.001),
      BorderRadius.circular(10.004),
    );
    expect(
      flightRadius(HeroFlightDirection.push, 0.5),
      BorderRadius.circular(12),
    );
    expect(
      flightRadius(HeroFlightDirection.push, 0.999),
      BorderRadius.circular(13.996),
    );
    expect(
      flightRadius(HeroFlightDirection.push, 1),
      BorderRadius.circular(14),
    );
    expect(flightRadius(HeroFlightDirection.pop, 1), BorderRadius.circular(14));
    expect(
      flightRadius(HeroFlightDirection.pop, 0.999),
      BorderRadius.circular(13.996),
    );
    expect(
      flightRadius(HeroFlightDirection.pop, 0.5),
      BorderRadius.circular(12),
    );
    expect(
      flightRadius(HeroFlightDirection.pop, 0.001),
      BorderRadius.circular(10.004),
    );
    expect(flightRadius(HeroFlightDirection.pop, 0), BorderRadius.circular(10));
  });

  testWidgets(
    'flight artwork preserves image and privacy behavior without a fixed radius',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const track = AudioTrack(
        id: 'flight-image',
        title: 'Flight image',
        url: 'audio.mp3',
        artworkUrl: 'https://example.invalid/cover.jpg',
        workId: 42,
      );
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: PlayerCompactArtwork(
              track: track,
              url: 'https://example.invalid/cover.jpg',
              forFlight: true,
            ),
          ),
        ),
      );

      final privacyCover = tester.widget<PrivacyBlurCover>(
        find.byType(PrivacyBlurCover),
      );
      expect(privacyCover.borderRadius, isNull);
      expect(find.byType(ClipRRect), findsNothing);
      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(image.cacheKey, 'work_cover_42');
      expect(image.fadeInDuration, const Duration(milliseconds: 220));
      expect(image.fadeOutDuration, const Duration(milliseconds: 220));
      expect(image.useOldImageOnUrlChange, isTrue);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerCompactArtwork)),
      );
      await container
          .read(privacyModeSettingsProvider.notifier)
          .setBlurCoverInApp(true);
      await container
          .read(privacyModeSettingsProvider.notifier)
          .setEnabled(true);
      await tester.pump();

      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(find.byType(ClipRRect), findsNothing);
    },
  );

  testWidgets(
    'Player Cover Page flight leaves corner radius to the Hero frame',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                PlayerArtworkHero(
                  trackId: 'mini-flight-source',
                  target: PlayerArtworkFlightTarget.main,
                  cornerRadius: PlayerCompactArtwork.cornerRadius,
                  child: SizedBox(width: 64, height: 48),
                ),
                SizedBox(
                  width: 320,
                  height: 240,
                  child: PlayerCoverWidget(track: _track),
                ),
              ],
            ),
          ),
        ),
      );

      final heroes = find.byType(Hero).evaluate().toList(growable: false);
      final miniHero = heroes.first.widget as Hero;
      final coverHero = heroes.last.widget as Hero;
      final pushShuttle =
          miniHero.flightShuttleBuilder!(
                heroes.first,
                const AlwaysStoppedAnimation<double>(0),
                HeroFlightDirection.push,
                heroes.first,
                heroes.last,
              )
              as AnimatedBuilder;
      final popShuttle =
          coverHero.flightShuttleBuilder!(
                heroes.last,
                const AlwaysStoppedAnimation<double>(0),
                HeroFlightDirection.pop,
                heroes.last,
                heroes.first,
              )
              as AnimatedBuilder;

      Future<void> expectClipNeutralFlight(Widget flight) async {
        const flightRoot = ValueKey('test-player-artwork-flight');
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: KeyedSubtree(key: flightRoot, child: flight),
            ),
          ),
        );
        final fixedRadiusDecorations = find.descendant(
          of: find.byKey(flightRoot),
          matching: find.byWidgetPredicate((widget) {
            if (widget is! DecoratedBox ||
                widget.decoration is! BoxDecoration) {
              return false;
            }
            final radius = (widget.decoration as BoxDecoration).borderRadius;
            return radius != null && radius != BorderRadius.zero;
          }),
        );
        expect(fixedRadiusDecorations, findsNothing);
      }

      await expectClipNeutralFlight(
        pushShuttle.builder(heroes.first, pushShuttle.child),
      );
      await expectClipNeutralFlight(
        popShuttle.builder(heroes.last, popShuttle.child),
      );
    },
  );

  testWidgets('none target does not create an offscreen Hero', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerArtworkHero(
          trackId: 'hidden',
          target: PlayerArtworkFlightTarget.none,
          cornerRadius: 10,
          child: SizedBox(width: 64, height: 48),
        ),
      ),
    );
    expect(find.byType(Hero), findsNothing);
  });
}

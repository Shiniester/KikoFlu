import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';

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
    final shuttle =
        from.flightShuttleBuilder!(
              heroes.first,
              const AlwaysStoppedAnimation<double>(0.5),
              HeroFlightDirection.push,
              heroes.first,
              heroes.last,
            )
            as AnimatedBuilder;
    final clip = shuttle.builder(heroes.first, shuttle.child) as ClipRRect;
    expect(clip.borderRadius, BorderRadius.circular(12));
  });

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

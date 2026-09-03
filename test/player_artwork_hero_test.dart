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
  testWidgets('compact artwork and queue target share exact geometry', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlayerArtworkHero(
            trackId: 'artwork-track',
            target: PlayerArtworkFlightTarget.queue,
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
      playerArtworkHeroTag(_track.id, PlayerArtworkFlightTarget.queue),
    );
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
    BorderRadius pushRadius(double progress) {
      final shuttle =
          from.flightShuttleBuilder!(
                heroes.first,
                AlwaysStoppedAnimation<double>(progress),
                HeroFlightDirection.push,
                heroes.first,
                heroes.last,
              )
              as AnimatedBuilder;
      final viewport = shuttle.builder(heroes.first, shuttle.child) as ClipRect;
      return (viewport.child! as ClipRRect).borderRadius as BorderRadius;
    }

    BorderRadius popRadius(double routeProgress) {
      final shuttle =
          from.flightShuttleBuilder!(
                heroes.first,
                AlwaysStoppedAnimation<double>(routeProgress),
                HeroFlightDirection.pop,
                heroes.last,
                heroes.first,
              )
              as AnimatedBuilder;
      final viewport = shuttle.builder(heroes.first, shuttle.child) as ClipRect;
      return (viewport.child! as ClipRRect).borderRadius as BorderRadius;
    }

    expect(pushRadius(0), BorderRadius.circular(10));
    expect(pushRadius(0.5), BorderRadius.circular(12));
    expect(pushRadius(1), BorderRadius.circular(14));
    expect(popRadius(1), BorderRadius.circular(14));
    expect(popRadius(0.5), BorderRadius.circular(12));
    expect(popRadius(0), BorderRadius.circular(10));
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

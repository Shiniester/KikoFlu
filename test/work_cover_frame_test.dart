import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';

Widget _testApp(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('renders cover layers inside a hero frame', (tester) async {
    await tester.pumpWidget(
      _testApp(
        const WorkCoverFrame(
          heroTag: 'cover-1',
          isLandscape: false,
          layers: [Center(child: Text('Cover Layer'))],
        ),
      ),
    );

    expect(find.byType(Hero), findsOneWidget);
    expect(find.text('Cover Layer'), findsOneWidget);
    expect(find.text('Subtitle'), findsNothing);
    final roundedClips = find
        .descendant(of: find.byType(Hero), matching: find.byType(ClipRRect))
        .evaluate()
        .map((element) => element.widget as ClipRRect)
        .where((clip) => clip.borderRadius == BorderRadius.circular(12));
    expect(roundedClips, isNotEmpty);
  });

  testWidgets('uses the source cover for the Hero flight', (tester) async {
    await tester.pumpWidget(
      _testApp(
        const WorkCoverFrame(
          heroTag: 'cover-flight',
          isLandscape: false,
          layers: [Center(child: Text('Cover Layer'))],
        ),
      ),
    );

    final hero = tester.widget<Hero>(find.byType(Hero));
    final heroContext = tester.element(find.byType(Hero));
    final shuttle = hero.flightShuttleBuilder!(
      heroContext,
      const AlwaysStoppedAnimation<double>(0),
      HeroFlightDirection.push,
      heroContext,
      heroContext,
    );

    expect(shuttle, isA<AnimatedBuilder>());
    final animatedShuttle = shuttle as AnimatedBuilder;
    final clippedShuttle =
        animatedShuttle.builder(heroContext, animatedShuttle.child)
            as ClipRRect;
    expect(clippedShuttle.borderRadius, BorderRadius.circular(12));
    expect(clippedShuttle.child, isNotNull);
  });

  testWidgets('interpolates compact and detail radii during Hero flight', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        const Row(
          children: [
            WorkCoverHeroFrame(
              heroTag: 'compact',
              cornerRadius: 8,
              child: SizedBox.square(dimension: 80),
            ),
            WorkCoverHeroFrame(
              heroTag: 'detail',
              cornerRadius: 12,
              child: SizedBox.square(dimension: 160),
            ),
          ],
        ),
      ),
    );

    final heroes = find.byType(Hero).evaluate().toList(growable: false);
    final fromHero = heroes.first.widget as Hero;
    final shuttle =
        fromHero.flightShuttleBuilder!(
              heroes.first,
              const AlwaysStoppedAnimation<double>(0.5),
              HeroFlightDirection.push,
              heroes.first,
              heroes.last,
            )
            as AnimatedBuilder;
    final clip = shuttle.builder(heroes.first, shuttle.child) as ClipRRect;
    expect(clip.borderRadius, BorderRadius.circular(10));
  });

  testWidgets('shows subtitle and age badges and handles tap', (tester) async {
    var tapCount = 0;

    await tester.pumpWidget(
      _testApp(
        WorkCoverFrame(
          heroTag: 'cover-2',
          isLandscape: true,
          showSubtitleBadge: true,
          showAgeRating: true,
          age: 'R18',
          onTap: () => tapCount++,
          layers: const [Center(child: Text('Cover Layer'))],
        ),
      ),
    );

    expect(find.text('Subtitle'), findsOneWidget);
    expect(find.byKey(const ValueKey('work-cover-age-badge')), findsOneWidget);

    final ageBadge = tester.getRect(
      find.byKey(const ValueKey('work-cover-age-badge')),
    );
    final subtitleBadge = tester.getRect(
      find.byKey(const ValueKey('work-cover-subtitle-badge')),
    );
    expect(ageBadge.bottom, subtitleBadge.bottom);
    expect(ageBadge.left, lessThan(subtitleBadge.left));

    await tester.tap(find.text('Cover Layer'));

    expect(tapCount, 1);
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_vertical_gestures.dart';

void main() {
  for (final buildFirst in [false, true]) {
    testWidgets(
      'queue can close during frame preparation (built: $buildFirst)',
      (tester) async {
        final navigatorKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: Text('host')),
          ),
        );
        final route = AudioPlayerPageRoute<void>(
          initialDismissVisualMode: PlayerDismissVisualMode.secondary,
          builder: (_) => const Scaffold(body: Text('queue')),
        );
        final result = navigatorKey.currentState!.push<void>(route);
        if (buildFirst) await tester.pump();
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        await result;
        await route.completed;
        expect(find.text('queue'), findsNothing);
        expect(find.text('host'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reduced motion completes queue entry during its first frame', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const Scaffold(body: Text('host')),
      ),
    );
    final route = AudioPlayerPageRoute<void>(
      initialDismissVisualMode: PlayerDismissVisualMode.secondary,
      builder: (_) => const Scaffold(body: Text('queue')),
    );
    unawaited(navigatorKey.currentState!.push<void>(route));
    await tester.pump();
    expect(route.debugTransitionValue, 1);
    await tester.pumpAndSettle();
    expect(route.debugTransitionStatus, AnimationStatus.completed);
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('host'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide queue entry waits for initial layout', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('host')),
      ),
    );
    var builds = 0;
    final route = AudioPlayerPageRoute<void>(
      initialDismissVisualMode: PlayerDismissVisualMode.secondary,
      builder: (_) {
        builds++;
        return const Scaffold(body: Text('queue'));
      },
    );
    unawaited(navigatorKey.currentState!.push<void>(route));
    await tester.pump();
    expect(builds, 1);
    // The next vsync arrives late after the initial page's build/layout work.
    await tester.pump(const Duration(milliseconds: 120));
    expect(route.debugTransitionValue, 0);
    await tester.pump(const Duration(milliseconds: 16));
    expect(route.debugTransitionValue, closeTo(16 / 380, 0.001));
    await tester.pump(const Duration(milliseconds: 364));
    expect(route.debugTransitionValue, 1);
    expect(builds, 1);
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('host'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player route follows, reverses, cancels and completes opening', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('route-host')),
      ),
    );

    final cancelledRoute = AudioPlayerPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('cancelled-player')),
    );
    expect(cancelledRoute.transitionDuration, playerRouteTransitionDuration);
    expect(
      cancelledRoute.reverseTransitionDuration,
      playerRouteTransitionDuration,
    );
    final handoffRoute = AudioPlayerPageRoute<void>(
      skipInitialTransition: true,
      builder: (_) => const SizedBox.shrink(),
    );
    expect(handoffRoute.transitionDuration, Duration.zero);
    expect(
      handoffRoute.reverseTransitionDuration,
      playerRouteTransitionDuration,
    );
    unawaited(navigatorKey.currentState!.push<void>(cancelledRoute));
    expect(cancelledRoute.beginVerticalOpenGesture(), isTrue);
    cancelledRoute.updateVerticalOpenGesture(distance: 160, extent: 800);
    expect(cancelledRoute.debugTransitionValue, closeTo(0.2, 0.001));
    cancelledRoute.updateVerticalOpenGesture(distance: 80, extent: 800);
    expect(cancelledRoute.debugTransitionValue, closeTo(0.1, 0.001));
    final cancelled = cancelledRoute.cancelVerticalOpenGesture();
    await tester.pumpAndSettle();
    await cancelled;
    await tester.pumpAndSettle();
    expect(find.text('route-host'), findsOneWidget);
    expect(find.text('cancelled-player'), findsNothing);

    final route = AudioPlayerPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('interactive-player')),
    );
    unawaited(navigatorKey.currentState!.push<void>(route));
    expect(route.beginVerticalOpenGesture(), isTrue);
    route.updateVerticalOpenGesture(distance: 160, extent: 800);
    route.endVerticalOpenGesture(velocity: -700, extent: 800);
    await tester.pumpAndSettle();
    expect(route.debugTransitionValue, closeTo(1, 0.001));
    expect(find.text('interactive-player'), findsOneWidget);

    route.setDismissVisualMode(PlayerDismissVisualMode.secondary);
    expect(route.debugDismissVisualMode, PlayerDismissVisualMode.secondary);
    expect(
      route.beginVerticalDismissGesture(PlayerDismissVisualMode.secondary),
      isTrue,
    );
    route.updateVerticalDismissGesture(distance: 160, extent: 800);
    await tester.pump();
    expect(route.debugTransitionValue, closeTo(0.8, 0.001));
    expect(route.debugTransitionStatus, AnimationStatus.reverse);
    final translation = tester.widget<Transform>(
      find.byKey(const ValueKey('player-route-vertical-translation')),
    );
    expect(translation.transform.entry(1, 3), closeTo(160, 0.001));
    final heroMode = tester.widget<HeroMode>(
      find.ancestor(
        of: find.byKey(const ValueKey('player-route-vertical-translation')),
        matching: find.byType(HeroMode),
      ),
    );
    expect(heroMode.enabled, isFalse);

    route.updateVerticalDismissGesture(distance: 80, extent: 800);
    expect(route.debugTransitionValue, closeTo(0.9, 0.001));
    route.cancelVerticalDismissGesture();
    await tester.pumpAndSettle();
    expect(route.debugTransitionValue, closeTo(1, 0.001));
    expect(find.text('interactive-player'), findsOneWidget);

    route.setDismissVisualMode(PlayerDismissVisualMode.main);
    await tester.pump();
    expect(
      tester
          .widget<HeroMode>(
            find.ancestor(
              of: find.byKey(
                const ValueKey('player-route-vertical-translation'),
              ),
              matching: find.byType(HeroMode),
            ),
          )
          .enabled,
      isTrue,
    );
    expect(
      route.beginVerticalDismissGesture(PlayerDismissVisualMode.main),
      isTrue,
    );
    route.updateVerticalDismissGesture(distance: 184, extent: 800);
    route.endVerticalDismissGesture(velocity: 0, extent: 800);
    await tester.pumpAndSettle();
    expect(find.text('route-host'), findsOneWidget);
    expect(find.text('interactive-player'), findsNothing);
  });

  testWidgets('standard player route decelerates while opening and closing', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('curve-host')),
      ),
    );

    final route = AudioPlayerPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('curve-player')),
    );
    unawaited(navigatorKey.currentState!.push<void>(route));
    await tester.pump();
    final translationFinder = find.byKey(
      const ValueKey('player-route-vertical-translation'),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      1 -
          tester.widget<Transform>(translationFinder).transform.entry(1, 3) /
              route.debugRouteTranslation,
      closeTo(route.animation!.value, 0.001),
    );
    final firstOpeningDistance =
        1 -
        tester.widget<Transform>(translationFinder).transform.entry(1, 3) /
            route.debugRouteTranslation;
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      1 -
          tester.widget<Transform>(translationFinder).transform.entry(1, 3) /
              route.debugRouteTranslation,
      closeTo(route.animation!.value, 0.001),
    );
    final halfwayOpeningDistance =
        1 -
        tester.widget<Transform>(translationFinder).transform.entry(1, 3) /
            route.debugRouteTranslation;
    expect(
      firstOpeningDistance,
      greaterThan(halfwayOpeningDistance - firstOpeningDistance),
    );

    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      1 -
          tester.widget<Transform>(translationFinder).transform.entry(1, 3) /
              route.debugRouteTranslation,
      closeTo(route.animation!.value, 0.001),
    );
    final firstClosingDistance =
        tester.widget<Transform>(translationFinder).transform.entry(1, 3) /
        route.debugRouteTranslation;
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      1 -
          tester.widget<Transform>(translationFinder).transform.entry(1, 3) /
              route.debugRouteTranslation,
      closeTo(route.animation!.value, 0.001),
    );
    final halfwayClosingDistance =
        tester.widget<Transform>(translationFinder).transform.entry(1, 3) /
        route.debugRouteTranslation;
    expect(
      firstClosingDistance,
      greaterThan(halfwayClosingDistance - firstClosingDistance),
    );
    await tester.pumpAndSettle();
    expect(find.text('curve-player'), findsNothing);
  });

  testWidgets('interactive player route exposes one-to-one visual progress', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('progress-host')),
      ),
    );

    final route = AudioPlayerPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('progress-player')),
    );
    unawaited(navigatorKey.currentState!.push<void>(route));
    await tester.pumpAndSettle();
    expect(
      route.beginVerticalDismissGesture(PlayerDismissVisualMode.main),
      isTrue,
    );

    route.updateVerticalDismissGesture(distance: 8, extent: 800);
    expect(route.debugTransitionValue, closeTo(0.99, 0.001));
    expect(
      route.debugSettleDuration(showRoute: true),
      const Duration(microseconds: 3800),
    );
    route.cancelVerticalDismissGesture();
    await tester.pump(const Duration(milliseconds: 3));
    expect(route.debugTransitionValue, lessThan(1));
    await tester.pump(const Duration(milliseconds: 3));
    expect(route.debugTransitionValue, lessThan(1));
    await tester.pump(const Duration(milliseconds: 2));
    expect(route.debugTransitionValue, closeTo(1, 0.001));
    expect(
      route.beginVerticalDismissGesture(PlayerDismissVisualMode.main),
      isTrue,
    );

    final translationFinder = find.byKey(
      const ValueKey('player-route-vertical-translation'),
    );
    for (final progress in [0.8, 0.5, 0.2]) {
      route.updateVerticalDismissGesture(
        distance: 800 * (1 - progress),
        extent: 800,
      );
      await tester.pump();
      expect(route.debugTransitionValue, closeTo(progress, 0.001));
      expect(route.animation!.value, closeTo(progress, 0.001));
      expect(
        tester.widget<Transform>(translationFinder).transform.entry(1, 3),
        closeTo(800 * (1 - progress), 0.001),
      );
    }

    route.cancelVerticalDismissGesture();
    await tester.pumpAndSettle();
    expect(route.animation!.value, closeTo(1, 0.001));
    expect(find.text('progress-player'), findsOneWidget);
  });

  testWidgets('compact queue entry uses 260ms and retains 380ms dismissal', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
    );
    for (final width in [390.0, 1280.0]) {
      tester.view.physicalSize = Size(width, 844);
      await tester.pump();
      for (final mode in PlayerDismissVisualMode.values) {
        final route = AudioPlayerPageRoute<void>(
          initialDismissVisualMode: mode,
          builder: (_) => const SizedBox.shrink(),
        );
        unawaited(navigatorKey.currentState!.push(route));
        await tester.pumpAndSettle();
        expect(
          route.transitionDuration,
          width == 390 && mode == PlayerDismissVisualMode.secondary
              ? const Duration(milliseconds: 260)
              : playerRouteTransitionDuration,
        );
        expect(route.reverseTransitionDuration, playerRouteTransitionDuration);
        navigatorKey.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 190));
        expect(
          route.debugVisualValue,
          closeTo(Curves.easeInCubic.transform(0.5), 0.001),
        );
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('reduced motion shows the route without translation or Hero', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const Scaffold(body: Text('reduced-host')),
      ),
    );
    final route = AudioPlayerPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('reduced-player')),
    );
    unawaited(navigatorKey.currentState!.push<void>(route));
    await tester.pumpAndSettle();

    final translation = tester.widget<Transform>(
      find.byKey(const ValueKey('player-route-vertical-translation')),
    );
    expect(translation.transform.entry(1, 3), 0);
    final heroMode = tester.widget<HeroMode>(
      find.ancestor(
        of: find.byKey(const ValueKey('player-route-vertical-translation')),
        matching: find.byType(HeroMode),
      ),
    );
    expect(heroMode.enabled, isFalse);
  });
}

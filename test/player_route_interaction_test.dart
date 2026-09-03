import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_vertical_gestures.dart';

void main() {
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
    unawaited(navigatorKey.currentState!.push<void>(cancelledRoute));
    expect(cancelledRoute.beginVerticalOpenGesture(), isTrue);
    cancelledRoute.updateVerticalOpenGesture(distance: 160, extent: 800);
    expect(cancelledRoute.debugTransitionValue, closeTo(0.2, 0.001));
    cancelledRoute.updateVerticalOpenGesture(distance: 80, extent: 800);
    expect(cancelledRoute.debugTransitionValue, closeTo(0.1, 0.001));
    cancelledRoute.cancelVerticalOpenGesture();
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
    final slide = tester.widget<SlideTransition>(
      find.byKey(const ValueKey('player-route-vertical-slide')),
    );
    expect(slide.position.value.dy, closeTo(0.2, 0.001));
    final heroMode = tester.widget<HeroMode>(
      find.ancestor(
        of: find.byKey(const ValueKey('player-route-vertical-slide')),
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
              of: find.byKey(const ValueKey('player-route-vertical-slide')),
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
}

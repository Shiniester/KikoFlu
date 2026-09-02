import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';

void main() {
  testWidgets('player route follows, reverses, cancels and completes drags', (
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

    final route = AudioPlayerPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('interactive-player')),
    );
    unawaited(navigatorKey.currentState!.push<void>(route));
    expect(route.beginVerticalOpenGesture(), isTrue);
    route.updateVerticalOpenGesture(distance: 160, extent: 800);
    expect(route.debugTransitionValue, closeTo(0.2, 0.001));
    route.updateVerticalOpenGesture(distance: 80, extent: 800);
    expect(route.debugTransitionValue, closeTo(0.1, 0.001));
    route.endVerticalOpenGesture(velocity: -700, extent: 800);
    await tester.pumpAndSettle();
    expect(route.debugTransitionValue, closeTo(1, 0.001));
    expect(find.text('interactive-player'), findsOneWidget);

    expect(route.beginVerticalDismissGesture(), isTrue);
    route.updateVerticalDismissGesture(distance: 200, extent: 800);
    expect(route.debugTransitionValue, closeTo(0.75, 0.001));
    route.updateVerticalDismissGesture(distance: 80, extent: 800);
    expect(route.debugTransitionValue, closeTo(0.9, 0.001));
    route.cancelVerticalDismissGesture();
    await tester.pumpAndSettle();
    expect(route.debugTransitionValue, closeTo(1, 0.001));

    expect(route.beginVerticalDismissGesture(), isTrue);
    route.updateVerticalDismissGesture(distance: 200, extent: 800);
    route.endVerticalDismissGesture(velocity: 0, extent: 800);
    await tester.pumpAndSettle();
    expect(find.text('route-host'), findsOneWidget);
    expect(find.text('interactive-player'), findsNothing);
  });
}

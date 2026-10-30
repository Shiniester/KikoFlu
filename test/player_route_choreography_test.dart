import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_vertical_gestures.dart';

const _viewportSize = Size(400, 800);
const _queueArtworkRect = Rect.fromLTWH(24, 112, 64, 48);

void main() {
  for (final complete in [false, true]) {
    testWidgets('reduced motion preserves interactive open result $complete', (
      tester,
    ) async {
      final navigatorKey = await _pumpHost(tester);
      final route = AudioPlayerPageRoute<void>(
        builder: (_) => const _PlayerPageFixture(),
      );
      unawaited(navigatorKey.currentState!.push<void>(route));
      expect(route.beginVerticalOpenGesture(), isTrue);
      await tester.pump();
      await tester.pump();
      route.updateVerticalOpenGesture(distance: 320, extent: 800);
      final result = complete
          ? route.endVerticalOpenGesture(velocity: 0, extent: 800)
          : route.cancelVerticalOpenGesture();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(route.verticalGestureInProgress, isTrue);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      await tester.pump();
      expect(await result, complete);
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);
      expect(
        find.byType(_PlayerPageFixture),
        complete ? findsOneWidget : findsNothing,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final popping in [false, true]) {
    testWidgets(
      'reduced motion completes active route ${popping ? 'pop' : 'push'}',
      (tester) async {
        final navigatorKey = await _pumpHost(tester);
        final route = AudioPlayerPageRoute<void>(
          builder: (_) => const _PlayerPageFixture(),
        );
        unawaited(navigatorKey.currentState!.push<void>(route));
        await tester.pump();
        if (popping) {
          await tester.pumpAndSettle();
          navigatorKey.currentState!.pop();
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 80));

        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pump();
        await tester.pump();
        if (popping) {
          expect(find.byType(_PlayerPageFixture), findsNothing);
        } else {
          expect(route.debugTransitionValue, 1);
          expect(route.debugTransitionStatus, AnimationStatus.completed);
          expect(_routeTranslation(tester), 0);
        }
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Player Queue Page artwork remains fixed in the page during push and pop',
    (tester) async {
      final navigatorKey = await _pumpHost(tester);
      final route = AudioPlayerPageRoute<void>(
        initialDismissVisualMode: PlayerDismissVisualMode.secondary,
        builder: (_) => const _QueuePageFixture(),
      );

      unawaited(navigatorKey.currentState!.push<void>(route));
      await tester.pump();
      await tester.pump();
      expect(find.byType(Hero, skipOffstage: false), findsNothing);

      for (final progress in <double>[0.2, 0.5, 0.8]) {
        final actualProgress = await _setAutomaticVisualProgress(
          tester,
          route,
          progress,
          reverse: false,
          forwardCurve: Curves.fastEaseInToSlowEaseOut,
        );
        _expectQueueArtworkAttachedToPage(tester, actualProgress);
      }

      route.debugContinueForward();
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pump();

      for (final progress in <double>[0.8, 0.5, 0.2]) {
        final actualProgress = await _setAutomaticVisualProgress(
          tester,
          route,
          progress,
          reverse: true,
        );
        _expectQueueArtworkAttachedToPage(tester, actualProgress);
      }

      route.debugContinueReverse();
      await tester.pumpAndSettle();
      expect(find.byType(_QueuePageFixture), findsNothing);
    },
  );
}

Future<GlobalKey<NavigatorState>> _pumpHost(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _viewportSize;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Center(child: Text('player-route-host'))),
    ),
  );
  return navigatorKey;
}

Future<double> _setAutomaticVisualProgress(
  WidgetTester tester,
  AudioPlayerPageRoute<void> route,
  double visualProgress, {
  required bool reverse,
  Curve forwardCurve = Curves.easeOutCubic,
}) async {
  final curve = reverse ? Curves.easeInCubic : forwardCurve;
  route.debugSetControllerValue(_invertCurve(curve, visualProgress));
  await tester.pump();
  expect(route.debugVisualValue, closeTo(visualProgress, 0.003));
  return route.debugVisualValue;
}

double _invertCurve(Curve curve, double target) {
  var low = 0.0;
  var high = 1.0;
  for (var index = 0; index < 30; index++) {
    final midpoint = (low + high) / 2;
    if (curve.transform(midpoint) < target) {
      low = midpoint;
    } else {
      high = midpoint;
    }
  }
  return (low + high) / 2;
}

void _expectQueueArtworkAttachedToPage(WidgetTester tester, double progress) {
  expect(find.byType(Hero, skipOffstage: false), findsNothing);
  final artworkRect = tester.getRect(
    find.byKey(const ValueKey('queue-artwork-content')),
  );
  final pageTranslation = _routeTranslation(tester);
  expect(pageTranslation, closeTo(_viewportSize.height * (1 - progress), 1));
  expect(artworkRect, _queueArtworkRect.shift(Offset(0, pageTranslation)));
}

double _routeTranslation(WidgetTester tester) => tester
    .getTopLeft(find.byKey(const ValueKey('player-route-vertical-translation')))
    .dy;

class _PlayerPageFixture extends StatelessWidget {
  const _PlayerPageFixture();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: ColoredBox(color: Colors.red));
  }
}

class _QueuePageFixture extends StatelessWidget {
  const _QueuePageFixture();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Stack(
        children: [
          Positioned(
            left: 24,
            top: 112,
            width: 64,
            height: 48,
            child: ColoredBox(
              key: ValueKey('queue-artwork-content'),
              color: Colors.red,
            ),
          ),
        ],
      ),
    );
  }
}

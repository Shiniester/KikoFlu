import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_cover_widget.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_vertical_gestures.dart';

const _viewportSize = Size(400, 800);
const _miniArtworkRect = Rect.fromLTWH(16, 700, 64, 48);
const _coverArtworkRect = Rect.fromLTWH(40, 120, 320, 240);
const _queueArtworkRect = Rect.fromLTWH(24, 112, 64, 48);

void main() {
  testWidgets(
    'Player Cover Page Hero follows the staged path for automatic push and pop',
    (tester) async {
      final navigatorKey = await _pumpHost(tester, withCoverHero: true);
      final route = AudioPlayerPageRoute<void>(
        builder: (_) => const _CoverPageFixture(),
      );

      unawaited(navigatorKey.currentState!.push<void>(route));
      await tester.pump();
      await tester.pump();

      for (final progress in <double>[0.2, 0.5, 0.8]) {
        final actualProgress = await _setAutomaticVisualProgress(
          tester,
          route,
          progress,
          reverse: false,
        );
        _expectCoverArtworkAtProgress(tester, actualProgress);
      }

      route.debugContinueForward();
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump();

      for (final progress in <double>[0.8, 0.5, 0.2]) {
        final actualProgress = await _setAutomaticVisualProgress(
          tester,
          route,
          progress,
          reverse: true,
        );
        _expectCoverArtworkAtProgress(tester, actualProgress);
      }

      route.debugContinueReverse();
      await tester.pumpAndSettle();
      expect(find.byType(_CoverPageFixture), findsNothing);
    },
  );

  testWidgets(
    'Player Cover Page Hero follows raw drag progress and the same rebound path',
    (tester) async {
      final navigatorKey = await _pumpHost(tester, withCoverHero: true);
      final route = AudioPlayerPageRoute<void>(
        builder: (_) => const _CoverPageFixture(),
      );

      unawaited(navigatorKey.currentState!.push<void>(route));
      expect(route.beginVerticalOpenGesture(), isTrue);
      await tester.pump();
      await tester.pump();

      for (final progress in <double>[0.2, 0.5, 0.8]) {
        route.updateVerticalOpenGesture(
          distance: _viewportSize.height * progress,
          extent: _viewportSize.height,
        );
        await tester.pump();
        expect(route.debugVisualValue, closeTo(progress, 0.001));
        _expectCoverArtworkAtProgress(tester, progress);
      }

      final opened = route.endVerticalOpenGesture(
        velocity: 0,
        extent: _viewportSize.height,
      );
      await tester.pumpAndSettle();
      expect(await opened, isTrue);

      expect(
        route.beginVerticalDismissGesture(PlayerDismissVisualMode.main),
        isTrue,
      );
      await tester.pump();
      for (final progress in <double>[0.8, 0.5, 0.2, 0.5]) {
        route.updateVerticalDismissGesture(
          distance: _viewportSize.height * (1 - progress),
          extent: _viewportSize.height,
        );
        await tester.pump();
        expect(route.debugVisualValue, closeTo(progress, 0.001));
        _expectCoverArtworkAtProgress(tester, progress);
      }

      route.cancelVerticalDismissGesture();
      await tester.pump(const Duration(milliseconds: 125));
      _expectCoverArtworkAtProgress(tester, route.debugVisualValue);
      await tester.pumpAndSettle();
      expect(find.byType(_CoverPageFixture), findsOneWidget);
    },
  );

  testWidgets(
    'Player Queue Page artwork remains fixed in the page during push and pop',
    (tester) async {
      final navigatorKey = await _pumpHost(tester, withCoverHero: false);
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

Future<GlobalKey<NavigatorState>> _pumpHost(
  WidgetTester tester, {
  required bool withCoverHero,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _viewportSize;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fromRect(
              rect: _miniArtworkRect,
              child: withCoverHero
                  ? const PlayerArtworkHero(
                      trackId: 'route-artwork',
                      target: PlayerArtworkFlightTarget.main,
                      cornerRadius: 10,
                      child: ColoredBox(
                        key: ValueKey('mini-artwork-content'),
                        color: Colors.blue,
                      ),
                    )
                  : const ColoredBox(color: Colors.blue),
            ),
          ],
        ),
      ),
    ),
  );
  return navigatorKey;
}

Future<double> _setAutomaticVisualProgress(
  WidgetTester tester,
  AudioPlayerPageRoute<void> route,
  double visualProgress, {
  required bool reverse,
}) async {
  final curve = reverse ? Curves.easeInCubic : Curves.easeOutCubic;
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

void _expectCoverArtworkAtProgress(WidgetTester tester, double progress) {
  final artworkRect = tester.getRect(
    find.byKey(const ValueKey('cover-artwork-content')),
  );
  final expected = createPlayerArtworkRectTween(
    _miniArtworkRect,
    _coverArtworkRect,
    viewportHeight: _viewportSize.height,
  ).transform(progress)!;
  _expectRectClose(artworkRect, expected);

  final pageTranslation = _routeTranslation(tester);
  expect(pageTranslation, closeTo(_viewportSize.height * (1 - progress), 1));
  expect(artworkRect.top, greaterThanOrEqualTo(pageTranslation - 1));
  expect(
    artworkRect.bottom,
    lessThanOrEqualTo(pageTranslation + _viewportSize.height + 1),
  );

  final flightFrame = tester.widget<ClipRRect>(
    find.byKey(
      const ValueKey('player-artwork-flight-frame'),
      skipOffstage: false,
    ),
  );
  final radius = flightFrame.borderRadius as BorderRadius;
  final expectedRadius = 10 + (4 * progress);
  expect(radius.topLeft.x, closeTo(expectedRadius, 0.01));
  expect(radius.topRight.x, closeTo(expectedRadius, 0.01));
  expect(radius.bottomLeft.x, closeTo(expectedRadius, 0.01));
  expect(radius.bottomRight.x, closeTo(expectedRadius, 0.01));
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
    .widget<Transform>(
      find.byKey(const ValueKey('player-route-vertical-translation')),
    )
    .transform
    .entry(1, 3);

void _expectRectClose(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 1));
  expect(actual.top, closeTo(expected.top, 1));
  expect(actual.width, closeTo(expected.width, 1));
  expect(actual.height, closeTo(expected.height, 1));
}

class _CoverPageFixture extends StatelessWidget {
  const _CoverPageFixture();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Stack(
        children: [
          Positioned(
            left: 40,
            top: 120,
            width: 320,
            height: 240,
            child: PlayerArtworkHero(
              trackId: 'route-artwork',
              target: PlayerArtworkFlightTarget.main,
              cornerRadius: 14,
              isPlayerPageTarget: true,
              child: ColoredBox(
                key: ValueKey('cover-artwork-content'),
                color: Colors.red,
              ),
            ),
          ),
        ],
      ),
    );
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

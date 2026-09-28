import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_cover_frame.dart';

const _root = ValueKey('root');
const _page = ValueKey('page');

Future<GlobalKey<NavigatorState>> _app(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  bool reduced = false,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: AppTheme.lightTheme(null).copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: const Scaffold(key: _root, body: SizedBox.expand()),
    ),
  );
  return navigator;
}

MaterialPageRoute<void> _push(GlobalKey<NavigatorState> navigator, Key key) {
  final route = MaterialPageRoute<void>(
    builder: (_) => Scaffold(key: key, body: const SizedBox.expand()),
  );
  navigator.currentState!.push(route);
  return route;
}

double _x(WidgetTester tester, Key key) =>
    tester.getTopLeft(find.byKey(key, skipOffstage: false)).dx;

Future<void> _backEvent(
  WidgetTester tester,
  String method, [
  double? progress,
]) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
  'flutter/backgesture',
  const StandardMethodCodec().encodeMethodCall(
    MethodCall(
      method,
      progress == null
          ? null
          : <String, dynamic>{
              'touchOffset': <double>[5, 300],
              'progress': progress,
              'swipeEdge': 0,
            },
    ),
  ),
  (_) {},
);

void main() {
  testWidgets('300ms push and pop move only the top page with ease', (
    tester,
  ) async {
    final navigator = await _app(tester);
    final route = _push(navigator, _page);
    await tester.pump();
    expect(route.transitionDuration, const Duration(milliseconds: 300));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 300));
    await tester.pump();
    expect(_x(tester, _page), 800);
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      _x(tester, _page),
      closeTo(800 * (1 - Curves.ease.transform(.5)), .01),
    );
    expect(_x(tester, _root), 0);
    await tester.pumpAndSettle();
    expect(_x(tester, _page), 0);
    const next = ValueKey('next');
    _push(navigator, next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_x(tester, _page), 0);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      _x(tester, next),
      closeTo(800 * (1 - Curves.ease.transform(.5)), .01),
    );
    expect(_x(tester, _page), 0);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(_root), findsOneWidget);
  });

  testWidgets(
    'Android platform back gesture cancels and commits without a jump',
    (tester) async {
      final navigator = await _app(tester);
      _push(navigator, _page);
      await tester.pumpAndSettle();
      for (final commit in [false, true]) {
        await _backEvent(tester, 'startBackGesture', 0);
        await _backEvent(tester, 'updateBackGestureProgress', .4);
        await tester.pump();
        expect(navigator.currentState!.userGestureInProgress, isTrue);
        expect(_x(tester, _page), closeTo(320, .01));
        expect(_x(tester, _root), 0);
        await _backEvent(
          tester,
          commit ? 'commitBackGesture' : 'cancelBackGesture',
        );
        await tester.pump();
        expect(_x(tester, _page), closeTo(320, .01));
        await tester.pumpAndSettle();
        expect(navigator.currentState!.userGestureInProgress, isFalse);
        expect(find.byKey(_page), commit ? findsNothing : findsOneWidget);
      }
    },
  );

  testWidgets('iOS edge drag can cancel and complete', (tester) async {
    final navigator = await _app(tester, platform: TargetPlatform.iOS);
    _push(navigator, _page);
    await tester.pumpAndSettle();
    for (final distance in [100.0, 600.0]) {
      final gesture = await tester.startGesture(const Offset(1, 300));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(Offset(distance, 0));
      await tester.pump();
      expect(_x(tester, _page), closeTo(distance + 30, .01));
      expect(_x(tester, _root), 0);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pump();
      expect(_x(tester, _page), closeTo(distance + 30, .01));
      await tester.pumpAndSettle();
      expect(find.byKey(_page), distance > 400 ? findsNothing : findsOneWidget);
      expect(navigator.currentState!.userGestureInProgress, isFalse);
    }
  });

  for (final useTabs in [false, true]) {
    testWidgets(
      'iOS edge swipe takes priority over ${useTabs ? 'TabBarView' : 'PageView'}',
      (tester) async {
        final navigator = await _app(tester, platform: TargetPlatform.iOS);
        const pages = [
          ColoredBox(color: Colors.red),
          ColoredBox(color: Colors.blue),
        ];
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              key: _page,
              body: useTabs
                  ? const DefaultTabController(
                      length: 2,
                      child: TabBarView(children: pages),
                    )
                  : PageView(children: pages),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byKey(_page),
            matching: find.byType(Scrollable),
          ),
        );

        // Away from the edge, horizontal drags still turn the content page.
        await tester.dragFrom(const Offset(600, 300), const Offset(-500, 0));
        await tester.pumpAndSettle();
        expect(scrollable.position.pixels, closeTo(800, .01));
        expect(_x(tester, _page), 0);
        expect(navigator.currentState!.userGestureInProgress, isFalse);

        for (final distance in [100.0, 600.0]) {
          final gesture = await tester.startGesture(const Offset(1, 300));
          await gesture.moveBy(const Offset(30, 0));
          await tester.pump();
          final startX = _x(tester, _page);
          await gesture.moveBy(Offset(distance, 0));
          await tester.pump();
          expect(navigator.currentState!.userGestureInProgress, isTrue);
          expect(_x(tester, _page), closeTo(startX + distance, .01));
          expect(_x(tester, _root), 0);
          expect(scrollable.position.pixels, closeTo(800, .01));
          await tester.pump(const Duration(milliseconds: 100));
          await gesture.up();
          await tester.pump();
          expect(_x(tester, _page), closeTo(startX + distance, .01));
          await tester.pumpAndSettle();
          expect(
            find.byKey(_page),
            distance > 400 ? findsNothing : findsOneWidget,
          );
          expect(navigator.currentState!.userGestureInProgress, isFalse);
        }
      },
    );
  }

  testWidgets('reduced motion has no page displacement', (tester) async {
    final navigator = await _app(tester, reduced: true);
    final route = _push(navigator, _page);
    await tester.pump();
    expect(_x(tester, _page), 0);
    await tester.pump();
    expect(_x(tester, _page), 0);
    expect(route.animation!.status, AnimationStatus.completed);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_page), findsNothing);
  });

  testWidgets('cover Hero flies independently of the page translation', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    const artwork = ValueKey('flying-artwork');
    Widget cover(double size) => WorkCoverHeroFrame(
      heroTag: 'work',
      flightChild: const ColoredBox(key: artwork, color: Colors.red),
      child: SizedBox.square(dimension: size),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.lightTheme(null),
        home: Scaffold(
          body: Align(alignment: Alignment.topLeft, child: cover(80)),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: Center(child: cover(200))),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final rect = tester.getRect(find.byKey(artwork));
    expect(rect.left, inExclusiveRange(0, 300));
    expect(rect.top, inExclusiveRange(0, 200));
    expect(rect.width, inExclusiveRange(80, 200));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final reverse = tester.getRect(find.byKey(artwork));
    expect(reverse.left, inExclusiveRange(0, 300));
    expect(reverse.width, inExclusiveRange(80, 200));
    await tester.pumpAndSettle();
  });
}

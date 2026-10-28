import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock.dart';
import 'package:kikoeru_flutter/src/widgets/app_bottom_dock_transition.dart';

const _sourceMini = ValueKey('source-mini');
const _targetMini = ValueKey('target-mini');
const _sourceDock = ValueKey('source-dock');

void _configurePhone(WidgetTester tester, {double bottomInset = 0}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.padding = FakeViewPadding(bottom: bottomInset);
  tester.view.viewPadding = FakeViewPadding(bottom: bottomInset);
  addTearDown(tester.view.reset);
}

Widget _detail({String name = 'Details', Key miniKey = _targetMini}) =>
    Scaffold(
      appBar: AppBar(title: Text(name)),
      body: Column(
        children: [
          const Expanded(child: SizedBox()),
          SizedBox(key: miniKey, height: 72, width: double.infinity),
        ],
      ),
    );

Future<BuildContext> _pumpHome(
  WidgetTester tester, {
  required GlobalKey<NavigatorState> navigator,
  bool withTrack = true,
  bool reduceMotion = false,
}) async {
  late BuildContext sourceContext;
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: AppTheme.lightTheme(null),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            sourceContext = context;
            return const Center(child: Text('Home'));
          },
        ),
        bottomNavigationBar: AppBottomDock(
          key: _sourceDock,
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          miniPlayer: withTrack
              ? const SizedBox(key: _sourceMini, height: 72)
              : null,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home), label: 'Audio'),
            NavigationDestination(icon: Icon(Icons.menu_book), label: 'Comics'),
          ],
        ),
      ),
    ),
  );
  return sourceContext;
}

void main() {
  for (final bottomInset in [0.0, 34.0]) {
    for (final withTrack in [false, true]) {
      testWidgets(
        'Dock stays at its page bottom during push and return (inset=$bottomInset, track=$withTrack)',
        (tester) async {
          _configurePhone(tester, bottomInset: bottomInset);
          final navigator = GlobalKey<NavigatorState>();
          final context = await _pumpHome(
            tester,
            navigator: navigator,
            withTrack: withTrack,
          );
          final sourceRect = tester.getRect(find.byKey(_sourceDock));
          final miniRect = withTrack
              ? tester.getRect(find.byKey(_sourceMini))
              : null;
          var returned = false;
          unawaited(
            pushWorkDetailRoute(
              context,
              builder: (_) => _detail(),
            ).then((_) => returned = true),
          );
          await tester.pump();
          for (var sample = 0; sample < 3; sample++) {
            await tester.pump(const Duration(milliseconds: 80));
            expect(tester.getRect(find.byKey(_sourceDock)).top, sourceRect.top);
            if (miniRect != null) {
              expect(tester.getRect(find.byKey(_sourceMini)).top, miniRect.top);
            }
            expect(tester.getRect(find.byKey(_targetMini)).bottom, 844);
            expect(returned, isFalse);
          }
          await tester.pumpAndSettle();
          navigator.currentState!.pop();
          await tester.pump();
          for (var sample = 0; sample < 3; sample++) {
            await tester.pump(const Duration(milliseconds: 80));
            expect(tester.getRect(find.byKey(_sourceDock)).top, sourceRect.top);
            expect(tester.getRect(find.byKey(_targetMini)).bottom, 844);
            expect(returned, isFalse);
          }
          await tester.pumpAndSettle();
          expect(tester.getRect(find.byKey(_sourceDock)), sourceRect);
          expect(returned, isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('reduced motion uses the same static bottom layouts', (
    tester,
  ) async {
    _configurePhone(tester, bottomInset: 34);
    final navigator = GlobalKey<NavigatorState>();
    final context = await _pumpHome(
      tester,
      navigator: navigator,
      reduceMotion: true,
    );
    final sourceRect = tester.getRect(find.byKey(_sourceDock));
    unawaited(pushBottomDockRoute(context, builder: (_) => _detail()));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_targetMini)).bottom, 844);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_sourceDock)), sourceRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'iOS back swipe keeps both page bottoms fixed when cancelled',
    (tester) async {
      _configurePhone(tester, bottomInset: 34);
      final navigator = GlobalKey<NavigatorState>();
      final context = await _pumpHome(tester, navigator: navigator);
      final sourceRect = tester.getRect(find.byKey(_sourceDock));
      unawaited(pushBottomDockRoute(context, builder: (_) => _detail()));
      await tester.pumpAndSettle();
      final targetRect = tester.getRect(find.byKey(_targetMini));
      final gesture = await tester.startGesture(const Offset(2, 400));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      expect(navigator.currentState!.userGestureInProgress, isTrue);
      expect(tester.getRect(find.byKey(_sourceDock)).top, sourceRect.top);
      expect(tester.getRect(find.byKey(_targetMini)).top, targetRect.top);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(find.text('Details'), findsOneWidget);
      expect(tester.getRect(find.byKey(_targetMini)), targetRect);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(_sourceDock)), sourceRect);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('nested pages keep independent Mini Player layouts', (
    tester,
  ) async {
    _configurePhone(tester);
    final navigator = GlobalKey<NavigatorState>();
    final context = await _pumpHome(tester, navigator: navigator);
    unawaited(pushBottomDockRoute(context, builder: (_) => _detail()));
    await tester.pumpAndSettle();
    const nestedMini = ValueKey('nested-mini');
    unawaited(
      pushBottomDockRoute(
        tester.element(find.text('Details')),
        builder: (_) => _detail(name: 'Nested', miniKey: nestedMini),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getRect(find.byKey(_targetMini)).bottom, 844);
    expect(tester.getRect(find.byKey(nestedMini)).bottom, 844);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    expect(tester.getRect(find.byKey(_targetMini)).bottom, 844);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated entry only pushes while the source route is current', (
    tester,
  ) async {
    _configurePhone(tester);
    final navigator = GlobalKey<NavigatorState>();
    final context = await _pumpHome(tester, navigator: navigator);
    unawaited(pushBottomDockRoute(context, builder: (_) => _detail()));
    unawaited(
      pushBottomDockRoute(context, builder: (_) => _detail(name: 'Duplicate')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('Duplicate', skipOffstage: false), findsNothing);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/cupertino.dart'
    show
        CupertinoPageTransition,
        CupertinoFullscreenDialogTransition,
        CupertinoPageTransitionsBuilder;
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
  PageTransitionsTheme? transitions,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: AppTheme.lightTheme(
        null,
      ).copyWith(platform: platform, pageTransitionsTheme: transitions),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: Scaffold(
        key: _root,
        body: Semantics(label: 'root content', child: const SizedBox.expand()),
      ),
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

SnapshotController _snapshotController(WidgetTester tester, Key key) {
  final snapshot = find.ancestor(
    of: find.byKey(key, skipOffstage: false),
    matching: find.byType(SnapshotWidget, skipOffstage: false),
  );
  return tester.widget<SnapshotWidget>(snapshot.first).controller;
}

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
  testWidgets('return during entry follows stock Cupertino without a jump', (
    tester,
  ) async {
    for (final entryMilliseconds in [200, 320, 360, 392]) {
      Future<List<double>> sample({required bool stock}) async {
        await tester.pumpWidget(const SizedBox.shrink());
        final navigator = await _app(
          tester,
          transitions: stock
              ? const PageTransitionsTheme(
                  builders: {
                    TargetPlatform.android: CupertinoPageTransitionsBuilder(),
                  },
                )
              : null,
        );
        final route = _push(navigator, _page);
        await tester.pump();
        await tester.pump(Duration(milliseconds: entryMilliseconds));
        expect(route.animation!.status, AnimationStatus.forward);
        final beforePop = _x(tester, _page);
        navigator.currentState!.pop();
        await tester.pump();
        expect(_x(tester, _page), closeTo(beforePop, .01));
        final positions = <double>[beforePop, _x(tester, _root)];
        for (var elapsed = 30; elapsed < entryMilliseconds; elapsed += 30) {
          await tester.pump(const Duration(milliseconds: 30));
          positions.addAll([_x(tester, _page), _x(tester, _root)]);
        }
        await tester.pumpAndSettle();
        expect(find.byKey(_page), findsNothing);
        return positions;
      }

      final stock = await sample(stock: true);
      final wrapped = await sample(stock: false);
      for (var i = 0; i < stock.length; i++) {
        expect(
          wrapped[i],
          closeTo(stock[i], .01),
          reason: 'return at ${entryMilliseconds}ms, position sample $i',
        );
      }
      if (entryMilliseconds >= 320) {
        final firstTravel = stock[2] - stock[0];
        final secondTravel = stock[4] - stock[2];
        expect(firstTravel, lessThan(secondTravel));
      }
    }
  });

  testWidgets('snapshot wrapper preserves default Cupertino motion', (
    tester,
  ) async {
    Future<List<double>> sample({required bool stock}) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final navigator = await _app(
        tester,
        transitions: stock
            ? const PageTransitionsTheme(
                builders: {
                  TargetPlatform.android: CupertinoPageTransitionsBuilder(),
                },
              )
            : null,
      );
      final positions = <double>[];
      Future<void> record(List<int> intervals) async {
        for (final milliseconds in intervals) {
          await tester.pump(Duration(milliseconds: milliseconds));
          positions.addAll([_x(tester, _page), _x(tester, _root)]);
        }
      }

      _push(navigator, _page);
      await tester.pump();
      await record([50, 50, 150, 150, 90]);
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pump();
      await record([50, 50, 150, 150, 90]);
      await tester.pumpAndSettle();

      _push(navigator, _page);
      await tester.pumpAndSettle();
      for (final distance in [100.0, 600.0]) {
        final gesture = await tester.startGesture(const Offset(1, 300));
        await gesture.moveBy(const Offset(30, 0));
        await tester.pump();
        await gesture.moveBy(Offset(distance, 0));
        await tester.pump(const Duration(milliseconds: 100));
        await gesture.up();
        await tester.pump();
        await record([50, 50, 75, 125, 40]);
        expect(navigator.currentState!.userGestureInProgress, isTrue);
        await tester.pump(const Duration(milliseconds: 11));
        expect(navigator.currentState!.userGestureInProgress, isFalse);
        await tester.pumpAndSettle();
        expect(
          find.byKey(_page),
          distance > 400 ? findsNothing : findsOneWidget,
        );
      }
      return positions;
    }

    final stock = await sample(stock: true);
    final wrapped = await sample(stock: false);
    expect(wrapped, hasLength(stock.length));
    for (var i = 0; i < stock.length; i++) {
      expect(wrapped[i], closeTo(stock[i], .01), reason: 'position sample $i');
    }
  });

  testWidgets('page translation reuses static layout and paint', (
    tester,
  ) async {
    final navigator = await _app(tester);
    var builds = 0;
    var layouts = 0;
    var paints = 0;
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Builder(
          builder: (_) {
            builds++;
            return LayoutBuilder(
              builder: (_, __) {
                layouts++;
                return CustomPaint(
                  painter: _PaintProbe(() => paints++),
                  child: const SizedBox.expand(),
                );
              },
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final initial = (builds, layouts, paints);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect((builds, layouts, paints), initial);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final returning = (builds, layouts, paints);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect((builds, layouts, paints), returning);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Cupertino shadow stays attached to the clipped page during push and pop',
    (tester) async {
      final navigator = await _app(tester);
      _push(navigator, _page);

      void expectEdge() {
        final page = find.byKey(_page);
        final pageRect = tester.getRect(page);
        final transition = find.ancestor(
          of: page,
          matching: find.byType(CupertinoPageTransition),
        );
        final shadow = find.descendant(
          of: transition.first,
          matching: find.byType(DecoratedBoxTransition),
        );
        expect(shadow, findsOneWidget);
        expect(tester.getRect(shadow), pageRect);
        final pageClip = find.ancestor(
          of: page,
          matching: find.byType(ClipRect),
        );
        expect(tester.getRect(pageClip.first), pageRect);
      }

      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expectEdge();
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expectEdge();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('default Cupertino push and pop include secondary parallax', (
    tester,
  ) async {
    final navigator = await _app(tester);
    final route = _push(navigator, _page);
    await tester.pump();
    const defaults = CupertinoPageTransitionsBuilder();
    expect(route.transitionDuration, defaults.transitionDuration);
    expect(route.reverseTransitionDuration, defaults.reverseTransitionDuration);
    await tester.pump();
    expect(_x(tester, _page), 800);
    await tester.pump(route.transitionDuration ~/ 2);
    expect(
      _x(tester, _page),
      closeTo(800 * (1 - Curves.fastEaseInToSlowEaseOut.transform(.5)), .01),
    );
    expect(
      _x(tester, _root),
      closeTo(-800 / 3 * Curves.linearToEaseOut.transform(.5), .01),
    );
    await tester.pumpAndSettle();
    expect(_x(tester, _page), 0);
    const next = ValueKey('next');
    _push(navigator, next);
    await tester.pump();
    await tester.pump(route.transitionDuration ~/ 2);
    expect(
      _x(tester, _page),
      closeTo(-800 / 3 * Curves.linearToEaseOut.transform(.5), .01),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(route.reverseTransitionDuration ~/ 2);
    expect(
      _x(tester, next),
      closeTo(
        800 * (1 - Curves.fastEaseInToSlowEaseOut.flipped.transform(.5)),
        .01,
      ),
    );
    expect(
      _x(tester, _page),
      closeTo(-800 / 3 * Curves.easeInToLinear.transform(.5), .01),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(_root), findsOneWidget);
  });

  testWidgets('Android snapshots a moving page and releases it when settled', (
    tester,
  ) async {
    final navigator = await _app(tester);
    await tester.pump();
    final route = _push(navigator, _page);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final controller = _snapshotController(tester, _page);
    expect(route.animation!.status, AnimationStatus.forward);
    expect(controller.allowSnapshotting, isTrue);
    expect(
      tester
          .widget<SnapshotWidget>(
            find
                .ancestor(
                  of: find.byKey(_page, skipOffstage: false),
                  matching: find.byType(SnapshotWidget, skipOffstage: false),
                )
                .first,
          )
          .mode,
      SnapshotMode.permissive,
    );

    await tester.pumpAndSettle();
    expect(controller.allowSnapshotting, isFalse);

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(route.animation!.status, AnimationStatus.reverse);
    expect(controller.allowSnapshotting, isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(_page), findsNothing);
  });

  testWidgets(
    'snapshots follow secondary motion but skip dialogs and opt-outs',
    (tester) async {
      final navigator = await _app(tester);
      await tester.pump();
      final first = _push(navigator, _page);
      await tester.pumpAndSettle();
      final firstController = _snapshotController(tester, _page);

      const next = ValueKey('next-page');
      final second = _push(navigator, next);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(first.secondaryAnimation!.status, AnimationStatus.forward);
      expect(firstController.allowSnapshotting, isTrue);
      await tester.pumpAndSettle();
      expect(firstController.allowSnapshotting, isTrue);
      expect(_snapshotController(tester, next).allowSnapshotting, isFalse);

      navigator.currentState!.push<void>(
        DialogRoute<void>(
          context: navigator.currentState!.context,
          builder: (_) => const AlertDialog(content: Text('dialog content')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(_snapshotController(tester, next).allowSnapshotting, isFalse);
      final dialogSnapshot = find.ancestor(
        of: find.text('dialog content'),
        matching: find.byType(SnapshotWidget),
      );
      expect(dialogSnapshot, findsNothing);
      await tester.pumpAndSettle();

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      second.navigator!.pop();
      await tester.pumpAndSettle();
      expect(firstController.allowSnapshotting, isFalse);

      const noSnapshotKey = ValueKey('snapshot-opt-out');
      final noSnapshotRoute = MaterialPageRoute<void>(
        allowSnapshotting: false,
        builder: (_) =>
            const Scaffold(key: noSnapshotKey, body: SizedBox.expand()),
      );
      navigator.currentState!.push(noSnapshotRoute);
      await tester.pump();
      expect(
        _snapshotController(tester, noSnapshotKey).allowSnapshotting,
        isFalse,
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets('covered background snapshot is reused through the return', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var paints = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.lightTheme(null),
        home: Scaffold(
          key: _root,
          body: CustomPaint(
            painter: _PaintProbe(() => paints++),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    final controller = _snapshotController(tester, _root);
    _push(navigator, _page);
    await tester.pumpAndSettle();
    expect(controller.allowSnapshotting, isTrue);
    final capturedPaints = paints;

    // A covered page can receive content updates while its image is retained.
    tester
        .renderObject(
          find.byWidgetPredicate(
            (widget) => widget is CustomPaint && widget.painter is _PaintProbe,
            skipOffstage: false,
          ),
        )
        .markNeedsPaint();

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(controller.allowSnapshotting, isTrue);
    expect(paints, capturedPaints);
    await tester.pumpAndSettle();
    expect(controller.allowSnapshotting, isFalse);
    expect(paints, greaterThan(capturedPaints));
  });

  testWidgets('non-Android routes keep live child rendering', (tester) async {
    final navigator = await _app(tester, platform: TargetPlatform.iOS);
    await tester.pump();
    _push(navigator, _page);
    await tester.pump();
    expect(_snapshotController(tester, _page).allowSnapshotting, isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('page semantics return after the final moving frame', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final navigator = await _app(tester);
    await tester.pump();
    final route = MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: Semantics(
          label: 'detail content',
          child: const SizedBox.expand(),
        ),
      ),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.bySemanticsLabel('detail content'), findsNothing);
    await tester.pump(
      route.transitionDuration - const Duration(milliseconds: 150),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(route.animation!.status, AnimationStatus.completed);
    expect(find.bySemanticsLabel('detail content'), findsNothing);
    await tester.pump();
    expect(find.bySemanticsLabel('detail content'), findsOneWidget);
    final rootExclusion = find.ancestor(
      of: find.byKey(_root, skipOffstage: false),
      matching: find.byType(ExcludeSemantics, skipOffstage: false),
    );
    await _backEvent(tester, 'startBackGesture', 0);
    await _backEvent(tester, 'updateBackGestureProgress', .4);
    await tester.pump();
    expect(route.popGestureInProgress, isTrue);
    final excluded = find.ancestor(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'detail content',
      ),
      matching: find.byType(ExcludeSemantics),
    );
    expect(tester.widget<ExcludeSemantics>(excluded.first).excluding, isTrue);
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isTrue,
    );
    await _backEvent(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(tester.widget<ExcludeSemantics>(excluded.first).excluding, isFalse);
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isTrue,
    );
    expect(find.bySemanticsLabel('detail content'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('covered page semantics stay excluded through push and pop', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final navigator = await _app(tester);
    await tester.pump();
    final rootExclusion = find.ancestor(
      of: find.byKey(_root, skipOffstage: false),
      matching: find.byType(ExcludeSemantics, skipOffstage: false),
    );
    final route = _push(navigator, _page);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(route.animation!.status, AnimationStatus.forward);
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isTrue,
    );

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isFalse,
    );
    expect(find.bySemanticsLabel('root content'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('a dialog leaves the completed page semantics unchanged', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final navigator = await _app(tester);
    await tester.pump();
    final rootExclusion = find.ancestor(
      of: find.byKey(_root, skipOffstage: false),
      matching: find.byType(ExcludeSemantics, skipOffstage: false),
    );
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isFalse,
    );

    navigator.currentState!.push<void>(
      DialogRoute<void>(
        context: navigator.currentState!.context,
        builder: (_) => const AlertDialog(content: Text('dialog content')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<ExcludeSemantics>(rootExclusion.first).excluding,
      isFalse,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
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
        expect(_x(tester, _root), closeTo(-160, .01));
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
      final startX = _x(tester, _page);
      await gesture.moveBy(Offset(distance, 0));
      await tester.pump();
      expect(_x(tester, _page), closeTo(startX + distance, .01));
      expect(
        _x(tester, _root),
        closeTo(-800 / 3 * (1 - (startX + distance) / 800), .01),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pump();
      expect(_x(tester, _page), closeTo(startX + distance, .01));
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
          expect(
            _x(tester, _root),
            closeTo(-800 / 3 * (1 - (startX + distance) / 800), .01),
          );
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
    expect(_x(tester, _root), 0);
    await tester.pump();
    expect(_x(tester, _page), 0);
    expect(route.animation!.status, AnimationStatus.completed);
    expect(_snapshotController(tester, _page).allowSnapshotting, isFalse);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_page), findsNothing);
  });

  testWidgets('fullscreen dialogs use the Cupertino vertical transition', (
    tester,
  ) async {
    final navigator = await _app(tester);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const Scaffold(key: _page, body: SizedBox.expand()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(CupertinoFullscreenDialogTransition), findsOneWidget);
    expect(_x(tester, _page), 0);
    expect(tester.getTopLeft(find.byKey(_page)).dy, greaterThan(0));
    expect(_x(tester, _root), 0);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(_page), findsNothing);
  });

  testWidgets('cover moves with the page without a Hero on push and pop', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    const source = ValueKey('source-cover');
    const target = ValueKey('target-cover');
    Widget cover(Key key, double size) => WorkCoverClip(
      child: SizedBox.square(key: key, dimension: size),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.lightTheme(null),
        home: Scaffold(
          key: _root,
          body: Align(alignment: Alignment.topLeft, child: cover(source, 80)),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          key: _page,
          body: Center(child: cover(target, 200)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    void expectCoverAttached() {
      expect(find.byType(Hero), findsNothing);
      final rect = tester.getRect(find.byKey(target));
      expect(rect.left, closeTo(300 + _x(tester, _page), .01));
      expect(rect.top, 200);
      expect(rect.width, closeTo(200, .01));
      expect(rect.height, closeTo(200, .01));
      final sourceRect = tester.getRect(find.byKey(source));
      expect(sourceRect.left, closeTo(_x(tester, _root), .01));
      expect(sourceRect.top, 0);
      expect(sourceRect.width, closeTo(80, .01));
      expect(sourceRect.height, closeTo(80, .01));
    }

    expectCoverAttached();
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expectCoverAttached();
    await tester.pumpAndSettle();
    expect(find.byKey(target), findsNothing);
  });
}

class _PaintProbe extends CustomPainter {
  _PaintProbe(this.onPaint);
  final VoidCallback onPaint;
  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(covariant _PaintProbe oldDelegate) => false;
}

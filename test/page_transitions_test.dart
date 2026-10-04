import 'dart:ui' as ui;

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

Finder _exposedPageClip(Key sourcePage) => find.ancestor(
  of: find.byKey(sourcePage, skipOffstage: false),
  matching: find.byWidgetPredicate(
    (widget) => widget is ClipRect && widget.clipper != null,
    skipOffstage: false,
  ),
);

void _expectExposedPageClipTracks(
  WidgetTester tester,
  Key sourcePage,
  Key foregroundPage,
) {
  final exposedClip = _exposedPageClip(sourcePage);
  expect(exposedClip, findsOneWidget);
  final clipWidget = tester.widget<ClipRect>(exposedClip);
  final clipBounds = tester.getRect(exposedClip);
  final clip = clipWidget.clipper!.getClip(clipBounds.size);
  final foregroundBounds = tester.getRect(
    find.byKey(foregroundPage, skipOffstage: false),
  );
  final isRtl =
      Directionality.of(tester.element(exposedClip)) == TextDirection.rtl;
  final viewportEdge = isRtl
      ? foregroundBounds.right.clamp(clipBounds.left, clipBounds.right)
      : foregroundBounds.left.clamp(clipBounds.left, clipBounds.right);
  expect(
    clipBounds.left + (isRtl ? clip.left : clip.right),
    closeTo(viewportEdge, .01),
    reason: '$sourcePage clip edge should meet $foregroundPage',
  );
}

void _expectExposedPageClipWidth(
  WidgetTester tester,
  Key sourcePage,
  double expectedWidth,
) {
  final exposedClip = _exposedPageClip(sourcePage);
  expect(exposedClip, findsOneWidget);
  final clipWidget = tester.widget<ClipRect>(exposedClip);
  final clipBounds = tester.getRect(exposedClip);
  expect(
    clipWidget.clipper!.getClip(clipBounds.size).width,
    closeTo(expectedWidth, .01),
  );
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
  testWidgets('source parallax does not allocate a full-screen raster', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1170, 2532);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final navigator = await _app(tester);
    await tester.pumpAndSettle();

    var rasters = 0;
    final onCreate = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      onCreate?.call(image);
      if (image.width == 1170 && image.height == 2532) rasters++;
    };
    addTearDown(() => ui.Image.onCreate = onCreate);

    _push(navigator, _page);
    await tester.pump();
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(rasters, 1, reason: 'Only the foreground page needs a raster.');
    final beforePop = rasters;
    navigator.currentState!.pop();
    await tester.pump();
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(rasters - beforePop, 1);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'page translation reuses static layout and paint on $platform',
      (tester) async {
        final navigator = await _app(tester, platform: platform);
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
        _push(navigator, const ValueKey('covering-page'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final covered = (builds, layouts, paints);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect((builds, layouts, paints), covered);
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final revealed = (builds, layouts, paints);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect((builds, layouts, paints), revealed);
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
      },
    );
  }

  testWidgets('page shadow stays on the exposed edge during push and pop', (
    tester,
  ) async {
    final navigator = await _app(tester);
    _push(navigator, _page);

    void expectEdge() {
      final page = find.byKey(_page);
      final pageRect = tester.getRect(page);
      final translation = find.ancestor(
        of: page,
        matching: find.byType(FractionalTranslation),
      );
      final shadow = find.descendant(
        of: translation.first,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is PhysicalModel &&
              widget.color == Colors.transparent &&
              widget.elevation == 6,
        ),
      );
      expect(shadow, findsOneWidget);
      expect(
        tester.getRect(shadow),
        Rect.fromLTWH(pageRect.left, pageRect.top, 24, pageRect.height),
      );
      final pageClip = find.ancestor(of: page, matching: find.byType(ClipRect));
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
  });

  testWidgets('300ms ease push and pop include one third source parallax', (
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
    expect(route.animation!.value, closeTo(.5, .01));
    expect(
      _x(tester, _page),
      closeTo(800 * (1 - Curves.ease.transform(route.animation!.value)), .01),
    );
    expect(
      _x(tester, _root),
      closeTo(-800 / 3 * Curves.ease.transform(route.animation!.value), .01),
    );
    _expectExposedPageClipTracks(tester, _root, _page);
    await tester.pumpAndSettle();
    expect(_x(tester, _page), 0);

    const next = ValueKey('next');
    final nextRoute = _push(navigator, next);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(nextRoute.transitionDuration, const Duration(milliseconds: 300));
    expect(
      _x(tester, next),
      closeTo(800 * (1 - Curves.ease.transform(.5)), .01),
    );
    expect(
      _x(tester, _page),
      closeTo(-800 / 3 * Curves.ease.transform(.5), .01),
    );
    expect(_x(tester, _root), closeTo(-800 / 3, .01));
    _expectExposedPageClipTracks(tester, _root, _page);
    _expectExposedPageClipTracks(tester, _page, next);
    await tester.pumpAndSettle();

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      _x(tester, next),
      closeTo(800 * (1 - Curves.ease.transform(.5)), .01),
    );
    expect(
      _x(tester, _page),
      closeTo(-800 / 3 * Curves.ease.transform(.5), .01),
    );
    expect(_x(tester, _root), closeTo(-800 / 3, .01));
    _expectExposedPageClipTracks(tester, _page, next);
    await tester.pumpAndSettle();

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      _x(tester, _page),
      closeTo(800 * (1 - Curves.ease.transform(.5)), .01),
    );
    expect(
      _x(tester, _root),
      closeTo(-800 / 3 * Curves.ease.transform(.5), .01),
    );
    _expectExposedPageClipTracks(tester, _root, _page);
    await tester.pumpAndSettle();
    expect(find.byKey(_root), findsOneWidget);
  });

  testWidgets('source clip meets the foreground through stacked push and pop', (
    tester,
  ) async {
    final navigator = await _app(tester);
    const middle = ValueKey('middle');
    const top = ValueKey('top');

    _push(navigator, _page);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    _expectExposedPageClipTracks(tester, _root, _page);
    await tester.pumpAndSettle();
    _expectExposedPageClipWidth(tester, _root, 0);

    _push(navigator, middle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    _expectExposedPageClipTracks(tester, _page, middle);
    await tester.pumpAndSettle();

    _push(navigator, top);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    _expectExposedPageClipTracks(tester, _root, _page);
    _expectExposedPageClipTracks(tester, _page, middle);
    _expectExposedPageClipTracks(tester, middle, top);

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    _expectExposedPageClipTracks(tester, _page, middle);
    await tester.pumpAndSettle();
    _expectExposedPageClipWidth(tester, _page, 0);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    _expectExposedPageClipWidth(tester, _root, 0);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    _expectExposedPageClipWidth(tester, _root, 800);
  });

  testWidgets('source clip follows the foreground when entry reverses early', (
    tester,
  ) async {
    final navigator = await _app(tester);
    _push(navigator, _page);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    _expectExposedPageClipTracks(tester, _root, _page);
    final beforePop = _x(tester, _page);

    navigator.currentState!.pop();
    await tester.pump();
    expect(_x(tester, _page), closeTo(beforePop, .01));
    _expectExposedPageClipTracks(tester, _root, _page);
    await tester.pump(const Duration(milliseconds: 40));
    _expectExposedPageClipTracks(tester, _root, _page);
    await tester.pumpAndSettle();
    _expectExposedPageClipWidth(tester, _root, 800);
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
    'source pages retain paint layers while dialogs and opt-outs skip snapshots',
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
      expect(firstController.allowSnapshotting, isFalse);
      await tester.pumpAndSettle();
      expect(firstController.allowSnapshotting, isFalse);
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

  testWidgets('covered source paints changed content once on return', (
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
    expect(controller.allowSnapshotting, isFalse);
    final capturedPaints = paints;

    // A covered page can receive content updates while its layer is retained.
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
    expect(controller.allowSnapshotting, isFalse);
    expect(paints, capturedPaints + 1);
    await tester.pump(const Duration(milliseconds: 50));
    expect(paints, capturedPaints + 1);
    await tester.pumpAndSettle();
    expect(controller.allowSnapshotting, isFalse);
    expect(paints, capturedPaints + 1);
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
        expect(_x(tester, _root), closeTo(-800 / 3 * .6, .01));
        _expectExposedPageClipTracks(tester, _root, _page);
        await _backEvent(
          tester,
          commit ? 'commitBackGesture' : 'cancelBackGesture',
        );
        await tester.pump();
        expect(_x(tester, _page), closeTo(320, .01));
        _expectExposedPageClipTracks(tester, _root, _page);
        await tester.pump(const Duration(milliseconds: 100));
        _expectExposedPageClipTracks(tester, _root, _page);
        await tester.pumpAndSettle();
        expect(navigator.currentState!.userGestureInProgress, isFalse);
        expect(find.byKey(_page), commit ? findsNothing : findsOneWidget);
        _expectExposedPageClipWidth(tester, _root, commit ? 800 : 0);
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
      expect(_x(tester, _root), closeTo(-(800 - _x(tester, _page)) / 3, .01));
      _expectExposedPageClipTracks(tester, _root, _page);
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
            closeTo(-(800 - _x(tester, _page)) / 3, .01),
          );
          _expectExposedPageClipTracks(tester, _root, _page);
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

  testWidgets('fullscreen dialogs use the horizontal app transition', (
    tester,
  ) async {
    final navigator = await _app(tester);
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => const Scaffold(key: _page, body: SizedBox.expand()),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(route.transitionDuration, const Duration(milliseconds: 300));
    expect(
      _x(tester, _page),
      closeTo(800 * (1 - Curves.ease.transform(.5)), .01),
    );
    expect(tester.getTopLeft(find.byKey(_page)).dy, 0);
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

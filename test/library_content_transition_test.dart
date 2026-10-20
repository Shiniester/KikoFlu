import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/library_content_transition.dart';

void main() {
  Future<void> pumpContent(
    WidgetTester tester,
    GlobalKey<LibraryContentTransitionState> transition,
    GlobalKey content,
    ValueNotifier<Color> color,
    ValueNotifier<bool> reduced,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: reduced,
          builder: (context, reduceMotion, _) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: Scaffold(
              body: LibraryContentTransition(
                key: transition,
                child: ValueListenableBuilder<Color>(
                  valueListenable: color,
                  builder: (context, value, _) => StatefulBuilder(
                    key: content,
                    builder: (context, _) => ColoredBox(color: value),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shared content slides both ways with its old pixels and state', (
    tester,
  ) async {
    final transition = GlobalKey<LibraryContentTransitionState>();
    final content = GlobalKey();
    final color = ValueNotifier(Colors.red);
    final reduced = ValueNotifier(false);
    addTearDown(color.dispose);
    addTearDown(reduced.dispose);
    await pumpContent(tester, transition, content, color, reduced);
    final state = tester.state(find.byKey(content));
    final width = tester.getSize(find.byKey(transition)).width;

    transition.currentState!.animate(() => color.value = Colors.green);
    await tester.pump();
    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    final pixels = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    expect(pixels!.getUint8(0), 244);
    expect(pixels.getUint8(1), 67);
    expect(pixels.getUint8(2), 54);
    expect(tester.getTopLeft(find.byKey(content)).dx, width);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.getTopLeft(find.byKey(content)).dx,
      inExclusiveRange(0, width),
    );
    expect(tester.getTopLeft(find.byType(RawImage)).dx, lessThan(0));
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsNothing);
    expect(tester.state(find.byKey(content)), same(state));

    transition.currentState!.animate(
      () => color.value = Colors.red,
      reverse: true,
    );
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(content)).dx, -width);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.getTopLeft(find.byKey(content)).dx,
      inExclusiveRange(-width, 0),
    );
    await tester.pumpAndSettle();
    expect(tester.state(find.byKey(content)), same(state));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid changes and disposal release outgoing frames safely', (
    tester,
  ) async {
    final transition = GlobalKey<LibraryContentTransitionState>();
    final content = GlobalKey();
    final color = ValueNotifier(Colors.red);
    final reduced = ValueNotifier(false);
    addTearDown(color.dispose);
    addTearDown(reduced.dispose);
    await pumpContent(tester, transition, content, color, reduced);
    final state = tester.state(find.byKey(content));
    transition.currentState!.animate(() => color.value = Colors.green);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    transition.currentState!.animate(() => color.value = Colors.blue);
    transition.currentState!.animate(() => color.value = Colors.yellow);
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsNothing);
    expect(tester.state(find.byKey(content)), same(state));
    expect(
      tester
          .widget<ColoredBox>(
            find.descendant(
              of: find.byKey(content),
              matching: find.byType(ColoredBox),
            ),
          )
          .color,
      Colors.yellow,
    );
    transition.currentState!.animate(() => color.value = Colors.red);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion finishes active slides and skips new ones', (
    tester,
  ) async {
    final transition = GlobalKey<LibraryContentTransitionState>();
    final content = GlobalKey();
    final color = ValueNotifier(Colors.red);
    final reduced = ValueNotifier(false);
    addTearDown(color.dispose);
    addTearDown(reduced.dispose);
    await pumpContent(tester, transition, content, color, reduced);
    transition.currentState!.animate(() => color.value = Colors.green);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    reduced.value = true;
    await tester.pump();
    expect(find.byType(RawImage), findsNothing);
    expect(tester.getTopLeft(find.byKey(content)).dx, 0);
    transition.currentState!.animate(() => color.value = Colors.blue);
    await tester.pump();
    expect(find.byType(RawImage), findsNothing);
    expect(tester.getTopLeft(find.byKey(content)).dx, 0);
    expect(tester.takeException(), isNull);
  });
}

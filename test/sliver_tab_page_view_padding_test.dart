import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/sliver_tab_page_view.dart';

Widget _fixture(
  ValueNotifier<double> position, {
  required VoidCallback onRedTap,
  required VoidCallback onBlueTap,
}) => MaterialApp(
  home: Scaffold(
    body: RepaintBoundary(
      key: const ValueKey('capture'),
      child: ColoredBox(
        color: Colors.white,
        child: ValueListenableBuilder<double>(
          valueListenable: position,
          builder: (context, page, _) => CustomScrollView(
            slivers: [
              SliverTabPageView(
                position: AlwaysStoppedAnimation(page),
                crossAxisPadding: 16,
                onDragStart: () {},
                onDragUpdate: (_) {},
                onDragEnd: (_) {},
                onDragCancel: () {},
                pages: [
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(
                      child: SizedBox(
                        key: const ValueKey('red'),
                        height: 100,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onRedTap,
                          child: const ColoredBox(color: Colors.red),
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(
                      child: SizedBox(
                        key: const ValueKey('blue'),
                        height: 100,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onBlueTap,
                          child: const ColoredBox(color: Colors.blue),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

Future<List<int>> _samplePixels(
  WidgetTester tester,
  List<int> xCoordinates,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  final pixels = await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return [
        for (final x in xCoordinates)
          Color.fromARGB(
            255,
            data.getUint8((40 * image.width + x) * 4),
            data.getUint8((40 * image.width + x) * 4 + 1),
            data.getUint8((40 * image.width + x) * 4 + 2),
          ).toARGB32(),
      ];
    } finally {
      image.dispose();
    }
  });
  return pixels!;
}

void main() {
  testWidgets('keeps page padding and clips the moving pager gutters', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final position = ValueNotifier(0.0);
    var redTaps = 0;
    var blueTaps = 0;
    addTearDown(position.dispose);
    for (final width in [390.0, 700.0]) {
      await tester.binding.setSurfaceSize(Size(width, 500));
      position.value = 0;
      redTaps = 0;
      blueTaps = 0;
      await tester.pumpWidget(
        _fixture(
          position,
          onRedTap: () => redTaps++,
          onBlueTap: () => blueTaps++,
        ),
      );

      for (final page in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        position.value = page;
        await tester.pump();

        final outsideGutters = await _samplePixels(tester, [
          8,
          width.toInt() - 8,
        ]);
        expect(outsideGutters, [
          Colors.white.toARGB32(),
          Colors.white.toARGB32(),
        ]);

        if (page == 0) {
          final red = tester.getRect(find.byKey(const ValueKey('red')));
          expect(red.width, closeTo(width - 32, 0.01));
          expect(red.left, closeTo(16, 0.01));
        }

        if (page == 1) {
          final blue = tester.getRect(find.byKey(const ValueKey('blue')));
          expect(blue.width, closeTo(width - 32, 0.01));
          expect(blue.left, closeTo(16, 0.01));
        }

        if (page == 0.5) {
          final red = tester.getRect(find.byKey(const ValueKey('red')));
          final blue = tester.getRect(find.byKey(const ValueKey('blue')));
          expect(red.width, closeTo(width - 32, 0.01));
          expect(blue.width, closeTo(width - 32, 0.01));
          expect(blue.left - red.right, closeTo(32, 0.01));
        }

        if (page == 0.5) {
          final content = await _samplePixels(tester, [
            24,
            width.toInt() ~/ 2,
            width.toInt() - 24,
          ]);
          expect(content, [
            Colors.red.toARGB32(),
            Colors.white.toARGB32(),
            Colors.blue.toARGB32(),
          ]);

          await tester.tapAt(const Offset(8, 40));
          await tester.tapAt(Offset(width - 8, 40));
          expect([redTaps, blueTaps], [0, 0]);
          await tester.tapAt(const Offset(24, 40));
          await tester.tapAt(Offset(width - 24, 40));
          expect([redTaps, blueTaps], [1, 1]);
          expect(tester.takeException(), isNull);
        }
      }
    }
  });
}

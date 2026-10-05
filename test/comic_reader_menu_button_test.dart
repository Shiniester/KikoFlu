import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/comics/ui/comic_reader_menu_button.dart';

void main() {
  testWidgets('opens above the button and returns the selected value', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final selected = <int>[];
    await tester.pumpWidget(_menuHarness(selected: selected));
    await tester.tap(find.byTooltip('Mode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final clip = find
        .descendant(
          of: find.byType(SizeTransition),
          matching: find.byType(ClipRect),
        )
        .first;
    final partial = tester.getRect(clip);
    expect(partial.height, greaterThan(0));
    expect(partial.height, lessThan(6 * 48));
    final partialMenuBottom = tester
        .getRect(find.byKey(const ValueKey('comic-reader-menu-surface')))
        .bottom;
    expect(
      partialMenuBottom,
      lessThanOrEqualTo(tester.getRect(find.byTooltip('Mode')).top - 8),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(clip).height, greaterThan(partial.height));

    final menu = find.byKey(const ValueKey('comic-reader-menu-surface'));
    expect(menu, findsOneWidget);
    expect(tester.getRect(menu).bottom, closeTo(partialMenuBottom, .01));
    expect(
      tester.getRect(menu).bottom,
      lessThanOrEqualTo(tester.getRect(find.byTooltip('Mode')).top - 8),
    );

    await tester.tap(find.text('Option 2'));
    await tester.pumpAndSettle();

    expect(selected, [1]);
    expect(menu, findsNothing);
  });

  testWidgets('reduced motion stays above the button in a short resized view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final selected = <int>[];
    await tester.pumpWidget(
      _menuHarness(selected: selected, reduceMotion: true),
    );
    await tester.tap(find.byTooltip('Mode'));
    await tester.pump();

    final menu = find.byKey(const ValueKey('comic-reader-menu-surface'));
    expect(menu, findsOneWidget);

    tester.view.physicalSize = const Size(320, 240);
    await tester.pumpAndSettle();

    final menuRect = tester.getRect(menu);
    final buttonRect = tester.getRect(find.byTooltip('Mode'));
    expect(menuRect.bottom, lessThanOrEqualTo(buttonRect.top - 8));
    expect(menuRect.height, lessThan(6 * 48));

    await tester.drag(menu, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Option 6'));
    await tester.pumpAndSettle();

    expect(selected, [5]);
  });

  testWidgets('outside tap and Escape dismiss without selecting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final selected = <int>[];
    await tester.pumpWidget(_menuHarness(selected: selected));

    await tester.tap(find.byTooltip('Mode'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('comic-reader-menu-surface')),
      findsNothing,
    );

    await tester.tap(find.byTooltip('Mode'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('comic-reader-menu-surface')),
      findsNothing,
    );
    expect(selected, isEmpty);
  });
}

Widget _menuHarness({required List<int> selected, bool reduceMotion = false}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.white)),
            Positioned(
              right: 16,
              bottom: 16,
              child: ComicReaderMenuButton<int>(
                tooltip: 'Mode',
                icon: const Icon(Icons.menu),
                itemBuilder: (_) => List.generate(
                  6,
                  (index) => PopupMenuItem<int>(
                    value: index,
                    child: Text('Option ${index + 1}'),
                  ),
                ),
                onSelected: selected.add,
              ),
            ),
          ],
        ),
      ),
    );

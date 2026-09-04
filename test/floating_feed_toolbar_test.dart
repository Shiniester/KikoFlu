import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/floating_feed_toolbar.dart';

Widget _testApp(Widget child, {double width = 390}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('renders classic Material capsules with interactive actions', (
    tester,
  ) async {
    var selectedMode = '';
    var toolTaps = 0;

    await tester.pumpWidget(
      _testApp(
        FloatingFeedToolbar(
          modeActions: [
            FloatingFeedModeAction(
              icon: Icons.grid_view,
              label: 'All',
              isSelected: true,
              onPressed: () => selectedMode = 'all',
            ),
            FloatingFeedModeAction(
              icon: Icons.local_fire_department,
              label: 'Popular',
              isSelected: false,
              onPressed: () => selectedMode = 'popular',
            ),
          ],
          toolActions: [
            FloatingFeedToolAction(
              icon: Icons.closed_caption,
              tooltip: 'Subtitles',
              isSelected: true,
              onPressed: () => toolTaps++,
            ),
          ],
        ),
      ),
    );

    expect(find.byKey(const ValueKey('feed-mode-capsule')), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-tool-capsule')), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    final surfaceMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey('feed-mode-capsule')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      surfaceMaterial.color?.a,
      closeTo(FloatingToolbarSurface.backgroundOpacity, 0.001),
    );

    await tester.tap(find.text('Popular'));
    await tester.tap(find.byTooltip('Subtitles'));
    expect(selectedMode, 'popular');
    expect(toolTaps, 1);
  });

  testWidgets('uses a bounded Material popup when modes do not fit', (
    tester,
  ) async {
    var selectedMode = -1;
    await tester.pumpWidget(
      _testApp(
        FloatingFeedToolbar(
          modeActions: [
            for (var index = 0; index < 8; index++)
              FloatingFeedModeAction(
                icon: Icons.filter_alt,
                label: 'Filter option $index',
                isSelected: index == 0,
                onPressed: () => selectedMode = index,
              ),
          ],
          toolActions: [
            FloatingFeedToolAction(
              icon: Icons.sort,
              tooltip: 'Sort',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );

    expect(find.byKey(const ValueKey('feed-mode-dropdown')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('feed-mode-dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('Filter option 1'), findsOneWidget);
    await tester.tap(find.text('Filter option 1'));
    await tester.pumpAndSettle();
    expect(selectedMode, 1);
  });

  testWidgets('can keep every mode as scrolling buttons when requested', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        FloatingFeedToolbar(
          collapseModesWhenNeeded: false,
          modeActions: [
            for (var index = 0; index < 8; index++)
              FloatingFeedModeAction(
                icon: Icons.filter_alt,
                label: 'Filter option $index',
                isSelected: index == 0,
                onPressed: () {},
              ),
          ],
          toolActions: const [],
        ),
        width: 280,
      ),
    );

    expect(find.byKey(const ValueKey('feed-mode-scroll')), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-mode-dropdown')), findsNothing);
  });

  testWidgets('secondary toolbar follows primary visibility', (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      _testApp(
        Stack(
          children: [
            FloatingToolbarPositionFollower(
              primaryToolbarVisible: visible,
              visibleTop: 64,
              hiddenTop: 8,
              left: 8,
              right: 8,
              child: const SizedBox(height: 40),
            ),
          ],
        ),
      ),
    );

    expect(
      tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned)).top,
      64,
    );
    visible.value = false;
    await tester.pump();
    expect(
      tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned)).top,
      8,
    );
  });

  testWidgets('progressive top treatment avoids dynamic backdrop filters', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        const MediaQuery(
          data: MediaQueryData(padding: EdgeInsets.only(top: 24)),
          child: ProgressiveTopScrim(height: 48),
        ),
      ),
    );

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(DecoratedBox), findsOneWidget);
  });
}

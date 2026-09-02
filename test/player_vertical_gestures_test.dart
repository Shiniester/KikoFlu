import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_vertical_gestures.dart';

void main() {
  testWidgets('directional player region ignores horizontal page gestures', (
    tester,
  ) async {
    var upCount = 0;
    var downCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerVerticalSwipeRegion(
            key: const ValueKey('vertical-region'),
            onSwipeUp: () => upCount++,
            onSwipeDown: () => downCount++,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey('vertical-region')),
      const Offset(220, 8),
    );
    expect((upCount, downCount), (0, 0));

    await tester.drag(
      find.byKey(const ValueKey('vertical-region')),
      const Offset(0, -100),
    );
    await tester.drag(
      find.byKey(const ValueKey('vertical-region')),
      const Offset(0, 100),
    );
    expect((upCount, downCount), (1, 1));
  });

  testWidgets('scroll edge actions require a user overscroll at each edge', (
    tester,
  ) async {
    var topCount = 0;
    var bottomCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerScrollEdgeActions(
            onPullDownAtTop: () => topCount++,
            onPushUpAtBottom: () => bottomCount++,
            child: ListView.builder(
              key: const ValueKey('edge-list'),
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              itemCount: 40,
              itemExtent: 48,
              itemBuilder: (_, index) => Text('item $index'),
            ),
          ),
        ),
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey('edge-list')),
      const Offset(0, 140),
    );
    await tester.pump();
    expect((topCount, bottomCount), (1, 0));

    await tester.fling(
      find.byKey(const ValueKey('edge-list')),
      const Offset(0, -1600),
      4000,
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('edge-list')),
      const Offset(0, -140),
    );
    await tester.pump();
    expect((topCount, bottomCount), (1, 1));
  });
}

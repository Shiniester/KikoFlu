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

  testWidgets(
    'progressive vertical drag keeps its initial semantic direction',
    (tester) async {
      final upUpdates = <double>[];
      var upStarts = 0;
      var upEnds = 0;
      var downStarts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerVerticalSwipeRegion(
              key: const ValueKey('progressive-region'),
              swipeUpDrag: PlayerVerticalDragCallbacks(
                onStart: () => upStarts++,
                onUpdate: upUpdates.add,
                onEnd: (_, __) => upEnds++,
                onCancel: () {},
              ),
              swipeDownDrag: PlayerVerticalDragCallbacks(
                onStart: () => downStarts++,
                onUpdate: (_) {},
                onEnd: (_, __) {},
                onCancel: () {},
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('progressive-region'))),
      );
      await gesture.moveBy(const Offset(0, -80));
      await gesture.moveBy(const Offset(0, 35));
      await gesture.up();

      expect(upStarts, 1);
      expect(upEnds, 1);
      expect(downStarts, 0);
      expect(upUpdates.first, greaterThan(upUpdates.last));
    },
  );

  testWidgets('edge drag keeps ownership and reverses monotonically', (
    tester,
  ) async {
    final updates = <double>[];
    var starts = 0;
    var ends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerScrollEdgeActions(
            pullDownDrag: PlayerVerticalDragCallbacks(
              onStart: () => starts++,
              onUpdate: updates.add,
              onEnd: (_, __) => ends++,
              onCancel: () {},
            ),
            child: ListView.builder(
              key: const ValueKey('progressive-edge-list'),
              physics: const AlwaysScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              ),
              itemCount: 30,
              itemExtent: 48,
              itemBuilder: (_, index) => Text('edge item $index'),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('progressive-edge-list'))),
    );
    await gesture.moveBy(const Offset(0, 90));
    await tester.pump();
    final outwardDistance = updates.last;
    await gesture.moveBy(const Offset(0, -42));
    await tester.pump();
    expect(updates.last, lessThan(outwardDistance));
    expect(updates.every((value) => value >= 0), isTrue);
    await gesture.up();
    await tester.pump();

    expect(starts, 1);
    expect(ends, 1);
  });
}

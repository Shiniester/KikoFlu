import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_scroll_drag_handoff.dart';
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
                onStart: () {
                  upStarts++;
                  return true;
                },
                onUpdate: upUpdates.add,
                onEnd: (_, __) => upEnds++,
                onCancel: () {},
              ),
              swipeDownDrag: PlayerVerticalDragCallbacks(
                onStart: () {
                  downStarts++;
                  return true;
                },
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

  testWidgets('page-only vertical forwarding starts after six drag pixels', (
    tester,
  ) async {
    final pageController = PageController();
    final coordinator = PlayerScrollDragHandoffCoordinator(pageController);
    final mediaQuery = MediaQueryData.fromView(
      tester.view,
    ).copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: 1));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: PageView(
                  controller: pageController,
                  scrollDirection: Axis.vertical,
                  children: const [
                    ColoredBox(color: Colors.red),
                    ColoredBox(color: Colors.blue),
                  ],
                ),
              ),
              SizedBox(
                height: 100,
                child: MediaQuery(
                  data: mediaQuery,
                  child: PlayerVerticalSwipeRegion(
                    key: const ValueKey('page-forward-region'),
                    pageDragCoordinator: coordinator,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('page-forward-region'))),
    );
    await gesture.moveBy(const Offset(0, -5));
    await tester.pump();
    expect(pageController.page, closeTo(0, 0.001));
    await gesture.moveBy(const Offset(0, -1));
    await tester.pump();
    expect(pageController.page, greaterThan(0));
    await gesture.cancel();
    await tester.pumpAndSettle();
    pageController.dispose();
    expect(tester.takeException(), isNull);
  });

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
              onStart: () {
                starts++;
                return true;
              },
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

  testWidgets('list and page return residual delta during one pointer drag', (
    tester,
  ) async {
    final pageController = PageController();
    final coordinator = PlayerScrollDragHandoffCoordinator(pageController);
    final listController = coordinator.createScrollController();
    await tester.pumpWidget(_handoffHarness(pageController, listController));
    await tester.pumpAndSettle();

    final listPosition = listController.position;
    final startPixels = listPosition.maxScrollExtent - 80;
    listController.jumpTo(startPixels);
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('handoff-list'))),
    );
    await gesture.moveBy(
      const Offset(0, -20),
      timeStamp: const Duration(milliseconds: 10),
    );
    await tester.pump();
    await gesture.moveBy(
      const Offset(0, -140),
      timeStamp: const Duration(milliseconds: 30),
    );
    await tester.pump();
    expect(pageController.page, greaterThan(0));
    expect(listController.offset, closeTo(listPosition.maxScrollExtent, 0.5));

    await gesture.moveBy(
      const Offset(0, 220),
      timeStamp: const Duration(milliseconds: 50),
    );
    await tester.pump();
    expect(pageController.page, closeTo(0, 0.001));
    expect(listController.offset, lessThan(startPixels));

    await gesture.up(timeStamp: const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(pageController.page, closeTo(0, 0.001));
    expect(listController.hasClients, isTrue);

    listController.dispose();
    pageController.dispose();
  });

  testWidgets('handoff page receives the original pointer end velocity', (
    tester,
  ) async {
    final pageController = PageController();
    final coordinator = PlayerScrollDragHandoffCoordinator(pageController);
    final listController = coordinator.createScrollController();
    await tester.pumpWidget(_handoffHarness(pageController, listController));
    await tester.pumpAndSettle();
    listController.jumpTo(listController.position.maxScrollExtent - 24);
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('handoff-list'))),
    );
    await gesture.moveBy(
      const Offset(0, -20),
      timeStamp: const Duration(milliseconds: 10),
    );
    await tester.pump();
    await gesture.moveBy(
      const Offset(0, -64),
      timeStamp: const Duration(milliseconds: 18),
    );
    await gesture.up(timeStamp: const Duration(milliseconds: 19));
    await tester.pumpAndSettle();

    expect(pageController.page, closeTo(1, 0.001));

    listController.dispose();
    pageController.dispose();
  });

  testWidgets('cancelled handoff settles and accepts a later drag', (
    tester,
  ) async {
    final pageController = PageController();
    final coordinator = PlayerScrollDragHandoffCoordinator(pageController);
    final listController = coordinator.createScrollController();
    await tester.pumpWidget(_handoffHarness(pageController, listController));
    await tester.pumpAndSettle();
    listController.jumpTo(listController.position.maxScrollExtent - 24);
    await tester.pump();

    final firstGesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('handoff-list'))),
    );
    await firstGesture.moveBy(
      const Offset(0, -20),
      timeStamp: const Duration(milliseconds: 10),
    );
    await tester.pump();
    await firstGesture.moveBy(
      const Offset(0, -100),
      timeStamp: const Duration(milliseconds: 20),
    );
    await tester.pump();
    expect(pageController.page, greaterThan(0));
    expect(pageController.page, lessThan(0.5));
    await firstGesture.cancel(timeStamp: const Duration(milliseconds: 30));
    await tester.pumpAndSettle();
    expect(
      (pageController.page! - pageController.page!.round()).abs(),
      lessThan(0.001),
    );

    pageController.jumpToPage(0);
    await tester.pumpAndSettle();
    expect(listController.hasClients, isTrue);
    listController.jumpTo(listController.position.maxScrollExtent - 24);
    await tester.pump();

    final nextGesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('handoff-list'))),
    );
    await nextGesture.moveBy(
      const Offset(0, -20),
      timeStamp: const Duration(milliseconds: 40),
    );
    await tester.pump();
    await nextGesture.moveBy(
      const Offset(0, -60),
      timeStamp: const Duration(milliseconds: 50),
    );
    await tester.pump();
    expect(pageController.page, greaterThan(0));
    await nextGesture.cancel(timeStamp: const Duration(milliseconds: 60));
    await tester.pumpAndSettle();

    listController.dispose();
    pageController.dispose();
  });
}

Widget _handoffHarness(
  PageController pageController,
  ScrollController listController,
) {
  return MaterialApp(
    home: Scaffold(
      body: PageView(
        key: const ValueKey('handoff-pages'),
        controller: pageController,
        scrollDirection: Axis.vertical,
        children: [
          ListView.builder(
            key: const ValueKey('handoff-list'),
            controller: listController,
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            itemCount: 40,
            itemExtent: 48,
            itemBuilder: (context, index) => Text('row $index'),
          ),
          const ColoredBox(
            key: ValueKey('handoff-queue-page'),
            color: Colors.blue,
          ),
        ],
      ),
    ),
  );
}

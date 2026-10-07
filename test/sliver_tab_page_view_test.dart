import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/sliver_tab_page_view.dart';

Widget _fixture(
  ValueNotifier<double> page,
  ScrollController scroll,
  ValueChanged<int> onBuild, {
  VoidCallback? onCancel,
}) => MaterialApp(
  home: Scaffold(
    body: ValueListenableBuilder<double>(
      valueListenable: page,
      builder: (context, position, _) => CustomScrollView(
        controller: scroll,
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
          SliverTabPageView(
            position: AlwaysStoppedAnimation(position),
            onDragStart: () {},
            onDragUpdate: (delta) =>
                page.value = (page.value + delta).clamp(0.0, 2.0),
            onDragEnd: (_) => page.value = page.value.roundToDouble(),
            onDragCancel: onCancel ?? () {},
            pages: [
              SliverList.builder(
                itemCount: 200,
                itemBuilder: (context, index) {
                  onBuild(index);
                  return SizedBox(height: 52, child: Text('audio $index'));
                },
              ),
              SliverLayoutBuilder(
                builder: (context, constraints) => SliverMasonryGrid.count(
                  key: const ValueKey('images'),
                  crossAxisCount: constraints.crossAxisExtent > 600 ? 4 : 2,
                  childCount: 60,
                  itemBuilder: (context, index) => SizedBox(
                    height: index.isEven ? 96 : 152,
                    child: Text('image $index'),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
          const SliverToBoxAdapter(
            child: SizedBox(height: 50, child: Text('recommendations')),
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'sliding preserves lazy outer scrolling and selected page extent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final page = ValueNotifier(0.0);
      final scroll = ScrollController();
      addTearDown(page.dispose);
      addTearDown(scroll.dispose);
      final built = <int>{};
      var canceled = 0;
      await tester.pumpWidget(
        _fixture(page, scroll, built.add, onCancel: () => canceled++),
      );
      expect(built.length, lessThan(30));
      await tester.drag(find.text('audio 0'), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(canceled, 0);
      scroll.jumpTo(800);
      await tester.pump();
      expect(scroll.offset, 800);
      expect(built, contains(20));
      expect(built.length, lessThan(50));

      page.value = 0.25;
      await tester.pump();
      expect(find.textContaining('audio '), findsWidgets);
      expect(find.byKey(const ValueKey('images')), findsOneWidget);

      page.value = 2;
      await tester.pumpAndSettle();
      final pager = tester.renderObject<RenderSliverTabPageView>(
        find.byType(SliverTabPageView),
      );
      expect(pager.geometry!.scrollExtent, 100);
      expect(find.text('recommendations').hitTestable(), findsOneWidget);
      page.value = 0;
      await tester.pumpAndSettle();
      expect(find.textContaining('audio '), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rotated offscreen masonry corrects before it becomes nearest', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final page = ValueNotifier(1.0);
    final scroll = ScrollController();
    addTearDown(page.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_fixture(page, scroll, (_) {}));
    scroll.jumpTo(1000);
    await tester.pumpAndSettle();
    final grid = tester.renderObject<RenderSliver>(
      find.byKey(const ValueKey('images')),
    );
    expect(grid.constraints.scrollOffset, greaterThan(500));

    page.value = 0;
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(900, 500));
    await tester.pumpAndSettle();
    page.value = 0.25;
    await tester.pumpAndSettle();
    expect(grid.geometry!.scrollOffsetCorrection, isNull);
    expect(grid.geometry!.visible, isTrue);
    expect(tester.takeException(), isNull);
  });
}

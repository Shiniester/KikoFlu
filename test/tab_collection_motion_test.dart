import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/tab_page_motion.dart';
import 'package:kikoeru_flutter/src/widgets/virtualized_sliver_collection.dart';

void main() {
  for (final layout in VirtualizedCollectionLayout.values) {
    testWidgets('first $layout content waits for paging and stays mounted', (
      tester,
    ) async {
      final pages = PageController();
      final target = ValueNotifier<int?>(null);
      addTearDown(pages.dispose);
      addTearDown(target.dispose);
      var builtItems = 0;
      var prefetches = 0;
      final collection = VirtualizedSliverCollection<int>(
        items: List.generate(40, (i) => i),
        itemId: (item) => item,
        layout: layout,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
        ),
        masonryCrossAxisCount: 2,
        showEndIndicator: false,
        onPrefetch: (_) => prefetches++,
        itemBuilder: (context, item, _) {
          builtItems++;
          return SizedBox(
            key: ValueKey(item),
            height: 72,
            child: Text('$item'),
          );
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TabPageWarmup(
              pages: pages,
              target: target,
              builder: (extent) => PageView(
                controller: pages,
                allowImplicitScrolling: extent > 0,
                scrollCacheExtent: ScrollCacheExtent.viewport(extent),
                children: [
                  const SizedBox.expand(),
                  LazyTabPage(
                    index: 1,
                    pages: pages,
                    target: target,
                    child: collection,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      Future<void> select(int index) async {
        target.value = index;
        await moveToTabPage(pages, index, reduceMotion: false);
        target.value = null;
      }

      unawaited(select(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(pages.page, inExclusiveRange(0, 1));
      expect(builtItems, 0);
      expect(prefetches, 0);
      await tester.pumpAndSettle();
      expect(builtItems, greaterThan(0));
      expect(prefetches, greaterThan(0));
      final first = tester.element(find.byKey(const ValueKey(0)));

      unawaited(select(0));
      await tester.pumpAndSettle();
      unawaited(select(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.element(find.byKey(const ValueKey(0))), same(first));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

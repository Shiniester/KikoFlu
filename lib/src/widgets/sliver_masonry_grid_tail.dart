import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// Keeps a bounded masonry grid's full extent stable after its items leave cache.
class SliverMasonryGridTail extends SingleChildRenderObjectWidget {
  const SliverMasonryGridTail({
    super.key,
    required this.itemCount,
    required super.child,
  });

  final int itemCount;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSliverMasonryGridTail(itemCount);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderSliverMasonryGridTail).itemCount = itemCount;
  }
}

class _RenderSliverMasonryGridTail extends RenderProxySliver {
  _RenderSliverMasonryGridTail(this.itemCount);

  int itemCount;

  @override
  void performLayout() {
    final grid = child! as RenderSliverMasonryGrid;
    final previous = grid.geometry;
    final cacheStart = constraints.scrollOffset + constraints.cacheOrigin;
    final lastChild = grid.lastChild;
    final reachedEnd =
        lastChild != null && grid.indexOf(lastChild) == itemCount - 1;
    if (!reachedEnd ||
        previous == null ||
        previous.scrollOffsetCorrection != null) {
      super.performLayout();
      return;
    }

    // Keep the bounded page's columns while its final child is in cache. The
    // final child may belong to a shorter column, so waiting for the grid's
    // maximum extent lets that column be collected before the cache reaches it.
    grid.layout(
      constraints.copyWith(
        cacheOrigin: -constraints.scrollOffset,
        remainingCacheExtent: constraints.remainingCacheExtent + cacheStart,
      ),
      parentUsesSize: true,
    );
    final result = grid.geometry!;
    geometry = result.scrollOffsetCorrection != null
        ? result
        : result.copyWith(
            cacheExtent: calculateCacheOffset(
              constraints,
              from: 0,
              to: result.scrollExtent,
            ),
          );
  }
}

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Horizontally transitions between full-width slivers in one vertical viewport.
class SliverTabPageView extends MultiChildRenderObjectWidget {
  const SliverTabPageView({
    super.key,
    required this.position,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
    required List<Widget> pages,
  }) : assert(pages.length >= 2),
       super(children: pages);

  final Animation<double> position;
  final VoidCallback onDragStart;

  /// Reports page-space movement, where positive values move to the next page.
  final ValueChanged<double> onDragUpdate;

  /// Reports page-space velocity, where positive values move to the next page.
  final ValueChanged<double> onDragEnd;
  final VoidCallback onDragCancel;

  @override
  MultiChildRenderObjectElement createElement() =>
      _SliverTabPageViewElement(this);

  @override
  RenderSliverTabPageView createRenderObject(BuildContext context) =>
      RenderSliverTabPageView(
        position: position,
        onDragStart: onDragStart,
        onDragUpdate: onDragUpdate,
        onDragEnd: onDragEnd,
        onDragCancel: onDragCancel,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverTabPageView renderObject,
  ) {
    renderObject
      ..position = position
      ..onDragStart = onDragStart
      ..onDragUpdate = onDragUpdate
      ..onDragEnd = onDragEnd
      ..onDragCancel = onDragCancel;
  }
}

class _SliverTabPageViewElement extends MultiChildRenderObjectElement {
  _SliverTabPageViewElement(SliverTabPageView super.widget);

  @override
  SliverTabPageView get widget => super.widget as SliverTabPageView;

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    final renderSliver = renderObject as RenderSliverTabPageView;
    final page = renderSliver.position.value
        .clamp(0.0, (widget.children.length - 1).toDouble())
        .toDouble();
    final firstPage = page.floor();
    final lastPage = page.ceil();
    for (var index = 0; index < children.length; index++) {
      if (index != firstPage && index != lastPage) continue;
      final child = children.elementAt(index);
      final childRenderObject = child.renderObject;
      if (childRenderObject is RenderSliver &&
          renderSliver._laidOutPages.contains(childRenderObject) &&
          childRenderObject.geometry?.visible == true) {
        visitor(child);
      }
    }
  }
}

class _SliverTabPageParentData extends SliverPhysicalContainerParentData {}

class RenderSliverTabPageView extends RenderSliver
    with
        ContainerRenderObjectMixin<RenderSliver, _SliverTabPageParentData>,
        RenderSliverHelpers {
  RenderSliverTabPageView({
    required this._position,
    required this._onDragStart,
    required this._onDragUpdate,
    required this._onDragEnd,
    required this._onDragCancel,
  }) {
    _position.addListener(_handlePositionChanged);
    _dragRecognizer = HorizontalDragGestureRecognizer(debugOwner: this);
    _dragRecognizer.dragStartBehavior = DragStartBehavior.down;
    _dragRecognizer.onStart = (_) {
      _dragging = true;
      _onDragStart();
    };
    _dragRecognizer.onUpdate = _handleDragUpdate;
    _dragRecognizer.onEnd = _handleDragEnd;
    _dragRecognizer.onCancel = () {
      if (!_dragging) return;
      _dragging = false;
      _onDragCancel();
    };
  }

  late final HorizontalDragGestureRecognizer _dragRecognizer;
  bool _dragging = false;
  Animation<double> _position;
  VoidCallback _onDragStart;
  ValueChanged<double> _onDragUpdate;
  ValueChanged<double> _onDragEnd;
  VoidCallback _onDragCancel;
  final _laidOutPages = <RenderSliver>[];

  Animation<double> get position => _position;
  set position(Animation<double> value) {
    if (value == _position) return;
    _position.removeListener(_handlePositionChanged);
    _position = value;
    _position.addListener(_handlePositionChanged);
    markNeedsLayout();
  }

  set onDragStart(VoidCallback value) => _onDragStart = value;
  set onDragUpdate(ValueChanged<double> value) => _onDragUpdate = value;
  set onDragEnd(ValueChanged<double> value) => _onDragEnd = value;
  set onDragCancel(VoidCallback value) => _onDragCancel = value;

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! _SliverTabPageParentData) {
      child.parentData = _SliverTabPageParentData();
    }
  }

  RenderSliver _childAt(int index) {
    var child = firstChild!;
    for (var current = 0; current < index; current++) {
      child = childAfter(child)!;
    }
    return child;
  }

  void _handlePositionChanged() {
    if (attached) markNeedsLayout();
  }

  double _pageDelta(double physicalDelta) {
    final direction = constraints.crossAxisDirection == AxisDirection.right
        ? 1.0
        : -1.0;
    return -physicalDelta * direction / constraints.crossAxisExtent;
  }

  void _handleDragUpdate(DragUpdateDetails details) =>
      _onDragUpdate(_pageDelta(details.delta.dx));

  void _handleDragEnd(DragEndDetails details) {
    _dragging = false;
    _onDragEnd(_pageDelta(details.velocity.pixelsPerSecond.dx));
  }

  @override
  void performLayout() {
    assert(constraints.axis == Axis.vertical);
    assert(childCount >= 2);

    final page = _position.value
        .clamp(0.0, (childCount - 1).toDouble())
        .toDouble();
    final firstPage = page.floor();
    final lastPage = page.ceil();
    final activePages = firstPage == lastPage
        ? [firstPage]
        : [firstPage, lastPage];
    _laidOutPages.clear();
    final corrections = <int, double>{};

    for (final index in activePages) {
      final child = _childAt(index);
      child.layout(constraints, parentUsesSize: true);
      final childGeometry = child.geometry!;
      final correction = childGeometry.scrollOffsetCorrection;
      if (correction != null) {
        corrections[index] = correction;
        continue;
      }
      final direction = constraints.crossAxisDirection == AxisDirection.right
          ? 1.0
          : -1.0;
      final crossAxisOffset =
          (index - page) * constraints.crossAxisExtent * direction;
      final childParentData = child.parentData! as _SliverTabPageParentData;
      childParentData.paintOffset = Offset(
        crossAxisOffset,
        childGeometry.paintOrigin,
      );
      _laidOutPages.add(child);
    }

    // Previously visited pages may rebuild asynchronously; isolate their
    // layout invalidations from this pager while they are offscreen.
    for (var index = 0; index < childCount; index++) {
      if (activePages.contains(index)) continue;
      final child = _childAt(index);
      if (child.geometry != null) {
        child.layout(child.constraints, parentUsesSize: false);
      }
    }

    final correction =
        corrections[page.round()] ??
        (corrections.isEmpty ? null : corrections.values.first);
    if (correction != null) {
      geometry = SliverGeometry(scrollOffsetCorrection: correction);
      return;
    }

    if (_laidOutPages.length == 1) {
      final childGeometry = _laidOutPages.single.geometry!;
      geometry = childGeometry.copyWith(
        paintOrigin: 0,
        crossAxisExtent: constraints.crossAxisExtent,
        hasVisualOverflow: true,
      );
      return;
    }

    final first = _laidOutPages.first.geometry!;
    final second = _laidOutPages.last.geometry!;
    geometry = SliverGeometry(
      scrollExtent: math.max(first.scrollExtent, second.scrollExtent),
      paintExtent: math.max(first.paintExtent, second.paintExtent),
      layoutExtent: math.max(first.layoutExtent, second.layoutExtent),
      maxPaintExtent: math.max(first.maxPaintExtent, second.maxPaintExtent),
      maxScrollObstructionExtent: math.max(
        first.maxScrollObstructionExtent,
        second.maxScrollObstructionExtent,
      ),
      crossAxisExtent: constraints.crossAxisExtent,
      hitTestExtent: math.max(first.hitTestExtent, second.hitTestExtent),
      visible: first.visible || second.visible,
      hasVisualOverflow: true,
      cacheExtent: math.max(first.cacheExtent, second.cacheExtent),
    );
  }

  @override
  double? childScrollOffset(RenderObject child) => 0;

  @override
  double childMainAxisPosition(RenderSliver child) {
    final childParentData = child.parentData! as _SliverTabPageParentData;
    return switch (applyGrowthDirectionToAxisDirection(
      constraints.axisDirection,
      constraints.growthDirection,
    )) {
      AxisDirection.down => childParentData.paintOffset.dy,
      AxisDirection.up =>
        geometry!.paintExtent -
            child.geometry!.paintExtent -
            childParentData.paintOffset.dy,
      AxisDirection.right => childParentData.paintOffset.dx,
      AxisDirection.left =>
        geometry!.paintExtent -
            child.geometry!.paintExtent -
            childParentData.paintOffset.dx,
    };
  }

  @override
  double childCrossAxisPosition(RenderSliver child) {
    final childParentData = child.parentData! as _SliverTabPageParentData;
    return switch (constraints.axis) {
      Axis.vertical => childParentData.paintOffset.dx,
      Axis.horizontal => childParentData.paintOffset.dy,
    };
  }

  @override
  void applyPaintTransform(RenderSliver child, Matrix4 transform) {
    final childParentData = child.parentData! as _SliverTabPageParentData;
    childParentData.applyPaintTransform(transform);
  }

  @override
  bool hitTestSelf({
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) => true;

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    for (final child in _laidOutPages.reversed) {
      final childParentData = child.parentData! as _SliverTabPageParentData;
      if (result.addWithAxisOffset(
        mainAxisPosition: mainAxisPosition,
        crossAxisPosition: crossAxisPosition,
        paintOffset: childParentData.paintOffset,
        mainAxisOffset: childMainAxisPosition(child),
        crossAxisOffset: childCrossAxisPosition(child),
        hitTest: child.hitTest,
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (event is PointerDownEvent) _dragRecognizer.addPointer(event);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final page = _position.value.round().clamp(0, childCount - 1);
    visitor(_childAt(page));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.pushClipRect(
      needsCompositing,
      offset,
      Rect.fromLTWH(0, 0, constraints.crossAxisExtent, geometry!.paintExtent),
      (context, offset) {
        for (final child in _laidOutPages) {
          if (child.geometry!.visible) {
            final childParentData =
                child.parentData! as _SliverTabPageParentData;
            context.paintChild(child, offset + childParentData.paintOffset);
          }
        }
      },
      clipBehavior: Clip.hardEdge,
    );
  }

  @override
  void dispose() {
    _position.removeListener(_handlePositionChanged);
    _dragRecognizer.dispose();
    super.dispose();
  }
}

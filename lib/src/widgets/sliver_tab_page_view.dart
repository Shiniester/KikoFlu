import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
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
    this.pageResourceOffsets,
    this.leadingExtent = 0,
    this.transitionSourceIndex,
    this.onPageResourceOffsetCorrected,
    this.crossAxisPadding = 0,
    required List<Widget> pages,
  }) : assert(pages.length >= 2),
       assert(
         pageResourceOffsets == null ||
             pageResourceOffsets.length == pages.length,
       ),
       super(children: pages);

  final Animation<double> position;
  final VoidCallback onDragStart;

  /// Reports page-space movement, where positive values move to the next page.
  final ValueChanged<double> onDragUpdate;

  /// Reports page-space velocity, where positive values move to the next page.
  final ValueChanged<double> onDragEnd;
  final VoidCallback onDragCancel;
  final List<double>? pageResourceOffsets;
  final double leadingExtent;
  final int? transitionSourceIndex;
  final double crossAxisPadding;
  final void Function(int pageIndex, double correction)?
  onPageResourceOffsetCorrected;

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
        pageResourceOffsets: pageResourceOffsets,
        leadingExtent: leadingExtent,
        transitionSourceIndex: transitionSourceIndex,
        onPageResourceOffsetCorrected: onPageResourceOffsetCorrected,
        crossAxisPadding: crossAxisPadding,
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
      ..onDragCancel = onDragCancel
      ..pageResourceOffsets = pageResourceOffsets
      ..leadingExtent = leadingExtent
      ..transitionSourceIndex = transitionSourceIndex
      ..crossAxisPadding = crossAxisPadding
      ..onPageResourceOffsetCorrected = onPageResourceOffsetCorrected;
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
    required this._pageResourceOffsets,
    required this._leadingExtent,
    required this._transitionSourceIndex,
    required this._onPageResourceOffsetCorrected,
    required this._crossAxisPadding,
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
  List<double>? _pageResourceOffsets;
  double _leadingExtent;
  int? _transitionSourceIndex;
  double _crossAxisPadding;
  void Function(int pageIndex, double correction)?
  _onPageResourceOffsetCorrected;
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

  set crossAxisPadding(double value) {
    if (value == _crossAxisPadding) return;
    _crossAxisPadding = value;
    markNeedsPaint();
  }

  set pageResourceOffsets(List<double>? value) {
    if (listEquals(_pageResourceOffsets, value)) return;
    _pageResourceOffsets = value;
    markNeedsLayout();
  }

  set leadingExtent(double value) {
    if (value == _leadingExtent) return;
    _leadingExtent = value;
    markNeedsLayout();
  }

  set transitionSourceIndex(int? value) {
    if (value == _transitionSourceIndex) return;
    _transitionSourceIndex = value;
    markNeedsLayout();
  }

  set onPageResourceOffsetCorrected(
    void Function(int pageIndex, double correction)? value,
  ) => _onPageResourceOffsetCorrected = value;

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
    final activePages = <int>{firstPage, lastPage};
    final sourceIndex = _transitionSourceIndex;
    final transitionSource =
        sourceIndex != null && sourceIndex >= 0 && sourceIndex < childCount
        ? sourceIndex
        : null;
    if (transitionSource != null) {
      activePages.add(transitionSource);
    }
    final layoutPages = activePages.toList()..sort();
    _laidOutPages.clear();
    final corrections = <int, double>{};
    var paintOrigin = 0.0;
    var paintEnd = 0.0;
    var layoutEnd = 0.0;
    var hitTestEnd = 0.0;
    var scrollExtent = 0.0;
    var maxPaintExtent = 0.0;
    var maxScrollObstructionExtent = 0.0;
    var visible = false;

    for (final index in layoutPages) {
      final child = _childAt(index);
      final isVirtualPage =
          transitionSource != null && index != transitionSource;
      var resourceOffset = _pageResourceOffsets?[index] ?? 0.0;
      ({SliverConstraints constraints, double paintOffset}) virtualLayout(
        double offset,
      ) {
        final pageScrollOffset = math.max(0.0, offset - _leadingExtent);
        final virtualHostY = math.max(0.0, _leadingExtent - offset);
        final currentHostY =
            constraints.viewportMainAxisExtent -
            constraints.remainingPaintExtent;
        final paintOffset = virtualHostY - currentHostY;
        final cacheOrigin = (constraints.cacheOrigin - paintOffset)
            .clamp(-pageScrollOffset, 0.0)
            .toDouble();
        return (
          constraints: constraints.copyWith(
            scrollOffset: pageScrollOffset,
            remainingPaintExtent: math.max(
              0.0,
              constraints.viewportMainAxisExtent - virtualHostY,
            ),
            cacheOrigin: cacheOrigin,
            remainingCacheExtent: math.max(
              0.0,
              constraints.remainingCacheExtent +
                  constraints.cacheOrigin -
                  paintOffset -
                  cacheOrigin,
            ),
          ),
          paintOffset: paintOffset,
        );
      }

      var pageLayout = isVirtualPage
          ? virtualLayout(resourceOffset)
          : (constraints: constraints, paintOffset: 0.0);
      child.layout(pageLayout.constraints, parentUsesSize: true);
      var childGeometry = child.geometry!;
      var correction = childGeometry.scrollOffsetCorrection;
      var totalCorrection = 0.0;
      while (isVirtualPage && correction != null) {
        totalCorrection += correction;
        resourceOffset += correction;
        pageLayout = virtualLayout(resourceOffset);
        child.layout(pageLayout.constraints, parentUsesSize: true);
        childGeometry = child.geometry!;
        correction = childGeometry.scrollOffsetCorrection;
      }
      if (totalCorrection != 0) {
        _onPageResourceOffsetCorrected?.call(index, totalCorrection);
      }
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
      final childPaintOrigin =
          childGeometry.paintOrigin + pageLayout.paintOffset;
      childParentData.paintOffset = Offset(crossAxisOffset, childPaintOrigin);
      _laidOutPages.add(child);
      paintOrigin = math.min(paintOrigin, childPaintOrigin);
      paintEnd = math.max(
        paintEnd,
        childPaintOrigin + childGeometry.paintExtent,
      );
      layoutEnd = math.max(
        layoutEnd,
        childPaintOrigin + childGeometry.layoutExtent,
      );
      hitTestEnd = math.max(
        hitTestEnd,
        childPaintOrigin + childGeometry.hitTestExtent,
      );
      scrollExtent = math.max(scrollExtent, childGeometry.scrollExtent);
      maxPaintExtent = math.max(maxPaintExtent, childGeometry.maxPaintExtent);
      maxScrollObstructionExtent = math.max(
        maxScrollObstructionExtent,
        childGeometry.maxScrollObstructionExtent,
      );
      visible = visible || childGeometry.visible;
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

    paintEnd = math.min(constraints.remainingPaintExtent, paintEnd);
    layoutEnd = math.min(paintEnd, layoutEnd);
    hitTestEnd = math.min(paintEnd, hitTestEnd);
    for (final child in _laidOutPages) {
      final childParentData = child.parentData! as _SliverTabPageParentData;
      childParentData.paintOffset = Offset(
        childParentData.paintOffset.dx,
        childParentData.paintOffset.dy - paintOrigin,
      );
    }
    scrollExtent = math.max(
      scrollExtent,
      constraints.scrollOffset + constraints.remainingPaintExtent,
    );
    geometry = SliverGeometry(
      scrollExtent: scrollExtent,
      paintOrigin: paintOrigin,
      paintExtent: paintEnd - paintOrigin,
      layoutExtent: layoutEnd
          .clamp(0.0, constraints.remainingPaintExtent)
          .toDouble(),
      maxPaintExtent: math.max(
        maxPaintExtent,
        constraints.remainingPaintExtent - paintOrigin,
      ),
      maxScrollObstructionExtent: maxScrollObstructionExtent,
      crossAxisExtent: constraints.crossAxisExtent,
      hitTestExtent: (hitTestEnd - paintOrigin)
          .clamp(0.0, paintEnd - paintOrigin)
          .toDouble(),
      visible: visible,
      hasVisualOverflow: true,
      cacheExtent: calculateCacheOffset(constraints, from: 0, to: scrollExtent),
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
  bool hitTest(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    if (crossAxisPosition < _crossAxisPadding ||
        crossAxisPosition >= constraints.crossAxisExtent - _crossAxisPadding) {
      return false;
    }
    return super.hitTest(
      result,
      mainAxisPosition: mainAxisPosition,
      crossAxisPosition: crossAxisPosition,
    );
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
      Rect.fromLTWH(
        _crossAxisPadding,
        0,
        math.max(0.0, constraints.crossAxisExtent - _crossAxisPadding * 2),
        geometry!.paintExtent,
      ),
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

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Coordinates a live vertical drag between a bounded inner scrollable and a
/// neighboring player [PageView].
///
/// The coordinator forwards only the portion of an update that each position
/// can consume. Both framework drags stay alive until the pointer ends or is
/// cancelled, so Flutter receives the original end velocity on the final
/// owner and a cancel on the other position.
class PlayerScrollDragHandoffCoordinator {
  PlayerScrollDragHandoffCoordinator(
    this.pageController, {
    this.onPageDragStart,
  });

  final PageController pageController;
  final VoidCallback? onPageDragStart;
  final Set<_PlayerScrollDragHandoff> _activeDrags = {};

  PlayerScrollDragHandoffController createScrollController({
    String? debugLabel,
  }) => PlayerScrollDragHandoffController(
    coordinator: this,
    debugLabel: debugLabel,
  );

  PlayerVerticalPageDragForwarder createPageForwarder() =>
      PlayerVerticalPageDragForwarder(this);

  void cancelActiveDrags() {
    for (final drag in _activeDrags.toList()) {
      drag.cancel();
    }
  }

  _PlayerScrollDragHandoff _beginScrollDrag({
    required ScrollPositionWithSingleContext sourcePosition,
    required DragStartDetails details,
    required Drag sourceDrag,
    required VoidCallback onSourceDisposed,
  }) {
    final drag = _PlayerScrollDragHandoff.scroll(
      coordinator: this,
      sourcePosition: sourcePosition,
      startDetails: details,
      sourceDrag: sourceDrag,
      onSourceDisposed: onSourceDisposed,
    );
    _activeDrags.add(drag);
    return drag;
  }

  _PlayerScrollDragHandoff? _beginPageDrag(DragStartDetails details) {
    if (!pageController.hasClients || pageController.positions.length != 1) {
      return null;
    }
    final position = pageController.position;
    if (!position.hasContentDimensions ||
        position.axisDirection == AxisDirection.left ||
        position.axisDirection == AxisDirection.right) {
      return null;
    }
    final drag = _PlayerScrollDragHandoff.page(
      coordinator: this,
      startDetails: details,
      pagePosition: position,
    );
    _activeDrags.add(drag);
    return drag;
  }

  void _finished(_PlayerScrollDragHandoff drag) {
    _activeDrags.remove(drag);
  }
}

/// A [ScrollController] whose positions can pass edge residuals to a player
/// page drag while retaining their ordinary scroll physics.
class PlayerScrollDragHandoffController extends ScrollController {
  PlayerScrollDragHandoffController({
    required this.coordinator,
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  final PlayerScrollDragHandoffCoordinator coordinator;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _PlayerScrollDragHandoffPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      coordinator: coordinator,
    );
  }
}

class _PlayerScrollDragHandoffPosition extends ScrollPositionWithSingleContext {
  _PlayerScrollDragHandoffPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    required super.oldPosition,
    required super.debugLabel,
    required this.coordinator,
  });

  final PlayerScrollDragHandoffCoordinator coordinator;
  _PlayerScrollDragHandoff? _activeDrag;

  @override
  Drag drag(DragStartDetails details, VoidCallback dragCancelCallback) {
    _PlayerScrollDragHandoff? handoff;
    final sourceDrag = super.drag(details, () {
      final active = _activeDrag;
      _activeDrag = null;
      active?.sourceWasDisposed();
      dragCancelCallback();
    });
    handoff = coordinator._beginScrollDrag(
      sourcePosition: this,
      details: details,
      sourceDrag: sourceDrag,
      onSourceDisposed: () {
        if (identical(_activeDrag, handoff)) _activeDrag = null;
      },
    );
    _activeDrag = handoff;
    return handoff;
  }

  @override
  void dispose() {
    _activeDrag?.sourceWasDisposed();
    _activeDrag = null;
    super.dispose();
  }
}

/// Forwards a non-scrollable region's vertical recognizer to the outer page.
///
/// Use this only where a child drag recognizer is needed for another action,
/// such as dismissing the player route. Plain page content should be left to
/// the [PageView]'s own recognizer.
class PlayerVerticalPageDragForwarder {
  PlayerVerticalPageDragForwarder(this._coordinator);

  final PlayerScrollDragHandoffCoordinator _coordinator;
  _PlayerScrollDragHandoff? _drag;

  void start(DragStartDetails details) {
    _drag?.cancel();
    _drag = _coordinator._beginPageDrag(details);
  }

  void update(DragUpdateDetails details) {
    _drag?.updateDirectPage(details);
  }

  void end(DragEndDetails details) {
    final drag = _drag;
    _drag = null;
    drag?.endDirectPage(details);
  }

  void cancel() {
    final drag = _drag;
    _drag = null;
    drag?.cancel();
  }
}

enum _PlayerDragOwner { source, page }

class _PlayerScrollDragHandoff implements Drag {
  _PlayerScrollDragHandoff.scroll({
    required this.coordinator,
    required this.sourcePosition,
    required this.startDetails,
    required this.sourceDrag,
    required this.onSourceDisposed,
  }) : pagePosition = _attachedPagePosition(coordinator),
       pageDrag = null,
       owner = _PlayerDragOwner.source {
    homePixels = pagePosition?.pixels ?? 0;
  }

  _PlayerScrollDragHandoff.page({
    required this.coordinator,
    required this.startDetails,
    required ScrollPosition pagePosition,
  }) : sourcePosition = null,
       sourceDrag = null,
       onSourceDisposed = null,
       pagePosition = pagePosition,
       homePixels = pagePosition.pixels,
       owner = _PlayerDragOwner.page {
    pageDrag = _createPageDrag(pagePosition);
  }

  final PlayerScrollDragHandoffCoordinator coordinator;
  final ScrollPositionWithSingleContext? sourcePosition;
  final Drag? sourceDrag;
  final DragStartDetails startDetails;
  final VoidCallback? onSourceDisposed;
  ScrollPosition? pagePosition;
  Drag? pageDrag;
  late final double homePixels;
  _PlayerDragOwner owner;
  bool _terminal = false;

  static ScrollPosition? _attachedPagePosition(
    PlayerScrollDragHandoffCoordinator coordinator,
  ) {
    final controller = coordinator.pageController;
    if (!controller.hasClients || controller.positions.length != 1) return null;
    final position = controller.position;
    if (!position.hasContentDimensions ||
        position.axisDirection == AxisDirection.left ||
        position.axisDirection == AxisDirection.right) {
      return null;
    }
    return position;
  }

  static double _pixelDeltaPerPointerDelta(ScrollPosition position) {
    return switch (position.axisDirection) {
      AxisDirection.down => -1,
      AxisDirection.up => 1,
      AxisDirection.left => throw StateError('Expected a vertical page'),
      AxisDirection.right => throw StateError('Expected a vertical page'),
    };
  }

  static DragUpdateDetails _withPrimaryDelta(
    DragUpdateDetails details,
    double primaryDelta,
  ) => DragUpdateDetails(
    sourceTimeStamp: details.sourceTimeStamp,
    delta: Offset(0, primaryDelta),
    primaryDelta: primaryDelta,
    globalPosition: details.globalPosition,
    localPosition: details.localPosition,
    kind: details.kind,
  );

  Drag _createPageDrag(ScrollPosition position) {
    coordinator.onPageDragStart?.call();
    late final Drag drag;
    drag = position.drag(startDetails, () {
      if (identical(pageDrag, drag)) pageDrag = null;
      if (!_terminal) _pageDragWasDisposed();
    });
    return drag;
  }

  double _distanceToSourceBoundary(double pointerDelta) {
    final position = sourcePosition!;
    if (pointerDelta == 0 || !position.hasContentDimensions) {
      return double.infinity;
    }
    final proposed =
        position.pixels + _pixelDeltaPerPointerDelta(position) * pointerDelta;
    if (proposed < position.minScrollExtent) {
      return math.max(0, position.pixels - position.minScrollExtent);
    }
    if (proposed > position.maxScrollExtent) {
      return math.max(0, position.maxScrollExtent - position.pixels);
    }
    return double.infinity;
  }

  double _distanceToHomeBoundary(double pointerDelta) {
    final position = pagePosition!;
    if (pointerDelta == 0) return double.infinity;
    final distanceToHome = homePixels - position.pixels;
    if (distanceToHome.abs() <= 0.5) return 0;
    final pixelDelta = _pixelDeltaPerPointerDelta(position) * pointerDelta;
    if (distanceToHome.sign != pixelDelta.sign) {
      return double.infinity;
    }
    final physicsInput =
        -_pixelDeltaPerPointerDelta(position) * pointerDelta.sign;
    final appliedPerPixel = position.physics
        .applyPhysicsToUserOffset(position, physicsInput)
        .abs();
    if (appliedPerPixel == 0) return double.infinity;
    return distanceToHome.abs() / appliedPerPixel;
  }

  bool _pageCanMove(double pointerDelta) {
    final position = pagePosition;
    if (position == null ||
        pointerDelta == 0 ||
        !position.hasContentDimensions) {
      return false;
    }
    final pixelDelta = _pixelDeltaPerPointerDelta(position) * pointerDelta;
    return pixelDelta < 0
        ? position.pixels > position.minScrollExtent
        : position.pixels < position.maxScrollExtent;
  }

  void _updateSource(DragUpdateDetails details, double amount) {
    if (amount != 0) sourceDrag?.update(_withPrimaryDelta(details, amount));
  }

  void _updatePage(DragUpdateDetails details, double amount) {
    if (amount != 0) pageDrag?.update(_withPrimaryDelta(details, amount));
  }

  @override
  void update(DragUpdateDetails details) {
    if (_terminal) return;
    final pointerDelta = details.primaryDelta ?? details.delta.dy;
    if (sourcePosition == null) {
      _updatePage(details, pointerDelta);
      return;
    }

    if (owner == _PlayerDragOwner.source) {
      final available = _distanceToSourceBoundary(pointerDelta);
      final sourceAmount = math.min(pointerDelta.abs(), available);
      _updateSource(details, pointerDelta.sign * sourceAmount);
      final pageRemainder = pointerDelta - pointerDelta.sign * sourceAmount;
      if (pageRemainder == 0 || !_pageCanMove(pageRemainder)) {
        final sourceRemainder = pointerDelta - pointerDelta.sign * sourceAmount;
        _updateSource(details, sourceRemainder);
        return;
      }
      final position = coordinator.pageController.position;
      pageDrag ??= _createPageDrag(position);
      owner = _PlayerDragOwner.page;
      _updatePage(details, pageRemainder);
      return;
    }

    final pageRemainder = pointerDelta;
    final backToSource = _distanceToHomeBoundary(pageRemainder);
    if (backToSource.isFinite && backToSource <= pointerDelta.abs()) {
      final pageAmount = pointerDelta.sign * backToSource;
      _updatePage(details, pageAmount);
      final homeReached = (pagePosition!.pixels - homePixels).abs() <= 0.5;
      final sourceRemainder = pointerDelta - pageAmount;
      if (homeReached) {
        owner = _PlayerDragOwner.source;
        _updateSource(details, sourceRemainder);
      } else {
        _updatePage(details, sourceRemainder);
      }
      return;
    }
    _updatePage(details, pageRemainder);
  }

  void updateDirectPage(DragUpdateDetails details) {
    if (_terminal || sourcePosition != null) return;
    update(details);
  }

  void endDirectPage(DragEndDetails details) {
    if (_terminal || sourcePosition != null) return;
    _terminal = true;
    pageDrag?.end(details);
    pageDrag = null;
    coordinator._finished(this);
  }

  void sourceWasDisposed() {
    if (_terminal) return;
    _terminal = true;
    pageDrag?.cancel();
    pageDrag = null;
    coordinator._finished(this);
    onSourceDisposed?.call();
  }

  void _pageDragWasDisposed() {
    if (_terminal) return;
    _terminal = true;
    sourceDrag?.cancel();
    pageDrag = null;
    coordinator._finished(this);
    onSourceDisposed?.call();
  }

  @override
  void end(DragEndDetails details) {
    if (_terminal) return;
    _terminal = true;
    if (owner == _PlayerDragOwner.page) {
      sourceDrag?.cancel();
      pageDrag?.end(details);
    } else {
      pageDrag?.cancel();
      sourceDrag?.end(details);
    }
    pageDrag = null;
    coordinator._finished(this);
  }

  @override
  void cancel() {
    if (_terminal) return;
    _terminal = true;
    sourceDrag?.cancel();
    pageDrag?.cancel();
    pageDrag = null;
    coordinator._finished(this);
  }
}

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

/// The bounded presentation state shared by track titles and artwork.
/// Payloads remain owned by their widgets; audio requests never wait here.
enum PlayerTrackVisualKind { title, cover }

class PlayerTrackLayers<T> extends ChangeNotifier {
  PlayerTrackLayers({
    required this.vsync,
    required T initialValue,
    required this.sameContent,
    required this.kind,
    required this.duration,
  }) : _target = initialValue {
    _layers.add(_create(initialValue, settled: true));
  }

  static const interruptedDuration = Duration(milliseconds: 125);
  final TickerProvider vsync;
  final bool Function(T, T) sameContent;
  final PlayerTrackVisualKind kind;
  final Duration duration;
  final List<PlayerTrackLayer<T>> _layers = [];
  int _serial = 0;
  late T _target;
  T? _pending;
  int _pendingDirection = 1;
  bool _disposed = false;

  List<PlayerTrackLayer<T>> get layers => List.unmodifiable(_layers);
  T? get pending => _pending;
  bool get isTransitioning =>
      _pending != null ||
      _layers.length > 1 ||
      _layers.any((layer) => layer.controller.isAnimating);

  PlayerTrackLayer<T> _create(
    T value, {
    bool settled = false,
    int direction = 1,
  }) {
    final layer = PlayerTrackLayer<T>(
      token: _serial++,
      value: value,
      controller: AnimationController(vsync: vsync, duration: duration),
    );
    layer.offset = AlwaysStoppedAnimation(
      settled || kind == PlayerTrackVisualKind.cover
          ? Offset.zero
          : Offset(direction.toDouble(), 0),
    );
    layer.scale = AlwaysStoppedAnimation(
      !settled && kind == PlayerTrackVisualKind.cover ? 1.20 : 1,
    );
    layer.opacity = AlwaysStoppedAnimation(
      !settled && kind == PlayerTrackVisualKind.cover ? 0 : 1,
    );
    layer.controller.addStatusListener((status) {
      if (status != AnimationStatus.completed || _disposed) return;
      if (layer.exiting) {
        _layers.remove(layer);
        layer.controller.dispose();
      }
      final pending = _pending;
      if (pending != null && _layers.length < 3) {
        _pending = null;
        _present(pending, _pendingDirection);
      }
      notifyListeners();
    });
    return layer;
  }

  void present(T value, {int direction = 1}) {
    final sameTarget = sameContent(_target, value);
    _target = value;
    if (sameTarget &&
        (_pending != null ||
            _layers.any((layer) => sameContent(layer.value, value)))) {
      for (final layer in _layers) {
        if (sameContent(layer.value, value)) layer.value = value;
      }
      if (_pending != null) _pending = value;
      notifyListeners();
      return;
    }
    _pending = null;
    _present(value, direction);
    notifyListeners();
  }

  void _present(T value, int direction) {
    PlayerTrackLayer<T>? existing;
    for (final layer in _layers) {
      if (sameContent(layer.value, value)) existing = layer;
    }
    if (existing == null && _layers.length == 3) {
      _pending = value;
      _pendingDirection = direction;
      return;
    }
    final interrupted = isTransitioning;
    for (final layer in _layers) {
      if (identical(layer, existing)) continue;
      _retire(layer, direction, interrupted: interrupted);
    }
    if (existing != null) {
      existing.value = value;
      existing.exiting = false;
      _animate(
        existing,
        offset: Offset.zero,
        scale: 1,
        opacity: 1,
        duration: duration,
      );
    } else if (_layers.length < 3) {
      final incoming = _create(value, direction: direction);
      _layers.add(incoming);
      _animate(
        incoming,
        offset: Offset.zero,
        scale: 1,
        opacity: 1,
        duration: duration,
      );
    } else {
      _pending = value;
      _pendingDirection = direction;
    }
  }

  void _retire(
    PlayerTrackLayer<T> layer,
    int direction, {
    required bool interrupted,
  }) {
    var retireDuration = interrupted ? interruptedDuration : duration;
    if (layer.exiting) {
      final remaining =
          layer.controller.duration! * (1 - layer.controller.value);
      if (remaining <= retireDuration) return;
      retireDuration = remaining < interruptedDuration
          ? remaining
          : interruptedDuration;
    }
    final targetOffset = layer.exiting
        ? layer.exitOffset
        : Offset(
            kind == PlayerTrackVisualKind.title ? -direction.toDouble() : 0,
            0,
          );
    layer.exiting = true;
    layer.exitOffset = targetOffset;
    layer.fades = kind == PlayerTrackVisualKind.cover || interrupted;
    _animate(
      layer,
      offset: targetOffset,
      scale: kind == PlayerTrackVisualKind.cover ? 1.20 : 1,
      opacity: layer.fades ? 0 : 1,
      duration: retireDuration,
    );
  }

  void _animate(
    PlayerTrackLayer<T> layer, {
    required Offset offset,
    required double scale,
    required double opacity,
    required Duration duration,
  }) {
    final startOffset = layer.offset.value;
    final startScale = layer.scale.value;
    final startOpacity = layer.opacity.value;
    layer.controller.stop();
    final eased = layer.controller.drive(
      CurveTween(curve: Curves.easeOutCubic),
    );
    layer.offset = Tween(begin: startOffset, end: offset).animate(eased);
    layer.scale = Tween(begin: startScale, end: scale).animate(eased);
    layer.opacity = Tween(
      begin: startOpacity,
      end: opacity,
    ).animate(layer.controller);
    layer.controller.duration = duration;
    layer.controller.forward(from: 0);
  }

  /// A newer artwork request invalidates ready-but-not-yet-displayed artwork.
  void discardPending() {
    _pending = null;
  }

  bool replaceContent(bool Function(T) matches, T value) {
    var replaced = false;
    for (final layer in _layers) {
      if (matches(layer.value)) {
        layer.value = value;
        replaced = true;
      }
    }
    if (_pending != null && matches(_pending as T)) {
      _pending = value;
      replaced = true;
    }
    if (matches(_target)) _target = value;
    if (replaced) notifyListeners();
    return replaced;
  }

  void showImmediately(T value) {
    for (final layer in _layers) {
      layer.controller.dispose();
    }
    _layers.clear();
    _pending = null;
    _target = value;
    _layers.add(_create(value, settled: true));
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final layer in _layers) {
      layer.controller.dispose();
    }
    _layers.clear();
    super.dispose();
  }
}

class PlayerTrackLayer<T> {
  PlayerTrackLayer({
    required this.token,
    required this.value,
    required this.controller,
  });

  final int token;
  T value;
  final AnimationController controller;
  late Animation<Offset> offset;
  late Animation<double> scale;
  late Animation<double> opacity;
  bool exiting = false;
  bool fades = false;
  Offset exitOffset = Offset.zero;
}

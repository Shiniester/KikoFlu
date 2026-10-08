import 'dart:async';

/// Warms visible images before the rest of one bounded page.
class ImagePrefetchQueue<T> {
  ImagePrefetchQueue({
    required this._keyOf,
    required this._prepare,
  });

  static const _maxConcurrent = 2;
  static const _maxBackgroundConcurrent = 1;

  final Object Function(T item) _keyOf;
  final Future<void> Function(T item) _prepare;
  List<T> _items = const [];
  List<T> _visible = const [];
  final Set<Object> _ready = {};
  final Set<Object> _running = {};
  bool _active = false;
  bool _disposed = false;

  void update({
    required List<T> items,
    required List<T> visible,
    required bool active,
  }) {
    if (_disposed) return;
    final uniqueItems = <Object, T>{};
    for (final item in items) {
      uniqueItems.putIfAbsent(_keyOf(item), () => item);
    }
    final pageKeys = uniqueItems.keys.toSet();
    final visibleKeys = <Object>{};
    _visible = [
      for (final item in visible)
        if (pageKeys.contains(_keyOf(item)) && visibleKeys.add(_keyOf(item)))
          uniqueItems[_keyOf(item)]!,
    ];
    _items = uniqueItems.values.toList(growable: false);
    _ready.retainAll(pageKeys);
    _active = active;
    _pump();
  }

  void dispose() {
    _disposed = true;
    _active = false;
    _items = const [];
    _visible = const [];
    _ready.clear();
  }

  void _pump() {
    if (_disposed || !_active) return;
    final visibleKeys = _visible.map(_keyOf).toSet();
    final waitingForVisible = _visible.any(
      (item) => !_ready.contains(_keyOf(item)),
    );
    while (_running.length < _maxConcurrent) {
      final nextVisible = _visible
          .where(
            (item) =>
                !_ready.contains(_keyOf(item)) &&
                !_running.contains(_keyOf(item)),
          )
          .firstOrNull;
      if (nextVisible != null) {
        _start(nextVisible);
        continue;
      }
      if (waitingForVisible) return;
      final backgroundRunning = _running.difference(visibleKeys).length;
      if (backgroundRunning >= _maxBackgroundConcurrent) return;
      final nextBackground = _items
          .where(
            (item) =>
                !_ready.contains(_keyOf(item)) &&
                !_running.contains(_keyOf(item)),
          )
          .firstOrNull;
      if (nextBackground == null) return;
      _start(nextBackground);
    }
  }

  void _start(T item) {
    final key = _keyOf(item);
    if (!_running.add(key)) return;
    unawaited(_run(item, key));
  }

  Future<void> _run(T item, Object key) async {
    try {
      await _prepare(item);
    } catch (_) {
      // A failed prewarm must not block the remaining page.
    }
    _running.remove(key);
    if (_items.any((item) => _keyOf(item) == key)) _ready.add(key);
    _pump();
  }
}

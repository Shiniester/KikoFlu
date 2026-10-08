import 'dart:async';

import 'package:flutter/painting.dart';

/// Warms visible images before the rest of one bounded page.
class ImagePrefetchQueue<T> {
  ImagePrefetchQueue({required this._keyOf, required this._prepare});

  static const _maxConcurrent = 4;
  static const _maxBackgroundConcurrent = 2;
  static const _maxRetainedBytes = 32 * 1024 * 1024;

  final Object Function(T item) _keyOf;
  final Future<void> Function(T item) _prepare;
  List<T> _items = const [];
  List<T> _visible = const [];
  final Set<Object> _ready = {};
  final Set<Object> _running = {};
  List<Object> _upcomingKeys = const [];
  final _retainedImages =
      <
        Object,
        ({ImageStream stream, ImageStreamListener listener, int bytes})
      >{};
  int _retainedBytes = 0;
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
    final lastVisibleIndex = _items.lastIndexWhere(
      (item) => visibleKeys.contains(_keyOf(item)),
    );
    final upcomingKeys = active && _visible.isNotEmpty
        ? _items
              .skip(lastVisibleIndex + 1)
              .take(_visible.length.clamp(2, 8))
              .map(_keyOf)
              .toList(growable: false)
        : <Object>[];
    for (final key in upcomingKeys) {
      // Full-page warming may have evicted a frame before it enters this window.
      if (!_upcomingKeys.contains(key)) _ready.remove(key);
    }
    _upcomingKeys = upcomingKeys;
    for (final key in _retainedImages.keys.toList()) {
      if (!upcomingKeys.contains(key)) _releaseImage(key);
    }
    _active = active;
    _pump();
  }

  void retainImage(Object key, ImageStream stream) {
    if (_disposed ||
        !_active ||
        !_upcomingKeys.contains(key) ||
        _retainedImages.containsKey(key)) {
      return;
    }
    final listener = ImageStreamListener((info, _) {
      final bytes = info.image.width * info.image.height * 4;
      info.dispose();
      final retained = _retainedImages[key];
      if (retained == null) return;
      _retainedBytes += bytes - retained.bytes;
      _retainedImages[key] = (
        stream: retained.stream,
        listener: retained.listener,
        bytes: bytes,
      );
      while (_retainedBytes > _maxRetainedBytes) {
        final furthest = _upcomingKeys.reversed.firstWhere(
          _retainedImages.containsKey,
        );
        _releaseImage(furthest);
      }
    }, onError: (_, __) => _releaseImage(key));
    _retainedImages[key] = (stream: stream, listener: listener, bytes: 0);
    stream.addListener(listener);
  }

  void _releaseImage(Object key) {
    final retained = _retainedImages.remove(key);
    if (retained == null) return;
    _retainedBytes -= retained.bytes;
    retained.stream.removeListener(retained.listener);
  }

  void dispose() {
    _disposed = true;
    _active = false;
    _items = const [];
    _visible = const [];
    _ready.clear();
    _upcomingKeys = const [];
    for (final key in _retainedImages.keys.toList()) {
      _releaseImage(key);
    }
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
      final lastVisibleIndex = _items.lastIndexWhere(
        (item) => visibleKeys.contains(_keyOf(item)),
      );
      final nearbyFirst = _items
          .skip(lastVisibleIndex + 1)
          .followedBy(_items.take(lastVisibleIndex + 1));
      final nextBackground = nearbyFirst
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

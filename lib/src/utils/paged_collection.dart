import 'package:dio/dio.dart';

class PagedRequestHandle {
  PagedRequestHandle(this.id);

  final int id;
  final CancelToken cancelToken = CancelToken();

  void cancel([String reason = 'Superseded by a newer page request']) {
    if (!cancelToken.isCancelled) cancelToken.cancel(reason);
  }
}

/// Tracks the newest request so stale responses cannot overwrite a newer query.
class PagedRequestGate {
  int _serial = 0;
  PagedRequestHandle? _activeToken;

  bool get isInFlight => _activeToken != null;

  PagedRequestHandle? begin({bool supersede = false}) {
    if (_activeToken != null && !supersede) return null;
    if (supersede) _activeToken?.cancel();
    final token = PagedRequestHandle(++_serial);
    _activeToken = token;
    return token;
  }

  bool isCurrent(PagedRequestHandle token) => identical(_activeToken, token);

  void complete(PagedRequestHandle token) {
    if (identical(_activeToken, token)) _activeToken = null;
  }

  void invalidate() {
    _serial++;
    _activeToken?.cancel('Request gate invalidated');
    _activeToken = null;
  }
}

/// Creates an immutable, identity-based snapshot for refreshes and appends.
///
/// Existing positions are retained while newer values replace matching IDs.
/// New IDs are appended in response order. A refresh starts from an empty map.
List<T> mergePagedItems<T, I>({
  required List<T> existing,
  required Iterable<T> incoming,
  required I Function(T item) idOf,
  bool replace = false,
}) {
  final byId = <I, T>{};
  if (!replace) {
    for (final item in existing) {
      byId[idOf(item)] = item;
    }
  }
  for (final item in incoming) {
    byId[idOf(item)] = item;
  }
  return List<T>.unmodifiable(byId.values);
}

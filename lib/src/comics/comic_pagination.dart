import 'comic_models.dart';

typedef ComicPageFetcher = Future<ComicResult> Function(String? cursor);

class ComicPageSource {
  const ComicPageSource(this.key, this.fetch);

  final String key;
  final ComicPageFetcher fetch;
}

class ComicPageSlice {
  const ComicPageSlice(
    this.items, {
    required this.hasMore,
    this.errors = const {},
  });

  final List<Comic> items;
  final bool hasMore;
  final Map<String, Object> errors;
}

class ComicPageBuffer {
  ComicPageBuffer(List<ComicPageSource> sources)
    : _sources = [for (final source in sources) _ComicPageChannel(source)];

  factory ComicPageBuffer.fromItems(List<Comic> items) => ComicPageBuffer([
    ComicPageSource(
      'local',
      (cursor) async =>
          cursor == null ? ComicResult(items) : const ComicResult([]),
    ),
  ]);

  final List<_ComicPageChannel> _sources;
  final List<Comic> _items = [];
  final Map<int, Map<String, Object>> _pageErrors = {};
  int _nextSource = 0;

  Future<ComicPageSlice> page(
    int page,
    int pageSize, {
    bool retryFailures = false,
  }) async {
    if (page < 1 || pageSize < 1) {
      throw ArgumentError('Page and page size must be positive.');
    }
    final end = page * pageSize;
    final errors = _pageErrors.putIfAbsent(page, () => {});
    if (retryFailures) {
      for (final source in _sources.where(
        (source) => errors.containsKey(source.source.key),
      )) {
        try {
          await _fetch(source);
          errors.remove(source.source.key);
        } catch (error) {
          errors[source.source.key] = error;
        }
      }
    }
    final blocked = <String>{};
    while (_items.length < end) {
      if (!await _appendNext(blocked, errors)) break;
    }
    final start = (page - 1) * pageSize;
    return ComicPageSlice(
      _items.skip(start).take(pageSize).toList(growable: false),
      hasMore: _items.length > end || _hasMore,
      errors: Map.unmodifiable(errors),
    );
  }

  bool get _hasMore => _sources.any(
    (source) =>
        !source.exhausted &&
        (source.emitted < source.items.length ||
            !source.initialized ||
            source.cursor != null),
  );

  Future<bool> _appendNext(
    Set<String> blocked,
    Map<String, Object> errors,
  ) async {
    if (_sources.isEmpty) return false;
    var skipped = 0;
    while (skipped < _sources.length) {
      final index = _nextSource;
      final source = _sources[index];
      if (blocked.contains(source.source.key)) {
        _nextSource = (index + 1) % _sources.length;
        skipped++;
        continue;
      }
      if (source.emitted < source.items.length) {
        _items.add(source.items[source.emitted++]);
        _nextSource = (index + 1) % _sources.length;
        return true;
      }
      if (!source.initialized || source.cursor != null) {
        try {
          await _fetch(source);
          errors.remove(source.source.key);
        } catch (error) {
          errors[source.source.key] = error;
          blocked.add(source.source.key);
          _nextSource = (index + 1) % _sources.length;
          skipped++;
          continue;
        }
        continue;
      }
      source.exhausted = true;
      _nextSource = (index + 1) % _sources.length;
      skipped++;
    }
    return false;
  }

  Future<void> _fetch(_ComicPageChannel source) async {
    final requestCursor = source.cursor;
    final result = await source.source.fetch(requestCursor);
    source.initialized = true;
    source.cursor = result.next;
    var added = 0;
    for (final comic in result.items) {
      if (source.itemKeys.add(comic.key)) {
        source.items.add(comic);
        added++;
      }
    }
    if (added == 0 && result.next == requestCursor) {
      source.cursor = null;
      source.exhausted = true;
    }
  }
}

class _ComicPageChannel {
  _ComicPageChannel(this.source);

  final ComicPageSource source;
  final List<Comic> items = [];
  final Set<String> itemKeys = {};
  String? cursor;
  int emitted = 0;
  bool initialized = false;
  bool exhausted = false;
}

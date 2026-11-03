import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UnifiedSearchHistoryContext {
  const UnifiedSearchHistoryContext({
    required this.contentType,
    required this.entryScope,
    required this.source,
  });

  final String contentType;
  final String entryScope;
  final String source;

  String get key => jsonEncode([contentType, entryScope, source]);

  Map<String, Object?> toJson() => {
    'contentType': contentType,
    'entryScope': entryScope,
    'source': source,
  };

  factory UnifiedSearchHistoryContext.fromJson(Map<String, dynamic> json) =>
      UnifiedSearchHistoryContext(
        contentType: json['contentType'] as String,
        entryScope: json['entryScope'] as String,
        source: json['source'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is UnifiedSearchHistoryContext && key == other.key;

  @override
  int get hashCode => key.hashCode;
}

class UnifiedSearchHistoryEntry {
  UnifiedSearchHistoryEntry({
    required this.id,
    required this.context,
    required Map<String, Object?> payload,
    required this.timestamp,
  }) : payload = _freezeJsonMap(payload);

  final String id;
  final UnifiedSearchHistoryContext context;
  final Map<String, Object?> payload;
  final DateTime timestamp;

  Map<String, Object?> toJson() => {
    'id': id,
    'context': context.toJson(),
    'payload': payload,
    'timestamp': timestamp.toIso8601String(),
  };

  factory UnifiedSearchHistoryEntry.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'];
    if (payload is! Map) throw const FormatException('Invalid history payload');
    return UnifiedSearchHistoryEntry(
      id: json['id'] as String,
      context: UnifiedSearchHistoryContext.fromJson(
        Map<String, dynamic>.from(json['context'] as Map),
      ),
      payload: Map<String, Object?>.from(payload),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

class UnifiedSearchHistoryState {
  UnifiedSearchHistoryState({
    List<UnifiedSearchHistoryEntry> entries = const [],
    this.isLoading = false,
  }) : entries = List.unmodifiable(entries);

  final List<UnifiedSearchHistoryEntry> entries;
  final bool isLoading;

  List<UnifiedSearchHistoryEntry> itemsFor(
    UnifiedSearchHistoryContext context,
  ) => List.unmodifiable(entries.where((entry) => entry.context == context));
}

class UnifiedSearchHistoryNotifier
    extends StateNotifier<UnifiedSearchHistoryState> {
  UnifiedSearchHistoryNotifier()
    : super(UnifiedSearchHistoryState(isLoading: true)) {
    unawaited(load());
  }

  static const preferenceKey = 'unified_search_history';
  static const _legacyAudioPreferenceKey = 'search_history';
  static const _legacyVideoPreferenceKey = 'video_search_history';
  static const _version = 1;
  static const maxItemsPerContext = 20;
  static int _nextIdSequence = 0;

  Future<void>? _loadFuture;
  Future<void> _operationQueue = Future<void>.value();
  bool _loaded = false;
  bool _legacyMigrationComplete = false;
  bool _legacyMigrationPending = false;
  bool _storeReadable = true;

  bool get canPersist => _storeReadable;

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= _load();
  }

  List<UnifiedSearchHistoryEntry> itemsFor(
    UnifiedSearchHistoryContext context,
  ) => state.itemsFor(context);

  Future<String> addOrReplace(
    UnifiedSearchHistoryContext context,
    Map<String, Object?> payload, {
    String? id,
    UnifiedSearchHistoryContext? previousContext,
    String? protectedId,
    UnifiedSearchHistoryContext? protectedContext,
  }) {
    final storedPayload = _freezeJsonMap(payload);
    final canonicalPayload = _canonicalJson(storedPayload);
    return _serialize(() async {
      await load();
      final moveFromPreviousContext =
          id != null && previousContext != null && previousContext != context;
      final matchingId = id == null
          ? null
          : state.entries.where(
              (entry) => entry.context == context && entry.id == id,
            );
      final duplicate =
          matchingId == null || (moveFromPreviousContext && matchingId.isEmpty)
          ? state.entries.where(
              (entry) =>
                  entry.context == context &&
                  _canonicalJson(entry.payload) == canonicalPayload,
            )
          : const <UnifiedSearchHistoryEntry>[];
      final existing = matchingId != null
          ? (matchingId.isEmpty ? null : matchingId.first)
          : (duplicate.isEmpty ? null : duplicate.first);
      final entryId = existing?.id ?? id ?? _newId();
      final entry = UnifiedSearchHistoryEntry(
        id: entryId,
        context: context,
        payload: storedPayload,
        timestamp: DateTime.now(),
      );
      final entries = state.entries
          .where(
            (candidate) =>
                !(moveFromPreviousContext &&
                    candidate.context == previousContext &&
                    candidate.id == id) &&
                !(candidate.context == context &&
                    (candidate.id == entryId ||
                        _canonicalJson(candidate.payload) == canonicalPayload)),
          )
          .toList();
      final protectExisting =
          protectedContext == context &&
          entries.any(
            (candidate) =>
                candidate.context == context && candidate.id == protectedId,
          );
      var contextItems = 0;
      final cappedEntries = [entry, ...entries].where((candidate) {
        if (candidate.context != context) return true;
        if (protectExisting && candidate.id == protectedId) return true;
        return contextItems++ < maxItemsPerContext - (protectExisting ? 1 : 0);
      }).toList();
      state = UnifiedSearchHistoryState(entries: cappedEntries);
      await _persist();
      return entryId;
    });
  }

  Future<void> remove(UnifiedSearchHistoryContext context, String id) =>
      _serialize(() async {
        await load();
        state = UnifiedSearchHistoryState(
          entries: state.entries
              .where((entry) => entry.context != context || entry.id != id)
              .toList(),
        );
        await _persist();
      });

  Future<void> clear(UnifiedSearchHistoryContext context) =>
      _serialize(() async {
        await load();
        state = UnifiedSearchHistoryState(
          entries: state.entries
              .where((entry) => entry.context != context)
              .toList(),
        );
        await _persist();
      });

  Future<void> _load() async {
    var entries = <UnifiedSearchHistoryEntry>[];
    try {
      final preferences = await SharedPreferences.getInstance();
      String? stored;
      try {
        stored = preferences.getString(preferenceKey);
      } catch (_) {
        _storeReadable = false;
      }
      if (stored != null) {
        try {
          final decoded = jsonDecode(stored);
          if (decoded is! Map<String, dynamic> ||
              decoded['version'] != _version ||
              decoded['records'] is! List) {
            _storeReadable = false;
          } else {
            var recordsReadable = true;
            for (final record in decoded['records'] as List) {
              if (record is! Map) {
                recordsReadable = false;
                continue;
              }
              try {
                entries.add(
                  UnifiedSearchHistoryEntry.fromJson(
                    Map<String, dynamic>.from(record),
                  ),
                );
              } catch (_) {
                recordsReadable = false;
              }
            }
            if (!recordsReadable) _storeReadable = false;
            _legacyMigrationComplete =
                decoded['legacyMigrationComplete'] == true;
          }
        } catch (_) {
          _storeReadable = false;
        }
      }

      if (!_legacyMigrationComplete) {
        final legacy = _readLegacyHistory(preferences);
        entries = _mergeLegacy(entries, legacy);
        // Old keys stay intact, so repeated imports could restore deleted rows.
        _legacyMigrationPending = true;
        state = UnifiedSearchHistoryState(entries: entries, isLoading: true);
        await _persist();
      }
    } catch (_) {
      _storeReadable = false;
      // Keep the provider usable in memory when preferences are unavailable.
    } finally {
      _loaded = true;
      if (mounted) {
        state = UnifiedSearchHistoryState(
          entries: entries.isEmpty ? state.entries : entries,
          isLoading: false,
        );
      }
    }
  }

  Future<void> _persist() async {
    if (!_storeReadable) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final markMigrationComplete =
          _legacyMigrationComplete || _legacyMigrationPending;
      final saved = await preferences.setString(
        preferenceKey,
        jsonEncode({
          'version': _version,
          'legacyMigrationComplete': markMigrationComplete,
          'records': state.entries.map((entry) => entry.toJson()).toList(),
        }),
      );
      if (saved && markMigrationComplete) {
        _legacyMigrationComplete = true;
        _legacyMigrationPending = false;
      } else if (!saved) {
        _disablePersistence();
      }
    } catch (_) {
      _disablePersistence();
      // Keep in-memory history when the stored data cannot be read or written.
    }
  }

  void _disablePersistence() {
    if (!_storeReadable) return;
    _storeReadable = false;
    if (mounted) {
      state = UnifiedSearchHistoryState(
        entries: state.entries,
        isLoading: state.isLoading,
      );
    }
  }

  List<UnifiedSearchHistoryEntry> _readLegacyHistory(
    SharedPreferences preferences,
  ) {
    final entries = <UnifiedSearchHistoryEntry>[];

    try {
      final storedAudioHistory = preferences.getString(
        _legacyAudioPreferenceKey,
      );
      if (storedAudioHistory != null) {
        final decoded = jsonDecode(storedAudioHistory);
        if (decoded is List) {
          for (var index = 0; index < decoded.length; index++) {
            final row = decoded[index];
            if (row is! Map) continue;
            try {
              final item = Map<String, dynamic>.from(row);
              final parameters = item['searchParams'];
              final sourceValue = parameters is Map
                  ? parameters['source']
                  : null;
              final source = sourceValue is String && sourceValue.isNotEmpty
                  ? sourceValue
                  : 'asmrOne';
              entries.add(
                UnifiedSearchHistoryEntry(
                  id: item['id'] as String? ?? 'audio-legacy-$index',
                  context: UnifiedSearchHistoryContext(
                    contentType: 'audio',
                    entryScope: 'global-works',
                    source: source,
                  ),
                  payload: Map<String, Object?>.from(item),
                  timestamp: DateTime.parse(item['timestamp'] as String),
                ),
              );
            } catch (_) {
              // The original legacy value remains available for recovery.
            }
          }
        }
      }
    } catch (_) {
      // The original legacy value remains available for recovery.
    }

    try {
      final storedVideoHistory = preferences.getStringList(
        _legacyVideoPreferenceKey,
      );
      if (storedVideoHistory != null) {
        final migratedAt = DateTime.now();
        for (var index = 0; index < storedVideoHistory.length; index++) {
          entries.add(
            UnifiedSearchHistoryEntry(
              id: 'video-legacy-$index',
              context: const UnifiedSearchHistoryContext(
                contentType: 'video',
                entryScope: 'source-directory',
                source: 'legacy-unknown',
              ),
              payload: {'keyword': storedVideoHistory[index], 'legacy': true},
              timestamp: migratedAt.subtract(Duration(microseconds: index)),
            ),
          );
        }
      }
    } catch (_) {
      // The original legacy value remains available for recovery.
    }

    return entries;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operationQueue.then((_) => operation());
    _operationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  static List<UnifiedSearchHistoryEntry> _mergeLegacy(
    List<UnifiedSearchHistoryEntry> current,
    List<UnifiedSearchHistoryEntry> legacy,
  ) {
    final merged = [...current];
    for (final candidate in legacy) {
      if (merged.any(
        (entry) =>
            entry.context == candidate.context &&
            (entry.id == candidate.id ||
                _canonicalJson(entry.payload) ==
                    _canonicalJson(candidate.payload)),
      )) {
        continue;
      }
      merged.add(candidate);
    }
    merged.sort((left, right) => right.timestamp.compareTo(left.timestamp));
    return merged;
  }

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_nextIdSequence++}';
}

class UnifiedSearchHistorySession {
  UnifiedSearchHistorySession(this._history);

  final UnifiedSearchHistoryNotifier _history;
  Future<void> _queue = Future<void>.value();
  String? _activeId;
  UnifiedSearchHistoryContext? _activeContext;
  bool _replayNextUpdate = false;
  UnifiedSearchHistoryContext? _replayedContext;
  Map<String, Object?>? _replayedPayload;
  String? _protectedId;
  UnifiedSearchHistoryContext? _protectedContext;

  Future<void> submit(
    UnifiedSearchHistoryContext context,
    Map<String, Object?> payload,
  ) {
    final snapshot = _freezeJsonMap(payload);
    return _enqueue(() async {
      await _history.load();
      final alreadySaved = _history
          .itemsFor(context)
          .any(
            (entry) =>
                _canonicalJson(entry.payload) == _canonicalJson(snapshot),
          );
      _activeId = null;
      _activeContext = null;
      _replayNextUpdate = alreadySaved;
      _replayedContext = alreadySaved ? context : null;
      _replayedPayload = alreadySaved ? snapshot : null;
      final id = await _history.addOrReplace(context, snapshot);
      _protectedId = alreadySaved ? id : null;
      _protectedContext = alreadySaved ? context : null;
      if (!alreadySaved) {
        _activeId = id;
        _activeContext = context;
      }
    });
  }

  Future<void> update(
    UnifiedSearchHistoryContext context,
    Map<String, Object?> payload,
  ) {
    final snapshot = _freezeJsonMap(payload);
    return _enqueue(() async {
      await _history.load();
      final sameAsReplay =
          _replayedPayload != null &&
          context == _replayedContext &&
          _canonicalJson(snapshot) == _canonicalJson(_replayedPayload!);
      final matchesExisting = _history
          .itemsFor(context)
          .any(
            (entry) =>
                (entry.id != _activeId || entry.context != _activeContext) &&
                _canonicalJson(entry.payload) == _canonicalJson(snapshot),
          );
      if (sameAsReplay || matchesExisting) {
        if (_activeId != null && _activeContext != null) {
          await _history.remove(_activeContext!, _activeId!);
        }
        _activeId = null;
        _activeContext = null;
        _replayNextUpdate = true;
        return;
      }
      final shouldCreateRecord = _activeId == null || _replayNextUpdate;
      _activeId = await _history.addOrReplace(
        context,
        snapshot,
        id: shouldCreateRecord ? null : _activeId,
        previousContext: shouldCreateRecord ? null : _activeContext,
        protectedId: _protectedId,
        protectedContext: _protectedContext,
      );
      _activeContext = context;
      _replayNextUpdate = false;
    });
  }

  Future<void> replay({
    UnifiedSearchHistoryContext? context,
    Map<String, Object?>? payload,
    UnifiedSearchHistoryEntry? entry,
  }) {
    final snapshot = payload == null ? null : _freezeJsonMap(payload);
    return _enqueue(() async {
      _activeId = null;
      _activeContext = null;
      _replayNextUpdate = true;
      _replayedContext = context;
      _replayedPayload = snapshot;
      _protectedId = entry?.id;
      _protectedContext = entry?.context;
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _queue.then((_) async {
      try {
        await operation();
      } catch (_) {
        // A failed write must not block later changes in this search session.
      }
    });
    _queue = next;
    return next;
  }
}

Map<String, Object?> _freezeJsonMap(Map<String, Object?> value) {
  final decoded = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  return Map<String, Object?>.unmodifiable({
    for (final entry in decoded.entries)
      entry.key: _freezeJsonValue(entry.value),
  });
}

Object? _freezeJsonValue(Object? value) => switch (value) {
  Map map => Map<String, Object?>.unmodifiable({
    for (final entry in map.entries)
      entry.key as String: _freezeJsonValue(entry.value),
  }),
  List list => List<Object?>.unmodifiable(list.map(_freezeJsonValue)),
  _ => value,
};

String _canonicalJson(Map<String, Object?> value) =>
    jsonEncode(_sortJson(value));

Object? _sortJson(Object? value) => switch (value) {
  Map map => {
    for (final key in map.keys.cast<String>().toList()..sort())
      key: _sortJson(map[key]),
  },
  List list => list.map(_sortJson).toList(),
  _ => value,
};

final unifiedSearchHistoryProvider =
    StateNotifierProvider<
      UnifiedSearchHistoryNotifier,
      UnifiedSearchHistoryState
    >((ref) => UnifiedSearchHistoryNotifier());

import 'dart:async';

import '../models/audio_track.dart';
import '../models/automatic_marking_event.dart';

/// Account-local completion history and serialized online review mutations.
class AutomaticWorkMarkingService {
  AutomaticWorkMarkingService({
    required this.account,
    required this.fetchProgress,
    required this.writeProgress,
    required this.persist,
    required this.onChanged,
    required this.onConflict,
    required this.onSynced,
    required this.onError,
    Map<String, dynamic>? saved,
    this.enabled = false,
  }) : _accounts = Map<String, dynamic>.from(saved ?? {}) {
    for (final owner in _accounts.keys) {
      for (final id in _map(_data(owner), 'pending').keys) {
        _blockedPending.add(_key(owner, int.parse(id)));
      }
    }
  }

  final String? Function() account;

  /// When fresh is false, read only the current account's local cache.
  final Future<String?> Function(int workId, bool fresh) fetchProgress;
  final Future<void> Function(int workId, String progress) writeProgress;
  final Future<void> Function(Map<String, dynamic>) persist;
  final void Function() onChanged;
  final void Function() onConflict;
  final void Function() onSynced;
  final void Function(Object) onError;
  final Map<String, dynamic> _accounts;
  Future<void> _tail = Future.value();
  Future<void> _persistTail = Future.value();
  Future<void> _localTail = Future.value();
  final Map<String, int> _intents = {};
  final Set<String> _blockedPending = {};
  String _key(String owner, int id) => '$owner/$id';
  bool enabled;
  int _generation = 0;
  final Map<String, int> _viewRevisions = {};
  void _touch(String owner, int id) {
    final key = _key(owner, id);
    _viewRevisions[key] = (_viewRevisions[key] ?? 0) + 1;
  }

  bool _disposed = false;

  int _revision(String owner, int id) =>
      (_map(_data(owner), 'revisions')['$id'] as int?) ?? 0;

  Map<String, dynamic> _data(String owner) =>
      _accounts.putIfAbsent(owner, () => <String, dynamic>{})
          as Map<String, dynamic>;

  Map<String, dynamic> _map(Map<String, dynamic> data, String key) =>
      data.putIfAbsent(key, () => <String, dynamic>{}) as Map<String, dynamic>;

  List<dynamic> _list(Map<String, dynamic> data, String key) =>
      data.putIfAbsent(key, () => <dynamic>[]) as List<dynamic>;

  String? progressFor(int id, String? fallback) {
    if (!enabled) return fallback;
    final owner = account();
    if (owner == null || id < 0) return fallback;
    final pending = _map(_data(owner), 'pending');
    final visible = _map(_data(owner), 'visible');
    final key = '$id';
    if (pending.containsKey(key)) return pending[key] as String?;
    return visible.containsKey(key) ? visible[key] as String? : fallback;
  }

  void observeProgress(int id, String? progress) {
    if (!enabled) return;
    final owner = account();
    if (owner == null || id < 0) return;
    _map(_data(owner), 'known')['$id'] = progress;
  }

  ({String? owner, int revision}) refreshSnapshot(int id) {
    final owner = enabled ? account() : null;
    return (
      owner: owner,
      revision: owner == null ? 0 : _viewRevisions[_key(owner, id)] ?? 0,
    );
  }

  void refreshedProgress(
    int id,
    String? progress, {
    required ({String? owner, int revision}) snapshot,
  }) {
    if (!enabled) return;
    final owner = account();
    if (owner == null ||
        snapshot.owner != owner ||
        snapshot.revision != (_viewRevisions[_key(owner, id)] ?? 0)) {
      return;
    }
    final pending = _map(_data(owner), 'pending');
    final discarded = pending.remove('$id') != null;
    _blockedPending.remove(_key(owner, id));
    _intents[_key(owner, id)] = (_intents[_key(owner, id)] ?? 0) + 1;
    _map(_data(owner), 'known')['$id'] = progress;
    _map(_data(owner), 'visible')['$id'] = progress;
    _touch(owner, id);
    unawaited(_save().catchError(onError));
    onChanged();
    if (discarded) onConflict();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _tail.then((_) async {
      if (!_disposed) await operation();
    });
    _tail = next.catchError((Object error) {
      onError(error);
    });
    return next;
  }

  Future<void> _save() {
    final next = _persistTail.then((_) => persist(_accounts));
    _persistTail = next.catchError((Object error) {
      onError(error);
    });
    return next;
  }

  Future<void> setEnabled(bool value) {
    enabled = value;
    ++_generation;
    if (!value) {
      for (final raw in _accounts.values) {
        final data = raw as Map<String, dynamic>;
        _map(data, 'pending').clear();
        _map(data, 'visible').clear();
        _map(data, 'direct').clear();
        _list(data, 'suppressed').clear();
      }
      _blockedPending.clear();
    }
    onChanged();
    return _save();
  }

  Future<void> clearCompletionHistory({String? owner}) {
    final selectedOwner = owner ?? account();
    if (selectedOwner == null) return Future.value();
    _list(_data(selectedOwner), 'completed').clear();
    return _save();
  }

  /// Manual edits win over queued/in-flight automation, including deletion.
  Future<void> manualUpdate(
    int id,
    String? progress,
    Future<void> Function() write,
  ) {
    final owner = account();
    if (owner == null) {
      return Future.error(
        StateError('Audio account changed or is not signed in'),
      );
    }
    if (!enabled) {
      return _enqueue(() async {
        if (account() != owner) throw StateError('Audio account changed');
        await write();
      });
    }
    _blockedPending.remove(_key(owner, id));
    _map(_data(owner), 'revisions')['$id'] = _revision(owner, id) + 1;
    _touch(owner, id);
    final suppressed = _list(_data(owner), 'suppressed');
    if (!suppressed.contains(id)) suppressed.add(id);
    _map(_data(owner), 'pending').remove('$id');
    _map(_data(owner), 'visible').remove('$id');
    onChanged();
    return _enqueue(() async {
      if (account() != owner) throw StateError('Audio account changed');
      await write();
      _touch(owner, id);
      final data = _data(owner);
      _map(data, 'known')['$id'] = progress;
      _map(data, 'visible')['$id'] = progress;
      await _save();
      onChanged();
    });
  }

  Future<void> addedToPlaylist(int id) => _change(id, _MarkAction.add);

  Future<void> handle(AutomaticMarkingEvent event) {
    final owner = account();
    if (owner == null) return Future.value();
    final generation = _generation;
    final data = _data(owner);
    if (data['queueId'] != event.queueId) {
      data['queueId'] = event.queueId;
      _list(data, 'done').clear();
      _map(data, 'direct').clear();
    }
    if (!enabled) return _save();
    final actions = <(int, _MarkAction)>[];
    final direct = _map(data, 'direct');
    final track = event.track;
    switch (event.type) {
      case AutomaticMarkingEventType.replace:
      case AutomaticMarkingEventType.added:
        for (final item in event.tracks) {
          direct[item.id] = _revision(owner, item.workId ?? 0);
        }
        for (final id
            in event.tracks
                .map((item) => item.workId)
                .whereType<int>()
                .toSet()) {
          actions.add((id, _MarkAction.add));
        }
      case AutomaticMarkingEventType.selected:
        if (track != null) {
          direct[track.id] = _revision(owner, track.workId ?? 0);
        }
      case AutomaticMarkingEventType.started:
        if (track?.workId == null) break;
        final selectionRevision = direct.remove(track!.id);
        final selected =
            selectionRevision != null &&
            selectionRevision == _revision(owner, track.workId!);
        if (selected) _list(data, 'suppressed').remove(track.workId);
        final completed = _trackKey(track);
        final heard =
            completed != null && _list(data, 'completed').contains(completed);
        actions.add((
          track.workId!,
          selected && heard
              ? _MarkAction.replay
              : selected
              ? _MarkAction.selected
              : _MarkAction.start,
        ));
      case AutomaticMarkingEventType.completed:
        if (track?.workId == null || track!.workId! < 0) break;
        final completed = _trackKey(track);
        if (completed != null &&
            !_list(data, 'completed').contains(completed)) {
          _list(data, 'completed').add(completed);
        }
        if (!_list(data, 'done').contains(track.id)) {
          _list(data, 'done').add(track.id);
        }
        _finishActions(data, event.queue, actions, track.workId);
      case AutomaticMarkingEventType.removed:
        _finishActions(data, event.queue, actions, track?.workId);
      case AutomaticMarkingEventType.restore:
        break;
    }
    // Local state never waits for a slow request from a previous track.
    final saved = _save();
    final operations = actions.map(
      (entry) => _prepareAction(owner, entry.$1, entry.$2, generation),
    );
    return Future.wait<void>([saved, ...operations]).then((_) {});
  }

  void _finishActions(
    Map<String, dynamic> data,
    List<AudioTrack> queue,
    List<(int, _MarkAction)> actions,
    int? id,
  ) {
    if (id == null || id < 0) return;
    final done = _list(data, 'done');
    final tracks = queue.where((item) => item.workId == id);
    if (tracks.isNotEmpty && tracks.every((item) => done.contains(item.id))) {
      actions.add((id, _MarkAction.finish));
    }
  }

  String? _trackKey(AudioTrack track) {
    final hash = track.hash;
    return hash == null || hash.isEmpty ? null : '${track.workId}/$hash';
  }

  Future<void> _change(int id, _MarkAction action) {
    final owner = account();
    if (!enabled || owner == null) return Future.value();
    return _prepareAction(owner, id, action, _generation);
  }

  String? _next(_MarkAction action, String? current) => switch (action) {
    _MarkAction.add => current ?? 'marked',
    _MarkAction.start =>
      current == 'listened' || current == 'replay' ? current : 'listening',
    _MarkAction.selected => current == 'replay' ? current : 'listening',
    _MarkAction.replay =>
      current == 'listened' || current == 'replay' ? 'replay' : 'listening',
    _MarkAction.finish => current == 'replay' ? current : 'listened',
  };

  bool _valid(String owner, int id, int generation, int manualRevision) =>
      !_disposed &&
      enabled &&
      account() == owner &&
      generation == _generation &&
      manualRevision == _revision(owner, id) &&
      !_list(_data(owner), 'suppressed').contains(id);

  Future<void> _prepareAction(
    String owner,
    int id,
    _MarkAction action,
    int generation,
  ) {
    if (id < 0) return Future.value();
    final manualRevision = _revision(owner, id);
    Future<void> remote = Future.value();
    final local = _localTail.then<void>((_) async {
      if (!_valid(owner, id, generation, manualRevision)) return;
      final key = _key(owner, id);
      final data = _data(owner);
      final pending = _map(data, 'pending');
      final known = _map(data, 'known');
      final hadPending = pending.containsKey('$id');
      var hasBaseline = hadPending || known.containsKey('$id');
      String? baseline = hadPending
          ? pending['$id'] as String?
          : known['$id'] as String?;
      if (!hasBaseline) {
        try {
          baseline = await fetchProgress(id, false);
          hasBaseline = true;
        } catch (_) {
          /* No account-local review evidence. */
        }
      }
      if (!_valid(owner, id, generation, manualRevision)) return;
      final desired = hasBaseline ? _next(action, baseline) : null;
      if (hadPending && desired == baseline) return;
      final intent = (_intents[key] ?? 0) + 1;
      _intents[key] = intent;
      if (hasBaseline) known.putIfAbsent('$id', () => baseline);
      if (desired != null && desired != baseline) {
        _touch(owner, id);
        pending['$id'] = desired;
        _map(data, 'visible')['$id'] = desired;
        onChanged();
        await _save();
      }
      remote = _enqueue(
        () => _apply(
          owner,
          id,
          action,
          generation,
          manualRevision,
          intent,
          hadPending ? desired : null,
        ),
      );
    });
    _localTail = local.catchError(onError);
    return local.then((_) => remote);
  }

  Future<void> _apply(
    String owner,
    int id,
    _MarkAction action,
    int generation,
    int manualRevision,
    int intent,
    String? dependentProgress,
  ) async {
    final key = _key(owner, id);
    bool valid() =>
        _valid(owner, id, generation, manualRevision) &&
        _intents[key] == intent;
    if (!valid() || _blockedPending.contains(key)) return;
    final data = _data(owner);
    final pending = _map(data, 'pending');
    final known = _map(data, 'known');
    String? current;
    try {
      current = await fetchProgress(id, true);
    } catch (_) {
      if (valid()) {
        if (pending.containsKey('$id')) {
          _blockedPending.add(key);
        } else {
          onConflict();
        }
      }
      return;
    }
    if (!valid()) return;
    known['$id'] = current;
    final next = action == _MarkAction.add && current != null
        ? current
        : current == 'replay'
        ? current
        : dependentProgress ?? _next(action, current);
    if (next == null || next == current) {
      pending.remove('$id');
      _map(data, 'visible')['$id'] = current;
      _touch(owner, id);
      await _save();
      onChanged();
      return;
    }
    if (pending['$id'] != next) {
      _touch(owner, id);
      pending['$id'] = next;
      _map(data, 'visible')['$id'] = next;
      onChanged();
    }
    await _save();
    if (!valid()) return;
    _blockedPending.add(key);
    try {
      await writeProgress(id, next);
      // A newer local intent can follow a confirmed write, but never an uncertain one.
      _blockedPending.remove(key);
      if (!_valid(owner, id, generation, manualRevision)) return;
      known['$id'] = next;
      if (_intents[key] == intent) pending.remove('$id');
      _touch(owner, id);
      await _save();
      onSynced();
    } catch (_) {
      // An uncertain mutation stays local until a read can discard it safely.
    }
  }

  /// Current review APIs have no conditional write. Never replay an offline PUT.
  Future<void> reconcilePending() {
    final owner = account();
    if (!enabled || owner == null) return Future.value();
    return _enqueue(() async {
      if (account() != owner) return;
      final data = _data(owner);
      final pending = _map(data, 'pending');
      var discarded = false;
      for (final key in pending.keys.toList()) {
        final id = int.parse(key);
        final snapshot = refreshSnapshot(id);
        final generation = _generation;
        try {
          final current = await fetchProgress(id, true);
          if (!enabled || generation != _generation || account() != owner) {
            return;
          }
          if (!pending.containsKey(key) ||
              snapshot.revision != (_viewRevisions[_key(owner, id)] ?? 0)) {
            continue;
          }
          _map(data, 'known')[key] = current;
          _touch(owner, id);
          _map(data, 'visible')[key] = current;
          pending.remove(key);
          _blockedPending.remove(_key(owner, id));
          _intents[_key(owner, id)] = (_intents[_key(owner, id)] ?? 0) + 1;
          discarded = true;
        } catch (_) {
          break;
        }
      }
      if (discarded) {
        await _save();
        onChanged();
        onConflict();
      }
    });
  }

  void dispose() {
    _disposed = true;
    ++_generation;
  }
}

enum _MarkAction { add, start, selected, replay, finish }

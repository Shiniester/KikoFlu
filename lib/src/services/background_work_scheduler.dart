import 'dart:async';

enum BackgroundWorkPriority {
  maintenance(0),
  startup(1),
  userInitiated(2);

  const BackgroundWorkPriority(this.weight);

  final int weight;
}

/// Serializes disk-heavy work and deduplicates jobs with the same key.
///
/// The scheduler intentionally runs one job at a time. This prevents cache,
/// download, and subtitle scans from competing for storage bandwidth while the
/// UI is becoming interactive. Higher-priority queued work is selected first;
/// an already-running job is allowed to finish safely.
class BackgroundWorkScheduler {
  BackgroundWorkScheduler();

  static final BackgroundWorkScheduler instance = BackgroundWorkScheduler();

  final List<_QueuedBackgroundWork<dynamic>> _queue = [];
  final Map<String, Future<dynamic>> _jobsByKey = {};
  final StreamController<bool> _busyController =
      StreamController<bool>.broadcast();

  bool _isDraining = false;
  int _sequence = 0;

  bool get isBusy => _isDraining || _queue.isNotEmpty;
  Stream<bool> get busyStream => _busyController.stream.distinct();

  Future<T> schedule<T>({
    required String key,
    required Future<T> Function() task,
    BackgroundWorkPriority priority = BackgroundWorkPriority.maintenance,
  }) {
    final existing = _jobsByKey[key];
    if (existing != null) return existing.then((value) => value as T);

    final completer = Completer<T>();
    final work = _QueuedBackgroundWork<T>(
      key: key,
      priority: priority,
      sequence: _sequence++,
      task: task,
      completer: completer,
    );
    _queue.add(work);
    _jobsByKey[key] = completer.future;
    _notifyBusy();
    unawaited(_drain());
    return completer.future;
  }

  Future<void> whenIdle() async {
    while (isBusy) {
      await busyStream.firstWhere((busy) => !busy);
    }
  }

  Future<void> _drain() async {
    if (_isDraining) return;
    _isDraining = true;
    _notifyBusy();
    try {
      while (_queue.isNotEmpty) {
        _queue.sort((a, b) {
          final priority = b.priority.weight.compareTo(a.priority.weight);
          return priority != 0 ? priority : a.sequence.compareTo(b.sequence);
        });
        final work = _queue.removeAt(0);
        try {
          await work.run();
        } finally {
          _jobsByKey.remove(work.key);
        }
      }
    } finally {
      _isDraining = false;
      _notifyBusy();
    }
  }

  void _notifyBusy() {
    if (!_busyController.isClosed) _busyController.add(isBusy);
  }

  Future<void> dispose() async {
    await whenIdle();
    await _busyController.close();
  }
}

class _QueuedBackgroundWork<T> {
  const _QueuedBackgroundWork({
    required this.key,
    required this.priority,
    required this.sequence,
    required this.task,
    required this.completer,
  });

  final String key;
  final BackgroundWorkPriority priority;
  final int sequence;
  final Future<T> Function() task;
  final Completer<T> completer;

  Future<void> run() async {
    try {
      completer.complete(await task());
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
  }
}

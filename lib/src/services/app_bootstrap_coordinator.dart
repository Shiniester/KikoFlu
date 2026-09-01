import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'background_work_scheduler.dart';

enum BootstrapPhase {
  idle,
  initializing,
  ready,
  failed,
}

@immutable
class BootstrapState {
  const BootstrapState({
    this.phase = BootstrapPhase.idle,
    this.error,
    this.stackTrace,
    this.criticalDuration = Duration.zero,
    this.deferredWorkRunning = false,
  });

  final BootstrapPhase phase;
  final Object? error;
  final StackTrace? stackTrace;
  final Duration criticalDuration;
  final bool deferredWorkRunning;

  bool get isReady => phase == BootstrapPhase.ready;

  BootstrapState copyWith({
    BootstrapPhase? phase,
    Object? error,
    StackTrace? stackTrace,
    Duration? criticalDuration,
    bool? deferredWorkRunning,
    bool clearError = false,
  }) {
    return BootstrapState(
      phase: phase ?? this.phase,
      error: clearError ? null : error ?? this.error,
      stackTrace: clearError ? null : stackTrace ?? this.stackTrace,
      criticalDuration: criticalDuration ?? this.criticalDuration,
      deferredWorkRunning:
          deferredWorkRunning ?? this.deferredWorkRunning,
    );
  }
}

class DeferredBootstrapTask {
  const DeferredBootstrapTask({
    required this.key,
    required this.run,
    this.priority = BackgroundWorkPriority.startup,
  });

  final String key;
  final Future<void> Function() run;
  final BackgroundWorkPriority priority;
}

/// Owns the app's critical bootstrap and post-first-frame maintenance work.
class AppBootstrapCoordinator extends ChangeNotifier {
  AppBootstrapCoordinator({
    required this._initializeCritical,
    List<DeferredBootstrapTask> deferredTasks = const [],
    BackgroundWorkScheduler? scheduler,
  })  : _deferredTasks = List.unmodifiable(deferredTasks),
        _scheduler = scheduler ?? BackgroundWorkScheduler.instance;

  final Future<void> Function() _initializeCritical;
  final List<DeferredBootstrapTask> _deferredTasks;
  final BackgroundWorkScheduler _scheduler;

  BootstrapState _state = const BootstrapState();
  Future<void>? _criticalFuture;
  Future<void>? _deferredFuture;

  BootstrapState get state => _state;

  Future<void> start() {
    if (_state.isReady) return Future.value();
    return _criticalFuture ??= _runCritical();
  }

  Future<void> retry() {
    if (_state.phase != BootstrapPhase.failed) return start();
    _criticalFuture = null;
    return start();
  }

  Future<void> runDeferred() {
    if (!_state.isReady || _deferredTasks.isEmpty) return Future.value();
    return _deferredFuture ??= _runDeferredTasks();
  }

  Future<void> _runCritical() async {
    _setState(
      _state.copyWith(
        phase: BootstrapPhase.initializing,
        clearError: true,
      ),
    );
    final stopwatch = Stopwatch()..start();
    final timeline = developer.TimelineTask()..start('app.bootstrap.critical');
    try {
      await _initializeCritical();
      stopwatch.stop();
      timeline.finish(arguments: {
        'durationMs': stopwatch.elapsedMilliseconds,
      });
      _setState(
        _state.copyWith(
          phase: BootstrapPhase.ready,
          criticalDuration: stopwatch.elapsed,
          clearError: true,
        ),
      );
    } catch (error, stackTrace) {
      stopwatch.stop();
      timeline.finish(arguments: {
        'durationMs': stopwatch.elapsedMilliseconds,
        'failed': true,
      });
      _criticalFuture = null;
      _setState(
        _state.copyWith(
          phase: BootstrapPhase.failed,
          error: error,
          stackTrace: stackTrace,
          criticalDuration: stopwatch.elapsed,
        ),
      );
    }
  }

  Future<void> _runDeferredTasks() async {
    _setState(_state.copyWith(deferredWorkRunning: true));
    try {
      final scheduled = _deferredTasks.map((task) async {
        try {
          await _scheduler.schedule<void>(
            key: task.key,
            priority: task.priority,
            task: () async {
              developer.Timeline.startSync('app.bootstrap.${task.key}');
              try {
                await task.run();
              } finally {
                developer.Timeline.finishSync();
              }
            },
          );
        } catch (error, stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'app bootstrap',
              context: ErrorDescription('running deferred task ${task.key}'),
            ),
          );
        }
      });
      await Future.wait(scheduled);
    } finally {
      _setState(_state.copyWith(deferredWorkRunning: false));
    }
  }

  void _setState(BootstrapState next) {
    _state = next;
    notifyListeners();
  }
}

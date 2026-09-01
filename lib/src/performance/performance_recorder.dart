import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/scheduler.dart';

/// Lightweight Profile-mode instrumentation enabled with
/// `--dart-define=KIKOFLU_PERFORMANCE=true`.
///
/// It is a no-op in normal builds and deliberately records raw frame timings;
/// aggregation and pass/fail decisions live in `tool/performance`.
class PerformanceRecorder {
  PerformanceRecorder._();

  static final PerformanceRecorder instance = PerformanceRecorder._();
  static const bool enabledByEnvironment = bool.fromEnvironment(
    'KIKOFLU_PERFORMANCE',
  );

  final Stopwatch _startupStopwatch = Stopwatch();
  final List<double> _frameTimesMs = [];
  final Map<String, num> _metrics = {};
  bool _active = false;
  bool _timingsCallbackAttached = false;
  bool _interactiveMarked = false;
  String? _activeScenario;
  int _scenarioStartFrameIndex = 0;

  bool get isActive => _active;

  num? metric(String name) => _metrics[name];

  void start({bool force = false}) {
    if (_active) return;
    if (!force && !enabledByEnvironment) return;
    _active = true;
    _startupStopwatch
      ..reset()
      ..start();
    if (!_timingsCallbackAttached) {
      SchedulerBinding.instance.addTimingsCallback(_handleFrameTimings);
      _timingsCallbackAttached = true;
    }
    developer.Timeline.instantSync('performance.appMainStarted');
  }

  void markFirstInteractive() {
    if (!_active || _interactiveMarked) return;
    _interactiveMarked = true;
    _metrics['firstInteractiveMs'] =
        _startupStopwatch.elapsedMicroseconds / 1000;
    developer.Timeline.instantSync(
      'performance.firstInteractive',
      arguments: {'elapsedMs': _metrics['firstInteractiveMs']},
    );
    developer.log(
      'KIKOFLU_PERF firstInteractiveMs=${_metrics['firstInteractiveMs']}',
      name: 'KikoFluPerformance',
    );
  }

  void beginScenario(String name) {
    if (!_active) return;
    if (_activeScenario != null) {
      throw StateError('Performance scenario $_activeScenario is still active');
    }
    _activeScenario = name;
    _scenarioStartFrameIndex = _frameTimesMs.length;
    developer.Timeline.startSync('performance.$name');
  }

  Map<String, num> endScenario() {
    final scenario = _activeScenario;
    if (!_active || scenario == null) return const {};
    developer.Timeline.finishSync();
    _activeScenario = null;

    final frames = _frameTimesMs.sublist(_scenarioStartFrameIndex);
    final metrics = <String, num>{
      '${scenario}FrameP95Ms': _percentile(frames, 0.95),
      '${scenario}JankyFrames': frames
          .where((duration) => duration > 16.7)
          .length,
      '${scenario}FrameCount': frames.length,
    };
    _metrics.addAll(metrics);
    return metrics;
  }

  void recordMetric(String name, num value) {
    if (_active) _metrics[name] = value;
  }

  Map<String, Object?> createRun({
    required int run,
    Map<String, Object?> metadata = const {},
  }) {
    return {
      'run': run,
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'metrics': Map<String, num>.unmodifiable(_metrics),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }

  String emitRun({required int run, Map<String, Object?> metadata = const {}}) {
    final encoded = jsonEncode(createRun(run: run, metadata: metadata));
    developer.log('KIKOFLU_PERF_JSON:$encoded', name: 'KikoFluPerformance');
    return encoded;
  }

  void resetRun() {
    _metrics.clear();
    _frameTimesMs.clear();
    _interactiveMarked = false;
    _activeScenario = null;
    _scenarioStartFrameIndex = 0;
    _startupStopwatch
      ..reset()
      ..start();
  }

  void _handleFrameTimings(List<FrameTiming> timings) {
    if (!_active) return;
    for (final timing in timings) {
      _frameTimesMs.add(timing.totalSpan.inMicroseconds / 1000);
    }
  }

  static double _percentile(List<double> values, double percentile) {
    if (values.isEmpty) return 0;
    final sorted = List<double>.of(values)..sort();
    final index = ((sorted.length - 1) * percentile).ceil();
    return sorted[index.clamp(0, sorted.length - 1)];
  }
}

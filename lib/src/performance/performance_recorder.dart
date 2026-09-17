import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
  final List<_FrameTimingSample> _frameTimings = [];
  final Map<String, num> _metrics = {};
  final Map<int, _PlaybackTiming> _pendingPlayback = {};
  final List<Map<String, Object?>> _playbackTimings = [];
  bool _active = false;
  bool _timingsCallbackAttached = false;
  bool _interactiveMarked = false;
  String? _activeScenario;
  int _scenarioStartFrameTimestampUs = 0;
  int _timingBatchCount = 0;
  int _nextPlaybackRequestId = 0;
  double _refreshRateHz = 60;
  final List<_ScenarioWindow> _scenarioWindows = [];
  int? _debugFrameTimestampUs;

  bool get isActive => _active;

  num? metric(String name) => _metrics[name];

  /// The display refresh rate used for the current run's frame budget.
  ///
  /// The default only makes host/widget tests deterministic. Android Profile
  /// callers should set this from the active display before recording a
  /// scenario because the same device may be switched between 60 and 90 Hz.
  double get refreshRateHz => _refreshRateHz;

  double get frameBudgetMs => 1000 / _refreshRateHz;

  List<Map<String, Object?>> get playbackTimings =>
      List<Map<String, Object?>>.unmodifiable(_playbackTimings);

  void setRefreshRate(double refreshRateHz) {
    if (!_active || !refreshRateHz.isFinite || refreshRateHz <= 0) return;
    _refreshRateHz = refreshRateHz;
    _metrics['displayRefreshRateHz'] = refreshRateHz;
    _metrics['frameBudgetMs'] = frameBudgetMs;
  }

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
    _scenarioStartFrameTimestampUs = _currentSystemFrameTimestampUs;
    developer.Timeline.startSync('performance.$name');
  }

  Map<String, num> endScenario() {
    final scenario = _activeScenario;
    if (!_active || scenario == null) return const {};
    developer.Timeline.finishSync();
    _activeScenario = null;
    final window = _ScenarioWindow(
      name: scenario,
      startFrameTimestampUs: _scenarioStartFrameTimestampUs,
      endFrameTimestampUs: _currentSystemFrameTimestampUs,
      frameBudgetMs: frameBudgetMs,
    );
    _scenarioWindows.add(window);
    final metrics = _metricsForScenario(window);
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
    completePendingPlaybackRequests();
    for (final window in _scenarioWindows) {
      _metrics.addAll(_metricsForScenario(window));
    }
    return {
      'run': run,
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'metrics': Map<String, num>.unmodifiable(_metrics),
      if (_scenarioWindows.isNotEmpty)
        'frameSamples': {
          for (final window in _scenarioWindows)
            window.name: [
              for (final sample in _framesForScenario(window))
                [sample.uiMs, sample.rasterMs],
            ],
        },
      if (_playbackTimings.isNotEmpty) 'playbackTimings': playbackTimings,
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
    _frameTimings.clear();
    _pendingPlayback.clear();
    _playbackTimings.clear();
    _interactiveMarked = false;
    _activeScenario = null;
    _scenarioStartFrameTimestampUs = 0;
    _timingBatchCount = 0;
    _nextPlaybackRequestId = 0;
    _refreshRateHz = 60;
    _scenarioWindows.clear();
    _debugFrameTimestampUs = null;
    _startupStopwatch
      ..reset()
      ..start();
  }

  /// Starts a measurement for one source-switch request. This is intentionally
  /// a recorder concern: the production load path only calls it when the
  /// Profile instrumentation build is enabled.
  int? beginPlaybackRequest(String trackId, {String? mode}) {
    if (!_active) return null;
    final requestId = ++_nextPlaybackRequestId;
    _pendingPlayback[requestId] = _PlaybackTiming(
      requestId: requestId,
      trackId: trackId,
      mode: mode,
      requestMs: _elapsedMs,
    );
    return requestId;
  }

  void markPlaybackPhase(int? requestId, String phase) {
    if (!_active || requestId == null) return;
    final timing = _pendingPlayback[requestId];
    if (timing == null) return;
    timing.mark(phase, _elapsedMs);
  }

  void markFirstPlaybackPosition(int? requestId) {
    if (!_active || requestId == null) return;
    final timing = _pendingPlayback[requestId];
    if (timing == null || !timing.hasPhase('ready')) return;
    timing.mark('firstPosition', _elapsedMs);
    completePlaybackRequest(requestId);
  }

  /// Completes a request at the first non-zero position, or at the end of a
  /// test when a source was ready but never started playing.
  void completePlaybackRequest(int? requestId, {bool incomplete = false}) {
    if (!_active || requestId == null) return;
    final timing = _pendingPlayback.remove(requestId);
    if (timing == null) return;
    _playbackTimings.add(timing.toJson(incomplete: incomplete));
  }

  void completePendingPlaybackRequests() {
    final pending = List<int>.of(_pendingPlayback.keys);
    for (final requestId in pending) {
      completePlaybackRequest(requestId, incomplete: true);
    }
  }

  double get _elapsedMs => _startupStopwatch.elapsedMicroseconds / 1000;

  int get _currentSystemFrameTimestampUs =>
      _debugFrameTimestampUs ??
      SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;

  @visibleForTesting
  void debugSetFrameTimestamp(int timestampUs) {
    _debugFrameTimestampUs = timestampUs;
  }

  @visibleForTesting
  void debugRecordFrameTiming({
    required int timestampUs,
    required double uiMs,
    required double rasterMs,
    required double totalSpanMs,
  }) {
    if (!_active) return;
    _timingBatchCount++;
    _frameTimings.add(
      _FrameTimingSample(
        timestampUs: timestampUs,
        timingBatch: _timingBatchCount,
        uiMs: uiMs,
        rasterMs: rasterMs,
        totalSpanMs: totalSpanMs,
      ),
    );
  }

  void _handleFrameTimings(List<FrameTiming> timings) {
    if (!_active) return;
    _timingBatchCount++;
    for (final timing in timings) {
      _frameTimings.add(
        _FrameTimingSample(
          timestampUs: timing.timestampInMicroseconds(ui.FramePhase.buildStart),
          timingBatch: _timingBatchCount,
          uiMs: timing.buildDuration.inMicroseconds / 1000,
          rasterMs: timing.rasterDuration.inMicroseconds / 1000,
          totalSpanMs: timing.totalSpan.inMicroseconds / 1000,
        ),
      );
    }
  }

  List<_FrameTimingSample> _framesForScenario(_ScenarioWindow window) {
    return _frameTimings
        .where(
          (sample) =>
              sample.timestampUs > window.startFrameTimestampUs &&
              sample.timestampUs <= window.endFrameTimestampUs,
        )
        .toList(growable: false);
  }

  Map<String, num> _metricsForScenario(_ScenarioWindow window) {
    final frames = _framesForScenario(window);
    final renderTimes = frames
        .map((sample) => math.max(sample.uiMs, sample.rasterMs))
        .toList(growable: false);
    final uiTimes = frames.map((sample) => sample.uiMs).toList(growable: false);
    final rasterTimes = frames
        .map((sample) => sample.rasterMs)
        .toList(growable: false);
    final totalSpans = frames
        .map((sample) => sample.totalSpanMs)
        .toList(growable: false);
    final jankyFrames = frames
        .where(
          (sample) =>
              math.max(sample.uiMs, sample.rasterMs) > window.frameBudgetMs,
        )
        .length;
    return {
      '${window.name}FrameP95Ms': _percentile(renderTimes, 0.95),
      '${window.name}UiP95Ms': _percentile(uiTimes, 0.95),
      '${window.name}RasterP95Ms': _percentile(rasterTimes, 0.95),
      '${window.name}TotalSpanP95Ms': _percentile(totalSpans, 0.95),
      '${window.name}FrameBudgetMs': window.frameBudgetMs,
      '${window.name}JankyFrames': jankyFrames,
      '${window.name}FrameCount': frames.length,
      '${window.name}TimingBatches': frames
          .map((sample) => sample.timingBatch)
          .toSet()
          .length,
    };
  }

  static double _percentile(List<double> values, double percentile) {
    if (values.isEmpty) return 0;
    final sorted = List<double>.of(values)..sort();
    final index = ((sorted.length - 1) * percentile).ceil();
    return sorted[index.clamp(0, sorted.length - 1)];
  }
}

class _FrameTimingSample {
  const _FrameTimingSample({
    required this.timestampUs,
    required this.timingBatch,
    required this.uiMs,
    required this.rasterMs,
    required this.totalSpanMs,
  });

  final int timestampUs;
  final int timingBatch;
  final double uiMs;
  final double rasterMs;
  final double totalSpanMs;
}

class _ScenarioWindow {
  const _ScenarioWindow({
    required this.name,
    required this.startFrameTimestampUs,
    required this.endFrameTimestampUs,
    required this.frameBudgetMs,
  });

  final String name;
  final int startFrameTimestampUs;
  final int endFrameTimestampUs;
  final double frameBudgetMs;
}

class _PlaybackTiming {
  _PlaybackTiming({
    required this.requestId,
    required this.trackId,
    required this.mode,
    required this.requestMs,
  });

  final int requestId;
  final String trackId;
  final String? mode;
  final double requestMs;
  final Map<String, double> _phases = {};

  void mark(String phase, double elapsedMs) {
    _phases.putIfAbsent(phase, () => elapsedMs);
  }

  bool hasPhase(String phase) => _phases.containsKey(phase);

  Map<String, Object?> toJson({required bool incomplete}) {
    double? requestTo(String phase) {
      final elapsed = _phases[phase];
      return elapsed == null ? null : elapsed - requestMs;
    }

    return {
      'requestId': requestId,
      'trackId': trackId,
      if (mode != null) 'mode': mode,
      'requestMs': requestMs,
      if (requestTo('sourcePrepared') != null)
        'requestToPreparedMs': requestTo('sourcePrepared'),
      if (requestTo('setFilePathStart') != null)
        'requestToSetFilePathStartMs': requestTo('setFilePathStart'),
      if (requestTo('setFilePathEnd') != null)
        'requestToSetFilePathEndMs': requestTo('setFilePathEnd'),
      if (requestTo('ready') != null) 'requestToReadyMs': requestTo('ready'),
      if (requestTo('firstPosition') != null)
        'requestToFirstPositionMs': requestTo('firstPosition'),
      'sourcePreparationMs': _phaseDuration('sourcePrepared'),
      'setFilePathMs': _phaseDurationBetween(
        'setFilePathStart',
        'setFilePathEnd',
      ),
      'readyAfterSetFilePathMs': _phaseDurationBetween(
        'setFilePathEnd',
        'ready',
      ),
      'firstPositionAfterReadyMs': _phaseDurationBetween(
        'ready',
        'firstPosition',
      ),
      'incomplete': incomplete,
    };
  }

  double? _phaseDuration(String phase) {
    final elapsed = _phases[phase];
    return elapsed == null ? null : elapsed - requestMs;
  }

  double? _phaseDurationBetween(String start, String end) {
    final startMs = _phases[start];
    final endMs = _phases[end];
    return startMs == null || endMs == null ? null : endMs - startMs;
  }
}

import 'package:flutter_test/flutter_test.dart';

import '../tool/performance/src/performance_comparison.dart';

void main() {
  test('passes strict five-run reports meeting every threshold', () {
    final baseline = _report(
      label: 'baseline',
      revision: '1111111111111111111111111111111111111111',
      metrics: _baselineMetrics,
    );
    final candidate = _report(
      label: 'candidate',
      revision: '2222222222222222222222222222222222222222',
      metrics: _passingMetrics,
    );

    final result = comparePerformanceReports(baseline, candidate);

    expect(result.passed, isTrue);
    expect(result.errors, isEmpty);
    expect(result.fixtureHash, _fixtureHash);
  });

  test('rejects legacy schema and missing revision/fixture metadata', () {
    final baseline = _report(
      label: '',
      revision: '',
      metrics: _baselineMetrics,
      schemaVersion: 1,
      fixture: const {},
    );
    final candidate = _report(
      label: 'candidate',
      revision: '2222222',
      metrics: _passingMetrics,
    );

    final result = comparePerformanceReports(baseline, candidate);

    expect(result.passed, isFalse);
    expect(result.errors, contains(contains('schemaVersion 3')));
    expect(result.errors, contains(contains('Git SHA')));
    expect(result.errors, contains(contains('已哈希数据集')));
  });

  test('rejects schema 3 reports missing incremental peak PSS', () {
    final baseline = _report(
      label: 'baseline',
      revision: '1111111',
      metrics: Map<String, double>.of(_baselineMetrics)
        ..remove('scanPeakPssDeltaMb'),
    );
    final candidate = _report(
      label: 'candidate',
      revision: '2222222',
      metrics: _passingMetrics,
    );

    final result = comparePerformanceReports(baseline, candidate);

    expect(result.passed, isFalse);
    expect(result.errors, contains('缺少验收指标: scanPeakPssDeltaMb'));
  });

  test('fails missing runs, hot runs, and progress latency breaches', () {
    final baseline = _report(
      label: 'baseline',
      revision: '1111111',
      metrics: _baselineMetrics,
    );
    final candidate = _report(
      label: 'candidate',
      revision: '2222222',
      metrics: {..._passingMetrics, 'downloadProgressLatencyMs': 800},
      runs: 4,
      thermalStatus: '3',
    );

    final result = comparePerformanceReports(baseline, candidate);

    expect(result.passed, isFalse);
    expect(result.errors, contains(contains('至少需要 5 轮')));
    expect(result.errors, contains(contains('thermal')));
    expect(
      result.metrics
          .firstWhere((metric) => metric.name == 'downloadProgressLatencyMs')
          .passed,
      isFalse,
    );
  });

  test(
    'allows frame budget but requires playback diagnostics to stay zero',
    () {
      final baseline = _report(
        label: 'baseline',
        revision: '1111111',
        metrics: {..._baselineMetrics, 'homeFrameP95Ms': 30},
      );
      final candidate = _report(
        label: 'candidate',
        revision: '2222222',
        metrics: {
          ..._passingMetrics,
          'homeFrameP95Ms': 16.7,
          'cacheErrorCount': 1,
        },
      );

      final result = comparePerformanceReports(baseline, candidate);
      expect(
        result.metrics
            .firstWhere((metric) => metric.name == 'homeFrameP95Ms')
            .passed,
        isTrue,
      );
      expect(
        result.metrics
            .firstWhere((metric) => metric.name == 'cacheErrorCount')
            .passed,
        isFalse,
      );
    },
  );

  test('allows baseline diagnostics when candidate returns to zero', () {
    final baseline = _report(
      label: 'baseline',
      revision: '1111111',
      metrics: {
        ..._baselineMetrics,
        'playbackUnexpectedBufferingCount': 2,
        'playbackErrorCount': 1,
        'cacheErrorCount': 3,
      },
    );
    final candidate = _report(
      label: 'candidate',
      revision: '2222222',
      metrics: _passingMetrics,
    );

    final result = comparePerformanceReports(baseline, candidate);

    expect(result.passed, isTrue);
  });
}

const _fixtureHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const _baselineMetrics = <String, double>{
  'coldStartMs': 1000,
  'firstInteractiveMs': 1200,
  'homeFrameP95Ms': 28,
  'playerFrameP95Ms': 24,
  'scanDurationMs': 1000,
  'scanPeakPssMb': 500,
  'scanPeakPssDeltaMb': 200,
  'zipImportDurationMs': 5000,
  'zipPeakPssMb': 500,
  'zipPeakPssDeltaMb': 300,
  'downloadListBuilds': 1000,
  'downloadTemporaryAllocations': 10000,
  'trackSwitchMedianMs': 200,
  'trackSwitchP95Ms': 300,
  'homeJankyFrames': 5,
  'playerJankyFrames': 3,
  'playbackUnexpectedBufferingCount': 0,
  'playbackErrorCount': 0,
  'cacheErrorCount': 0,
  'downloadProgressLatencyMs': 600,
  'playbackDurationMinutes': 30,
  'realTrackSwitches': 50,
  'startupPeakPssMb': 200,
};

const _passingMetrics = <String, double>{
  'coldStartMs': 700,
  'firstInteractiveMs': 820,
  'homeFrameP95Ms': 16.5,
  'playerFrameP95Ms': 15,
  'scanDurationMs': 700,
  'scanPeakPssMb': 510,
  'scanPeakPssDeltaMb': 140,
  'zipImportDurationMs': 3500,
  'zipPeakPssMb': 490,
  'zipPeakPssDeltaMb': 200,
  'downloadListBuilds': 700,
  'downloadTemporaryAllocations': 7000,
  'trackSwitchMedianMs': 120,
  'trackSwitchP95Ms': 200,
  'homeJankyFrames': 4,
  'playerJankyFrames': 2,
  'playbackUnexpectedBufferingCount': 0,
  'playbackErrorCount': 0,
  'cacheErrorCount': 0,
  'downloadProgressLatencyMs': 500,
  'playbackDurationMinutes': 30,
  'realTrackSwitches': 50,
  'startupPeakPssMb': 195,
};

PerformanceReport _report({
  required String label,
  required String revision,
  required Map<String, double> metrics,
  int schemaVersion = 3,
  int runs = 5,
  String thermalStatus = '1',
  Map<String, Object?> fixture = const {
    'fixtureVersion': 2,
    'contentHash': _fixtureHash,
  },
}) {
  return PerformanceReport(
    schemaVersion: schemaVersion,
    scenario: 'kikoflu-android-profile-v3',
    label: label,
    revision: revision,
    scenarioAdapterVersion: 3,
    device: const {
      'serial': 'device-1',
      'model': 'Pixel',
      'androidVersion': '16',
      'fingerprint': 'google/pixel/fingerprint',
      'buildMode': 'profile',
      'windowAnimationScale': '1.0',
      'transitionAnimationScale': '1.0',
      'animatorDurationScale': '1.0',
    },
    fixture: fixture,
    runs: List.generate(
      runs,
      (index) => PerformanceRun(
        run: index + 1,
        metrics: metrics,
        metadata: {'thermalStatus': thermalStatus},
      ),
    ),
  );
}

import 'dart:convert';

enum PerformanceRuleKind {
  improveBy25Percent,
  improveBy25PercentOrFrameBudget,
  noIncrease,
  noRegressionOver5Percent,
  maximum,
  minimum,
  mustBeZero,
}

class PerformanceMetricRule {
  const PerformanceMetricRule(
    this.name,
    this.kind, {
    this.maximum,
    this.minimum,
  });

  final String name;
  final PerformanceRuleKind kind;
  final double? maximum;
  final double? minimum;
}

const defaultPerformanceRules = <PerformanceMetricRule>[
  PerformanceMetricRule('coldStartMs', PerformanceRuleKind.improveBy25Percent),
  PerformanceMetricRule(
    'firstInteractiveMs',
    PerformanceRuleKind.improveBy25Percent,
  ),
  PerformanceMetricRule(
    'homeFrameP95Ms',
    PerformanceRuleKind.improveBy25PercentOrFrameBudget,
  ),
  PerformanceMetricRule(
    'playerFrameP95Ms',
    PerformanceRuleKind.improveBy25PercentOrFrameBudget,
  ),
  PerformanceMetricRule(
    'scanDurationMs',
    PerformanceRuleKind.improveBy25Percent,
  ),
  PerformanceMetricRule(
    'scanPeakPssDeltaMb',
    PerformanceRuleKind.improveBy25Percent,
  ),
  PerformanceMetricRule(
    'scanPeakPssMb',
    PerformanceRuleKind.noRegressionOver5Percent,
  ),
  PerformanceMetricRule(
    'zipImportDurationMs',
    PerformanceRuleKind.improveBy25Percent,
  ),
  PerformanceMetricRule(
    'zipPeakPssDeltaMb',
    PerformanceRuleKind.improveBy25Percent,
  ),
  PerformanceMetricRule(
    'zipPeakPssMb',
    PerformanceRuleKind.noRegressionOver5Percent,
  ),
  PerformanceMetricRule(
    'downloadListBuilds',
    PerformanceRuleKind.improveBy25Percent,
  ),
  PerformanceMetricRule(
    'downloadTemporaryAllocations',
    PerformanceRuleKind.improveBy25Percent,
  ),
  PerformanceMetricRule(
    'trackSwitchMedianMs',
    PerformanceRuleKind.improveBy25Percent,
  ),
  PerformanceMetricRule(
    'trackSwitchP95Ms',
    PerformanceRuleKind.improveBy25Percent,
  ),
  PerformanceMetricRule('homeJankyFrames', PerformanceRuleKind.noIncrease),
  PerformanceMetricRule('playerJankyFrames', PerformanceRuleKind.noIncrease),
  PerformanceMetricRule(
    'playbackUnexpectedBufferingCount',
    PerformanceRuleKind.mustBeZero,
  ),
  PerformanceMetricRule('playbackErrorCount', PerformanceRuleKind.mustBeZero),
  PerformanceMetricRule('cacheErrorCount', PerformanceRuleKind.mustBeZero),
  PerformanceMetricRule(
    'downloadProgressLatencyMs',
    PerformanceRuleKind.maximum,
    maximum: 750,
  ),
  PerformanceMetricRule(
    'playbackDurationMinutes',
    PerformanceRuleKind.minimum,
    minimum: 30,
  ),
  PerformanceMetricRule(
    'realTrackSwitches',
    PerformanceRuleKind.minimum,
    minimum: 50,
  ),
];

class PerformanceReport {
  const PerformanceReport({
    required this.schemaVersion,
    required this.scenario,
    required this.label,
    required this.revision,
    required this.scenarioAdapterVersion,
    required this.runs,
    this.device = const {},
    this.fixture = const {},
  });

  final int schemaVersion;
  final String scenario;
  final String label;
  final String revision;
  final int scenarioAdapterVersion;
  final List<PerformanceRun> runs;
  final Map<String, Object?> device;
  final Map<String, Object?> fixture;

  factory PerformanceReport.fromJson(Map<String, Object?> json) {
    final rawRuns = json['runs'];
    if (rawRuns is! List) {
      throw const FormatException('Performance report must contain runs');
    }
    return PerformanceReport(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 0,
      scenario: json['scenario']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      revision: json['revision']?.toString() ?? '',
      scenarioAdapterVersion:
          (json['scenarioAdapterVersion'] as num?)?.toInt() ?? 0,
      runs: rawRuns
          .map(
            (run) =>
                PerformanceRun.fromJson(Map<String, Object?>.from(run as Map)),
          )
          .toList(growable: false),
      device: _objectMap(json['device']),
      fixture: _objectMap(json['fixture']),
    );
  }

  factory PerformanceReport.decode(String source) {
    return PerformanceReport.fromJson(
      Map<String, Object?>.from(jsonDecode(source) as Map),
    );
  }

  Map<String, double> medians() {
    final valuesByMetric = <String, List<double>>{};
    for (final run in runs) {
      for (final metric in run.metrics.entries) {
        valuesByMetric.putIfAbsent(metric.key, () => []).add(metric.value);
      }
    }
    return {
      for (final entry in valuesByMetric.entries)
        entry.key: _median(entry.value),
    };
  }
}

class PerformanceRun {
  const PerformanceRun({
    required this.run,
    required this.metrics,
    this.metadata = const {},
  });

  final int run;
  final Map<String, double> metrics;
  final Map<String, Object?> metadata;

  factory PerformanceRun.fromJson(Map<String, Object?> json) {
    final rawMetrics = json['metrics'];
    if (rawMetrics is! Map) {
      throw const FormatException('Each run must contain metrics');
    }
    return PerformanceRun(
      run: (json['run'] as num?)?.toInt() ?? 0,
      metrics: {
        for (final entry in rawMetrics.entries)
          entry.key.toString(): (entry.value as num).toDouble(),
      },
      metadata: _objectMap(json['metadata']),
    );
  }
}

class PerformanceComparison {
  const PerformanceComparison({
    required this.passed,
    required this.metrics,
    required this.errors,
    required this.baselineRevision,
    required this.candidateRevision,
    required this.fixtureHash,
  });

  final bool passed;
  final List<PerformanceMetricComparison> metrics;
  final List<String> errors;
  final String baselineRevision;
  final String candidateRevision;
  final String fixtureHash;

  Map<String, Object?> toJson() => {
    'passed': passed,
    'baselineRevision': baselineRevision,
    'candidateRevision': candidateRevision,
    'fixtureHash': fixtureHash,
    'errors': errors,
    'metrics': metrics.map((metric) => metric.toJson()).toList(),
  };

  String toMarkdown() {
    final buffer = StringBuffer()
      ..writeln('# KikoFlu Android Profile 性能对比')
      ..writeln()
      ..writeln('结果：${passed ? '通过' : '未通过'}')
      ..writeln()
      ..writeln('- Baseline: `$baselineRevision`')
      ..writeln('- Candidate: `$candidateRevision`')
      ..writeln('- Fixture: `$fixtureHash`')
      ..writeln()
      ..writeln('| 指标 | 基线中位数 | 优化后中位数 | 变化 | 门槛 | 结果 |')
      ..writeln('|---|---:|---:|---:|---|---|');
    for (final metric in metrics) {
      final change = metric.changePercent == null
          ? '—'
          : '${metric.changePercent!.toStringAsFixed(1)}%';
      buffer.writeln(
        '| ${metric.name} | ${metric.baseline.toStringAsFixed(2)} | '
        '${metric.candidate.toStringAsFixed(2)} | $change | '
        '${metric.requirement} | ${metric.passed ? '✅' : '❌'} |',
      );
    }
    if (errors.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## 错误')
        ..writeln();
      for (final error in errors) {
        buffer.writeln('- $error');
      }
    }
    return buffer.toString();
  }
}

class PerformanceMetricComparison {
  const PerformanceMetricComparison({
    required this.name,
    required this.baseline,
    required this.candidate,
    required this.requirement,
    required this.passed,
  });

  final String name;
  final double baseline;
  final double candidate;
  final String requirement;
  final bool passed;

  double? get changePercent {
    if (baseline == 0) return null;
    return ((candidate - baseline) / baseline) * 100;
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'baseline': baseline,
    'candidate': candidate,
    'changePercent': changePercent,
    'requirement': requirement,
    'passed': passed,
  };
}

PerformanceComparison comparePerformanceReports(
  PerformanceReport baseline,
  PerformanceReport candidate, {
  List<PerformanceMetricRule> rules = defaultPerformanceRules,
  int requiredRuns = 5,
}) {
  final errors = <String>[];
  if (baseline.schemaVersion < 3 || candidate.schemaVersion < 3) {
    errors.add('严格比较仅接受 schemaVersion 3 或更高版本');
  }
  if (baseline.label != 'baseline' || candidate.label != 'candidate') {
    errors.add('报告标签必须分别为 baseline 与 candidate');
  }
  if (!_validRevision(baseline.revision) ||
      !_validRevision(candidate.revision) ||
      baseline.revision == candidate.revision) {
    errors.add('报告必须包含两个不同且有效的 Git SHA');
  }
  if (baseline.scenario.isEmpty || baseline.scenario != candidate.scenario) {
    errors.add('基线与候选的场景名称不一致');
  }
  if (baseline.scenarioAdapterVersion < 3 ||
      baseline.scenarioAdapterVersion != candidate.scenarioAdapterVersion) {
    errors.add('基线与候选未使用同一稳定场景适配器');
  }
  if (baseline.runs.length < requiredRuns) {
    errors.add('基线只有 ${baseline.runs.length} 轮，至少需要 $requiredRuns 轮');
  }
  if (candidate.runs.length < requiredRuns) {
    errors.add('优化后只有 ${candidate.runs.length} 轮，至少需要 $requiredRuns 轮');
  }
  if (!_sameDevice(baseline.device, candidate.device)) {
    errors.add('基线与优化后报告不是同一设备/构建配置');
  }
  final baselineHash = baseline.fixture['contentHash']?.toString() ?? '';
  final candidateHash = candidate.fixture['contentHash']?.toString() ?? '';
  if (baselineHash.isEmpty ||
      candidateHash.isEmpty ||
      baselineHash != candidateHash ||
      !_sameFixture(baseline.fixture, candidate.fixture)) {
    errors.add('基线与优化后报告未使用同一份已哈希数据集');
  }
  _validateThermalRuns('基线', baseline.runs, errors);
  _validateThermalRuns('候选', candidate.runs, errors);

  final baselineMedians = baseline.medians();
  final candidateMedians = candidate.medians();
  final metricComparisons = <PerformanceMetricComparison>[];
  final evaluatedNames = <String>{};
  for (final rule in rules) {
    evaluatedNames.add(rule.name);
    final baselineValue = baselineMedians[rule.name];
    final candidateValue = candidateMedians[rule.name];
    if (baselineValue == null || candidateValue == null) {
      errors.add('缺少验收指标: ${rule.name}');
      continue;
    }

    final evaluation = _evaluate(rule, baselineValue, candidateValue);
    metricComparisons.add(
      PerformanceMetricComparison(
        name: rule.name,
        baseline: baselineValue,
        candidate: candidateValue,
        requirement: evaluation.requirement,
        passed: evaluation.passed,
      ),
    );
  }

  final sharedMetrics = baselineMedians.keys.toSet()
    ..retainAll(candidateMedians.keys);
  for (final name in sharedMetrics) {
    if (evaluatedNames.contains(name) ||
        name.endsWith('FrameCount') ||
        name.endsWith('EventCount')) {
      continue;
    }
    final evaluation = _evaluate(
      PerformanceMetricRule(name, PerformanceRuleKind.noRegressionOver5Percent),
      baselineMedians[name]!,
      candidateMedians[name]!,
    );
    metricComparisons.add(
      PerformanceMetricComparison(
        name: name,
        baseline: baselineMedians[name]!,
        candidate: candidateMedians[name]!,
        requirement: evaluation.requirement,
        passed: evaluation.passed,
      ),
    );
  }

  return PerformanceComparison(
    passed:
        errors.isEmpty && metricComparisons.every((metric) => metric.passed),
    metrics: metricComparisons,
    errors: errors,
    baselineRevision: baseline.revision,
    candidateRevision: candidate.revision,
    fixtureHash: baselineHash,
  );
}

({bool passed, String requirement}) _evaluate(
  PerformanceMetricRule rule,
  double baseline,
  double candidate,
) {
  switch (rule.kind) {
    case PerformanceRuleKind.improveBy25Percent:
      return (
        passed: baseline == 0 ? candidate <= 0 : candidate <= baseline * 0.75,
        requirement: '至少改善 25%',
      );
    case PerformanceRuleKind.improveBy25PercentOrFrameBudget:
      if (baseline <= 16.7) {
        return (
          passed: candidate <= baseline * 1.05,
          requirement: '基线已达 16.7ms；回退不超过 5%',
        );
      }
      return (
        passed: candidate <= 16.7 || candidate <= baseline * 0.75,
        requirement: '至少改善 25% 或达到 16.7ms',
      );
    case PerformanceRuleKind.noIncrease:
      return (passed: candidate <= baseline, requirement: '不得增加');
    case PerformanceRuleKind.noRegressionOver5Percent:
      return (
        passed: baseline == 0 ? candidate <= 0 : candidate <= baseline * 1.05,
        requirement: '回退不超过 5%',
      );
    case PerformanceRuleKind.maximum:
      final maximum = rule.maximum!;
      final noRegression = baseline == 0
          ? candidate <= 0
          : candidate <= baseline * 1.05;
      return (
        passed: candidate <= maximum && noRegression,
        requirement: '不超过 ${maximum.toStringAsFixed(0)}，且回退不超过 5%',
      );
    case PerformanceRuleKind.minimum:
      final minimum = rule.minimum!;
      return (
        passed: baseline >= minimum && candidate >= minimum,
        requirement: '两版本均不少于 ${minimum.toStringAsFixed(0)}',
      );
    case PerformanceRuleKind.mustBeZero:
      return (
        passed: candidate == 0 && candidate <= baseline,
        requirement: '候选必须为 0，且不得高于基线',
      );
  }
}

void _validateThermalRuns(
  String label,
  List<PerformanceRun> runs,
  List<String> errors,
) {
  for (final run in runs) {
    final raw = run.metadata['thermalStatus']?.toString();
    final status = int.tryParse(raw ?? '');
    if (status == null || status >= 3) {
      errors.add('$label第 ${run.run} 轮 thermal 状态无效或过热');
    }
  }
}

Map<String, Object?> _objectMap(Object? value) {
  return value is Map ? Map<String, Object?>.from(value) : const {};
}

bool _sameDevice(Map<String, Object?> left, Map<String, Object?> right) {
  const keys = [
    'serial',
    'model',
    'androidVersion',
    'fingerprint',
    'buildMode',
    'windowAnimationScale',
    'transitionAnimationScale',
    'animatorDurationScale',
  ];
  return keys.every((key) => left[key] == right[key]);
}

bool _sameFixture(Map<String, Object?> left, Map<String, Object?> right) {
  return jsonEncode(left) == jsonEncode(right);
}

bool _validRevision(String value) {
  return RegExp(r'^[a-f0-9]{7,40}$').hasMatch(value);
}

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = List<double>.of(values)..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle];
  return (sorted[middle - 1] + sorted[middle]) / 2;
}

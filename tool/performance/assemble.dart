import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length < 6 || arguments.contains('--help')) {
    stdout.writeln(
      'Usage: dart run tool/performance/assemble.dart <output.json> '
      '<device.json> <baseline|candidate> <git-sha> '
      '<run1.json> <run2.json> [run3.json ...] '
      '[--shared-metrics <media3-soak.json>]',
    );
    exitCode = arguments.contains('--help') ? 0 : 64;
    return;
  }

  final output = File(arguments[0]);
  final device = Map<String, Object?>.from(
    jsonDecode(await File(arguments[1]).readAsString()) as Map,
  );
  final label = arguments[2];
  final revision = arguments[3];
  if (label != 'baseline' && label != 'candidate') {
    throw const FormatException('Label must be baseline or candidate');
  }
  if (!RegExp(r'^[a-f0-9]{7,40}$').hasMatch(revision)) {
    throw const FormatException('A full or abbreviated Git SHA is required');
  }

  final sharedMetricsIndex = arguments.indexOf('--shared-metrics');
  if (sharedMetricsIndex == arguments.length - 1) {
    throw const FormatException('--shared-metrics requires a path');
  }
  final runPathEnd = sharedMetricsIndex < 0
      ? arguments.length
      : sharedMetricsIndex;
  final runPaths = arguments.sublist(4, runPathEnd);
  if (runPaths.length < 2) {
    throw const FormatException('At least two run files are required');
  }

  final runReports = <Map<String, Object?>>[];
  for (final runPath in runPaths) {
    final decoded = Map<String, Object?>.from(
      jsonDecode(await File(runPath).readAsString()) as Map,
    );
    runReports.add(_unwrapReport(decoded));
  }

  final first = runReports.first;
  final schemaVersion = (first['schemaVersion'] as num?)?.toInt() ?? 0;
  final scenario = first['scenario']?.toString() ?? '';
  final adapterVersion =
      (first['scenarioAdapterVersion'] as num?)?.toInt() ?? 0;
  final fixture = Map<String, Object?>.from(first['fixture']! as Map);
  final fixtureHash = fixture['contentHash']?.toString() ?? '';
  if (schemaVersion < 3 || adapterVersion < 3 || fixtureHash.isEmpty) {
    throw const FormatException('Run files do not use strict schema 3');
  }
  for (final report in runReports.skip(1)) {
    if (report['schemaVersion'] != schemaVersion ||
        report['scenario'] != scenario ||
        report['scenarioAdapterVersion'] != adapterVersion ||
        jsonEncode(report['fixture']) != jsonEncode(fixture)) {
      throw const FormatException('Run files use different scenarios/fixtures');
    }
  }

  Map<String, Object?> sharedMetrics = const {};
  Map<String, Object?> diagnosticSummary = const {};
  if (sharedMetricsIndex >= 0) {
    final sharedEnvelope = Map<String, Object?>.from(
      jsonDecode(await File(arguments[sharedMetricsIndex + 1]).readAsString())
          as Map,
    );
    final shared = _unwrapReport(sharedEnvelope);
    if (shared['schemaVersion'] != schemaVersion ||
        shared['label'] != label ||
        shared['revision'] != revision ||
        shared['fixtureHash'] != fixtureHash) {
      throw const FormatException(
        'Media3 soak does not match report revision, label, or fixture',
      );
    }
    sharedMetrics = Map<String, Object?>.from(shared['metrics']! as Map);
    diagnosticSummary = _objectMap(shared['diagnosticSummary']);
  }

  final runs = <Map<String, Object?>>[];
  for (final report in runReports) {
    final run = Map<String, Object?>.from(report['run']! as Map);
    if (sharedMetrics.isNotEmpty) {
      final metrics = Map<String, Object?>.from(run['metrics']! as Map)
        ..addAll(sharedMetrics);
      run['metrics'] = metrics;
    }
    runs.add(run);
  }

  final report = {
    'schemaVersion': schemaVersion,
    'scenario': scenario,
    'scenarioAdapterVersion': adapterVersion,
    'label': label,
    'revision': revision,
    'device': device,
    'fixture': fixture,
    if (diagnosticSummary.isNotEmpty) 'playbackDiagnostics': diagnosticSummary,
    'runs': runs,
  };
  await output.parent.create(recursive: true);
  await output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
  );
  stdout.writeln('Combined ${runs.length} runs in ${output.path}');
}

Map<String, Object?> _unwrapReport(Map<String, Object?> decoded) {
  if (decoded.containsKey('run') || decoded.containsKey('metrics')) {
    return decoded;
  }
  final data = decoded['data'];
  if (data is Map) return Map<String, Object?>.from(data);
  throw const FormatException('Run output does not contain report data');
}

Map<String, Object?> _objectMap(Object? value) {
  return value is Map ? Map<String, Object?>.from(value) : const {};
}

import 'dart:convert';
import 'dart:io';

import 'src/performance_comparison.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 || arguments.contains('--help')) {
    stdout.writeln(
      'Usage: dart run tool/performance/compare.dart '
      '<baseline.json> <candidate.json> '
      '[--json-output <path>] [--markdown-output <path>]',
    );
    exitCode = arguments.contains('--help') ? 0 : 64;
    return;
  }

  final baselinePath = arguments[0];
  final candidatePath = arguments[1];
  final jsonOutput = _option(arguments, '--json-output');
  final markdownOutput = _option(arguments, '--markdown-output');

  try {
    final baseline = PerformanceReport.decode(
      await File(baselinePath).readAsString(),
    );
    final candidate = PerformanceReport.decode(
      await File(candidatePath).readAsString(),
    );
    final comparison = comparePerformanceReports(baseline, candidate);
    final markdown = comparison.toMarkdown();
    stdout.write(markdown);

    if (jsonOutput != null) {
      final file = File(jsonOutput);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(comparison.toJson()),
      );
    }
    if (markdownOutput != null) {
      final file = File(markdownOutput);
      await file.parent.create(recursive: true);
      await file.writeAsString(markdown);
    }
    if (!comparison.passed) exitCode = 1;
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('Unable to compare performance reports: $error')
      ..writeln(stackTrace);
    exitCode = 65;
  }
}

String? _option(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0) return null;
  if (index + 1 >= arguments.length) {
    throw FormatException('$name requires a path');
  }
  return arguments[index + 1];
}

import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  await integrationDriver(
    responseDataCallback: (data) async {
      final outputPath = Platform.environment['KIKOFLU_PERF_RUN_OUTPUT'];
      if (outputPath == null || outputPath.isEmpty) {
        throw StateError('KIKOFLU_PERF_RUN_OUTPUT is required');
      }
      final file = File(outputPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );
    },
  );
}

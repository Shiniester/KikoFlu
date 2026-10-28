import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  await integrationDriver(
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      final output = Platform.environment['KIKOFLU_PERF_RUN_OUTPUT'];
      if (output == null || data?['videoRelayProfile'] == null) {
        throw StateError('A profile report and output path are required.');
      }
      await File(
        output,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    },
  );
}

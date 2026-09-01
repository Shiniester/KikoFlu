import 'dart:convert';
import 'dart:isolate';

import '../models/download_task.dart';

class DownloadTaskPersistence {
  const DownloadTaskPersistence._();

  static const int defaultIsolateTaskThreshold = 200;
  static const int defaultIsolateDecodeThresholdBytes = 256 * 1024;

  static Future<String> encode(
    Iterable<DownloadTask> tasks, {
    int isolateTaskThreshold = defaultIsolateTaskThreshold,
  }) async {
    final values = tasks.map((task) => task.toJson()).toList(growable: false);
    if (values.length < isolateTaskThreshold) return jsonEncode(values);
    return Isolate.run(() => jsonEncode(values));
  }

  static Future<List<Map<String, dynamic>>> decode(
    String source, {
    int isolateDecodeThresholdBytes = defaultIsolateDecodeThresholdBytes,
  }) async {
    final dynamic decoded = source.length >= isolateDecodeThresholdBytes
        ? await Isolate.run(() => jsonDecode(source))
        : jsonDecode(source);
    if (decoded is! List) {
      throw const FormatException('Download task payload must be a JSON list');
    }
    return decoded
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList(growable: false);
  }
}

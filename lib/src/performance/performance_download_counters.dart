import 'package:flutter/foundation.dart';

@immutable
class PerformanceDownloadCounters {
  const PerformanceDownloadCounters({
    required this.taskRowBuilds,
    required this.temporaryListAllocations,
  });

  final int taskRowBuilds;
  final int temporaryListAllocations;
}

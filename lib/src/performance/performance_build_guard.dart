class PerformanceBuildGuard {
  const PerformanceBuildGuard._();

  static const bool enabled = bool.fromEnvironment('KIKOFLU_PERFORMANCE');

  static void requireEnabled([String operation = 'performance operation']) {
    if (!enabled) {
      throw StateError(
        '$operation is available only when KIKOFLU_PERFORMANCE=true.',
      );
    }
  }
}

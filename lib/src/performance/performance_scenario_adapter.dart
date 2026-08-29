import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../screens/downloads_screen.dart';
import '../services/background_work_scheduler.dart';
import '../services/download_service.dart';
import '../services/subtitle_database.dart';
import '../services/subtitle_library_service.dart';
import '../widgets/lazy_indexed_stack.dart';
import 'performance_download_counters.dart';

/// Stable boundary used by both the v3.8.2 baseline and optimized candidate.
/// Scenario actions and metric names live in the integration test; only the
/// implementation behind this adapter changes in optimization commits.
abstract interface class PerformanceScenarioAdapter {
  String get implementation;

  Widget buildTabHost({
    required int index,
    required Set<int> visitedIndices,
    required List<Widget> children,
  });

  Widget buildDownloads();

  Widget buildPlayer({
    required ValueNotifier<int> position,
    required ValueNotifier<int> track,
  });

  Future<void> waitForBackgroundWork();

  void injectDownloadTasks(List<DownloadTask> tasks);
  void advanceActiveDownloads(int tick);
  void resetDownloadCounters();
  PerformanceDownloadCounters readDownloadCounters();
  void clearDownloadTasks();

  Future<List<SubtitleFileRecord>> scanSubtitleDirectory(String sourcePath);

  Future<ImportResult> importSubtitleArchive({
    required String sourcePath,
    required String targetPath,
  });
}

PerformanceScenarioAdapter createPerformanceScenarioAdapter() {
  return const OptimizedPerformanceScenarioAdapter();
}

class OptimizedPerformanceScenarioAdapter
    implements PerformanceScenarioAdapter {
  const OptimizedPerformanceScenarioAdapter();

  @override
  String get implementation => 'v3.8.2-optimized';

  @override
  Widget buildTabHost({
    required int index,
    required Set<int> visitedIndices,
    required List<Widget> children,
  }) {
    return LazyIndexedStack(
      index: index,
      visitedIndices: visitedIndices,
      children: children,
    );
  }

  @override
  Widget buildDownloads() => const DownloadsScreen();

  @override
  Widget buildPlayer({
    required ValueNotifier<int> position,
    required ValueNotifier<int> track,
  }) {
    return Column(
      children: [
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: track,
            builder: (context, value, child) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [const FlutterLogo(size: 240), Text('Track $value')],
            ),
          ),
        ),
        ValueListenableBuilder<int>(
          valueListenable: position,
          builder: (context, value, child) =>
              LinearProgressIndicator(value: (value % 1000) / 1000),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  Future<void> waitForBackgroundWork() {
    return BackgroundWorkScheduler.instance.whenIdle();
  }

  @override
  void injectDownloadTasks(List<DownloadTask> tasks) {
    DownloadService.instance.debugInjectPerformanceTasks(tasks);
  }

  @override
  void advanceActiveDownloads(int tick) {
    DownloadService.instance.debugAdvancePerformanceTasks(tick);
  }

  @override
  void resetDownloadCounters() {
    DownloadService.instance.debugResetPerformanceCounters();
  }

  @override
  PerformanceDownloadCounters readDownloadCounters() {
    return DownloadService.instance.debugPerformanceCounters;
  }

  @override
  void clearDownloadTasks() {
    DownloadService.instance.debugClearPerformanceTasks();
  }

  @override
  Future<List<SubtitleFileRecord>> scanSubtitleDirectory(String sourcePath) {
    return SubtitleLibraryService.scanDirectoryFromPath(sourcePath);
  }

  @override
  Future<ImportResult> importSubtitleArchive({
    required String sourcePath,
    required String targetPath,
  }) {
    return SubtitleLibraryService.importArchiveFromPath(
      sourcePath,
      targetLibraryPath: targetPath,
      refreshIndex: false,
    );
  }
}

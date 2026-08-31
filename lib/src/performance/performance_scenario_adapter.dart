import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../screens/downloads_screen.dart';
import '../services/download_service.dart';
import '../services/subtitle_database.dart';
import '../services/subtitle_library_service.dart';
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
  return const LegacyPerformanceScenarioAdapter();
}

class LegacyPerformanceScenarioAdapter implements PerformanceScenarioAdapter {
  const LegacyPerformanceScenarioAdapter();

  @override
  String get implementation => 'v3.8.2-legacy';

  @override
  Widget buildTabHost({
    required int index,
    required Set<int> visitedIndices,
    required List<Widget> children,
  }) {
    return IndexedStack(index: index, children: children);
  }

  @override
  Widget buildDownloads() => const DownloadsScreen();

  @override
  Widget buildPlayer({
    required ValueNotifier<int> position,
    required ValueNotifier<int> track,
  }) {
    return AnimatedBuilder(
      animation: Listenable.merge([position, track]),
      builder: (context, child) {
        return Column(
          children: [
            const Expanded(child: Center(child: FlutterLogo(size: 240))),
            Text('Track ${track.value}'),
            LinearProgressIndicator(value: (position.value % 1000) / 1000),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  @override
  Future<void> waitForBackgroundWork() async {}

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

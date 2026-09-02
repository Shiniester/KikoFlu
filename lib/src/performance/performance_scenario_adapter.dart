import 'package:flutter/material.dart';

import '../models/download_task.dart';
import '../screens/downloads_screen.dart';
import '../services/background_work_scheduler.dart';
import '../services/download_service.dart';
import '../services/subtitle_database.dart';
import '../services/subtitle_library_service.dart';
import '../widgets/lazy_indexed_stack.dart';
import '../widgets/player/player_visual_palette.dart';
import 'performance_download_counters.dart';

/// Versioned boundary shared by the Android profile scenario and its reports.
/// Increment [performanceScenarioAdapterVersion] whenever the measured widget
/// workload changes so reports with different costs cannot be compared.
const performanceScenarioAdapterVersion = 4;

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
  String get implementation => 'salt-player-stage';

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
    return _ProfilePlayerStage(position: position, track: track);
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

/// Mirrors the real player's static visual workload while keeping the profile
/// fixture deterministic and independent from platform audio plugins.
class _ProfilePlayerStage extends StatelessWidget {
  const _ProfilePlayerStage({required this.position, required this.track});

  final ValueNotifier<int> position;
  final ValueNotifier<int> track;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: track,
      builder: (context, trackIndex, child) {
        final palette = PlayerVisualPalette.fromDominant(
          Colors.primaries[trackIndex % Colors.primaries.length],
          brightness: Brightness.dark,
        );
        return AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                palette.backgroundStart,
                palette.backgroundMiddle,
                palette.backgroundEnd,
              ],
            ),
          ),
          child: Theme(
            data: Theme.of(context).copyWith(
              colorScheme: Theme.of(context).colorScheme.copyWith(
                primary: palette.accent,
                onPrimary: palette.onAccent,
                onSurface: palette.foreground,
                onSurfaceVariant: palette.secondaryForeground,
              ),
              iconTheme: IconThemeData(color: palette.foreground),
              textTheme: Theme.of(context).textTheme.apply(
                bodyColor: palette.foreground,
                displayColor: palette.foreground,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final artwork = _ProfileArtwork(trackIndex: trackIndex);
                final controls = _ProfileControls(position: position);
                if (constraints.maxWidth >= 840) {
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Row(
                      children: [
                        Expanded(child: artwork),
                        const SizedBox(width: 32),
                        Expanded(child: controls),
                      ],
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Expanded(child: artwork),
                      const SizedBox(height: 16),
                      controls,
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _ProfileArtwork extends StatelessWidget {
  const _ProfileArtwork({required this.trackIndex});

  final int trackIndex;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.12),
                  ),
                ),
                child: const Icon(Icons.album, size: 112),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Track $trackIndex',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            'Performance Artist',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileControls extends StatelessWidget {
  const _ProfileControls({required this.position});

  final ValueNotifier<int> position;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<int>(
            valueListenable: position,
            builder: (context, value, child) => LinearProgressIndicator(
              value: (value % 1000) / 1000,
              minHeight: 4,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(height: 24),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Icon(Icons.skip_previous, size: 40),
              CircleAvatar(radius: 34, child: Icon(Icons.play_arrow, size: 38)),
              Icon(Icons.skip_next, size: 40),
            ],
          ),
          const SizedBox(height: 24),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Icon(Icons.repeat),
              Icon(Icons.timer_outlined),
              Icon(Icons.tune),
              Icon(Icons.queue_music),
              Icon(Icons.more_horiz),
            ],
          ),
        ],
      ),
    );
  }
}

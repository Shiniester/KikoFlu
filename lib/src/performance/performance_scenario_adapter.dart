import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../models/audio_track.dart';
import '../providers/audio_provider.dart';
import '../providers/lyric_provider.dart';
import '../models/download_task.dart';
import '../screens/downloads_screen.dart';
import '../services/background_work_scheduler.dart';
import '../services/download_service.dart';
import '../services/subtitle_database.dart';
import '../services/subtitle_library_service.dart';
import '../widgets/lazy_indexed_stack.dart';
import '../widgets/mini_player.dart';
import 'performance_download_counters.dart';

/// Versioned boundary shared by the Android profile scenario and its reports.
/// Increment [performanceScenarioAdapterVersion] whenever the measured widget
/// workload changes so reports with different costs cannot be compared.
const performanceScenarioAdapterVersion = 5;

abstract interface class PerformanceScenarioAdapter {
  String get implementation;

  Widget buildTabHost({
    required int index,
    required Set<int> visitedIndices,
    required List<Widget> children,
  });

  Widget buildDownloads();

  Widget buildPlayer({required String artworkFilePath});

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
  String get implementation => 'real-player-route-v1';

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
  Widget buildPlayer({required String artworkFilePath}) =>
      _ProfilePlayerRouteStage(artworkFilePath: artworkFilePath);

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

/// Uses the production Mini Player and Player Cover Page while keeping audio
/// and artwork inputs deterministic for repeatable Profile measurements.
class _ProfilePlayerRouteStage extends StatelessWidget {
  const _ProfilePlayerRouteStage({required this.artworkFilePath});

  final String artworkFilePath;

  @override
  Widget build(BuildContext context) {
    final track = AudioTrack(
      id: 'profile-player-route-track',
      title: 'Profile Player Route',
      url: 'file:///profile-player-route.flac',
      artist: 'KikoFlu Performance',
      artworkUrl: Uri.file(artworkFilePath).toString(),
    );
    return ProviderScope(
      overrides: [
        currentTrackProvider.overrideWith((ref) => Stream.value(track)),
        isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        playerStateProvider.overrideWith(
          (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
        ),
        queueProvider.overrideWith((ref) => Stream.value([track])),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
      ],
      child: const Scaffold(
        key: ValueKey('profile-player-route-host'),
        body: ColoredBox(color: Color(0xFF101216)),
        bottomNavigationBar: MiniPlayer(),
      ),
    );
  }
}

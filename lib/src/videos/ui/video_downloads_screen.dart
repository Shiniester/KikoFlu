import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../video_download_task.dart';
import '../video_downloads.dart';
import '../video_providers.dart';
import 'video_details_screen.dart';

class VideoDownloadsScreen extends ConsumerStatefulWidget {
  const VideoDownloadsScreen({super.key});

  @override
  ConsumerState<VideoDownloadsScreen> createState() =>
      _VideoDownloadsScreenState();
}

class _VideoDownloadsScreenState extends ConsumerState<VideoDownloadsScreen> {
  bool _ready = false;
  bool _initializationFailed = false;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await ref.read(videoDownloadsProvider).initialize();
    } catch (_) {
      _initializationFailed = true;
    } finally {
      if (mounted) setState(() => _ready = true);
    }
  }

  Future<void> _run(String id, Future<void> Function(String) action) async {
    if (!_busy.add(id)) return;
    setState(() {});
    try {
      await action(id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).videoDownloadFailed)),
        );
      }
    } finally {
      _busy.remove(id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete(VideoDownloads downloads, VideoDownloadTask task) async {
    final s = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.delete),
        content: Text(s.videoDownloadDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(s.delete),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(task.id, downloads.remove);
    }
  }

  Future<void> _openTask(VideoDownloadTask task) => pushWorkDetailRoute(
    context,
    builder: (_) => VideoDetailsScreen(video: task.video, downloadedTask: task),
  );

  Future<void> _openSource(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).videoSourceUnavailable)),
      );
    }
  }

  String _status(VideoDownloadTask task, S s) => switch (task.status) {
    VideoDownloadStatus.queued => s.videoDownloadQueued,
    VideoDownloadStatus.downloading => s.videoDownloadInProgress,
    VideoDownloadStatus.paused => s.videoDownloadPaused,
    VideoDownloadStatus.failed => s.videoDownloadFailedStatus,
    VideoDownloadStatus.completed => s.videoDownloadCompleted,
  };

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final downloads = ref.watch(videoDownloadsProvider);
    return GlobalAudioPlayerWrapper(
      child: Scaffold(
        appBar: AppBar(title: Text(s.videoDownloads)),
        body: !_ready
            ? const Center(child: CircularProgressIndicator())
            : _initializationFailed
            ? Center(child: Text(s.videoDownloadFailed))
            : downloads.tasks.isEmpty
            ? Center(child: Text(s.noDownloadTasks))
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: downloads.tasks.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final task = downloads.tasks[index];
                  final busy = _busy.contains(task.id);
                  final completed =
                      task.status == VideoDownloadStatus.completed &&
                      task.localPath?.isNotEmpty == true;
                  final status = _status(task, s);
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: completed ? () => _openTask(task) : null,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 104,
                              child: AspectRatio(
                                aspectRatio: 16 / 9,
                                child: task.video.cover.isEmpty
                                    ? const ColoredBox(
                                        color: Colors.black12,
                                        child: Icon(Icons.movie_outlined),
                                      )
                                    : Image.network(
                                        task.video.cover,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) =>
                                            const ColoredBox(
                                              color: Colors.black12,
                                              child: Icon(Icons.movie_outlined),
                                            ),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    task.video.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 4),
                                  Text('$status · ${task.quality}'),
                                  const SizedBox(height: 6),
                                  LinearProgressIndicator(
                                    value:
                                        task.status ==
                                            VideoDownloadStatus.completed
                                        ? 1
                                        : task.progress,
                                  ),
                                  if (task.status == VideoDownloadStatus.failed)
                                    TextButton.icon(
                                      onPressed: () => unawaited(
                                        _openSource(task.video.pageUrl),
                                      ),
                                      icon: const Icon(Icons.open_in_new),
                                      label: Text(s.videoOpenSource),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 4),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (task.status ==
                                        VideoDownloadStatus.downloading ||
                                    task.status == VideoDownloadStatus.queued)
                                  IconButton(
                                    tooltip: s.pause,
                                    onPressed: busy
                                        ? null
                                        : () => _run(task.id, downloads.pause),
                                    icon: const Icon(Icons.pause),
                                  ),
                                if (task.status == VideoDownloadStatus.paused)
                                  IconButton(
                                    tooltip: s.resume,
                                    onPressed: busy
                                        ? null
                                        : () => _run(task.id, downloads.resume),
                                    icon: const Icon(Icons.play_arrow),
                                  ),
                                if (task.status == VideoDownloadStatus.failed)
                                  IconButton(
                                    tooltip: s.retry,
                                    onPressed: busy
                                        ? null
                                        : () => _run(task.id, downloads.retry),
                                    icon: const Icon(Icons.refresh),
                                  ),
                                IconButton(
                                  tooltip: s.delete,
                                  onPressed: busy
                                      ? null
                                      : () => _delete(downloads, task),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

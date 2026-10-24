import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../utils/collection_grid_layout.dart';
import '../../providers/settings_provider.dart';
import '../../providers/works_provider.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/virtualized_sliver_collection.dart';
import '../video_download_task.dart';
import '../video_downloads.dart';
import '../video_models.dart';
import '../video_providers.dart';
import 'video_details_screen.dart';
import 'video_collection_view.dart';
import 'video_search_screen.dart';
import 'video_screen.dart';

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
  final ScrollController _scrollController = ScrollController();
  int _currentPage = 1;

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
      if (!mounted) return;
      final pageSize = ref.read(pageSizeProvider);
      final totalPages = ((downloads.tasks.length + pageSize - 1) ~/ pageSize)
          .clamp(1, 1 << 30)
          .toInt();
      if (_currentPage > totalPages) {
        setState(() => _currentPage = totalPages);
      }
    }
  }

  void _goToPage(int page) {
    setState(() => _currentPage = page);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Widget _downloadsList(S s, VideoDownloads downloads, int pageSize) {
    final totalCount = downloads.tasks.length;
    final totalPages = (totalCount / pageSize).ceil().clamp(1, 1 << 30).toInt();
    final currentPage = _currentPage.clamp(1, totalPages).toInt();
    final tasks = downloads.tasks
        .skip((currentPage - 1) * pageSize)
        .take(pageSize)
        .toList(growable: false);
    return VirtualizedSliverCollection<VideoDownloadTask>(
      controller: _scrollController,
      pageStorageKey: const PageStorageKey<String>('video-downloads'),
      items: tasks,
      itemId: (task) => task.id,
      itemBuilder: (context, task, _) {
        final busy = _busy.contains(task.id);
        final completed =
            task.status == VideoDownloadStatus.completed &&
            task.localPath?.isNotEmpty == true;
        final status = _status(task, s);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: completed ? () => _openTask(task) : null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox.fromSize(
                      size: collectionListCoverSize,
                      child: VideoCover(video: task.video),
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
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text('$status · ${task.quality}'),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(
                            value: task.status == VideoDownloadStatus.completed
                                ? 1
                                : task.progress,
                          ),
                          if (task.status == VideoDownloadStatus.failed)
                            TextButton.icon(
                              onPressed: () =>
                                  unawaited(_openSource(task.video.pageUrl)),
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
                        if (task.status == VideoDownloadStatus.downloading ||
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
          ),
        );
      },
      layout: VirtualizedCollectionLayout.list,
      padding: const EdgeInsets.all(12),
      pagination: VirtualizedPagination(
        currentPage: currentPage,
        pageSize: pageSize,
        totalCount: totalCount,
        hasMore: currentPage < totalPages,
        isLoading: false,
        onPreviousPage: currentPage > 1
            ? () => _goToPage(currentPage - 1)
            : null,
        onNextPage: currentPage < totalPages
            ? () => _goToPage(currentPage + 1)
            : null,
        onGoToPage: _goToPage,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _openTask(VideoDownloadTask task) => pushWorkDetailRoute(
    context,
    builder: (_) => VideoDetailsScreen(video: task.video, downloadedTask: task),
  );

  Future<void> _searchDownloads(VideoDownloads downloads) async {
    final s = S.of(context);
    final client = ref.read(videoClientProvider);
    VideoDownloadTask? taskFor(VideoItem video) {
      for (final task in downloads.tasks) {
        if (task.video.id == video.id) return task;
      }
      return null;
    }

    await pushWorkDetailRoute(
      context,
      builder: (_) => GlobalAudioPlayerWrapper.workDetails(
        child: VideoSearchScreen(
          title: s.videoDownloads,
          search: (query, filters, _) async {
            assert(filters.isEmpty);
            final normalized = query.toLowerCase();
            final matches = downloads.tasks
                .where(
                  (task) =>
                      task.video.title.toLowerCase().contains(normalized) ||
                      task.video.id.toLowerCase().contains(normalized),
                )
                .map((task) => task.video)
                .toList(growable: false);
            return VideoSearchResults.collection(matches);
          },
          browsePage: client.browse,
          canOpenVideo: (video) {
            final task = taskFor(video);
            return task?.status == VideoDownloadStatus.completed &&
                task?.localPath?.isNotEmpty == true;
          },
          itemBuilder: (context, video, layoutType, onTap) {
            final task = taskFor(video);
            return VideoCard(
              video: video,
              layoutType: layoutType,
              onTap: onTap,
              subtitle: layoutType == LayoutType.list && task != null
                  ? '${_status(task, s)} · ${task.quality}'
                  : null,
              onOpenLink: (link) => unawaited(
                pushBottomDockRoute(
                  context,
                  builder: (_) => VideoScreen.catalog(url: link.url),
                ),
              ),
            );
          },
          onOpenVideo: (searchContext, video) {
            final task = taskFor(video);
            if (task == null) return;
            pushWorkDetailRoute(
              searchContext,
              builder: (_) =>
                  VideoDetailsScreen(video: task.video, downloadedTask: task),
            );
          },
        ),
      ),
    );
  }

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
    final pageSize = ref.watch(pageSizeProvider);
    return GlobalAudioPlayerWrapper(
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.videoDownloads),
          actions: [
            IconButton(
              tooltip: s.search,
              icon: const Icon(Icons.search),
              onPressed: () => _searchDownloads(downloads),
            ),
          ],
        ),
        body: !_ready
            ? const Center(child: CircularProgressIndicator())
            : _initializationFailed
            ? Center(child: Text(s.videoDownloadFailed))
            : downloads.tasks.isEmpty
            ? Center(child: Text(s.noDownloadTasks))
            : _downloadsList(s, downloads, pageSize),
      ),
    );
  }
}

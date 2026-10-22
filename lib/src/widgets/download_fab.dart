import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../providers/audio_subtitle_generation_notice_provider.dart';
import '../providers/download_provider.dart';
import '../screens/downloads_screen.dart';
import '../services/download_service.dart';
import 'audio_subtitle_generation_sheet.dart';

/// 下载任务浮动按钮
class DownloadFab extends ConsumerWidget {
  const DownloadFab({super.key, this.showDownloadButtonWhenIdle = false});

  final bool showDownloadButtonWhenIdle;

  void _navigateToDownloads(BuildContext context) {
    showDownloadTasksSheet(context);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeCount =
        ref.watch(downloadSummaryProvider).valueOrNull?.active ??
        DownloadService.instance.activeDownloadCount;
    final generationNotice = ref.watch(audioSubtitleGenerationNoticeProvider);

    final showDownloads = activeCount > 0 || showDownloadButtonWhenIdle;
    if (!showDownloads && !generationNotice.shouldShow) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (generationNotice.shouldShow) ...[
          Badge(
            isLabelVisible: generationNotice.hasUnreadResults,
            child: FloatingActionButton.small(
              heroTag: 'audio-subtitle-generation',
              onPressed: () => showAudioSubtitleGenerationSheet(context),
              tooltip: S.of(context).subtitleGenerationTitle,
              child: const Icon(Icons.subtitles),
            ),
          ),
          if (showDownloads) const SizedBox(height: 12),
        ],
        if (showDownloads)
          Badge(
            isLabelVisible: activeCount > 0,
            label: Text('$activeCount'),
            child: FloatingActionButton(
              heroTag: 'download-tasks',
              onPressed: () => _navigateToDownloads(context),
              tooltip: S.of(context).downloadTasks,
              child: const Icon(Icons.download),
            ),
          ),
      ],
    );
  }
}

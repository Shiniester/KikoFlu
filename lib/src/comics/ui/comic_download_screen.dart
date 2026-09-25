import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../l10n/app_localizations.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../utils/snackbar_util.dart';
import '../comic_downloads.dart';
import '../comic_providers.dart';

class ComicDownloadScreen extends ConsumerWidget {
  const ComicDownloadScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(comicDownloadsProvider);
    final s = S.of(context);
    final status = [
      s.comicQueued,
      s.comicDownloading,
      s.comicPaused,
      s.comicFailed,
      s.comicComplete,
    ];
    return GlobalAudioPlayerWrapper(
      child: Scaffold(
        appBar: AppBar(title: Text(s.downloadTasks)),
        body: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: downloads.tasks.length,
          itemBuilder: (context, i) {
            final task = downloads.tasks[i];
            final canPause =
                task.status == ComicDownloadStatus.downloading ||
                task.status == ComicDownloadStatus.queued;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.comic.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(task.chapter.title),
                    Text(
                      '${status[task.status.index]} · ${task.completed}/${task.pages.length}',
                    ),
                    if (task.error != null)
                      Text(
                        task.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: task.pages.isEmpty
                          ? 0
                          : task.completed / task.pages.length,
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (task.status != ComicDownloadStatus.complete)
                          IconButton(
                            tooltip: canPause ? s.comicPause : s.comicResume,
                            icon: Icon(
                              canPause ? Icons.pause : Icons.play_arrow,
                            ),
                            onPressed: () async {
                              try {
                                if (task.status ==
                                        ComicDownloadStatus.downloading ||
                                    task.status == ComicDownloadStatus.queued) {
                                  await downloads.pause(task);
                                } else {
                                  await downloads.resume(task);
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  SnackBarUtil.showError(context, e.toString());
                                }
                              }
                            },
                          ),
                        IconButton(
                          tooltip: s.delete,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                content: Text(s.comicDeleteConfirm),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: Text(s.cancel),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: Text(s.delete),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true) {
                              try {
                                await downloads.remove(task);
                              } catch (e) {
                                if (context.mounted) {
                                  SnackBarUtil.showError(context, e.toString());
                                }
                              }
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

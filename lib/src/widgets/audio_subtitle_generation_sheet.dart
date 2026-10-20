import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../providers/audio_subtitle_generation_provider.dart';
import 'responsive_dialog.dart';

Future<void> showAudioSubtitleGenerationSheet(BuildContext context) {
  final screenHeight = MediaQuery.sizeOf(context).height;
  return showResponsiveBottomSheet<void>(
    context: context,
    maxWidth: 560,
    maxHeight: screenHeight * 0.84,
    builder: (_) => const _AudioSubtitleGenerationSheet(),
  );
}

class _AudioSubtitleGenerationSheet extends ConsumerWidget {
  const _AudioSubtitleGenerationSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identities = ref.watch(
      audioSubtitleGenerationProvider.select(
        (jobs) => jobs.map((job) => job.identity).join('\u0000'),
      ),
    );
    final jobIdentities = identities.isEmpty
        ? const <String>[]
        : identities.split('\u0000');
    final summary = ref.watch(
      audioSubtitleGenerationProvider.select(
        (jobs) => (
          completed: jobs
              .where(
                (job) => job.status == AudioSubtitleGenerationStatus.completed,
              )
              .length,
          skipped: jobs
              .where(
                (job) => job.status == AudioSubtitleGenerationStatus.skipped,
              )
              .length,
          unsupported: jobs
              .where(
                (job) =>
                    job.status == AudioSubtitleGenerationStatus.unsupported,
              )
              .length,
          failed: jobs
              .where(
                (job) =>
                    job.status == AudioSubtitleGenerationStatus.failed ||
                    job.status ==
                        AudioSubtitleGenerationStatus.translationFailed,
              )
              .length,
          cancelled: jobs
              .where(
                (job) => job.status == AudioSubtitleGenerationStatus.cancelled,
              )
              .length,
          hasActive: jobs.any((job) => !job.status.isFinished),
        ),
      ),
    );
    final l10n = S.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.84;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.subtitleGenerationTitle,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.close,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Flexible(
                child: CustomScrollView(
                  key: const ValueKey('audio-subtitle-generation-jobs'),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.subtitleGenerationDescription,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.subtitleGenerationCloseHint,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                    SliverList.builder(
                      itemCount: jobIdentities.length,
                      itemBuilder: (context, index) => _AudioSubtitleJobTile(
                        key: ValueKey(jobIdentities[index]),
                        identity: jobIdentities[index],
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Divider(height: 20),
                          Text(
                            l10n.subtitleGenerationSummary(
                              summary.completed,
                              summary.skipped,
                              summary.unsupported,
                              summary.failed,
                              summary.cancelled,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextButton(
                                  onPressed: summary.hasActive
                                      ? () => ref
                                            .read(
                                              audioSubtitleGenerationProvider
                                                  .notifier,
                                            )
                                            .cancelAll()
                                      : null,
                                  child: Text(l10n.subtitleGenerationCancelAll),
                                ),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: Text(l10n.close),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AudioSubtitleJobTile extends ConsumerWidget {
  const _AudioSubtitleJobTile({super.key, required this.identity});

  final String identity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = ref.watch(
      audioSubtitleGenerationProvider.select(
        (jobs) => jobs.where((job) => job.identity == identity).firstOrNull,
      ),
    );
    if (job == null) return const SizedBox.shrink();

    final l10n = S.of(context);
    final status = job.status;
    final active = !status.isFinished;
    final statusText = status == AudioSubtitleGenerationStatus.translationFailed
        ? l10n.subtitleGenerationTranslationFailed
        : status == AudioSubtitleGenerationStatus.failed
        ? l10n.subtitleGenerationFailed(
            _statusLabel(
              l10n,
              job.failureStage ?? AudioSubtitleGenerationStatus.checking,
            ),
          )
        : switch (status) {
            AudioSubtitleGenerationStatus.downloadingAudio ||
            AudioSubtitleGenerationStatus.downloadingModel ||
            AudioSubtitleGenerationStatus.transcribing ||
            AudioSubtitleGenerationStatus.translating ||
            AudioSubtitleGenerationStatus.saving =>
              l10n.subtitleGenerationProgress(
                _statusLabel(l10n, status),
                job.progress,
              ),
            _ => _statusLabel(l10n, status),
          };
    final progress = switch (status) {
      AudioSubtitleGenerationStatus.checking => null,
      AudioSubtitleGenerationStatus.queued => null,
      _ when active && job.progress > 0 => job.progress,
      _ when active => null,
      _ => null,
    };

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(
        job.request.track.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (job.request.parentPath case final path? when path.isNotEmpty)
            Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(statusText),
          if (active)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: LinearProgressIndicator(value: progress),
            ),
        ],
      ),
      trailing: active
          ? IconButton(
              tooltip: l10n.cancel,
              onPressed: () => ref
                  .read(audioSubtitleGenerationProvider.notifier)
                  .cancel(identity),
              icon: const Icon(Icons.cancel_outlined),
            )
          : status == AudioSubtitleGenerationStatus.translationFailed
          ? IconButton(
              tooltip: l10n.subtitleGenerationRetryTranslation,
              onPressed: () => ref
                  .read(audioSubtitleGenerationProvider.notifier)
                  .retryTranslation(identity),
              icon: const Icon(Icons.refresh),
            )
          : null,
    );
  }
}

String _statusLabel(S s, AudioSubtitleGenerationStatus status) =>
    switch (status) {
      AudioSubtitleGenerationStatus.queued => s.subtitleGenerationQueued,
      AudioSubtitleGenerationStatus.checking => s.subtitleGenerationChecking,
      AudioSubtitleGenerationStatus.downloadingAudio =>
        s.subtitleGenerationDownloadingAudio,
      AudioSubtitleGenerationStatus.downloadingModel =>
        s.subtitleGenerationDownloadingModel,
      AudioSubtitleGenerationStatus.transcribing =>
        s.subtitleGenerationTranscribing,
      AudioSubtitleGenerationStatus.saving => s.subtitleGenerationSaving,
      AudioSubtitleGenerationStatus.translating => s.translating,
      AudioSubtitleGenerationStatus.completed => s.subtitleGenerationCompleted,
      AudioSubtitleGenerationStatus.skipped => s.subtitleGenerationSkipped,
      AudioSubtitleGenerationStatus.unsupported =>
        s.subtitleGenerationUnsupported,
      AudioSubtitleGenerationStatus.failed => s.subtitleGenerationChecking,
      AudioSubtitleGenerationStatus.translationFailed =>
        s.subtitleGenerationTranslationFailed,
      AudioSubtitleGenerationStatus.cancelled => s.subtitleGenerationCancelled,
    };

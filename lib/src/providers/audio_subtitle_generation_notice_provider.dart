import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'audio_subtitle_generation_provider.dart';

@immutable
class AudioSubtitleGenerationNotice {
  const AudioSubtitleGenerationNotice({
    required this.activeCount,
    required this.unreadResultIdentities,
  });

  final int activeCount;
  final Set<String> unreadResultIdentities;

  bool get hasActiveJobs => activeCount > 0;
  bool get hasUnreadResults => unreadResultIdentities.isNotEmpty;
  bool get shouldShow => hasActiveJobs || hasUnreadResults;
}

class AudioSubtitleGenerationNoticeController
    extends StateNotifier<AudioSubtitleGenerationNotice> {
  AudioSubtitleGenerationNoticeController(List<AudioSubtitleJob> jobs)
    : _jobs = jobs,
      super(
        AudioSubtitleGenerationNotice(
          activeCount: jobs.where((job) => !job.status.isFinished).length,
          unreadResultIdentities: Set.unmodifiable(
            jobs
                .where((job) => job.status.isFinished)
                .map((job) => job.identity),
          ),
        ),
      );

  List<AudioSubtitleJob> _jobs;

  void updateJobs(List<AudioSubtitleJob> jobs) {
    final previousByIdentity = {for (final job in _jobs) job.identity: job};
    final currentIdentities = jobs.map((job) => job.identity).toSet();
    final unread = state.unreadResultIdentities.toSet()
      ..removeWhere((identity) => !currentIdentities.contains(identity));

    for (final job in jobs) {
      final previous = previousByIdentity[job.identity];
      if (!job.status.isFinished) {
        unread.remove(job.identity);
      } else if (previous == null || !previous.status.isFinished) {
        unread.add(job.identity);
      }
    }

    _jobs = jobs;
    final activeCount = jobs.where((job) => !job.status.isFinished).length;
    if (activeCount == state.activeCount &&
        setEquals(unread, state.unreadResultIdentities)) {
      return;
    }
    state = AudioSubtitleGenerationNotice(
      activeCount: activeCount,
      unreadResultIdentities: Set.unmodifiable(unread),
    );
  }

  void markViewed(List<AudioSubtitleJob> jobs) {
    final viewed = jobs
        .where((job) => job.status.isFinished)
        .map((job) => job.identity)
        .toSet();
    if (viewed.isEmpty) return;

    final unread = state.unreadResultIdentities.difference(viewed);
    if (unread.length == state.unreadResultIdentities.length) return;
    state = AudioSubtitleGenerationNotice(
      activeCount: state.activeCount,
      unreadResultIdentities: Set.unmodifiable(unread),
    );
  }
}

final audioSubtitleGenerationNoticeProvider =
    StateNotifierProvider<
      AudioSubtitleGenerationNoticeController,
      AudioSubtitleGenerationNotice
    >((ref) {
      final jobs = ref.read(audioSubtitleGenerationProvider);
      final controller = AudioSubtitleGenerationNoticeController(jobs);
      ref.listen(audioSubtitleGenerationProvider, (_, next) {
        controller.updateJobs(next);
      });
      return controller;
    });

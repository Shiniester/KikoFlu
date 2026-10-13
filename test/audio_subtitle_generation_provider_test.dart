import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_subtitle_generation_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_subtitle_generation_service.dart';

void main() {
  test(
    'deduplicates, runs serially, continues after failure, and retries',
    () async {
      final first = _request('first', 'shared-audio');
      final duplicate = _request('duplicate', 'shared-audio');
      final second = _request('second', 'other-audio');
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final calls = <AudioSubtitleRequest>[];
      final completed = <({AudioSubtitleRequest request, String path})>[];
      final controller = AudioSubtitleGenerationController(
        (request, _, __) async {
          calls.add(request);
          if (calls.length == 1) {
            firstStarted.complete();
            await releaseFirst.future;
            throw StateError('transcription failed');
          }
          return (
            status: AudioSubtitleGenerationStatus.completed,
            path: '/generated/${request.track.id}.srt',
          );
        },
        onCompleted: (request, path) {
          completed.add((request: request, path: path));
        },
      );
      addTearDown(controller.dispose);

      controller.enqueue([first, duplicate, second]);
      await firstStarted.future;

      expect(calls, [first]);
      expect(controller.state, hasLength(2));
      expect(
        controller.state[0].status,
        AudioSubtitleGenerationStatus.checking,
      );
      expect(controller.state[1].status, AudioSubtitleGenerationStatus.queued);

      releaseFirst.complete();
      final secondJob = await _waitForJob(
        controller,
        second.identity,
        AudioSubtitleGenerationStatus.completed,
      );

      expect(calls, [first, second]);
      expect(controller.state[0].status, AudioSubtitleGenerationStatus.failed);
      expect(
        controller.state[0].failureStage,
        AudioSubtitleGenerationStatus.checking,
      );
      expect(secondJob.path, '/generated/second.srt');
      expect(completed, hasLength(1));
      expect(identical(completed.single.request, second), isTrue);

      controller.enqueue([first]);
      final retriedJob = await _waitForJob(
        controller,
        first.identity,
        AudioSubtitleGenerationStatus.completed,
      );

      expect(calls, [first, second, first]);
      expect(retriedJob.path, '/generated/first.srt');
      expect(identical(completed.last.request, first), isTrue);
    },
  );

  test(
    'retries a failed audio while the rest of the batch is running',
    () async {
      final first = _request('first', 'first-audio');
      final second = _request('second', 'second-audio');
      final secondStarted = Completer<void>();
      final releaseSecond = Completer<void>();
      final calls = <String>[];
      final controller = AudioSubtitleGenerationController((
        request,
        _,
        __,
      ) async {
        calls.add(request.track.id);
        if (calls.length == 1) throw StateError('download failed');
        if (request == second) {
          secondStarted.complete();
          await releaseSecond.future;
        }
        return (status: AudioSubtitleGenerationStatus.completed, path: null);
      });
      addTearDown(controller.dispose);
      controller.enqueue([first, second]);
      await secondStarted.future;
      controller.enqueue([first]);
      expect(controller.state, hasLength(2));
      expect(
        controller.state.last.status,
        AudioSubtitleGenerationStatus.queued,
      );
      releaseSecond.complete();
      await _waitForJob(
        controller,
        first.identity,
        AudioSubtitleGenerationStatus.completed,
      );
      expect(calls, ['first', 'second', 'first']);
    },
  );

  test('cancel marks queued work and cancels the active runner', () async {
    final active = _request('active', 'active-audio');
    final queued = _request('queued', 'queued-audio');
    final started = Completer<void>();
    final calls = <AudioSubtitleRequest>[];
    CancelToken? activeToken;
    final controller = AudioSubtitleGenerationController((
      request,
      cancelToken,
      _,
    ) async {
      calls.add(request);
      activeToken = cancelToken;
      started.complete();
      await cancelToken.whenCancel;
      return (status: AudioSubtitleGenerationStatus.cancelled, path: null);
    });
    addTearDown(controller.dispose);

    controller.enqueue([active, queued]);
    await started.future;

    controller.cancel(queued.identity);
    controller.cancel(active.identity);
    final activeJob = await _waitForJob(
      controller,
      active.identity,
      AudioSubtitleGenerationStatus.cancelled,
    );

    expect(activeJob.status, AudioSubtitleGenerationStatus.cancelled);
    expect(
      controller.state
          .singleWhere((job) => job.identity == queued.identity)
          .status,
      AudioSubtitleGenerationStatus.cancelled,
    );
    expect(activeToken!.isCancelled, isTrue);
    expect(calls, [active]);
  });

  test('cancelAll cancels active and queued jobs', () async {
    final active = _request('active', 'active-audio');
    final queued = _request('queued', 'queued-audio');
    final started = Completer<void>();
    final controller = AudioSubtitleGenerationController((
      _,
      cancelToken,
      __,
    ) async {
      started.complete();
      await cancelToken.whenCancel;
      return (status: AudioSubtitleGenerationStatus.cancelled, path: null);
    });
    addTearDown(controller.dispose);

    controller.enqueue([active, queued]);
    await started.future;
    controller.cancelAll();
    await _waitForJob(
      controller,
      active.identity,
      AudioSubtitleGenerationStatus.cancelled,
    );

    expect(controller.state.map((job) => job.status).toList(), [
      AudioSubtitleGenerationStatus.cancelled,
      AudioSubtitleGenerationStatus.cancelled,
    ]);
  });

  test('dispose cancels the active runner token', () async {
    final started = Completer<void>();
    final runnerStopped = Completer<void>();
    CancelToken? activeToken;
    final controller = AudioSubtitleGenerationController((
      _,
      cancelToken,
      __,
    ) async {
      activeToken = cancelToken;
      started.complete();
      try {
        await cancelToken.whenCancel;
        throw cancelToken.cancelError!;
      } finally {
        runnerStopped.complete();
      }
    });

    controller.enqueue([_request('active', 'active-audio')]);
    await started.future;
    controller.dispose();

    expect(activeToken!.isCancelled, isTrue);
    await runnerStopped.future;
  });

  test(
    'does not load track A subtitles after playback changes to track B',
    () async {
      final trackA = _track('track-a', 'audio-a');
      final trackB = _track('track-b', 'audio-b');
      final requestA = AudioSubtitleRequest(track: trackA, fileTree: const []);
      final trackChanges = StreamController<AudioTrack?>.broadcast(sync: true);
      final trackAReady = Completer<void>();
      final trackBReady = Completer<void>();
      final runnerStarted = Completer<void>();
      final generationResult = Completer<AudioSubtitleGenerationResult>();
      late _RecordingLyricController lyricController;
      final service = _DelayedGenerationService((request, cancelToken, _) {
        expect(identical(request, requestA), isTrue);
        runnerStarted.complete();
        return Future.any([
          generationResult.future,
          cancelToken.whenCancel.then<AudioSubtitleGenerationResult>((_) {
            throw cancelToken.cancelError!;
          }),
        ]);
      });
      final container = ProviderContainer(
        overrides: [
          currentTrackProvider.overrideWith((ref) => trackChanges.stream),
          audioSubtitleGenerationServiceProvider.overrideWithValue(service),
          lyricControllerProvider.overrideWith((ref) {
            lyricController = _RecordingLyricController(ref);
            return lyricController;
          }),
        ],
      );
      final trackSubscription = container.listen(currentTrackProvider, (
        _,
        value,
      ) {
        if (value.valueOrNull == trackA && !trackAReady.isCompleted) {
          trackAReady.complete();
        }
        if (value.valueOrNull == trackB && !trackBReady.isCompleted) {
          trackBReady.complete();
        }
      }, fireImmediately: true);
      addTearDown(() async {
        trackSubscription.close();
        container.dispose();
        await trackChanges.close();
      });

      trackChanges.add(trackA);
      await trackAReady.future;
      final controller = container.read(
        audioSubtitleGenerationProvider.notifier,
      );
      container.read(lyricControllerProvider.notifier);
      controller.enqueue([requestA]);
      await runnerStarted.future;

      trackChanges.add(trackB);
      await trackBReady.future;
      generationResult.complete((
        status: AudioSubtitleGenerationStatus.completed,
        path: '/generated/track-a.srt',
      ));
      final completedJob = await _waitForJob(
        controller,
        requestA.identity,
        AudioSubtitleGenerationStatus.completed,
      );

      expect(completedJob.request, requestA);
      expect(lyricController.loadedPaths, isEmpty);
    },
  );
}

AudioSubtitleRequest _request(String id, String hash) => AudioSubtitleRequest(
  track: AudioTrack(
    id: id,
    title: '$id.mp3',
    url: 'https://example.test/$id.mp3',
    workId: 1,
    hash: hash,
  ),
  fileTree: const [],
);

AudioTrack _track(String id, String hash) => AudioTrack(
  id: id,
  title: '$id.mp3',
  url: 'https://example.test/$id.mp3',
  workId: 1,
  hash: hash,
);

Future<AudioSubtitleJob> _waitForJob(
  AudioSubtitleGenerationController controller,
  String identity,
  AudioSubtitleGenerationStatus status,
) {
  AudioSubtitleJob? matchingJob(List<AudioSubtitleJob> jobs) {
    for (final job in jobs) {
      if (job.identity == identity && job.status == status) return job;
    }
    return null;
  }

  final current = matchingJob(controller.state);
  if (current != null) return Future.value(current);

  final completed = Completer<AudioSubtitleJob>();
  late final void Function() removeListener;
  removeListener = controller.addListener((jobs) {
    final job = matchingJob(jobs);
    if (job != null && !completed.isCompleted) {
      completed.complete(job);
    }
  }, fireImmediately: false);
  return completed.future.whenComplete(removeListener);
}

class _DelayedGenerationService extends AudioSubtitleGenerationService {
  _DelayedGenerationService(this.runner);

  final AudioSubtitleRunner runner;

  @override
  Future<AudioSubtitleGenerationResult> generate(
    AudioSubtitleRequest request,
    CancelToken cancelToken,
    AudioSubtitleProgress onProgress,
  ) => runner(request, cancelToken, onProgress);
}

class _RecordingLyricController extends LyricController {
  _RecordingLyricController(super.ref);

  final loadedPaths = <String>[];

  @override
  Future<void> loadLyricFromLocalFile(String filePath) async {
    loadedPaths.add(filePath);
  }
}

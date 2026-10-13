import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/download_task.dart';
import 'package:kikoeru_flutter/src/models/download_task_change.dart';
import 'package:kikoeru_flutter/src/providers/player_subtitle_candidates_provider.dart';
import 'package:kikoeru_flutter/src/services/audio_subtitle_generation_service.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_store.dart';
import 'package:kikoeru_flutter/src/services/local_audio_transcriber.dart';
import 'package:kikoeru_flutter/src/services/local_subtitle_model_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'audio-subtitle-generation-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'only reuses a parseable subtitle that matches the current audio',
    () async {
      final matchingPath = p.join(temporaryDirectory.path, 'matching.srt');
      final mismatchedPath = p.join(temporaryDirectory.path, 'mismatched.srt');
      final corruptPath = p.join(temporaryDirectory.path, 'corrupt.srt');
      await File(matchingPath).writeAsString(_validSrt);
      await File(mismatchedPath).writeAsString(_validSrt);
      await File(corruptPath).writeAsString('not a subtitle');
      final request = _request(title: 'voice.txt');

      final matchingService = AudioSubtitleGenerationService(
        candidateRepository: _candidateRepository([
          _candidate(matchingPath, matchesCurrentAudio: true),
        ]),
      );
      final mismatchedService = AudioSubtitleGenerationService(
        candidateRepository: _candidateRepository([
          _candidate(mismatchedPath, matchesCurrentAudio: false),
        ]),
      );
      final corruptService = AudioSubtitleGenerationService(
        candidateRepository: _candidateRepository([
          _candidate(corruptPath, matchesCurrentAudio: true),
        ]),
      );

      final matchingResult = await matchingService.generate(
        request,
        CancelToken(),
        (_, _) {},
      );
      final mismatchedResult = await mismatchedService.generate(
        request,
        CancelToken(),
        (_, _) {},
      );
      final corruptResult = await corruptService.generate(
        request,
        CancelToken(),
        (_, _) {},
      );

      expect(matchingResult.status, AudioSubtitleGenerationStatus.skipped);
      expect(
        mismatchedResult.status,
        AudioSubtitleGenerationStatus.unsupported,
      );
      expect(corruptResult.status, AudioSubtitleGenerationStatus.unsupported);
    },
  );

  test(
    'generates and saves subtitles for an existing local audio file',
    () async {
      final audioPath = p.join(temporaryDirectory.path, 'voice.mp3');
      await File(audioPath).writeAsBytes([1, 2, 3]);
      final modelStore = _FakeModelStore();
      final transcriber = _FakeTranscriber();
      final subtitleStore = _FakeGeneratedSubtitleStore();
      final service = AudioSubtitleGenerationService(
        modelStore: modelStore,
        transcriber: transcriber,
        subtitleStore: subtitleStore,
        candidateRepository: _candidateRepository(const []),
      );
      final progress = <AudioSubtitleGenerationStatus>[];

      final result = await service.generate(
        _request(audioPath: audioPath),
        CancelToken(),
        (status, _) => progress.add(status),
      );

      expect(result.status, AudioSubtitleGenerationStatus.completed);
      expect(result.path, '/generated/voice.srt');
      expect(modelStore.calls, 1);
      expect(transcriber.audioPaths, [audioPath]);
      expect(transcriber.modelDirectories, ['/models']);
      expect(subtitleStore.saved, [_validSrt]);
      expect(progress, [
        AudioSubtitleGenerationStatus.checking,
        AudioSubtitleGenerationStatus.downloadingAudio,
        AudioSubtitleGenerationStatus.downloadingModel,
        AudioSubtitleGenerationStatus.transcribing,
        AudioSubtitleGenerationStatus.saving,
      ]);
    },
  );

  test(
    'does not save when cancellation reaches the generated subtitle store',
    () async {
      final audioPath = p.join(temporaryDirectory.path, 'voice.mp3');
      await File(audioPath).writeAsBytes([1, 2, 3]);
      final cancelToken = CancelToken();
      final subtitleStore = _FakeGeneratedSubtitleStore();
      final service = AudioSubtitleGenerationService(
        modelStore: _FakeModelStore(),
        transcriber: _FakeTranscriber(
          beforeReturn: (token) => token.cancel('test cancellation'),
        ),
        subtitleStore: subtitleStore,
        candidateRepository: _candidateRepository(const []),
      );

      await expectLater(
        service.generate(
          _request(audioPath: audioPath),
          cancelToken,
          (_, _) {},
        ),
        throwsA(isA<DioException>()),
      );

      expect(subtitleStore.saved, isEmpty);
    },
  );

  test(
    'returns an already completed download without waiting for a change',
    () async {
      final task = _downloadTask(status: DownloadStatus.completed);
      final repository = _FakeDownloadTaskRepository([task]);
      addTearDown(repository.close);

      final result = await AudioSubtitleGenerationService.waitForDownload(
        repository: repository,
        taskId: task.id,
        cancelToken: CancelToken(),
        onProgress: (_) {},
      );

      expect(result, task);
      expect(repository.changes.hasListener, isFalse);
    },
  );

  test('observes progress and completion after repository changes', () async {
    final pending = _downloadTask();
    final repository = _FakeDownloadTaskRepository([pending]);
    addTearDown(repository.close);
    final progress = <double>[];

    final waiting = AudioSubtitleGenerationService.waitForDownload(
      repository: repository,
      taskId: pending.id,
      cancelToken: CancelToken(),
      onProgress: progress.add,
    );
    final downloading = pending.copyWith(
      status: DownloadStatus.downloading,
      downloadedBytes: 25,
    );
    repository.update(downloading);
    final completed = downloading.copyWith(
      status: DownloadStatus.completed,
      downloadedBytes: 100,
    );
    repository.reset([completed]);

    expect(await waiting, completed);
    expect(progress, [0, 0.25]);
    expect(repository.changes.hasListener, isFalse);
  });

  for (final status in [DownloadStatus.paused, DownloadStatus.failed]) {
    test('stops waiting when the download becomes ${status.name}', () async {
      final pending = _downloadTask();
      final repository = _FakeDownloadTaskRepository([pending]);
      addTearDown(repository.close);

      final waiting = AudioSubtitleGenerationService.waitForDownload(
        repository: repository,
        taskId: pending.id,
        cancelToken: CancelToken(),
        onProgress: (_) {},
      );
      repository.update(pending.copyWith(status: status));

      await expectLater(waiting, throwsA(isA<StateError>()));
      expect(repository.changes.hasListener, isFalse);
    });
  }

  test('stops waiting when the download is removed', () async {
    final pending = _downloadTask();
    final repository = _FakeDownloadTaskRepository([pending]);
    addTearDown(repository.close);

    final waiting = AudioSubtitleGenerationService.waitForDownload(
      repository: repository,
      taskId: pending.id,
      cancelToken: CancelToken(),
      onProgress: (_) {},
    );
    repository.remove(pending.id);

    await expectLater(waiting, throwsA(isA<StateError>()));
    expect(repository.changes.hasListener, isFalse);
  });

  test(
    'cancellation releases the listener and preserves the download task',
    () async {
      final pending = _downloadTask();
      final repository = _FakeDownloadTaskRepository([pending]);
      addTearDown(repository.close);
      final cancelToken = CancelToken();

      final waiting = AudioSubtitleGenerationService.waitForDownload(
        repository: repository,
        taskId: pending.id,
        cancelToken: cancelToken,
        onProgress: (_) {},
      );
      cancelToken.cancel('test cancellation');

      await expectLater(waiting, throwsA(isA<DioException>()));
      expect(repository.changes.hasListener, isFalse);
      expect(repository.taskById(pending.id), pending);
    },
  );
}

const _validSrt = '1\n00:00:01,000 --> 00:00:02,000\nHello\n';

AudioSubtitleRequest _request({
  String? audioPath,
  String title = 'voice.mp3',
}) => AudioSubtitleRequest(
  track: AudioTrack(
    id: 'voice',
    title: title,
    url: 'file:///voice.mp3',
    workId: 123,
    hash: 'voice-hash',
    sourcePath: audioPath,
  ),
  fileTree: const [],
);

PlayerSubtitleCandidateRepository _candidateRepository(
  List<PlayerSubtitleCandidate> candidates,
) => PlayerSubtitleCandidateRepository(libraryLoader: (_) async => candidates);

PlayerSubtitleCandidate _candidate(
  String localPath, {
  required bool matchesCurrentAudio,
}) => PlayerSubtitleCandidate(
  identity: 'local:$localPath',
  title: p.basename(localPath),
  pathLabel: localPath,
  origin: PlayerSubtitleCandidateOrigin.library,
  source: {'localPath': localPath},
  matchesCurrentAudio: matchesCurrentAudio,
  matchScore: matchesCurrentAudio ? 1 : 0,
  sameDirectory: false,
);

DownloadTask _downloadTask({DownloadStatus status = DownloadStatus.pending}) =>
    DownloadTask(
      id: '123:hash:audio-hash',
      workId: 123,
      workTitle: 'Work',
      fileName: 'voice.mp3',
      downloadUrl: 'https://example.test/voice.mp3',
      hash: 'audio-hash',
      totalBytes: 100,
      status: status,
      createdAt: DateTime(2026),
    );

class _FakeModelStore extends LocalSubtitleModelStore {
  int calls = 0;

  @override
  Future<String> ensureReady({
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    calls++;
    return '/models';
  }
}

class _FakeTranscriber extends LocalAudioTranscriber {
  _FakeTranscriber({this.beforeReturn});

  final void Function(CancelToken cancelToken)? beforeReturn;
  final audioPaths = <String>[];
  final modelDirectories = <String>[];

  @override
  Future<String> transcribe({
    required String audioPath,
    required String modelDirectory,
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    audioPaths.add(audioPath);
    modelDirectories.add(modelDirectory);
    beforeReturn?.call(cancelToken);
    return _validSrt;
  }
}

class _FakeGeneratedSubtitleStore extends GeneratedSubtitleStore {
  final saved = <String>[];

  @override
  Future<String> save(
    AudioTrack track,
    String srt, {
    required CancelToken cancelToken,
  }) async {
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    saved.add(srt);
    return '/generated/${track.title.replaceAll('.mp3', '.srt')}';
  }
}

class _FakeDownloadTaskRepository implements DownloadTaskRepository {
  _FakeDownloadTaskRepository(Iterable<DownloadTask> tasks)
    : _tasks = List.of(tasks);

  final StreamController<DownloadTaskChange> changes =
      StreamController<DownloadTaskChange>.broadcast(sync: true);
  final List<DownloadTask> _tasks;

  @override
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  @override
  List<String> get taskIds => _tasks.map((task) => task.id).toList();

  @override
  DownloadTaskSummary get summary => DownloadTaskSummary.fromTasks(_tasks);

  @override
  Stream<DownloadTaskChange> get taskChangesStream => changes.stream;

  @override
  DownloadTask? taskById(String taskId) {
    for (final task in _tasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  void update(DownloadTask task) {
    final index = _tasks.indexWhere((current) => current.id == task.id);
    final previous = _tasks[index];
    _tasks[index] = task;
    changes.add(
      DownloadTaskChange.updated(
        task: task,
        previousTask: previous,
        index: index,
      ),
    );
  }

  void reset(Iterable<DownloadTask> tasks) {
    _tasks
      ..clear()
      ..addAll(tasks);
    changes.add(DownloadTaskChange.reset(taskIds));
  }

  void remove(String taskId) {
    final index = _tasks.indexWhere((task) => task.id == taskId);
    final task = _tasks.removeAt(index);
    changes.add(DownloadTaskChange.removed(task, index));
  }

  Future<void> close() => changes.close();
}

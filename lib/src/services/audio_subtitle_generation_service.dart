import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
import '../models/download_task.dart';
import '../models/download_task_change.dart';
import '../models/lyric/lyric_parser.dart';
import '../providers/player_subtitle_candidates_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/encoding_utils.dart';
import '../utils/local_file_url.dart';
import 'audio_file_url_resolver.dart';
import 'cache_service.dart';
import 'download_file_path_service.dart';
import 'download_path_service.dart';
import 'download_service.dart';
import 'generated_subtitle_store.dart';
import 'local_audio_transcriber.dart';
import 'local_subtitle_model_store.dart';
import 'remote_asset_cache.dart';
import 'storage_service.dart';

enum AudioSubtitleGenerationStatus {
  queued,
  checking,
  downloadingAudio,
  downloadingModel,
  transcribing,
  saving,
  completed,
  skipped,
  unsupported,
  failed,
  cancelled;

  bool get isFinished => index >= completed.index;
}

class AudioSubtitleRequest {
  const AudioSubtitleRequest({
    required this.track,
    required this.fileTree,
    this.parentPath,
    this.downloadUrl,
    this.totalBytes,
    this.workMetadata,
    this.host = '',
    this.token = '',
  });

  final AudioTrack track;
  final List<dynamic> fileTree;
  final String? parentPath;
  final String? downloadUrl;
  final int? totalBytes;
  final Map<String, dynamic>? workMetadata;
  final String host;
  final String token;

  String get identity => GeneratedSubtitleStore.audioIdentity(track);
}

typedef AudioSubtitleGenerationResult = ({
  AudioSubtitleGenerationStatus status,
  String? path,
});

typedef AudioSubtitleProgress =
    void Function(AudioSubtitleGenerationStatus status, double progress);

typedef AudioSubtitleRunner =
    Future<AudioSubtitleGenerationResult> Function(
      AudioSubtitleRequest request,
      CancelToken cancelToken,
      AudioSubtitleProgress onProgress,
    );

class AudioSubtitleGenerationService {
  AudioSubtitleGenerationService({
    LocalSubtitleModelStore? modelStore,
    LocalAudioTranscriber? transcriber,
    GeneratedSubtitleStore? subtitleStore,
    PlayerSubtitleCandidateRepository? candidateRepository,
  }) : _modelStore = modelStore ?? LocalSubtitleModelStore(),
       _transcriber = transcriber ?? LocalAudioTranscriber(),
       _subtitleStore = subtitleStore ?? const GeneratedSubtitleStore(),
       _candidateRepository =
           candidateRepository ?? const PlayerSubtitleCandidateRepository();

  final LocalSubtitleModelStore _modelStore;
  final LocalAudioTranscriber _transcriber;
  final GeneratedSubtitleStore _subtitleStore;
  final PlayerSubtitleCandidateRepository _candidateRepository;

  Future<bool> hasUsableSubtitle(
    AudioSubtitleRequest request,
    CancelToken cancelToken,
  ) async {
    final candidates = await _candidateRepository.load(
      track: request.track,
      fileTree: request.fileTree,
      audioParentPath: request.parentPath,
      libraryPriority: SubtitleLibraryPriority.lowest,
    );
    for (final candidate in candidates.where((c) => c.matchesCurrentAudio)) {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      try {
        final localPath = candidate.source['localPath']?.toString();
        String? text;
        if (localPath != null && localPath.isNotEmpty) {
          text = (await EncodingUtils.readFileWithEncoding(File(localPath))).$1;
        } else {
          final hash = candidate.source['hash']?.toString();
          if (hash == null || hash.isEmpty) continue;
          final workId = request.track.workId;
          if (workId != null) {
            text = await CacheService.getCachedTextContent(
              workId: workId,
              hash: hash,
              fileName: candidate.title,
            );
          }
          if (text == null) {
            var url = candidate.source['mediaDownloadUrl']?.toString() ?? '';
            final host = request.host.isEmpty
                ? ''
                : AudioFileUrlResolver.normalizeMediaHost(request.host);
            if (url.startsWith('/')) url = '$host$url';
            if (url.isEmpty && host.isNotEmpty) {
              url = '$host/api/media/stream/$hash';
            }
            if (url.isEmpty) continue;
            if (request.token.isNotEmpty && !url.contains('token=')) {
              url += '${url.contains('?') ? '&' : '?'}token=${request.token}';
            }
            final lease = CacheService.remoteTextLoader.acquire(
              uri: Uri.parse(url),
              key: CacheService.remoteAssetKey(
                kind: RemoteAssetKind.subtitle,
                identity: hash,
              ),
              headers: StorageService.serverCookieHeaders,
            );
            try {
              text = (await Future.any([
                lease.content,
                cancelToken.whenCancel.then((error) => throw error),
              ])).text;
            } finally {
              await lease.release();
            }
          }
        }
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
        LyricParser.parse(text);
        return true;
      } catch (_) {
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      }
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    return false;
  }

  Future<AudioSubtitleGenerationResult> generate(
    AudioSubtitleRequest request,
    CancelToken cancelToken,
    AudioSubtitleProgress onProgress,
  ) async {
    onProgress(AudioSubtitleGenerationStatus.checking, 0);
    if (await hasUsableSubtitle(request, cancelToken)) {
      return (status: AudioSubtitleGenerationStatus.skipped, path: null);
    }
    final extension = p.extension(request.track.title).toLowerCase();
    if (!const {'.mp3', '.wav', '.flac'}.contains(extension)) {
      return (status: AudioSubtitleGenerationStatus.unsupported, path: null);
    }
    onProgress(AudioSubtitleGenerationStatus.downloadingAudio, 0);
    final audioPath = await _resolveAudio(request, cancelToken, onProgress);
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    onProgress(AudioSubtitleGenerationStatus.downloadingModel, 0);
    final modelDirectory = await _modelStore.ensureReady(
      cancelToken: cancelToken,
      onProgress: (value) =>
          onProgress(AudioSubtitleGenerationStatus.downloadingModel, value),
    );
    onProgress(AudioSubtitleGenerationStatus.transcribing, 0);
    final srt = await _transcriber.transcribe(
      audioPath: audioPath,
      modelDirectory: modelDirectory,
      cancelToken: cancelToken,
      onProgress: (value) =>
          onProgress(AudioSubtitleGenerationStatus.transcribing, value),
    );
    onProgress(AudioSubtitleGenerationStatus.saving, 0);
    final path = await _subtitleStore.save(
      request.track,
      srt,
      cancelToken: cancelToken,
    );
    return (status: AudioSubtitleGenerationStatus.completed, path: path);
  }

  Future<String> _resolveAudio(
    AudioSubtitleRequest request,
    CancelToken cancelToken,
    AudioSubtitleProgress onProgress,
  ) async {
    final track = request.track;
    final localPath = track.sourcePath ?? LocalFileUrl.pathFromUrl(track.url);
    if (localPath != null && await File(localPath).exists()) return localPath;
    final hash = track.hash;
    if (hash != null && hash.isNotEmpty) {
      final cached = await CacheService.getCachedAudioFile(hash);
      if (cached != null) return cached;
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    final downloadUrl = request.downloadUrl;
    if (track.workId == null || downloadUrl == null || downloadUrl.isEmpty) {
      throw StateError('A complete local audio file is unavailable.');
    }
    final downloads = DownloadService.instance;
    final task = await downloads.addTask(
      workId: track.workId!,
      workTitle: track.album ?? track.title,
      fileName: track.title,
      relativePath: request.parentPath,
      downloadUrl: downloadUrl,
      hash: hash,
      totalBytes: request.totalBytes,
      workMetadata: request.workMetadata,
      coverUrl: track.artworkUrl,
    );
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    if (task.status == DownloadStatus.failed ||
        task.status == DownloadStatus.paused) {
      await downloads.resumeTask(task.id);
    }
    final completed = await waitForDownload(
      repository: downloads,
      taskId: task.id,
      cancelToken: cancelToken,
      onProgress: (value) =>
          onProgress(AudioSubtitleGenerationStatus.downloadingAudio, value),
    );
    final root = await DownloadPathService.getDownloadDirectory();
    final path = DownloadFilePathService.localPathForWorkRelativePath(
      rootPath: root.path,
      workId: track.workId!,
      relativePath: completed.fileName,
    );
    if (!await File(path).exists()) {
      throw FileSystemException('Downloaded audio file is missing', path);
    }
    return path;
  }

  static Future<DownloadTask> waitForDownload({
    required DownloadTaskRepository repository,
    required String taskId,
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    final completion = Completer<DownloadTask>();
    void update() {
      if (completion.isCompleted) return;
      final task = repository.taskById(taskId);
      if (task == null) {
        completion.completeError(StateError('Audio download was removed.'));
      } else if (task.status == DownloadStatus.completed) {
        completion.complete(task);
      } else if (task.status == DownloadStatus.failed ||
          task.status == DownloadStatus.paused) {
        completion.completeError(
          StateError('Audio download ${task.status.name}.'),
        );
      } else {
        onProgress(task.progress.clamp(0.0, 1.0));
      }
    }

    final subscription = repository.taskChangesStream.listen((event) {
      if (event.type == DownloadTaskChangeType.reset ||
          event.taskId == taskId) {
        update();
      }
    });
    try {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      update();
      return await Future.any([
        completion.future,
        cancelToken.whenCancel.then((error) => throw error),
      ]);
    } finally {
      await subscription.cancel();
    }
  }
}

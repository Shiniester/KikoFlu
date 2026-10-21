import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
import '../models/download_task.dart';
import '../models/download_task_change.dart';
import '../models/work.dart';
import '../models/lyric/lyric_parser.dart';
import '../providers/player_subtitle_candidates_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/encoding_utils.dart';
import '../utils/file_tree_utils.dart';
import '../utils/local_file_url.dart';
import 'audio_file_url_resolver.dart';
import 'cache_service.dart';
import 'download_file_path_service.dart';
import 'download_path_service.dart';
import 'download_service.dart';
import 'generated_subtitle_store.dart';
import 'local_audio_transcriber.dart';
import 'local_subtitle_model_store.dart';
import 'player_audio_variant_classifier.dart';
import 'remote_asset_cache.dart';
import 'storage_service.dart';

enum AudioSubtitleGenerationStatus {
  queued,
  checking,
  downloadingAudio,
  downloadingModel,
  transcribing,
  saving,
  translating,
  completed,
  skipped,
  unsupported,
  failed,
  translationFailed,
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

typedef AudioSubtitleAudioDownloader =
    Future<String> Function({
      required AudioSubtitleRequest request,
      required String fileName,
      required String relativePath,
      required String downloadUrl,
      required String? hash,
      required int? totalBytes,
      required CancelToken cancelToken,
      required void Function(double) onProgress,
    });

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
    this.audioDownloader,
  }) : _modelStore = modelStore ?? LocalSubtitleModelStore(),
       _transcriber = transcriber ?? LocalAudioTranscriber(),
       _subtitleStore = subtitleStore ?? const GeneratedSubtitleStore(),
       _candidateRepository =
           candidateRepository ?? const PlayerSubtitleCandidateRepository();

  final LocalSubtitleModelStore _modelStore;
  final LocalAudioTranscriber _transcriber;
  final GeneratedSubtitleStore _subtitleStore;
  final PlayerSubtitleCandidateRepository _candidateRepository;
  final AudioSubtitleAudioDownloader? audioDownloader;

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
      if (await isUsableSubtitleCandidate(candidate, request, cancelToken)) {
        return true;
      }
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    return false;
  }

  static Future<bool> isUsableSubtitleCandidate(
    PlayerSubtitleCandidate candidate,
    AudioSubtitleRequest request,
    CancelToken cancelToken,
  ) async {
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    try {
      final localPath = candidate.source['localPath']?.toString();
      String? text;
      if (localPath != null && localPath.isNotEmpty) {
        text = (await EncodingUtils.readFileWithEncoding(File(localPath))).$1;
      } else {
        final hash = candidate.source['hash']?.toString();
        if (hash == null || hash.isEmpty) return false;
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
          if (url.isEmpty) return false;
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

    final variants = request.fileTree.isEmpty
        ? const <PlayerAudioVariant>[]
        : const PlayerAudioVariantClassifier().scan(request.fileTree);
    final original = _findOriginalVariant(request, variants);
    if (original != null) {
      final localOriginal = await _existingLocalPath(request, original);
      if (localOriginal != null) return localOriginal;
    }

    final hash = track.hash?.isNotEmpty == true
        ? track.hash
        : _fileString(original?.source, 'hash');
    if (hash != null && hash.isNotEmpty) {
      final cached = await _cachedAudioPath(request, hash);
      if (cached != null) return cached;
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;

    final alternative = _findMp3Alternative(original, variants);
    if (alternative != null) {
      final localAlternative = await _existingAlternativePath(
        request,
        alternative,
      );
      if (localAlternative != null) return localAlternative;
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;

      final alternativeHash = _fileString(alternative.source, 'hash');
      final alternativeUrl = _audioDownloadUrl(request, alternative);
      if (alternativeUrl != null) {
        return _downloadAudio(
          request: request,
          fileName: alternative.title,
          relativePath: alternative.parentPath,
          downloadUrl: alternativeUrl,
          hash: alternativeHash,
          totalBytes: _fileSize(alternative.source),
          cancelToken: cancelToken,
          onProgress: (value) =>
              onProgress(AudioSubtitleGenerationStatus.downloadingAudio, value),
        );
      }
    }

    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    final downloadUrl = request.downloadUrl?.isNotEmpty == true
        ? request.downloadUrl
        : original == null
        ? null
        : _audioDownloadUrl(request, original);
    if (track.workId == null || downloadUrl == null || downloadUrl.isEmpty) {
      throw StateError('A complete local audio file is unavailable.');
    }
    return _downloadAudio(
      request: request,
      fileName: original?.title ?? track.title,
      relativePath: request.parentPath ?? original?.parentPath ?? '',
      downloadUrl: downloadUrl,
      hash: hash,
      totalBytes: request.totalBytes ?? _fileSize(original?.source),
      cancelToken: cancelToken,
      onProgress: (value) =>
          onProgress(AudioSubtitleGenerationStatus.downloadingAudio, value),
    );
  }

  PlayerAudioVariant? _findOriginalVariant(
    AudioSubtitleRequest request,
    List<PlayerAudioVariant> variants,
  ) {
    final track = request.track;
    final requestedPath = _trackPath(track.title, request.parentPath);
    final trackHash = track.hash?.isNotEmpty == true ? track.hash : null;
    final originalMatches = variants
        .where((variant) {
          final variantHash = _fileString(variant.source, 'hash');
          if (trackHash != null && variantHash != trackHash) return false;
          return request.parentPath == null
              ? variant.title == track.title
              : variant.fullPath == requestedPath;
        })
        .toList(growable: false);
    return originalMatches.length == 1 ? originalMatches.single : null;
  }

  PlayerAudioVariant? _findMp3Alternative(
    PlayerAudioVariant? original,
    List<PlayerAudioVariant> variants,
  ) {
    if (original == null || original.format == PlayerAudioFormat.mp3) {
      return null;
    }
    final originalHash = _fileString(original.source, 'hash');
    final identity = _normalizedTrackPath(original.fullPath);
    final alternatives = variants
        .where((variant) {
          if (identical(variant.source, original.source) ||
              variant.fullPath == original.fullPath ||
              variant.format != PlayerAudioFormat.mp3 ||
              _normalizedTrackPath(variant.fullPath) != identity ||
              variant.se != original.se ||
              variant.ejaculation != original.ejaculation) {
            return false;
          }
          final variantHash = _fileString(variant.source, 'hash');
          return originalHash == null || variantHash != originalHash;
        })
        .toList(growable: false);
    return alternatives.length == 1 ? alternatives.single : null;
  }

  Future<String?> _existingAlternativePath(
    AudioSubtitleRequest request,
    PlayerAudioVariant alternative,
  ) async {
    final localPath = await _existingLocalPath(request, alternative);
    if (localPath != null) return localPath;

    final hash = _fileString(alternative.source, 'hash');
    if (hash == null) return null;
    return _cachedAudioPath(request, hash);
  }

  Future<String?> _existingLocalPath(
    AudioSubtitleRequest request,
    PlayerAudioVariant variant,
  ) async {
    final sourcePath = _fileString(variant.source, 'localPath');
    if (sourcePath != null && await File(sourcePath).exists()) {
      return sourcePath;
    }

    final workDirectory = request.track.subtitleWorkDirPath;
    if (workDirectory != null) {
      final relativePath = DownloadFilePathService.localRelativePathForItem(
        variant.source,
        variant.parentPath,
      );
      final localPath = DownloadFilePathService.localPathForRelativePath(
        rootPath: workDirectory,
        relativePath: relativePath,
      );
      if (await File(localPath).exists()) return localPath;
    }
    return null;
  }

  Future<String?> _cachedAudioPath(
    AudioSubtitleRequest request,
    String hash,
  ) async {
    final workId = request.track.workId;
    if (workId != null) {
      final downloaded = await DownloadService.instance.getDownloadedFilePath(
        workId,
        hash,
      );
      if (downloaded != null) return downloaded;
    }
    return CacheService.getCachedAudioFile(hash);
  }

  String? _audioDownloadUrl(
    AudioSubtitleRequest request,
    PlayerAudioVariant variant,
  ) {
    var url = _fileString(variant.source, 'mediaDownloadUrl') ?? '';
    final host = request.host.isEmpty
        ? ''
        : AudioFileUrlResolver.normalizeMediaHost(request.host);
    if (url.startsWith('/')) {
      if (host.isEmpty) return null;
      url = '$host$url';
    }
    final hash = _fileString(variant.source, 'hash');
    if (url.isEmpty && host.isNotEmpty && hash != null) {
      url =
          '$host/api/media/download/$hash/${Uri.encodeComponent(variant.title)}';
    }
    if (url.isEmpty) return null;
    if ((request.track.workId ?? 0) >= 0 &&
        request.token.isNotEmpty &&
        !url.contains('token=')) {
      url += '${url.contains('?') ? '&' : '?'}token=${request.token}';
    }
    return url;
  }

  Future<String> _downloadAudio({
    required AudioSubtitleRequest request,
    required String fileName,
    required String relativePath,
    required String downloadUrl,
    required String? hash,
    required int? totalBytes,
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) {
    return (audioDownloader ?? _downloadAudioWithService)(
      request: request,
      fileName: fileName,
      relativePath: relativePath,
      downloadUrl: downloadUrl,
      hash: hash,
      totalBytes: totalBytes,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  Future<String> _downloadAudioWithService({
    required AudioSubtitleRequest request,
    required String fileName,
    required String relativePath,
    required String downloadUrl,
    required String? hash,
    required int? totalBytes,
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    final track = request.track;
    if (track.workId == null) {
      throw StateError('A complete local audio file is unavailable.');
    }
    final downloads = DownloadService.instance;
    final task = await downloads.addTask(
      workId: track.workId!,
      workTitle: track.album ?? track.title,
      fileName: fileName,
      relativePath: relativePath.isEmpty ? null : relativePath,
      downloadUrl: downloadUrl,
      hash: hash,
      totalBytes: totalBytes,
      workMetadata: request.workMetadata,
      startTimeMs: track.startTimeMs,
      endTimeMs: track.endTimeMs,
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
      onProgress: onProgress,
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

  String? _fileString(dynamic source, String key) {
    final value =
        (source is AudioFile
                ? source.toJson()[key]
                : FileTreeUtils.property(source, key))
            ?.toString();
    return value == null || value.isEmpty ? null : value;
  }

  int? _fileSize(dynamic source) {
    final value = FileTreeUtils.property(source, 'size');
    return value is num ? value.toInt() : null;
  }

  String _trackPath(String title, String? parentPath) {
    final parentSegments =
        parentPath
            ?.replaceAll('\\', '/')
            .split('/')
            .where((segment) => segment.isNotEmpty)
            .toList() ??
        const <String>[];
    return [...parentSegments, title].join('/');
  }

  String _normalizedTrackPath(String fullPath) {
    final segments = fullPath.replaceAll('\\', '/').split('/');
    final fileName = segments.removeLast();
    final extension = p.extension(fileName);
    final stem = extension.isEmpty
        ? fileName
        : fileName.substring(0, fileName.length - extension.length);
    final directories = segments
        .map(
          (segment) => segment
              .replaceAll(
                RegExp(
                  r'(?<![A-Za-z0-9])(?:wav|flac|mp3|opus|m4a|aac)(?![A-Za-z0-9])',
                  caseSensitive: false,
                ),
                '',
              )
              .replaceAll(
                RegExp(r'^[\s._\-()（）\[\]【】]+|[\s._\-()（）\[\]【】]+$'),
                '',
              ),
        )
        .where((segment) => segment.isNotEmpty);
    return [...directories, stem].join('/');
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

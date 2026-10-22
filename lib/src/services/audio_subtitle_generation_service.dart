import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
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
import 'generated_subtitle_store.dart';
import 'local_audio_transcriber.dart';
import 'local_subtitle_model_store.dart';
import 'player_audio_variant_classifier.dart';
import 'remote_asset_cache.dart';
import 'resumable_file_transfer.dart';
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
    this.selectedAudio,
    this.workMetadata,
    this.host = '',
    this.token = '',
  });

  final AudioTrack track;
  final List<dynamic> fileTree;
  final String? parentPath;
  final String? downloadUrl;
  final int? totalBytes;
  final PlayerAudioVariant? selectedAudio;
  final Map<String, dynamic>? workMetadata;
  final String host;
  final String token;

  String get identity => GeneratedSubtitleStore.audioIdentity(track);
}

typedef AudioSubtitleGenerationResult = ({
  AudioSubtitleGenerationStatus status,
  String? path,
});

class _ResolvedAudio {
  const _ResolvedAudio(this.path, {this.temporaryDirectory});

  final String path;
  final Directory? temporaryDirectory;
}

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
    final extension = p
        .extension(request.selectedAudio?.title ?? request.track.title)
        .toLowerCase();
    if (!const {'.mp3', '.wav', '.flac'}.contains(extension)) {
      return (status: AudioSubtitleGenerationStatus.unsupported, path: null);
    }
    onProgress(AudioSubtitleGenerationStatus.downloadingAudio, 0);
    final audio = await _resolveAudio(request, cancelToken, onProgress);
    try {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      onProgress(AudioSubtitleGenerationStatus.downloadingModel, 0);
      final modelDirectory = await _modelStore.ensureReady(
        cancelToken: cancelToken,
        onProgress: (value) =>
            onProgress(AudioSubtitleGenerationStatus.downloadingModel, value),
      );
      onProgress(AudioSubtitleGenerationStatus.transcribing, 0);
      final srt = await _transcriber.transcribe(
        audioPath: audio.path,
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
    } finally {
      final temporaryDirectory = audio.temporaryDirectory;
      if (temporaryDirectory != null && await temporaryDirectory.exists()) {
        try {
          await temporaryDirectory.delete(recursive: true);
        } on FileSystemException {
          // Temporary audio cleanup must not replace a generation result.
        }
      }
    }
  }

  Future<_ResolvedAudio> _resolveAudio(
    AudioSubtitleRequest request,
    CancelToken cancelToken,
    AudioSubtitleProgress onProgress,
  ) async {
    final track = request.track;
    final variants = request.fileTree.isEmpty
        ? const <PlayerAudioVariant>[]
        : const PlayerAudioVariantClassifier().scan(request.fileTree);
    final original = _findOriginalVariant(request, variants);
    final selected = request.selectedAudio ?? original;
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;

    if (selected != null) {
      if (track.subtitleWorkDirPath != null) {
        final localPath = await _existingLocalPath(request, selected);
        if (localPath != null) return _ResolvedAudio(localPath);
        throw StateError('A complete local audio file is unavailable.');
      }
      final downloadUrl = _audioDownloadUrl(request, selected);
      if (downloadUrl != null) {
        return _downloadAudio(
          request: request,
          fileName: selected.title,
          relativePath: selected.parentPath,
          downloadUrl: downloadUrl,
          hash: _fileString(selected.source, 'hash'),
          totalBytes: _fileSize(selected.source),
          cancelToken: cancelToken,
          onProgress: (value) =>
              onProgress(AudioSubtitleGenerationStatus.downloadingAudio, value),
        );
      }

      if (request.selectedAudio == null &&
          request.downloadUrl?.isNotEmpty == true) {
        return _downloadAudio(
          request: request,
          fileName: selected.title,
          relativePath: selected.parentPath,
          downloadUrl: request.downloadUrl!,
          hash: _fileString(selected.source, 'hash'),
          totalBytes: request.totalBytes ?? _fileSize(selected.source),
          cancelToken: cancelToken,
          onProgress: (value) =>
              onProgress(AudioSubtitleGenerationStatus.downloadingAudio, value),
        );
      }

      final localPath = await _existingLocalPath(request, selected);
      if (localPath != null) return _ResolvedAudio(localPath);

      // The request URL describes the original track. Never use it for an
      // explicitly selected variant, which may use a different mix or format.
      if (request.selectedAudio != null) {
        throw StateError('A complete local audio file is unavailable.');
      }
    } else {
      if (track.subtitleWorkDirPath != null) {
        final localPath =
            track.sourcePath ?? LocalFileUrl.pathFromUrl(track.url);
        if (localPath != null && await File(localPath).exists()) {
          return _ResolvedAudio(localPath);
        }
        throw StateError('A complete local audio file is unavailable.');
      }
      final downloadUrl = request.downloadUrl?.isNotEmpty == true
          ? request.downloadUrl
          : track.url.startsWith('http')
          ? track.url
          : null;
      if (downloadUrl != null && downloadUrl.isNotEmpty) {
        return _downloadAudio(
          request: request,
          fileName: track.title,
          relativePath: request.parentPath ?? '',
          downloadUrl: downloadUrl,
          hash: track.hash,
          totalBytes: request.totalBytes,
          cancelToken: cancelToken,
          onProgress: (value) =>
              onProgress(AudioSubtitleGenerationStatus.downloadingAudio, value),
        );
      }
      final localPath = track.sourcePath ?? LocalFileUrl.pathFromUrl(track.url);
      if (localPath != null && await File(localPath).exists()) {
        return _ResolvedAudio(localPath);
      }
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    throw StateError('A complete local audio file is unavailable.');
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
    if (url.isEmpty &&
        host.isNotEmpty &&
        hash != null &&
        !hash.startsWith('local:')) {
      url =
          '$host/api/media/download/$hash/${Uri.encodeComponent(variant.title)}';
    }
    if (url.isEmpty) return null;
    if (request.token.isNotEmpty && !url.contains('token=')) {
      url += '${url.contains('?') ? '&' : '?'}token=${request.token}';
    }
    return url;
  }

  Future<_ResolvedAudio> _downloadAudio({
    required AudioSubtitleRequest request,
    required String fileName,
    required String relativePath,
    required String downloadUrl,
    required String? hash,
    required int? totalBytes,
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) async {
    final downloader = audioDownloader;
    if (downloader != null) {
      final path = await downloader(
        request: request,
        fileName: fileName,
        relativePath: relativePath,
        downloadUrl: downloadUrl,
        hash: hash,
        totalBytes: totalBytes,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
      return _ResolvedAudio(path);
    }

    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'kikoflu-audio-subtitle-',
    );
    try {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      final temporaryFile = File(
        p.join(temporaryDirectory.path, p.basename(fileName)),
      );
      final cancellation = RemoteAssetCancellation();
      unawaited(cancelToken.whenCancel.then((_) => cancellation.cancel()));
      final result = await ResumableFileTransfer().download(
        uri: Uri.parse(downloadUrl),
        partialFile: temporaryFile,
        cancellation: cancellation,
        headers: StorageService.serverCookieHeaders,
        onProgress: (received, total) {
          onProgress(total == null || total <= 0 ? 0 : received / total);
        },
      );
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      if (result.totalBytes <= 0 || !await temporaryFile.exists()) {
        throw FileSystemException(
          'Downloaded audio file is empty',
          temporaryFile.path,
        );
      }
      return _ResolvedAudio(
        temporaryFile.path,
        temporaryDirectory: temporaryDirectory,
      );
    } catch (_) {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
      rethrow;
    }
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
}

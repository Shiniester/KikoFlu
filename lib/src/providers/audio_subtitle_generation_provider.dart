import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio_track.dart';
import '../models/work.dart';
import '../services/audio_file_url_resolver.dart';
import '../services/audio_subtitle_generation_service.dart';
import '../services/audio_track_queue_builder.dart';
import '../services/cache_service.dart';
import '../services/download_file_path_service.dart';
import '../services/download_path_service.dart';
import '../services/download_service.dart';
import '../services/generated_subtitle_store.dart';
import '../services/player_audio_variant_classifier.dart';
import '../utils/file_tree_utils.dart';
import '../utils/local_file_url.dart';
import 'audio_provider.dart';
import 'auth_provider.dart';
import 'lyric_provider.dart';
import 'player_work_details_provider.dart';

export '../services/audio_subtitle_generation_service.dart'
    show AudioSubtitleRequest, AudioSubtitleGenerationStatus;

class AudioSubtitleJob {
  const AudioSubtitleJob({
    required this.request,
    this.status = AudioSubtitleGenerationStatus.queued,
    this.progress = 0,
    this.path,
    this.failureStage,
  });

  final AudioSubtitleRequest request;
  final AudioSubtitleGenerationStatus status;
  final double progress;
  final String? path;
  final AudioSubtitleGenerationStatus? failureStage;

  String get identity => request.identity;
}

class AudioSubtitleGenerationController
    extends StateNotifier<List<AudioSubtitleJob>> {
  AudioSubtitleGenerationController(this._runner, {this.onCompleted})
    : super(const []);

  final AudioSubtitleRunner _runner;
  final void Function(AudioSubtitleRequest request, String path)? onCompleted;
  bool _draining = false;
  CancelToken? _activeToken;
  String? _activeIdentity;

  void enqueue(Iterable<AudioSubtitleRequest> requests) {
    final incoming = requests.toList(growable: false);
    if (incoming.isEmpty) return;
    final jobs = state.any((job) => !job.status.isFinished)
        ? List<AudioSubtitleJob>.of(state)
        : <AudioSubtitleJob>[];
    final identities = jobs
        .where((job) => !job.status.isFinished)
        .map((job) => job.identity)
        .toSet();
    for (final request in incoming) {
      if (identities.add(request.identity)) {
        jobs.removeWhere((job) => job.identity == request.identity);
        jobs.add(AudioSubtitleJob(request: request));
      }
    }
    state = List.unmodifiable(jobs);
    if (!_draining) unawaited(_drain());
  }

  void cancel(String identity) {
    if (_activeIdentity == identity) {
      _activeToken?.cancel();
      return;
    }
    final job = state.where((job) => job.identity == identity).firstOrNull;
    if (job?.status == AudioSubtitleGenerationStatus.queued) {
      _update(job!, AudioSubtitleGenerationStatus.cancelled);
    }
  }

  void cancelAll() {
    _activeToken?.cancel();
    state = List.unmodifiable([
      for (final job in state)
        if (job.status == AudioSubtitleGenerationStatus.queued)
          AudioSubtitleJob(
            request: job.request,
            status: AudioSubtitleGenerationStatus.cancelled,
          )
        else
          job,
    ]);
  }

  void _update(
    AudioSubtitleJob job,
    AudioSubtitleGenerationStatus status, {
    double progress = 0,
    String? path,
    AudioSubtitleGenerationStatus? failureStage,
  }) {
    if (!mounted) return;
    state = List.unmodifiable([
      for (final current in state)
        if (current.identity == job.identity)
          AudioSubtitleJob(
            request: job.request,
            status: status,
            progress: progress.clamp(0.0, 1.0),
            path: path,
            failureStage: failureStage,
          )
        else
          current,
    ]);
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (mounted) {
        final job = state
            .where((job) => job.status == AudioSubtitleGenerationStatus.queued)
            .firstOrNull;
        if (job == null) break;
        final token = CancelToken();
        _activeToken = token;
        _activeIdentity = job.identity;
        var stage = AudioSubtitleGenerationStatus.checking;
        _update(job, stage);
        try {
          final result = await _runner(job.request, token, (status, progress) {
            stage = status;
            _update(job, status, progress: progress);
          });
          _update(job, result.status, progress: 1, path: result.path);
          if (mounted && result.path != null) {
            onCompleted?.call(job.request, result.path!);
          }
        } catch (_) {
          _update(
            job,
            token.isCancelled
                ? AudioSubtitleGenerationStatus.cancelled
                : AudioSubtitleGenerationStatus.failed,
            failureStage: stage,
          );
        } finally {
          _activeToken = null;
          _activeIdentity = null;
        }
      }
    } finally {
      _draining = false;
    }
  }

  @override
  void dispose() {
    _activeToken?.cancel();
    super.dispose();
  }
}

final audioSubtitleGenerationServiceProvider =
    Provider<AudioSubtitleGenerationService>((ref) {
      return AudioSubtitleGenerationService();
    });

final audioSubtitleGenerationProvider =
    StateNotifierProvider<
      AudioSubtitleGenerationController,
      List<AudioSubtitleJob>
    >((ref) {
      return AudioSubtitleGenerationController(
        ref.read(audioSubtitleGenerationServiceProvider).generate,
        onCompleted: (request, path) {
          final current = ref.read(currentTrackProvider).valueOrNull;
          if (current != null &&
              GeneratedSubtitleStore.audioIdentity(current) ==
                  request.identity) {
            unawaited(
              ref
                  .read(lyricControllerProvider.notifier)
                  .loadLyricFromLocalFile(path),
            );
          }
        },
      );
    });

class AudioSubtitleActions {
  AudioSubtitleActions(this.ref);

  final Ref ref;

  /// Returns false when the existing subtitle picker should be opened.
  Future<bool> startCurrentTrack() async {
    final track = ref.read(currentTrackProvider).valueOrNull;
    if (track == null) return false;
    final details = ref.read(playerWorkDetailsProvider).valueOrNull;
    final work =
        details != null &&
            GeneratedSubtitleStore.audioIdentity(details.track) ==
                GeneratedSubtitleStore.audioIdentity(track)
        ? details.work
        : Work(id: track.workId ?? 0, title: track.album ?? track.title);
    final auth = ref.read(authProvider);
    final fileList = ref.read(fileListControllerProvider);
    final loader = ref.read(playbackLyricFileTreeLoaderProvider);
    var files = fileList.matches(track) ? fileList.files : <dynamic>[];
    if (files.isEmpty &&
        canLoadPlayerWorkFileTree(
          track: track,
          isLoggedIn: auth.isLoggedIn,
          host: auth.host,
        )) {
      try {
        files = await loader(track);
      } catch (_) {
        // Local files and complete caches can still be transcribed offline.
      }
    }
    final variants = const PlayerAudioVariantClassifier().scan(files);
    final matches = variants
        .where((variant) {
          final hash = FileTreeUtils.property(
            variant.source,
            'hash',
          )?.toString();
          if (track.hash != null) return hash == track.hash;
          final local = FileTreeUtils.property(
            variant.source,
            'localPath',
          )?.toString();
          final sourcePath =
              track.sourcePath ?? LocalFileUrl.pathFromUrl(track.url);
          if (sourcePath != null && local != null) return sourcePath == local;
          return variant.title == track.title;
        })
        .toList(growable: false);
    final variant = matches.length == 1 ? matches.single : null;
    final metadata = Map<String, dynamic>.from(work.toJson());
    metadata['children'] =
        DownloadFilePathService.annotateFileTreeWithLocalPaths(
          files.isNotEmpty
              ? files
              : [
                  {'type': 'audio', 'title': track.title, 'hash': track.hash},
                ],
        );
    final request = _request(
      track: track,
      files: files,
      variant: variant,
      host: auth.host ?? '',
      token: auth.token ?? '',
      metadata: metadata,
    );
    final active = ref
        .read(audioSubtitleGenerationProvider)
        .any(
          (job) => job.identity == request.identity && !job.status.isFinished,
        );
    if (!active &&
        await ref
            .read(audioSubtitleGenerationServiceProvider)
            .hasUsableSubtitle(request, CancelToken())) {
      return false;
    }
    ref.read(audioSubtitleGenerationProvider.notifier).enqueue([request]);
    return true;
  }

  Future<void> startWork({
    required Work work,
    required List<dynamic> fileTree,
    required List<PlayerAudioVariant> variants,
    String? workDirPath,
    Map<String, bool> downloadedFiles = const {},
    Map<String, String> fileRelativePaths = const {},
  }) async {
    final auth = ref.read(authProvider);
    final host = auth.host ?? '';
    final token = auth.token ?? '';
    final resolver = AudioFileUrlResolver(
      resolveDownloadedPath: DownloadService.instance.getDownloadedFilePath,
      downloadRootPath: () async =>
          (await DownloadPathService.getDownloadDirectory()).path,
      resolveCachedAudioPath: CacheService.getCachedAudioFile,
    );
    final requests = <AudioSubtitleRequest>[];
    final metadata = Map<String, dynamic>.from(work.toJson());
    metadata['children'] =
        DownloadFilePathService.annotateFileTreeWithLocalPaths(fileTree);
    for (final variant in variants) {
      final queue = await const AudioTrackQueueBuilder().build(
        audioFiles: [variant.source],
        selectedFile: variant.source,
        workId: work.id,
        albumTitle: work.title,
        unknownTitle: variant.title,
        subtitleWorkDirPath: workDirPath,
        resolveUrl: (file) => workDirPath != null
            ? resolver.resolveOffline(
                file: file,
                workDir: workDirPath,
                parentPath: variant.parentPath,
              )
            : resolver.resolveOnline(
                file: file,
                workId: work.id,
                host: host,
                token: token,
                downloadedFiles: downloadedFiles,
                fileRelativePaths: fileRelativePaths,
              ),
      );
      final track =
          queue.tracks.firstOrNull ??
          AudioTrack(
            id: variant.fullPath,
            title: variant.title,
            url: '',
            album: work.title,
            workId: work.id,
            hash: FileTreeUtils.property(variant.source, 'hash')?.toString(),
            subtitleWorkDirPath: workDirPath,
          );
      requests.add(
        _request(
          track: track,
          files: fileTree,
          variant: variant,
          host: host,
          token: token,
          metadata: metadata,
        ),
      );
    }
    ref.read(audioSubtitleGenerationProvider.notifier).enqueue(requests);
  }

  AudioSubtitleRequest _request({
    required AudioTrack track,
    required List<dynamic> files,
    PlayerAudioVariant? variant,
    required String host,
    required String token,
    Map<String, dynamic>? metadata,
  }) {
    final original = variant?.source;
    final source = original is AudioFile ? original.toJson() : original;
    var url =
        FileTreeUtils.property(source, 'mediaDownloadUrl')?.toString() ?? '';
    final normalizedHost = host.isEmpty
        ? ''
        : AudioFileUrlResolver.normalizeMediaHost(host);
    if (url.startsWith('/')) url = '$normalizedHost$url';
    if (url.isEmpty && normalizedHost.isNotEmpty && track.hash != null) {
      url =
          '$normalizedHost/api/media/download/${track.hash}/'
          '${Uri.encodeComponent(track.title)}';
    }
    if (url.isNotEmpty && token.isNotEmpty && !url.contains('token=')) {
      url += '${url.contains('?') ? '&' : '?'}token=$token';
    }
    final size = FileTreeUtils.property(source, 'size');
    return AudioSubtitleRequest(
      track: track,
      fileTree: List.unmodifiable(files),
      parentPath: variant?.parentPath,
      downloadUrl: url.isEmpty ? null : url,
      totalBytes: size is num ? size.toInt() : null,
      workMetadata: metadata,
      host: host,
      token: token,
    );
  }
}

final audioSubtitleActionsProvider = Provider<AudioSubtitleActions>((ref) {
  return AudioSubtitleActions(ref);
});

import 'dart:collection';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
import '../models/audio_tap_playlist_mode.dart';
import '../models/work.dart';
import '../services/audio_file_url_resolver.dart';
import '../services/audio_playback_plan_builder.dart';
import '../services/audio_player_service.dart';
import '../services/cache_service.dart';
import '../services/download_service.dart';
import '../services/local_work_metadata_service.dart';
import '../services/player_audio_variant_classifier.dart';
import '../utils/file_tree_utils.dart';
import 'audio_provider.dart';
import 'auth_provider.dart';
import 'lyric_provider.dart';

class PlayerWorkDetailsData {
  const PlayerWorkDetailsData({
    required this.track,
    required this.work,
    required this.fileTree,
    required this.variants,
    required this.fileTreeId,
    this.metadataError,
  });

  final AudioTrack track;
  final Work work;
  final List<dynamic> fileTree;
  final List<PlayerAudioVariant> variants;
  final String fileTreeId;
  final Object? metadataError;
}

bool canLoadPlayerWorkFileTree({
  required AudioTrack track,
  required bool isLoggedIn,
  required String? host,
}) {
  final hasOfflineTreeSource =
      track.subtitleWorkDirPath?.trim().isNotEmpty == true;
  final mayLoadOnlineTree = isLoggedIn && (host?.trim().isNotEmpty ?? false);
  return hasOfflineTreeSource || mayLoadOnlineTree;
}

/// Keeps metadata and variant scans bounded across player page rebuilds.
class PlayerWorkDetailsRepository {
  PlayerWorkDetailsRepository({
    PlayerAudioVariantClassifier? classifier,
    this.cacheCapacity = 24,
  }) : _classifier = classifier ?? const PlayerAudioVariantClassifier();

  static final PlayerWorkDetailsRepository instance =
      PlayerWorkDetailsRepository();

  final PlayerAudioVariantClassifier _classifier;
  final int cacheCapacity;
  final LinkedHashMap<String, PlayerWorkDetailsData> _cache =
      LinkedHashMap<String, PlayerWorkDetailsData>();

  int _classificationCount = 0;

  int get debugClassificationCount => _classificationCount;
  int get debugCacheSize => _cache.length;

  Future<PlayerWorkDetailsData> load({
    required AudioTrack track,
    required List<dynamic> fileTree,
    required bool canUseRemoteMetadata,
    required Future<Map<String, dynamic>> Function(int workId) loadRemoteWork,
  }) async {
    final workId = track.workId ?? 0;
    final sourceKey = track.subtitleWorkDirPath == null
        ? 'online'
        : p.normalize(track.subtitleWorkDirPath!);
    Work? work;
    Object? metadataError;

    try {
      work = await _loadLocalWork(track, fileTree);
      if (canUseRemoteMetadata && track.workId != null) {
        try {
          work = Work.fromJson(await loadRemoteWork(track.workId!));
        } catch (error) {
          metadataError = error;
        }
      }
    } catch (error) {
      metadataError = error;
    }
    work ??= _fallbackWork(track, fileTree);

    final effectiveTree = fileTree.isNotEmpty
        ? fileTree
        : List<dynamic>.from(work.children ?? const <AudioFile>[]);
    final inheritedLanguage = _classifier.inferWorkTitleLanguage(work.title);
    final fileTreeId =
        '$workId:$sourceKey:${inheritedLanguage.name}:'
        '${_fingerprint(effectiveTree)}';
    final cached = _cache.remove(fileTreeId);
    if (cached != null) {
      _cache[fileTreeId] = cached;
      return PlayerWorkDetailsData(
        track: track,
        work: work,
        fileTree: cached.fileTree,
        variants: cached.variants,
        fileTreeId: cached.fileTreeId,
        metadataError: metadataError,
      );
    }

    _classificationCount++;
    final result = PlayerWorkDetailsData(
      track: track,
      work: work,
      fileTree: List<dynamic>.unmodifiable(effectiveTree),
      variants: _classifier.scan(effectiveTree, workTitle: work.title),
      fileTreeId: fileTreeId,
      metadataError: metadataError,
    );
    _cache[fileTreeId] = result;
    while (_cache.length > cacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  Future<Work?> _loadLocalWork(AudioTrack track, List<dynamic> fileTree) async {
    final workId = track.workId;
    final workDirPath = track.subtitleWorkDirPath;
    if (workId == null || workDirPath == null || workDirPath.isEmpty) {
      return null;
    }
    final workDir = Directory(workDirPath);
    if (!await workDir.exists()) return null;

    const metadataService = LocalWorkMetadataService();
    final imported = await metadataService.loadImportedMetadata(
      workDir: workDir,
      workId: workId,
    );
    final metadata = <String, dynamic>{
      ...?imported,
      'id': workId,
      'title': imported?['title'] ?? track.album ?? track.title,
      'children': fileTree,
    };
    return Work.fromJson(metadata);
  }

  Work _fallbackWork(AudioTrack track, List<dynamic> fileTree) {
    final artist = track.artist?.trim();
    return Work(
      id: track.workId ?? 0,
      title: track.album?.trim().isNotEmpty == true
          ? track.album!.trim()
          : track.title,
      vas: artist == null || artist.isEmpty
          ? null
          : <Va>[Va(id: 'current-track', name: artist)],
      children: fileTree.whereType<AudioFile>().toList(growable: false),
    );
  }

  int _fingerprint(List<dynamic> items) {
    var result = 17;
    void addItems(List<dynamic> current) {
      for (final item in current) {
        result = Object.hash(
          result,
          FileTreeUtils.typeOf(item),
          FileTreeUtils.titleOf(item),
          FileTreeUtils.property(item, 'hash'),
        );
        final children = FileTreeUtils.childrenOf(item);
        if (children != null) addItems(children);
      }
    }

    addItems(items);
    return result;
  }
}

final playerWorkDetailsProvider = FutureProvider<PlayerWorkDetailsData?>((
  ref,
) async {
  final track = ref.watch(currentTrackProvider).valueOrNull;
  if (track == null) return null;

  final fileListState = ref.watch(fileListControllerProvider);
  final fileTreeLoader = ref.watch(playbackLyricFileTreeLoaderProvider);
  final auth = ref.watch(authProvider);
  var files = fileListState.matches(track)
      ? fileListState.files
      : const <dynamic>[];

  if (files.isEmpty &&
      track.workId != null &&
      canLoadPlayerWorkFileTree(
        track: track,
        isLoggedIn: auth.isLoggedIn,
        host: auth.host,
      )) {
    try {
      files = await fileTreeLoader(track);
    } catch (_) {
      // Offline/no-login playback must still show the metadata already on the
      // track. Loading details never redirects to authentication.
    }
  }

  return PlayerWorkDetailsRepository.instance.load(
    track: track,
    fileTree: files,
    canUseRemoteMetadata: auth.isLoggedIn && (auth.host?.isNotEmpty ?? false),
    loadRemoteWork: ref.read(kikoeruApiServiceProvider).getWork,
  );
});

enum PlayerEnqueueVariantStatus { queued, currentTrack, unavailable }

class PlayerEnqueueVariantResult {
  const PlayerEnqueueVariantResult(this.status, {this.queueResult});

  final PlayerEnqueueVariantStatus status;
  final EnqueueNextResult? queueResult;
}

class PlayerAudioVariantQueueController {
  PlayerAudioVariantQueueController(this.ref);

  final Ref ref;

  Future<PlayerEnqueueVariantResult> enqueueNext({
    required PlayerWorkDetailsData details,
    required PlayerAudioVariant variant,
  }) async {
    final current = ref.read(currentTrackProvider).valueOrNull;
    if (current == null) {
      return const PlayerEnqueueVariantResult(
        PlayerEnqueueVariantStatus.unavailable,
      );
    }
    final selectedHash = FileTreeUtils.property(
      variant.source,
      'hash',
    )?.toString();
    if ((selectedHash != null && selectedHash == current.hash) ||
        current.id == (selectedHash ?? variant.title)) {
      return const PlayerEnqueueVariantResult(
        PlayerEnqueueVariantStatus.currentTrack,
      );
    }

    final auth = ref.read(authProvider);
    final resolver = AudioFileUrlResolver(
      resolveDownloadedPath: DownloadService.instance.getDownloadedFilePath,
      downloadRootPath: () async {
        final directory = await DownloadService.instance.getDownloadDirectory();
        return directory.path;
      },
      resolveCachedAudioPath: CacheService.getCachedAudioFile,
    );
    final workDir = current.subtitleWorkDirPath;
    final isOffline = workDir != null && workDir.isNotEmpty;
    if (!isOffline && (auth.host?.isEmpty ?? true)) {
      return const PlayerEnqueueVariantResult(
        PlayerEnqueueVariantStatus.unavailable,
      );
    }

    final plan = await const AudioPlaybackPlanBuilder().build(
      fileTree: details.fileTree,
      parentPath: variant.parentPath,
      selectedFile: variant.source,
      resolveUrl: (file) {
        if (isOffline) {
          return resolver.resolveOffline(
            file: file,
            workDir: workDir,
            parentPath: variant.parentPath,
          );
        }
        return resolver.resolveOnline(
          file: file,
          workId: details.work.id,
          host: auth.host ?? '',
          token: auth.token ?? '',
          downloadedFiles: const {},
          fileRelativePaths: const {},
        );
      },
      work: details.work,
      unknownTitle: variant.title,
      artworkUrl: current.artworkUrl,
      subtitleWorkDirPath: workDir,
      playlistMode: AudioTapPlaylistMode.addToQueue,
    );
    if (plan.status != AudioPlaybackPlanStatus.ready || plan.queue!.isEmpty) {
      return const PlayerEnqueueVariantResult(
        PlayerEnqueueVariantStatus.unavailable,
      );
    }
    final result = await ref
        .read(audioPlayerControllerProvider.notifier)
        .enqueueNext(plan.queue!.tracks.first);
    return PlayerEnqueueVariantResult(
      result == EnqueueNextResult.currentTrack
          ? PlayerEnqueueVariantStatus.currentTrack
          : PlayerEnqueueVariantStatus.queued,
      queueResult: result,
    );
  }
}

final playerAudioVariantQueueControllerProvider =
    Provider<PlayerAudioVariantQueueController>((ref) {
      return PlayerAudioVariantQueueController(ref);
    });

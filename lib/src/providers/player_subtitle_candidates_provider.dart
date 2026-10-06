import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
import '../services/subtitle_database.dart';
import '../services/subtitle_library_service.dart';
import '../services/work_subtitle_candidate_selector.dart';
import '../utils/file_tree_utils.dart';
import 'audio_provider.dart';
import 'lyric_provider.dart';
import 'player_work_details_provider.dart';
import 'settings_provider.dart';
import 'subtitle_library_provider.dart';

enum PlayerSubtitleCandidateOrigin { work, library }

typedef PlayerSubtitleLibraryLoader =
    Future<List<PlayerSubtitleCandidate>> Function(AudioTrack track);

class PlayerSubtitleCandidate {
  const PlayerSubtitleCandidate({
    required this.identity,
    required this.title,
    required this.pathLabel,
    required this.origin,
    required this.source,
    required this.matchesCurrentAudio,
    required this.matchScore,
    required this.sameDirectory,
  });

  final String identity;
  final String title;
  final String pathLabel;
  final PlayerSubtitleCandidateOrigin origin;
  final Map<String, dynamic> source;
  final bool matchesCurrentAudio;
  final double matchScore;
  final bool sameDirectory;

  bool matchesSource(LyricSourceDescriptor? descriptor) {
    if (descriptor == null) return false;
    final localPath = descriptor.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      return identity == _localIdentity(localPath);
    }
    final hash = descriptor.hash;
    if (hash != null && hash.isNotEmpty) return identity == 'hash:$hash';
    return descriptor.title == title && descriptor.workId == source['workId'];
  }
}

class PlayerSubtitleCandidateRepository {
  const PlayerSubtitleCandidateRepository({this.libraryLoader});

  final PlayerSubtitleLibraryLoader? libraryLoader;

  Future<List<PlayerSubtitleCandidate>> load({
    required AudioTrack track,
    required List<dynamic> fileTree,
    required SubtitleLibraryPriority libraryPriority,
    LyricSourceDescriptor? currentSource,
  }) async {
    final candidates = <PlayerSubtitleCandidate>[];
    final currentCandidate = _candidateFromCurrentSource(track, currentSource);
    if (currentCandidate != null) candidates.add(currentCandidate);
    candidates.addAll(
      collectWorkCandidates(
        fileTree: fileTree,
        audioTitle: track.title,
        audioHash: track.hash,
        workId: track.workId,
      ),
    );
    candidates.addAll(await (libraryLoader ?? _loadLibraryCandidates)(track));

    final deduplicated = <String, PlayerSubtitleCandidate>{};
    for (final candidate in candidates) {
      final previous = deduplicated[candidate.identity];
      if (previous == null ||
          _compareCandidates(candidate, previous, libraryPriority) < 0) {
        deduplicated[candidate.identity] = candidate;
      }
    }

    final result = deduplicated.values.toList(growable: false);
    result.sort((a, b) => _compareCandidates(a, b, libraryPriority));
    return result;
  }

  /// Collects only work-tree candidates for the supplied audio identity.
  List<PlayerSubtitleCandidate> collectWorkCandidates({
    required List<dynamic> fileTree,
    required String audioTitle,
    String? audioHash,
    String? audioParentPath,
    int? workId,
  }) {
    return const WorkSubtitleCandidateSelector()
        .collectWorkCandidates(
          fileTree: fileTree,
          audioTitle: audioTitle,
          audioHash: audioHash,
          audioParentPath: audioParentPath,
          workId: workId,
        )
        .map((candidate) {
          final localPath = candidate.source['localPath']?.toString();
          final hash = candidate.source['hash']?.toString();
          final identity = localPath != null && localPath.isNotEmpty
              ? _localIdentity(localPath)
              : hash != null && hash.isNotEmpty
              ? 'hash:$hash'
              : 'work:${workId ?? 0}:${candidate.pathLabel}';
          return PlayerSubtitleCandidate(
            identity: identity,
            title: candidate.title,
            pathLabel: candidate.pathLabel,
            origin: PlayerSubtitleCandidateOrigin.work,
            source: candidate.source,
            matchesCurrentAudio: candidate.matchesCurrentAudio,
            matchScore: candidate.matchScore,
            sameDirectory: candidate.sameDirectory,
          );
        })
        .toList(growable: false);
  }

  PlayerSubtitleCandidate? _candidateFromCurrentSource(
    AudioTrack track,
    LyricSourceDescriptor? source,
  ) {
    if (source == null) return null;
    final localPath = source.localPath;
    final hash = source.hash;
    if ((localPath == null || localPath.isEmpty) &&
        (hash == null || hash.isEmpty)) {
      return null;
    }
    final identity = localPath != null && localPath.isNotEmpty
        ? _localIdentity(localPath)
        : 'hash:$hash';
    return PlayerSubtitleCandidate(
      identity: identity,
      title: source.title,
      pathLabel: localPath ?? source.url ?? source.title,
      origin:
          source.type == LyricSourceType.localFile ||
              source.type == LyricSourceType.subtitleLibrary
          ? PlayerSubtitleCandidateOrigin.library
          : PlayerSubtitleCandidateOrigin.work,
      source: <String, dynamic>{
        'title': source.title,
        if (localPath != null && localPath.isNotEmpty) 'localPath': localPath,
        if (hash != null && hash.isNotEmpty) 'hash': hash,
        'workId': source.workId ?? track.workId,
      },
      matchesCurrentAudio: true,
      matchScore: double.infinity,
      sameDirectory: true,
    );
  }

  int _compareCandidates(
    PlayerSubtitleCandidate candidate,
    PlayerSubtitleCandidate previous,
    SubtitleLibraryPriority libraryPriority,
  ) {
    if (candidate.matchesCurrentAudio != previous.matchesCurrentAudio) {
      return candidate.matchesCurrentAudio ? -1 : 1;
    }
    final scoreCompare = previous.matchScore.compareTo(candidate.matchScore);
    if (scoreCompare != 0) return scoreCompare;
    if (candidate.sameDirectory != previous.sameDirectory) {
      return candidate.sameDirectory ? -1 : 1;
    }
    final preferredOrigin = libraryPriority == SubtitleLibraryPriority.highest
        ? PlayerSubtitleCandidateOrigin.library
        : PlayerSubtitleCandidateOrigin.work;
    final candidateOriginRank = candidate.origin == preferredOrigin ? 0 : 1;
    final previousOriginRank = previous.origin == preferredOrigin ? 0 : 1;
    final originCompare = candidateOriginRank.compareTo(previousOriginRank);
    if (originCompare != 0) return originCompare;
    return FileTreeUtils.compareTitles(candidate.pathLabel, previous.pathLabel);
  }

  static Future<List<PlayerSubtitleCandidate>> _loadLibraryCandidates(
    AudioTrack track,
  ) async {
    try {
      await SubtitleLibraryService.ensureInitialized();
      final root =
          (await SubtitleLibraryService.getSubtitleLibraryDirectory()).path;
      final records = <SubtitleFileRecord>[];
      final workId = track.workId;
      if (workId != null) {
        records.addAll(
          await SubtitleDatabase.instance.getFilesByWorkId(workId),
        );
      }
      final saved = await SubtitleDatabase.instance.getFilesByCategory(
        SubtitleLibraryService.savedFolderName,
      );
      for (final record in saved) {
        final match = SubtitleLibraryService.checkMatch(
          record.fileName,
          track.title,
        );
        if (match.$1) records.add(record);
      }

      final result = <PlayerSubtitleCandidate>[];
      for (final record in records) {
        final absolutePath = record.absolutePath(root);
        if (!await File(absolutePath).exists()) continue;
        final match = SubtitleLibraryService.checkMatch(
          record.fileName,
          track.title,
        );
        result.add(
          PlayerSubtitleCandidate(
            identity: _localIdentity(absolutePath),
            title: record.fileName,
            pathLabel: record.relativePath,
            origin: PlayerSubtitleCandidateOrigin.library,
            source: <String, dynamic>{
              'title': record.fileName,
              'localPath': absolutePath,
              'workId': record.workId ?? track.workId,
            },
            matchesCurrentAudio: match.$1,
            matchScore: match.$2,
            sameDirectory: false,
          ),
        );
      }
      return result;
    } catch (_) {
      return const <PlayerSubtitleCandidate>[];
    }
  }
}

String _localIdentity(String filePath) =>
    'local:${p.normalize(filePath).toLowerCase()}';

final playerSubtitleCandidatesProvider =
    FutureProvider.autoDispose<List<PlayerSubtitleCandidate>>((ref) async {
      final track = ref.watch(currentTrackProvider).valueOrNull;
      if (track == null) return const <PlayerSubtitleCandidate>[];
      ref.watch(subtitleLibraryProvider);
      final priority = ref.watch(subtitleLibraryPriorityProvider);
      final currentSource = ref.watch(
        lyricControllerProvider.select((state) => state.source),
      );
      final details = await ref.watch(playerWorkDetailsProvider.future);
      return const PlayerSubtitleCandidateRepository().load(
        track: track,
        fileTree: details?.fileTree ?? const <dynamic>[],
        libraryPriority: priority,
        currentSource: currentSource,
      );
    });

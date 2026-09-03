import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../models/audio_track.dart';
import '../services/subtitle_database.dart';
import '../services/subtitle_library_service.dart';
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

  static const _extensions = <String>{'.vtt', '.srt', '.txt', '.lrc'};

  Future<List<PlayerSubtitleCandidate>> load({
    required AudioTrack track,
    required List<dynamic> fileTree,
    required SubtitleLibraryPriority libraryPriority,
    LyricSourceDescriptor? currentSource,
  }) async {
    final candidates = <PlayerSubtitleCandidate>[];
    final currentCandidate = _candidateFromCurrentSource(track, currentSource);
    if (currentCandidate != null) candidates.add(currentCandidate);
    final audioParent = _findAudioParent(fileTree, track);
    _collectWorkCandidates(
      candidates,
      items: fileTree,
      parentPath: '',
      audioParent: audioParent,
      track: track,
    );
    candidates.addAll(await (libraryLoader ?? _loadLibraryCandidates)(track));

    final deduplicated = <String, PlayerSubtitleCandidate>{};
    for (final candidate in candidates) {
      final previous = deduplicated[candidate.identity];
      if (previous == null || _isBetter(candidate, previous)) {
        deduplicated[candidate.identity] = candidate;
      }
    }

    final result = deduplicated.values.toList(growable: false);
    result.sort((a, b) {
      final matchCompare = _boolRank(
        b.matchesCurrentAudio,
      ).compareTo(_boolRank(a.matchesCurrentAudio));
      if (matchCompare != 0) return matchCompare;
      final sameDirectoryCompare = _boolRank(
        b.sameDirectory,
      ).compareTo(_boolRank(a.sameDirectory));
      if (sameDirectoryCompare != 0) return sameDirectoryCompare;
      final scoreCompare = b.matchScore.compareTo(a.matchScore);
      if (scoreCompare != 0) return scoreCompare;
      final preferredOrigin = libraryPriority == SubtitleLibraryPriority.highest
          ? PlayerSubtitleCandidateOrigin.library
          : PlayerSubtitleCandidateOrigin.work;
      final originCompare = (a.origin == preferredOrigin ? 0 : 1).compareTo(
        b.origin == preferredOrigin ? 0 : 1,
      );
      if (originCompare != 0) return originCompare;
      return FileTreeUtils.compareTitles(a.pathLabel, b.pathLabel);
    });
    return result;
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

  bool _isBetter(
    PlayerSubtitleCandidate candidate,
    PlayerSubtitleCandidate previous,
  ) {
    if (candidate.matchesCurrentAudio != previous.matchesCurrentAudio) {
      return candidate.matchesCurrentAudio;
    }
    if (candidate.sameDirectory != previous.sameDirectory) {
      return candidate.sameDirectory;
    }
    return candidate.matchScore > previous.matchScore;
  }

  int _boolRank(bool value) => value ? 1 : 0;

  String? _findAudioParent(List<dynamic> items, AudioTrack track) {
    String? match;
    void visit(List<dynamic> current, String parentPath) {
      if (match != null) return;
      for (final item in current) {
        final children = FileTreeUtils.childrenOf(item);
        if (FileTreeUtils.isFolder(item) && children != null) {
          visit(children, FileTreeUtils.itemPath(parentPath, item));
          if (match != null) return;
          continue;
        }
        if (!FileTreeUtils.isAudio(item)) continue;
        final hash = FileTreeUtils.property(item, 'hash')?.toString();
        final title = FileTreeUtils.titleOf(item);
        if ((track.hash != null && hash == track.hash) ||
            (track.hash == null && title == track.title)) {
          match = parentPath;
          return;
        }
      }
    }

    visit(items, '');
    return match;
  }

  void _collectWorkCandidates(
    List<PlayerSubtitleCandidate> result, {
    required List<dynamic> items,
    required String parentPath,
    required String? audioParent,
    required AudioTrack track,
  }) {
    for (final item in items) {
      final title = FileTreeUtils.titleOf(item);
      final children = FileTreeUtils.childrenOf(item);
      if (FileTreeUtils.isFolder(item) && children != null) {
        _collectWorkCandidates(
          result,
          items: children,
          parentPath: FileTreeUtils.itemPath(parentPath, item),
          audioParent: audioParent,
          track: track,
        );
        continue;
      }
      if (!_extensions.contains(p.extension(title).toLowerCase())) continue;

      final match = SubtitleLibraryService.checkMatch(title, track.title);
      final localPath = FileTreeUtils.property(item, 'localPath')?.toString();
      final hash = FileTreeUtils.property(item, 'hash')?.toString();
      final relativePath = FileTreeUtils.itemPath(parentPath, item);
      final identity = localPath != null && localPath.isNotEmpty
          ? _localIdentity(localPath)
          : hash != null && hash.isNotEmpty
          ? 'hash:$hash'
          : 'work:${track.workId ?? 0}:$relativePath';
      result.add(
        PlayerSubtitleCandidate(
          identity: identity,
          title: title,
          pathLabel: relativePath,
          origin: PlayerSubtitleCandidateOrigin.work,
          source: <String, dynamic>{
            'title': title,
            'hash': hash,
            if (localPath != null && localPath.isNotEmpty)
              'localPath': localPath,
            'workId': track.workId,
          },
          matchesCurrentAudio: match.$1,
          matchScore: match.$2,
          sameDirectory: audioParent != null && parentPath == audioParent,
        ),
      );
    }
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

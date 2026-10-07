import 'package:path/path.dart' as p;

import 'subtitle_matching.dart';
import '../utils/file_tree_utils.dart';

class WorkSubtitleCandidate {
  const WorkSubtitleCandidate({
    required this.title,
    required this.pathLabel,
    required this.source,
    required this.matchesCurrentAudio,
    required this.matchScore,
    required this.sameDirectory,
  });

  final String title;
  final String pathLabel;
  final Map<String, dynamic> source;
  final bool matchesCurrentAudio;
  final double matchScore;
  final bool sameDirectory;
}

class WorkSubtitleCandidateSelector {
  const WorkSubtitleCandidateSelector();

  static const _extensions = <String>{'.vtt', '.srt', '.txt', '.lrc'};

  List<WorkSubtitleCandidate> collectWorkCandidates({
    required List<dynamic> fileTree,
    required String audioTitle,
    String? audioHash,
    String? audioParentPath,
    int? workId,
  }) {
    final resolvedAudioParent =
        audioParentPath ?? _findAudioParent(fileTree, audioTitle, audioHash);
    final preparedAudio = SubtitleMatcher.prepareAudio(audioTitle);
    final result = <WorkSubtitleCandidate>[];

    void collect(List<dynamic> items, String parentPath) {
      for (final item in items) {
        final title = FileTreeUtils.titleOf(item);
        final children = FileTreeUtils.childrenOf(item);
        if (FileTreeUtils.isFolder(item) && children != null) {
          collect(children, FileTreeUtils.itemPath(parentPath, item));
          continue;
        }

        if (!_extensions.contains(p.extension(title).toLowerCase())) continue;

        final match = SubtitleMatcher.checkPrepared(
          SubtitleMatcher.prepareSubtitle(title),
          preparedAudio,
        ).toRecord();
        final relativePath = FileTreeUtils.itemPath(parentPath, item);
        result.add(
          WorkSubtitleCandidate(
            title: title,
            pathLabel: relativePath,
            source: _sourceFor(item, title, relativePath, workId),
            matchesCurrentAudio: match.$1,
            matchScore: match.$2,
            sameDirectory:
                resolvedAudioParent != null &&
                parentPath == resolvedAudioParent,
          ),
        );
      }
    }

    collect(fileTree, '');
    result.sort((a, b) {
      final matchCompare = _boolRank(
        b.matchesCurrentAudio,
      ).compareTo(_boolRank(a.matchesCurrentAudio));
      if (matchCompare != 0) return matchCompare;
      final scoreCompare = b.matchScore.compareTo(a.matchScore);
      if (scoreCompare != 0) return scoreCompare;
      final sameDirectoryCompare = _boolRank(
        b.sameDirectory,
      ).compareTo(_boolRank(a.sameDirectory));
      if (sameDirectoryCompare != 0) return sameDirectoryCompare;
      return FileTreeUtils.compareTitles(a.pathLabel, b.pathLabel);
    });
    return result;
  }

  String? _findAudioParent(
    List<dynamic> items,
    String audioTitle,
    String? audioHash,
  ) {
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
        if ((audioHash != null && hash == audioHash) ||
            (audioHash == null && title == audioTitle)) {
          match = parentPath;
          return;
        }
      }
    }

    visit(items, '');
    return match;
  }

  Map<String, dynamic> _sourceFor(
    dynamic item,
    String title,
    String relativePath,
    int? workId,
  ) {
    final source = <String, dynamic>{};
    if (item is Map) {
      for (final entry in item.entries) {
        if (entry.key is String) source[entry.key as String] = entry.value;
      }
    }

    source['title'] = title;
    final hash = FileTreeUtils.property(item, 'hash')?.toString();
    if (hash != null) source['hash'] = hash;
    final localPath = FileTreeUtils.property(item, 'localPath')?.toString();
    if (localPath != null && localPath.isNotEmpty) {
      source['localPath'] = localPath;
    }
    source['workId'] = workId;
    final relativePathValue = source['relativePath'];
    if (relativePathValue is! String || relativePathValue.trim().isEmpty) {
      source['relativePath'] = relativePath;
    }
    return source;
  }

  int _boolRank(bool value) => value ? 1 : 0;
}

import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/file_tree_utils.dart';
import 'subtitle_library_service.dart';
import 'subtitle_matching.dart';

class SubtitleAvailabilityScanner {
  const SubtitleAvailabilityScanner();

  Future<Set<String>> findAudioTitlesWithSubtitles({
    required Directory libraryDir,
    required int workId,
    required List<dynamic> fileTree,
  }) async {
    if (!await libraryDir.exists()) {
      return {};
    }

    final unmatchedAudio = collectAudioTitles(fileTree)
        .map(
          (title) =>
              (title: title, prepared: SubtitleMatcher.prepareAudio(title)),
        )
        .toList();
    if (unmatchedAudio.isEmpty) {
      return {};
    }

    final matchedAudioTitles = <String>{};
    final parsedFolderPath = p.join(
      libraryDir.path,
      SubtitleLibraryService.parsedFolderName,
    );

    for (final folderName in possibleWorkFolderNames(workId)) {
      final folder = Directory(p.join(parsedFolderPath, folderName));
      if (!await folder.exists()) continue;

      await for (final entity in folder.list(recursive: true)) {
        if (entity is! File) continue;

        final subtitle = SubtitleMatcher.prepareSubtitle(
          p.basename(entity.path),
        );
        if (subtitle == null) continue;

        for (var index = unmatchedAudio.length - 1; index >= 0; index--) {
          final audio = unmatchedAudio[index];
          if (SubtitleMatcher.checkPrepared(subtitle, audio.prepared).isMatch) {
            matchedAudioTitles.add(audio.title);
            unmatchedAudio.removeAt(index);
          }
        }

        if (unmatchedAudio.isEmpty) return matchedAudioTitles;
      }
    }

    return matchedAudioTitles;
  }

  static List<String> possibleWorkFolderNames(int workId) {
    return [
      'RJ$workId',
      'RJ0$workId',
      'BJ$workId',
      'BJ0$workId',
      'VJ$workId',
      'VJ0$workId',
    ];
  }

  static Set<String> collectAudioTitles(List<dynamic> fileTree) {
    final audioTitles = <String>{};

    void collect(List<dynamic> items) {
      for (final item in items) {
        final title = FileTreeUtils.titleOf(item);
        if (title.isNotEmpty && FileTreeUtils.isAudio(item)) {
          audioTitles.add(title);
        }

        final children = FileTreeUtils.childrenOf(item);
        if (children != null) {
          collect(children);
        }
      }
    }

    collect(fileTree);
    return audioTitles;
  }
}

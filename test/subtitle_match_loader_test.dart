import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_match_loader.dart';

void main() {
  test('loads subtitle matches through injected directory and finder',
      () async {
    final libraryDir = Directory('/tmp/subtitles');
    final fileTree = [
      {'type': 'audio', 'title': 'track01.mp3'},
    ];
    Directory? receivedDir;
    int? receivedWorkId;
    List<dynamic>? receivedTree;

    final loader = SubtitleMatchLoader(
      libraryDirectoryProvider: () async => libraryDir,
      findMatches: ({
        required libraryDir,
        required workId,
        required fileTree,
      }) async {
        receivedDir = libraryDir;
        receivedWorkId = workId;
        receivedTree = fileTree;
        return {'track01.mp3'};
      },
    );

    final matches = await loader.loadMatches(
      workId: 123,
      fileTree: fileTree,
    );

    expect(matches, {'track01.mp3'});
    expect(receivedDir, libraryDir);
    expect(receivedWorkId, 123);
    expect(receivedTree, same(fileTree));
  });

  test(
    'shared loader finds matching saved imports for either explorer',
    () async {
      final libraryDir = await Directory.systemTemp.createTemp(
        'kikoflu_saved_subtitle_loader_test_',
      );
      final savedDir = Directory(
        p.join(libraryDir.path, SubtitleLibraryService.savedFolderName),
      );
      await savedDir.create(recursive: true);
      await File(
        p.join(savedDir.path, 'track01.ass'),
      ).writeAsString('subtitle');

      try {
        final loader = SubtitleMatchLoader(
          libraryDirectoryProvider: () async => libraryDir,
        );

        final matches = await loader.loadMatches(
          workId: 42,
          fileTree: const [
            {'type': 'audio', 'title': 'track01.mp3'},
            {'type': 'audio', 'title': 'unmatched.mp3'},
          ],
        );

        expect(matches, {'track01.mp3'});
      } finally {
        await libraryDir.delete(recursive: true);
      }
    },
  );
}

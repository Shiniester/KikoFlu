import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:kikoeru_flutter/src/services/generated_subtitle_store.dart';
import 'package:kikoeru_flutter/src/services/subtitle_availability_scanner.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_long_path.dart';

Map<String, dynamic> fileItem(String title, {String type = 'file'}) {
  return {
    'type': type,
    'title': title,
  };
}

Map<String, dynamic> folderItem(String title, List<dynamic> children) {
  return {
    'type': 'folder',
    'title': title,
    'children': children,
  };
}

void main() {
  group('SubtitleAvailabilityScanner', () {
    test('generates possible work folder names', () {
      expect(
        SubtitleAvailabilityScanner.possibleWorkFolderNames(123456),
        [
          'RJ123456',
          'RJ0123456',
          'BJ123456',
          'BJ0123456',
          'VJ123456',
          'VJ0123456'
        ],
      );
    });

    test('collects audio titles recursively from file tree', () {
      final tree = [
        folderItem('Main', [
          fileItem('track01.flac'),
          fileItem('script.srt', type: 'text'),
          folderItem('Bonus', [fileItem('bonus.wav')]),
        ]),
      ];

      expect(
        SubtitleAvailabilityScanner.collectAudioTitles(tree),
        {'track01.flac', 'bonus.wav'},
      );
    });

    test('finds audio files with matching subtitles in library folders',
        () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'kikoflu_subtitle_scanner_test_',
      );

      try {
        final parsedDir = Directory(
          p.join(
            tempDir.path,
            SubtitleLibraryService.parsedFolderName,
            'RJ123456',
          ),
        );
        await parsedDir.create(recursive: true);
        await File(p.join(parsedDir.path, 'track01.srt')).writeAsString('sub');
        await File(p.join(parsedDir.path, 'unmatched.srt'))
            .writeAsString('sub');

        final tree = [
          folderItem('Main', [
            fileItem('track01.flac'),
            folderItem('Mirror', [fileItem('track01.flac')]),
            fileItem('track02.wav'),
          ]),
        ];

        final matches = await const SubtitleAvailabilityScanner()
            .findAudioTitlesWithSubtitles(
          libraryDir: tempDir,
          workId: 123456,
          fileTree: tree,
        );

        expect(matches, {'track01.flac'});
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'matches saved imports and parsed formats but ignores unknown folders',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'kikoflu_saved_subtitle_scanner_test_',
        );

        try {
          final parsedDir = Directory(
            p.join(
              tempDir.path,
              SubtitleLibraryService.parsedFolderName,
              'RJ123456',
            ),
          );
          final savedDir = Directory(
            p.join(tempDir.path, SubtitleLibraryService.savedFolderName),
          );
          final unknownDir = Directory(
            p.join(tempDir.path, SubtitleLibraryService.unknownFolderName),
          );
          await parsedDir.create(recursive: true);
          await savedDir.create(recursive: true);
          await unknownDir.create(recursive: true);
          await File(
            p.join(parsedDir.path, 'track01.ssa'),
          ).writeAsString('sub');
          await File(
            p.join(savedDir.path, 'track02.en.sbv'),
          ).writeAsString('sub');
          await File(
            p.join(unknownDir.path, 'track03.ttml'),
          ).writeAsString('sub');
          final generatedDir = Directory(
            p.join(tempDir.path, GeneratedSubtitleStore.relativeDirectory),
          );
          await generatedDir.create(recursive: true);
          await File(
            p.join(generatedDir.path, 'track04.srt'),
          ).writeAsString('sub');

          final matches = await const SubtitleAvailabilityScanner()
              .findAudioTitlesWithSubtitles(
                libraryDir: tempDir,
                workId: 123456,
                fileTree: [
                  fileItem('track01.wav'),
                  fileItem('track02.wav'),
                  fileItem('track03.wav'),
                  fileItem('track04.wav'),
                  fileItem('unmatched.wav'),
                ],
              );

          expect(matches, {'track01.wav', 'track02.wav'});
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );

    for (final category in [
      SubtitleLibraryService.parsedFolderName,
      SubtitleLibraryService.savedFolderName,
    ]) {
      test('matches shortened subtitles in $category after a folder rename',
          () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'kikoflu_shortened_subtitle_',
        );
        try {
          final folder = category == SubtitleLibraryService.parsedFolderName
              ? p.join(tempDir.path, category, 'RJ123456')
              : p.join(tempDir.path, category);
          final title = 'track_${'n' * 130}';
          final path = SubtitleLongPath.resolve(
            folder,
            '简体中文/$title.srt',
            maxPathLength: folder.length + 40,
          )!;
          final subtitle = File(path);
          await subtitle.writeAsString('sub');
          expect(p.basename(path), isNot('$title.srt'));

          for (final renameFolder in [false, true]) {
            if (renameFolder) {
              await subtitle.parent.rename(p.join(folder, 'renamed'));
            }
            final matches = await const SubtitleAvailabilityScanner()
                .findAudioTitlesWithSubtitles(
              libraryDir: tempDir,
              workId: 123456,
              fileTree: [fileItem('$title.wav'), fileItem('other.wav')],
            );
            expect(matches, {'$title.wav'});
          }
        } finally {
          await tempDir.delete(recursive: true);
        }
      });
    }

    test('returns empty set when library directory is missing', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'kikoflu_missing_subtitle_scanner_test_',
      );
      final missingDir = Directory(p.join(tempDir.path, 'missing'));

      try {
        final matches = await const SubtitleAvailabilityScanner()
            .findAudioTitlesWithSubtitles(
          libraryDir: missingDir,
          workId: 123456,
          fileTree: [fileItem('track01.flac')],
        );

        expect(matches, isEmpty);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}

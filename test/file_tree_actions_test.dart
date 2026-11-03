import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/widgets/file_tree_actions.dart';
import 'package:kikoeru_flutter/src/widgets/file_tree_view.dart';

Widget _testApp(Widget child) {
  return MaterialApp(
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(body: child),
  );
}

FileTreeEntry _entry({
  required Map<String, dynamic> item,
  String parentPath = 'Disc 1',
}) {
  final title = item['title'] as String;
  return FileTreeEntry(
    item: item,
    parentPath: parentPath,
    itemPath: parentPath.isEmpty ? title : '$parentPath/$title',
    originalTitle: title,
    displayTitle: title,
    isFolder: item['type'] == 'folder',
    isExpanded: false,
    children: item['children'] as List<dynamic>?,
    level: 0,
  );
}

void main() {
  group('FileTreeActions', () {
    testWidgets('does not render an audio playback action', (tester) async {
      await tester.pumpWidget(
        _testApp(
          FileTreeActions(
            entry: _entry(
              item: {'type': 'audio', 'title': 'track01.mp3', 'hash': 'audio'},
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.play_arrow), findsNothing);
      expect(find.byIcon(Icons.visibility), findsNothing);
    });

    testWidgets('does not render video or image playback actions', (
      tester,
    ) async {
      for (final item in [
        {'type': 'video', 'title': 'clip.mp4'},
        {'type': 'image', 'title': 'cover.jpg'},
      ]) {
        await tester.pumpWidget(
          _testApp(FileTreeActions(entry: _entry(item: item))),
        );
        expect(find.byIcon(Icons.video_library), findsNothing);
        expect(find.byIcon(Icons.visibility), findsNothing);

        await tester.pumpWidget(
          _testApp(
            FileTreeActions(
              entry: _entry(item: item),
              showDeleteAction: true,
              onDelete: (_, __) {},
            ),
          ),
        );
        expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      }
    });

    testWidgets('renders subtitle and preview actions for lyric text', (
      tester,
    ) async {
      var loadedSubtitle = false;
      var previewedText = false;

      await tester.pumpWidget(
        _testApp(
          FileTreeActions(
            entry: _entry(
              item: {'type': 'text', 'title': 'track01.srt', 'hash': 'lyric'},
            ),
            onLoadSubtitle: (_, __) {
              loadedSubtitle = true;
            },
            onPreviewText: (_, __) {
              previewedText = true;
            },
          ),
        ),
      );

      expect(find.byIcon(Icons.subtitles), findsOneWidget);
      expect(find.byIcon(Icons.visibility), findsOneWidget);

      await tester.tap(find.byIcon(Icons.subtitles));
      await tester.tap(find.byIcon(Icons.visibility));

      expect(loadedSubtitle, isTrue);
      expect(previewedText, isTrue);
    });

    testWidgets(
      'offline mode renders delete without preview for generic files',
      (tester) async {
        String? deletedTitle;

        await tester.pumpWidget(
          _testApp(
            FileTreeActions(
              entry: _entry(
                item: {
                  'type': 'file',
                  'title': 'archive.zip',
                  'hash': 'archive',
                },
              ),
              showPreviewActions: false,
              showDeleteAction: true,
              onDelete: (item, _) {
                deletedTitle = item['title'] as String;
              },
            ),
          ),
        );

        expect(find.byIcon(Icons.delete_outline), findsOneWidget);
        expect(find.byIcon(Icons.visibility), findsNothing);

        await tester.tap(find.byIcon(Icons.delete_outline));
        expect(deletedTitle, 'archive.zip');
      },
    );
  });

  testWidgets('video and image resource rows remain tappable', (tester) async {
    final tapped = <(String, String)>[];
    await tester.pumpWidget(
      _testApp(
        CustomScrollView(
          slivers: [
            FileTreeView(
              items: const [
                {
                  'type': 'folder',
                  'title': 'Disc 1',
                  'children': [
                    {'type': 'video', 'title': 'clip.mp4'},
                    {'type': 'image', 'title': 'cover.jpg'},
                  ],
                },
              ],
              expandedFolders: const {'Disc 1'},
              onToggleFolder: (_) {},
              onFileTap: (item, _, parentPath) =>
                  tapped.add((item['title'] as String, parentPath)),
              trailingBuilder: (_, entry) => FileTreeActions(entry: entry),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('clip.mp4'));
    await tester.tap(find.text('cover.jpg'));
    expect(tapped, [('clip.mp4', 'Disc 1'), ('cover.jpg', 'Disc 1')]);
  });
}

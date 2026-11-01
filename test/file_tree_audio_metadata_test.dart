import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/utils/string_utils.dart';
import 'package:kikoeru_flutter/src/widgets/file_tree_view.dart';

Widget _testApp(Widget child) => MaterialApp(
  localizationsDelegates: S.localizationsDelegates,
  supportedLocales: S.supportedLocales,
  home: Scaffold(body: CustomScrollView(slivers: [child])),
);

Widget _fileTree({required bool videoBeforeAudio, bool offline = false}) {
  final items = [
    {'type': 'audio', 'title': 'voice.wav', 'duration': 3661},
    {'type': 'audio', 'title': 'missing.wav'},
    {'type': 'video', 'title': 'clip.mp4', 'duration': 120},
    {'type': 'video', 'title': 'mixed.mp3', 'duration': 30},
  ];
  return FileTreeView(
    items: items,
    expandedFolders: const {},
    onToggleFolder: (_) {},
    onFileTap: (_, __, ___) {},
    metadataBuilder: (_, entry) => Text(
      'tree-metadata-${entry.originalTitle}',
      key: ValueKey('tree-metadata-${entry.originalTitle}'),
    ),
    audioMetadataBuilder: offline
        ? (_, entry) =>
              Text('8 KB', key: ValueKey('audio-size-${entry.originalTitle}'))
        : null,
    audioDurationBuilder: (_, entry) {
      final value = formatDurationSeconds(
        (entry.item as Map<String, dynamic>)['duration'],
        padHours: false,
      );
      return value.isEmpty
          ? null
          : Text(value, key: ValueKey('audio-duration-${entry.originalTitle}'));
    },
    trailingBuilder: (_, entry) => entry.originalTitle == 'voice.wav'
        ? IconButton(onPressed: () {}, icon: const Icon(Icons.delete_outline))
        : null,
    videoBeforeAudio: videoBeforeAudio,
  );
}

void main() {
  testWidgets('resource audio duration follows existing actions at row end', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(_fileTree(videoBeforeAudio: false, offline: true)),
    );

    final duration = find.byKey(const ValueKey('audio-duration-voice.wav'));
    final delete = find.byIcon(Icons.delete_outline);
    expect(duration, findsOneWidget);
    expect(find.text('1:01:01'), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-size-voice.wav')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-metadata-voice.wav')), findsNothing);
    expect(find.text('tree-metadata-clip.mp4'), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-duration-clip.mp4')), findsNothing);
    expect(
      tester.getRect(duration).left,
      greaterThan(tester.getRect(delete).right),
    );
    expect(
      find.byKey(const ValueKey('audio-duration-missing.wav')),
      findsNothing,
    );
  });

  testWidgets('online resource audio duration moves out of title metadata', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(_fileTree(videoBeforeAudio: true)));

    expect(
      find.byKey(const ValueKey('audio-duration-voice.wav')),
      findsOneWidget,
    );
    expect(find.text('1:01:01'), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-metadata-voice.wav')), findsNothing);
    expect(
      find.byKey(const ValueKey('tree-metadata-clip.mp4')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('audio-duration-clip.mp4')), findsNothing);
  });

  testWidgets(
    'mixed audio/video rows follow the owning playback classification',
    (tester) async {
      await tester.pumpWidget(_testApp(_fileTree(videoBeforeAudio: true)));
      expect(
        find.byKey(const ValueKey('tree-metadata-mixed.mp3')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('audio-duration-mixed.mp3')),
        findsNothing,
      );

      await tester.pumpWidget(_testApp(_fileTree(videoBeforeAudio: false)));
      expect(
        find.byKey(const ValueKey('tree-metadata-mixed.mp3')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('audio-duration-mixed.mp3')),
        findsOneWidget,
      );
    },
  );
}

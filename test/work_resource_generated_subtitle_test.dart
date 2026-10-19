import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_store.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/work_resource_tabs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _pumpResources(
  WidgetTester tester,
  ValueNotifier<List<dynamic>> tree, {
  required ResourceAudioAction onPlay,
  required void Function(dynamic, String, String) onFileTap,
}) => tester.pumpWidget(
  ProviderScope(
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: Scaffold(
        body: ValueListenableBuilder<List<dynamic>>(
          valueListenable: tree,
          builder: (context, files, _) => CustomScrollView(
            slivers: [
              WorkResourceTabs(
                workId: 42,
                fileTree: files,
                audioVariants: const PlayerAudioVariantClassifier().scan(files),
                resourceSliver: const SliverToBoxAdapter(
                  child: Text('Resources'),
                ),
                resourceTitle: 'Resources',
                onPlayAudio: onPlay,
                onFileTap: onFileTap,
                onImageTap: (_) {},
                resolveImage: (_) async => null,
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

Future<void> _pumpUntilVisible(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 40 && finder.evaluate().isEmpty; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'refreshes exact generated previews and keeps work subtitles first',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'work-resource-generated-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      await tester.runAsync(() => StorageService.initCritical());
      final tree = ValueNotifier<List<dynamic>>([
        {
          'type': 'folder',
          'title': 'Disc A',
          'children': [
            {'type': 'audio', 'title': 'voice.wav', 'hash': 'audio-a'},
          ],
        },
        {
          'type': 'folder',
          'title': 'Disc B',
          'children': [
            {'type': 'audio', 'title': 'existing.wav', 'hash': 'audio-b'},
          ],
        },
        {
          'type': 'folder',
          'title': 'Disc C',
          'children': [
            {'type': 'audio', 'title': 'voice.wav', 'hash': 'audio-c'},
          ],
        },
        {'type': 'text', 'title': 'existing.srt', 'hash': 'caption-b'},
      ]);
      const store = GeneratedSubtitleStore();
      const generatedTrack = AudioTrack(
        id: 'audio-a',
        title: 'voice.wav',
        url: '',
        workId: 42,
        hash: 'audio-a',
      );
      const existingTrack = AudioTrack(
        id: 'audio-b',
        title: 'existing.wav',
        url: '',
        workId: 42,
        hash: 'audio-b',
      );
      var playCalls = 0;
      final previewCalls =
          <({dynamic file, String title, String parentPath})>[];
      void onFileTap(dynamic file, String title, String parentPath) {
        previewCalls.add((file: file, title: title, parentPath: parentPath));
      }

      try {
        final existingGeneratedPath = await tester.runAsync(
          () => store.save(
            existingTrack,
            '1\n00:00:01,000 --> 00:00:02,000\nGenerated B\n',
            cancelToken: CancelToken(),
          ),
        );
        await _pumpResources(
          tester,
          tree,
          onPlay: (_, _, _) => playCalls++,
          onFileTap: onFileTap,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('work-audio-subtitle-Disc A/voice.wav')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('work-audio-subtitle-Disc B/existing.wav')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('work-audio-subtitle-Disc C/voice.wav')),
          findsNothing,
        );

        await tester.tap(
          find.byKey(const ValueKey('work-audio-subtitle-Disc B/existing.wav')),
        );
        expect(previewCalls.last.file['hash'], 'caption-b');
        expect(previewCalls.last.file['localPath'], isNull);
        expect(existingGeneratedPath, isNotNull);

        final generatedPath = await tester.runAsync(
          () => store.save(
            generatedTrack,
            '1\n00:00:01,000 --> 00:00:02,000\nGenerated A\n',
            cancelToken: CancelToken(),
          ),
        );
        final generatedEye = find.byKey(
          const ValueKey('work-audio-subtitle-Disc A/voice.wav'),
        );
        await _pumpUntilVisible(tester, generatedEye);
        expect(generatedEye, findsOneWidget);
        expect(
          find.byKey(const ValueKey('work-audio-subtitle-Disc C/voice.wav')),
          findsNothing,
        );

        await tester.tap(generatedEye);
        expect(previewCalls.last.file, {
          'type': 'text',
          'title': 'voice.srt',
          'localPath': generatedPath,
          'workId': 42,
        });
        expect(previewCalls.last.title, 'voice.srt');
        expect(playCalls, 0);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _pumpResources(
          tester,
          tree,
          onPlay: (_, _, _) => playCalls++,
          onFileTap: onFileTap,
        );
        await _pumpUntilVisible(tester, generatedEye);
        expect(generatedEye, findsOneWidget);
        expect(
          find.byKey(const ValueKey('work-audio-subtitle-Disc B/existing.wav')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('work-audio-subtitle-Disc C/voice.wav')),
          findsNothing,
        );

        tree.value = [];
        await tester.pump();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(() async {
          await (await SubtitleDatabase.instance.database).close();
          await directory.delete(recursive: true);
        });
        messenger.setMockMethodCallHandler(channel, null);
        tree.dispose();
      }
    },
  );
}

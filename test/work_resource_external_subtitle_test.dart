import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/services/account_database.dart';
import 'package:kikoeru_flutter/src/services/player_audio_variant_classifier.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:kikoeru_flutter/src/widgets/work_resource_tabs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('audio subtitle preview opens its matching saved import', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'work-resource-external-subtitle-',
    );
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    await tester.runAsync(() => StorageService.initCritical());

    final libraryDir = await tester.runAsync(
      SubtitleLibraryService.getSubtitleLibraryDirectory,
    );
    final savedDir = Directory(
      '${libraryDir!.path}${Platform.pathSeparator}${SubtitleLibraryService.savedFolderName}',
    );
    final subtitleFile = File(
      '${savedDir.path}${Platform.pathSeparator}voice.en.ass',
    );
    final tree = [
      {'type': 'audio', 'title': 'voice.wav', 'hash': 'audio-imported'},
    ];
    final previewCalls = <({dynamic file, String title, String parentPath})>[];

    try {
      await tester.runAsync(() async {
        await SubtitleLibraryService.ensureInitialized();
        await savedDir.create(recursive: true);
        await subtitleFile.writeAsString('[Script Info]\n');
        await SubtitleLibraryService.refreshDirectoryCache(savedDir.path);
      });

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  WorkResourceTabs(
                    workId: 42,
                    fileTree: tree,
                    audioVariants: const PlayerAudioVariantClassifier().scan(
                      tree,
                    ),
                    resourceSliver: const SliverToBoxAdapter(
                      child: Text('Resources'),
                    ),
                    resourceTitle: 'Resources',
                    onPlayAudio: (_, _, _) {},
                    onFileTap: (file, title, parentPath) {
                      previewCalls.add((
                        file: file,
                        title: title,
                        parentPath: parentPath,
                      ));
                    },
                    onImageTap: (_) {},
                    resolveImage: (_) async => null,
                    audioWithLibrarySubtitles: const {'voice.wav'},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final preview = find.byKey(
        const ValueKey('work-audio-subtitle-voice.wav'),
      );
      expect(preview, findsOneWidget);

      await tester.tap(preview);
      for (var frame = 0; frame < 40 && previewCalls.isEmpty; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }

      expect(previewCalls, hasLength(1));
      expect(previewCalls.single.file['type'], 'text');
      expect(previewCalls.single.file['localPath'], subtitleFile.path);
      expect(previewCalls.single.title, 'voice.en.ass');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async {
        await (await SubtitleDatabase.instance.database).close();
        await AccountDatabase.instance.close();
        await directory.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}

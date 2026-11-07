import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric/lyric_parser.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/subtitle_database.dart';
import 'package:kikoeru_flutter/src/services/subtitle_library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('manual lyric load reads localPath without server auth', () async {
    final tempDir = await Directory.systemTemp.createTemp('lyric_local_file_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final subtitle = File('${tempDir.path}/track01.lrc');
    await subtitle.writeAsString('[00:01.00]hello');

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(lyricControllerProvider.notifier).loadLyricManually({
      'title': 'track01.lrc',
      'localPath': subtitle.path,
      'hash': 'local:track01.lrc',
    });

    final state = container.read(lyricControllerProvider);
    expect(state.error, isNull);
    expect(state.lyrics, hasLength(1));
    expect(state.lyrics.single.text, 'hello');
    expect(state.lyricUrl, 'file://${subtitle.path}');
  });

  for (final autoSave in [false, true]) {
    test(
      'existing Japanese subtitles translate to Chinese with auto-save $autoSave',
      () async {
        const original =
            '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n\n'
            '2\n00:00:03,000 --> 00:00:04,000\n声を聴いて\n';
        const sourceText = 'こんにちは\n声を聴いて';
        const translatedText = '你好\n听我说话';
        final root = await Directory.systemTemp.createTemp(
          'existing_subtitle_translation_',
        );
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (_) async => root.path);
        SharedPreferences.setMockInitialValues({
          'locale_language': 'en',
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'zh_hans',
          AutoSaveTranslatedLyricsNotifier.preferenceKey: autoSave,
          'custom_download_path': root.path,
          'translation_cache_auto_zh_Hans_${sourceText.hashCode}': jsonEncode({
            'translation': translatedText,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }),
        });
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        if (autoSave) {
          sqfliteFfiInit();
          databaseFactory = databaseFactoryFfi;
        }
        final subtitle = await File(
          '${root.path}/existing.srt',
        ).writeAsString(original);
        const track = AudioTrack(
          id: 'track',
          title: 'track01.mp3',
          url: 'file:///track01.mp3',
        );
        final container = ProviderContainer(
          overrides: [
            currentTrackProvider.overrideWith((ref) => Stream.value(track)),
          ],
        );
        addTearDown(() async {
          container.dispose();
          if (autoSave) {
            await (await SubtitleDatabase.instance.database).close();
          }
          messenger.setMockMethodCallHandler(channel, null);
          await root.delete(recursive: true);
        });
        await container.read(currentTrackProvider.future);
        await container.read(effectiveTranslationTargetLocaleProvider.future);
        final controller = container.read(lyricControllerProvider.notifier);
        await controller.loadLyricFromLocalFile(subtitle.path);
        final sourceLines = container.read(lyricControllerProvider).lyrics;

        await controller.toggleTranslation();

        final translated = container.read(lyricControllerProvider);
        expect(translated.showTranslated, isTrue);
        expect(translated.translatedLyrics, isNotNull);
        expect(translated.translatedTargetLanguage, 'zh-Hans');
        expect(translated.displayLyrics.map((line) => line.text), [
          '你好',
          '听我说话',
        ]);
        expect(
          translated.translatedLyrics!.map(
            (line) => (line.startTime, line.endTime),
          ),
          sourceLines.map((line) => (line.startTime, line.endTime)),
        );
        expect(await subtitle.readAsString(), original);
        if (autoSave) {
          final savedPath = translated.translatedSubtitlePath;
          expect(savedPath, isNotNull);
          final saved = LyricParser.parse(
            await File(savedPath!).readAsString(),
          );
          expect(saved.map((line) => line.text), ['你好', '听我说话']);
          expect(
            saved.map((line) => line.startTime),
            sourceLines.map((line) => line.startTime),
          );
          final records = await SubtitleDatabase.instance.getFilesByCategory(
            SubtitleLibraryService.savedFolderName,
          );
          expect(
            records.any((record) => record.fileName == 'track01.lrc'),
            isTrue,
          );
        } else {
          expect(translated.translatedSubtitlePath, isNull);
          expect(
            await Directory('${root.path}/subtitle_library/已保存').exists(),
            isFalse,
          );
        }

        await controller.toggleTranslation();
        expect(container.read(lyricControllerProvider).showTranslated, isFalse);
        expect(
          container
              .read(lyricControllerProvider)
              .displayLyrics
              .map((line) => line.text),
          ['こんにちは', '声を聴いて'],
        );
        await controller.toggleTranslation();
        expect(
          container
              .read(lyricControllerProvider)
              .displayLyrics
              .map((line) => line.text),
          ['你好', '听我说话'],
        );
      },
    );
  }
}

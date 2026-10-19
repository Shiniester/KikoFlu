import 'dart:ui';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_translation_service.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_store.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'en',
      'locale_language': 'en',
      AutoSaveTranslatedLyricsNotifier.preferenceKey: false,
    }),
  );

  test(
    'late generated translation preserves a same-track manual source and request',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'generated-manual-guard-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final original = await File(
        '${directory.path}/audio.srt',
      ).writeAsString('[00:01.00]こんにちは');
      final manual = await File(
        '${directory.path}/manual.srt',
      ).writeAsString('[00:01.00]manual');
      const track = AudioTrack(
        id: 'a',
        title: 'audio',
        url: 'file:///audio',
        hash: 'a',
      );
      final container = ProviderContainer(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(track)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(currentTrackProvider.future);
      final controller = container.read(lyricControllerProvider.notifier);
      await controller.loadLyricFromLocalFile(original.path);
      final expected = controller.loadRequestId;
      final lines = LyricParser.parse(await original.readAsString());
      final translation = GeneratedSubtitleTranslation(
        original: lines,
        translated: [lines.single.copyWith(text: 'Hello')],
        targetLocale: const Locale('en'),
      );
      await controller.selectLyricManually({
        'title': 'manual.srt',
        'localPath': manual.path,
      });
      await controller.showGeneratedTranslation(
        track,
        original.path,
        translation,
        expectedLoadRequestId: expected,
      );
      expect(
        container.read(lyricControllerProvider).displayLyrics.single.text,
        'manual',
      );
      expect(
        controller.generatedTranslationContent(
          original.path,
          targetLocale: const Locale('en'),
        ),
        contains('Hello'),
      );

      await controller.loadLyricFromLocalFile(original.path);
      final pending = controller.selectLyricManually({
        'title': 'manual.srt',
        'localPath': manual.path,
      });
      expect(container.read(lyricControllerProvider).isLoading, isTrue);
      final pendingId = controller.loadRequestId;
      await controller.showGeneratedTranslation(
        track,
        original.path,
        translation,
      );
      expect(controller.loadRequestId, pendingId);
      await pending;
      expect(
        container.read(lyricControllerProvider).source?.localPath,
        manual.path,
      );
    },
  );

  test(
    'session translations and late completion stay bound to their target',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'generated-target-memory-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final folder = await Directory(
        '${directory.path}/${GeneratedSubtitleStore.relativeDirectory}/1',
      ).create(recursive: true);
      final original = await File(
        '${folder.path}/audio.srt',
      ).writeAsString('[00:01.00]こんにちは');
      const track = AudioTrack(
        id: 'a',
        title: 'audio',
        url: 'file:///audio',
        hash: 'a',
      );
      final container = ProviderContainer(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(track)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(currentTrackProvider.future);
      final controller = container.read(lyricControllerProvider.notifier);
      await controller.loadLyricFromLocalFile(original.path);
      final expected = controller.loadRequestId;
      final lines = LyricParser.parse(await original.readAsString());
      await container
          .read(translationLanguagePreferencesProvider.notifier)
          .updateTargetLanguage(TranslationTargetLanguage.japanese);
      await controller.showGeneratedTranslation(
        track,
        original.path,
        GeneratedSubtitleTranslation(
          original: lines,
          translated: [lines.single.copyWith(text: 'Hello')],
          targetLocale: const Locale('en'),
        ),
        expectedLoadRequestId: expected,
      );
      expect(
        container.read(lyricControllerProvider).displayLyrics.single.text,
        'こんにちは',
      );
      expect(
        controller.generatedTranslationContent(
          original.path,
          targetLocale: const Locale('ja'),
        ),
        isNull,
      );
      await controller.loadLyricFromLocalFile(original.path);
      expect(container.read(lyricControllerProvider).isTranslated, isFalse);
      await container
          .read(translationLanguagePreferencesProvider.notifier)
          .updateTargetLanguage(TranslationTargetLanguage.english);
      await controller.loadLyricFromLocalFile(original.path);
      expect(
        container.read(lyricControllerProvider).displayLyrics.single.text,
        'Hello',
      );
      await container
          .read(translationLanguagePreferencesProvider.notifier)
          .updateTargetLanguage(TranslationTargetLanguage.japanese);
      await container.read(effectiveTranslationTargetLocaleProvider.future);
      await controller.toggleTranslation();
      expect(
        container.read(lyricControllerProvider).displayLyrics.single.text,
        'こんにちは',
      );
      expect(
        container.read(lyricControllerProvider).translatedTargetLanguage,
        'ja',
      );
    },
  );
  test(
    'loading a saved generated original restores its translation and original toggle',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'saved-generated-lyric-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final folder = await Directory(
        '${directory.path}/${GeneratedSubtitleStore.relativeDirectory}/1',
      ).create(recursive: true);
      final original = await File(
        '${folder.path}/audio.srt',
      ).writeAsString('1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n\n');
      await File(
        GeneratedSubtitleStore.translatedPath(
          original.path,
          targetLocale: const Locale('en'),
        ),
      ).writeAsString('1\n00:00:01,000 --> 00:00:02,000\nHello\n\n');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(lyricControllerProvider.notifier);
      await controller.loadLyricManually({
        'title': 'audio.srt',
        'localPath': original.path,
      });
      expect(
        container.read(lyricControllerProvider).displayLyrics.single.text,
        'Hello',
      );
      await controller.toggleTranslation();
      expect(
        container.read(lyricControllerProvider).displayLyrics.single.text,
        'こんにちは',
      );
    },
  );

  test(
    'background translation does not replace another track and is reused on load',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'generated-lyric-memory-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final original = await File(
        '${directory.path}/audio.srt',
      ).writeAsString('1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n\n');
      const trackA = AudioTrack(
        id: 'a',
        title: 'a',
        url: 'file:///a',
        workId: 1,
        hash: 'a',
      );
      const trackB = AudioTrack(
        id: 'b',
        title: 'b',
        url: 'file:///b',
        workId: 1,
        hash: 'b',
      );
      final container = ProviderContainer(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(trackB)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(currentTrackProvider.future);
      final controller = container.read(lyricControllerProvider.notifier);
      final source = LyricParser.parse(await original.readAsString());
      controller.showGeneratedTranslation(
        trackA,
        original.path,
        GeneratedSubtitleTranslation(
          targetLocale: const Locale('en'),
          original: source,
          translated: [source.single.copyWith(text: 'Hello')],
        ),
      );
      expect(container.read(lyricControllerProvider).lyrics, isEmpty);
      await controller.loadLyricFromLocalFile(original.path);
      final state = container.read(lyricControllerProvider);
      expect(state.lyrics.single.text, 'こんにちは');
      expect(state.displayLyrics.single.text, 'Hello');
      await controller.toggleTranslation();
      expect(
        container.read(lyricControllerProvider).displayLyrics.single.text,
        'こんにちは',
      );
    },
  );

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
}

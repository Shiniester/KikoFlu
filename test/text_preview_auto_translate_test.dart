import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_store.dart';
import 'package:kikoeru_flutter/src/services/generated_subtitle_translation_service.dart';
import 'package:kikoeru_flutter/src/utils/local_file_url.dart';
import 'package:kikoeru_flutter/src/widgets/text_preview_screen.dart';
import 'package:kikoeru_flutter/src/widgets/translation_toggle_button.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

Widget _testApp(String path, {required String title}) {
  return ProviderScope(
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: TextPreviewScreen(
        textUrl: LocalFileUrl.fromPath(path),
        title: title,
        autoTranslate: true,
      ),
    ),
  );
}

Widget _testPreviewApp(
  String filePath, {
  required String title,
  required bool autoTranslate,
  Future<String> Function(String source)? translateContentForTesting,
  AutoSaveTranslatedLyricsNotifier? autoSaveNotifier,
}) {
  final notifier = autoSaveNotifier;
  return ProviderScope(
    overrides: [
      if (notifier != null)
        autoSaveTranslatedLyricsProvider.overrideWith((ref) => notifier),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: TextPreviewScreen(
        textUrl: LocalFileUrl.fromPath(filePath),
        title: title,
        autoTranslate: autoTranslate,
        translateContentForTesting: translateContentForTesting,
      ),
    ),
  );
}

Future<Directory> _createPreviewRoot({
  required bool autoSaveTranslated,
  String? source,
  String? translated,
}) async {
  final directory = Directory.systemTemp.createTempSync('preview_auto_');
  final values = <String, Object>{
    'locale_language': 'en',
    'custom_download_path': directory.path,
    AutoSaveTranslatedLyricsNotifier.preferenceKey: autoSaveTranslated,
  };
  if (source != null && translated != null) {
    values['translation_cache_auto_en_${source.hashCode}'] = jsonEncode({
      'translation': translated,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  SharedPreferences.setMockInitialValues(values);
  await StorageService.initCritical(
    preferences: await SharedPreferences.getInstance(),
  );
  return directory;
}

Future<void> _pumpUntilContent(WidgetTester tester, String expected) async {
  final contentFinder = find.byKey(const ValueKey('text-preview-content'));
  for (
    var attempt = 0;
    attempt < 40 &&
        (contentFinder.evaluate().isEmpty ||
            tester.widget<SelectableText>(contentFinder).data != expected);
    attempt++
  ) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 40 && !ready(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(ready(), isTrue);
}

Future<void> _toggleEditMode(WidgetTester tester) async {
  final l10n = S.of(tester.element(find.byType(TextPreviewScreen)));
  final editing = find.byType(TextField).evaluate().isNotEmpty;
  await tester.tap(find.byTooltip(editing ? l10n.previewMode : l10n.editMode));
  await tester.pump();
}

class _PendingAutoSaveNotifier extends AutoSaveTranslatedLyricsNotifier {
  _PendingAutoSaveNotifier(this.enabled);

  final Completer<bool> enabled;
  bool requested = false;

  @override
  Future<bool> resolvedEnabled() {
    requested = true;
    return enabled.future;
  }
}

Future<void> _pumpUntilFile(WidgetTester tester, File file) async {
  for (
    var attempt = 0;
    attempt < 40 && await tester.runAsync(file.exists) != true;
    attempt++
  ) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

Future<void> _resolveAutoSavePreference(WidgetTester tester) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(TextPreviewScreen)),
    listen: false,
  );
  await container
      .read(autoSaveTranslatedLyricsProvider.notifier)
      .resolvedEnabled();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final hasTranslation in [true, false]) {
    testWidgets('generated preview reuses saved translation: $hasTranslation', (
      tester,
    ) async {
      const originalText = '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n';
      final translatedText = originalText.replaceFirst('こんにちは', 'Hello');
      final root = await _createPreviewRoot(autoSaveTranslated: false);
      final directory = Directory(
        path.join(
          root.path,
          'subtitle_library',
          GeneratedSubtitleStore.relativeDirectory,
          '1',
        ),
      )..createSync(recursive: true);
      final original = File(path.join(directory.path, 'audio.srt'))
        ..writeAsStringSync(originalText);
      if (hasTranslation) {
        File(
          GeneratedSubtitleStore.translatedPath(original.path),
        ).writeAsStringSync(translatedText);
      }
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => root.delete(recursive: true));
      });
      var translations = 0;
      await tester.pumpWidget(
        _testPreviewApp(
          original.path,
          title: 'audio.srt',
          autoTranslate: true,
          translateContentForTesting: (_) async {
            translations++;
            return 'unexpected new translation';
          },
        ),
      );
      final expected = hasTranslation ? translatedText : originalText;
      await _pumpUntilContent(tester, expected);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('text-preview-content')),
            )
            .data,
        expected,
      );
      expect(translations, 0);
      if (hasTranslation) {
        await tester.tap(find.byType(TranslationToolbarButton));
        await tester.pump();
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('text-preview-content')),
              )
              .data,
          originalText,
        );
      }
    });
  }

  testWidgets(
    'generated preview reuses session translation without changing playback',
    (tester) async {
      const originalText = '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n';
      final root = await _createPreviewRoot(autoSaveTranslated: false);
      final directory = Directory(
        path.join(
          root.path,
          'subtitle_library',
          GeneratedSubtitleStore.relativeDirectory,
          '1',
        ),
      )..createSync(recursive: true);
      final original = File(path.join(directory.path, 'audio.srt'))
        ..writeAsStringSync(originalText);
      const current = AudioTrack(
        id: 'other',
        title: 'other.mp3',
        url: 'file:///other.mp3',
      );
      final container = ProviderContainer(
        overrides: [
          currentTrackProvider.overrideWith((ref) => Stream.value(current)),
        ],
      );
      final controller = container.read(lyricControllerProvider.notifier);
      final lines = LyricParser.parse(originalText);
      controller.showGeneratedTranslation(
        const AudioTrack(
          id: 'generated',
          title: 'audio.wav',
          url: 'file:///audio.wav',
        ),
        original.path,
        GeneratedSubtitleTranslation(
          original: lines,
          translated: [lines.single.copyWith(text: 'Hello')],
        ),
      );
      final playbackLyrics = container.read(lyricControllerProvider);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: TextPreviewScreen(
              textUrl: LocalFileUrl.fromPath(original.path),
              title: 'audio.srt',
            ),
          ),
        ),
      );
      final translatedText = originalText.replaceFirst('こんにちは', 'Hello');
      await _pumpUntilContent(tester, translatedText);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('text-preview-content')),
            )
            .data,
        translatedText,
      );
      expect(container.read(lyricControllerProvider), same(playbackLyrics));
      expect(container.read(currentTrackProvider).valueOrNull, same(current));
    },
  );

  testWidgets('auto-translates a subtitle after local content loads', (
    tester,
  ) async {
    const source = 'Original subtitle';
    const translated = 'Translated subtitle';
    final tempDir = await _createPreviewRoot(
      autoSaveTranslated: false,
      source: source,
      translated: translated,
    );
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(source);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => tempDir.delete(recursive: true));
    });

    await tester.pumpWidget(_testApp(subtitle.path, title: 'track01.srt'));
    await _pumpUntilContent(tester, translated);

    final content = tester.widget<SelectableText>(
      find.byKey(const ValueKey('text-preview-content')),
    );
    expect(content.data, translated);
    await _resolveAutoSavePreference(tester);
    expect(
      await tester.runAsync(
        () => Directory(
          path.join(tempDir.path, 'subtitle_library', '已保存'),
        ).exists(),
      ),
      isFalse,
    );
  });

  testWidgets(
    'auto-saves translated subtitle without modifying the source file',
    (tester) async {
      const source = 'Original subtitle';
      const translated = 'Translated subtitle';
      final tempDir = await _createPreviewRoot(
        autoSaveTranslated: true,
        source: source,
        translated: translated,
      );
      final subtitle = File('${tempDir.path}/track01.srt')
        ..writeAsStringSync(source);
      final savedSubtitle = File(
        path.join(tempDir.path, 'subtitle_library', '已保存', 'track01.srt'),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => tempDir.delete(recursive: true));
      });

      await tester.pumpWidget(_testApp(subtitle.path, title: 'track01.srt'));
      await _pumpUntilContent(tester, translated);
      await _pumpUntilFile(tester, savedSubtitle);

      expect(
        await tester.runAsync(() => savedSubtitle.readAsString()),
        translated,
      );
      expect(await tester.runAsync(() => subtitle.readAsString()), source);
    },
  );

  testWidgets('does not auto-translate a non-subtitle text preview', (
    tester,
  ) async {
    const source = 'Plain text document';
    SharedPreferences.setMockInitialValues({
      'locale_language': 'en',
      AutoSaveTranslatedLyricsNotifier.preferenceKey: false,
    });
    final tempDir = Directory.systemTemp.createTempSync('preview_auto_');
    final document = File('${tempDir.path}/notes.md')
      ..writeAsStringSync(source);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => tempDir.delete(recursive: true));
    });

    await tester.pumpWidget(_testApp(document.path, title: 'notes.md'));
    await _pumpUntilContent(tester, source);

    final content = tester.widget<SelectableText>(
      find.byKey(const ValueKey('text-preview-content')),
    );
    expect(content.data, source);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('first manual translation uses the edited original subtitle', (
    tester,
  ) async {
    const source = 'Original subtitle';
    const edited = 'Edited subtitle';
    const translated = 'Translated edited subtitle';
    final tempDir = await _createPreviewRoot(autoSaveTranslated: false);
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(source);
    final requests = <String>[];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => tempDir.delete(recursive: true));
    });

    await tester.pumpWidget(
      _testPreviewApp(
        subtitle.path,
        title: 'track01.srt',
        autoTranslate: false,
        translateContentForTesting: (content) async {
          requests.add(content);
          return translated;
        },
      ),
    );
    await _pumpUntilContent(tester, source);

    await _toggleEditMode(tester);
    await tester.enterText(find.byType(TextField), edited);
    await _toggleEditMode(tester);
    await _pumpUntilContent(tester, edited);
    await tester.tap(find.byType(TranslationToolbarButton));
    await _pumpUntilContent(tester, translated);

    expect(requests, [edited]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing the original clears and replaces its old translation', (
    tester,
  ) async {
    const source = 'Original subtitle';
    const edited = 'Edited subtitle';
    final tempDir = await _createPreviewRoot(autoSaveTranslated: false);
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(source);
    final requests = <String>[];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => tempDir.delete(recursive: true));
    });

    await tester.pumpWidget(
      _testPreviewApp(
        subtitle.path,
        title: 'track01.srt',
        autoTranslate: false,
        translateContentForTesting: (content) async {
          requests.add(content);
          return 'Translated: $content';
        },
      ),
    );
    await _pumpUntilContent(tester, source);
    await tester.tap(find.byType(TranslationToolbarButton));
    await _pumpUntilContent(tester, 'Translated: $source');

    await tester.tap(find.byType(TranslationToolbarButton));
    await _pumpUntilContent(tester, source);
    await _toggleEditMode(tester);
    await tester.enterText(find.byType(TextField), edited);
    await _toggleEditMode(tester);
    await _pumpUntilContent(tester, edited);
    await tester.tap(find.byType(TranslationToolbarButton));
    await _pumpUntilContent(tester, 'Translated: $edited');

    expect(requests, [source, edited]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late translation is discarded after the original is edited', (
    tester,
  ) async {
    const source = 'Original subtitle';
    const edited = 'Edited while translating';
    const currentTranslation = 'Current translation';
    final translations = [Completer<String>(), Completer<String>()];
    final autoSave = Completer<bool>();
    final autoSaveNotifier = _PendingAutoSaveNotifier(autoSave);
    final tempDir = await _createPreviewRoot(autoSaveTranslated: true);
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(source);
    final requests = <String>[];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!autoSave.isCompleted) autoSave.complete(false);
      await tester.runAsync(() => tempDir.delete(recursive: true));
    });

    await tester.pumpWidget(
      _testPreviewApp(
        subtitle.path,
        title: 'track01.srt',
        autoTranslate: false,
        autoSaveNotifier: autoSaveNotifier,
        translateContentForTesting: (content) {
          requests.add(content);
          return translations[requests.length - 1].future;
        },
      ),
    );
    await _pumpUntilContent(tester, source);
    await tester.tap(find.byType(TranslationToolbarButton));
    await _pumpUntil(tester, () => requests.isNotEmpty);

    await _toggleEditMode(tester);
    await tester.enterText(find.byType(TextField), edited);
    await tester.pump();
    expect(
      tester
          .widget<TranslationToolbarButton>(
            find.byType(TranslationToolbarButton),
          )
          .isLoading,
      isFalse,
    );
    expect(
      find.text(
        S
            .of(tester.element(find.byType(TextPreviewScreen)))
            .preparingTranslation,
      ),
      findsNothing,
    );
    await tester.tap(find.byType(TranslationToolbarButton));
    await _pumpUntil(tester, () => requests.length == 2);

    translations[0].complete('Late old translation');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(
      tester
          .widget<TranslationToolbarButton>(
            find.byType(TranslationToolbarButton),
          )
          .isLoading,
      isTrue,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      edited,
    );
    expect(autoSaveNotifier.requested, isFalse);

    translations[1].complete(currentTranslation);
    await _pumpUntil(
      tester,
      () => !tester
          .widget<TranslationToolbarButton>(
            find.byType(TranslationToolbarButton),
          )
          .isLoading,
    );
    await _toggleEditMode(tester);
    await _pumpUntilContent(tester, currentTranslation);
    expect(autoSaveNotifier.requested, isTrue);
    autoSave.complete(false);

    expect(requests, [source, edited]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'auto-save drops a translation if its source changes while waiting',
    (tester) async {
      const source = 'Original subtitle';
      const edited = 'Edited before auto-save';
      const translated = 'Translated subtitle';
      final autoSave = Completer<bool>();
      final autoSaveNotifier = _PendingAutoSaveNotifier(autoSave);
      final tempDir = await _createPreviewRoot(autoSaveTranslated: true);
      final subtitle = File('${tempDir.path}/track01.srt')
        ..writeAsStringSync(source);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        if (!autoSave.isCompleted) autoSave.complete(false);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.runAsync(() => tempDir.delete(recursive: true));
      });

      await tester.pumpWidget(
        _testPreviewApp(
          subtitle.path,
          title: 'track01.srt',
          autoTranslate: false,
          autoSaveNotifier: autoSaveNotifier,
          translateContentForTesting: (_) async => translated,
        ),
      );
      await _pumpUntilContent(tester, source);
      await tester.tap(find.byType(TranslationToolbarButton));
      await _pumpUntilContent(tester, translated);
      await _pumpUntil(tester, () => autoSaveNotifier.requested);

      await tester.tap(find.byType(TranslationToolbarButton));
      await _pumpUntilContent(tester, source);
      await _toggleEditMode(tester);
      await tester.enterText(find.byType(TextField), edited);
      autoSave.complete(true);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      expect(
        await tester.runAsync(
          () => Directory(
            path.join(tempDir.path, 'subtitle_library', '已保存'),
          ).exists(),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

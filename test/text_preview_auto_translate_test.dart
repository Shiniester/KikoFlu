import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/local_file_url.dart';
import 'package:kikoeru_flutter/src/widgets/text_preview_screen.dart';
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
}

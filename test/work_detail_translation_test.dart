import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/settings_provider.dart';
import 'package:kikoeru_flutter/src/screens/offline_work_detail_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/widgets/offline_file_explorer_widget.dart';
import 'package:kikoeru_flutter/src/widgets/text_preview_screen.dart';
import 'package:kikoeru_flutter/src/widgets/translation_toggle_button.dart';
import 'package:kikoeru_flutter/src/widgets/work_detail/work_title_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoImageCache extends Fake implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => const Stream.empty();
}

class _Auth extends AuthNotifier {
  _Auth() : super(KikoeruApiService()) {
    state = const AuthState();
  }
}

String _cache(String translation) => jsonEncode({
  'translation': translation,
  'timestamp': DateTime.now().millisecondsSinceEpoch,
});

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 60 && !ready(); i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BaseCacheManager previousCacheManager;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => Directory.systemTemp.path,
        );
    previousCacheManager = CachedNetworkImageProvider.defaultCacheManager;
    CachedNetworkImageProvider.defaultCacheManager = _NoImageCache();
  });
  tearDown(() {
    CachedNetworkImageProvider.defaultCacheManager = previousCacheManager;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final automatic in [false, true]) {
    testWidgets('detail translation stays local with automatic=$automatic', (
      tester,
    ) async {
      const title = '作品タイトル';
      const audioTitle = '音声.wav';
      const folder = '資料';
      const subtitleTitle = '音声.srt';
      const expandedNames = 'メモ.md\n非表示';
      const source = '1\n00:00:00,000 --> 00:00:01,000\n字幕';
      final directory = Directory.systemTemp.createTempSync(
        'detail-translation-',
      );
      File('${directory.path}/$audioTitle').writeAsBytesSync([]);
      File('${directory.path}/$subtitleTitle').writeAsStringSync(source);
      Directory('${directory.path}/$folder/非表示').createSync(recursive: true);
      File('${directory.path}/$folder/メモ.md').writeAsStringSync('memo');
      File('${directory.path}/$folder/非表示/秘密.md').writeAsStringSync('secret');
      SharedPreferences.setMockInitialValues({
        'custom_download_path': directory.path,
        'locale_language': 'en',
        AutoTranslateWorkDetailsNotifier.preferenceKey: automatic,
        AutoSaveTranslatedLyricsNotifier.preferenceKey: false,
        'translation_cache_ja_en_${title.hashCode}': _cache('Translated work'),
        'translation_cache_ja_en_${audioTitle.hashCode}': _cache(
          'Translated track.wav',
        ),
        'translation_cache_ja_en_${'$folder\n$subtitleTitle'.hashCode}': _cache(
          'Translated folder\nTranslated track.srt',
        ),
        'translation_cache_ja_en_${expandedNames.hashCode}': _cache(
          'Translated memo.md\nTranslated nested folder',
        ),
        'translation_cache_auto_en_${source.hashCode}': _cache(
          'Translated subtitle',
        ),
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith((ref) => _Auth()),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
        ],
      );
      final navigator = GlobalKey<NavigatorState>();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigator,
            locale: const Locale('en'),
            theme: AppTheme.lightTheme(null),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );
      final route = MaterialPageRoute<void>(
        builder: (_) => OfflineWorkDetailScreen(
          work: const Work(id: 810, title: title),
          localWorkDirPath: directory.path,
          fileTree: const [
            {'type': 'audio', 'title': audioTitle, 'hash': 'track'},
            {
              'type': 'folder',
              'title': folder,
              'children': [
                {'type': 'text', 'title': 'メモ.md', 'hash': 'memo'},
                {
                  'type': 'folder',
                  'title': '非表示',
                  'children': [
                    {'type': 'text', 'title': '秘密.md', 'hash': 'secret'},
                  ],
                },
              ],
            },
            {'type': 'text', 'title': subtitleTitle, 'hash': 'subtitle'},
          ],
        ),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      expect(
        tester
            .widget<WorkTitleHeader>(
              find.byType(WorkTitleHeader, skipOffstage: false),
            )
            .showTranslation,
        isFalse,
      );
      expect(find.byType(OfflineFileExplorerWidget), findsNothing);
      await tester.pump(route.transitionDuration);
      await _pumpUntil(
        tester,
        () => container.read(fileListControllerProvider).workId == 810,
      );
      if (!automatic) {
        expect(
          tester
              .widget<WorkTitleHeader>(find.byType(WorkTitleHeader))
              .showTranslation,
          isFalse,
        );
        await tester.tap(find.byType(InlineTranslationButton));
      }
      await _pumpUntil(
        tester,
        () =>
            tester
                .widget<WorkTitleHeader>(find.byType(WorkTitleHeader))
                .displayTitle ==
            'Translated work',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('work-resource-files-tab')),
      );
      await _pumpUntil(
        tester,
        () => find.text('Translated track.wav').evaluate().isNotEmpty,
      );
      expect(find.byType(TranslationToggleButton), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('work-audio-subtitle-$audioTitle')),
      );
      await _pumpUntil(
        tester,
        () => find.byType(TextPreviewScreen).evaluate().isNotEmpty,
      );
      expect(
        tester
            .widget<TextPreviewScreen>(find.byType(TextPreviewScreen))
            .autoTranslate,
        isTrue,
      );
      expect(
        tester.widget<TextPreviewScreen>(find.byType(TextPreviewScreen)).title,
        subtitleTitle,
      );
      navigator.currentState!.pop();
      await _pumpUntil(
        tester,
        () => find.byType(TextPreviewScreen).evaluate().isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
      await _pumpUntil(
        tester,
        () => find.text('Translated folder').evaluate().isNotEmpty,
      );
      expect(find.text('Translated memo.md'), findsNothing);
      await tester.tap(find.text('Translated folder'));
      await _pumpUntil(
        tester,
        () => find.text('Translated nested folder').evaluate().isNotEmpty,
      );
      expect(find.text('Translated memo.md'), findsOneWidget);
      expect(find.text('秘密.md'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'translation_cache_ja_en_${'秘密.md'.hashCode}',
        _cache('Translated secret.md'),
      );
      await tester.tap(find.text('Translated nested folder'));
      await _pumpUntil(
        tester,
        () => find.text('Translated secret.md').evaluate().isNotEmpty,
      );
      await tester.ensureVisible(find.byType(InlineTranslationButton));
      await tester.tap(find.byType(InlineTranslationButton));
      await tester.pump();
      expect(
        tester
            .widget<WorkTitleHeader>(find.byType(WorkTitleHeader))
            .displayTitle,
        title,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('work-resource-files-tab')),
      );
      expect(find.text('秘密.md'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('work-resource-audio-tab')));
      await tester.pump();
      expect(find.text(audioTitle), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('work-audio-subtitle-$audioTitle')),
      );
      await _pumpUntil(
        tester,
        () => find.byType(TextPreviewScreen).evaluate().isNotEmpty,
      );
      expect(
        tester
            .widget<TextPreviewScreen>(find.byType(TextPreviewScreen))
            .autoTranslate,
        isFalse,
      );
      await _pumpUntil(tester, () {
        final content = find.byKey(const ValueKey('text-preview-content'));
        return content.evaluate().isNotEmpty &&
            tester.widget<SelectableText>(content).data == source;
      });
      expect(
        File('${directory.path}/$subtitleTitle').readAsStringSync(),
        source,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

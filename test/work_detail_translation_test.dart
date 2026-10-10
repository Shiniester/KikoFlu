import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
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
import 'package:kikoeru_flutter/src/screens/work_detail_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/chinese_script_converter.dart';
import 'package:kikoeru_flutter/src/utils/theme.dart';
import 'package:kikoeru_flutter/src/widgets/offline_file_explorer_widget.dart';
import 'package:kikoeru_flutter/src/widgets/file_explorer_widget.dart';
import 'package:kikoeru_flutter/src/widgets/tab_page_motion.dart';
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

class _OnlineApi extends KikoeruApiService {
  _OnlineApi(
    this.title, {
    this.pendingWork,
    this.lang = 'CHI_HANS',
    this.tracks = const [],
  });

  final String title;
  final Completer<Map<String, dynamic>>? pendingWork;
  final String? lang;
  final List<dynamic> tracks;
  int workRequests = 0;
  bool workCompleted = false;

  @override
  Future<Map<String, dynamic>> getWork(
    int id, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    workRequests++;
    final response = pendingWork == null
        ? {'id': id, 'title': title, 'lang': lang}
        : await pendingWork!.future;
    workCompleted = true;
    return response;
  }

  @override
  Future<List<dynamic>> getWorkTracks(
    int id, {
    bool forceRefresh = false,
  }) async => tracks;
}

String _cache(String translation) => jsonEncode({
  'translation': translation,
  'timestamp': DateTime.now().millisecondsSinceEpoch,
});

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BaseCacheManager previousCacheManager;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(() async {
    // Load assets outside widget tests so their cached futures use the real clock.
    await convertChineseScript('', toTraditional: false);
    await convertChineseScript('', toTraditional: true);
  });
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

  const scenarios =
      <({bool automatic, TranslationTargetLanguage targetLanguage})>[
        (automatic: false, targetLanguage: TranslationTargetLanguage.english),
        (automatic: true, targetLanguage: TranslationTargetLanguage.english),
        (automatic: false, targetLanguage: TranslationTargetLanguage.zhHans),
        (automatic: true, targetLanguage: TranslationTargetLanguage.zhHans),
        (automatic: false, targetLanguage: TranslationTargetLanguage.zhHant),
        (automatic: true, targetLanguage: TranslationTargetLanguage.zhHant),
      ];
  for (final scenario in scenarios) {
    final automatic = scenario.automatic;
    final targetLanguage = scenario.targetLanguage;
    final targetCode = targetLanguage == TranslationTargetLanguage.zhHans
        ? 'zh_Hans'
        : targetLanguage == TranslationTargetLanguage.zhHant
        ? 'zh_Hant'
        : 'en';
    final shouldAutoTranslate = automatic;
    testWidgets('details target=${targetLanguage.value}, auto=$automatic', (
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
        TranslationLanguagePreferencesNotifier.keyTargetLanguage:
            targetLanguage.value,
        AutoTranslateWorkDetailsNotifier.preferenceKey: automatic,
        AutoSaveTranslatedLyricsNotifier.preferenceKey: false,
        'translation_cache_ja_${targetCode}_${title.hashCode}': _cache(
          'Translated work',
        ),
        'translation_cache_ja_${targetCode}_${audioTitle.hashCode}': _cache(
          'Translated track.wav',
        ),
        'translation_cache_ja_${targetCode}_${'$folder\n$subtitleTitle'.hashCode}':
            _cache('Translated folder\nTranslated track.srt'),
        'translation_cache_ja_${targetCode}_${expandedNames.hashCode}': _cache(
          'Translated memo.md\nTranslated nested folder',
        ),
        'translation_cache_auto_${targetCode}_${source.hashCode}': _cache(
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
          work: const Work(id: 810, title: title, lang: 'JPN'),
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
      if (!shouldAutoTranslate) {
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
        'translation_cache_ja_${targetCode}_${'秘密.md'.hashCode}',
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
      await tester.pump(tabPageDuration);
      expect(find.text(audioTitle).hitTestable(), findsOneWidget);
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

  for (final online in [false, true]) {
    for (final automatic in [false, true]) {
      for (final chinese in [
        (lang: 'CHI_HANT', source: '環境音', target: 'zh_hans', expected: '环境音'),
        (lang: 'CHI_HANS', source: '后面', target: 'zh_hant', expected: '後面'),
        (lang: 'CHI_HANS', source: '后面', target: 'zh_hans', expected: '后面'),
        (lang: 'CHI_HANT', source: '環境音', target: 'zh_hant', expected: '環境音'),
      ]) {
        testWidgets(
          'Chinese details online=$online auto=$automatic ${chinese.lang}->${chinese.target}',
          (tester) async {
            final directory = Directory.systemTemp.createTempSync(
              'chinese-details-',
            );
            final filename = '${chinese.source}.wav';
            File('${directory.path}/$filename').writeAsBytesSync([]);
            final tracks = [
              {'type': 'audio', 'title': filename, 'hash': 'track'},
            ];
            final sourceCode = chinese.lang == 'CHI_HANS' ? 'zh-cn' : 'zh-tw';
            final targetCode = chinese.target == 'zh_hans'
                ? 'zh_Hans'
                : 'zh_Hant';
            SharedPreferences.setMockInitialValues({
              'custom_download_path': directory.path,
              'locale_language': 'en',
              TranslationLanguagePreferencesNotifier.keyTargetLanguage:
                  chinese.target,
              AutoTranslateWorkDetailsNotifier.preferenceKey: automatic,
              'translation_cache_${sourceCode}_${targetCode}_${chinese.source.hashCode}':
                  _cache('Unwanted cached work'),
              'translation_cache_${sourceCode}_${targetCode}_${filename.hashCode}':
                  _cache('Unwanted cached filename.wav'),
            });
            await StorageService.initCritical(
              preferences: await SharedPreferences.getInstance(),
            );
            final api = _OnlineApi(
              chinese.source,
              lang: chinese.lang,
              tracks: tracks,
            );
            final container = ProviderContainer(
              overrides: [
                authProvider.overrideWith((ref) => _Auth()),
                kikoeruApiServiceProvider.overrideWithValue(api),
                currentTrackProvider.overrideWith((ref) => Stream.value(null)),
              ],
            );
            addTearDown(() async {
              await tester.pumpWidget(const SizedBox.shrink());
              container.dispose();
              await tester.runAsync(() => directory.delete(recursive: true));
            });
            final work = Work(
              id: 813,
              title: chinese.source,
              lang: chinese.lang,
            );
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: container,
                child: MaterialApp(
                  locale: const Locale('en'),
                  theme: AppTheme.lightTheme(null),
                  localizationsDelegates: S.localizationsDelegates,
                  supportedLocales: S.supportedLocales,
                  home: online
                      ? WorkDetailScreen(work: work)
                      : OfflineWorkDetailScreen(
                          work: work,
                          fileTree: tracks,
                          localWorkDirPath: directory.path,
                        ),
                ),
              ),
            );
            await _pumpUntil(
              tester,
              () => online
                  ? find.byType(FileExplorerWidget).evaluate().isNotEmpty
                  : container.read(fileListControllerProvider).workId ==
                        work.id,
            );
            final sameLanguage = chinese.source == chinese.expected;
            if (!automatic || sameLanguage) {
              expect(
                tester
                    .widget<WorkTitleHeader>(find.byType(WorkTitleHeader))
                    .showTranslation,
                isFalse,
              );
              await tester.ensureVisible(find.byType(InlineTranslationButton));
              await tester.tap(find.byType(InlineTranslationButton));
            }
            await _pumpUntil(tester, () {
              final header = tester.widget<WorkTitleHeader>(
                find.byType(WorkTitleHeader),
              );
              return header.showTranslation &&
                  header.displayTitle == chinese.expected &&
                  !header.isTranslating;
            });
            await _pumpUntil(
              tester,
              () => find
                  .byKey(const ValueKey('work-resource-files-tab'))
                  .evaluate()
                  .isNotEmpty,
            );
            await tester.ensureVisible(
              find.byKey(const ValueKey('work-resource-files-tab')),
            );
            await _pumpUntil(
              tester,
              () => find.text('${chinese.expected}.wav').evaluate().isNotEmpty,
            );
            expect(find.text('Unwanted cached filename.wav'), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final pending in [
    (automatic: false, leaveEarly: false, initialLang: null),
    (automatic: true, leaveEarly: false, initialLang: null),
    (automatic: false, leaveEarly: true, initialLang: null),
    (automatic: true, leaveEarly: false, initialLang: 'ENG'),
    (automatic: true, leaveEarly: false, initialLang: 'CHI_HANS'),
  ]) {
    testWidgets(
      'pending language metadata auto=${pending.automatic} leave=${pending.leaveEarly} initial=${pending.initialLang}',
      (tester) async {
        const title = '環境音';
        const filename = '環境音.wav';
        final response = Completer<Map<String, dynamic>>();
        SharedPreferences.setMockInitialValues({
          'locale_language': 'en',
          TranslationLanguagePreferencesNotifier.keyTargetLanguage: 'zh_hans',
          AutoTranslateWorkDetailsNotifier.preferenceKey: pending.automatic,
          'translation_cache_auto_zh_Hans_${title.hashCode}': _cache(
            'Premature translated title',
          ),
          'translation_cache_auto_zh_Hans_${filename.hashCode}': _cache(
            'Premature translated filename',
          ),
          'translation_cache_en_zh_Hans_${title.hashCode}': _cache(
            'Known English title',
          ),
          'translation_cache_en_zh_Hans_${filename.hashCode}': _cache(
            'Known English filename',
          ),
        });
        await StorageService.initCritical(
          preferences: await SharedPreferences.getInstance(),
        );
        final api = _OnlineApi(
          title,
          pendingWork: response,
          tracks: const [
            {'type': 'audio', 'title': filename, 'hash': 'track'},
          ],
        );
        final container = ProviderContainer(
          overrides: [
            authProvider.overrideWith((ref) => _Auth()),
            kikoeruApiServiceProvider.overrideWithValue(api),
            currentTrackProvider.overrideWith((ref) => Stream.value(null)),
          ],
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: WorkDetailScreen(
                work: Work(id: 814, title: title, lang: pending.initialLang),
              ),
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () =>
              api.workRequests == 1 &&
              find.byType(FileExplorerWidget).evaluate().isNotEmpty,
        );
        if (!pending.automatic) {
          await tester.ensureVisible(find.byType(InlineTranslationButton));
          await tester.tap(find.byType(InlineTranslationButton));
        }
        // A pending manual translation animates its progress indicator.
        await tester.pump(const Duration(milliseconds: 100));
        if (pending.initialLang != 'ENG') {
          expect(
            tester
                .widget<WorkTitleHeader>(find.byType(WorkTitleHeader))
                .displayTitle,
            title,
          );
        } else {
          await _pumpUntil(
            tester,
            () =>
                tester
                    .widget<WorkTitleHeader>(find.byType(WorkTitleHeader))
                    .displayTitle ==
                'Known English title',
          );
        }
        expect(find.text('Premature translated filename'), findsNothing);
        if (pending.leaveEarly) {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        response.complete({'id': 814, 'title': title, 'lang': 'CHI_HANT'});
        await _pumpUntil(tester, () => api.workCompleted);
        if (!pending.leaveEarly) {
          await _pumpUntil(
            tester,
            () =>
                tester
                    .widget<WorkTitleHeader>(find.byType(WorkTitleHeader))
                    .displayTitle ==
                '环境音',
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('work-resource-files-tab')),
          );
          await _pumpUntil(
            tester,
            () => find.text('环境音.wav').evaluate().isNotEmpty,
          );
        } else {
          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.getKeys().where(
              (key) => key.startsWith('translation_cache_opencc_'),
            ),
            isEmpty,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'online details skip automatic translation for simplified CHI_HANS',
    (tester) async {
      const title = '作品タイトル';
      SharedPreferences.setMockInitialValues({
        'locale_language': 'en',
        TranslationLanguagePreferencesNotifier.keyTargetLanguage:
            TranslationTargetLanguage.zhHans.value,
        AutoTranslateWorkDetailsNotifier.preferenceKey: true,
        'translation_cache_ja_zh_Hans_${title.hashCode}': _cache(
          'Translated work',
        ),
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final api = _OnlineApi(title);
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith((ref) => _Auth()),
          kikoeruApiServiceProvider.overrideWithValue(api),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: WorkDetailScreen(
              work: Work(id: 811, title: title, lang: 'CHI_HANS'),
            ),
          ),
        ),
      );
      await _pumpUntil(tester, () => api.workRequests == 1);
      await tester.pumpAndSettle();
      final header = tester.widget<WorkTitleHeader>(
        find.byType(WorkTitleHeader),
      );
      expect(header.showTranslation, isFalse);
      expect(header.displayTitle, title);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'online details wait for missing language metadata before auto translation',
    (tester) async {
      const initialTitle = '仮タイトル';
      const detailedTitle = '作品タイトル';
      final workResponse = Completer<Map<String, dynamic>>();
      SharedPreferences.setMockInitialValues({
        'locale_language': 'en',
        TranslationLanguagePreferencesNotifier.keyTargetLanguage:
            TranslationTargetLanguage.zhHans.value,
        AutoTranslateWorkDetailsNotifier.preferenceKey: true,
        'translation_cache_ja_zh_Hans_${initialTitle.hashCode}': _cache(
          'Translated initial work',
        ),
        'translation_cache_ja_zh_Hans_${detailedTitle.hashCode}': _cache(
          'Translated work',
        ),
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final api = _OnlineApi(initialTitle, pendingWork: workResponse);
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith((ref) => _Auth()),
          kikoeruApiServiceProvider.overrideWithValue(api),
          currentTrackProvider.overrideWith((ref) => Stream.value(null)),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: WorkDetailScreen(work: Work(id: 812, title: initialTitle)),
          ),
        ),
      );
      await _pumpUntil(tester, () => api.workRequests == 1);
      await tester.pumpAndSettle();
      expect(api.workCompleted, isFalse);
      expect(
        tester
            .widget<WorkTitleHeader>(find.byType(WorkTitleHeader))
            .showTranslation,
        isFalse,
      );

      workResponse.complete({
        'id': 812,
        'title': detailedTitle,
        'lang': 'CHI_HANS',
      });
      await _pumpUntil(tester, () => api.workCompleted);
      await _pumpUntil(
        tester,
        () =>
            tester
                .widget<WorkTitleHeader>(find.byType(WorkTitleHeader))
                .displayTitle ==
            detailedTitle,
      );
      await tester.pumpAndSettle();
      var header = tester.widget<WorkTitleHeader>(find.byType(WorkTitleHeader));
      expect(header.showTranslation, isFalse);
      expect(header.displayTitle, detailedTitle);

      await tester.ensureVisible(find.byType(InlineTranslationButton));
      await tester.tap(find.byType(InlineTranslationButton));
      await _pumpUntil(
        tester,
        () => tester
            .widget<WorkTitleHeader>(find.byType(WorkTitleHeader))
            .showTranslation,
      );
      header = tester.widget<WorkTitleHeader>(find.byType(WorkTitleHeader));
      expect(header.showTranslation, isTrue);
      expect(header.displayTitle, detailedTitle);
      expect(tester.takeException(), isNull);
    },
  );
}

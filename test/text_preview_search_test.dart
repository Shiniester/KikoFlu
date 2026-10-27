import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/subtitle_search_query_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/utils/local_file_url.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_lyrics_surface.dart';
import 'package:kikoeru_flutter/src/widgets/text_preview_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _testApp(String filePath) {
  return ProviderScope(
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: TextPreviewScreen(
        textUrl: LocalFileUrl.fromPath(filePath),
        title: 'track01.srt',
      ),
    ),
  );
}

Widget _playerApp(String filePath) {
  final lyrics = [
    LyricLine(
      startTime: Duration.zero,
      endTime: const Duration(seconds: 5),
      text: 'needle current line',
    ),
    LyricLine(
      startTime: const Duration(seconds: 5),
      endTime: const Duration(seconds: 10),
      text: 'later needle result',
    ),
    LyricLine(
      startTime: const Duration(seconds: 10),
      endTime: const Duration(seconds: 15),
      text: 'last needle result',
    ),
  ];
  return ProviderScope(
    overrides: [
      positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
      lyricControllerProvider.overrideWith(
        (ref) => LyricController(ref, initialState: LyricState(lyrics: lyrics)),
      ),
      audioSliceStateProvider.overrideWith((ref) => const Stream.empty()),
      durationProvider.overrideWith((ref) => const Stream.empty()),
      isTrackLoadingProvider.overrideWith((ref) => const Stream.empty()),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      home: Scaffold(
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        body: PlayerLyricsSurface(
          isWide: false,
          onFullscreen: () {},
          translateButton: const IconButton(
            onPressed: null,
            icon: Icon(Icons.translate),
          ),
        ),
        floatingActionButton: Builder(
          builder: (context) => FloatingActionButton(
            key: const ValueKey('open-preview'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => TextPreviewScreen(
                    textUrl: LocalFileUrl.fromPath(filePath),
                    title: 'track01.srt',
                  ),
                ),
              );
            },
            child: const Icon(Icons.description),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'locale_language': 'en'});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets(
    'search action precedes edit and navigates case-insensitive matches',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'text_preview_search_',
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 5; attempt++) {
            try {
              if (await tempDir.exists()) {
                await tempDir.delete(recursive: true);
              }
              return;
            } on FileSystemException {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
        });
      });

      final lines = <String>[
        'Alpha opening line',
        ...List.generate(100, (index) => 'filler subtitle line $index'),
        'middle ALPHA line',
        ...List.generate(100, (index) => 'more filler line $index'),
        'closing alpha line',
      ];
      final subtitle = File('${tempDir.path}/track01.srt');
      subtitle.writeAsStringSync(lines.join('\n'));

      await tester.pumpWidget(_testApp(subtitle.path));
      final searchAction = find.byKey(
        const ValueKey('text-preview-search-action'),
      );
      for (
        var attempt = 0;
        attempt < 40 && searchAction.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }

      final editAction = find.byIcon(Icons.edit);
      expect(searchAction, findsOneWidget);
      expect(editAction, findsOneWidget);
      expect(
        tester.getCenter(searchAction).dx,
        lessThan(tester.getCenter(editAction).dx),
      );

      await tester.tap(searchAction);
      await tester.pump();
      final searchField = find.byKey(
        const ValueKey('text-preview-search-field'),
      );
      expect(searchField, findsOneWidget);

      await tester.enterText(searchField, 'alpha');
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('1/3'), findsOneWidget);

      final selectable = tester.widget<SelectableText>(
        find.byKey(const ValueKey('text-preview-content')),
      );
      final highlightedSpans = selectable.textSpan!.children!
          .whereType<TextSpan>()
          .where((span) => span.style?.backgroundColor != null);
      expect(highlightedSpans, hasLength(3));

      final scrollable = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scrollable.controller!.position.maxScrollExtent, greaterThan(0));
      expect(scrollable.controller!.offset, 0);

      await tester.tap(find.byKey(const ValueKey('text-preview-search-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('2/3'), findsOneWidget);
      expect(scrollable.controller!.offset, greaterThan(0));

      await tester.tap(
        find.byKey(const ValueKey('text-preview-search-previous')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('1/3'), findsOneWidget);

      await tester.enterText(searchField, 'missing');
      await tester.pump();
      expect(find.text('0/0'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('text-preview-search-close')));
      await tester.pump();
      expect(searchField, findsNothing);
    },
  );

  testWidgets(
    'search query is shared with the player and survives reopening the app',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'shared_subtitle_search_',
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
      });
      final subtitle = File('${tempDir.path}/track01.srt')
        ..writeAsStringSync('needle current line\nlater needle result');

      await tester.pumpWidget(_playerApp(subtitle.path));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('open-preview')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final previewSearch = find.byKey(
        const ValueKey('text-preview-search-action'),
      );
      for (
        var attempt = 0;
        attempt < 40 && previewSearch.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      await tester.tap(previewSearch);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('text-preview-search-field')),
        'needle',
      );
      await tester.pump();
      expect(
        ProviderScope.containerOf(
          tester.element(
            find.byKey(const ValueKey('text-preview-search-field')),
          ),
          listen: false,
        ).read(subtitleSearchQueryProvider),
        'needle',
      );

      await tester.tap(find.byKey(const ValueKey('text-preview-search-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      Navigator.of(
        tester.element(find.byType(TextPreviewScreen)),
        rootNavigator: true,
      ).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TextPreviewScreen), findsNothing);
      await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('lyric-search-field')))
            .controller!
            .text,
        'needle',
      );
      expect(find.text('2/3'), findsOneWidget);
      final playerContainer = ProviderScope.containerOf(
        tester.element(find.byType(PlayerLyricsSurface)),
        listen: false,
      );
      expect(playerContainer.read(currentLyricIndexProvider), 0);

      final playerSearchField = find.byKey(
        const ValueKey('lyric-search-field'),
      );
      await tester.enterText(playerSearchField, '');
      await tester.pump();
      expect(playerContainer.read(subtitleSearchQueryProvider), isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          SubtitleSearchQueryNotifier.preferenceKey,
        ),
        isNull,
      );
      await tester.enterText(playerSearchField, 'needle');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_testApp(subtitle.path));
      final restartedSearch = find.byKey(
        const ValueKey('text-preview-search-action'),
      );
      for (
        var attempt = 0;
        attempt < 40 && restartedSearch.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      await tester.tap(restartedSearch);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('text-preview-search-field')),
            )
            .controller!
            .text,
        'needle',
      );

      await tester.tap(find.byKey(const ValueKey('text-preview-search-clear')));
      await tester.pump();
      expect(
        (await SharedPreferences.getInstance()).getString(
          SubtitleSearchQueryNotifier.preferenceKey,
        ),
        isNull,
      );
    },
  );
}

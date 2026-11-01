import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

Widget _testApp(String filePath, {ThemeData? theme}) {
  return ProviderScope(
    child: MaterialApp(
      theme: theme,
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

RenderEditable _contentRenderEditable(
  WidgetTester tester, {
  required bool editing,
}) {
  final contentFinder = find.byKey(
    ValueKey(editing ? 'text-preview-edit-field' : 'text-preview-content'),
  );
  final editableFinder = find.descendant(
    of: contentFinder,
    matching: find.byType(EditableText),
  );
  return tester.state<EditableTextState>(editableFinder).renderEditable;
}

double _documentYForMatch(
  WidgetTester tester,
  int matchOffset, {
  required bool editing,
}) {
  final renderEditable = _contentRenderEditable(tester, editing: editing);
  final caretRect = renderEditable.getLocalRectForCaret(
    TextPosition(offset: matchOffset),
  );
  final scrollView = find.byType(SingleChildScrollView);
  final viewportRect = tester.getRect(scrollView);
  final controller = tester
      .widget<SingleChildScrollView>(scrollView)
      .controller!;
  return controller.offset +
      renderEditable.localToGlobal(caretRect.topLeft).dy -
      viewportRect.top;
}

double _markerYForMatch(
  WidgetTester tester,
  int matchOffset, {
  required bool editing,
}) {
  final scrollView = find.byType(SingleChildScrollView);
  final controller = tester
      .widget<SingleChildScrollView>(scrollView)
      .controller!;
  final contentExtent =
      controller.position.maxScrollExtent +
      controller.position.viewportDimension;
  final railRect = tester.getRect(
    find.byKey(const ValueKey('text-preview-search-marker-rail')),
  );
  return _documentYForMatch(tester, matchOffset, editing: editing) /
      contentExtent *
      railRect.height;
}

Future<void> _tapMarkerForMatch(
  WidgetTester tester,
  int matchOffset, {
  required bool editing,
}) async {
  final railRect = tester.getRect(
    find.byKey(const ValueKey('text-preview-search-marker-rail')),
  );
  await tester.tapAt(
    Offset(
      railRect.center.dx,
      railRect.top + _markerYForMatch(tester, matchOffset, editing: editing),
    ),
  );
}

Future<Color> _markerPixelColorAt(WidgetTester tester, double y) async {
  final rail = find.byKey(const ValueKey('text-preview-search-marker-rail'));
  final customPaint = find.descendant(
    of: rail,
    matching: find.byType(CustomPaint),
  );
  final widget = tester.widget<CustomPaint>(customPaint);
  final size = tester.getSize(customPaint);
  final recorder = ui.PictureRecorder();
  widget.painter!.paint(ui.Canvas(recorder), size);
  final picture = recorder.endRecording();
  try {
    return (await tester.runAsync(() async {
      final image = await picture.toImage(
        size.width.round(),
        size.height.round(),
      );
      try {
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final x = image.width ~/ 2;
        final pixelY = y.round().clamp(0, image.height - 1).toInt();
        final offset = (pixelY * image.width + x) * 4;
        return Color.fromARGB(
          pixels.getUint8(offset + 3),
          pixels.getUint8(offset),
          pixels.getUint8(offset + 1),
          pixels.getUint8(offset + 2),
        );
      } finally {
        image.dispose();
      }
    }))!;
  } finally {
    picture.dispose();
  }
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
      expect(
        find.byKey(const ValueKey('text-preview-search-marker-rail')),
        findsOneWidget,
      );

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
      expect(
        find.byKey(const ValueKey('text-preview-search-marker-rail')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('text-preview-search-close')));
      await tester.pump();
      expect(searchField, findsNothing);
      expect(
        find.byKey(const ValueKey('text-preview-search-marker-rail')),
        findsNothing,
      );
    },
  );

  testWidgets('short preview selects the middle search marker', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_short_markers_',
    );
    const content = 'needle first\nneedle middle\nneedle last';
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await subtitle.delete();
        await tempDir.delete();
      });
    });

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

    await tester.tap(searchAction);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('text-preview-search-field')),
      'needle',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('1/3'), findsOneWidget);

    await _tapMarkerForMatch(
      tester,
      content.indexOf('needle', 1),
      editing: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets(
    'search markers follow wrapped lines across resize and keep the scrollbar draggable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final tempDir = Directory.systemTemp.createTempSync(
        'text_preview_marker_layout_',
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
      });

      final content = [
        'needle first',
        ...List.filled(180, 'x'),
        'needle middle',
        'z' * 3000,
        'needle last',
      ].join('\n');
      final subtitle = File('${tempDir.path}/track01.srt')
        ..writeAsStringSync(content);

      await tester.pumpWidget(
        _testApp(
          subtitle.path,
          theme: ThemeData(platform: TargetPlatform.windows),
        ),
      );
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

      await tester.tap(searchAction);
      await tester.pump();
      final searchField = find.byKey(
        const ValueKey('text-preview-search-field'),
      );
      await tester.enterText(searchField, 'needle');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('1/3'), findsOneWidget);

      final scrollView = find.byType(SingleChildScrollView);
      final controller = tester
          .widget<SingleChildScrollView>(scrollView)
          .controller!;
      final middleOffset = content.indexOf(
        'needle',
        content.indexOf('needle') + 1,
      );
      final renderEditable = _contentRenderEditable(tester, editing: false);
      final caretRect = renderEditable.getLocalRectForCaret(
        TextPosition(offset: middleOffset),
      );
      final viewportRect = tester.getRect(scrollView);
      final documentY = _documentYForMatch(
        tester,
        middleOffset,
        editing: false,
      );
      final expectedOffset =
          (documentY -
                  (controller.position.viewportDimension - caretRect.height) *
                      0.25)
              .clamp(0.0, controller.position.maxScrollExtent)
              .toDouble();

      await _tapMarkerForMatch(tester, middleOffset, editing: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('2/3'), findsOneWidget);
      expect(controller.offset, closeTo(expectedOffset, 2));

      await tester.binding.setSurfaceSize(const Size(900, 720));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);

      final lastOffset = content.lastIndexOf('needle');
      await _tapMarkerForMatch(tester, lastOffset, editing: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('3/3'), findsOneWidget);
      expect(tester.takeException(), isNull);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);

      final rail = find.byKey(
        const ValueKey('text-preview-search-marker-rail'),
      );
      final railRect = tester.getRect(rail);
      final markerPosition = Offset(
        railRect.center.dx,
        railRect.top + _markerYForMatch(tester, lastOffset, editing: false),
      );
      final gesture = await tester.startGesture(markerPosition);
      await gesture.up();
      expect(tester.binding.hasScheduledFrame, isTrue);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('3/3'), findsOneWidget);
      expect(controller.offset, greaterThan(0));

      controller.jumpTo(0);
      await tester.pump();
      final scrollbar = find.ancestor(
        of: scrollView,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollbar && identical(widget.controller, controller),
        ),
      );
      final scrollRect = tester.getRect(scrollbar);
      await tester.dragFrom(
        Offset(scrollRect.right - 2, scrollRect.top + 12),
        const Offset(0, 120),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(tester.takeException(), isNull);
      expect(viewportRect.height, greaterThan(0));
    },
  );

  testWidgets('a marker on a line with repeated matches selects the first', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_same_line_marker_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    const content = 'needle needle';
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);

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

    await tester.tap(searchAction);
    await tester.pump();
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    await tester.enterText(searchField, 'needle');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('text-preview-search-next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('2/2'), findsOneWidget);

    await _tapMarkerForMatch(tester, content.indexOf('needle'), editing: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('the current marker stays visible when nearby marks overlap', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_overlapping_markers_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    final content = 'needle\nneedle\n${'x' * 25000}\nneedle';
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);

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

    await tester.tap(searchAction);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('text-preview-search-field')),
      'needle',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('1/3'), findsOneWidget);

    final firstY = _markerYForMatch(tester, 0, editing: false);
    final secondY = _markerYForMatch(
      tester,
      content.indexOf('needle', 1),
      editing: false,
    );
    expect((firstY - secondY).abs(), lessThan(2));

    final rail = find.byKey(const ValueKey('text-preview-search-marker-rail'));
    final currentColor = Theme.of(tester.element(rail)).colorScheme.primary;
    expect(await _markerPixelColorAt(tester, firstY), currentColor);
  });

  testWidgets('editing mode selects a marked match and updates after edits', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_edit_marker_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    final content =
        'needle first\n${List.filled(100, 'filler').join('\n')}\nneedle second';
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);

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

    await tester.tap(searchAction);
    await tester.pump();
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    await tester.enterText(searchField, 'needle');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byIcon(Icons.edit));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('1/2'), findsOneWidget);

    final secondOffset = content.lastIndexOf('needle');
    await _tapMarkerForMatch(tester, secondOffset, editing: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('2/2'), findsOneWidget);

    final editField = find.byKey(const ValueKey('text-preview-edit-field'));
    final controller = tester.widget<TextField>(editField).controller!;
    expect(controller.selection.start, secondOffset);
    expect(controller.selection.end, secondOffset + 'needle'.length);

    final updatedText = controller.text.replaceRange(
      controller.selection.start,
      controller.selection.end,
      'edited',
    );
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: updatedText,
        selection: TextSelection.collapsed(
          offset: controller.selection.start + 'edited'.length,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.text, updatedText);
    expect(find.text('1/1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('text-preview-search-marker-rail')),
      findsOneWidget,
    );

    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    await tester.pump();
    final scrollView = find.byType(SingleChildScrollView);
    final scrollController = tester
        .widget<SingleChildScrollView>(scrollView)
        .controller!;
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();

    await tester.binding.setSurfaceSize(const Size(360, 720));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(
      scrollController.offset,
      closeTo(scrollController.position.maxScrollExtent, 1),
    );
    expect(find.text('1/1'), findsOneWidget);
  });

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

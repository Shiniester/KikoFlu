import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
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

Finder _textHighlightPainterFinder() => find
    .ancestor(
      of: find.byKey(const ValueKey('text-preview-content')),
      matching: find.byType(CustomPaint),
    )
    .first;

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 40 && finder.evaluate().isEmpty; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(finder, findsOneWidget);
}

Future<void> _pumpUntilScheduledFramesIdle(WidgetTester tester) async {
  for (
    var attempt = 0;
    attempt < 300 && tester.binding.hasScheduledFrame;
    attempt++
  ) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(tester.binding.hasScheduledFrame, isFalse);
}

Future<void> _tapMarkerForMatch(
  WidgetTester tester,
  int matchOffset, {
  required bool editing,
}) async {
  await _pumpUntilScheduledFramesIdle(tester);
  final railRect = tester.getRect(
    find.byKey(const ValueKey('text-preview-search-marker-rail')),
  );
  final markerY = _markerYForMatch(
    tester,
    matchOffset,
    editing: editing,
  ).clamp(2.0, railRect.height - 2.0);
  await tester.tapAt(Offset(railRect.center.dx, railRect.top + markerY));
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

Future<Color> _textHighlightPixelColorAt(
  WidgetTester tester,
  int matchOffset, {
  int matchLength = 5,
  Offset? paintLocalSamplePoint,
}) async {
  final paintFinder = _textHighlightPainterFinder();
  final paintWidget = tester.widget<CustomPaint>(paintFinder);
  final paintSize = tester.getSize(paintFinder);
  final paintRenderObject = tester.renderObject<RenderBox>(paintFinder);
  final renderEditable = _contentRenderEditable(tester, editing: false);
  final boxes = renderEditable.getBoxesForSelection(
    TextSelection(
      baseOffset: matchOffset,
      extentOffset: matchOffset + matchLength,
    ),
  );
  expect(boxes, isNotEmpty);
  final matchPoint =
      paintLocalSamplePoint ??
      paintRenderObject.globalToLocal(
        renderEditable.localToGlobal(boxes.first.toRect().center),
      );

  final recorder = ui.PictureRecorder();
  paintWidget.painter!.paint(ui.Canvas(recorder), paintSize);
  final picture = recorder.endRecording();
  try {
    return (await tester.runAsync(() async {
      final image = await picture.toImage(
        paintSize.width.round(),
        paintSize.height.round(),
      );
      try {
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final x = matchPoint.dx.round().clamp(0, image.width - 1).toInt();
        final y = matchPoint.dy.round().clamp(0, image.height - 1).toInt();
        final offset = (y * image.width + x) * 4;
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

int _colorChannelByte(double channel) => (channel * 255).round();

void _expectHighlightAlpha(Color actual, Color expected) {
  expect(
    _colorChannelByte(actual.a),
    closeTo(_colorChannelByte(expected.a), 1),
  );
}

void _expectOtherHighlightColor(Color color, ColorScheme colorScheme) {
  final expectedColor = colorScheme.tertiaryContainer.withValues(alpha: 0.7);
  int premultipliedChannel(double channel) =>
      (channel * expectedColor.a * 255).round();
  _expectHighlightAlpha(color, expectedColor);
  expect(
    _colorChannelByte(color.r),
    closeTo(premultipliedChannel(expectedColor.r), 1),
  );
  expect(
    _colorChannelByte(color.g),
    closeTo(premultipliedChannel(expectedColor.g), 1),
  );
  expect(
    _colorChannelByte(color.b),
    closeTo(premultipliedChannel(expectedColor.b), 1),
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
      expect(highlightedSpans, hasLength(1));
      expect(highlightedSpans.single.text, 'Alpha');
      expect(selectable.textSpan!.children, hasLength(lessThanOrEqualTo(3)));
      expect(_textHighlightPainterFinder(), findsOneWidget);

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

  testWidgets(
    'visible search highlights keep their colors and selectable text behavior',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'text_preview_visible_highlights_',
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
      });

      final content = [
        'Alpha opening line',
        'middle ALPHA line',
        'closing alpha line',
        ...List.filled(40, 'filler subtitle line'),
        'last alpha line',
      ].join('\n');
      final subtitle = File('${tempDir.path}/track01.srt')
        ..writeAsStringSync(content);

      await tester.pumpWidget(_testApp(subtitle.path));
      await _pumpUntilFound(
        tester,
        find.byKey(const ValueKey('text-preview-search-action')),
      );
      await tester.tap(
        find.byKey(const ValueKey('text-preview-search-action')),
      );
      await tester.pump();
      final searchField = find.byKey(
        const ValueKey('text-preview-search-field'),
      );
      await tester.enterText(searchField, 'alpha');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('1/4'), findsOneWidget);

      final selectable = tester.widget<SelectableText>(
        find.byKey(const ValueKey('text-preview-content')),
      );
      final currentSpan = selectable.textSpan!.children!
          .whereType<TextSpan>()
          .singleWhere((span) => span.style?.backgroundColor != null);
      final colorScheme = Theme.of(tester.element(searchField)).colorScheme;
      expect(currentSpan.text, 'Alpha');
      expect(currentSpan.style!.backgroundColor, colorScheme.primaryContainer);
      expect(currentSpan.style!.color, colorScheme.onPrimaryContainer);
      expect(currentSpan.style!.fontWeight, FontWeight.w700);

      final otherMatchOffset = content.indexOf('ALPHA');
      final otherHighlight = await _textHighlightPixelColorAt(
        tester,
        otherMatchOffset,
      );
      final expectedOtherColor = colorScheme.tertiaryContainer.withValues(
        alpha: 0.7,
      );
      _expectOtherHighlightColor(otherHighlight, colorScheme);

      final renderEditable = _contentRenderEditable(tester, editing: false);
      final selectionBox = renderEditable
          .getBoxesForSelection(
            TextSelection(
              baseOffset: otherMatchOffset,
              extentOffset: otherMatchOffset + 'ALPHA'.length,
            ),
          )
          .first;
      await tester.longPressAt(
        renderEditable.localToGlobal(selectionBox.toRect().center),
      );
      await tester.pump();
      final selection = renderEditable.selection;
      expect(selection, isNotNull);
      expect(selection!.start, lessThanOrEqualTo(otherMatchOffset));
      expect(
        selection.end,
        greaterThanOrEqualTo(otherMatchOffset + 'ALPHA'.length),
      );

      final scrollView = find.byType(SingleChildScrollView);
      final scrollController = tester
          .widget<SingleChildScrollView>(scrollView)
          .controller!;
      FocusManager.instance.primaryFocus?.unfocus();
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();
      final lastMatchOffset = content.lastIndexOf('alpha');
      final lastHighlight = await _textHighlightPixelColorAt(
        tester,
        lastMatchOffset,
      );
      _expectHighlightAlpha(lastHighlight, expectedOtherColor);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mixed-script caret positions stay ordered across visual lines', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_mixed_script_marker_positions_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    const content =
        'needle 日本語 🚀 needle e\u0301 needle\nעברית needle 🧪 العربية needle 🚀 needle';
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);

    await tester.pumpWidget(_testApp(subtitle.path));
    final searchAction = find.byKey(
      const ValueKey('text-preview-search-action'),
    );
    await _pumpUntilFound(tester, searchAction);
    await tester.tap(searchAction);
    await tester.pump();
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    await tester.enterText(searchField, 'needle');
    await tester.pump();
    await _pumpUntilScheduledFramesIdle(tester);
    expect(find.text('1/6'), findsOneWidget);

    final renderEditable = _contentRenderEditable(tester, editing: false);
    final viewport = RenderAbstractViewport.of(renderEditable);
    final matchOffsets = <int>[];
    for (
      var offset = content.indexOf('needle');
      offset >= 0;
      offset = content.indexOf('needle', offset + 'needle'.length)
    ) {
      matchOffsets.add(offset);
    }

    final caretRects = matchOffsets
        .map(
          (offset) =>
              renderEditable.getLocalRectForCaret(TextPosition(offset: offset)),
        )
        .toList(growable: false);
    final lineRanges = matchOffsets
        .map(
          (offset) =>
              renderEditable.getLineAtOffset(TextPosition(offset: offset)),
        )
        .toList(growable: false);
    final revealOffsets = List<double>.generate(matchOffsets.length, (index) {
      return viewport
          .getOffsetToReveal(renderEditable, 0, rect: caretRects[index])
          .offset;
    });

    expect(matchOffsets, hasLength(6));
    expect(lineRanges.map((line) => line.baseOffset).toSet(), hasLength(2));
    for (var index = 1; index < matchOffsets.length; index++) {
      if (lineRanges[index].baseOffset == lineRanges[index - 1].baseOffset) {
        expect(
          lineRanges[index].extentOffset,
          lineRanges[index - 1].extentOffset,
        );
      }
      expect(
        caretRects[index].top,
        greaterThanOrEqualTo(caretRects[index - 1].top - 0.5),
      );
      expect(
        revealOffsets[index],
        greaterThanOrEqualTo(revealOffsets[index - 1] - 0.5),
      );
    }
  });

  testWidgets('visible non-current combining-mark matches keep a background', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_combining_mark_highlight_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    const grapheme = 'e\u0301';
    const query = '\u0301';
    final content = [
      'first $grapheme',
      ...List.generate(20, (index) => 'filler line $index'),
      'target $grapheme',
    ].join('\n');
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);

    await tester.pumpWidget(_testApp(subtitle.path));
    final searchAction = find.byKey(
      const ValueKey('text-preview-search-action'),
    );
    await _pumpUntilFound(tester, searchAction);
    await tester.tap(searchAction);
    await tester.pump();
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    await tester.enterText(searchField, query);
    await tester.pump();
    await _pumpUntilScheduledFramesIdle(tester);
    expect(find.text('1/2'), findsOneWidget);

    final renderEditable = _contentRenderEditable(tester, editing: false);
    final combiningMarkOffset = content.lastIndexOf(query);
    expect(
      renderEditable.getBoxesForSelection(
        TextSelection(
          baseOffset: combiningMarkOffset,
          extentOffset: combiningMarkOffset + query.length,
        ),
      ),
      isEmpty,
    );

    final color = await _textHighlightPixelColorAt(
      tester,
      content.lastIndexOf(grapheme),
      matchLength: grapheme.length,
    );
    final colorScheme = Theme.of(tester.element(searchField)).colorScheme;
    _expectOtherHighlightColor(color, colorScheme);
  });

  testWidgets('partial grapheme matches with non-empty boxes keep backgrounds', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_partial_grapheme_highlight_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    const startGrapheme = 'e\u0301';
    const endGrapheme = 'cafe\u0301';
    const content =
        'first ${startGrapheme}x target ${startGrapheme}x\nfirst $endGrapheme target $endGrapheme';
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);

    await tester.pumpWidget(_testApp(subtitle.path));
    final searchAction = find.byKey(
      const ValueKey('text-preview-search-action'),
    );
    await _pumpUntilFound(tester, searchAction);
    await tester.tap(searchAction);
    await tester.pump();
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));

    const startsInsideGrapheme = '\u0301x';
    await tester.enterText(searchField, startsInsideGrapheme);
    await tester.pump();
    await _pumpUntilScheduledFramesIdle(tester);
    expect(find.text('1/2'), findsOneWidget);

    var renderEditable = _contentRenderEditable(tester, editing: false);
    final partialStartOffset = content.lastIndexOf(startsInsideGrapheme);
    expect(
      renderEditable.getBoxesForSelection(
        TextSelection(
          baseOffset: partialStartOffset,
          extentOffset: partialStartOffset + startsInsideGrapheme.length,
        ),
      ),
      isNotEmpty,
    );
    final targetStartGraphemeOffset = content.indexOf(
      startGrapheme,
      content.indexOf(startGrapheme) + startGrapheme.length,
    );
    final startHighlight = await _textHighlightPixelColorAt(
      tester,
      targetStartGraphemeOffset,
      matchLength: startGrapheme.length,
    );
    _expectOtherHighlightColor(
      startHighlight,
      Theme.of(tester.element(searchField)).colorScheme,
    );

    await tester.enterText(searchField, 'cafe');
    await tester.pump();
    await _pumpUntilScheduledFramesIdle(tester);
    expect(find.text('1/2'), findsOneWidget);

    renderEditable = _contentRenderEditable(tester, editing: false);
    final partialEndOffset = content.lastIndexOf('cafe');
    expect(
      renderEditable.getBoxesForSelection(
        TextSelection(
          baseOffset: partialEndOffset,
          extentOffset: partialEndOffset + 'cafe'.length,
        ),
      ),
      isNotEmpty,
    );
    final accentGraphemeOffset =
        content.lastIndexOf(endGrapheme) + 'caf'.length;
    final accentBoxes = renderEditable.getBoxesForSelection(
      TextSelection(
        baseOffset: accentGraphemeOffset,
        extentOffset: accentGraphemeOffset + startGrapheme.length,
      ),
    );
    expect(accentBoxes, isNotEmpty);
    final painterFinder = _textHighlightPainterFinder();
    final painterRenderObject = tester.renderObject<RenderBox>(painterFinder);
    final accentPoint = painterRenderObject.globalToLocal(
      renderEditable.localToGlobal(
        Offset(accentBoxes.first.toRect().center.dx, accentBoxes.first.top + 1),
      ),
    );
    final endHighlight = await _textHighlightPixelColorAt(
      tester,
      partialEndOffset,
      matchLength: 'cafe'.length,
      paintLocalSamplePoint: accentPoint,
    );
    _expectOtherHighlightColor(
      endHighlight,
      Theme.of(tester.element(searchField)).colorScheme,
    );
  });

  testWidgets('emoji highlights remain visible at the viewport bottom', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final tempDir = Directory.systemTemp.createTempSync(
        'text_preview_emoji_highlight_viewport_edge_',
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
      });

      const query = '🧑‍🚀';
      final content = [
        ...List.generate(100, (index) => 'before line $index'),
        'first $query result',
        ...List.generate(100, (index) => 'between line $index'),
        'target $query result',
        ...List.generate(100, (index) => 'after line $index'),
      ].join('\n');
      final subtitle = File('${tempDir.path}/track01.srt')
        ..writeAsStringSync(content);

      await tester.pumpWidget(
        _testApp(subtitle.path, theme: ThemeData(platform: TargetPlatform.iOS)),
      );
      final searchAction = find.byKey(
        const ValueKey('text-preview-search-action'),
      );
      await _pumpUntilFound(tester, searchAction);
      await tester.tap(searchAction);
      await tester.pump();
      final searchField = find.byKey(
        const ValueKey('text-preview-search-field'),
      );
      await tester.enterText(searchField, query);
      await tester.pump();
      await _pumpUntilScheduledFramesIdle(tester);
      expect(find.text('1/2'), findsOneWidget);

      final renderEditable = _contentRenderEditable(tester, editing: false);
      final targetOffset = content.lastIndexOf(query);
      final caretRect = renderEditable.getLocalRectForCaret(
        TextPosition(offset: targetOffset),
      );
      final selectionBox = renderEditable
          .getBoxesForSelection(
            TextSelection(
              baseOffset: targetOffset,
              extentOffset: targetOffset + query.length,
            ),
          )
          .first
          .toRect();
      final scrollView = find.byType(SingleChildScrollView);
      final viewportRect = tester.getRect(scrollView);
      final controller = tester
          .widget<SingleChildScrollView>(scrollView)
          .controller!;
      final viewport = RenderAbstractViewport.of(renderEditable);
      final markerDocumentY = viewport
          .getOffsetToReveal(renderEditable, 0, rect: caretRect)
          .offset;
      final boxDocumentY =
          controller.offset +
          renderEditable.localToGlobal(selectionBox.topLeft).dy -
          viewportRect.top;
      final visibleBottom = boxDocumentY < markerDocumentY
          ? (boxDocumentY + markerDocumentY) / 2
          : boxDocumentY + 1;
      final targetScrollOffset = (visibleBottom - viewportRect.height)
          .clamp(0.0, controller.position.maxScrollExtent)
          .toDouble();
      controller.jumpTo(targetScrollOffset);
      await tester.pump();
      expect(boxDocumentY, lessThan(visibleBottom));
      expect(
        boxDocumentY + selectionBox.height,
        greaterThan(targetScrollOffset + viewportRect.height),
      );
      if (boxDocumentY < markerDocumentY) {
        expect(markerDocumentY, greaterThan(visibleBottom));
      }

      final color = await _textHighlightPixelColorAt(
        tester,
        targetOffset,
        matchLength: query.length,
      );
      final colorScheme = Theme.of(tester.element(searchField)).colorScheme;
      _expectOtherHighlightColor(color, colorScheme);
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });

  testWidgets('long matches stay highlighted across the viewport boundary', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_long_match_highlight_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    final query = 'x' * 600;
    final content = '$query\nseparator\n$query\ntrailing';
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);

    await tester.pumpWidget(_testApp(subtitle.path));
    final searchAction = find.byKey(
      const ValueKey('text-preview-search-action'),
    );
    await _pumpUntilFound(tester, searchAction);
    await tester.tap(searchAction);
    await tester.pump();
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    await tester.enterText(searchField, query);
    await tester.pump();
    await _pumpUntilScheduledFramesIdle(tester);
    expect(find.text('1/2'), findsOneWidget);

    final scrollView = find.byType(SingleChildScrollView);
    final controller = tester
        .widget<SingleChildScrollView>(scrollView)
        .controller!;
    final secondMatchOffset = content.lastIndexOf(query);
    final secondMatchDocumentY = _documentYForMatch(
      tester,
      secondMatchOffset,
      editing: false,
    );
    controller.jumpTo(
      (secondMatchDocumentY + 80)
          .clamp(0.0, controller.position.maxScrollExtent)
          .toDouble(),
    );
    await tester.pump();

    final visibleMatchOffset = secondMatchOffset + 150;
    final visibleMatchDocumentY = _documentYForMatch(
      tester,
      visibleMatchOffset,
      editing: false,
    );
    expect(visibleMatchDocumentY, greaterThanOrEqualTo(controller.offset));
    expect(
      visibleMatchDocumentY,
      lessThanOrEqualTo(
        controller.offset + controller.position.viewportDimension,
      ),
    );
    final rail = find.byKey(const ValueKey('text-preview-search-marker-rail'));
    final expectedColor = Theme.of(
      tester.element(rail),
    ).colorScheme.tertiaryContainer.withValues(alpha: 0.7);
    final highlightColor = await _textHighlightPixelColorAt(
      tester,
      visibleMatchOffset,
    );
    _expectHighlightAlpha(highlightColor, expectedColor);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visible highlights repaint while marker positions are pending', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_pending_marker_scroll_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    const rowCount = 500;
    final content = List.generate(
      rowCount,
      (index) => 'needle subtitle row $index',
    ).join('\n');
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);
    await StorageService.setString(
      SubtitleSearchQueryNotifier.preferenceKey,
      'needle',
    );

    await tester.pumpWidget(_testApp(subtitle.path));
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    await _pumpUntilFound(tester, searchField);
    expect(tester.binding.hasScheduledFrame, isTrue);

    final scrollView = find.byType(SingleChildScrollView);
    final controller = tester
        .widget<SingleChildScrollView>(scrollView)
        .controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);

    final lastMatchOffset = content.lastIndexOf('needle');
    final lastMatch = _contentRenderEditable(tester, editing: false)
        .getBoxesForSelection(
          TextSelection(
            baseOffset: lastMatchOffset,
            extentOffset: lastMatchOffset + 'needle'.length,
          ),
        )
        .first;
    final lastMatchGlobal = _contentRenderEditable(
      tester,
      editing: false,
    ).localToGlobal(lastMatch.toRect().center);
    expect(tester.getRect(scrollView).contains(lastMatchGlobal), isTrue);

    final rail = find.byKey(const ValueKey('text-preview-search-marker-rail'));
    final expectedColor = Theme.of(
      tester.element(rail),
    ).colorScheme.tertiaryContainer.withValues(alpha: 0.7);
    final highlightColor = await _textHighlightPixelColorAt(
      tester,
      lastMatchOffset,
    );
    _expectHighlightAlpha(highlightColor, expectedColor);
    await _pumpUntilScheduledFramesIdle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens saved search after text loads without taking focus', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_auto_search_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    final content = [
      'needle first',
      ...List.filled(24, 'filler'),
      'needle second',
    ].join('\n');
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);
    await StorageService.setString(
      SubtitleSearchQueryNotifier.preferenceKey,
      'needle',
    );

    await tester.pumpWidget(_testApp(subtitle.path));
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    await _pumpUntilFound(tester, searchField);

    expect(find.text('1/2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('text-preview-search-marker-rail')),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(searchField).focusNode!.hasFocus, isFalse);
  });

  testWidgets('empty remembered query does not open search automatically', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_empty_auto_search_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync('needle subtitle text');
    await tester.pumpWidget(_testApp(subtitle.path));
    final searchAction = find.byKey(
      const ValueKey('text-preview-search-action'),
    );
    await _pumpUntilFound(tester, searchAction);

    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    expect(searchField, findsNothing);
    expect(
      find.byKey(const ValueKey('text-preview-search-marker-rail')),
      findsNothing,
    );

    await tester.tap(searchAction);
    await tester.pump();
    await tester.enterText(searchField, 'needle');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('text-preview-search-clear')));
    await tester.pump();
    expect(find.text('0/0'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString(
        SubtitleSearchQueryNotifier.preferenceKey,
      ),
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('text-preview-search-close')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_testApp(subtitle.path));
    await _pumpUntilFound(tester, searchAction);
    expect(searchField, findsNothing);
  });

  testWidgets('disabled auto search keeps the last query for manual search', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_disabled_auto_search_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync('needle first\nneedle second');
    await StorageService.setString(
      SubtitleSearchQueryNotifier.preferenceKey,
      'needle',
    );
    await StorageService.setBool(
      AutoSearchLastSubtitleQueryNotifier.preferenceKey,
      false,
    );

    await tester.pumpWidget(_testApp(subtitle.path));
    final searchAction = find.byKey(
      const ValueKey('text-preview-search-action'),
    );
    await _pumpUntilFound(tester, searchAction);
    expect(
      find.byKey(const ValueKey('text-preview-search-field')),
      findsNothing,
    );

    await tester.tap(searchAction);
    await tester.pump();
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    expect(tester.widget<TextField>(searchField).controller!.text, 'needle');
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('saved search opens after a failed text load is retried', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_retry_auto_search_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    final subtitle = File('${tempDir.path}/track01.srt');
    await StorageService.setString(
      SubtitleSearchQueryNotifier.preferenceKey,
      'needle',
    );
    await tester.pumpWidget(_testApp(subtitle.path));

    final retry = find.text(
      S.of(tester.element(find.byType(TextPreviewScreen))).retry,
    );
    await _pumpUntilFound(tester, retry);
    subtitle.writeAsStringSync('needle after retry');

    await tester.tap(retry);
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    await _pumpUntilFound(tester, searchField);
    expect(find.text('1/1'), findsOneWidget);
  });

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

  testWidgets('dense markers restart on query changes and select both ends', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final tempDir = Directory.systemTemp.createTempSync(
      'text_preview_dense_markers_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
    });

    const rowCount = 500;
    final content = [
      'tail needle row 0',
      ...List.generate(rowCount - 2, (index) => 'needle row ${index + 1}'),
      'tail needle row ${rowCount - 1}',
    ].join('\n');
    final subtitle = File('${tempDir.path}/track01.srt')
      ..writeAsStringSync(content);
    await StorageService.setString(
      SubtitleSearchQueryNotifier.preferenceKey,
      'tail',
    );

    await tester.pumpWidget(_testApp(subtitle.path));
    final searchField = find.byKey(const ValueKey('text-preview-search-field'));
    await _pumpUntilFound(tester, searchField);
    await _pumpUntilScheduledFramesIdle(tester);
    expect(find.text('1/2'), findsOneWidget);

    await _tapMarkerForMatch(
      tester,
      content.lastIndexOf('tail'),
      editing: false,
    );
    await tester.pumpAndSettle();
    await _pumpUntilScheduledFramesIdle(tester);
    expect(find.text('2/2'), findsOneWidget);

    await tester.enterText(searchField, 'needle');
    await tester.pump();
    expect(find.text('1/$rowCount'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.binding.setSurfaceSize(const Size(420, 720));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);

    final railRect = tester.getRect(
      find.byKey(const ValueKey('text-preview-search-marker-rail')),
    );
    await tester.tapAt(Offset(railRect.center.dx, railRect.bottom - 2));
    expect(find.text('1/$rowCount'), findsOneWidget);

    await _pumpUntilScheduledFramesIdle(tester);
    final scrollView = find.byType(SingleChildScrollView);
    final controller = tester
        .widget<SingleChildScrollView>(scrollView)
        .controller!;
    await _tapMarkerForMatch(
      tester,
      content.lastIndexOf('needle'),
      editing: false,
    );
    await tester.pumpAndSettle();
    await _pumpUntilScheduledFramesIdle(tester);
    expect(find.text('$rowCount/$rowCount'), findsOneWidget);
    expect(
      controller.offset,
      greaterThan(controller.position.maxScrollExtent * 0.9),
    );

    await _tapMarkerForMatch(tester, content.indexOf('needle'), editing: false);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(find.text('1/$rowCount'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.tap(find.byKey(const ValueKey('text-preview-search-close')));
    await _pumpUntilScheduledFramesIdle(tester);
    expect(searchField, findsNothing);
    expect(
      find.byKey(const ValueKey('text-preview-search-marker-rail')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
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
    await _pumpUntilScheduledFramesIdle(tester);
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
      final restartedSearchField = find.byKey(
        const ValueKey('text-preview-search-field'),
      );
      expect(restartedSearchField, findsOneWidget);
      expect(
        tester.widget<TextField>(restartedSearchField).controller!.text,
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

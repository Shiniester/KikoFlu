import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/widgets/player/lyric_display_widget.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_glass_surface.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_lyrics_surface.dart';

void main() {
  final lyrics = List.generate(
    12,
    (index) => LyricLine(
      startTime: Duration(seconds: index),
      endTime: Duration(seconds: index + 1),
      text: index.isEven ? 'matching lyric $index' : 'lyric $index',
    ),
  );

  test('literal lyric matcher counts non-overlapping occurrences', () {
    final matches = findLyricSearchMatches([
      LyricLine(
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
        text: 'Echo echo ECHO',
      ),
      LyricLine(
        startTime: const Duration(seconds: 1),
        endTime: const Duration(seconds: 2),
        text: 'unrelated',
      ),
    ], 'echo');

    expect(matches, hasLength(3));
    expect(matches.map((match) => match.lineIndex), everyElement(0));
    expect(matches.map((match) => match.start), [0, 5, 10]);
  });

  testWidgets('active lyric is bold white and tapping seeks then centers', (
    tester,
  ) async {
    Duration? requested;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          positionProvider.overrideWith(
            (ref) => Stream.value(const Duration(seconds: 2)),
          ),
          lyricControllerProvider.overrideWith(
            (ref) =>
                LyricController(ref, initialState: LyricState(lyrics: lyrics)),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: FullLyricDisplay(
              isPortrait: true,
              onSeekRequested: (value) => requested = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final active = tester.widget<Text>(find.text('matching lyric 2'));
    expect(active.style?.fontWeight, FontWeight.w700);
    expect(active.style?.color?.a, 1);
    final inactive = tester.widget<Text>(find.text('lyric 3'));
    expect(inactive.style?.color?.a, lessThan(0.4));

    await tester.tap(find.text('lyric 5'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(requested, const Duration(seconds: 5));
    final center = tester.getCenter(find.text('lyric 5'));
    expect((center.dy - 350).abs(), lessThan(120));
  });

  testWidgets(
    'activating lyric page snaps to playback line without animation',
    (tester) async {
      final longLyrics = List.generate(
        48,
        (index) => LyricLine(
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: 'long lyric $index',
        ),
      );
      var active = false;
      late StateSetter updateActive;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            positionProvider.overrideWith(
              (ref) => Stream.value(const Duration(seconds: 30)),
            ),
            lyricControllerProvider.overrideWith(
              (ref) => LyricController(
                ref,
                initialState: LyricState(lyrics: longLyrics),
              ),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  updateActive = setState;
                  return FullLyricDisplay(
                    isPortrait: true,
                    suspendAutoScroll: !active,
                    snapToCurrentOnFirstLayout: true,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(FullLyricDisplay),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scrollable.position.pixels, 0);

      updateActive(() => active = true);
      await tester.pump();
      await tester.pump();
      final snappedOffset = scrollable.position.pixels;
      expect(snappedOffset, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 180));
      expect(scrollable.position.pixels, closeTo(snappedOffset, 0.1));
    },
  );

  testWidgets('lyric search counts words, selects one and centers its line', (
    tester,
  ) async {
    final searchLyrics = List.generate(
      42,
      (index) => LyricLine(
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: switch (index) {
          0 => '我看见我',
          30 => '远处还有我',
          _ => 'unmatched lyric $index',
        },
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          lyricControllerProvider.overrideWith(
            (ref) => LyricController(
              ref,
              initialState: LyricState(lyrics: searchLyrics),
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: PlayerLyricsSurface(
              isWide: false,
              onFullscreen: () {},
              translateButton: const IconButton(
                onPressed: null,
                icon: Icon(Icons.translate),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('lyric-edge-fade-mask')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
    await tester.pumpAndSettle();
    final searchGlass = find.byType(PlayerTransientGlassSurface);
    expect(searchGlass, findsOneWidget);
    expect(
      find.descendant(of: searchGlass, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('lyric-search-field')),
      '我',
    );
    await tester.pumpAndSettle();

    expect(find.text('1/3'), findsOneWidget);
    final colors = Theme.of(
      tester.element(find.byType(PlayerLyricsSurface)),
    ).colorScheme;
    RichText highlightedLine(String text) => tester.widget<RichText>(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == text,
      ),
    );
    List<TextSpan> hitsIn(String text) => _flattenTextSpans(
      highlightedLine(text).text,
    ).where((span) => span.text == '我').toList(growable: false);

    var hits = hitsIn('我看见我');
    expect(hits, hasLength(2));
    expect(hits.first.style?.backgroundColor, colors.primary);
    expect(hits.first.style?.color, colors.onPrimary);
    expect(hits.last.style?.backgroundColor, isNull);
    expect(hits.last.style?.color, colors.primary);

    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    hits = hitsIn('我看见我');
    expect(hits.first.style?.backgroundColor, isNull);
    expect(hits.last.style?.backgroundColor, colors.primary);

    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    final viewport = tester.getRect(
      find.byKey(const ValueKey('lyric-keyboard-safe-viewport')),
    );
    final selectedLine = tester.getRect(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == '远处还有我',
      ),
    );
    expect((selectedLine.center.dy - viewport.center.dy).abs(), lessThan(36));
    final farHit = hitsIn('远处还有我').single;
    expect(farHit.style?.backgroundColor, colors.primary);

    await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyric-search-field')), findsNothing);
  });
}

Iterable<TextSpan> _flattenTextSpans(InlineSpan span) sync* {
  if (span is! TextSpan) return;
  yield span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    yield* _flattenTextSpans(child);
  }
}

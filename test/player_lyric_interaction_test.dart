import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/widgets/player/lyric_display_widget.dart';
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

  testWidgets('lyric search reports matches and navigates them', (
    tester,
  ) async {
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
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('lyric-search-field')),
      'matching',
    );
    await tester.pumpAndSettle();

    expect(find.text('1/6'), findsOneWidget);
    final primary = Theme.of(
      tester.element(find.byType(PlayerLyricsSurface)),
    ).colorScheme.primary;
    final highlighted = tester.widget<RichText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText() == 'matching lyric 0',
      ),
    );
    final highlightedSpans = _flattenTextSpans(highlighted.text);
    expect(
      highlightedSpans.any((span) => span.style?.color == primary),
      isTrue,
    );
    await tester.tap(find.byTooltip('Next'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2/6'), findsOneWidget);

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

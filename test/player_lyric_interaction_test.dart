import 'dart:async';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
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

  testWidgets('active lyric is bold white and tapping seeks to playback line', (
    tester,
  ) async {
    Duration? requested;
    final positions = StreamController<Duration>();
    addTearDown(positions.close);
    positions.add(const Duration(seconds: 2));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          positionProvider.overrideWith((ref) => positions.stream),
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
              onSeekRequested: (value) {
                requested = value;
                positions.add(value);
              },
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
    expect(
      tester.getCenter(find.text('matching lyric 4')).dy -
          tester.getCenter(find.text('lyric 3')).dy,
      closeTo(44, 0.01),
    );

    await tester.tap(find.text('lyric 5'));
    await tester.pumpAndSettle();
    expect(requested, const Duration(seconds: 5));
    _expectLineAtPlaybackAnchor(tester, find.text('lyric 5'));
    final settledCenter = tester.getCenter(find.text('lyric 5')).dy;

    await tester.pump(const Duration(milliseconds: 2500));
    expect(
      tester.getCenter(find.text('lyric 5')).dy,
      closeTo(settledCenter, 0.1),
    );

    positions.add(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    _expectLineAtPlaybackAnchor(tester, find.text('matching lyric 6'));

    positions.add(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    await tester.tap(find.text('lyric 3'));
    await tester.pumpAndSettle();
    expect(requested, const Duration(seconds: 3));
    _expectLineAtPlaybackAnchor(tester, find.text('lyric 3'));
    final upperSettledCenter = tester.getCenter(find.text('lyric 3')).dy;
    await tester.pump(const Duration(milliseconds: 2500));
    expect(
      tester.getCenter(find.text('lyric 3')).dy,
      closeTo(upperSettledCenter, 0.1),
    );
  });

  testWidgets('double tapping a lyric toggles without seeking', (tester) async {
    var seekCount = 0;
    var toggleCount = 0;
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
              onSeekRequested: (_) => seekCount++,
              onLineDoubleTap: () => toggleCount++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final line = find.text('matching lyric 2');
    await tester.tap(line);
    await tester.pump(const Duration(milliseconds: 400));
    expect(seekCount, 1);
    expect(toggleCount, 0);

    seekCount = 0;
    await tester.tap(line);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(line);
    await tester.pump(const Duration(milliseconds: 400));
    expect(seekCount, 0);
    expect(toggleCount, 1);
    expect(
      find.byKey(const ValueKey('full-lyric-tap-feedback-2')),
      findsNothing,
    );
  });

  testWidgets(
    'enabled full lyric taps fade feedback while keeping seek and toggle exclusive',
    (tester) async {
      Duration? requested;
      var toggleCount = 0;
      final positions = StreamController<Duration>();
      addTearDown(positions.close);
      positions.add(const Duration(seconds: 2));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            positionProvider.overrideWith((ref) => positions.stream),
            lyricControllerProvider.overrideWith(
              (ref) => LyricController(
                ref,
                initialState: LyricState(lyrics: lyrics),
              ),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: FullLyricDisplay(
                isPortrait: true,
                enableLineTapFeedback: true,
                onSeekRequested: (value) {
                  requested = value;
                  positions.add(value);
                },
                onLineDoubleTap: () => toggleCount++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final line = find.text('matching lyric 2');
      await tester.tap(line);
      await tester.pump();
      expect(requested, isNull);
      expect(toggleCount, 0);
      expect(
        _tapFeedbackAlpha(tester, 'full-lyric-tap-feedback-2'),
        greaterThan(0),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('full-lyric-tap-feedback-2')),
          matching: line,
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 79));
      expect(
        _tapFeedbackAlpha(tester, 'full-lyric-tap-feedback-2'),
        closeTo(0.10, 0.001),
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        _tapFeedbackAlpha(tester, 'full-lyric-tap-feedback-2'),
        closeTo(0.10, 0.001),
      );
      await tester.pump(const Duration(milliseconds: 101));
      expect(requested, const Duration(seconds: 2));
      expect(toggleCount, 0);
      final inkWell = tester.widget<InkWell>(
        find.ancestor(of: line, matching: find.byType(InkWell)),
      );
      expect(inkWell.splashFactory, NoSplash.splashFactory);
      expect(
        find.ancestor(
          of: line,
          matching: find.byKey(const ValueKey('full-lyric-tap-feedback-2')),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 199));
      expect(
        _tapFeedbackAlpha(tester, 'full-lyric-tap-feedback-2'),
        greaterThan(0),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _tapFeedbackAlpha(tester, 'full-lyric-tap-feedback-2'),
        closeTo(0, 0.001),
      );

      requested = null;
      await tester.tap(line);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(line);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(requested, isNull);
      expect(toggleCount, 1);
      expect(
        _tapFeedbackAlpha(tester, 'full-lyric-tap-feedback-2'),
        greaterThan(0),
      );
    },
  );

  testWidgets(
    'lyric feedback surfaces follow full and compact rows during scroll',
    (tester) async {
      final positions = StreamController<Duration>();
      addTearDown(positions.close);
      positions.add(const Duration(seconds: 2));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            positionProvider.overrideWith((ref) => positions.stream),
            lyricControllerProvider.overrideWith(
              (ref) => LyricController(
                ref,
                initialState: LyricState(lyrics: lyrics),
              ),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: FullLyricDisplay(
                enableLineTapFeedback: true,
                onSeekRequested: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final lowerLine = find.text('matching lyric 4');
      await tester.tap(lowerLine);
      await tester.pump(const Duration(milliseconds: 320));
      await _expectFeedbackTravelTracksLine(
        tester,
        line: lowerLine,
        feedback: const ValueKey('full-lyric-tap-feedback-4'),
        movesUp: true,
      );
      await tester.pump(const Duration(milliseconds: 400));

      positions.add(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      final upperLine = find.text('lyric 3');
      await tester.tap(upperLine);
      await tester.pump(const Duration(milliseconds: 320));
      await _expectFeedbackTravelTracksLine(
        tester,
        line: upperLine,
        feedback: const ValueKey('full-lyric-tap-feedback-3'),
        movesUp: false,
      );
    },
  );

  testWidgets('compact feedback surface follows both lyric scroll directions', (
    tester,
  ) async {
    final positions = StreamController<Duration>();
    addTearDown(positions.close);
    positions.add(const Duration(seconds: 2));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          positionProvider.overrideWith((ref) => positions.stream),
          lyricControllerProvider.overrideWith(
            (ref) =>
                LyricController(ref, initialState: LyricState(lyrics: lyrics)),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: Center(
              child: ThreeLineLyricDisplay(
                lineCount: 5,
                enableLineTapFeedback: true,
                onSeekRequested: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final lowerLine = find.byKey(const ValueKey('compact-lyric-line-4'));
    await tester.tap(lowerLine);
    await tester.pump(const Duration(milliseconds: 320));
    await _expectFeedbackTravelTracksLine(
      tester,
      line: lowerLine,
      feedback: const ValueKey('compact-lyric-tap-feedback-4'),
      movesUp: true,
    );
    await tester.pump(const Duration(milliseconds: 400));

    positions.add(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    final upperLine = find.byKey(const ValueKey('compact-lyric-line-3'));
    await tester.tap(upperLine);
    await tester.pump(const Duration(milliseconds: 320));
    await _expectFeedbackTravelTracksLine(
      tester,
      line: upperLine,
      feedback: const ValueKey('compact-lyric-tap-feedback-3'),
      movesUp: false,
    );
  });

  testWidgets('reduced-motion lyric feedback stays static for 300ms', (
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
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: FullLyricDisplay(
              enableLineTapFeedback: true,
              onSeekRequested: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('lyric 5'));
    await tester.pump();
    expect(
      _tapFeedbackAlpha(tester, 'full-lyric-tap-feedback-5'),
      closeTo(0.10, 0.001),
    );
    await tester.pump(const Duration(milliseconds: 299));
    expect(
      _tapFeedbackAlpha(tester, 'full-lyric-tap-feedback-5'),
      closeTo(0.10, 0.001),
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      _tapFeedbackAlpha(tester, 'full-lyric-tap-feedback-5'),
      closeTo(0, 0.001),
    );
  });

  testWidgets(
    'first and last lyrics use the playback line without extra edge travel',
    (tester) async {
      final edgeLyrics = List.generate(
        20,
        (index) => LyricLine(
          startTime: Duration(seconds: index + 5),
          endTime: Duration(seconds: index + 6),
          text: 'edge lyric $index',
        ),
      );
      final positions = StreamController<Duration>();
      addTearDown(positions.close);
      positions.add(Duration.zero);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            positionProvider.overrideWith((ref) => positions.stream),
            lyricControllerProvider.overrideWith(
              (ref) => LyricController(
                ref,
                initialState: LyricState(lyrics: edgeLyrics),
              ),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: const Scaffold(body: FullLyricDisplay(isPortrait: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final firstBefore = tester.getCenter(find.text('edge lyric 0'));
      _expectLineAtPlaybackAnchor(tester, find.text('edge lyric 0'));
      positions.add(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.text('edge lyric 0')).dy,
        closeTo(firstBefore.dy, 1.1),
      );

      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('full-lyric-list')),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
      _expectLineAtPlaybackAnchor(tester, find.text('edge lyric 19'));
      expect(
        scrollable.position.pixels,
        closeTo(scrollable.position.maxScrollExtent, 1.1),
      );
    },
  );

  testWidgets('full lyrics resume following two seconds after user browsing', (
    tester,
  ) async {
    final longLyrics = List.generate(
      48,
      (index) => LyricLine(
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: 'browse lyric $index',
      ),
    );
    final positions = StreamController<Duration>();
    addTearDown(positions.close);
    positions.add(const Duration(seconds: 20));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          positionProvider.overrideWith((ref) => positions.stream),
          lyricControllerProvider.overrideWith(
            (ref) => LyricController(
              ref,
              initialState: LyricState(lyrics: longLyrics),
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: const Scaffold(body: FullLyricDisplay(isPortrait: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = find.byKey(const ValueKey('full-lyric-list'));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)),
    );
    await tester.drag(list, const Offset(0, -180));
    await tester.pump();
    final browsedOffset = scrollable.position.pixels;

    positions.add(const Duration(seconds: 21));
    await tester.pump(const Duration(milliseconds: 1900));
    expect(scrollable.position.pixels, closeTo(browsedOffset, 0.1));

    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 320));
    _expectLineAtPlaybackAnchor(tester, find.text('browse lyric 21'));
  });

  testWidgets('compact lyric rows seek, fade edges, and resume following', (
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
            body: Center(
              child: ThreeLineLyricDisplay(
                lineCount: 5,
                onSeekRequested: (position) => requested = position,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('compact-lyric-edge-fade-mask')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('compact-lyric-tap-feedback-2')),
      findsNothing,
    );
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('compact-lyric-scroll-list')),
        matching: find.byType(Scrollable),
      ),
    );
    final followedOffset = scrollable.position.pixels;

    await tester.tap(find.byKey(const ValueKey('compact-lyric-line-3')));
    await tester.pump(const Duration(milliseconds: 320));
    expect(requested, const Duration(seconds: 3));

    requested = null;
    await tester.drag(
      find.byKey(const ValueKey('compact-lyric-scroll-list')),
      const Offset(0, -190),
    );
    await tester.pump();
    expect(requested, isNull);
    expect(scrollable.position.pixels, greaterThan(followedOffset));

    await tester.tap(find.byKey(const ValueKey('compact-lyric-line-11')));
    await tester.pump(const Duration(milliseconds: 320));
    expect(requested, const Duration(seconds: 11));
    expect(scrollable.position.pixels, greaterThan(followedOffset));

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 320));
    expect(scrollable.position.pixels, closeTo(followedOffset, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'five-line lyrics show feedback and double tap toggles without seeking',
    (tester) async {
      var seekCount = 0;
      var toggleCount = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            positionProvider.overrideWith(
              (ref) => Stream.value(const Duration(seconds: 2)),
            ),
            lyricControllerProvider.overrideWith(
              (ref) => LyricController(
                ref,
                initialState: LyricState(lyrics: lyrics),
              ),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: Center(
                child: ThreeLineLyricDisplay(
                  lineCount: 5,
                  enableLineTapFeedback: true,
                  onSeekRequested: (_) => seekCount++,
                  onLineDoubleTap: () => toggleCount++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      const firstFeedbackKey = 'compact-lyric-tap-feedback-2';
      final firstLine = find.byKey(const ValueKey('compact-lyric-line-2'));
      await tester.tap(firstLine);
      await tester.pump();
      expect(_tapFeedbackAlpha(tester, firstFeedbackKey), greaterThan(0));
      expect(seekCount, 0);
      expect(toggleCount, 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(seekCount, 1);
      expect(toggleCount, 0);
      expect(_tapFeedbackAlpha(tester, firstFeedbackKey), greaterThan(0));
      expect(
        tester.getRect(find.byKey(const ValueKey(firstFeedbackKey))),
        tester.getRect(firstLine),
      );

      seekCount = 0;
      final secondLine = find.byKey(const ValueKey('compact-lyric-line-3'));
      final firstDoubleTap = await tester.startGesture(
        tester.getCenter(secondLine),
      );
      await firstDoubleTap.up();
      await tester.pump();
      expect(
        _tapFeedbackAlpha(tester, 'compact-lyric-tap-feedback-3'),
        greaterThan(0),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('compact-lyric-tap-feedback-3')),
          matching: secondLine,
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 40));
      final alphaBeforeSecondTap = _tapFeedbackAlpha(
        tester,
        'compact-lyric-tap-feedback-3',
      );
      expect(alphaBeforeSecondTap, greaterThan(0.08));
      final secondDoubleTap = await tester.startGesture(
        tester.getCenter(secondLine),
      );
      await secondDoubleTap.up();
      await tester.pump();
      expect(seekCount, 0);
      expect(toggleCount, 1);
      expect(_tapFeedbackAlpha(tester, firstFeedbackKey), 0);
      expect(
        _tapFeedbackAlpha(tester, 'compact-lyric-tap-feedback-3'),
        closeTo(alphaBeforeSecondTap, 0.001),
      );
      await tester.pump(const Duration(milliseconds: 470));
      expect(
        _tapFeedbackAlpha(tester, 'compact-lyric-tap-feedback-3'),
        closeTo(0, 0.001),
      );
    },
  );

  testWidgets('drag, cancel, and long press do not show lyric feedback', (
    tester,
  ) async {
    var seekCount = 0;
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
              enableLineTapFeedback: true,
              onSeekRequested: (_) => seekCount++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final line = find.text('matching lyric 2');
    const feedback = ValueKey<String>('full-lyric-tap-feedback-2');

    var gesture = await tester.startGesture(tester.getCenter(line));
    await gesture.moveBy(const Offset(24, 0));
    await gesture.up();
    await tester.pump();
    expect(_tapFeedbackAlpha(tester, feedback.value), 0);
    expect(seekCount, 0);

    gesture = await tester.startGesture(tester.getCenter(line));
    await gesture.cancel();
    await tester.pump();
    expect(_tapFeedbackAlpha(tester, feedback.value), 0);

    gesture = await tester.startGesture(tester.getCenter(line));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await gesture.up();
    await tester.pump();
    expect(_tapFeedbackAlpha(tester, feedback.value), 0);
  });

  testWidgets(
    'inactive lyric page follows before activation and stays stable',
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
      final positions = StreamController<Duration>();
      addTearDown(positions.close);
      positions.add(const Duration(seconds: 5));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            positionProvider.overrideWith((ref) => positions.stream),
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
                    isActive: active,
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
      final initialOffset = scrollable.position.pixels;

      positions.add(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      final hiddenOffset = scrollable.position.pixels;
      expect(hiddenOffset, greaterThan(initialOffset));
      _expectLineAtPlaybackAnchor(tester, find.text('long lyric 30'));

      updateActive(() => active = true);
      await tester.pump();
      await tester.pump();
      expect(scrollable.position.pixels, closeTo(hiddenOffset, 0.1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(scrollable.position.pixels, closeTo(hiddenOffset, 0.1));
    },
  );

  testWidgets('lyric search counts words and selects on the playback line', (
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
            resizeToAvoidBottomInset: false,
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

    expect(
      tester
          .widget<FullLyricDisplay>(find.byType(FullLyricDisplay))
          .enableLineTapFeedback,
      isTrue,
    );
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
    final playbackAnchor = viewport.top + viewport.height * 0.4;
    expect((selectedLine.center.dy - playbackAnchor).abs(), lessThan(36));
    final farHit = hitsIn('远处还有我').single;
    expect(farHit.style?.backgroundColor, colors.primary);

    await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyric-search-field')), findsNothing);
  });

  testWidgets(
    'lyric search centers exact glyphs across five hundred wrapped lines',
    (tester) async {
      const middleIndex = 267;
      const lastIndex = 519;
      final middleText =
          '${List.filled(14, 'a deliberately wrapped lyric prefix').join(' ')} '
          'needle';
      final searchLyrics = List.generate(
        lastIndex + 1,
        (index) => LyricLine(
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: switch (index) {
            0 => 'needle at the beginning',
            middleIndex => middleText,
            lastIndex => 'the final needle',
            _ => 'ordinary lyric line number $index',
          },
        ),
      );
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.35)),
              child: child!,
            ),
            home: Scaffold(
              body: PlayerLyricsSurface(
                isWide: false,
                actionWidth: 306,
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
      await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('lyric-search-field')),
        'needle',
      );
      await tester.pumpAndSettle();

      expect(find.text('1/3'), findsOneWidget);
      _expectMatchAtPlaybackAnchor(tester, 'needle at the beginning', 0, 6);

      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      _expectMatchAtPlaybackAnchor(
        tester,
        middleText,
        middleText.lastIndexOf('needle'),
        middleText.length,
      );

      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget);
      _expectMatchAtPlaybackAnchor(
        tester,
        'the final needle',
        'the final '.length,
        'the final needle'.length,
      );

      addTearDown(tester.view.resetViewInsets);
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pump();
      await tester.tap(find.byTooltip('Previous'));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      _expectMatchAtPlaybackAnchor(
        tester,
        middleText,
        middleText.lastIndexOf('needle'),
        middleText.length,
      );

      await tester.tap(find.byTooltip('Next'));
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);
      _expectMatchAtPlaybackAnchor(tester, 'needle at the beginning', 0, 6);
    },
  );

  testWidgets('matches on different wrapped rows center independently', (
    tester,
  ) async {
    final wrapped =
        'needle ${List.filled(24, 'spaced wrapping words').join(' ')} needle';
    final wrappedLyrics = [
      LyricLine(
        startTime: Duration.zero,
        endTime: const Duration(seconds: 1),
        text: wrapped,
      ),
    ];
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
          lyricControllerProvider.overrideWith(
            (ref) => LyricController(
              ref,
              initialState: LyricState(lyrics: wrappedLyrics),
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: PlayerLyricsSurface(
              isWide: false,
              actionWidth: 306,
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
    await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('lyric-search-field')),
      'needle',
    );
    await tester.pumpAndSettle();
    _expectMatchAtPlaybackAnchor(tester, wrapped, 0, 'needle'.length);

    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    _expectMatchAtPlaybackAnchor(
      tester,
      wrapped,
      wrapped.lastIndexOf('needle'),
      wrapped.length,
    );
  });

  testWidgets('opening and closing search preserves the lyric scroll anchor', (
    tester,
  ) async {
    final stableLyrics = List.generate(
      80,
      (index) => LyricLine(
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: 'stable lyric line $index',
      ),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          positionProvider.overrideWith(
            (ref) => Stream.value(const Duration(seconds: 30)),
          ),
          lyricControllerProvider.overrideWith(
            (ref) => LyricController(
              ref,
              initialState: LyricState(lyrics: stableLyrics),
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: PlayerLyricsSurface(
              isWide: false,
              actionWidth: 306,
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

    final list = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('full-lyric-list')),
        matching: find.byType(Scrollable),
      ),
    );
    final anchor = find.text('stable lyric line 30');
    final initialOffset = list.position.pixels;
    final initialTop = tester.getTopLeft(anchor).dy;

    await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
    for (final elapsed in const [
      Duration(milliseconds: 1),
      Duration(milliseconds: 60),
      Duration(milliseconds: 100),
    ]) {
      await tester.pump(elapsed);
      expect(list.position.pixels, closeTo(initialOffset, 0.01));
      expect(tester.getTopLeft(anchor).dy, closeTo(initialTop, 1));
    }
    await tester.pumpAndSettle();
    expect(list.position.pixels, closeTo(initialOffset, 0.01));

    addTearDown(tester.view.resetViewInsets);
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pump();
    expect(list.position.pixels, closeTo(initialOffset, 0.01));
    expect(tester.getTopLeft(anchor).dy, closeTo(initialTop, 1));

    await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
    for (final elapsed in const [
      Duration(milliseconds: 1),
      Duration(milliseconds: 50),
      Duration(milliseconds: 100),
    ]) {
      await tester.pump(elapsed);
      expect(list.position.pixels, closeTo(initialOffset, 0.01));
      expect(tester.getTopLeft(anchor).dy, closeTo(initialTop, 1));
    }
    for (final inset in const [160.0, 80.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 30));
      expect(list.position.pixels, closeTo(initialOffset, 0.01));
      expect(tester.getTopLeft(anchor).dy, closeTo(initialTop, 1));
    }
    await tester.pumpAndSettle();
    expect(list.position.pixels, closeTo(initialOffset, 0.01));
    expect(tester.getTopLeft(anchor).dy, closeTo(initialTop, 1));
  });
}

void _expectMatchAtPlaybackAnchor(
  WidgetTester tester,
  String line,
  int start,
  int end,
) {
  final finder = find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText() == line,
  );
  expect(finder, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  expect(boxes, isNotEmpty);
  final top = boxes.map((box) => box.top).reduce(mathMin);
  final bottom = boxes.map((box) => box.bottom).reduce(mathMax);
  final left = boxes.map((box) => box.left).reduce(mathMin);
  final right = boxes.map((box) => box.right).reduce(mathMax);
  final glyphCenter = paragraph.localToGlobal(
    Offset((left + right) / 2, (top + bottom) / 2),
  );
  final viewport = tester.getRect(
    find.byKey(const ValueKey('lyric-keyboard-safe-viewport')),
  );
  final playbackAnchor = viewport.top + viewport.height * 0.4;
  expect((glyphCenter.dy - playbackAnchor).abs(), lessThanOrEqualTo(2.1));
}

void _expectLineAtPlaybackAnchor(WidgetTester tester, Finder line) {
  final viewport = tester.getRect(find.byType(FullLyricDisplay));
  final playbackAnchor = viewport.top + viewport.height * 0.4;
  expect(
    (tester.getCenter(line).dy - playbackAnchor).abs(),
    lessThanOrEqualTo(2.1),
  );
}

double _tapFeedbackAlpha(WidgetTester tester, String keyValue) {
  final surface = tester.widget<DecoratedBox>(
    find.byKey(ValueKey<String>(keyValue)),
  );
  final decoration = surface.decoration;
  return decoration is BoxDecoration ? decoration.color?.a ?? 0 : 0;
}

Future<void> _expectFeedbackTravelTracksLine(
  WidgetTester tester, {
  required Finder line,
  required Key feedback,
  required bool movesUp,
}) async {
  final feedbackFinder = find.byKey(feedback);
  final initialDelta =
      tester.getRect(feedbackFinder).center.dy - tester.getRect(line).center.dy;
  final centers = <double>[tester.getRect(line).center.dy];
  for (final step in const [
    Duration(milliseconds: 20),
    Duration(milliseconds: 40),
    Duration(milliseconds: 40),
    Duration(milliseconds: 40),
    Duration(milliseconds: 40),
    Duration(milliseconds: 40),
  ]) {
    await tester.pump(step);
    final feedbackCenter = tester.getRect(feedbackFinder).center.dy;
    final lineCenter = tester.getRect(line).center.dy;
    expect(feedbackCenter - lineCenter, closeTo(initialDelta, 0.5));
    centers.add(lineCenter);
  }

  final totalTravel = centers.last - centers.first;
  expect(totalTravel, movesUp ? lessThan(-0.5) : greaterThan(0.5));
  for (var index = 1; index < centers.length; index++) {
    if (movesUp) {
      expect(centers[index], lessThanOrEqualTo(centers[index - 1] + 0.5));
    } else {
      expect(centers[index], greaterThanOrEqualTo(centers[index - 1] - 0.5));
    }
  }
}

double mathMin(double left, double right) => left < right ? left : right;

double mathMax(double left, double right) => left > right ? left : right;

Iterable<TextSpan> _flattenTextSpans(InlineSpan span) sync* {
  if (span is! TextSpan) return;
  yield span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    yield* _flattenTextSpans(child);
  }
}

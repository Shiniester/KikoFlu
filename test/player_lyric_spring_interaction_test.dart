import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/player_lyric_style_provider.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/player/lyric_display_widget.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_lyrics_surface.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_seek_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets(
    'dense continuous progress keeps a cascade across several lines',
    (tester) async {
      final playback = await _mount(tester);
      final first = tester.getCenter(find.text('spring 4')).dy;
      final second = tester.getCenter(find.text('spring 5')).dy;
      playback.positions.add(const Duration(seconds: 3));
      await _frames(tester, 24);
      final firstTravel = tester.getCenter(find.text('spring 4')).dy - first;
      final secondTravel = tester.getCenter(find.text('spring 5')).dy - second;
      expect((firstTravel - secondTravel).abs(), greaterThan(1));
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 3');
    },
  );

  for (final interrupted in [false, true]) {
    testWidgets(
      'every retarget frame preserves adjacent text with interrupted=$interrupted',
      (tester) async {
        final playback = await _mount(tester);
        if (interrupted) {
          playback.positions.add(const Duration(seconds: 1));
          await _frames(tester, 20);
        }
        final adjacent = find.text('spring 4');
        final before = tester.getCenter(adjacent).dy;
        playback.positions.add(Duration(seconds: interrupted ? 2 : 1));
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump();
          expect(
            tester.getCenter(adjacent).dy,
            closeTo(before, 0.5),
            reason: 'retarget frame $frame must not expose the logical scroll',
          );
        }
        await _frames(tester, 20);
        expect(tester.getCenter(adjacent).dy, isNot(closeTo(before, 0.5)));
        await tester.pumpAndSettle();
        _expectAnchor(tester, 'spring ${interrupted ? 2 : 1}');
      },
    );
  }

  testWidgets('same-line preview stops pending cascade immediately', (
    tester,
  ) async {
    final playback = await _mount(tester);
    playback.positions.add(const Duration(seconds: 1));
    await _frames(tester, 12);
    playback.preview.value = (
      isSeekingManually: true,
      seekValue: 1.5,
      position: const Duration(milliseconds: 1500),
    );
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump();
    }
    _expectAnchor(tester, 'spring 1');
    final center = tester.getCenter(find.text('spring 4'));
    await _frames(tester, 30);
    expect(tester.getCenter(find.text('spring 4')), center);
    expect(tester.binding.hasScheduledFrame, isFalse);
    playback.preview.value = (
      isSeekingManually: true,
      seekValue: 1.8,
      position: const Duration(milliseconds: 1800),
    );
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 1');
    expect(tester.getCenter(find.text('spring 4')), center);
    playback.preview.value = null;
    await tester.pumpAndSettle();
    playback.positions.add(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 2');
  });

  testWidgets(
    'leaving preview directly follows newer playback without a cascade',
    (tester) async {
      final playback = await _mount(tester);
      playback.positions.add(const Duration(seconds: 1));
      await _frames(tester, 12);
      playback.preview.value = (
        isSeekingManually: true,
        seekValue: 1.5,
        position: const Duration(milliseconds: 1500),
      );
      await tester.pumpAndSettle();
      playback.positions.add(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 1');
      playback.preview.value = null;
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump();
      }
      _expectAnchor(tester, 'spring 2');
      final adjacent = tester.getCenter(find.text('spring 4'));
      await _frames(tester, 30);
      expect(tester.getCenter(find.text('spring 4')), adjacent);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'leaving a very tall preview locates the uncached adjacent line',
    (tester) async {
      final playback = await _mount(
        tester,
        position: const Duration(seconds: 1),
        lyrics: List.generate(
          3,
          (index) => LyricLine(
            startTime: Duration(seconds: index),
            endTime: Duration(seconds: index + 1),
            text: index == 1
                ? List.filled(180, 'a very tall wrapped subtitle').join(' ')
                : 'spring $index',
          ),
        ),
      );
      playback.preview.value = (
        isSeekingManually: true,
        seekValue: 1.5,
        position: const Duration(milliseconds: 1500),
      );
      await tester.pumpAndSettle();
      playback.positions.add(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('spring 2'), findsNothing);
      playback.preview.value = null;
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 2');
      final center = tester.getCenter(find.text('spring 2'));
      await _frames(tester, 30);
      expect(tester.getCenter(find.text('spring 2')), center);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  for (final input in ['drag', 'wheel', 'trackpad']) {
    testWidgets(
      '$input browsing cancels moving lyrics and resumes after three seconds',
      (tester) async {
        final playback = await _mount(
          tester,
          position: const Duration(seconds: 20),
        );
        playback.positions.add(const Duration(seconds: 21));
        await _frames(tester, 12);
        final list = find.byKey(const ValueKey('full-lyric-list'));
        if (input == 'drag') {
          await tester.drag(list, const Offset(0, -160));
        } else if (input == 'wheel') {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: tester.getCenter(list),
              scrollDelta: const Offset(0, 160),
            ),
          );
        } else {
          final gesture = await tester.createGesture(
            kind: PointerDeviceKind.trackpad,
          );
          await gesture.panZoomStart(tester.getCenter(list));
          await gesture.panZoomUpdate(
            tester.getCenter(list),
            pan: const Offset(0, -160),
          );
          await gesture.panZoomEnd();
        }
        await tester.pumpAndSettle();
        final browsed = tester.getCenter(find.text('spring 23')).dy;
        playback.positions.add(const Duration(seconds: 22));
        await tester.pump(const Duration(seconds: 1));
        expect(
          tester.getCenter(find.text('spring 23')).dy,
          closeTo(browsed, 0.1),
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        _expectAnchor(tester, 'spring 22');
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );
  }

  for (final input in ['wheel', 'trackpad']) {
    testWidgets('$input browsing takes over a started return', (tester) async {
      await _mount(tester, position: const Duration(seconds: 20));
      final list = find.byKey(const ValueKey('full-lyric-list'));
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      final line = find.text('spring 23');

      await tester.drag(list, const Offset(0, -160));
      await tester.pumpAndSettle();
      final beforeReturn = position.pixels;
      await tester.pump(const Duration(seconds: 3));
      await _frames(tester, 8);
      expect((position.pixels - beforeReturn).abs(), greaterThan(0.1));

      final beforeBrowse = tester.getCenter(line).dy;
      final beforeBrowseOffset = position.pixels;
      if (input == 'wheel') {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(list),
            scrollDelta: const Offset(0, 160),
          ),
        );
      } else {
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );
        await gesture.panZoomStart(tester.getCenter(list));
        await gesture.panZoomUpdate(
          tester.getCenter(list),
          pan: const Offset(0, -160),
        );
        await gesture.panZoomEnd();
      }
      await tester.pump(const Duration(milliseconds: 16));
      final afterBrowseOffset = position.pixels;
      final afterBrowse = tester.getCenter(line).dy;
      final browseOffsetDelta = afterBrowseOffset - beforeBrowseOffset;
      expect(browseOffsetDelta.abs(), greaterThan(0.1));
      expect((afterBrowse - beforeBrowse) * browseOffsetDelta, lessThan(0));
      await tester.pumpAndSettle();

      final browsedCenter = tester.getCenter(line).dy;
      await tester.pump(const Duration(milliseconds: 2500));
      expect(tester.getCenter(line).dy, closeTo(browsedCenter, 0.5));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 20');
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets('a visible lyric follows wheel input during a browse return', (
    tester,
  ) async {
    await _mount(tester, position: const Duration(seconds: 20));
    final list = find.byKey(const ValueKey('full-lyric-list'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;

    await tester.drag(list, const Offset(0, -180));
    await tester.pumpAndSettle();
    final retainedLine = find.text('spring 26');
    expect(retainedLine, findsOneWidget);
    expect(tester.getRect(retainedLine).overlaps(tester.getRect(list)), isTrue);
    await tester.pump(const Duration(seconds: 3));
    await _frames(tester, 140);
    expect(retainedLine, findsOneWidget);
    expect(tester.getRect(retainedLine).overlaps(tester.getRect(list)), isTrue);

    final beforeOffset = position.pixels;
    final beforeY = tester.getCenter(retainedLine).dy;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, 60),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    final offsetDelta = position.pixels - beforeOffset;
    expect(offsetDelta.abs(), greaterThan(1));
    expect(
      tester.getCenter(retainedLine).dy,
      closeTo(beforeY - offsetDelta, 6),
    );
  });

  testWidgets(
    'a browse return follows a newer long line without another delay',
    (tester) async {
      final longLine =
          'spring 40 ${List.filled(28, 'wrapped subtitle words').join(' ')}';
      final playback = await _mount(
        tester,
        position: const Duration(seconds: 20),
        lyrics: List.generate(
          80,
          (index) => LyricLine(
            startTime: Duration(seconds: index),
            endTime: Duration(seconds: index + 1),
            text: index == 40 ? longLine : 'spring $index',
          ),
        ),
      );
      await tester.drag(
        find.byKey(const ValueKey('full-lyric-list')),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 180));
      final beforeRetarget = _lyricIndexAtPlaybackAnchor(tester);

      playback.positions.add(const Duration(seconds: 40));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      expect(_lyricIndexAtPlaybackAnchor(tester), greaterThan(beforeRetarget));
      await tester.pumpAndSettle();
      _expectAnchor(tester, longLine);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'browsing during a return takes control without jumping to its old end',
    (tester) async {
      await _mount(tester, position: const Duration(seconds: 20));
      final list = find.byKey(const ValueKey('full-lyric-list'));
      await tester.drag(list, const Offset(0, -180));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 160));

      final trackedIndex = _lyricIndexAtPlaybackAnchor(tester);
      final trackedLine = find.text('spring $trackedIndex');
      final beforeDrag = tester.getCenter(trackedLine).dy;
      await tester.drag(list, const Offset(0, -80));
      await tester.pump();
      final afterDrag = tester.getCenter(trackedLine).dy;
      expect(afterDrag, closeTo(beforeDrag - 80, 35));

      await tester.pumpAndSettle();
      final browsedCenter = tester.getCenter(trackedLine).dy;
      await tester.pump(const Duration(milliseconds: 2900));
      expect(tester.getCenter(trackedLine).dy, closeTo(browsedCenter, 0.5));

      await tester.pump(const Duration(milliseconds: 240));
      expect(
        tester.getCenter(trackedLine).dy,
        greaterThan(browsedCenter + 0.5),
      );
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 20');
    },
  );

  testWidgets('a remounted lyric list snaps to playback after browsing', (
    tester,
  ) async {
    final playback = await _mount(
      tester,
      position: const Duration(seconds: 20),
      display: (playback) => KeyedSubtree(
        key: ValueKey(playback.active.value),
        child: const FullLyricDisplay(
          key: PageStorageKey('player-full-lyrics-scroll'),
          isPortrait: true,
          showPlaybackLineControls: true,
          snapToCurrentOnFirstLayout: true,
        ),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('full-lyric-list')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 160));
    expect(_lyricIndexAtPlaybackAnchor(tester), isNot(20));

    playback.active.value = false;
    await tester.pump();
    await tester.pump();

    _expectAnchor(tester, 'spring 20');
  });

  for (final gesture in ['none', 'single', 'double', 'drag']) {
    testWidgets(
      'bouncy far return keeps delayed rows visible, gesture=$gesture',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final requested = <Duration>[];
        var toggleCount = 0;
        final playback = await _mount(
          tester,
          position: const Duration(seconds: 1),
          lyrics: List.generate(
            500,
            (index) => LyricLine(
              startTime: Duration(seconds: index),
              endTime: Duration(seconds: index + 1),
              text: 'spring $index',
            ),
          ),
          display: (_) => FullLyricDisplay(
            isPortrait: true,
            showPlaybackLineControls: true,
            enableLineTapFeedback: true,
            onSeekRequested: requested.add,
            onLineDoubleTap: () => toggleCount++,
          ),
        );
        await playback.container
            .read(playerLyricSettingsProvider.notifier)
            .updateSpringPreset(PlayerLyricSpringPreset.jello);
        await tester.pumpAndSettle();
        final list = find.byKey(const ValueKey('full-lyric-list'));
        final scrollable = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.text('spring 490'),
          900,
          scrollable: scrollable,
          maxScrolls: 40,
        );
        await tester.pumpAndSettle();
        final delayedIndex = _lyricIndexAtPlaybackAnchor(tester) - 2;
        final delayedLine = find.text('spring $delayedIndex');
        final initialY = tester.getCenter(delayedLine).dy;

        await tester.pump(const Duration(seconds: 3));
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(delayedLine, findsOneWidget);
          expect(tester.getCenter(delayedLine).dy, closeTo(initialY, 0.5));
        }
        if (gesture == 'drag') {
          final pointer = await tester.startGesture(
            tester.getCenter(delayedLine),
          );
          await pointer.moveBy(const Offset(0, -30));
          await tester.pump();
          await pointer.moveBy(const Offset(0, -50));
          await tester.pump();
          expect(tester.getCenter(delayedLine).dy, closeTo(initialY - 50, 25));
          await pointer.up();
          await tester.pump(const Duration(milliseconds: 50));
          expect(requested, isEmpty);
          expect(toggleCount, 0);
        } else if (gesture != 'none') {
          final center = tester.getCenter(delayedLine);
          await tester.tapAt(center);
          if (gesture == 'double') {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.tapAt(center);
          }
          await tester.pump(kDoubleTapTimeout);
          expect(
            requested,
            gesture == 'single' ? [Duration(seconds: delayedIndex)] : isEmpty,
          );
          expect(toggleCount, gesture == 'double' ? 1 : 0);
        } else {
          for (var frame = 0; frame < 30; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            _lyricIndexAtPlaybackAnchor(tester);
          }
          await tester.pumpAndSettle();
          _expectAnchor(tester, 'spring 1');
          expect(tester.binding.hasScheduledFrame, isFalse);
        }
        semantics.dispose();
      },
    );
  }

  testWidgets('a jello return follows a fling from its edge row', (
    tester,
  ) async {
    final playback = await _mount(
      tester,
      lyrics: List.generate(
        500,
        (index) => LyricLine(
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: 'spring $index',
        ),
      ),
    );
    await playback.container
        .read(playerLyricSettingsProvider.notifier)
        .updateSpringPreset(PlayerLyricSpringPreset.jello);
    await tester.pumpAndSettle();

    final list = find.byKey(const ValueKey('full-lyric-list'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    await tester.scrollUntilVisible(
      find.text('spring 490'),
      900,
      scrollable: scrollable,
      maxScrolls: 40,
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));

    var touchedLeadingEdge = false;
    var previousOffset = position.pixels;
    for (var frame = 0; frame < 360; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final offset = position.pixels;
      if (offset <= position.minScrollExtent + 0.5 &&
          previousOffset > offset + 0.1) {
        touchedLeadingEdge = true;
        break;
      }
      previousOffset = offset;
    }
    expect(touchedLeadingEdge, isTrue);

    final trackedIndex = _lyricIndexAtPlaybackAnchor(tester);
    final trackedLine = find.text('spring $trackedIndex');
    final beforeDragCenter = tester.getCenter(trackedLine).dy;
    final beforeDragOffset = position.pixels;
    final pointer = await tester.startGesture(tester.getCenter(trackedLine));
    await pointer.moveBy(
      const Offset(0, -30),
      timeStamp: const Duration(milliseconds: 16),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await pointer.moveBy(
      const Offset(0, -50),
      timeStamp: const Duration(milliseconds: 32),
    );
    await tester.pump(const Duration(milliseconds: 16));
    final afterDragOffset = position.pixels;
    final afterDragCenter = tester.getCenter(trackedLine).dy;
    expect(afterDragOffset, greaterThan(beforeDragOffset + 0.1));
    expect(afterDragCenter, lessThan(beforeDragCenter - 0.5));

    await pointer.up(timeStamp: const Duration(milliseconds: 48));
    await tester.pump();

    var previousBallisticOffset = position.pixels;
    var previousBallisticCenter = tester.getCenter(trackedLine).dy;
    var followedBallisticScroll = false;
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final offset = position.pixels;
      final center = tester.getCenter(trackedLine).dy;
      final offsetDelta = offset - previousBallisticOffset;
      if (offsetDelta.abs() > 0.1) {
        final centerDelta = center - previousBallisticCenter;
        expect(centerDelta * offsetDelta, lessThan(0));
        followedBallisticScroll = true;
        break;
      }
      previousBallisticOffset = offset;
      previousBallisticCenter = center;
    }
    expect(followedBallisticScroll, isTrue);
  });

  for (final reverse in [false, true]) {
    testWidgets(
      'a far browse return stays continuous and lazy with reverse=$reverse',
      (tester) async {
        final targetIndex = reverse ? 480 : 20;
        final browseIndex = reverse ? 20 : 480;
        await _mount(
          tester,
          position: Duration(seconds: targetIndex),
          lyrics: List.generate(
            500,
            (index) => LyricLine(
              startTime: Duration(seconds: index),
              endTime: Duration(seconds: index + 1),
              text: index % 80 == 40
                  ? 'spring $index ${List.filled(28, 'wrapped subtitle words').join(' ')}'
                  : 'spring $index',
            ),
          ),
        );
        final list = find.byKey(const ValueKey('full-lyric-list'));
        final scrollableFinder = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        final position = tester
            .state<ScrollableState>(scrollableFinder)
            .position;
        final startOffset = position.pixels;
        final viewportHeight = position.viewportDimension;

        await tester.scrollUntilVisible(
          find.text('spring $browseIndex'),
          reverse ? -900 : 900,
          scrollable: scrollableFinder,
          maxScrolls: 40,
        );
        await tester.pumpAndSettle();
        expect(
          (position.pixels - startOffset).abs(),
          greaterThan(viewportHeight * 10),
        );

        final browsedAnchorIndex = _lyricIndexAtPlaybackAnchor(tester);
        final browsedOffset = position.pixels;
        final renderedLyrics = find.descendant(
          of: list,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is RichText &&
                widget.text.toPlainText().startsWith('spring '),
          ),
        );
        expect(renderedLyrics.evaluate().length, lessThan(500));

        await tester.pump(const Duration(seconds: 3));
        expect(_lyricIndexAtPlaybackAnchor(tester), browsedAnchorIndex);
        final returnAnchorIndices = <int>[];
        final returnOffsets = <double>[];
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
          returnAnchorIndices.add(_lyricIndexAtPlaybackAnchor(tester));
          returnOffsets.add(position.pixels);
          expect(renderedLyrics.evaluate().length, lessThan(500));
        }
        expect(
          (returnOffsets.first - browsedOffset).abs(),
          lessThan((startOffset - browsedOffset).abs()),
        );
        if (reverse) {
          expect(returnOffsets.last, greaterThan(browsedOffset));
          expect(returnAnchorIndices.last, lessThan(480));
        } else {
          expect(returnOffsets.last, lessThan(browsedOffset));
          expect(returnAnchorIndices.last, greaterThan(20));
        }

        await tester.pumpAndSettle();
        _expectAnchor(tester, 'spring $targetIndex');
        expect(tester.takeException(), isNull);
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );
  }

  for (final hiddenBy in ['inactive', 'ticker mode', 'background']) {
    for (final duringReturn in [false, true]) {
      testWidgets(
        '$hiddenBy stops motion and resumes at the latest line duringReturn=$duringReturn',
        (tester) async {
          final playback = await _mount(
            tester,
            position: duringReturn
                ? const Duration(seconds: 20)
                : Duration.zero,
            lyrics: List.generate(
              500,
              (index) => LyricLine(
                startTime: Duration(seconds: index),
                endTime: Duration(seconds: index + 1),
                text: 'spring $index',
              ),
            ),
          );
          final list = find.byKey(const ValueKey('full-lyric-list'));
          if (duringReturn) {
            await tester.drag(list, const Offset(0, -180));
            await tester.pumpAndSettle();
            final browsedIndex = _lyricIndexAtPlaybackAnchor(tester);
            await tester.pump(const Duration(seconds: 3));
            await tester.pump(const Duration(milliseconds: 160));
            expect(_lyricIndexAtPlaybackAnchor(tester), isNot(browsedIndex));
          } else {
            playback.positions.add(const Duration(seconds: 1));
            await _frames(tester, 10);
          }
          if (hiddenBy == 'inactive') {
            playback.active.value = false;
          } else if (hiddenBy == 'ticker mode') {
            playback.tickers.value = false;
          } else {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
          }
          await tester.pump();
          final scrollPosition = tester
              .state<ScrollableState>(
                find.descendant(of: list, matching: find.byType(Scrollable)),
              )
              .position;
          final hiddenOffset = scrollPosition.pixels;
          final hiddenIndex = duringReturn
              ? _lyricIndexAtPlaybackAnchor(tester)
              : null;
          playback.positions.add(const Duration(seconds: 450));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          expect(scrollPosition.pixels, hiddenOffset);
          if (hiddenIndex != null) {
            expect(_lyricIndexAtPlaybackAnchor(tester), hiddenIndex);
          }
          expect(tester.binding.hasScheduledFrame, isFalse);
          playback.discontinuities.add(
            _jump(450, 400, loop: hiddenBy == 'inactive'),
          );
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          expect(scrollPosition.pixels, hiddenOffset);
          if (hiddenIndex != null) {
            expect(_lyricIndexAtPlaybackAnchor(tester), hiddenIndex);
          }
          expect(scrollPosition.isScrollingNotifier.value, isFalse);
          playback.positions.add(const Duration(seconds: 400));
          await tester.pump();
          await tester.pump();
          expect(scrollPosition.pixels, hiddenOffset);
          if (hiddenIndex != null) {
            expect(_lyricIndexAtPlaybackAnchor(tester), hiddenIndex);
          }
          if (hiddenBy == 'inactive') {
            playback.active.value = true;
          } else if (hiddenBy == 'ticker mode') {
            playback.tickers.value = true;
          } else {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          }
          await tester.pump();
          await tester.pump();
          _expectAnchor(tester, 'spring 400');
          final center = tester.getCenter(find.text('spring 400'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(tester.getCenter(find.text('spring 400')), center);
        },
      );
    }
  }

  testWidgets('browse resume timer waits for foreground before following', (
    tester,
  ) async {
    final playback = await _mount(
      tester,
      position: const Duration(seconds: 20),
    );
    final list = find.byKey(const ValueKey('full-lyric-list'));
    await tester.drag(list, const Offset(0, -160));
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        )
        .position;
    final browsedOffset = position.pixels;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    playback.positions.add(const Duration(seconds: 60));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(position.pixels, browsedOffset);
    expect(position.isScrollingNotifier.value, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    _expectAnchor(tester, 'spring 60');
  });

  testWidgets('same-line seek continues following later lyrics', (
    tester,
  ) async {
    final playback = await _mount(
      tester,
      position: const Duration(milliseconds: 1200),
    );
    playback.discontinuities.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.seek,
        PlaybackEvent(
          currentIndex: 0,
          updatePosition: const Duration(milliseconds: 1200),
        ),
        PlaybackEvent(
          currentIndex: 0,
          updatePosition: const Duration(milliseconds: 1700),
        ),
      ),
    );
    playback.positions.add(const Duration(milliseconds: 1700));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 1');
    for (final next in [2, 3]) {
      playback.positions.add(Duration(seconds: next));
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring $next');
    }
  });

  testWidgets('seek target passed before a frame follows current playback', (
    tester,
  ) async {
    final playback = await _mount(
      tester,
      lyrics: List.generate(
        80,
        (index) => LyricLine(
          startTime: index == 2
              ? const Duration(milliseconds: 1001)
              : Duration(seconds: index),
          endTime: index == 1
              ? const Duration(milliseconds: 1001)
              : Duration(seconds: index + 1),
          text: 'spring $index',
        ),
      ),
    );
    playback.discontinuities.add(_jump(0, 1));
    playback.positions.add(const Duration(seconds: 1));
    await tester.idle();
    playback.positions.add(const Duration(milliseconds: 1002));
    await tester.idle();
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump();
    }
    _expectAnchor(tester, 'spring 2');
    final adjacent = tester.getCenter(find.text('spring 4'));
    await _frames(tester, 30);
    expect(tester.getCenter(find.text('spring 4')), adjacent);
    for (final next in [3, 4]) {
      playback.positions.add(Duration(seconds: next));
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring $next');
    }
  });

  testWidgets(
    'tapping a short line follows playback beyond the tapped target',
    (tester) async {
      Duration? requested;
      final playback = await _mount(
        tester,
        lyrics: List.generate(
          80,
          (index) => LyricLine(
            startTime: index == 2
                ? const Duration(milliseconds: 1001)
                : Duration(seconds: index),
            endTime: index == 1
                ? const Duration(milliseconds: 1001)
                : Duration(seconds: index + 1),
            text: 'spring $index',
          ),
        ),
        display: (playback) => FullLyricDisplay(
          isPortrait: true,
          showPlaybackLineControls: true,
          onSeekRequested: (target) {
            requested = target;
            playback.discontinuities.add(_jump(0, 1));
            playback.positions.add(target);
            playback.positions.add(const Duration(milliseconds: 1002));
          },
        ),
      );
      await tester.tap(find.text('spring 1'));
      await tester.idle();
      expect(requested, const Duration(seconds: 1));
      await tester.pump();
      expect(playback.container.read(currentLyricIndexProvider), 2);
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 2');
      final adjacent = tester.getCenter(find.text('spring 4'));
      await _frames(tester, 30);
      expect(tester.getCenter(find.text('spring 4')), adjacent);
      for (final next in [3, 4]) {
        playback.positions.add(Duration(seconds: next));
        await tester.pumpAndSettle();
        _expectAnchor(tester, 'spring $next');
      }
    },
  );

  testWidgets('a synchronous seek confirmation does not snap a tapped line', (
    tester,
  ) async {
    Duration? requested;
    await _mount(
      tester,
      syncDiscontinuities: true,
      display: (playback) => FullLyricDisplay(
        isPortrait: true,
        showPlaybackLineControls: true,
        onSeekRequested: (target) {
          requested = target;
          playback.discontinuities.add(_jump(0, 1));
          playback.positions.add(target);
        },
      ),
    );
    final clickedLine = find.text('spring 1');
    final activeSize = tester
        .widget<Text>(find.text('spring 0'))
        .style!
        .fontSize!;
    await tester.tap(clickedLine);
    await tester.idle();
    await tester.pump();

    expect(requested, const Duration(seconds: 1));
    final afterConfirmation = tester.getCenter(clickedLine).dy;
    expect(tester.widget<Text>(clickedLine).style!.fontSize, activeSize);
    expect(tester.widget<Text>(clickedLine).style!.color!.a, 1);
    expect(
      tester.getRect(clickedLine).width / tester.getSize(clickedLine).width,
      closeTo(1, 0.005),
    );
    expect(
      (afterConfirmation -
              tester
                  .getCenter(
                    find.byKey(const ValueKey('playback-line-indicator')),
                  )
                  .dy)
          .abs(),
      greaterThan(0.5),
    );
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      (tester.getCenter(clickedLine).dy - afterConfirmation).abs(),
      greaterThan(0.5),
    );

    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 1');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a paused tap keeps its temporary target and stays paused', (
    tester,
  ) async {
    Duration? requested;
    final playback = await _mount(
      tester,
      display: (_) => FullLyricDisplay(
        isPortrait: true,
        showPlaybackLineControls: true,
        onSeekRequested: (target) => requested = target,
      ),
    );
    playback.states.add(PlayerState(false, ProcessingState.ready));
    await tester.pumpAndSettle();
    expect(playback.container.read(isPlayingProvider), isFalse);

    await tester.tap(find.text('spring 3'));
    await tester.idle();
    await tester.pump();

    expect(requested, const Duration(seconds: 3));
    expect(playback.container.read(isPlayingProvider), isFalse);
    expect(tester.widget<Text>(find.text('spring 3')).style!.color!.a, 1);

    await tester.pumpAndSettle();

    expect(playback.container.read(isPlayingProvider), isFalse);
    _expectAnchor(tester, 'spring 3');
  });

  testWidgets('an external seek takes over a moving click target', (
    tester,
  ) async {
    final playback = await _mount(
      tester,
      display: (_) => FullLyricDisplay(
        isPortrait: true,
        showPlaybackLineControls: true,
        onSeekRequested: (_) {},
      ),
    );
    await tester.tap(find.text('spring 3'));
    await tester.pump(const Duration(milliseconds: 80));

    playback.discontinuities.add(_jump(0, 6));
    playback.positions.add(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 6');

    await tester.pump(const Duration(seconds: 4));
    _expectAnchor(tester, 'spring 6');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('rapid confirmed taps leave only the newest target active', (
    tester,
  ) async {
    final requested = <Duration>[];
    var previousIndex = 0;
    await _mount(
      tester,
      display: (playback) => FullLyricDisplay(
        isPortrait: true,
        showPlaybackLineControls: true,
        onSeekRequested: (target) {
          requested.add(target);
          final index = target.inSeconds;
          playback.discontinuities.add(_jump(previousIndex, index));
          playback.positions.add(target);
          previousIndex = index;
        },
      ),
    );

    await tester.tap(find.text('spring 1'));
    await tester.pump(const Duration(milliseconds: 48));
    await tester.tap(find.text('spring 3'));
    await tester.pumpAndSettle();

    expect(requested, [const Duration(seconds: 1), const Duration(seconds: 3)]);
    _expectAnchor(tester, 'spring 3');
    await tester.pump(const Duration(seconds: 4));
    _expectAnchor(tester, 'spring 3');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final target in [1, 2, 0, 70]) {
    testWidgets(
      'explicit seek to line $target cancels queued and moving targets',
      (tester) async {
        final playback = await _mount(tester);
        playback.positions.add(const Duration(seconds: 1));
        await _frames(tester, 12);
        playback.discontinuities.add(_jump(1, target));
        playback.positions.add(Duration(seconds: target));
        await tester.pumpAndSettle();
        _expectAnchor(tester, 'spring $target');
        final center = tester.getCenter(find.text('spring $target'));
        await _frames(tester, 40);
        expect(tester.getCenter(find.text('spring $target')), center);
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );
  }

  testWidgets(
    'loop back clears its old target before the next continuous line',
    (tester) async {
      final playback = await _mount(
        tester,
        position: const Duration(seconds: 20),
      );
      playback.positions.add(const Duration(seconds: 21));
      await _frames(tester, 12);
      playback.discontinuities.add(_jump(21, 0, loop: true));
      playback.positions.add(Duration.zero);
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 0');
      playback.positions.add(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 1');
    },
  );

  testWidgets(
    'preview cancels motion and hidden restore keeps its selected line',
    (tester) async {
      final playback = await _mount(tester);
      playback.positions.add(const Duration(seconds: 1));
      await _frames(tester, 12);
      playback.preview.value = (
        isSeekingManually: true,
        seekValue: 70,
        position: const Duration(seconds: 70),
      );
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 70');
      playback.active.value = false;
      await tester.pump();
      playback.positions.add(const Duration(seconds: 5));
      await tester.pump();
      playback.active.value = true;
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 70');
      playback.preview.value = null;
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 5');
    },
  );

  testWidgets('tap on moving text seeks the displayed line', (tester) async {
    Duration? requested;
    final playback = await _mount(
      tester,
      display: (_) => FullLyricDisplay(
        isPortrait: true,
        showPlaybackLineControls: true,
        onSeekRequested: (value) => requested = value,
        onLineDoubleTap: () {},
      ),
    );
    playback.positions.add(const Duration(seconds: 1));
    await _frames(tester, 20);
    await tester.tapAt(tester.getCenter(find.text('spring 4')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(requested, const Duration(seconds: 4));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 4');
  });

  for (final locked in [false, true]) {
    testWidgets(
      'fullscreen first layout directly positions the distant line with locked=$locked',
      (tester) async {
        await _mount(
          tester,
          position: const Duration(seconds: 70),
          settle: false,
          display: (_) => FullLyricDisplay(
            isPortrait: true,
            isLocked: locked,
            showPlaybackLineControls: true,
          ),
        );
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump();
        }
        _expectAnchor(tester, 'spring 70');
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );

    testWidgets('moving lyrics preserve double tap with locked=$locked', (
      tester,
    ) async {
      final seeks = <Duration>[];
      var toggles = 0;
      final playback = await _mount(
        tester,
        display: (_) => FullLyricDisplay(
          isPortrait: true,
          isLocked: locked,
          showPlaybackLineControls: true,
          onSeekRequested: seeks.add,
          onLineDoubleTap: () => toggles++,
        ),
      );
      playback.positions.add(const Duration(seconds: 1));
      await _frames(tester, 12);
      final tap = tester.getCenter(find.text('spring 2'));
      await tester.tapAt(tap);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(tap);
      await tester.pumpAndSettle();
      expect(seeks, isEmpty);
      expect(toggles, locked ? 0 : 1);
      _expectAnchor(tester, 'spring 1');
    });
  }

  testWidgets(
    'search interrupts motion and aligns repeated wrapped hits with keyboard',
    (tester) async {
      final wrapped =
          'needle ${List.filled(24, 'wrapped subtitle words').join(' ')} needle';
      final playback = await _mount(
        tester,
        lyrics: List.generate(
          520,
          (index) => LyricLine(
            startTime: Duration(seconds: index),
            endTime: Duration(seconds: index + 1),
            text: index == 267
                ? wrapped
                : index == 519
                ? 'last needle'
                : 'spring $index',
          ),
        ),
      );
      playback.positions.add(const Duration(seconds: 1));
      await _frames(tester, 12);
      await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('lyric-search-field')),
        'needle',
      );
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);
      _expectMatch(tester, wrapped, 0, 6);
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      _expectMatch(
        tester,
        wrapped,
        wrapped.lastIndexOf('needle'),
        wrapped.length,
      );
      playback.positions.add(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      _expectMatch(
        tester,
        wrapped,
        wrapped.lastIndexOf('needle'),
        wrapped.length,
      );
      addTearDown(tester.view.resetViewInsets);
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      _expectMatch(
        tester,
        wrapped,
        wrapped.lastIndexOf('needle'),
        wrapped.length,
      );
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      _expectMatch(tester, 'last needle', 5, 11);
      await tester.enterText(
        find.byKey(const ValueKey('lyric-search-field')),
        'absent text',
      );
      playback.positions.add(const Duration(seconds: 21));
      await tester.pumpAndSettle();
      expect(find.text('0/0'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('a tapped search lyric follows later scroll input', (
    tester,
  ) async {
    final requested = <Duration>[];
    final playback = await _mount(
      tester,
      display: (_) => FullLyricDisplay(
        isPortrait: true,
        showPlaybackLineControls: true,
        searchMode: true,
        suspendAutoScroll: true,
        enableLineTapFeedback: true,
        onSeekRequested: requested.add,
      ),
    );
    final clickedLine = find.text('spring 2');
    await tester.tap(clickedLine);
    await tester.idle();
    await tester.pumpAndSettle();

    expect(requested, [const Duration(seconds: 2)]);
    expect(tester.widget<Text>(clickedLine).style!.color!.a, 1);
    playback.discontinuities.add(_jump(0, 2));
    playback.positions.add(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 2');
    final list = find.byKey(const ValueKey('full-lyric-list'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    final beforeOffset = position.pixels;
    final beforeY = tester.getCenter(clickedLine).dy;

    await tester.drag(list, const Offset(0, -120));
    await tester.pumpAndSettle();

    final offsetDelta = position.pixels - beforeOffset;
    expect(offsetDelta.abs(), greaterThan(1));
    expect(tester.getCenter(clickedLine).dy, closeTo(beforeY - offsetDelta, 6));
  });

  testWidgets('changing a running preset preserves position and velocity', (
    tester,
  ) async {
    final playback = await _mount(tester);
    playback.positions.add(const Duration(seconds: 1));
    await _frames(tester, 16);
    final row = find.text('spring 1');
    final before = tester.getCenter(row).dy;
    await _frames(tester, 1);
    final atSwitch = tester.getCenter(row).dy;
    final travel = atSwitch - before;
    expect(travel.abs(), greaterThan(0.2));
    await playback.container
        .read(playerLyricSettingsProvider.notifier)
        .updateSpringPreset(PlayerLyricSpringPreset.heavy);
    await tester.pump();
    expect(tester.getCenter(row).dy, closeTo(atSwitch, 0.1));
    await _frames(tester, 1);
    final nextTravel = tester.getCenter(row).dy - atSwitch;
    expect(nextTravel.sign, travel.sign);
    expect(nextTravel.abs(), greaterThan(travel.abs() * 0.5));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 1');
  });

  for (final preset in PlayerLyricSpringPreset.values) {
    testWidgets('browse return settles with the ${preset.id} preset', (
      tester,
    ) async {
      final playback = await _mount(
        tester,
        position: const Duration(seconds: 20),
      );
      await playback.container
          .read(playerLyricSettingsProvider.notifier)
          .updateSpringPreset(preset);
      await tester.pumpAndSettle();

      final list = find.byKey(const ValueKey('full-lyric-list'));
      await tester.drag(list, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(_lyricIndexAtPlaybackAnchor(tester), greaterThan(20));

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 20');
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets('changing preset during a browse return preserves velocity', (
    tester,
  ) async {
    final playback = await _mount(
      tester,
      position: const Duration(seconds: 20),
    );
    final settings = playback.container.read(
      playerLyricSettingsProvider.notifier,
    );
    await settings.updateSpringPreset(PlayerLyricSpringPreset.smooth);
    await tester.pumpAndSettle();

    final list = find.byKey(const ValueKey('full-lyric-list'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    await tester.drag(list, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await _frames(tester, 8);

    final beforeSwitch = position.pixels;
    await _frames(tester, 1);
    final atSwitch = position.pixels;
    final beforeTravel = atSwitch - beforeSwitch;
    expect(beforeTravel.abs(), greaterThan(0.1));

    await settings.updateSpringPreset(PlayerLyricSpringPreset.heavy);
    await tester.pump();
    expect(position.pixels, closeTo(atSwitch, 0.1));
    await _frames(tester, 1);
    final afterSwitch = position.pixels;
    final afterTravel = afterSwitch - atSwitch;
    expect(afterTravel.sign, beforeTravel.sign);
    expect(afterTravel.abs(), greaterThan(0.1));

    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 20');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'a queued follow uses the preset selected before its first frame',
    (tester) async {
      Future<double> sample({
        required bool changeWhileQueued,
        PlayerLyricSpringPreset preset = PlayerLyricSpringPreset.heavy,
      }) async {
        final playback = await _mount(tester);
        final settings = playback.container.read(
          playerLyricSettingsProvider.notifier,
        );
        await settings.updateSpringPreset(
          PlayerLyricSpringPreset.defaultPreset,
        );
        await tester.pumpAndSettle();
        if (!changeWhileQueued) {
          await settings.updateSpringPreset(preset);
          await tester.pumpAndSettle();
        }
        playback.positions.add(const Duration(seconds: 1));
        if (changeWhileQueued) {
          tester.binding.addPostFrameCallback((_) {
            unawaited(settings.updateSpringPreset(preset));
          });
        }
        await tester.pump();
        await tester.pump();
        await _frames(tester, 20);
        return tester.getCenter(find.text('spring 1')).dy;
      }

      final selectedBeforeFollow = await sample(changeWhileQueued: false);
      final selectedWhileQueued = await sample(changeWhileQueued: true);
      expect(selectedWhileQueued, closeTo(selectedBeforeFollow, 0.1));
      final defaultMotion = await sample(
        changeWhileQueued: false,
        preset: PlayerLyricSpringPreset.defaultPreset,
      );
      expect((defaultMotion - selectedBeforeFollow).abs(), greaterThan(1));
      await tester.pumpAndSettle();
      _expectAnchor(tester, 'spring 1');
    },
  );

  testWidgets('replacing a browsed track starts at its current line', (
    tester,
  ) async {
    final playback = await _mount(
      tester,
      position: const Duration(seconds: 20),
    );
    await tester.drag(
      find.byKey(const ValueKey('full-lyric-list')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    final controller =
        playback.container.read(lyricControllerProvider.notifier) as _Lyrics;
    controller.replace(
      LyricState(
        trackKey: 'replacement',
        lyrics: List.generate(
          80,
          (index) => LyricLine(
            startTime: Duration(seconds: index),
            endTime: Duration(seconds: index + 1),
            text: 'replacement $index',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'replacement 20');
    final center = tester.getCenter(find.text('replacement 20'));
    await tester.pump(const Duration(seconds: 3));
    expect(tester.getCenter(find.text('replacement 20')), center);
  });

  testWidgets('font, text scale, and rotation retarget a moving line', (
    tester,
  ) async {
    final playback = await _mount(
      tester,
      position: const Duration(seconds: 20),
    );
    playback.positions.add(const Duration(seconds: 21));
    await _frames(tester, 12);
    await playback.container
        .read(playerLyricSettingsProvider.notifier)
        .updateFullFontSize(32);
    playback.textScale.value = 1.4;
    await tester.binding.setSurfaceSize(const Size(844, 390));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 21');
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 21');
  });

  testWidgets('pause settles and reduced motion removes scale and stagger', (
    tester,
  ) async {
    final playback = await _mount(tester);
    playback.positions.add(const Duration(seconds: 1));
    await _frames(tester, 12);
    playback.states.add(PlayerState(false, ProcessingState.ready));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 1');
    expect(tester.binding.hasScheduledFrame, isFalse);
    playback.states.add(PlayerState(true, ProcessingState.ready));
    playback.positions.add(const Duration(seconds: 2));
    await _frames(tester, 12);
    playback.reducedMotion.value = true;
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 2');
    for (final text in ['spring 1', 'spring 2', 'spring 3']) {
      final line = find.text(text);
      expect(
        tester.getRect(line).width / tester.getSize(line).width,
        closeTo(1, 0.001),
      );
    }
    final center = tester.getCenter(find.text('spring 2'));
    await _frames(tester, 40);
    expect(tester.getCenter(find.text('spring 2')), center);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion takes over a browse return', (tester) async {
    final playback = await _mount(
      tester,
      position: const Duration(seconds: 20),
    );
    final list = find.byKey(const ValueKey('full-lyric-list'));
    await tester.drag(list, const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 160));
    expect(_lyricIndexAtPlaybackAnchor(tester), isNot(20));

    playback.reducedMotion.value = true;
    await tester.pump();
    _expectAnchor(tester, 'spring 20');
    for (final index in [19, 20, 21]) {
      final line = find.text('spring $index');
      expect(
        tester.getRect(line).width / tester.getSize(line).width,
        closeTo(1, 0.001),
      );
    }
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion returns past a short-row extent estimate', (
    tester,
  ) async {
    final playback = await _mount(
      tester,
      position: const Duration(seconds: 480),
      lyrics: List.generate(
        500,
        (index) => LyricLine(
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: index >= 80 && index % 5 == 4
              ? 'spring $index ${List.filled(72, 'wrapped subtitle words').join(' ')}'
              : 'spring $index',
        ),
      ),
    );
    playback.reducedMotion.value = true;
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 480');

    final list = find.byKey(const ValueKey('full-lyric-list'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    final playbackOffset = position.pixels;
    position.jumpTo(1800);
    await tester.pumpAndSettle();
    await tester.drag(list, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(_lyricIndexAtPlaybackAnchor(tester), lessThan(480));
    expect(playbackOffset, greaterThan(position.maxScrollExtent));

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    _expectAnchor(tester, 'spring 480');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('empty and inner replacement discard moving or queued lyrics', (
    tester,
  ) async {
    final playback = await _mount(tester);
    final controller =
        playback.container.read(lyricControllerProvider.notifier) as _Lyrics;
    final original = playback.container.read(lyricControllerProvider).lyrics;
    playback.positions.add(const Duration(seconds: 1));
    await tester.pump();
    controller.clearLyrics();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('full-lyric-list')), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
    controller.replace(LyricState(lyrics: original));
    await tester.pumpAndSettle();
    playback.positions.add(const Duration(seconds: 2));
    await _frames(tester, 12);
    final replacement = original.toList();
    replacement[2] = LyricLine(
      startTime: const Duration(seconds: 2),
      endTime: const Duration(seconds: 3),
      text: 'new inner subtitle',
    );
    controller.replace(LyricState(lyrics: replacement));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'new inner subtitle');
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final sourceType in [
    LyricSourceType.remote,
    LyricSourceType.localFile,
  ]) {
    testWidgets(
      '$sourceType animates translated display lyrics with timeline offset',
      (tester) async {
        final original = List.generate(
          20,
          (index) => LyricLine(
            startTime: Duration(seconds: index),
            endTime: Duration(seconds: index + 1),
            text: 'original $index',
          ),
        );
        final translated = List.generate(
          20,
          (index) => LyricLine(
            startTime: Duration(seconds: index),
            endTime: Duration(seconds: index + 1),
            text: 'translated $index',
          ),
        );
        final playback = await _mount(
          tester,
          position: const Duration(seconds: 5),
          lyricState: LyricState(
            lyrics: original,
            translatedLyrics: translated,
            showTranslated: true,
            timelineOffset: const Duration(seconds: 5),
            source: LyricSourceDescriptor(title: 'subtitle', type: sourceType),
          ),
        );
        _expectAnchor(tester, 'translated 0');
        expect(find.text('original 0'), findsNothing);
        final activeLine = find.text('translated 1');
        final initialCenter = tester.getCenter(activeLine).dy;
        playback.positions.add(const Duration(seconds: 6));
        await tester.pump();
        await tester.pump();
        expect(
          tester.getRect(activeLine).width / tester.getSize(activeLine).width,
          closeTo(1, 0.001),
        );
        await _frames(tester, 12);
        expect(
          tester.getRect(activeLine).width / tester.getSize(activeLine).width,
          closeTo(1, 0.001),
        );
        expect(
          (tester.getCenter(activeLine).dy - initialCenter).abs(),
          greaterThan(0.5),
        );
        await tester.pumpAndSettle();
        _expectAnchor(tester, 'translated 1');
      },
    );
  }
}

void _expectMatch(WidgetTester tester, String text, int start, int end) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == text,
    ),
  );
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  final glyph = paragraph.localToGlobal(
    Offset(
      (boxes.first.left + boxes.last.right) / 2,
      (boxes.first.top + boxes.last.bottom) / 2,
    ),
  );
  final viewport = tester.getRect(
    find.byKey(const ValueKey('lyric-keyboard-safe-viewport')),
  );
  expect(glyph.dy, closeTo(viewport.top + viewport.height * 0.4, 2.1));
}

PositionDiscontinuity _jump(int from, int to, {bool loop = false}) =>
    PositionDiscontinuity(
      loop
          ? PositionDiscontinuityReason.autoAdvance
          : PositionDiscontinuityReason.seek,
      PlaybackEvent(currentIndex: 0, updatePosition: Duration(seconds: from)),
      PlaybackEvent(currentIndex: 0, updatePosition: Duration(seconds: to)),
    );

Future<void> _frames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void _expectAnchor(WidgetTester tester, String text) {
  final anchor = tester.getCenter(
    find.byKey(const ValueKey('playback-line-indicator')),
  );
  expect(tester.getCenter(find.text(text)).dy, closeTo(anchor.dy, 2.1));
}

int _lyricIndexAtPlaybackAnchor(WidgetTester tester) {
  final list = find.byKey(const ValueKey('full-lyric-list'));
  final viewport = tester.getRect(find.byType(FullLyricDisplay));
  final anchorY = tester
      .getCenter(find.byKey(const ValueKey('playback-line-indicator')))
      .dy;
  final visibleRows = find
      .descendant(
        of: list,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              RegExp(r'^spring \d+').hasMatch(widget.text.toPlainText()),
        ),
      )
      .evaluate()
      .map((element) {
        final paragraph = element.renderObject! as RenderParagraph;
        final center = paragraph.localToGlobal(
          paragraph.size.center(Offset.zero),
        );
        return (
          index: int.parse(
            RegExp(
              r'^spring (\d+)',
            ).firstMatch(paragraph.text.toPlainText())![1]!,
          ),
          center: center,
        );
      })
      .where(
        (row) =>
            row.center.dy >= viewport.top && row.center.dy <= viewport.bottom,
      )
      .toList(growable: false);
  expect(visibleRows, isNotEmpty);
  return visibleRows.reduce((left, right) {
    return (left.center.dy - anchorY).abs() <= (right.center.dy - anchorY).abs()
        ? left
        : right;
  }).index;
}

class _Playback {
  _Playback({bool syncDiscontinuities = false})
    : discontinuities = StreamController<PositionDiscontinuity>(
        sync: syncDiscontinuities,
      );

  final positions = StreamController<Duration>();
  final states = StreamController<PlayerState>();
  final StreamController<PositionDiscontinuity> discontinuities;
  final preview = ValueNotifier<PlayerSeekPreview?>(null);
  final active = ValueNotifier<bool>(true);
  final tickers = ValueNotifier<bool>(true);
  final reducedMotion = ValueNotifier<bool>(false);
  final textScale = ValueNotifier<double>(1);
  late ProviderContainer container;

  Future<void> dispose() async {
    container.dispose();
    await positions.close();
    await states.close();
    await discontinuities.close();
    preview.dispose();
    active.dispose();
    tickers.dispose();
    reducedMotion.dispose();
    textScale.dispose();
  }
}

Future<_Playback> _mount(
  WidgetTester tester, {
  List<LyricLine>? lyrics,
  LyricState? lyricState,
  Duration position = Duration.zero,
  bool settle = true,
  bool syncDiscontinuities = false,
  Widget Function(_Playback playback)? display,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final playback = _Playback(syncDiscontinuities: syncDiscontinuities);
  addTearDown(playback.dispose);
  playback.positions.add(position);
  playback.states.add(PlayerState(true, ProcessingState.ready));
  playback.container = ProviderContainer(
    overrides: [
      positionProvider.overrideWith((ref) => playback.positions.stream),
      positionDiscontinuityProvider.overrideWith(
        (ref) => playback.discontinuities.stream,
      ),
      currentTrackProvider.overrideWith((ref) => const Stream.empty()),
      playerStateProvider.overrideWith((ref) => playback.states.stream),
      lyricControllerProvider.overrideWith(
        (ref) => _Lyrics(
          ref,
          lyricState ??
              LyricState(
                lyrics:
                    lyrics ??
                    List.generate(
                      80,
                      (index) => LyricLine(
                        startTime: Duration(seconds: index),
                        endTime: Duration(seconds: index + 1),
                        text: 'spring $index',
                      ),
                    ),
              ),
        ),
      ),
      audioSliceStateProvider.overrideWith((ref) => const Stream.empty()),
      durationProvider.overrideWith((ref) => const Stream.empty()),
      isTrackLoadingProvider.overrideWith((ref) => const Stream.empty()),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: playback.container,
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: ListenableBuilder(
            listenable: Listenable.merge([
              playback.active,
              playback.tickers,
              playback.reducedMotion,
              playback.textScale,
            ]),
            builder: (context, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: playback.reducedMotion.value,
                textScaler: TextScaler.linear(playback.textScale.value),
              ),
              child: TickerMode(
                enabled: playback.tickers.value,
                child:
                    display?.call(playback) ??
                    PlayerLyricsSurface(
                      isWide: false,
                      isActive: playback.active.value,
                      seekingPositionListenable: playback.preview,
                      onFullscreen: () {},
                      translateButton: const Icon(Icons.translate),
                    ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return playback;
}

class _Lyrics extends LyricController {
  _Lyrics(super.ref, LyricState initial) : super(initialState: initial);

  void replace(LyricState value) => state = value;
}

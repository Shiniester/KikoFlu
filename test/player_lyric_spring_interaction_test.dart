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

  testWidgets('growing lyrics keep their original line breaks', (tester) async {
    const singleLine = 'MMMMMMMMM';
    const multipleLines = 'MMMMMMMMM MMMMMMMMM MMMMMMMMM';
    final playback = await _mount(
      tester,
      lyrics: [
        LyricLine(
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          text: 'first',
        ),
        LyricLine(
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
          text: singleLine,
        ),
        LyricLine(
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 3),
          text: multipleLines,
        ),
      ],
      display: (_) => const FullLyricDisplay(
        isPortrait: true,
        contentWidth: 160,
        showPlaybackLineControls: true,
      ),
    );

    List<int> lineBreaks(String text) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (widget) => widget is RichText && widget.text.toPlainText() == text,
        ),
      );
      final lineTops = <double>[];
      return List.generate(text.length, (index) {
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: index, extentOffset: index + 1),
        );
        if (boxes.isEmpty) return -1;
        final top = boxes.first.top;
        final line = lineTops.indexWhere((value) => (value - top).abs() < 0.5);
        if (line >= 0) return line;
        lineTops.add(top);
        return lineTops.length - 1;
      });
    }

    final singleWidth = tester.getRect(find.text(singleLine)).width;
    final multipleWidth = tester.getRect(find.text(multipleLines)).width;
    final singleBreaks = lineBreaks(singleLine);
    final multipleBreaks = lineBreaks(multipleLines);
    expect(singleBreaks.toSet(), {0});
    expect(multipleBreaks.toSet().length, greaterThan(1));

    playback.positions.add(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(lineBreaks(singleLine), singleBreaks);
    final activeWidth = tester.getRect(find.text(singleLine)).width;
    final settings = playback.container.read(playerLyricSettingsProvider);
    expect(
      activeWidth / singleWidth,
      closeTo(
        settings.fullActiveFontSize / (settings.fullInactiveFontSize * 0.97),
        0.02,
      ),
    );
    expect(activeWidth, greaterThan(160));

    playback.positions.add(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(lineBreaks(multipleLines), multipleBreaks);
    expect(
      tester.getRect(find.text(multipleLines)).width,
      greaterThan(multipleWidth),
    );
  });

  testWidgets('a large multiline subtitle does not cover its neighbor', (
    tester,
  ) async {
    final multiline = List.filled(5, 'MMMMMMMMM').join(' ');
    final playback = await _mount(
      tester,
      lyrics: [
        LyricLine(
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          text: 'first',
        ),
        LyricLine(
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
          text: multiline,
        ),
        LyricLine(
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 3),
          text: 'next',
        ),
      ],
      display: (_) => const FullLyricDisplay(
        isPortrait: true,
        contentWidth: 160,
        showPlaybackLineControls: true,
      ),
    );
    final settings = playback.container.read(
      playerLyricSettingsProvider.notifier,
    );
    await settings.updateFullActiveFontSize(32);
    await settings.updateFullInactiveFontSize(12);
    await tester.pumpAndSettle();
    final spacing =
        tester.getCenter(find.text('next')).dy -
        tester.getCenter(find.text(multiline)).dy;

    playback.positions.add(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final current = tester.getRect(find.text(multiline));
    final next = tester.getRect(find.text('next'));
    expect(current.bottom, lessThanOrEqualTo(next.top + 0.5));
    expect(next.center.dy - current.center.dy, closeTo(spacing, 0.5));
  });

  for (final locked in [false, true]) {
    for (final reducedMotion in [false, true]) {
      testWidgets(
        'full-screen subtitles fit with locked=$locked and reducedMotion=$reducedMotion',
        (tester) async {
          const subtitle = 'MMMMMMMMMMMMMMMMMMMMMMMM';
          final playback = await _mount(
            tester,
            lyrics: [
              LyricLine(
                startTime: Duration.zero,
                endTime: const Duration(seconds: 1),
                text: 'first',
              ),
              LyricLine(
                startTime: const Duration(seconds: 1),
                endTime: const Duration(seconds: 2),
                text: subtitle,
              ),
            ],
            display: (_) =>
                FullLyricDisplay(isPortrait: true, isLocked: locked),
          );
          final settings = playback.container.read(
            playerLyricSettingsProvider.notifier,
          );
          await settings.updateFullActiveFontSize(32);
          await settings.updateFullInactiveFontSize(12);
          playback.reducedMotion.value = reducedMotion;
          await tester.pumpAndSettle();
          playback.positions.add(const Duration(seconds: 1));

          final viewport = tester.getRect(
            find.byKey(const ValueKey('full-lyric-list')),
          );
          final finder = find.byWidgetPredicate(
            (widget) =>
                widget is RichText && widget.text.toPlainText() == subtitle,
          );
          for (var frame = 0; frame < 60; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            final paragraph = tester.renderObject<RenderParagraph>(finder);
            for (var index = 0; index < subtitle.length; index++) {
              final boxes = paragraph.getBoxesForSelection(
                TextSelection(baseOffset: index, extentOffset: index + 1),
              );
              for (final box in boxes) {
                final left = paragraph.localToGlobal(Offset(box.left, box.top));
                final right = paragraph.localToGlobal(
                  Offset(box.right, box.bottom),
                );
                expect(left.dx, greaterThanOrEqualTo(viewport.left - 0.01));
                expect(right.dx, lessThanOrEqualTo(viewport.right + 0.01));
              }
            }
          }
          final paragraph = tester.renderObject<RenderParagraph>(finder);
          final firstBox = paragraph
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 1),
              )
              .single;
          final lastBox = paragraph
              .getBoxesForSelection(
                const TextSelection(baseOffset: 23, extentOffset: 24),
              )
              .single;
          expect(lastBox.top, greaterThan(firstBox.top));
        },
      );
    }
  }

  testWidgets('subtitle overflow inside the lyric list remains tappable', (
    tester,
  ) async {
    const subtitle = 'MMMMMMMMMMMMM';
    Duration? requested;
    final playback = await _mount(
      tester,
      lyrics: [
        LyricLine(
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          text: 'first',
        ),
        LyricLine(
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
          text: subtitle,
        ),
      ],
      display: (_) => FullLyricDisplay(
        isPortrait: true,
        contentWidth: 160,
        onSeekRequested: (target) => requested = target,
      ),
    );
    final settings = playback.container.read(
      playerLyricSettingsProvider.notifier,
    );
    await settings.updateFullActiveFontSize(32);
    await settings.updateFullInactiveFontSize(12);
    playback.positions.add(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final line = find.text(subtitle);
    final textRect = tester.getRect(line);
    expect(textRect.left, lessThan(5));
    await tester.tapAt(Offset(5, textRect.center.dy));
    await tester.pumpAndSettle();
    expect(requested, const Duration(seconds: 1));
  });

  testWidgets('playback emphasis changes while the subtitle moves', (
    tester,
  ) async {
    final playback = await _mount(tester);
    final next = find.text('spring 1');
    final previous = find.text('spring 0');
    final initialWidth = tester.getRect(next).width;
    final initialAlpha = _visibleLyricAlpha(tester, next);
    final previousAlpha = _visibleLyricAlpha(tester, previous);
    final initialY = tester.getCenter(next).dy;
    final anchor = tester.getCenter(
      find.byKey(const ValueKey('playback-line-indicator')),
    );
    final samples =
        <({double width, double alpha, double previous, double y})>[];

    playback.positions.add(const Duration(seconds: 1));
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      samples.add((
        width: tester.getRect(next).width,
        alpha: _visibleLyricAlpha(tester, next),
        previous: _visibleLyricAlpha(tester, previous),
        y: tester.getCenter(next).dy,
      ));
    }
    await tester.pumpAndSettle();
    final finalWidth = tester.getRect(next).width;
    final finalAlpha = _visibleLyricAlpha(tester, next);
    final finalPrevious = _visibleLyricAlpha(tester, previous);
    final finalY = tester.getCenter(next).dy;

    expect(finalWidth, greaterThan(initialWidth));
    expect(finalAlpha, greaterThan(initialAlpha));
    expect(finalPrevious, lessThan(previousAlpha));
    expect(samples.first.width, lessThan((initialWidth + finalWidth) / 2));
    expect(samples.first.alpha, lessThan((initialAlpha + finalAlpha) / 2));
    expect(
      samples.any(
        (sample) =>
            sample.width > initialWidth + 0.1 &&
            sample.width < finalWidth - 0.1 &&
            sample.alpha > initialAlpha + 0.01 &&
            sample.alpha < finalAlpha - 0.01 &&
            (sample.y - initialY).abs() > 0.5 &&
            (sample.y - anchor.dy).abs() > 0.5,
      ),
      isTrue,
    );
    var comparedFrames = 0;
    for (final sample in samples) {
      final movement = (sample.y - initialY) / (finalY - initialY);
      if (movement <= 0.15 || movement >= 0.85) continue;
      final brightness =
          (sample.alpha - initialAlpha) / (finalAlpha - initialAlpha);
      final size = (sample.width - initialWidth) / (finalWidth - initialWidth);
      expect(brightness, closeTo(movement, 0.15));
      expect(size, closeTo(movement, 0.15));
      comparedFrames++;
    }
    expect(comparedFrames, greaterThan(1));
    expect(
      samples.any(
        (sample) =>
            sample.previous < previousAlpha - 0.01 &&
            sample.previous > finalPrevious + 0.01,
      ),
      isTrue,
    );
    _expectAnchor(tester, 'spring 1');
  });

  testWidgets('a newer subtitle continues from the current emphasis', (
    tester,
  ) async {
    final playback = await _mount(tester);
    final first = find.text('spring 1');
    final initialAlpha = _visibleLyricAlpha(tester, first);
    playback.positions.add(const Duration(seconds: 1));
    await _frames(tester, 8);
    final beforeAlpha = _visibleLyricAlpha(tester, first);
    final beforeWidth = tester.getRect(first).width;
    expect(beforeAlpha, greaterThan(initialAlpha));
    expect(beforeAlpha, lessThan(1));

    playback.positions.add(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump();
    expect(_visibleLyricAlpha(tester, first), closeTo(beforeAlpha, 0.02));
    expect(tester.getRect(first).width, closeTo(beforeWidth, 0.5));
    await tester.pumpAndSettle();
    expect(_visibleLyricAlpha(tester, find.text('spring 2')), closeTo(1, 0.01));
    _expectAnchor(tester, 'spring 2');
  });

  testWidgets('changing the active size retargets a running emphasis', (
    tester,
  ) async {
    final playback = await _mount(tester);
    final target = find.text('spring 1');
    playback.positions.add(const Duration(seconds: 1));
    await _frames(tester, 8);
    final before = tester.getRect(target).width;
    await playback.container
        .read(playerLyricSettingsProvider.notifier)
        .updateFullActiveFontSize(32);
    final widths = <double>[];
    for (var frame = 0; frame < 100; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      widths.add(tester.getRect(target).width);
    }
    await tester.pumpAndSettle();
    final targetWidth = tester.getRect(target).width;
    expect(targetWidth, greaterThan(before));
    final maximumStep = (targetWidth - before) * 0.35 + 0.5;
    var previous = before;
    for (final width in widths) {
      expect((width - previous).abs(), lessThan(maximumStep));
      previous = width;
    }
  });

  testWidgets('a paused tap gradually emphasizes its target', (tester) async {
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
    final target = find.text('spring 3');
    final initialWidth = tester.getRect(target).width;
    final initialAlpha = _visibleLyricAlpha(tester, target);
    final initialY = tester.getCenter(target).dy;
    final previous = find.text('spring 0');
    final previousAlpha = _visibleLyricAlpha(tester, previous);
    final samples =
        <({double width, double alpha, double previous, double y})>[];

    await tester.tap(target);
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      samples.add((
        width: tester.getRect(target).width,
        alpha: _visibleLyricAlpha(tester, target),
        previous: _visibleLyricAlpha(tester, previous),
        y: tester.getCenter(target).dy,
      ));
    }
    await tester.pumpAndSettle();
    final finalWidth = tester.getRect(target).width;
    final finalAlpha = _visibleLyricAlpha(tester, target);
    final finalPrevious = _visibleLyricAlpha(tester, previous);

    expect(requested, const Duration(seconds: 3));
    expect(playback.container.read(isPlayingProvider), isFalse);
    expect(
      samples.any(
        (sample) =>
            sample.width > initialWidth + 0.1 &&
            sample.width < finalWidth - 0.1 &&
            sample.alpha > initialAlpha + 0.01 &&
            sample.alpha < finalAlpha - 0.01 &&
            (sample.y - initialY).abs() > 0.5,
      ),
      isTrue,
    );
    expect(
      samples.any(
        (sample) =>
            sample.previous < previousAlpha - 0.01 &&
            sample.previous > finalPrevious + 0.01,
      ),
      isTrue,
    );
    _expectAnchor(tester, 'spring 3');
  });

  testWidgets('pausing during emphasis lets it finish without a jump', (
    tester,
  ) async {
    final playback = await _mount(tester);
    final target = find.text('spring 1');
    playback.positions.add(const Duration(seconds: 1));
    await _frames(tester, 8);
    final before = _visibleLyricAlpha(tester, target);
    expect(before, lessThan(1));

    playback.states.add(PlayerState(false, ProcessingState.ready));
    await tester.pump();
    expect(_visibleLyricAlpha(tester, target), closeTo(before, 0.02));
    await tester.pumpAndSettle();
    expect(_visibleLyricAlpha(tester, target), closeTo(1, 0.001));
    expect(playback.container.read(isPlayingProvider), isFalse);
  });

  testWidgets('a search result gradually emphasizes its tapped subtitle', (
    tester,
  ) async {
    Duration? requested;
    await _mount(
      tester,
      display: (_) => FullLyricDisplay(
        isPortrait: true,
        showPlaybackLineControls: true,
        searchMode: true,
        suspendAutoScroll: true,
        onSeekRequested: (target) => requested = target,
      ),
    );
    final target = find.text('spring 3');
    final initialAlpha = _visibleLyricAlpha(tester, target);
    final samples = <double>[];

    await tester.tap(target);
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      samples.add(_visibleLyricAlpha(tester, target));
    }
    await tester.pumpAndSettle();
    final finalAlpha = _visibleLyricAlpha(tester, target);
    expect(requested, const Duration(seconds: 3));
    expect(finalAlpha, closeTo(1, 0.001));
    expect(
      samples.any(
        (alpha) => alpha > initialAlpha + 0.01 && alpha < finalAlpha - 0.01,
      ),
      isTrue,
    );
  });

  testWidgets('playback emphasis changes while browsing without scrolling', (
    tester,
  ) async {
    final playback = await _mount(tester);
    final list = find.byKey(const ValueKey('full-lyric-list'));
    await tester.drag(list, const Offset(0, -25));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    final offset = position.pixels;
    final next = find.text('spring 1');
    final initialWidth = tester.getRect(next).width;
    final initialAlpha = _visibleLyricAlpha(tester, next);
    final initialY = tester.getCenter(next).dy;
    final samples = <({double width, double alpha})>[];

    playback.positions.add(const Duration(seconds: 1));
    for (var frame = 0; frame < 80; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      samples.add((
        width: tester.getRect(next).width,
        alpha: _visibleLyricAlpha(tester, next),
      ));
      expect(position.pixels, closeTo(offset, 0.01));
      expect(tester.getCenter(next).dy, closeTo(initialY, 0.5));
    }
    final finalWidth = tester.getRect(next).width;
    final finalAlpha = _visibleLyricAlpha(tester, next);
    expect(finalWidth, greaterThan(initialWidth));
    expect(finalAlpha, greaterThan(initialAlpha));
    expect(
      samples.any(
        (sample) =>
            sample.width > initialWidth + 0.1 &&
            sample.width < finalWidth - 0.1 &&
            sample.alpha > initialAlpha + 0.01 &&
            sample.alpha < finalAlpha - 0.01,
      ),
      isTrue,
    );
  });

  testWidgets('seek preview clears running emphasis while browsing', (
    tester,
  ) async {
    final playback = await _mount(tester);
    final list = find.byKey(const ValueKey('full-lyric-list'));
    await tester.drag(list, const Offset(0, -25));
    await tester.pumpAndSettle();

    playback.positions.add(const Duration(seconds: 1));
    await _frames(tester, 8);
    final previous = find.text('spring 1');
    expect(_visibleLyricAlpha(tester, previous), greaterThan(0.34));
    expect(_visibleLyricAlpha(tester, previous), lessThan(1));

    playback.preview.value = (
      isSeekingManually: true,
      seekValue: 3.0,
      position: const Duration(seconds: 3),
    );
    await tester.pump();
    await tester.pump();

    expect(_visibleLyricAlpha(tester, find.text('spring 3')), closeTo(1, 0.01));
    expect(_visibleLyricAlpha(tester, previous), closeTo(0.24, 0.01));
  });

  testWidgets('an initially unbuilt subtitle gradually becomes emphasized', (
    tester,
  ) async {
    final tall = List.filled(100, 'wrapped subtitle words').join(' ');
    final playback = await _mount(
      tester,
      lyrics: [
        LyricLine(
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          text: tall,
        ),
        LyricLine(
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
          text: 'next subtitle',
        ),
      ],
    );
    final next = find.text('next subtitle');
    expect(next, findsNothing);
    final samples = <double>[];

    playback.positions.add(const Duration(seconds: 1));
    for (var frame = 0; frame < 80; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (next.evaluate().isNotEmpty) {
        samples.add(_visibleLyricAlpha(tester, next));
      }
    }
    await tester.pumpAndSettle();
    expect(next, findsOneWidget);
    expect(samples.any((alpha) => alpha > 0.35 && alpha < 0.99), isTrue);
    expect(_visibleLyricAlpha(tester, next), closeTo(1, 0.001));
  });

  testWidgets('emphasis stays at its target after a spring overshoots', (
    tester,
  ) async {
    final playback = await _mount(tester);
    await playback.container
        .read(playerLyricSettingsProvider.notifier)
        .updateSpringPreset(PlayerLyricSpringPreset.jello);
    await tester.pumpAndSettle();
    final next = find.text('spring 1');
    final anchor = tester.getCenter(
      find.byKey(const ValueKey('playback-line-indicator')),
    );
    final samples = <({double width, double alpha, double distance})>[];

    playback.positions.add(const Duration(seconds: 1));
    for (var frame = 0; frame < 100; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      samples.add((
        width: tester.getRect(next).width,
        alpha: _visibleLyricAlpha(tester, next),
        distance: tester.getCenter(next).dy - anchor.dy,
      ));
    }
    await tester.pumpAndSettle();
    final finalWidth = tester.getRect(next).width;
    final finalAlpha = _visibleLyricAlpha(tester, next);
    final firstTarget = samples.indexWhere(
      (sample) =>
          (sample.width - finalWidth).abs() < 0.1 &&
          (sample.alpha - finalAlpha).abs() < 0.005,
    );
    final firstOvershoot = samples.indexWhere(
      (sample) => sample.distance < -0.5,
    );

    expect(samples.any((sample) => sample.distance > 0.5), isTrue);
    expect(samples.any((sample) => sample.distance < -0.5), isTrue);
    expect(firstTarget, greaterThanOrEqualTo(0));
    expect(firstTarget, lessThanOrEqualTo(firstOvershoot + 1));
    for (final sample in samples.skip(firstTarget)) {
      expect(sample.width, closeTo(finalWidth, 0.1));
      expect(sample.alpha, closeTo(finalAlpha, 0.005));
    }
  });

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

  testWidgets('browsing keeps retained rows after emphasis completes', (
    tester,
  ) async {
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
        onSeekRequested: (_) {},
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
    await tester.pump(const Duration(seconds: 3));
    await _frames(tester, 5);
    playback.positions.add(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final trackedIndex = _lyricIndexAtPlaybackAnchor(tester);
    final line = find.text('spring $trackedIndex');
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, 30),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(line, findsOneWidget);
    final center = tester.getCenter(line);

    await _frames(tester, 100);
    expect(line, findsOneWidget);
    expect(tester.getCenter(line).dy, closeTo(center.dy, 0.5));

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    _expectAnchor(tester, 'spring 2');
  });

  for (final gesture in ['none', 'single', 'double', 'drag']) {
    testWidgets(
      'bouncy far return supports gestures on moving rows, gesture=$gesture',
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
        await tester.pump(const Duration(seconds: 3));
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final visibleIndex = _lyricIndexAtPlaybackAnchor(tester);
        final visibleLine = find.text('spring $visibleIndex');
        final initialY = tester.getCenter(visibleLine).dy;
        if (gesture == 'drag') {
          final pointer = await tester.startGesture(
            tester.getCenter(visibleLine),
          );
          await pointer.moveBy(const Offset(0, -30));
          await tester.pump();
          await pointer.moveBy(const Offset(0, -50));
          await tester.pump();
          expect(tester.getCenter(visibleLine).dy, closeTo(initialY - 50, 25));
          await pointer.up();
          await tester.pump(const Duration(milliseconds: 50));
          expect(requested, isEmpty);
          expect(toggleCount, 0);
        } else if (gesture != 'none') {
          final center = tester.getCenter(visibleLine);
          await tester.tapAt(center);
          if (gesture == 'double') {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.tapAt(center);
          }
          await tester.pump(kDoubleTapTimeout);
          expect(
            requested,
            gesture == 'single' ? [Duration(seconds: visibleIndex)] : isEmpty,
          );
          expect(toggleCount, gesture == 'double' ? 1 : 0);
          if (gesture == 'double') {
            await tester.pump(const Duration(seconds: 3));
            await tester.pumpAndSettle();
            _expectAnchor(tester, 'spring 1');
          }
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

  for (final reverse in [false, true]) {
    testWidgets(
      'a fling waits three seconds after stopping, reverse=$reverse',
      (tester) async {
        await _mount(tester, position: const Duration(seconds: 40));
        final list = find.byKey(const ValueKey('full-lyric-list'));
        final scrollable = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        final position = tester.state<ScrollableState>(scrollable).position;

        await tester.fling(list, Offset(0, reverse ? 360 : -360), 1600);
        await _expectFlingReturnAfterStop(tester, position, 'spring 40');
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
    await _expectFlingReturnAfterStop(tester, position, 'spring 0');
  });

  for (final cancel in [false, true]) {
    testWidgets(
      'holding a moving lyric delays the return until release, cancel=$cancel',
      (tester) async {
        await _mount(
          tester,
          position: const Duration(seconds: 20),
          display: (_) => FullLyricDisplay(
            isPortrait: true,
            showPlaybackLineControls: true,
            enableLineTapFeedback: true,
            onLongPress: () {},
          ),
        );
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

        final visibleLine = find.text(
          'spring ${_lyricIndexAtPlaybackAnchor(tester)}',
        );
        final gesture = await tester.startGesture(
          tester.getCenter(visibleLine),
        );
        await tester.pump();
        final heldOffset = position.pixels;
        await tester.pump(const Duration(seconds: 4));
        await _frames(tester, 3);
        expect(position.pixels, closeTo(heldOffset, 0.1));

        if (cancel) {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        _expectAnchor(tester, 'spring 20');
      },
    );
  }

  for (final preset in [
    PlayerLyricSpringPreset.defaultPreset,
    PlayerLyricSpringPreset.jello,
  ]) {
    for (final reverse in [false, true]) {
      testWidgets(
        'a distant browse return shows one continuous lyric list, preset=${preset.id}, reverse=$reverse',
        (tester) async {
          final targetIndex = reverse ? 60 : 10;
          final browseIndex = reverse ? 40 : 30;
          final playback = await _mount(
            tester,
            position: Duration(seconds: targetIndex),
          );
          await playback.container
              .read(playerLyricSettingsProvider.notifier)
              .updateSpringPreset(preset);
          await tester.pumpAndSettle();
          final list = find.byKey(const ValueKey('full-lyric-list'));
          final scrollable = find.descendant(
            of: list,
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(
            find.text('spring $browseIndex'),
            reverse ? -600 : 600,
            scrollable: scrollable,
          );
          await tester.pumpAndSettle();
          final position = tester.state<ScrollableState>(scrollable).position;
          final browsedOffset = position.pixels;
          await tester.pump(const Duration(seconds: 3));

          for (var frame = 0; frame < 160; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            final viewport = tester.getRect(find.byType(FullLyricDisplay));
            final rows =
                find
                    .descendant(of: list, matching: find.byType(RichText))
                    .evaluate()
                    .map((element) {
                      final paragraph =
                          element.renderObject! as RenderParagraph;
                      final match = RegExp(
                        r'^spring (\d+)$',
                      ).firstMatch(paragraph.text.toPlainText());
                      return (
                        index: match == null ? null : int.parse(match[1]!),
                        y: paragraph
                            .localToGlobal(paragraph.size.center(Offset.zero))
                            .dy,
                      );
                    })
                    .where(
                      (row) =>
                          row.index != null &&
                          row.y > viewport.top &&
                          row.y < viewport.bottom,
                    )
                    .toList()
                  ..sort((a, b) => a.y.compareTo(b.y));
            expect(rows, isNotEmpty);
            for (var i = 1; i < rows.length; i++) {
              expect(
                rows[i].index,
                rows[i - 1].index! + 1,
                reason: 'frame $frame: $rows',
              );
            }
          }
          expect(position.pixels, isNot(closeTo(browsedOffset, 1)));
          await tester.pumpAndSettle();
          _expectAnchor(tester, 'spring $targetIndex');
        },
      );
    }
  }

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
    await tester.tap(clickedLine);
    await tester.idle();
    await tester.pump();

    expect(requested, const Duration(seconds: 1));
    final afterConfirmation = tester.getCenter(clickedLine).dy;
    expect(_visibleLyricAlpha(tester, clickedLine), lessThan(1));
    expect(
      tester.getRect(clickedLine).width / tester.getSize(clickedLine).width,
      closeTo(0.97, 0.005),
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
    expect(_visibleLyricAlpha(tester, clickedLine), closeTo(1, 0.001));
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
    expect(_visibleLyricAlpha(tester, find.text('spring 3')), lessThan(1));

    await tester.pumpAndSettle();

    expect(playback.container.read(isPlayingProvider), isFalse);
    _expectAnchor(tester, 'spring 3');
    expect(
      _visibleLyricAlpha(tester, find.text('spring 3')),
      closeTo(1, 0.001),
    );
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
    expect(_visibleLyricAlpha(tester, clickedLine), closeTo(1, 0.001));
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

  testWidgets('pause settles and reduced motion snaps emphasis and position', (
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
    final settings = playback.container.read(playerLyricSettingsProvider);
    for (final text in ['spring 1', 'spring 2', 'spring 3']) {
      final line = find.text(text);
      expect(
        tester.getRect(line).width / tester.getSize(line).width,
        closeTo(
          text == 'spring 2'
              ? settings.fullActiveFontSize / settings.fullInactiveFontSize
              : 1,
          0.001,
        ),
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
    final settings = playback.container.read(playerLyricSettingsProvider);
    for (final index in [19, 20, 21]) {
      final line = find.text('spring $index');
      expect(
        tester.getRect(line).width / tester.getSize(line).width,
        closeTo(
          index == 20
              ? settings.fullActiveFontSize / settings.fullInactiveFontSize
              : 1,
          0.001,
        ),
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
        final initialScale =
            tester.getRect(activeLine).width / tester.getSize(activeLine).width;
        playback.positions.add(const Duration(seconds: 6));
        await tester.pump();
        await tester.pump();
        expect(
          tester.getRect(activeLine).width / tester.getSize(activeLine).width,
          closeTo(initialScale, 0.001),
        );
        await _frames(tester, 12);
        expect(
          tester.getRect(activeLine).width / tester.getSize(activeLine).width,
          greaterThan(initialScale),
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

double _visibleLyricAlpha(WidgetTester tester, Finder lyric) {
  final color = tester.widget<Text>(lyric).style?.color;
  final opacities = tester.widgetList<Opacity>(
    find.ancestor(of: lyric, matching: find.byType(Opacity)),
  );
  return opacities.fold(color?.a ?? 1.0, (alpha, opacity) {
    return alpha * opacity.opacity;
  });
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

Future<void> _expectFlingReturnAfterStop(
  WidgetTester tester,
  ScrollPosition position,
  String target,
) async {
  expect(position.isScrollingNotifier.value, isTrue);
  final releasedOffset = position.pixels;
  for (
    var frame = 0;
    frame < 400 && position.isScrollingNotifier.value;
    frame++
  ) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(position.isScrollingNotifier.value, isFalse);
  final stoppedOffset = position.pixels;
  expect((stoppedOffset - releasedOffset).abs(), greaterThan(1));
  for (var frame = 0; frame < 187; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.pixels, closeTo(stoppedOffset, 0.1));
  }
  await tester.pump(const Duration(milliseconds: 8));
  await _frames(tester, 4);
  expect((position.pixels - stoppedOffset).abs(), greaterThan(0.1));
  await tester.pumpAndSettle();
  _expectAnchor(tester, target);
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

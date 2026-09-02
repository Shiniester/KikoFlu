import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = AudioTrack(
  id: 'track-1',
  title: 'A deliberately long player title',
  url: 'https://example.invalid/audio.mp3',
  artist: 'Artist',
  album: 'Album',
);

void main() {
  setUp(
    () =>
        SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true}),
  );

  testWidgets('compact player renders the paged stage without overflow', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));
    expect(find.byKey(const ValueKey('compact-player-pages')), findsOneWidget);
    expect(find.byKey(const ValueKey('wide-player-layout')), findsNothing);
    expect(find.text(_track.title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide player renders the two equal stage regions', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(1280, 720));

    expect(find.byKey(const ValueKey('wide-player-layout')), findsOneWidget);
    expect(find.byKey(const ValueKey('wide-right-pages')), findsOneWidget);
    expect(find.text(_track.title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone landscape uses the wide stage without overflow', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(900, 412));

    expect(find.byKey(const ValueKey('wide-player-layout')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide player has a dark-theme no-artwork fallback', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(1024, 768), themeMode: ThemeMode.dark);

    expect(find.byKey(const ValueKey('wide-player-layout')), findsOneWidget);
    expect(find.byIcon(Icons.album), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('more is an action sheet and queue returns to the compact page', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Keep Screen Awake'), findsOneWidget);
    expect(find.text('Fullscreen lyrics'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('controls-pane-compact')),
        matching: find.byIcon(Icons.queue_music),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-queue-pane')), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
    final queueMaterial = tester.widget<Material>(
      find.byKey(const ValueKey('player-queue-track-track-1')),
    );
    expect(
      (queueMaterial.shape! as RoundedRectangleBorder).side.style,
      BorderStyle.none,
    );

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Clear playback queue?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compact-main-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('semantic panes and last-operated page survive resizes', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(320, 0),
    );
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1280, 720);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('wide-player-layout')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('wide-audio-details-pane')),
      findsOneWidget,
    );

    await tester.fling(
      find.byKey(const ValueKey('controls-queue-swipe-surface-wide')),
      const Offset(520, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyrics-pane-wide')), findsOneWidget);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyrics-pane-compact')), findsOneWidget);

    tester.view.physicalSize = const Size(1280, 720);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('wide-audio-details-pane')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('lyrics-pane-wide')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact queue has matching upward and downward gestures', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));
    PageView verticalPages() => tester.widget<PageView>(
      find.byKey(const ValueKey('compact-player-vertical-pages')),
    );
    expect(verticalPages().controller!.page, 0);

    await tester.fling(
      find.byKey(const ValueKey('compact-player-vertical-pages')),
      const Offset(0, -300),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-queue-pane')), findsOneWidget);
    expect(verticalPages().controller!.page, 1);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    expect(find.byType(ReorderableDelayedDragStartListener), findsOneWidget);

    await tester.fling(
      find.byKey(const ValueKey('player-queue-title-dismiss-surface')),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compact-player-pages')), findsOneWidget);
    expect(verticalPages().controller!.page, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact queue transition can be interrupted and dragged back', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));
    final verticalPages = tester.widget<PageView>(
      find.byKey(const ValueKey('compact-player-vertical-pages')),
    );

    final pageRect = tester.getRect(
      find.byKey(const ValueKey('compact-player-vertical-pages')),
    );
    final gesture = await tester.startGesture(pageRect.center);
    await gesture.moveBy(const Offset(0, -24));
    await gesture.moveBy(const Offset(0, -196));
    await tester.pump();
    expect(verticalPages.controller!.page, greaterThan(0));
    expect(verticalPages.controller!.page, lessThan(1));
    await gesture.moveBy(const Offset(0, 24));
    await gesture.moveBy(const Offset(0, 196));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(verticalPages.controller!.page, 0);
    expect(find.byKey(const ValueKey('compact-main-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact swipes right to details and left to lyrics', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));
    PageView horizontalPages() => tester.widget<PageView>(
      find.byKey(const ValueKey('compact-player-pages')),
    );
    expect(horizontalPages().controller!.page, 1);

    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(320, 0),
    );
    await tester.pumpAndSettle();
    expect(horizontalPages().controller!.page, 0);
    expect(
      find.byKey(const ValueKey('compact-audio-details-pane')),
      findsOneWidget,
    );

    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(horizontalPages().controller!.page, 1);

    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(horizontalPages().controller!.page, 2);
    expect(find.byKey(const ValueKey('lyrics-pane-compact')), findsOneWidget);
  });

  testWidgets('compact artwork uses the denser rectangular frame', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));

    final size = tester.getSize(
      find.byKey(const ValueKey('player-cover-artwork-track-1')),
    );
    expect(size.width / size.height, closeTo(4 / 3, 0.01));
    final title = tester.widget<Text>(find.text(_track.title));
    expect(title.maxLines, 2);
    expect(title.style?.fontSize, 20);
    expect(
      find.byKey(const ValueKey('compact-lyric-preview-5-lines')),
      findsOneWidget,
    );
    final controlsSize = tester.getSize(
      find.byKey(const ValueKey('controls-pane-compact')),
    );
    expect(controlsSize.width, closeTo(size.width, 0.01));
    final progressTheme = tester.widget<SliderTheme>(
      find.descendant(
        of: find.byKey(const ValueKey('controls-pane-compact')),
        matching: find.byType(SliderTheme),
      ),
    );
    expect(progressTheme.data.padding, EdgeInsets.zero);

    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(320, 0),
    );
    await tester.pumpAndSettle();
    final detailsWidth = tester
        .getSize(find.byKey(const ValueKey('compact-audio-details-pane')))
        .width;
    expect(detailsWidth, closeTo(size.width, 0.01));
  });

  testWidgets('compact header and five bottom actions align to artwork', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));

    final coverRect = tester.getRect(
      find.byKey(const ValueKey('player-cover-artwork-track-1')),
    );
    final controls = find.byKey(const ValueKey('controls-pane-compact'));
    final orderedIcons = [
      Icons.repeat,
      Icons.replay_10,
      Icons.bookmark_border,
      Icons.forward_10,
      Icons.queue_music,
    ];
    final centers = [
      for (final icon in orderedIcons)
        tester.getCenter(
          find.descendant(of: controls, matching: find.byIcon(icon)),
        ),
    ];
    for (var index = 1; index < centers.length; index++) {
      expect(centers[index - 1].dx, lessThan(centers[index].dx));
    }
    final moreRect = tester.getRect(
      find.byKey(const ValueKey('player-more-button')),
    );
    expect(moreRect.right, closeTo(coverRect.right, 0.01));
    expect(tester.getTopLeft(find.text(_track.title)).dx, coverRect.left);
  });

  testWidgets(
    'lyric actions use the same width and positions as main actions',
    (tester) async {
      final lyrics = List.generate(
        8,
        (index) => LyricLine(
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: 'aligned lyric $index',
        ),
      );
      await _pumpPlayer(tester, const Size(390, 844), lyrics: lyrics);
      final coverRect = tester.getRect(
        find.byKey(const ValueKey('player-cover-artwork-track-1')),
      );
      final controls = find.byKey(const ValueKey('controls-pane-compact'));
      final mainLeft = tester.getCenter(
        find.descendant(of: controls, matching: find.byIcon(Icons.repeat)),
      );
      final mainRight = tester.getCenter(
        find.descendant(of: controls, matching: find.byIcon(Icons.queue_music)),
      );

      await tester.drag(
        find.byKey(const ValueKey('compact-player-pages')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();

      final actionsRect = tester.getRect(
        find.byKey(const ValueKey('lyric-actions-width-boundary')),
      );
      final lyricLeft = tester.getCenter(
        find.byKey(const ValueKey('lyric-settings-button')),
      );
      final lyricRight = tester.getCenter(
        find.byKey(const ValueKey('lyric-search-button')),
      );
      expect(actionsRect.left, closeTo(coverRect.left, 0.01));
      expect(actionsRect.right, closeTo(coverRect.right, 0.01));
      expect(lyricLeft.dx, closeTo(mainLeft.dx, 0.01));
      expect(lyricRight.dx, closeTo(mainRight.dx, 0.01));
    },
  );

  testWidgets('downward main-page swipe dismisses to the mini-player route', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844), pushedRoute: true);
    expect(find.byKey(const ValueKey('compact-main-page')), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('compact-player-vertical-pages')),
      const Offset(0, 140),
    );
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
  });

  testWidgets('fixed header swipe dismisses directly from the lyric page', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844), pushedRoute: true);
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('compact-header-dismiss-surface')),
      const Offset(0, 160),
    );
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
  });

  testWidgets('fixed header swipe dismisses directly from the details page', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844), pushedRoute: true);
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(320, 0),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('compact-header-dismiss-surface')),
      const Offset(0, 160),
    );
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
  });

  testWidgets('short compact stage keeps controls and queue at cover width', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(839, 720));

    final coverWidth = tester
        .getSize(find.byKey(const ValueKey('player-cover-artwork-track-1')))
        .width;
    final controlsWidth = tester
        .getSize(find.byKey(const ValueKey('controls-pane-compact')))
        .width;
    expect(controlsWidth, closeTo(coverWidth, 0.01));

    await tester.tap(find.byIcon(Icons.queue_music));
    await tester.pumpAndSettle();
    final queueWidth = tester
        .getSize(find.byKey(const ValueKey('player-queue-width-boundary')))
        .width;
    expect(queueWidth, closeTo(coverWidth, 0.01));
    final queueBoundary = tester.getRect(
      find.byKey(const ValueKey('player-queue-width-boundary')),
    );
    final nowPlaying = tester.getRect(
      find.byKey(const ValueKey('player-queue-now-playing')),
    );
    final queueTrack = tester.getRect(
      find.byKey(const ValueKey('player-queue-track-track-1')),
    );
    expect(nowPlaying.left, closeTo(queueBoundary.left, 0.01));
    expect(nowPlaying.right, closeTo(queueBoundary.right, 0.01));
    expect(queueTrack.left, closeTo(queueBoundary.left, 0.01));
    expect(queueTrack.right, closeTo(queueBoundary.right, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'more cards match and closing more does not restore search input',
    (tester) async {
      final lyrics = List.generate(
        4,
        (index) => LyricLine(
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: 'searchable lyric $index',
        ),
      );
      await _pumpPlayer(tester, const Size(390, 844), lyrics: lyrics);
      await tester.drag(
        find.byKey(const ValueKey('compact-player-pages')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.tap(find.byKey(const ValueKey('player-more-button')));
      await tester.pumpAndSettle();
      final keepAwakeSize = tester.getSize(
        find.byKey(const ValueKey('player-more-keep-awake-card')),
      );
      final fullscreenSize = tester.getSize(
        find.byKey(const ValueKey('player-more-fullscreen-card')),
      );
      final overflowSize = tester.getSize(
        find.byKey(const ValueKey('player-more-action-floatingLyric')),
      );
      expect(fullscreenSize, keepAwakeSize);
      expect(overflowSize, keepAwakeSize);

      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.byKey(const ValueKey('lyric-search-field')), findsOneWidget);
    },
  );

  testWidgets('compact player supports doubled text and long metadata', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844), textScale: 2);

    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(320, 0),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('compact-audio-details-pane')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact title stays fixed while swiping both directions', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));
    final headerPosition = tester.getTopLeft(find.text(_track.title));
    final morePosition = tester.getCenter(
      find.byKey(const ValueKey('player-more-button')),
    );

    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(320, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text(_track.title), findsOneWidget);
    expect(tester.getTopLeft(find.text(_track.title)), headerPosition);
    expect(
      tester.getCenter(find.byKey(const ValueKey('player-more-button'))),
      morePosition,
    );

    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-640, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text(_track.title), findsOneWidget);
    expect(tester.getTopLeft(find.text(_track.title)), headerPosition);
    expect(
      tester.getCenter(find.byKey(const ValueKey('player-more-button'))),
      morePosition,
    );
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyric positioning never moves either player PageView', (
    tester,
  ) async {
    final lyrics = List.generate(
      24,
      (index) => LyricLine(
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: 'lyric line $index',
      ),
    );
    await _pumpPlayer(tester, const Size(390, 844), lyrics: lyrics);
    final preview = find.byKey(const ValueKey('compact-lyric-preview-5-lines'));
    expect(
      find.descendant(
        of: preview,
        matching: find.byKey(const ValueKey('compact-lyric-scroll-list')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.byType(FadeTransition)),
      findsNothing,
    );
    final horizontal = tester.widget<PageView>(
      find.byKey(const ValueKey('compact-player-pages')),
    );
    final vertical = tester.widget<PageView>(
      find.byKey(const ValueKey('compact-player-vertical-pages')),
    );

    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(horizontal.controller!.page, 2);
    expect(vertical.controller!.page, 0);

    await tester.tap(find.text('lyric line 3'));
    await tester.pump(const Duration(milliseconds: 700));
    expect(horizontal.controller!.page, 2);
    expect(vertical.controller!.page, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fullscreen lyric round trip restores the same compact page', (
    tester,
  ) async {
    final lyrics = List.generate(
      8,
      (index) => LyricLine(
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: 'fullscreen lyric $index',
      ),
    );
    await _pumpPlayer(tester, const Size(390, 844), lyrics: lyrics);
    final horizontal = tester.widget<PageView>(
      find.byKey(const ValueKey('compact-player-pages')),
    );
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('lyric-fullscreen-button')));
    await tester.pump();
    expect(find.byKey(const ValueKey('compact-player-layout')), findsNothing);
    expect(
      find.byKey(const ValueKey('compact-player-layout'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Offstage>(
            find.byKey(const ValueKey('player-stage-under-fullscreen')),
          )
          .offstage,
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compact-player-layout')), findsOneWidget);
    expect(
      tester
          .widget<Offstage>(
            find.byKey(const ValueKey('player-stage-under-fullscreen')),
          )
          .offstage,
      isFalse,
    );
    expect(horizontal.controller!.page, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated track changes preserve lyric page responsiveness', (
    tester,
  ) async {
    final tracks = StreamController<AudioTrack?>();
    addTearDown(tracks.close);
    tracks.add(_track);
    final lyrics = List.generate(
      12,
      (index) => LyricLine(
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: 'switch lyric $index',
      ),
    );
    await _pumpPlayer(
      tester,
      const Size(390, 844),
      lyrics: lyrics,
      trackStream: tracks.stream,
    );
    final horizontal = tester.widget<PageView>(
      find.byKey(const ValueKey('compact-player-pages')),
    );
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();

    for (var index = 0; index < 6; index++) {
      tracks.add(
        AudioTrack(
          id: 'track-$index',
          title: 'Track switch $index',
          url: 'https://example.invalid/$index.mp3',
          artist: 'Artist',
        ),
      );
      await tester.pump(const Duration(milliseconds: 320));
    }

    expect(horizontal.controller!.page, 2);
    await tester.tap(find.text('switch lyric 4'));
    await tester.pump(const Duration(milliseconds: 700));
    expect(horizontal.controller!.page, 2);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPlayer(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
  ThemeMode themeMode = ThemeMode.light,
  List<LyricLine>? lyrics,
  Stream<AudioTrack?>? trackStream,
  bool pushedRoute = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTrackProvider.overrideWith(
          (ref) => trackStream ?? Stream.value(_track),
        ),
        isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        playerStateProvider.overrideWith(
          (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
        ),
        queueProvider.overrideWith((ref) => Stream.value(const [_track])),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
        if (lyrics != null)
          lyricControllerProvider.overrideWith(
            (ref) =>
                LyricController(ref, initialState: LyricState(lyrics: lyrics)),
          ),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData.light(useMaterial3: true),
        darkTheme: ThemeData.dark(useMaterial3: true),
        themeMode: themeMode,
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: pushedRoute
            ? const Scaffold(body: Text('mini-player-host'))
            : const AudioPlayerScreen(),
      ),
    ),
  );
  await tester.pump();
  if (pushedRoute) {
    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(builder: (_) => const AudioPlayerScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }
  await tester.pump(const Duration(milliseconds: 350));
}

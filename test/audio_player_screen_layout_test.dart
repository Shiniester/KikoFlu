import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/models/lyric.dart';
import 'package:kikoeru_flutter/src/models/work.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/auth_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/providers/player_work_details_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:kikoeru_flutter/src/screens/work_detail_screen.dart';
import 'package:kikoeru_flutter/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_glass_surface.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_action_icons.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_lyrics_surface.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_route.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_vertical_gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = AudioTrack(
  id: 'track-1',
  title: 'A deliberately long player title',
  url: 'https://example.invalid/audio.mp3',
  artist: 'Artist',
  album: 'Album',
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'lyric_hint_has_shown': true,
      'custom_download_path': Directory.systemTemp.path,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  testWidgets('compact player renders the paged stage without overflow', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));
    expect(find.byKey(const ValueKey('compact-player-pages')), findsOneWidget);
    expect(find.byKey(const ValueKey('wide-player-layout')), findsNothing);
    expect(find.text(_track.title), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-track-title-button')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('track title opens one work detail route on compact and wide', (
    tester,
  ) async {
    const track = AudioTrack(
      id: 'work-track',
      title: 'Open this work',
      url: 'https://example.invalid/work.mp3',
      artist: 'Artist',
      album: 'Work album',
      workId: 42,
    );
    const work = Work(id: 42, title: 'Work album');
    const details = PlayerWorkDetailsData(
      track: track,
      work: work,
      fileTree: [],
      variants: [],
      fileTreeId: '42:test',
    );
    await _pumpPlayer(
      tester,
      const Size(390, 844),
      track: track,
      workDetails: details,
    );

    final compactTitle = find.byKey(
      const ValueKey('player-track-title-button'),
    );
    final compactTitleButton = tester.widget<InkWell>(compactTitle);
    compactTitleButton.onTap!();
    compactTitleButton.onTap!();
    await tester.pumpAndSettle();
    expect(find.byType(WorkDetailScreen, skipOffstage: false), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1280, 720);
    await tester.pumpAndSettle();
    final wideTitleButton = tester.widget<InkWell>(
      find.byKey(const ValueKey('player-track-title-button-wide')),
    );
    wideTitleButton.onTap!();
    wideTitleButton.onTap!();
    await tester.pumpAndSettle();
    expect(find.byType(WorkDetailScreen), findsOneWidget);
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
    expect(find.text('Subtitle view settings'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('player-more-lyric-settings-card')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Subtitle view settings'), findsOneWidget);
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

  testWidgets('direct queue entry starts on queue and pops to mini player', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      const Size(390, 844),
      pushedRoute: true,
      initialSurface: PlayerInitialSurface.queue,
    );

    expect(find.byKey(const ValueKey('player-queue-pane')), findsOneWidget);
    expect(_compactQueueProgress(tester), closeTo(1, 0.001));
    expect(
      tester
          .widget<AudioPlayerScreen>(find.byType(AudioPlayerScreen))
          .initialSurface,
      PlayerInitialSurface.queue,
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
    expect(find.byType(AudioPlayerScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct compact queue drag exits the player route', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      const Size(390, 844),
      pushedRoute: true,
      initialSurface: PlayerInitialSurface.queue,
    );

    await tester.fling(
      find.byKey(const ValueKey('player-queue-title-dismiss-surface')),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
    expect(find.byType(AudioPlayerScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct wide queue escape exits without showing main first', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      const Size(1280, 720),
      pushedRoute: true,
      initialSurface: PlayerInitialSurface.queue,
    );

    expect(find.byKey(const ValueKey('wide-player-layout')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-queue-pane')), findsOneWidget);
    expect(find.byKey(const ValueKey('wide-right-pages')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
    expect(find.byType(AudioPlayerScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('translate action stays visible and disabled without lyrics', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-320, 0),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final translate = find.byKey(const ValueKey('lyric-translate-button'));
    expect(translate, findsOneWidget);
    expect(tester.getSize(translate).width, 48);
    expect(
      tester
          .widget<IconButton>(
            find.descendant(of: translate, matching: find.byType(IconButton)),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('translate action remains visible while lyrics are loading', (
    tester,
  ) async {
    await _pumpPlayer(
      tester,
      const Size(390, 844),
      lyricState: LyricState(isLoading: true),
    );
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-320, 0),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final translate = find.byKey(const ValueKey('lyric-translate-button'));
    expect(translate, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.descendant(of: translate, matching: find.byType(IconButton)),
          )
          .onPressed,
      isNull,
    );
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
    expect(_compactQueueProgress(tester), closeTo(0, 0.001));

    await tester.fling(
      find.byKey(const ValueKey('compact-player-vertical-pages')),
      const Offset(0, -300),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-queue-pane')), findsOneWidget);
    expect(_compactQueueProgress(tester), closeTo(1, 0.001));
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    expect(find.byType(ReorderableDelayedDragStartListener), findsOneWidget);

    await tester.fling(
      find.byKey(const ValueKey('player-queue-title-dismiss-surface')),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compact-player-pages')), findsOneWidget);
    expect(_compactQueueProgress(tester), closeTo(0, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact queue transition can be interrupted and dragged back', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));
    final pageRect = tester.getRect(
      find.byKey(const ValueKey('compact-player-vertical-pages')),
    );
    final gesture = await tester.startGesture(pageRect.center);
    final openingProgress = <double>[];
    for (var index = 0; index < 16; index++) {
      await gesture.moveBy(const Offset(0, -14));
      await tester.pump();
      openingProgress.add(_compactQueueProgress(tester));
    }
    for (var index = 1; index < openingProgress.length; index++) {
      expect(
        openingProgress[index],
        greaterThanOrEqualTo(openingProgress[index - 1]),
      );
    }
    expect(_compactQueueProgress(tester), greaterThan(0));
    expect(_compactQueueProgress(tester), lessThan(1));
    final closingProgress = <double>[];
    for (var index = 0; index < 16; index++) {
      await gesture.moveBy(const Offset(0, 14));
      await tester.pump();
      closingProgress.add(_compactQueueProgress(tester));
    }
    for (var index = 1; index < closingProgress.length; index++) {
      expect(
        closingProgress[index],
        lessThanOrEqualTo(closingProgress[index - 1]),
      );
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_compactQueueProgress(tester), closeTo(0, 0.001));
    expect(find.byKey(const ValueKey('compact-main-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue opened from details returns to the details page', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844));
    final horizontal = tester.widget<PageView>(
      find.byKey(const ValueKey('compact-player-pages')),
    );
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(320, 0),
    );
    await tester.pumpAndSettle();
    expect(horizontal.controller!.page, 0);

    await tester.drag(
      find.byKey(const ValueKey('compact-header-dismiss-surface')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(_compactQueueProgress(tester), closeTo(1, 0.001));

    final reverseGesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('player-queue-title-dismiss-surface')),
      ),
    );
    await reverseGesture.moveBy(const Offset(0, 24));
    await reverseGesture.moveBy(const Offset(0, 120));
    await tester.pump();
    final draggedPage = _compactQueueProgress(tester);
    expect(draggedPage, lessThan(1));
    await reverseGesture.moveBy(const Offset(0, -104));
    await tester.pump();
    expect(_compactQueueProgress(tester), greaterThan(draggedPage));
    await reverseGesture.cancel();
    await tester.pumpAndSettle();
    expect(_compactQueueProgress(tester), closeTo(1, 0.001));

    await tester.drag(
      find.byKey(const ValueKey('player-queue-title-dismiss-surface')),
      const Offset(0, 240),
    );
    await tester.pumpAndSettle();
    expect(_compactQueueProgress(tester), closeTo(0, 0.001));
    expect(horizontal.controller!.page, 0);
    expect(
      find.byKey(const ValueKey('compact-audio-details-pane')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue opened from lyrics returns to the lyric page', (
    tester,
  ) async {
    final lyrics = List.generate(
      30,
      (index) => LyricLine(
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: 'queue origin lyric $index',
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
    expect(horizontal.controller!.page, 2);

    final lyricList = tester.widget<ListView>(
      find.byKey(const ValueKey('full-lyric-list')),
    );
    lyricList.controller!.jumpTo(
      lyricList.controller!.position.maxScrollExtent,
    );
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('full-lyric-list')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(_compactQueueProgress(tester), closeTo(0, 0.001));

    await tester.drag(
      find.byKey(const ValueKey('lyric-bottom-queue-swipe-surface')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(_compactQueueProgress(tester), closeTo(1, 0.001));

    await tester.drag(
      find.byKey(const ValueKey('player-queue-title-dismiss-surface')),
      const Offset(0, 240),
    );
    await tester.pumpAndSettle();
    expect(_compactQueueProgress(tester), closeTo(0, 0.001));
    expect(horizontal.controller!.page, 2);
    expect(find.byKey(const ValueKey('lyrics-pane-compact')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'lyrics queue gesture is owned by the blank search and action region',
    (tester) async {
      final lyrics = List.generate(
        24,
        (index) => LyricLine(
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: 'bottom queue lyric $index',
        ),
      );
      await _pumpPlayer(tester, const Size(390, 844), lyrics: lyrics);
      await tester.drag(
        find.byKey(const ValueKey('compact-player-pages')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();

      Future<void> closeQueue() async {
        await tester.drag(
          find.byKey(const ValueKey('player-queue-title-dismiss-surface')),
          const Offset(0, 240),
        );
        await tester.pumpAndSettle();
        expect(_compactQueueProgress(tester), closeTo(0, 0.001));
      }

      Future<void> openFromFinder(Finder finder) async {
        await tester.drag(finder, const Offset(0, -240));
        await tester.pumpAndSettle();
        expect(_compactQueueProgress(tester), closeTo(1, 0.001));
        await closeQueue();
      }

      final blankDrag = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey('lyric-bottom-queue-blank')),
        ),
      );
      await blankDrag.moveBy(const Offset(0, -24));
      await tester.pump();
      await blankDrag.moveBy(const Offset(0, -216));
      await blankDrag.up();
      await tester.pumpAndSettle();
      expect(_compactQueueProgress(tester), closeTo(1, 0.001));
      await closeQueue();

      for (final key in const <ValueKey<String>>[
        ValueKey('lyric-subtitle-picker-button'),
        ValueKey('lyric-download-button'),
        ValueKey('lyric-fullscreen-button'),
        ValueKey('lyric-translate-button'),
        ValueKey('lyric-search-button'),
      ]) {
        await openFromFinder(find.byKey(key));
      }

      await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('lyric-search-field')),
        'queue',
      );
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await openFromFinder(find.byKey(const ValueKey('lyric-search-field')));
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.text('queue'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(progressTheme.data.trackHeight, 2);
    expect(progressTheme.data.trackShape, isA<RoundedRectSliderTrackShape>());
    final thumbShape = progressTheme.data.thumbShape as RoundSliderThumbShape;
    expect(thumbShape.enabledThumbRadius, 4);

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
    final moreIconRect = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('player-more-button')),
        matching: find.byIcon(Icons.more_horiz),
      ),
    );
    expect(moreRect.right, closeTo(coverRect.right + 12, 0.01));
    expect(moreIconRect.right, closeTo(coverRect.right, 0.01));
    expect(tester.getTopLeft(find.text(_track.title)).dx, coverRect.left);
    await tester.tapAt(Offset(coverRect.right + 8, moreRect.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('Keep Screen Awake'), findsOneWidget);
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
        find.byKey(const ValueKey('lyric-subtitle-picker-button')),
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

  testWidgets('wide lyric search shares the action row center and width', (
    tester,
  ) async {
    final lyrics = List.generate(
      12,
      (index) => LyricLine(
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: 'wide aligned lyric $index',
      ),
    );
    await _pumpPlayer(
      tester,
      const Size(1000, 720),
      textScale: 1.4,
      lyrics: lyrics,
    );
    await tester.tap(
      find.byKey(const ValueKey('player-cover-artwork-track-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lyric-search-button')));
    await tester.pumpAndSettle();

    final actions = tester.getRect(
      find.byKey(const ValueKey('lyric-actions-width-boundary')),
    );
    final search = tester.getRect(
      find.byKey(const ValueKey('lyric-search-width-boundary')),
    );
    expect(search.width, closeTo(actions.width, 0.01));
    expect(search.center.dx, closeTo(actions.center.dx, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'main lyric preview scrolls without opening queue or dismissing',
    (tester) async {
      final lyrics = List.generate(
        40,
        (index) => LyricLine(
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: 'scrollable preview lyric $index',
        ),
      );
      await _pumpPlayer(
        tester,
        const Size(390, 844),
        pushedRoute: true,
        lyrics: lyrics,
      );
      expect(find.byKey(const ValueKey('compact-main-page')), findsOneWidget);

      final preview = find.byKey(
        const ValueKey('compact-main-lyric-scroll-surface'),
      );
      expect(
        ProviderScope.containerOf(
          tester.element(preview),
        ).read(currentLyricIndexProvider),
        0,
      );
      final previewRect = tester.getRect(preview);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: preview, matching: find.byType(Scrollable)),
      );
      final initialOffset = scrollable.position.pixels;

      await tester.drag(preview, const Offset(0, -96));
      await tester.pumpAndSettle();
      final browsedOffset = scrollable.position.pixels;
      expect(browsedOffset, greaterThan(initialOffset));
      expect(_compactQueueProgress(tester), closeTo(0, 0.001));
      expect(find.byType(AudioPlayerScreen), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1900));
      expect(scrollable.position.pixels, closeTo(browsedOffset, 0.01));
      await tester.pump(const Duration(milliseconds: 101));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      expect(scrollable.position.pixels, closeTo(initialOffset, 0.01));

      final previewGesture = await tester.startGesture(previewRect.center);
      for (var index = 0; index < 12; index++) {
        await previewGesture.moveBy(const Offset(0, 20));
        await tester.pump();
      }
      await previewGesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('compact-main-page')), findsOneWidget);
      expect(find.text('mini-player-host'), findsNothing);
      expect(_compactQueueProgress(tester), closeTo(0, 0.001));

      final coverRect = tester.getRect(
        find.byKey(const ValueKey('compact-main-cover-dismiss-surface')),
      );
      final coverGesture = await tester.startGesture(coverRect.center);
      for (var index = 0; index < 12; index++) {
        await coverGesture.moveBy(const Offset(0, 20));
        await tester.pump();
      }
      await coverGesture.up();
      await tester.pumpAndSettle();
      expect(find.text('mini-player-host'), findsOneWidget);
      expect(find.byType(AudioPlayerScreen), findsNothing);
    },
  );

  testWidgets('main controls dismissal follows and can reverse', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844), pushedRoute: true);
    final controlsRect = tester.getRect(
      find.byKey(const ValueKey('compact-main-controls-dismiss-surface')),
    );
    final gesture = await tester.startGesture(controlsRect.center);
    for (var index = 0; index < 8; index++) {
      await gesture.moveBy(const Offset(0, 15));
      await tester.pump();
    }
    final slide = tester.widget<SlideTransition>(
      find.byKey(const ValueKey('player-route-vertical-slide')),
    );
    final outward = slide.position.value.dy;
    expect(outward, greaterThan(0.1));

    for (var index = 0; index < 7; index++) {
      await gesture.moveBy(const Offset(0, -16));
      await tester.pump();
    }
    expect(slide.position.value.dy, lessThan(outward));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(AudioPlayerScreen), findsOneWidget);
    expect(find.text('mini-player-host'), findsNothing);

    final finishGesture = await tester.startGesture(controlsRect.center);
    for (var index = 0; index < 12; index++) {
      await finishGesture.moveBy(const Offset(0, 20));
      await tester.pump();
    }
    await finishGesture.up();
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
  });

  testWidgets('fixed header dismisses directly from the lyric page', (
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
      const Offset(0, 240),
    );
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
    expect(find.byType(AudioPlayerScreen), findsNothing);
  });

  testWidgets('system back dismisses directly from the details page', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(390, 844), pushedRoute: true);
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(320, 0),
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
    expect(find.byType(AudioPlayerScreen), findsNothing);
  });

  testWidgets('escape dismisses directly from the lyric page', (tester) async {
    await _pumpPlayer(tester, const Size(390, 844), pushedRoute: true);
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
    expect(find.byType(AudioPlayerScreen), findsNothing);
  });

  testWidgets('details and lyric top overscroll do not dismiss the player', (
    tester,
  ) async {
    final lyrics = List.generate(
      16,
      (index) => LyricLine(
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: 'no dismiss lyric $index',
      ),
    );
    await _pumpPlayer(
      tester,
      const Size(390, 844),
      lyrics: lyrics,
      pushedRoute: true,
    );
    final horizontal = tester.widget<PageView>(
      find.byKey(const ValueKey('compact-player-pages')),
    );

    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(320, 0),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.descendant(
        of: find.byKey(const ValueKey('compact-audio-details-pane')),
        matching: find.byType(CustomScrollView),
      ),
      const Offset(0, 240),
    );
    await tester.pumpAndSettle();
    expect(horizontal.controller!.page, 0);
    expect(find.text('mini-player-host'), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-640, 0),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('full-lyric-list')),
      const Offset(0, 240),
    );
    await tester.pumpAndSettle();
    expect(horizontal.controller!.page, 2);
    expect(find.text('mini-player-host'), findsNothing);
  });

  testWidgets('wide secondary body ignores down but its header dismisses', (
    tester,
  ) async {
    await _pumpPlayer(tester, const Size(840, 720), pushedRoute: true);
    await tester.fling(
      find.byKey(const ValueKey('controls-queue-swipe-surface-wide')),
      const Offset(520, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyrics-pane-wide')), findsOneWidget);

    final coverRect = tester.getRect(
      find.byKey(const ValueKey('wide-cover-dismiss-surface')),
    );
    final coverGesture = await tester.startGesture(coverRect.center);
    await coverGesture.moveBy(const Offset(0, 240));
    await coverGesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(AudioPlayerScreen), findsOneWidget);
    expect(find.text('mini-player-host'), findsNothing);

    final headerRect = tester.getRect(
      find.byKey(const ValueKey('wide-header-dismiss-surface')),
    );
    final headerGesture = await tester.startGesture(headerRect.center);
    await headerGesture.moveBy(const Offset(0, 240));
    await headerGesture.up();
    await tester.pumpAndSettle();
    expect(find.text('mini-player-host'), findsOneWidget);
    expect(find.byType(AudioPlayerScreen), findsNothing);
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
    final nowPlayingArtwork = find.byKey(
      const ValueKey('player-queue-now-playing-artwork'),
    );
    final queueArtwork = find.byKey(
      const ValueKey('player-queue-artwork-track-1'),
    );
    expect(tester.getSize(nowPlayingArtwork), const Size(64, 48));
    expect(tester.getSize(queueArtwork), const Size(64, 48));
    for (final artwork in [nowPlayingArtwork, queueArtwork]) {
      final decoration =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: artwork,
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(10));
    }
    final queueBoundary = tester.getRect(
      find.byKey(const ValueKey('player-queue-width-boundary')),
    );
    final nowPlaying = tester.getRect(
      find.byKey(const ValueKey('player-queue-now-playing')),
    );
    final titleBar = tester.getRect(
      find.byKey(const ValueKey('player-queue-title-bar')),
    );
    final queueTrackFinder = find.byKey(
      const ValueKey('player-queue-track-track-1'),
    );
    final queueTrack = tester.getRect(queueTrackFinder);
    expect(nowPlaying.left, closeTo(queueBoundary.left, 0.01));
    expect(nowPlaying.right, closeTo(queueBoundary.right, 0.01));
    expect(titleBar.left, closeTo(queueBoundary.left, 0.01));
    expect(titleBar.right, closeTo(queueBoundary.right, 0.01));
    expect(queueTrack.left, closeTo(queueBoundary.left, 0.01));
    expect(queueTrack.right, closeTo(queueBoundary.right, 0.01));
    expect(
      find.descendant(of: queueTrackFinder, matching: find.text('Artist')),
      findsOneWidget,
    );
    expect(find.text('Artist · Album'), findsNothing);
    final queueTitle = tester.widget<Text>(
      find.descendant(of: queueTrackFinder, matching: find.text(_track.title)),
    );
    expect(queueTitle.style?.fontSize, 12.5);
    expect(queueTitle.style?.height, 1.12);
    final shiftedTextColumn = tester.widget<Transform>(
      find
          .descendant(
            of: queueTrackFinder,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Transform &&
                  (widget.transform.storage[13] - 1).abs() < 0.001,
            ),
          )
          .first,
    );
    expect(shiftedTextColumn.transform.storage[13], closeTo(1, 0.001));
    final countText = tester.widget<Text>(find.text('1 / 1'));
    final clearText = tester.widget<Text>(find.text('Clear'));
    expect(clearText.style?.fontSize, countText.style?.fontSize);
    expect(clearText.style?.color, countText.style?.color);
    final removeIcon = tester.widget<Icon>(
      find.descendant(
        of: queueTrackFinder,
        matching: find.byIcon(Icons.remove),
      ),
    );
    expect(removeIcon.size, 18);
    final removeButton = find.ancestor(
      of: find.descendant(
        of: queueTrackFinder,
        matching: find.byIcon(Icons.remove),
      ),
      matching: find.byType(PlayerCompactAction),
    );
    expect(tester.getSize(removeButton), const Size(32, 32));
    expect(
      removeIcon.color,
      Theme.of(tester.element(queueTrackFinder)).colorScheme.onSurfaceVariant,
    );
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
      final lyricSettingsSize = tester.getSize(
        find.byKey(const ValueKey('player-more-lyric-settings-card')),
      );
      final overflowSize = tester.getSize(
        find.byKey(const ValueKey('player-more-action-floatingLyric')),
      );
      expect(fullscreenSize, keepAwakeSize);
      expect(lyricSettingsSize, keepAwakeSize);
      expect(overflowSize, keepAwakeSize);
      expect(keepAwakeSize.height, 72);
      final lyricSettingsRect = tester.getRect(
        find.byKey(const ValueKey('player-more-lyric-settings-card')),
      );
      final detailsRect = tester.getRect(
        find.byKey(const ValueKey('player-more-action-detail')),
      );
      expect(lyricSettingsRect.top, closeTo(detailsRect.top, 0.01));
      expect(lyricSettingsRect.left, lessThan(detailsRect.left));
      for (final key in const [
        'player-more-action-floatingLyric',
        'player-more-action-sleepTimer',
        'player-more-action-speed',
        'player-more-action-subtitleAdjustment',
      ]) {
        expect(
          tester.getRect(find.byKey(ValueKey(key))).bottom,
          lessThan(lyricSettingsRect.top),
        );
      }
      final moreGlass = find
          .ancestor(
            of: find.byKey(const ValueKey('player-more-keep-awake-card')),
            matching: find.byType(PlayerTransientGlassSurface),
          )
          .first;
      expect(
        find.descendant(of: moreGlass, matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );

      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.byKey(const ValueKey('lyric-search-field')), findsOneWidget);
    },
  );

  testWidgets(
    'keyboard lifts only lyric controls and clips the lyric viewport',
    (tester) async {
      final lyrics = List.generate(
        8,
        (index) => LyricLine(
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: 'keyboard lyric $index',
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

      final actionWidthRect = tester.getRect(
        find.byKey(const ValueKey('lyric-actions-width-boundary')),
      );
      final searchWidthRect = tester.getRect(
        find.byKey(const ValueKey('lyric-search-width-boundary')),
      );
      expect(searchWidthRect.width, closeTo(actionWidthRect.width, 0.01));
      expect(
        searchWidthRect.center.dx,
        closeTo(actionWidthRect.center.dx, 0.01),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('lyric-search-field')))
            .textAlign,
        TextAlign.start,
      );

      final stageBefore = tester.getRect(
        find.byKey(const ValueKey('compact-player-vertical-pages')),
      );
      final controlsBefore = tester.getRect(
        find.byKey(const ValueKey('lyric-controls-keyboard-lift')),
      );
      final lyricViewportBefore = tester.getRect(
        find.byKey(const ValueKey('lyric-keyboard-safe-viewport')),
      );
      final lyricScrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('full-lyric-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final scrollOffsetBefore = lyricScrollable.position.pixels;
      expect(controlsBefore.top - lyricViewportBefore.bottom, closeTo(4, 0.01));

      addTearDown(tester.view.resetViewInsets);
      var previousBottom = controlsBefore.bottom;
      for (final inset in const [80.0, 160.0, 280.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump();
        final controls = tester.getRect(
          find.byKey(const ValueKey('lyric-controls-keyboard-lift')),
        );
        final viewport = tester.getRect(
          find.byKey(const ValueKey('lyric-keyboard-safe-viewport')),
        );
        expect(controls.bottom, lessThan(previousBottom));
        expect(controls.bottom, closeTo(controlsBefore.bottom - inset, 0.01));
        expect(
          viewport.bottom,
          closeTo(lyricViewportBefore.bottom - inset, 0.01),
        );
        expect(controls.top - viewport.bottom, closeTo(4, 0.01));
        expect(
          lyricScrollable.position.pixels,
          closeTo(scrollOffsetBefore, 0.01),
        );
        expect(
          tester
              .getRect(
                find.byKey(const ValueKey('lyric-search-width-boundary')),
              )
              .center
              .dx,
          closeTo(searchWidthRect.center.dx, 0.01),
        );
        previousBottom = controls.bottom;
      }

      final stageAfter = tester.getRect(
        find.byKey(const ValueKey('compact-player-vertical-pages')),
      );
      final controlsAfter = tester.getRect(
        find.byKey(const ValueKey('lyric-controls-keyboard-lift')),
      );
      final lyricViewportAfter = tester.getRect(
        find.byKey(const ValueKey('lyric-keyboard-safe-viewport')),
      );
      expect(stageAfter, stageBefore);
      expect(controlsAfter.bottom, closeTo(controlsBefore.bottom - 280, 0.01));
      expect(
        lyricViewportAfter.bottom,
        closeTo(lyricViewportBefore.bottom - 280, 0.01),
      );
      expect(lyricViewportAfter.bottom, lessThan(controlsAfter.top));
      expect(controlsAfter.top - lyricViewportAfter.bottom, closeTo(4, 0.01));

      tester.view.resetViewInsets();
      await tester.pump();
      expect(
        tester.getRect(
          find.byKey(const ValueKey('lyric-controls-keyboard-lift')),
        ),
        controlsBefore,
      );
      expect(tester.takeException(), isNull);
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
    await tester.drag(
      find.byKey(const ValueKey('compact-player-pages')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(horizontal.controller!.page, 2);
    expect(_compactQueueProgress(tester), closeTo(0, 0.001));

    await tester.tap(find.text('lyric line 3'));
    await tester.pump(const Duration(milliseconds: 700));
    expect(horizontal.controller!.page, 2);
    expect(_compactQueueProgress(tester), closeTo(0, 0.001));
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

  testWidgets('compact semantic pages stay alive across repeated swipes', (
    tester,
  ) async {
    final lyrics = List.generate(
      20,
      (index) => LyricLine(
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: 'retained lyric $index',
      ),
    );
    await _pumpPlayer(tester, const Size(390, 844), lyrics: lyrics);
    final details = find.byKey(
      const ValueKey('compact-audio-details-pane'),
      skipOffstage: false,
    );
    final lyricSurface = find.byType(PlayerLyricsSurface, skipOffstage: false);
    final detailsState = tester.state(details);
    final lyricState = tester.state(lyricSurface);

    for (var cycle = 0; cycle < 3; cycle++) {
      await tester.drag(
        find.byKey(const ValueKey('compact-player-pages')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('compact-player-pages')),
        const Offset(640, 0),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('compact-player-pages')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
    }

    expect(tester.state(details), same(detailsState));
    expect(tester.state(lyricSurface), same(lyricState));
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
  PlayerInitialSurface initialSurface = PlayerInitialSurface.main,
  AudioTrack track = _track,
  PlayerWorkDetailsData? workDetails,
  LyricState? lyricState,
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
          (ref) => trackStream ?? Stream.value(track),
        ),
        kikoeruApiServiceProvider.overrideWithValue(_PlayerTestApiService()),
        isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        playerStateProvider.overrideWith(
          (ref) => Stream.value(PlayerState(false, ProcessingState.ready)),
        ),
        queueProvider.overrideWith((ref) => Stream.value([track])),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
        if (workDetails != null)
          playerWorkDetailsProvider.overrideWith((ref) async => workDetails),
        if (lyrics != null || lyricState != null)
          lyricControllerProvider.overrideWith(
            (ref) => LyricController(
              ref,
              initialState: lyricState ?? LyricState(lyrics: lyrics!),
            ),
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
            : AudioPlayerScreen(initialSurface: initialSurface),
      ),
    ),
  );
  await tester.pump();
  if (pushedRoute) {
    unawaited(
      navigatorKey.currentState!.push<void>(
        createAudioPlayerRoute<void>(initialSurface: initialSurface),
      ),
    );
    await tester.pumpAndSettle();
  }
  await tester.pump(const Duration(milliseconds: 350));
}

class _PlayerTestApiService extends KikoeruApiService {
  @override
  Future<Map<String, dynamic>> getWork(
    int workId, {
    bool forceRefresh = false,
  }) async => <String, dynamic>{'id': workId, 'title': 'Work album'};

  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async => const [];
}

double _compactQueueProgress(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find.byKey(const ValueKey('compact-player-stage-transform')),
  );
  final stageHeight = tester
      .getSize(find.byKey(const ValueKey('compact-player-vertical-pages')))
      .height;
  if (stageHeight <= 0) return 0;
  return (-transform.transform.storage[13] / stageHeight).clamp(0.0, 1.0);
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/models/audio_track.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/providers/artwork_theme_provider.dart';
import 'package:kikoeru_flutter/src/providers/lyric_provider.dart';
import 'package:kikoeru_flutter/src/screens/audio_player_screen.dart';
import 'package:kikoeru_flutter/src/services/audio_player_service.dart';
import 'package:kikoeru_flutter/src/services/playback_session_store.dart';
import 'package:kikoeru_flutter/src/services/storage_service.dart';
import 'package:kikoeru_flutter/src/widgets/player/playlist_dialog.dart';
import 'package:kikoeru_flutter/src/widgets/player/player_vertical_gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _liveTrack = AudioTrack(
  id: 'live',
  title: 'Current queue track',
  url: 'https://example.invalid/live.mp3',
);
const _historyTracks = [
  AudioTrack(
    id: 'history-first',
    title: 'Historical first track',
    url: 'https://example.invalid/first.mp3',
  ),
  AudioTrack(
    id: 'history-second',
    title: 'Historical second track',
    url: 'https://example.invalid/second.mp3',
  ),
];
const _queueOwner = 'https://example.invalid\nlistener';
const _history = PlaybackSessionSnapshot(
  queue: _historyTracks,
  currentIndex: 0,
  position: Duration(seconds: 37),
  ownerKey: _queueOwner,
  markingQueueId: 'historical-queue',
);
const _liveSnapshot = PlaybackSessionSnapshot(
  queue: [_liveTrack],
  currentIndex: 0,
  position: Duration.zero,
  ownerKey: _queueOwner,
  markingQueueId: 'live-queue',
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'lyric_hint_has_shown': true});
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );
  });

  for (final size in [
    const Size(390, 844),
    const Size(900, 412),
    const Size(1100, 800),
  ]) {
    testWidgets('swiping history only browses a read-only queue at $size', (
      tester,
    ) async {
      final actions = _QueueActions();
      await _pumpQueue(tester, size: size, actions: actions);

      expect(
        find.byKey(const ValueKey('player-queue-now-playing')),
        findsNothing,
      );
      expect(find.text(_liveTrack.title).hitTestable(), findsOneWidget);
      final labels = S.of(tester.element(find.byType(PlayerQueueBrowser)));
      final header = tester.getRect(
        find.byKey(const ValueKey('player-queue-browser-header')),
      );
      final pagePositionFinder = find.byKey(
        const ValueKey('player-queue-browser-page-position'),
      );
      final pagePosition = tester.getRect(pagePositionFinder);
      final title = tester.getRect(find.text(labels.playlistTitle));
      final clear = tester.getRect(find.text('Clear'));
      expect(pagePosition.right, lessThan(header.center.dx));
      expect(clear.left, greaterThan(header.center.dx));
      final pagePositionText = tester.widget<Text>(pagePositionFinder);
      expect(pagePositionText.data, '2 / 2');
      expect(
        pagePositionText.semanticsLabel,
        labels.queueBrowserPagePosition(2, 2),
      );
      expect(title.center.dy, closeTo(pagePosition.center.dy, .01));
      expect(clear.center.dy, closeTo(pagePosition.center.dy, .01));

      await tester.drag(
        find.byKey(const ValueKey('player-queue-history-content')),
        Offset(size.width * .8, 0),
      );
      await tester.pumpAndSettle();

      final historyPage = find.byKey(
        const ValueKey('player-queue-history-page-0'),
      );
      expect(
        find
            .byKey(const ValueKey('player-queue-history-track-history-first'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(
        find.descendant(of: historyPage, matching: find.byTooltip('Remove')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: historyPage,
          matching: find.byType(ReorderableDelayedDragStartListener),
        ),
        findsNothing,
      );
      expect(find.text(_liveTrack.title).hitTestable(), findsNothing);
      expect(
        find.byKey(const ValueKey('player-queue-now-playing')),
        findsNothing,
      );
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('0 / 2'), findsNothing);
      expect(
        find.byKey(const ValueKey('player-queue-clear-button')),
        findsOneWidget,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerQueueBrowser)),
      );
      expect(container.read(currentTrackProvider).valueOrNull, _liveTrack);
      expect(container.read(queueProvider).valueOrNull, [_liveTrack]);
      expect(actions.restored, isEmpty);
      expect(actions.skipped, isEmpty);

      await tester.drag(
        find.byKey(const ValueKey('player-queue-history-content')),
        Offset(-size.width * .8, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text(_liveTrack.title).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('queue swipes page through history at $size', (tester) async {
      final histories = StreamController<List<PlaybackSessionSnapshot>>();
      addTearDown(histories.close);
      final olderHistory = PlaybackSessionSnapshot(
        queue: [_historyTracks.last],
        currentIndex: 0,
        position: Duration.zero,
        ownerKey: _history.ownerKey,
        markingQueueId: 'older-queue',
      );
      await _pumpQueue(
        tester,
        size: size,
        actions: _QueueActions(),
        historyStream: histories.stream,
        screen: const AudioPlayerScreen(
          initialSurface: PlayerInitialSurface.queue,
        ),
      );
      histories.add([_history, olderHistory]);
      await tester.pumpAndSettle();

      final contentFinder = find.byKey(
        const ValueKey('player-queue-history-content'),
      );
      final bounds = tester.getRect(contentFinder);
      final available = tester.getRect(
        find.byKey(const ValueKey('player-queue-pane')),
      );
      expect(bounds.left, closeTo(available.left, .01));
      expect(bounds.right, closeTo(available.right, .01));
      final body = tester.getRect(
        find.byKey(const ValueKey('player-queue-width-boundary')),
      );
      expect(body.center.dx, closeTo(bounds.center.dx, .01));
      if (size.width >= 840) {
        expect(body.width, closeTo(bounds.width - 20, .01));
        final frame = tester.getRect(
          find.byKey(const ValueKey('player-queue-track-live')),
        );
        expect(frame.left - available.left, closeTo(10, .01));
        expect(available.right - frame.right, closeTo(10, .01));
      } else {
        expect(body.width, lessThan(bounds.width));
      }
      expect(tester.widget<PageView>(contentFinder).reverse, isTrue);
      final header = find.byKey(const ValueKey('player-queue-browser-header'));
      final initialHeader = tester.getRect(header);
      for (var page = 0; page < 2; page++) {
        final currentClear = tester
            .widget<TextButton>(
              find.byKey(const ValueKey('player-queue-clear-button')),
            )
            .onPressed;
        final gesture = await tester.startGesture(
          tester.getCenter(contentFinder),
        );
        await gesture.moveBy(const Offset(24, 0));
        await tester.pump();
        await gesture.moveBy(Offset(bounds.width * .65, 0));
        await tester.pump();
        final controller = tester.widget<PageView>(contentFinder).controller!;
        expect(controller.page, greaterThan(page.toDouble()));
        expect(controller.page, lessThan(page + 1));
        expect(tester.getRect(header), initialHeader);
        expect(find.text('${3 - page} / 3'), findsOneWidget);
        if (page == 0) {
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('player-queue-clear-button')),
                )
                .onPressed,
            same(currentClear),
          );
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.getRect(header), initialHeader);
        expect(find.text('${3 - page} / 3'), findsOneWidget);
        await tester.pumpAndSettle();
        expect(controller.page, closeTo(page + 1, .01));
        expect(tester.getRect(header), initialHeader);
        expect(find.text('${2 - page} / 3'), findsOneWidget);
        if (page == 0) {
          final historyClear = tester
              .widget<TextButton>(
                find.byKey(const ValueKey('player-queue-clear-button')),
              )
              .onPressed;
          expect(historyClear, isNot(same(currentClear)));
          historyClear!.call();
          await tester.pumpAndSettle();
          expect(
            find.text('Clear this historical playback queue?'),
            findsOneWidget,
          );
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('incoming compact history can be hit outside the body boundary', (
    tester,
  ) async {
    final histories = StreamController<List<PlaybackSessionSnapshot>>();
    addTearDown(histories.close);
    final olderHistory = PlaybackSessionSnapshot(
      queue: [_historyTracks.last],
      currentIndex: 0,
      position: Duration.zero,
      ownerKey: _history.ownerKey,
      markingQueueId: 'older-queue',
    );
    await _pumpQueue(
      tester,
      size: const Size(390, 844),
      actions: _QueueActions(),
      historyStream: histories.stream,
      screen: const AudioPlayerScreen(
        initialSurface: PlayerInitialSurface.queue,
      ),
    );
    histories.add([_history, olderHistory]);
    await tester.pumpAndSettle();

    final viewport = find.byKey(const ValueKey('player-queue-history-content'));
    final viewportRect = tester.getRect(viewport);
    final bodyRect = tester.getRect(
      find.byKey(const ValueKey('player-queue-width-boundary')),
    );
    expect(bodyRect.width, lessThan(viewportRect.width));

    final gesture = await tester.startGesture(tester.getCenter(viewport));
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    await gesture.moveBy(Offset(viewportRect.width * .65, 0));
    await tester.pump();

    final incomingTrack = find.byKey(
      const ValueKey('player-queue-history-track-history-first'),
    );
    final incomingRect = tester.getRect(incomingTrack);
    final point = Offset(viewportRect.left + 1, incomingRect.center.dy);
    expect(incomingRect.left, lessThan(point.dx));
    expect(incomingRect.right, greaterThan(point.dx));
    expect(point.dx, greaterThan(viewportRect.left));
    expect(point.dx, lessThan(viewportRect.right));
    final renderViewport = tester.renderObject<RenderViewport>(
      find.descendant(of: viewport, matching: find.byType(Viewport)).first,
    );
    final hits = BoxHitTestResult();
    // Inspect the viewport directly because scrolling suppresses pointer events.
    renderViewport.hitTest(hits, position: renderViewport.globalToLocal(point));
    expect(
      hits.path.map((entry) => entry.target),
      contains(tester.renderObject(incomingTrack)),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selecting history restores its owning queue and selected index',
    (tester) async {
      final tracks = StreamController<AudioTrack?>();
      final queues = StreamController<List<AudioTrack>>();
      final histories = StreamController<List<PlaybackSessionSnapshot>>();
      addTearDown(tracks.close);
      addTearDown(queues.close);
      addTearDown(histories.close);
      final actions = _QueueActions()
        ..onRestore = (snapshot, index) {
          tracks.add(snapshot.queue[index]);
          queues.add(snapshot.queue);
          histories.add([_liveSnapshot]);
        };
      await _pumpQueue(
        tester,
        actions: actions,
        initialHistory: true,
        currentTrackStream: tracks.stream,
        queueStream: queues.stream,
        historyStream: histories.stream,
      );

      await tester.tap(
        find.byKey(const ValueKey('player-queue-history-track-history-second')),
      );
      final pages = find.byKey(const ValueKey('player-queue-history-content'));
      await tester.pump();
      expect(tester.widget<PageView>(pages).controller!.page, 1);
      await tester.pumpAndSettle();

      expect(actions.restored, [(_history, 1)]);
      expect(actions.skipped, isEmpty);
      expect(find.byType(PlayerQueueBrowser), findsOneWidget);
      expect(find.byType(PlayerQueueSurface), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-queue-history-page-0')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('restoring queues keeps slots until the next queue visit', (
    tester,
  ) async {
    const olderTrack = AudioTrack(
      id: 'older',
      title: 'Older queue',
      url: 'https://example.invalid/older.mp3',
    );
    const older = PlaybackSessionSnapshot(
      queue: [olderTrack],
      currentIndex: 0,
      position: Duration.zero,
      ownerKey: _queueOwner,
      markingQueueId: 'older-queue',
    );
    final tracks = StreamController<AudioTrack?>();
    final queues = StreamController<List<AudioTrack>>();
    final histories = StreamController<List<PlaybackSessionSnapshot>>();
    final active = ValueNotifier(true);
    addTearDown(tracks.close);
    addTearDown(queues.close);
    addTearDown(histories.close);
    addTearDown(active.dispose);
    var saved = <PlaybackSessionSnapshot>[_history, older];
    var outgoing = _liveSnapshot;
    final actions = _QueueActions()
      ..onRestore = (snapshot, index) {
        saved = [outgoing, ...saved.where((item) => item != snapshot)];
        outgoing = snapshot;
        tracks.add(snapshot.queue[index]);
        queues.add(snapshot.queue);
        histories.add(saved);
      };
    await _pumpQueue(
      tester,
      actions: actions,
      initialHistories: saved,
      currentTrackStream: tracks.stream,
      queueStream: queues.stream,
      historyStream: histories.stream,
      active: active,
    );
    final pages = tester
        .widget<PageView>(
          find.byKey(const ValueKey('player-queue-history-content')),
        )
        .controller!;
    pages.jumpToPage(2);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('player-queue-history-track-older')),
    );
    await tester.pumpAndSettle();
    expect(pages.page, 2);
    expect(find.text('1 / 3'), findsOneWidget);
    expect(
      find
          .byKey(const ValueKey('player-queue-track-content-older'))
          .hitTestable(),
      findsOneWidget,
    );

    pages.jumpToPage(1);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('player-queue-history-track-history-second')),
    );
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    expect(find.text('2 / 3'), findsOneWidget);
    pages.jumpToPage(0);
    await tester.pumpAndSettle();
    expect(
      find
          .byKey(const ValueKey('player-queue-history-track-live'))
          .hitTestable(),
      findsOneWidget,
    );
    pages.jumpToPage(1);
    await tester.pumpAndSettle();
    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pumpAndSettle();
    expect(pages.page, 0);
    expect(find.text('3 / 3'), findsOneWidget);
    expect(
      find
          .byKey(const ValueKey('player-queue-track-content-history-second'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(actions.restored, [(older, 0), (_history, 1)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'queue visit is ready before midpoint and survives canceled exits',
    (tester) async {
      final tracks = StreamController<AudioTrack?>();
      final queues = StreamController<List<AudioTrack>>();
      final histories = StreamController<List<PlaybackSessionSnapshot>>();
      addTearDown(tracks.close);
      addTearDown(queues.close);
      addTearDown(histories.close);
      final actions = _QueueActions()
        ..onRestore = (snapshot, index) {
          tracks.add(snapshot.queue[index]);
          queues.add(snapshot.queue);
          histories.add([_liveSnapshot]);
        };
      await _pumpQueue(
        tester,
        actions: actions,
        currentTrackStream: tracks.stream,
        queueStream: queues.stream,
        historyStream: histories.stream,
        screen: const AudioPlayerScreen(),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('controls-pane-compact')),
          matching: find.byIcon(Icons.queue_music),
        ),
      );
      await tester.pumpAndSettle();
      final pages = tester
          .widget<PageView>(
            find.byKey(const ValueKey('player-queue-history-content')),
          )
          .controller!;
      final vertical = tester
          .widget<PageView>(
            find.byKey(const ValueKey('compact-vertical-player-pages')),
          )
          .controller!;
      pages.jumpToPage(1);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('player-queue-history-track-history-first')),
      );
      await tester.pumpAndSettle();
      expect(pages.page, 1);
      expect(find.text('1 / 2'), findsOneWidget);

      final queueHeader = find.byKey(
        const ValueKey('player-queue-title-dismiss-surface'),
      );
      final exit = await tester.startGesture(tester.getCenter(queueHeader));
      await exit.moveBy(const Offset(0, 24));
      await tester.pump();
      await exit.moveBy(const Offset(0, 520));
      await tester.pump();
      expect(vertical.page, inExclusiveRange(0, .5));
      await exit.moveBy(const Offset(0, -520));
      await tester.pump();
      await exit.up();
      await tester.pumpAndSettle();
      expect(vertical.page, 1);
      expect(pages.page, 1);
      expect(find.text('1 / 2'), findsOneWidget);

      await tester.drag(queueHeader, const Offset(0, 700));
      await tester.pumpAndSettle();
      expect(vertical.page, 0);
      final reentry = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey('compact-header-dismiss-surface')),
        ),
      );
      await reentry.moveBy(const Offset(0, -24));
      await tester.pump();
      await reentry.moveBy(const Offset(0, -140));
      await tester.pump();
      await tester.pump();
      expect(vertical.page, inExclusiveRange(0, .5));
      expect(pages.page, 0);
      expect(find.text('2 / 2'), findsOneWidget);
      await reentry.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restoring history retains its offset instead of the old live offset',
    (tester) async {
      final live = List.generate(
        80,
        (index) => AudioTrack(
          id: 'long-live-$index',
          title: 'Live $index',
          url: 'https://example.invalid/live-$index.mp3',
        ),
      );
      final archived = PlaybackSessionSnapshot(
        queue: live,
        currentIndex: live.length - 1,
        position: Duration.zero,
        ownerKey: _history.ownerKey,
        markingQueueId: 'long-live',
      );
      final historical = PlaybackSessionSnapshot(
        queue: List.generate(
          40,
          (index) => AudioTrack(
            id: 'long-history-$index',
            title: 'History $index',
            url: 'https://example.invalid/history-$index.mp3',
          ),
        ),
        currentIndex: 0,
        position: Duration.zero,
        ownerKey: _history.ownerKey,
        markingQueueId: 'long-history',
      );
      final tracks = StreamController<AudioTrack?>();
      final queues = StreamController<List<AudioTrack>>();
      final histories = StreamController<List<PlaybackSessionSnapshot>>();
      addTearDown(tracks.close);
      addTearDown(queues.close);
      addTearDown(histories.close);
      final actions = _QueueActions()
        ..onRestore = (snapshot, index) {
          tracks.add(snapshot.queue[index]);
          queues.add(snapshot.queue);
          histories.add([archived]);
        };
      await _pumpQueue(
        tester,
        actions: actions,
        liveTrack: live.last,
        initialHistories: [historical],
        liveQueue: live,
        currentTrackStream: tracks.stream,
        queueStream: queues.stream,
        historyStream: histories.stream,
      );
      final liveList = tester.widget<ReorderableListView>(
        find.byKey(const ValueKey('player-queue-list')),
      );
      expect(liveList.scrollController!.offset, greaterThan(0));
      final pages = tester
          .widget<PageView>(
            find.byKey(const ValueKey('player-queue-history-content')),
          )
          .controller!;
      pages.jumpToPage(1);
      await tester.pumpAndSettle();
      final selected = find.byKey(
        const ValueKey('player-queue-track-content-long-history-0'),
      );
      final before = tester.getTopLeft(selected).dy;
      await tester.tap(selected);
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(pages.page, 1);
        expect(tester.getTopLeft(selected).dy, closeTo(before, .01));
      }
      final restoredList = tester.widget<ReorderableListView>(
        find.byKey(const ValueKey('player-queue-list')),
      );
      expect(restoredList.scrollController!.offset, 0);
      expect(
        restoredList.scrollController!.position.isScrollingNotifier.value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (height, textScale) in [
    (844.0, 1.0),
    (560.0, 1.0),
    (844.0, 2.0),
  ]) {
    testWidgets(
      'queue entry positions the current row at $height with scale $textScale',
      (tester) async {
        final queue = List.generate(
          60,
          (index) => AudioTrack(
            id: 'position-$index',
            title: 'Position $index',
            url: 'https://example.invalid/position-$index.mp3',
          ),
        );
        final tracks = StreamController<AudioTrack?>();
        final active = ValueNotifier(true);
        addTearDown(tracks.close);
        addTearDown(active.dispose);
        final actions = _QueueActions();
        await _pumpQueue(
          tester,
          actions: actions,
          size: Size(390, height),
          textScale: textScale,
          liveTrack: queue[30],
          liveQueue: queue,
          initialHistories: [],
          currentTrackStream: tracks.stream,
          active: active,
        );
        final listFinder = find.byKey(const ValueKey('player-queue-list'));
        final list = tester.widget<ReorderableListView>(listFinder);
        final bounds = tester.getRect(listFinder);
        final extent = list.itemExtent!;
        final count = (bounds.height / extent).floor();
        final expectedRow = (count * .4).ceil() - 1;
        final current = find.byKey(
          const ValueKey('player-queue-track-content-position-30'),
        );
        expect(
          tester.getTopLeft(current).dy - bounds.top,
          closeTo(expectedRow * extent, .01),
        );
        final offset = list.scrollController!.offset;
        await tester.tap(current);
        tracks.add(queue[5]);
        await tester.pumpAndSettle();
        expect(actions.skipped, [30]);
        expect(list.scrollController!.offset, offset);
        for (final index in [59, 0]) {
          tracks.add(queue[index]);
          active.value = false;
          await tester.pumpAndSettle();
          active.value = true;
          await tester.pumpAndSettle();
          final position = list.scrollController!.position;
          expect(
            position.pixels,
            index == 0 ? position.minScrollExtent : position.maxScrollExtent,
          );
          final row = tester.getRect(
            find.byKey(ValueKey('player-queue-track-content-position-$index')),
          );
          expect(row.top, greaterThanOrEqualTo(bounds.top));
          expect(row.bottom, lessThanOrEqualTo(bounds.bottom));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a failed rapid restore preserves the previous successful slot', (
    tester,
  ) async {
    const otherTrack = AudioTrack(
      id: 'other-history',
      title: 'Other history',
      url: 'https://example.invalid/other.mp3',
    );
    const other = PlaybackSessionSnapshot(
      queue: [otherTrack],
      currentIndex: 0,
      position: Duration.zero,
      ownerKey: _queueOwner,
      markingQueueId: 'other-queue',
    );
    final tracks = StreamController<AudioTrack?>();
    final queues = StreamController<List<AudioTrack>>();
    final histories = StreamController<List<PlaybackSessionSnapshot>>();
    addTearDown(tracks.close);
    addTearDown(queues.close);
    addTearDown(histories.close);
    final service = _QueueService();
    final actions = _QueueActions()
      ..onRestore = (snapshot, index) {
        service.saved = [_liveSnapshot, other];
        tracks.add(snapshot.queue[index]);
        queues.add(snapshot.queue);
        histories.add(service.saved);
      };
    await _pumpQueue(
      tester,
      actions: actions,
      service: service,
      initialHistories: [_history, other],
      currentTrackStream: tracks.stream,
      queueStream: queues.stream,
      historyStream: histories.stream,
    );
    final pages = tester
        .widget<PageView>(
          find.byKey(const ValueKey('player-queue-history-content')),
        )
        .controller!;
    VoidCallback callbackFor(String id) => tester
        .widget<InkWell>(
          find.descendant(
            of: find.byKey(ValueKey('player-queue-track-content-$id')),
            matching: find.byType(InkWell),
          ),
        )
        .onTap!;
    pages.jumpToPage(2);
    await tester.pumpAndSettle();
    final tapOther = callbackFor(otherTrack.id);
    pages.jumpToPage(1);
    await tester.pumpAndSettle();
    final tapFirst = callbackFor(_historyTracks.first.id);
    tapFirst();
    await tester.idle();
    actions.failure = StateError('second restore failed');
    tapOther();
    await tester.idle();
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(
      find
          .byKey(const ValueKey('player-queue-track-content-history-first'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(find.textContaining('second restore failed'), findsOneWidget);
    tapFirst();
    await tester.pumpAndSettle();
    expect(actions.restored, [(_history, 0), (other, 0)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed historical load keeps the browsed queue available', (
    tester,
  ) async {
    final actions = _QueueActions()..failure = StateError('load failed');
    await _pumpQueue(tester, actions: actions, initialHistory: true);

    await tester.tap(
      find.byKey(const ValueKey('player-queue-history-track-history-first')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('load failed'), findsOneWidget);
    expect(
      find
          .byKey(const ValueKey('player-queue-history-track-history-first'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(actions.restored, [(_history, 0)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue navigation buttons browse without starting playback', (
    tester,
  ) async {
    final actions = _QueueActions();
    await _pumpQueue(tester, size: const Size(1100, 800), actions: actions);
    final pages = find.byKey(const ValueKey('player-queue-history-content'));
    final controller = tester.widget<PageView>(pages).controller!;

    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('player-queue-history-next-button')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(
      find.byKey(const ValueKey('player-queue-history-previous-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(controller.page, greaterThan(0));
    expect(controller.page, lessThan(1));
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(controller.page, closeTo(1, .01));
    expect(find.text('1 / 2'), findsOneWidget);
    expect(
      find
          .byKey(const ValueKey('player-queue-history-track-history-first'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('player-queue-history-previous-button')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(
      find.byKey(const ValueKey('player-queue-history-next-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(controller.page, greaterThan(0));
    expect(controller.page, lessThan(1));
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(controller.page, closeTo(0, .01));
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text(_liveTrack.title).hitTestable(), findsWidgets);
    expect(actions.restored, isEmpty);
    expect(actions.skipped, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue navigation jumps when reduced motion is enabled', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pumpQueue(
      tester,
      size: const Size(1100, 800),
      actions: _QueueActions(),
    );

    final pages = find.byKey(const ValueKey('player-queue-history-content'));
    final controller = tester.widget<PageView>(pages).controller!;
    await tester.tap(
      find.byKey(const ValueKey('player-queue-history-previous-button')),
    );
    await tester.pump();

    expect(controller.page, 1);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1100, 800)]) {
    testWidgets('history entry works without a current track at $size', (
      tester,
    ) async {
      await _pumpQueue(
        tester,
        size: size,
        actions: _QueueActions(),
        liveTrack: null,
        screen: const AudioPlayerScreen(
          initialSurface: PlayerInitialSurface.queue,
          initialQueueHistory: true,
        ),
      );

      expect(find.byType(PlayerQueueBrowser), findsOneWidget);
      expect(
        find
            .byKey(const ValueKey('player-queue-history-track-history-first'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('restoring from an empty player stays on the restored queue', (
    tester,
  ) async {
    final tracks = StreamController<AudioTrack?>();
    final queues = StreamController<List<AudioTrack>>();
    final histories = StreamController<List<PlaybackSessionSnapshot>>();
    addTearDown(tracks.close);
    addTearDown(queues.close);
    addTearDown(histories.close);
    final actions = _QueueActions()
      ..onRestore = (snapshot, index) {
        tracks.add(snapshot.queue[index]);
        queues.add(snapshot.queue);
        histories.add([]);
      };
    await _pumpQueue(
      tester,
      actions: actions,
      liveTrack: null,
      currentTrackStream: tracks.stream,
      queueStream: queues.stream,
      historyStream: histories.stream,
      screen: const AudioPlayerScreen(
        initialSurface: PlayerInitialSurface.queue,
        initialQueueHistory: true,
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('player-queue-history-track-history-second')),
    );
    await tester.pumpAndSettle();

    expect(actions.restored, [(_history, 1)]);
    expect(find.byType(PlayerQueueBrowser), findsOneWidget);
    expect(find.byType(PlayerQueueSurface), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-queue-history-page-0')),
      findsNothing,
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerQueueBrowser)),
    );
    expect(container.read(currentTrackProvider).valueOrNull, _historyTracks[1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clearing history requires confirmation and preserves playback', (
    tester,
  ) async {
    final histories = StreamController<List<PlaybackSessionSnapshot>>();
    addTearDown(histories.close);
    final actions = _QueueActions()..onClear = (_) => histories.add([]);
    await _pumpQueue(
      tester,
      actions: actions,
      initialHistory: true,
      historyStream: histories.stream,
    );
    final pages = find.byKey(const ValueKey('player-queue-history-content'));
    expect(tester.widget<PageView>(pages).controller!.page, 1);
    expect(find.text('1 / 2'), findsOneWidget);
    final clearButton = find.byKey(const ValueKey('player-queue-clear-button'));
    await tester.tap(clearButton);
    await tester.pumpAndSettle();
    expect(find.text('Clear this historical playback queue?'), findsOneWidget);
    expect(actions.cleared, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions.cleared, isEmpty);
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.tap(clearButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(actions.cleared, [_history]);
    expect(actions.currentCleared, 0);
    expect(actions.restored, isEmpty);
    expect(actions.skipped, isEmpty);
    expect(find.byType(PlayerQueueSurface), findsOneWidget);
    expect(tester.widget<PageView>(pages).controller!.page, 0);
    expect(find.text('1 / 1'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerQueueBrowser)),
    );
    expect(container.read(currentTrackProvider).valueOrNull, _liveTrack);
    expect(container.read(queueProvider).valueOrNull, [_liveTrack]);
    expect(container.read(historicalQueuesProvider).valueOrNull, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed history clearing keeps the historical queue visible', (
    tester,
  ) async {
    final actions = _QueueActions()..clearFailure = StateError('clear failed');
    await _pumpQueue(tester, actions: actions, initialHistory: true);
    await tester.tap(find.byKey(const ValueKey('player-queue-clear-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(find.textContaining('clear failed'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-queue-history-page-0')),
      findsOneWidget,
    );
    expect(actions.currentCleared, 0);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpQueue(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  required _QueueActions actions,
  bool initialHistory = false,
  AudioTrack? liveTrack = _liveTrack,
  List<AudioTrack>? liveQueue,
  List<PlaybackSessionSnapshot> initialHistories = const [_history],
  ValueNotifier<bool>? active,
  double textScale = 1,
  AudioPlayerService? service,
  Stream<AudioTrack?>? currentTrackStream,
  Stream<List<AudioTrack>>? queueStream,
  Stream<List<PlaybackSessionSnapshot>>? historyStream,
  Widget? screen,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  Widget browser(bool isActive) => PlayerQueueBrowser(
    isActive: isActive,
    initialQueueHistory: initialHistory,
    showPageButtons: size.width >= 840,
    onClear: () async {
      actions.currentCleared++;
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (service != null)
          audioPlayerServiceProvider.overrideWithValue(service),
        currentTrackProvider.overrideWith((ref) async* {
          yield liveTrack;
          if (currentTrackStream != null) yield* currentTrackStream;
        }),
        queueProvider.overrideWith((ref) async* {
          yield liveQueue ?? [if (liveTrack != null) liveTrack];
          if (queueStream != null) yield* queueStream;
        }),
        historicalQueuesProvider.overrideWith((ref) async* {
          yield initialHistories;
          if (historyStream != null) yield* historyStream;
        }),
        audioPlayerControllerProvider.overrideWith(
          (ref) => _QueueController(ref, actions),
        ),
        playerStateProvider.overrideWith(
          (ref) => Stream.value(PlayerState(true, ProcessingState.ready)),
        ),
        isTrackLoadingProvider.overrideWith((ref) => Stream.value(false)),
        positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
        durationProvider.overrideWith(
          (ref) => Stream.value(const Duration(minutes: 4)),
        ),
        manualSkipAvailabilityProvider.overrideWith(
          (ref) => Stream.value(ManualSkipAvailability.unavailable),
        ),
        lyricAutoLoaderProvider.overrideWith((ref) {}),
        themeArtworkDescriptorProvider.overrideWith((ref) => null),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        builder: textScale == 1
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
        home:
            screen ??
            Scaffold(
              body: active == null
                  ? browser(true)
                  : ValueListenableBuilder<bool>(
                      valueListenable: active,
                      builder: (context, isActive, _) => browser(isActive),
                    ),
            ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _QueueActions {
  final restored = <(PlaybackSessionSnapshot, int)>[];
  final skipped = <int>[];
  final cleared = <PlaybackSessionSnapshot>[];
  int currentCleared = 0;
  Object? failure;
  Object? clearFailure;
  void Function(PlaybackSessionSnapshot, int)? onRestore;
  void Function(PlaybackSessionSnapshot)? onClear;
}

class _QueueService implements AudioPlayerService {
  List<PlaybackSessionSnapshot> saved = [];

  @override
  List<PlaybackSessionSnapshot> get historicalQueues => saved;

  @override
  List<AudioTrack> get queue => [_liveTrack];

  @override
  Future<void> updatePrivacySettings({
    required bool enabled,
    required bool blurCover,
    required bool maskTitle,
    required String customTitle,
  }) async {}

  @override
  Future<void> updateHapticsSettings({
    required bool enabled,
    required double intensity,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QueueController extends AudioPlayerController {
  _QueueController(Ref ref, this.actions)
    : super(ref.read(audioPlayerServiceProvider), ref);

  final _QueueActions actions;

  @override
  Future<bool> restoreHistoricalQueue(
    PlaybackSessionSnapshot snapshot,
    int index,
  ) async {
    actions.restored.add((snapshot, index));
    if (actions.failure case final error?) throw error;
    actions.onRestore?.call(snapshot, index);
    return true;
  }

  @override
  Future<void> skipToIndex(int index) async => actions.skipped.add(index);

  @override
  Future<bool> clearHistoricalQueue(PlaybackSessionSnapshot snapshot) async {
    actions.cleared.add(snapshot);
    if (actions.clearFailure case final error?) throw error;
    actions.onClear?.call(snapshot);
    return true;
  }
}
